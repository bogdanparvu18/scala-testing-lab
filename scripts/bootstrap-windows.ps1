# setup options
param(
    [string]$Root = (Get-Location).Path,
    [int]$Port = 55433,
    [string]$ContainerName = 'aurora-medication-auto-pg',
    [string]$VolumeName = 'aurora-medication-auto-pgdata',
    [switch]$NoEditor,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$Utf8 = New-Object Text.UTF8Encoding($false)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# stop if a command fails
function Run([scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "Command failed (exit $LASTEXITCODE)." }
}
# save json without a bom
function Save-Json($Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 8), $Utf8)
}
if ($Help) {
    Write-Host 'Usage: .\bootstrap-windows.ps1 [-Root directory] [-Port 55433] [-ContainerName name] [-VolumeName name] [-NoEditor]'
    Write-Host 'The current folder is the default destination. Install Git, Java 21 (JAVA_HOME), Node 22.12+, Docker Desktop with Linux containers, and VS Code first.'
    exit
}
# check the installed tools
$Root = [IO.Path]::GetFullPath($Root)
Write-Host "Setup folder: $Root"
foreach ($tool in @('git.exe', 'node.exe', 'npm.cmd', 'docker.exe')) { Get-Command $tool | Out-Null }
if (-not $NoEditor) { Get-Command code.cmd | Out-Null }
if (-not $env:JAVA_HOME) { throw 'Set JAVA_HOME to your Java 21 installation.' }
$JavaHome = $env:JAVA_HOME
$Java = Join-Path $JavaHome 'bin\java.exe'
if (-not (Test-Path $Java) -or (Get-Content "$JavaHome\release" -Raw) -notmatch 'JAVA_VERSION="21\.') { throw 'JAVA_HOME must point to Java 21.' }
$NodeHome = Split-Path (Get-Command node.exe).Source -Parent
$env:PATH = "$JavaHome\bin;$NodeHome;$env:PATH"
$nodeVersion = Run { node.exe --version }
if ([version]$nodeVersion.TrimStart('v') -lt [version]'22.12.0') { throw 'Install Node 22.12 or newer.' }
$dockerType = Run { docker.exe info --format '{{.OSType}}' }
if ($dockerType -ne 'linux') { throw 'Start Docker Desktop with Linux containers.' }

