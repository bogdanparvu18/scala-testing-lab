#Requires -Version 5.1
# Creates only the fixed personal-lab role/database on localhost. Never drops data.
[CmdletBinding()]
param([ValidateRange(1, 65535)][int]$Port = 5432)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$psqlCommand = Get-Command psql.exe -ErrorAction SilentlyContinue
if (-not $psqlCommand) { throw 'psql.exe is missing. Install PostgreSQL 17 and run Enter-Lab.ps1 with the correct -PGHome.' }
$psqlExecutable = $psqlCommand.Source
$adminArguments = @('-X', '-w', '-v', 'ON_ERROR_STOP=1', '-h', '127.0.0.1', '-p', "$Port", '-U', 'postgres', '-d', 'postgres')
$previousPassword = [Environment]::GetEnvironmentVariable('PGPASSWORD', 'Process')
$adminSecret = Read-Host 'Local PostgreSQL administrator password (postgres)' -AsSecureString
if ($adminSecret.Length -eq 0) { $adminSecret.Dispose(); throw 'An empty administrator password is not accepted.' }
$adminPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($adminSecret)
try {
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($adminPointer)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($adminPointer)
    $adminSecret.Dispose()
}

function Invoke-AdminQuery([string]$Sql) {
    $result = & $psqlExecutable @adminArguments -A -t -c $Sql
    if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL setup query failed. Inspect the error; no existing database is dropped or reset.' }
    return ($result -join "`n").Trim()
}
function Invoke-AdminCommand([string]$Command) {
    & $psqlExecutable @adminArguments -c $Command
    if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL setup command failed. Inspect existing state before continuing.' }
}

try {
    $serverVersion = Invoke-AdminQuery 'SHOW server_version;'
    Write-Host "Connected to local PostgreSQL $serverVersion on port $Port."
    $roleState = Invoke-AdminQuery "SELECT (rolcanlogin AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication AND NOT rolbypassrls)::text FROM pg_roles WHERE rolname = 'scala_lab';"
    if (-not $roleState) {
        Invoke-AdminCommand 'CREATE ROLE scala_lab LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;'
        Write-Host 'Set the NEW application password below (psql asks twice; input is hidden).'
        Invoke-AdminCommand '\password scala_lab'
    } elseif ($roleState -ne 'true') {
        throw 'Existing scala_lab does not have the expected restricted LOGIN attributes. Inspect it manually; no role attributes were changed.'
    } else {
        Write-Host 'Existing restricted scala_lab role preserved; its password was not changed.'
    }

    $databaseOwner = Invoke-AdminQuery "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'scala_testing_lab';"
    if (-not $databaseOwner) {
        Invoke-AdminCommand "CREATE DATABASE scala_testing_lab OWNER scala_lab ENCODING 'UTF8' TEMPLATE template0;"
    } elseif ($databaseOwner -ne 'scala_lab') {
        throw 'Existing scala_testing_lab has another owner. Inspect it manually; no ownership or data was changed.'
    } else {
        Write-Host 'Existing scala_testing_lab database preserved.'
    }
    Write-Host 'Database ready. Run Read-PostgresPassword.ps1 for the application password, then verify with psql.'
    Write-Host 'If the first run was interrupted after role creation, inspect the role and set its password manually with psql \password scala_lab.'
} finally {
    if ($null -eq $previousPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
    else { $env:PGPASSWORD = $previousPassword }
}
