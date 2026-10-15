#Requires -Version 5.1
# Import a user-downloaded FULL RxNorm ZIP into the local PostgreSQL index.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$Release,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSha256,
    [ValidateRange(512, 32768)][int]$SbtMaxHeapMB = 2048,
    [string]$DataRoot = (Join-Path $env:USERPROFILE 'AuroraLab\data\rxnorm'),
    [string]$ToolsRoot = (Join-Path $env:USERPROFILE 'AuroraLab\tools')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$parsedRelease = [datetime]::MinValue
if (-not [datetime]::TryParseExact($Release, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$parsedRelease)) {
    throw 'Release must be the archive release date in ISO format yyyy-MM-dd.'
}
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$archive = (Resolve-Path -LiteralPath $ArchivePath).Path
if ([IO.Path]::GetExtension($archive) -ne '.zip') { throw 'ArchivePath must identify a ZIP archive.' }
if ([IO.Path]::GetFileName($archive) -match '(?i)prescribe') {
    throw 'This helper expects the FULL release; Current Prescribable Content does not cover all source names.'
}
$DataRoot = [IO.Path]::GetFullPath($DataRoot)
if ($DataRoot.TrimEnd('\','/').Equals($projectRoot.TrimEnd('\','/'), [StringComparison]::OrdinalIgnoreCase) -or
        $DataRoot.StartsWith($projectRoot.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Choose DataRoot outside the Git repository.'
}
foreach ($checkedPath in @($projectRoot, $DataRoot, $archive)) {
    if ($checkedPath -match '[;"\r\n]') { throw 'Paths containing quotes, semicolons or line breaks are not supported by the sbt command parser.' }
}
$layoutPath = Join-Path $ToolsRoot 'layout.json'
if (-not (Test-Path -LiteralPath $layoutPath)) { throw 'Run Install-LabTools.ps1 first, or provide its matching -ToolsRoot.' }
$layout = Get-Content -LiteralPath $layoutPath -Raw | ConvertFrom-Json
$javaExecutable = Join-Path $layout.javaHome 'bin\java.exe'
$sbtLauncher = Join-Path $layout.sbtHome 'bin\sbt-launch.jar'
foreach ($toolFile in @($javaExecutable, $sbtLauncher)) {
    if (-not (Test-Path -LiteralPath $toolFile)) { throw "Missing installed tool: $toolFile" }
}
foreach ($environmentName in @('PGHOST', 'PGPORT', 'PGDATABASE', 'PGUSER', 'PGPASSWORD')) {
    if (-not [Environment]::GetEnvironmentVariable($environmentName, 'Process')) {
        throw "Missing $environmentName. Run Enter-Lab.ps1 and Read-PostgresPassword.ps1 in this terminal."
    }
}
$archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ExpectedSha256 -and $archiveHash -ne $ExpectedSha256.ToLowerInvariant()) {
    throw 'Archive SHA-256 mismatch. Nothing has been extracted or imported.'
}
Write-Host "Archive SHA-256: $archiveHash"
$required = @('RXNCONSO.RRF', 'RXNREL.RRF')
$releaseRoot = Join-Path $DataRoot $Release
$rrfRoot = Join-Path $releaseRoot 'rrf'
$manifestPath = Join-Path $releaseRoot 'extraction-manifest.json'
if (Test-Path -LiteralPath $releaseRoot) {
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Existing release directory has no helper manifest: $releaseRoot. Inspect it or select a fresh DataRoot; no files were overwritten."
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.release -ne $Release -or $manifest.archiveSha256 -ne $archiveHash) {
        throw 'Existing extracted release belongs to different input. No files were overwritten.'
    }
    foreach ($fileName in $required) {
        $record = @($manifest.files | Where-Object { $_.name -eq $fileName })
        $filePath = Join-Path $rrfRoot $fileName
        if ($record.Count -ne 1 -or -not (Test-Path -LiteralPath $filePath)) {
            throw "Extracted source is incomplete: $fileName. Inspect the directory before retrying."
        }
        if ((Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $record[0].sha256) {
            throw "Extracted source changed: $fileName. No existing files were overwritten."
        }
    }
    Write-Host 'Existing extraction verified; retrying/rechecking the local import.'
} else {
    New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
    $staging = Join-Path $DataRoot ('.extract-' + [Guid]::NewGuid().ToString('N'))
    $stagingRrf = Join-Path $staging 'rrf'
    New-Item -ItemType Directory -Path $stagingRrf | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = $null
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        $sourceRrfPrefix = $null
        foreach ($fileName in $required) {
            $pattern = '(?i)(^|/)rrf/' + [regex]::Escape($fileName) + '$'
            $entries = @($zip.Entries | Where-Object {
                $entryPath = $_.FullName.Replace('\','/')
                ($entryPath -match $pattern) -and ($entryPath -notmatch '(?i)(^|/)prescribe(/|$)')
            })
            if ($entries.Count -ne 1) { throw "Expected one unique FULL rrf/$fileName entry outside prescribe/; found $($entries.Count)." }
            $entryPath = $entries[0].FullName.Replace('\','/')
            $entryPrefix = $entryPath.Substring(0, $entryPath.LastIndexOf('/') + 1)
            if ($null -eq $sourceRrfPrefix) { $sourceRrfPrefix = $entryPrefix }
            elseif (-not $sourceRrfPrefix.Equals($entryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Required RRF files come from different ZIP directories; refusing to mix them.'
            }
            if ($entries[0].Length -le 0) { throw "Required RRF file is empty: $fileName" }
            # Never use a ZIP-controlled path as the output path (prevents ZIP traversal).
            $destination = Join-Path $stagingRrf $fileName
            $inputStream = $null
            $outputStream = $null
            try {
                $inputStream = $entries[0].Open()
                $outputStream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
                $inputStream.CopyTo($outputStream)
            } finally {
                if ($null -ne $outputStream) { $outputStream.Dispose() }
                if ($null -ne $inputStream) { $inputStream.Dispose() }
            }
        }
        $zip.Dispose()
        $zip = $null
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $archiveHash) {
            throw 'Archive changed during extraction.'
        }
        $fileRecords = @(foreach ($fileName in $required) {
            $filePath = Join-Path $stagingRrf $fileName
            @{ name = $fileName; sha256 = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant(); bytes = (Get-Item -LiteralPath $filePath).Length }
        })
        $manifest = [ordered]@{ release = $Release; archiveSha256 = $archiveHash; distributionDeclaredByUser = 'FULL'; sourceRrfPrefix = $sourceRrfPrefix; files = $fileRecords }
        [IO.File]::WriteAllText((Join-Path $staging 'extraction-manifest.json'), ($manifest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $staging -Destination $releaseRoot
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
}

function ConvertTo-WindowsArgument([string]$Value) {
    # Quote one CreateProcess argument, including embedded quotes and trailing slashes.
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (2 * $slashes + 1)))
            [void]$builder.Append('"')
        } else {
            [void]$builder.Append(('\' * $slashes))
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    [void]$builder.Append(('\' * (2 * $slashes)))
    [void]$builder.Append('"')
    return $builder.ToString()
}
$sbtCommand = 'run import-rxnorm "{0}" {1}' -f $rrfRoot.Replace('\','/'), $Release
$launchArguments = @(("-Xmx{0}m" -f $SbtMaxHeapMB), '-Dsbt.supershell=false', '-Dsbt.log.noformat=true', '-jar', $sbtLauncher, $sbtCommand)
$processInfo = New-Object Diagnostics.ProcessStartInfo
$processInfo.FileName = $javaExecutable
$processInfo.Arguments = ($launchArguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
$processInfo.WorkingDirectory = $projectRoot
$processInfo.UseShellExecute = $false
$processInfo.EnvironmentVariables['JAVA_HOME'] = $layout.javaHome
Write-Host "Importing local files from $rrfRoot into the configured PostgreSQL instance."
$process = [Diagnostics.Process]::Start($processInfo)
try {
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "sbt import failed (exit $($process.ExitCode)). Verified source files are preserved. Rerun the same command after fixing the cause."
    }
} finally {
    $process.Dispose()
}
Write-Host 'Import command completed. Check its committed release/count verification output before resolving medication names.'
