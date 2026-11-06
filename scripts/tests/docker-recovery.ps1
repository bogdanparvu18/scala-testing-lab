# Run with pwsh -NoProfile -File scripts/tests/docker-recovery.ps1.
# Mock only OS/engine operations. Inspect the actual decision and CLI arguments.
$ErrorActionPreference = 'Stop'
$bootstrap = Join-Path $PSScriptRoot '../bootstrap-windows.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($bootstrap, [ref]$null, [ref]$null)
$functions = foreach ($name in @('Run','Save-Json','Get-DockerObject','Get-OtherPostgresEvidence','Save-DockerCredentials','Copy-DockerWorker','Ensure-DockerImage','Select-DockerDatabaseImage','Assert-ServerVersion','Invoke-DockerRuntime')) {
    $func = $ast.Find({ param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -ceq $name }, $true)
    $func.Extent.Text
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) (([guid]::NewGuid()).ToString() + '.ps1')
try { [IO.File]::WriteAllLines($fixture, [string[]]$functions); . $fixture } finally { [IO.File]::Delete($fixture) }
$Root = Join-Path ([IO.Path]::GetTempPath()) ('aurora-docker-test-' + [guid]::NewGuid())
$Utf8 = New-Object Text.UTF8Encoding($false)
$ContainerName = 'managed-db'; $VolumeName = 'db-volume'; $RuntimeContainerName = 'linux-runtime'
$RuntimeVolumeName = 'source-volume'; $RuntimeCacheVolumeName = 'cache-volume'; $RuntimeImage = 'ubuntu:24.04'
$DockerToolSearchPath = @('/opt/company/java tools','/custom'); $RuntimeImageSpecified = $false; $NoEditor = $true; $ScalaBranch = 'test'; $LangiumBranch = 'main'
$StartupTimeoutSeconds = 30; $AllowToolUpgrade = $false; $interactive = $false
$PgHost = '127.0.0.1'; $Database = 'my_lab'; $DbUser = 'lab_user'; $Port = 5467
$oldPassword = $env:PGPASSWORD; $oldPostgresPassword = $env:POSTGRES_PASSWORD
$env:PGPASSWORD = 'fixture-password'; $DockerUseHostPostgres = $true; $DockerUseManagedPostgres = $false
$scenario = 'new'; $global:LASTEXITCODE = 0
$script:calls = [Collections.Generic.List[string[]]]::new()
function Protect-BootstrapState($Path) {}
function Test-BootstrapInteractive { return $interactive }
function Confirm-ToolUpgrade($name, $explanation) { return $AllowToolUpgrade }
function Get-CimInstance { return @{Name='ClinicalDB'; PathName='"C:\pg\bin\pg_ctl.exe" runservice'; State='Running'} }
function Assert-Test($condition, $label) { if (-not $condition) { throw $label } }
function docker.exe {
    $argsCopy = [string[]]$args
    $script:calls.Add($argsCopy)
    $global:LASTEXITCODE = 0
    switch ($args[0]) {
        'container' {
            if ($args[1] -eq 'ls') {
                if ($scenario -eq 'managed-existing') {
                    '{"Names":"managed-db","Image":"postgres:17","Ports":"127.0.0.1:55433->5432/tcp"}'
                    return
                }
                if ($scenario -eq 'existing') { return '{"Names":"linux-runtime","Image":"local/aurora","Ports":""}' }
                return
            }
            if ($args[1] -eq 'inspect' -and $args[2] -eq $ContainerName) {
                return ConvertTo-Json -Depth 8 -Compress @{
                    Id='existing-id'; Config=@{Image='postgres:17';Env=@('POSTGRES_USER=rxnorm_lab','POSTGRES_DB=rxnorm_public','PGDATA=/var/lib/postgresql/data','POSTGRES_PASSWORD=managedpw')};
                    Mounts=@(@{Destination='/var/lib/postgresql/data';Type='volume';Name=$VolumeName;RW=$true});
                    State=@{Running=$true};HostConfig=@{PortBindings=@{'5432/tcp'=@(@{HostIp='127.0.0.1';HostPort=[string]$Port})};NetworkMode='bridge'}
                }
            }
            if ($args[1] -eq 'inspect' -and $scenario -eq 'existing') {
                return ConvertTo-Json -Depth 8 -Compress @{
                    Config=@{Image='local/aurora';Labels=@{'aurora.runtime.schema'='1';'aurora.host.root'=$Root};Env=@('PGHOST=127.0.0.1',"PGPORT=$Port","PGDATABASE=$Database","PGUSER=$DbUser")};
                    Mounts=@(@{Destination='/workspace';Type='volume';Name=$RuntimeVolumeName;RW=$true},@{Destination='/root';Type='volume';Name=$RuntimeCacheVolumeName;RW=$true});
                    State=@{Running=$false};HostConfig=@{NetworkMode='host'}
                }
            }
        }
        'volume' { return }
        'image' {
            if ($args[1] -eq 'ls' -and '--format' -in $args) {
                if ($scenario -eq 'local-image') { 'postgres:18.1' }
                if ($scenario -eq 'old-image') { 'postgres:14' }
                return
            }
            if ($args[1] -eq 'ls') { return 'local-image-id' }
            if ($args[1] -eq 'inspect') {
                if ($args[2] -in @('postgres:18.1', 'postgres:14')) {
                    $major = if ($scenario -eq 'old-image') {14} else {18}
                    return ConvertTo-Json -Depth 5 -Compress @{
                        Os='linux';Architecture='amd64';Config=@{ Env=@("PG_MAJOR=$major","PGDATA=/var/lib/postgresql/$major/docker"); Volumes=@{'/var/lib/postgresql'=@{}} }
                    }
                }
                return '{"Os":"linux","Architecture":"amd64"}'
            }
        }
        'run' {
            if ($scenario -eq 'unreachable' -and '--rm' -in $args) { $global:LASTEXITCODE = 1 }
            return
        }
        'start' { return }
        'exec' { if ('psql' -in $args) { return '170001' }; return }
        'cp' { $script:copied = [IO.File]::ReadAllBytes($args[1]); return }
    }
    throw ('Unexpected Docker operation: ' + ($args -join ' '))
}
function Calls($predicate) { @($script:calls | Where-Object $predicate).Count }
try {
    $null = New-Item -Type Directory $Root
    $source = Join-Path $Root 'source.sh'
    [IO.File]::WriteAllText($source, "#!/bin/bash`r`nset -euo pipefail`r`n", [Text.Encoding]::Unicode)
    $original = (Get-FileHash $source).Hash
    $destination = Copy-DockerWorker $source $Root
    Assert-Test ($destination -like '/tmp/worker-*.sh' -and $script:copied[0] -eq 35 -and 13 -notin $script:copied) 'Linux worker must be BOM-free UTF-8 with LF.'
    Assert-Test (($original -eq (Get-FileHash $source).Hash) -and -not (Get-ChildItem $Root -Filter 'worker-*.sh')) 'Source was modified or a temporary file leaked.'
    function Copy-DockerWorker($source, $stateDirectory) { '/tmp/test-worker.sh' }
    $script:calls.Clear()
    Invoke-DockerRuntime
    Assert-Test ((Calls { $_[0] -eq 'container' -and $_[1] -eq 'ls' }) -eq 1) 'Repeated container inventory.'
    Assert-Test ((Calls { $_[0] -eq 'volume' -and $_[1] -eq 'ls' }) -eq 1) 'Repeated volume inventory.'
    Assert-Test ((Calls { $_[0] -eq 'run' -and '--rm' -in $_ -and 'host' -in $_ }) -eq 1) 'Missing host-network preflight.'
    Assert-Test ((Calls { $_[0] -eq 'run' -and '-d' -in $_ -and 'host' -in $_ -and 'PGPASSWORD' -notin $_ -and "PGPORT=$Port" -in $_ }) -eq 1) 'Expected one host DB runtime without a persistent password.'
    Assert-Test ((Calls { $_[0] -eq 'exec' -and 'PGPASSWORD' -in $_ -and '--non-interactive' -in $_ -and '--allow-tool-upgrade' -notin $_ }) -eq 1) 'Headless run must not authorize upgrades.'
    Assert-Test ((Calls { $_[0] -eq 'exec' -and 'AURORA_TOOL_SEARCH_PATH=/opt/company/java tools:/custom' -in $_ }) -eq 1) 'Explicit Linux search roots were not forwarded to the worker.'
    Assert-Test ((Calls { ($env:PGPASSWORD -in $_) -or ('postgres:16' -in $_) }) -eq 0) 'Host DB reuse leaked a credential or installed another server.'
    Assert-Test (-not (Get-ChildItem $Root -Filter 'secrets.json' -Recurse)) 'Windows DB password was saved on disk.'
    $scenario = 'existing'; $AllowToolUpgrade = $true; $script:calls.Clear()
    Invoke-DockerRuntime
    Assert-Test ((Calls { $_[0] -eq 'run' -or $_[0] -eq 'image' }) -eq 0) 'Existing compatible runtime was replaced or pulled.'
    Assert-Test ((Calls { $_[0] -eq 'start' -and $_[1] -eq $RuntimeContainerName }) -eq 1) 'Stopped existing runtime should be resumed.'
    Assert-Test ((Calls { $_[0] -eq 'exec' -and '--allow-tool-upgrade' -in $_ }) -eq 1) 'Explicit upgrade decision was lost.'
    $scenario = 'unreachable'; $script:calls.Clear()
    try { Invoke-DockerRuntime; throw 'Expected preflight failure' } catch { if ($_ -notmatch 'Cannot reach the selected Windows database') { throw } }
    Assert-Test ((Calls { $_[0] -eq 'run' -and '-d' -in $_ }) -eq 0) 'Persistent resources created on failed network preflight.'
    $DockerUseHostPostgres = $false; $scenario = 'new'; $script:calls.Clear()
    try { Invoke-DockerRuntime; throw 'Expected duplicate DB safeguard' } catch { if ($_ -notmatch 'ClinicalDB') { throw } }
    Assert-Test ((Calls { $_[0] -eq 'run' -or $_[0] -eq 'image' }) -eq 0) 'Detected server should suppress a second database installation.'
    $scenario = 'managed-existing'; $Database = 'rxnorm_public'; $DbUser = 'rxnorm_lab'; $Port = 55433
    $script:calls.Clear()
    Invoke-DockerRuntime
    Assert-Test ((Calls { $_[0] -eq 'run' -and $ContainerName -in $_ }) -eq 0) 'Compatible PostgreSQL 17 container must not be replaced.'
    Assert-Test ((Calls { $_[0] -eq 'run' -and 'container:existing-id' -in $_ }) -eq 1) 'Runtime must share the selected database namespace.'
    Assert-Test ((Calls { $_[0] -eq 'exec' -and 'psql' -in $_ }) -eq 1) 'Authenticate and check the managed server version in one query.'
    $scenario = 'new'; $DockerUseManagedPostgres = $true; $script:calls.Clear()
    Invoke-DockerRuntime
    Assert-Test ((Calls { $_[0] -eq 'run' -and 'postgres:16' -in $_ }) -eq 1) 'Explicit separate database should create exactly one managed DB.'
    $scenario = 'local-image'; $script:calls.Clear()
    Invoke-DockerRuntime
    Assert-Test ((Calls { $_[0] -eq 'run' -and 'postgres:18.1' -in $_ -and "${VolumeName}:/var/lib/postgresql" -in $_ }) -eq 1) 'Cached compatible official image should use its declared volume layout.'
    Assert-Test ((Calls { $_[0] -eq 'pull' -or 'postgres:16' -in $_ }) -eq 0) 'Compatible PG image must avoid new downloads.'
    $scenario = 'old-image'; $AllowToolUpgrade = $false; $script:calls.Clear()
    try { Invoke-DockerRuntime; throw 'Expected cached old-image upgrade consent' } catch { if ($_ -notmatch 'approve the image change') { throw } }
    Assert-Test ((Calls { $_[0] -eq 'pull' -or $_[0] -eq 'run' }) -eq 0) 'Older cached image must require consent before an alternative is pulled/started.'
    $secretPath = Join-Path $Root 'secrets.json'
    Save-DockerCredentials $secretPath @{password='generated';port=$Port}
    # A legacy port-less record acquires its port through atomic replacement.
    Save-Json $secretPath @{password='generated'}
    Save-DockerCredentials $secretPath @{password='generated';port=$Port}
    Assert-Test ((Get-Content $secretPath -Raw | ConvertFrom-Json).port -eq $Port) 'Legacy metadata must gain its selected port.'
    [IO.File]::SetLastWriteTimeUtc($secretPath, [datetime]'2020-01-01Z')
    Save-DockerCredentials $secretPath @{password='generated';port=$Port}
    Assert-Test ((Get-Item $secretPath).LastWriteTimeUtc.Year -eq 2020) 'Unchanged credentials must not be rewritten.'
    'PASS Docker database reuse, isolation, consent forwarding, worker encoding and credential persistence.'
} finally {
    $env:PGPASSWORD = $oldPassword; $env:POSTGRES_PASSWORD = $oldPostgresPassword
    Remove-Item -LiteralPath $Root -Recurse -Force
}
