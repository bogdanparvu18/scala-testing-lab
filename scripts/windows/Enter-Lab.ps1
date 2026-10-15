# Dot-source this file: . .\scripts\windows\Enter-Lab.ps1
#Requires -Version 5.1
param(
    [string]$ToolsRoot = (Join-Path $env:USERPROFILE 'AuroraLab\tools'),
    [string]$PGHome = 'C:\Program Files\PostgreSQL\17'
)
$labLayoutFile = Join-Path $ToolsRoot 'layout.json'
if (-not (Test-Path -LiteralPath $labLayoutFile)) { throw 'Run Install-LabTools.ps1 first, or provide the matching -ToolsRoot.' }
$labLayout = Get-Content -LiteralPath $labLayoutFile -Raw | ConvertFrom-Json
foreach ($labPath in @($labLayout.javaHome, $labLayout.nodeHome, $labLayout.sbtHome)) {
    if (-not (Test-Path -LiteralPath $labPath)) { throw "Missing tool directory: $labPath" }
}
$env:JAVA_HOME = $labLayout.javaHome
$labBins = @((Join-Path $labLayout.javaHome 'bin'), $labLayout.nodeHome, (Join-Path $labLayout.sbtHome 'bin'))
$labPgBin = Join-Path $PGHome 'bin'
if (Test-Path -LiteralPath (Join-Path $labPgBin 'psql.exe')) {
    $labBins += $labPgBin
} else {
    Write-Host 'PostgreSQL client not found at PGHome. Install PostgreSQL 17 or pass -PGHome before database setup.'
}
$labPathEntries = @($env:Path -split ';' | Where-Object { $_ -and ($_ -notin $labBins) })
$env:Path = ($labBins + $labPathEntries) -join ';'
$env:PGHOST = '127.0.0.1'
$env:PGPORT = '5432'
$env:PGDATABASE = 'scala_testing_lab'
$env:PGUSER = 'scala_lab'
$env:PGCLIENTENCODING = 'UTF8'
Write-Host 'Lab tools and local PostgreSQL settings active in this process. Passwords are not persisted.'
