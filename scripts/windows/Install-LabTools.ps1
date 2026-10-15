#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$JdkZip,
    [Parameter(Mandatory = $true)][string]$NodeZip,
    [string]$ToolsRoot = (Join-Path $env:USERPROFILE 'AuroraLab\tools'),
    [string]$SbtZip
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not [Environment]::Is64BitOperatingSystem) { throw 'This lab requires 64-bit Windows.' }
$ToolsRoot = [IO.Path]::GetFullPath($ToolsRoot)
New-Item -ItemType Directory -Force -Path $ToolsRoot | Out-Null
$downloadRoot = Join-Path $ToolsRoot 'downloads'
New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null

function Get-LabDownload([string]$Uri, [string]$Name) {
    $destination = Join-Path $downloadRoot $Name
    if (-not (Test-Path -LiteralPath $destination)) {
        $partial = "$destination.partial"
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $partial
        Move-Item -LiteralPath $partial -Destination $destination
    }
    return $destination
}

function Expand-LabTool([string]$Zip, [string]$DirectoryName, [string]$RequiredFile) {
    $target = Join-Path $ToolsRoot $DirectoryName
    if (Test-Path -LiteralPath (Join-Path $target $RequiredFile)) { return $target }
    if (Test-Path -LiteralPath $target) { throw "Incomplete directory: $target. Inspect it before retrying; it will not be overwritten." }
    $source = (Resolve-Path -LiteralPath $Zip).Path
    $staging = Join-Path $ToolsRoot ('.extract-' + [Guid]::NewGuid().ToString('N'))
    try {
        Expand-Archive -LiteralPath $source -DestinationPath $staging
        $candidates = @(Get-ChildItem -LiteralPath $staging -Directory | Where-Object {
            Test-Path -LiteralPath (Join-Path $_.FullName $RequiredFile)
        })
        if (Test-Path -LiteralPath (Join-Path $staging $RequiredFile)) {
            Move-Item -LiteralPath $staging -Destination $target
        } elseif ($candidates.Count -eq 1) {
            Move-Item -LiteralPath $candidates[0].FullName -Destination $target
        } else {
            throw "Expected exactly one tool folder containing $RequiredFile in $source."
        }
        return $target
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
}

if (-not $SbtZip) {
    $SbtZip = Get-LabDownload 'https://github.com/sbt/sbt/releases/download/v1.10.2/sbt-1.10.2.zip' 'sbt-1.10.2.zip'
}

$jdkDirectory = Expand-LabTool $JdkZip 'jdk-21' 'bin\java.exe'
$nodeDirectory = Expand-LabTool $NodeZip 'node-22' 'node.exe'
$sbtDirectory = Expand-LabTool $SbtZip 'sbt-1.10.2' 'bin\sbt.bat'
# java writes its version to stderr; cmd merges it without PowerShell 5.1 NativeCommandError.
$jdkExecutable = Join-Path $jdkDirectory 'bin\java.exe'
$javaVersion = (& cmd.exe /d /c ('""{0}" -version 2>&1"' -f $jdkExecutable)) -join "`n"
if ($LASTEXITCODE -ne 0 -or $javaVersion -notmatch 'version "21[.\"]') { throw "Expected JDK 21. Found: $javaVersion" }
$nodeVersion = (& (Join-Path $nodeDirectory 'node.exe') --version).Trim()
if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v22\.' -or [version]$nodeVersion.Substring(1) -lt [version]'22.12.0') {
    throw "Expected Node 22.x >=22.12.0. Found: $nodeVersion"
}
$layout = [ordered]@{
    javaHome = $jdkDirectory
    nodeHome = $nodeDirectory
    sbtHome = $sbtDirectory
}
[IO.File]::WriteAllText((Join-Path $ToolsRoot 'layout.json'), ($layout | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
Write-Host 'Tools unpacked. No machine/user PATH or existing Java installation was changed.'
Write-Host 'In EACH new PowerShell window run:'
Write-Host ('. .\scripts\windows\Enter-Lab.ps1 -ToolsRoot "{0}"' -f $ToolsRoot)