# keep setup files together
$Automatic = Join-Path $Root 'medication-lab-setup\automatic'
$State = Join-Path $Automatic 'state'
$Tools = Join-Path $Automatic 'tools'
$Downloads = Join-Path $Automatic 'downloads'
$Data = Join-Path $Automatic 'data\2026-10-05'
$Profile = Join-Path $Automatic 'editor-profile'
foreach ($directory in @($Root, $State, "$Tools\sbt\bin", $Downloads, "$Data\rrf", "$Profile\User")) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
# save the password in a private folder
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
Run { icacls.exe $State '/inheritance:r' '/grant:r' "${identity}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' } | Out-Null
$secretsFile = Join-Path $State 'secrets.json'
if (-not (Test-Path $secretsFile)) { Save-Json $secretsFile @{ password = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'); port = $Port } }
$secrets = Get-Content $secretsFile -Raw | ConvertFrom-Json
if (($secrets.port -and $secrets.port -ne $Port) -or -not $secrets.password) { throw 'Use this setup with its original Root and Port.' }
$env:PGHOST = '127.0.0.1'
$env:PGPORT = [string]$Port
$env:PGDATABASE = 'rxnorm_public'
$env:PGUSER = 'rxnorm_lab'
$env:PGPASSWORD = $secrets.password
$env:POSTGRES_PASSWORD = $secrets.password

# clone the demo repos if missing
foreach ($repo in @(
    @{ name = 'scala-testing-lab'; commit = '6d5f13851c4cccd90273d3a2e25688e2ba15028b' },
    @{ name = 'langium_dsl_lab'; commit = 'd7f75fee45838345c5b902c8f22bf8cd87bfd224' }
)) {
    $directory = Join-Path $Root $repo.name
    if (-not (Test-Path $directory)) {
        Run { git.exe clone "https://github.com/bogdanparvu18/$($repo.name).git" $directory }
        Run { git.exe -C $directory checkout --detach $repo.commit }
    }
    $head = Run { git.exe -C $directory rev-parse HEAD }
    if ($head -ne $repo.commit) { throw "$directory uses another revision. Choose a new Root to preserve that checkout." }
}
$Scala = Join-Path $Root 'scala-testing-lab'
$Langium = Join-Path $Root 'langium_dsl_lab\clinical-dsl-demo'
# get the scala launcher
$Launcher = Join-Path $Tools 'sbt\bin\sbt-launch.jar'
if (-not (Test-Path $Launcher)) { Invoke-WebRequest -UseBasicParsing 'https://repo.maven.apache.org/maven2/org/scala-sbt/sbt-launch/1.10.2/sbt-launch-1.10.2.jar' -OutFile $Launcher }
if ((Get-FileHash $Launcher).Hash -ne 'cdd6963b622f42690cb2e3154bde3f3257a03839f216e1b5d7420000d6a71817') { throw 'sbt launcher checksum failed.' }
Save-Json "$Tools\layout.json" @{ javaHome = $JavaHome; nodeHome = $NodeHome; sbtHome = "$Tools\sbt" }
# reuse the dependencies and build
Set-Location $Langium
$installedLock = 'node_modules\.package-lock.json'
$install = -not (Test-Path $installedLock) -or (Get-Item package-lock.json).LastWriteTime -gt (Get-Item $installedLock -ErrorAction SilentlyContinue).LastWriteTime
if ($install) { Run { npm.cmd ci } }
$output = 'packages\extension\out\extension\main.cjs'
$build = $install -or -not (Test-Path $output) -or -not (Test-Path 'packages\language\out\index.js') -or -not (Test-Path 'packages\extension\syntaxes\clinical-dsl.tmLanguage.json')
if (-not $build) { $build = (Get-Item package-lock.json).LastWriteTime -gt (Get-Item $output).LastWriteTime }
if ($build) {
    Run { npm.cmd run langium:generate }
    Run { npm.cmd run build }
}

# create or start the database container
$containers = @(Run { docker.exe ps -a --format '{{.Names}}' })
if ($ContainerName -in $containers) {
    $container = @(Run { docker.exe inspect $ContainerName } | ConvertFrom-Json)[0]
    $binding = @($container.HostConfig.PortBindings.'5432/tcp')
    if ($binding.Count -ne 1 -or $binding[0].HostPort -ne [string]$Port -or $binding[0].HostIp -ne '127.0.0.1' -or
        "POSTGRES_PASSWORD=$($secrets.password)" -notin $container.Config.Env -or 'POSTGRES_USER=rxnorm_lab' -notin $container.Config.Env -or 'POSTGRES_DB=rxnorm_public' -notin $container.Config.Env -or
        $VolumeName -notin @($container.Mounts | Where-Object Destination -eq '/var/lib/postgresql/data' | ForEach-Object Name)) { throw 'Existing container does not match this setup.' }
    if (-not $container.State.Running) { Run { docker.exe start $ContainerName } }
} else {
    $volumes = @(Run { docker.exe volume ls --format '{{.Name}}' })
    if ($VolumeName -in $volumes) { throw 'This volume already exists without its matching container. Choose another VolumeName; existing data was preserved.' }
    Run { docker.exe run -d --name $ContainerName -e POSTGRES_USER=rxnorm_lab -e POSTGRES_DB=rxnorm_public -e POSTGRES_PASSWORD -p "127.0.0.1:${Port}:5432" -v "${VolumeName}:/var/lib/postgresql/data" postgres:16 }
}
# wait for postgres
for ($attempt = 0; $attempt -lt 60; $attempt++) {
    docker.exe exec $ContainerName pg_isready -U rxnorm_lab -d rxnorm_public | Out-Null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 1
}
if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL did not become ready. Check docker logs.' }
Run { docker.exe exec -e PGPASSWORD $ContainerName psql -h 127.0.0.1 -U rxnorm_lab -d rxnorm_public -v ON_ERROR_STOP=1 -c 'SELECT 1;' } | Out-Null
# skip the import if this data is ready
$query = @"
SELECT 1 FROM rxnorm_lab.release r JOIN rxnorm_lab.product_release p USING (release)
WHERE r.release='2026-10-05' AND r.state='ready' AND p.state='ready' AND p.base_identity=r.identity
AND r.scope='all-active-rxnorm-pg-v4' AND p.policy='single-component-mass-v1'
AND r.sha256_json::jsonb->>'RXNCONSO.RRF'='555730c3ff2a981796dc5d649acc482e4685f7a31f7b0442941393ae50dd5209'
AND r.sha256_json::jsonb->>'RXNREL.RRF'='cca47f32a2c32ef60d65c6789851385ff5dcf287750ca01a53f800a5cf5ef694'
AND p.sha256_json::jsonb->>'RXNSAT.RRF'='b5a476f2bfbef9082144fd2bf00eb0de46f7b0b63da822d856067b9935914dda';
"@
try { $ready = docker.exe exec $ContainerName psql -U rxnorm_lab -d rxnorm_public -Atc $query 2>$null; if ($LASTEXITCODE -ne 0) { $ready = '' } } catch { $ready = '' }
if ($ready -ne '1') {
    # download and import the rxnorm files
    $Zip = Join-Path $Downloads 'RxNorm_full_prescribe_10052026.zip'
    if (-not (Test-Path $Zip)) { Invoke-WebRequest -UseBasicParsing 'https://download.nlm.nih.gov/rxnorm/RxNorm_full_prescribe_10052026.zip' -OutFile $Zip }
    if ((Get-FileHash $Zip).Hash -ne '8ed351c29f3cb56bedeb8e2bcb8fa56931f8d7eb88e2280dc9772d7d3eb16977') { throw 'RxNorm download checksum failed.' }
    Expand-Archive -LiteralPath $Zip -DestinationPath $Data -Force
    Set-Location $Scala
    $rrf = '../medication-lab-setup/automatic/data/2026-10-05/rrf'
    Run { & $Java -Xmx2G '-Dsbt.supershell=false' '-Dsbt.log.noformat=true' -jar $Launcher "run import-rxnorm $rrf 2026-10-05" }
    Run { & $Java -Xmx2G '-Dsbt.supershell=false' '-Dsbt.log.noformat=true' -jar $Launcher "run import-product-attributes $rrf 2026-10-05" }
    Run { docker.exe exec $ContainerName psql -U rxnorm_lab -d rxnorm_public -v ON_ERROR_STOP=1 -c 'ANALYZE;' }
} else { Write-Host 'RxNorm is already imported.' }

# leave an existing demo file alone
$Demo = Join-Path $Automatic 'aspirin-demo.clinical'
if (-not (Test-Path $Demo)) { [IO.File]::WriteAllText($Demo, "Patient P9999: age 30, condition Fever`nMedication aspirin: 100 mg, strength 325 mg, doseForm Oral Tablet, route PO, frequency PRN`nPlan DemoPlan: for P9999, prescribe aspirin`nshow DemoPlan`n", $Utf8) }
# turn on auto-save and database checks
$settings = @{}
$settingsFile = Join-Path $Profile 'User\settings.json'
if (Test-Path $settingsFile) { (Get-Content $settingsFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $settings[$_.Name] = $_.Value } }
$requiredSettings = @{
    'clinicalDsl.rxnorm.scalaRoot' = $Scala; 'clinicalDsl.rxnorm.toolsRoot' = $Tools
    'clinicalDsl.rxnorm.release' = '2026-10-05'; 'clinicalDsl.rxnorm.onSave' = $true
    'files.autoSave' = 'afterDelay'; 'files.autoSaveDelay' = 1000
    'clinicalDsl.rxnorm.pgHost' = '127.0.0.1'; 'clinicalDsl.rxnorm.pgPort' = $Port
    'clinicalDsl.rxnorm.pgDatabase' = 'rxnorm_public'; 'clinicalDsl.rxnorm.pgUser' = 'rxnorm_lab'
    'clinicalDsl.rxnorm.timeoutSeconds' = 300
}
foreach ($key in $requiredSettings.Keys) { $settings[$key] = $requiredSettings[$key] }
Save-Json $settingsFile $settings
# open the demo in the editor
if (-not $NoEditor) { Run { code.cmd --new-window --user-data-dir $Profile "--extensionDevelopmentPath=$Langium\packages\extension" $Langium $Demo } }
Write-Host "Ready: $Demo"
Write-Host 'Change strength 325 mg to strength 32500 mg and pause to see PRODUCT_NOT_FOUND.'
