# Invoke with Windows PowerShell 5.1 or PowerShell 7. No package manager or database required.
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'bootstrap-windows.ps1'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$errors)
if ($errors.Count) { throw $errors[0] }
foreach ($name in @('Test-ArtifactHash', 'Publish-VerifiedArtifact', 'Get-VerifiedDownload', 'Ensure-LocalPostgres', 'Open-LabDatabase', 'Assert-ServerVersion', 'Initialize-LabDatabase')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Check($Condition, $Message) { if (-not $Condition) { throw $Message } }
function MustFail($Command, $Expected) {
    try { & $Command } catch { if ($_.Exception.Message -like "*$Expected*") { return }; throw }
    throw "Expected failure: $Expected"
}
$dir = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N')))
$previousPassword = $env:PGPASSWORD
try {
    $cached = Join-Path $dir 'download.zip'
    $sample = Join-Path $dir 'sample'
    [IO.File]::WriteAllText($sample, 'verified')
    $digest = (Get-FileHash $sample).Hash
    $script:webCalls = 0
    function Invoke-WebRequest($Uri, $OutFile, [switch]$UseBasicParsing) {
        $script:webCalls++
        [IO.File]::WriteAllText($OutFile, $payload)
        if ($simulateInterruption) { throw 'connection interrupted' }
    }
    $payload = 'partial'; $simulateInterruption = $true
    MustFail { Get-VerifiedDownload 'https://fixture.invalid' $cached $digest } 'connection interrupted'
    Check (-not (Test-Path $cached)) 'An interrupted download published a partial file'
    Check (@(Get-ChildItem $dir -Filter '*.part').Count -eq 0) 'Temporary download remained after failure'
    [IO.File]::WriteAllText($cached, 'legacy partial file')
    $simulateInterruption = $false
    MustFail { Get-VerifiedDownload 'https://fixture.invalid' $cached $digest } 'SHA-256'
    Check ([IO.File]::ReadAllText($cached) -eq 'legacy partial file') 'Invalid bytes replaced the existing file'
    $payload = 'verified'
    Get-VerifiedDownload 'https://fixture.invalid' $cached $digest
    Get-VerifiedDownload 'https://fixture.invalid' $cached $digest
    Check ((Get-FileHash $cached).Hash -eq $digest -and $webCalls -eq 3) 'Retry or cache reuse failed'

    $PgHost = '127.0.0.1'; $Port = 5432; $PgAdminUser = 'postgres'; $DbUser = 'lab'; $Database = 'labdb'
    $PsqlPath = Join-Path $dir 'psql.exe'; $PgServiceName = $null
    function Test-PostgresReady { $false }
    function Get-PostgresServiceCandidates($PsqlPath) { $candidates }
    function Get-Service { [pscustomobject]@{ Name='ClinicalDB'; Status='Running' } }
    function Wait-Postgres { $script:waited++ }
    $script:waited = 0; $candidates = @('ClinicalDB')
    Ensure-LocalPostgres
    Check ($waited -eq 1) 'Custom PostgreSQL service was not selected'
    $candidates = @('ClinicalDB','SecondCluster')
    MustFail { Ensure-LocalPostgres } '2 services'

    $env:PGPASSWORD = 'application-test-secret'
    function Confirm-ToolUpgrade($component, $detail) { $false }
    function Test-BootstrapInteractive { $true }
    function Read-Host { ConvertTo-SecureString 'admin-test-secret' -AsPlainText -Force }
    function Invoke-DatabaseSql($Sql, $Login, $DbName) {
        if ($Login -eq $PgAdminUser -and $env:PGPASSWORD -ne 'admin-test-secret') { throw 'admin credentials missing' }
        if ($Login -eq $DbUser -and $env:PGPASSWORD -ne 'application-test-secret') { throw 'application credentials missing' }
        if ($Sql -eq 'SHOW server_version_num;') {
            if ($Login -eq $PgAdminUser) { return '160002' }
            if ($appLoginError) { throw 'initial authentication failed' }
            return $appVersion
        }
        if ($Sql -match 'pg_roles') { return $roleExists }
        if ($Sql -match 'pg_database') { return $dbExists }
        if ($Sql -eq 'SELECT 1;') { if ($wrongPassword) { throw 'wrong application password' }; return '1' }
        if ($Sql -match '^CREATE DATABASE') { $script:created++; return }
        throw "Unexpected command: $Sql"
    }
    $roleExists = '1'; $dbExists = '1'; $script:created = 0
    MustFail { Initialize-LabDatabase } 'exists'
    Check ($env:PGPASSWORD -eq 'application-test-secret' -and $created -eq 0) 'Changed existing DB or leaked admin credentials'
    $dbExists = '0'; $wrongPassword = $true
    MustFail { Initialize-LabDatabase } 'wrong application password'
    Check ($created -eq 0) 'Created DB without verifying its intended owner'
    $wrongPassword = $false
    Initialize-LabDatabase
    Check ($created -eq 1) 'Expected creation of the authenticated role''s missing database'
    $appLoginError = $true; $ProvisionDatabase = $false; $candidates = @('ClinicalDB')
    MustFail { Open-LabDatabase } '-ProvisionDatabase'
    $appLoginError = $false; $appVersion = '140000'; $ProvisionDatabase = $true
    MustFail { Open-LabDatabase } 'PostgreSQL 15+'
    Check ($created -eq 1) 'Incompatible server triggered provisioning'
    Write-Host 'PASS: atomic cache publication, recovery, custom PostgreSQL service, consent and database ownership'
} finally {
    [Environment]::SetEnvironmentVariable('PGPASSWORD', $previousPassword, 'Process')
    Remove-Item -LiteralPath $dir -Force -Recurse
}
