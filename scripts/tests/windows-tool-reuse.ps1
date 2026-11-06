# Cross-platform regression fixtures for the Windows resolver. No registry or package changes.
$ErrorActionPreference = 'Stop'
$bootstrap = Join-Path $PSScriptRoot '../bootstrap-windows.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($bootstrap,[ref]$null,[ref]$null)
foreach ($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    if ($f.Name -ne 'Select-ToolCandidate') { Invoke-Expression $f.Extent.Text }
}
function Check($Condition, [string]$Label) {
    if (-not $Condition) { throw "FAILED: $Label" }
    Write-Host "PASS $Label"
}
$work = Join-Path ([IO.Path]::GetTempPath()) ("aurora-tools-" + [guid]::NewGuid())
$source = New-Item -Type Directory -Path (Join-Path $work 'portable JDK/bin') -Force
$javaPath = Join-Path $source.FullName 'java.exe'
$nodeBin = New-Item -Type Directory -Path (Join-Path $work 'node') -Force
$npmBin = New-Item -Type Directory -Path (Join-Path $work 'npm') -Force
$nodePath = Join-Path $nodeBin.FullName 'node.exe'; $npm = Join-Path $npmBin.FullName 'npm.cmd'
$pgBin = New-Item -Type Directory -Path (Join-Path $work 'Postgres/bin') -Force
$psql = Join-Path $pgBin.FullName 'psql.exe'
$ready = Join-Path $pgBin.FullName 'pg_isready.exe'
foreach ($path in @($javaPath,$nodePath,$npm,$psql,$ready)) { [IO.File]::WriteAllText($path,'fixture') }
$nodeVersion = '22.12.0'; $major = 11; $probeCount = 0; $NoEditor = $true
$OriginalPath = $env:PATH
$AdditionalSearchPath = @()
try {
    function Invoke-ToolVersion([string]$Executable,[string[]]$Arguments) {
        $script:probeCount++
        if ($Executable -eq $javaPath) {
            return @{ok=$true;text="    java.home = $(Split-Path $source.FullName -Parent)`nopenjdk version `"$major.0.4`""}
        }
        if ($Executable -eq $nodePath) { return @{ok=$true;text="v$nodeVersion"} }
        if ($Executable -eq $npm) { return @{ok=$true;text='10.9.4'} }
        if ($Executable -eq $psql) { return @{ok=$true;text='psql (PostgreSQL) 15.19'} }
        if ($Executable -eq $ready) { return @{ok=$true;text='pg_isready (PostgreSQL) 16.10'} }
        return @{ok=$false;text='fixture is not an executable'}
    }
    function Get-FixedDrivePortableRoots { return }
    Initialize-ToolDiscovery
    $choice = Test-ToolCandidate Java $javaPath
    Check ($choice.state -eq 'compatible' -and -not $choice.probeBuild -and $choice.javaHome -eq (Split-Path $source.FullName -Parent)) 'JDK 11 discovered with canonical JAVA_HOME'
    Check ($probeCount -eq 1) 'one JVM launch when the original path is canonical'
    $major = 25
    Check ((Test-ToolCandidate Java $javaPath).probeBuild) 'untested Java is nominated for the real build probe'
    $major = 8
    Check ((Test-ToolCandidate Java $javaPath).canUpgrade) 'old Java can request an upgrade'
    $major = 17
    $alias = Join-Path $work 'linked-search-root'
    if ($env:OS -eq 'Windows_NT') { New-Item -Type Junction -Path $alias -Target (Split-Path $source.FullName -Parent) | Out-Null }
    else { New-Item -Type SymbolicLink -Path $alias -Target (Split-Path $source.FullName -Parent) | Out-Null }
    $AdditionalSearchPath = @($alias)
    $script:ToolRoots.Clear(); $script:ToolRoots.Add($alias)
    Check (@((Get-ToolInventory).Java).Count -eq 1) 'a configured directory junction reveals the existing Java'
    $script:ToolSearchErrors.PostgreSQL.Add('simulated unrelated CIM failure')
    $script:ToolDefinitions.Java.hint = 'AURORA_FIXTURE_JAVA_UNUSED'
    $script:ToolVendorLoaded.Java = $true
    $script:ToolRecords.Java.Clear()
    $script:ToolRoots.Clear(); $script:ToolInventory = $null
    function Get-PathToolCandidates([string]$Executable) { return }
    $oldJava = $env:JAVA_HOME; $env:JAVA_HOME = $null
    try { Check ((Find-SystemTool Java).state -eq 'missing') 'PG-only access errors do not block a Java absence decision' }
    finally { $env:JAVA_HOME = $oldJava }
    $countBefore = $probeCount
    function Get-FixedDrivePortableRoots { $source.FullName }
    $script:ToolInventory = $null
    Check ((Find-SystemTool Java).state -eq 'inconclusive' -and $probeCount -eq $countBefore) 'portable executable requires selection and blocks a duplicate install without being executed'
    function Get-FixedDrivePortableRoots { return }
    $AdditionalSearchPath = @(Join-Path $work 'absent-root')
    $script:ToolRoots.Add($AdditionalSearchPath[0]); $script:ToolInventory = $null
    Check ((Find-SystemTool Git).state -eq 'inconclusive') 'unreadable requested scope blocks installation'
    $script:ToolSearchErrors.Shared.Clear(); $AdditionalSearchPath = @()
    $script:ToolRoots.Clear(); $script:ToolRoots.Add($npmBin.FullName); $script:ToolInventory = $null
    $choice = Test-ToolCandidate Node $nodePath
    Check ($choice.state -eq 'compatible' -and $choice.npm -eq $npm) 'finds npm outside the selected Node directory'
    $nodeVersion='23.2.0'
    Check ((Test-ToolCandidate Node $nodePath).canUpgrade) 'Node 23 excludes the locked engine set'
    $nodeVersion='24.1.0'
    Check ((Test-ToolCandidate Node $nodePath).state -eq 'compatible') 'Node 24 and independent npm qualify'
    Check ((Test-ToolCandidate PostgreSQL $psql).state -eq 'compatible') 'PG15 client and independent PG16 readiness tool qualify'
    $script:ToolVendorLoaded.Services=$true
    $script:ToolRecords.PostgreSQL.Add(@{service='ClinicalDB';location=(Split-Path $pgBin.FullName -Parent)})
    Check ((Get-PostgresServiceCandidates $psql) -eq 'ClinicalDB') 'preserves the custom service mapped to the selected binary'
    $explicitFinds = New-Object 'System.Collections.Generic.List[string]'
    function Find-SystemTool([string]$Name,[string]$ExplicitPath) {
        $explicitFinds.Add($ExplicitPath)
        if ($ExplicitPath) { return @{state='incompatible'; canUpgrade=$true} }
        return @{state='compatible';path=$javaPath;version='17.0.0'}
    }
    Check ((Resolve-SystemTool Java 'obsolete.exe').path -eq $javaPath -and $explicitFinds.Count -eq 2) 'explicit old Java recovers another installed JDK before asking to install'
    function Test-BootstrapInteractive { $false }
    Check (-not (Confirm-ToolUpgrade 'Java' 'test')) 'unattended execution defaults to no'
    $AllowToolUpgrade = $true
    Check (Confirm-ToolUpgrade 'Java' 'test') 'explicit upgrade flag grants consent'
    $AllowToolUpgrade = $false
    function Test-BootstrapInteractive { $true }
    function Read-Host { return '' }
    Check (-not (Confirm-ToolUpgrade 'Java' 'test')) 'pressing Enter declines'
    function Read-Host { return 'Da' }
    Check (Confirm-ToolUpgrade 'Java' 'test') 'interactive explicit approval'
} finally {
    $env:PATH = $OriginalPath
    if (Test-Path -LiteralPath $alias) { [IO.Directory]::Delete($alias) }
    Remove-Item -LiteralPath $work -Recurse -Force
}
