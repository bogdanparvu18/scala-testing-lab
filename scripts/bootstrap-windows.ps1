# setup options
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Root,
    [string]$ScalaRepoPath,
    [string]$LangiumRepoPath,
    [string]$SetupPath,
    [Alias('Docker')][switch]$UseDocker,
    [ValidateRange(1, 65535)][int]$Port = 5432,
    [string]$PgHost,
    [string]$Database,
    [string]$DbUser,
    [string]$PsqlPath,
    [string]$JavaPath,
    [string]$NodePath,
    [string]$NpmPath,
    [string]$SbtLauncherPath,
    [switch]$AllowToolUpgrade,
    [switch]$LocateToolsOnFixedDrives,
    [string]$GitPath,
    [string]$CodePath,
    [string]$DockerPath,
    [string[]]$AdditionalSearchPath = @(),
    [switch]$SessionOnlyEnvironment,
    [string]$RuntimeContainerName = 'aurora-medication-runtime',
    [string]$RuntimeVolumeName = 'aurora-medication-workspace',
    [string]$RuntimeCacheVolumeName = 'aurora-medication-caches',
    [string]$RuntimeImage = 'ubuntu:24.04',
    [switch]$DockerUseHostPostgres,
    [switch]$DockerUseManagedPostgres,
    [string[]]$DockerToolSearchPath = @(),
    [string]$PgServiceName,
    [switch]$ProvisionDatabase,
    [string]$PgAdminUser = 'postgres',
    [switch]$RecoverPostgresPassword,
    [string]$ContainerName = 'aurora-medication-auto-pg',
    [string]$VolumeName = 'aurora-medication-auto-pgdata',
    [string]$ScalaBranch = 'main',
    [string]$LangiumBranch = 'main',
    [switch]$NoEditor,
    [switch]$Help,
    [ValidateRange(30, 600)][int]$StartupTimeoutSeconds = 180,
    [Parameter(DontShow = $true)][ValidateRange(0, 2)][int]$RelaunchCount = 0,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArguments
)

# Windows PowerShell 5.1 initializes PSScriptRoot after binding parameters.
if (-not $PSBoundParameters.ContainsKey('Root')) {
    $Root = Join-Path $PSScriptRoot 'AuroraMedicationLab'
}

# PowerShell treats double-dash switches as literal positional arguments when
# called from an existing shell. Normalize the documented --Docker spelling;
# -Docker and the previous -UseDocker remain compatible parameter aliases.
foreach ($argument in $RemainingArguments) {
    if ($argument -ceq '--Docker') { $UseDocker = $true }
    else { throw "Unknown argument '$argument'. Use -Help for supported options." }
}

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$OriginalLocation = Get-Location
$EntryHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
$HealthFile = $null
# Do not leave a prompted password or connection overrides in the caller's shell.
$PreviousEnvironment = @{}
foreach ($name in @('PGHOST', 'PGPORT', 'PGDATABASE', 'PGUSER', 'PGPASSWORD', 'POSTGRES_PASSWORD', 'PGCONNECT_TIMEOUT', 'PGSSLMODE', 'PGHOSTADDR', 'PGSERVICE', 'AURORA_PG_ADMIN_PASSWORD')) {
    $PreviousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$Utf8 = New-Object Text.UTF8Encoding($false)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# stop if a command fails
function Run([scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "Command failed (exit $LASTEXITCODE)." }
}
# save json without a bom
function Save-Json($Path, $Value) {
    $json = $Value | ConvertTo-Json -Depth 8
    if ([IO.File]::Exists($Path) -and [IO.File]::ReadAllText($Path) -ceq $json) { return }
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temp, $json, $Utf8)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

# Discover once, then reuse verified executables. A failed search is never absence.
function Initialize-ToolDiscovery {
    $script:ToolInventory = $null
    $script:RejectedJava = @{}
    $script:PortableEvidence = @{}
    $script:ToolSearchErrors = @{}
    $script:ToolVendorLoaded = @{}
    $script:UninstallRecordsLoaded = $false
    $script:ToolRecords = @{}
    $script:ToolRoots = New-Object 'System.Collections.Generic.List[string]'
    $script:ToolDefinitions = @{
        Java = @{ executable = 'java.exe'; hint = 'JAVA_HOME'; relative = 'bin\java.exe'; registry = 'Java|JDK|OpenJDK|Temurin|Corretto|Zulu'; package = 'Microsoft.OpenJDK.21' }
        Node = @{ executable = 'node.exe'; hint = 'NODE_HOME'; relative = 'node.exe'; registry = 'Node[.]?js|Node.js'; package = 'OpenJS.NodeJS.LTS' }
        Sbt = @{ executable = 'sbt.bat'; registry = '^sbt(?: |$)|Scala Build Tool' }
        Git = @{ executable = 'git.exe'; hint = 'GIT_HOME'; relative = 'cmd\git.exe'; registry = '^Git( |$)|Git for Windows'; package = 'Git.Git' }
        PostgreSQL = @{ executable = 'psql.exe'; hint = 'PGHOME'; relative = 'bin\psql.exe'; registry = 'PostgreSQL'; package = 'PostgreSQL.PostgreSQL.18' }
        Code = @{ executable = 'code.cmd'; hint = 'VSCODE_HOME'; relative = 'bin\code.cmd'; registry = 'Visual Studio Code'; package = 'Microsoft.VisualStudioCode' }
        Docker = @{ executable = 'docker.exe'; hint = 'DOCKER_HOME'; relative = 'resources\bin\docker.exe'; registry = 'Docker Desktop'; package = 'Docker.DockerDesktop' }
    }
    if ($UseDocker) {
        foreach ($name in @('Java', 'Node', 'Git', 'Sbt')) { $script:ToolDefinitions.Remove($name) }
        if (-not $RecoverPostgresPassword) { $script:ToolDefinitions.Remove('PostgreSQL') }
    } else { $script:ToolDefinitions.Remove('Docker') }
    if ($NoEditor) { $script:ToolDefinitions.Remove('Code') }
    foreach ($name in $script:ToolDefinitions.Keys) {
        $script:ToolSearchErrors[$name] = New-Object 'System.Collections.Generic.List[string]'
        $script:ToolRecords[$name] = New-Object 'System.Collections.Generic.List[object]'
    }
    $script:ToolSearchErrors['Shared'] = New-Object 'System.Collections.Generic.List[string]'
    foreach ($directory in @($AdditionalSearchPath) + @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432,
            "$env:LOCALAPPDATA\Programs", "$env:LOCALAPPDATA\Microsoft\WinGet\Packages",
            "$env:LOCALAPPDATA\nvm", "$env:APPDATA\nvm", "$env:LOCALAPPDATA\fnm_multishells",
            "$env:APPDATA\fnm", "$env:LOCALAPPDATA\Volta\tools", "$env:USERPROFILE\.jdks",
            "$env:USERPROFILE\scoop\apps", "$env:USERPROFILE\.sdkman\candidates",
            "$env:ProgramData\scoop\apps", "$env:ProgramData\chocolatey\lib", $env:ChocolateyInstall,
            $env:SCOOP, $env:SCOOP_GLOBAL, $env:NVM_HOME, $env:NVM_SYMLINK, $env:FNM_DIR, $env:VOLTA_HOME,
            $env:JDK_HOME, $env:SBT_HOME)) {
        if ($directory -and -not $script:ToolRoots.Contains($directory)) { $script:ToolRoots.Add($directory) }
    }
}
function Read-ToolRegistrations([string]$Name) {
    if ($script:ToolVendorLoaded[$Name]) { return }
    $script:ToolVendorLoaded[$Name] = $true
    if (-not $script:UninstallRecordsLoaded) {
        $script:UninstallRecordsLoaded = $true
        # Do not use Win32_Product: it can trigger MSI repair operations.
        foreach ($registryRoot in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
            try {
                if (-not (Test-Path -LiteralPath $registryRoot -ErrorAction Stop)) { continue }
                foreach ($key in Get-ChildItem -LiteralPath $registryRoot -ErrorAction Stop) {
                    $record = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                    foreach ($kind in $script:ToolDefinitions.Keys) {
                        if ([string]$record.DisplayName -match $script:ToolDefinitions[$kind].registry) {
                            $script:ToolRecords[$kind].Add(@{ description = [string]$record.DisplayName; location = [string]$record.InstallLocation })
                        }
                    }
                }
            } catch { $script:ToolSearchErrors.Shared.Add("Registry discovery failed at ${registryRoot}: $($_.Exception.Message)") }
        }
    }
    # Query only the relevant vendor or service if PATH and environment discovery failed.
    if ($Name -eq 'Java') {
        foreach ($vendorRoot in @('HKLM:\SOFTWARE\JavaSoft\JDK', 'HKLM:\SOFTWARE\JavaSoft\Java Development Kit', 'HKLM:\SOFTWARE\Eclipse Adoptium\JDK', 'HKLM:\SOFTWARE\Microsoft\JDK', 'HKLM:\SOFTWARE\WOW6432Node\JavaSoft', 'HKCU:\SOFTWARE\JavaSoft')) {
            try {
                if (-not (Test-Path -LiteralPath $vendorRoot -ErrorAction Stop)) { continue }
                foreach ($key in @(Get-Item -LiteralPath $vendorRoot) + @(Get-ChildItem -LiteralPath $vendorRoot -Recurse -ErrorAction Stop)) {
                    $record = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                    foreach ($property in @('JavaHome', 'Path', 'InstallationPath')) {
                        if ($record.$property) { $script:ToolRecords.Java.Add(@{ description = "Java vendor registry: $($key.Name)"; location = [string]$record.$property }) }
                    }
                }
            } catch { $script:ToolSearchErrors.Java.Add("Java registry discovery failed at ${vendorRoot}: $($_.Exception.Message)") }
        }
    }
    foreach ($vendor in @(
        @{ name = 'Node'; path = 'HKLM:\SOFTWARE\Node.js'; property = 'InstallPath' },
        @{ name = 'Node'; path = 'HKCU:\SOFTWARE\Node.js'; property = 'InstallPath' },
        @{ name = 'Git'; path = 'HKLM:\SOFTWARE\GitForWindows'; property = 'InstallPath' },
        @{ name = 'Git'; path = 'HKCU:\SOFTWARE\GitForWindows'; property = 'InstallPath' },
        @{ name = 'PostgreSQL'; path = 'HKLM:\SOFTWARE\PostgreSQL\Installations'; property = 'Base Directory' }
    )) {
        if ($Name -ne $vendor.name) { continue }
        try {
            if (-not (Test-Path -LiteralPath $vendor.path -ErrorAction Stop)) { continue }
            foreach ($key in @(Get-Item -LiteralPath $vendor.path) + @(Get-ChildItem -LiteralPath $vendor.path -ErrorAction Stop)) {
                $record = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                if ($record.($vendor.property)) {
                    $script:ToolRecords[$vendor.name].Add(@{ description = "Vendor registry: $($key.Name)"; location = [string]$record.($vendor.property) })
                }
            }
        } catch { $script:ToolSearchErrors[$Name].Add("Vendor registry discovery failed at $($vendor.path): $($_.Exception.Message)") }
    }
    if ($Name -eq 'PostgreSQL') { Read-PostgresServices }
}
function Read-PostgresServices {
    if ($script:ToolVendorLoaded['Services']) { return }
    $script:ToolVendorLoaded['Services'] = $true
    try {
        foreach ($service in @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.Name -match 'postgres' -or $_.PathName -match '(?:pg_ctl|postgres)[.]exe' })) {
            $match = [regex]::Match([string]$service.PathName, '^\s*(?:"(?<exe>[^"]+)"|(?<exe>.*?\.exe))(?:\s|$)')
            $location = if ($match.Success) { Split-Path (Split-Path $match.Groups['exe'].Value -Parent) -Parent } else { '' }
            $script:ToolRecords.PostgreSQL.Add(@{ description = "Windows service $($service.Name)"; location = $location; service = $service.Name })
        }
    } catch { $script:ToolSearchErrors.PostgreSQL.Add("PostgreSQL service discovery failed: $($_.Exception.Message)") }
}
function Get-PostgresServiceCandidates([string]$PsqlPath) {
    Read-PostgresServices
    $installation = Split-Path (Split-Path $PsqlPath -Parent) -Parent
    foreach ($record in $script:ToolRecords.PostgreSQL) {
        if ($record.service -and $record.location -and ([IO.Path]::GetFullPath($record.location) -eq [IO.Path]::GetFullPath($installation))) { $record.service }
    }
}
function Show-FixedDriveToolLocations {
    # This opt-in inventory prints paths only. A portable program on an arbitrary
    # drive must be explicitly selected before the bootstrap runs any of its code.
    $drives = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })
    $names = @('java.exe','javac.exe','node.exe','npm.cmd','sbt.bat','sbt.cmd','sbt.exe',
               'scala.exe','scala.bat','scala.cmd','scalac.bat','langium.cmd','psql.exe','pg_isready.exe','postgres.exe')
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    foreach ($drive in $drives) { $pending.Push($drive.RootDirectory.FullName) }
    $unreadable = 0
    $links = 0
    while ($pending.Count) {
        $directory = $pending.Pop()
        try {
            foreach ($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
                if ($item.PSIsContainer) {
                    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $links++; continue }
                    $pending.Push($item.FullName)
                } elseif (($item.Name -in $names) -or $item.Name -like 'sbt-launch*.jar' -or
                    ($item.Name -eq 'package.json' -and $item.Directory.Name -in @('langium','langium-cli'))) {
                    Write-Output $item.FullName
                }
            }
        } catch { $unreadable++; Write-Verbose "Skipped $directory ($($_.Exception.Message))" }
    }
    Write-Host "Inventory finished. Unreadable directories: $unreadable. Skipped directory links: $links."
    Write-Host 'Select trusted paths with -JavaPath, -NodePath, -NpmPath, -PsqlPath, -SbtLauncherPath or -AdditionalSearchPath on the next run.'
}

function Get-RegisteredToolPackageRoots {
    # WindowsApps is an ACL-protected package store, not a directory of
    # conventional installers. Windows publishes the current user's packages
    # and launches their commands through %LOCALAPPDATA%\Microsoft\WindowsApps.
    try { $packages = @(Get-AppxPackage -ErrorAction Stop) }
    catch {
        # The Appx module may require Windows PowerShell even when setup runs on 7.
        $windowsShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $windowsShell -PathType Leaf)) { throw }
        $listing = & $windowsShell -NoProfile -NonInteractive -Command '$ErrorActionPreference="Stop"; @(Get-AppxPackage | Select-Object Name,InstallLocation) | ConvertTo-Json -Compress' 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Cannot read Windows package registrations for the current user.' }
        if ($listing) { $packages = @(($listing -join ' ') | ConvertFrom-Json) } else { $packages = @() }
    }
    foreach ($package in $packages) {
        if ($package.InstallLocation -and $package.Name -match 'jdk|java|temurin|adoptium|corretto|zulu|nodejs|postgres|scala|langium|(?:^|[.])sbt|docker|visualstudiocode|gitforwindows') {
            $package.InstallLocation
        }
    }
}
function Get-FixedDrivePortableRoots {
    if ($env:OS -ne 'Windows_NT') { return }
    # A drive-root tools folder may be writable by other users. Its contents
    # count as installation evidence, but only an explicit selection may run them.
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -ne 'Fixed' -or -not $drive.IsReady) { continue }
        foreach ($relative in @('Tools','DevTools','scoop\apps')) { Join-Path $drive.RootDirectory.FullName $relative }
    }
}
function Get-ToolInventory {
    if ($null -ne $script:ToolInventory) { return $script:ToolInventory }
    $inventory = @{}
    foreach ($name in $script:ToolDefinitions.Keys) { $inventory[$name] = New-Object 'System.Collections.Generic.List[string]' }
    $names = @{}
    foreach ($name in $script:ToolDefinitions.Keys) { $names[$script:ToolDefinitions[$name].executable] = $name }
    $inventory['Npm'] = New-Object 'System.Collections.Generic.List[string]'
    $inventory['Sbt'] = New-Object 'System.Collections.Generic.List[string]'
    $inventory['Scala'] = New-Object 'System.Collections.Generic.List[string]'
    foreach ($alias in @('scala.exe','scalac.exe','scala.bat','scala.cmd','scalac.bat','scalac.cmd')) { $names[$alias] = 'Scala' }
    $inventory['Readiness'] = New-Object 'System.Collections.Generic.List[string]'
    $names['pg_isready.exe'] = 'Readiness'
    $names['npm.cmd'] = 'Npm'
    $names['sbt-launch.jar'] = 'Sbt'
    $names['sbt.bat'] = 'Sbt'
    $names['sbt.cmd'] = 'Sbt'
    $seen = @{}
    $appStores = @($env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramW6432) | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'WindowsApps' }
    $pending = New-Object 'System.Collections.Generic.Stack[object]'
    foreach ($kind in $inventory.Keys) { $script:PortableEvidence[$kind] = New-Object 'System.Collections.Generic.List[string]' }
    foreach ($portable in @(Get-FixedDrivePortableRoots)) { $pending.Push(@{ Path=$portable; SelectFirst=$true }) }
    # LIFO: known installation locations and explicitly supplied roots take priority.
    foreach ($directory in $script:ToolRoots) { $pending.Push(@{ Path=$directory; SelectFirst=$false }) }
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $directory = $current.Path
        if ($seen.ContainsKey($directory)) { continue }
        $seen[$directory] = $true
        try {
            if ($directory -in $appStores -and $directory -notin $AdditionalSearchPath) {
                foreach ($registered in @(Get-RegisteredToolPackageRoots)) { $pending.Push(@{ Path=$registered; SelectFirst=$false }) }
                continue
            }
            if (-not (Test-Path -LiteralPath $directory -ErrorAction Stop)) {
                # Additional search roots are explicit evidence requirements.
                if ($directory -in $AdditionalSearchPath) { throw 'Configured search directory does not exist.' }
                continue
            }
            $item = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
            if (-not $item.PSIsContainer) { throw 'Search root is not a directory.' }
            # Enumerate a selected root (including a version-manager junction) once.
            # Never follow nested directory links, which may loop or cross volumes.
            foreach ($child in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
                if ($child.PSIsContainer -and ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    foreach ($configured in $AdditionalSearchPath) {
                        $boundary = [IO.Path]::GetFullPath($configured).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
                        if ($child.FullName.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) {
                            $script:ToolSearchErrors.Shared.Add("Skipped nested link $($child.FullName). Select its target or an executable explicitly.")
                            break
                        }
                    }
                    continue
                }
                if ($child.PSIsContainer) { $pending.Push(@{ Path=$child.FullName; SelectFirst=$current.SelectFirst }); continue }
                $kind = $names[$child.Name]
                if ($child.Name -like 'sbt-launch-*.jar') { $kind = 'Sbt' }
                if ($child.Name -like 'scala3-compiler_3-*.jar') { $kind = 'Scala' }
                if ($kind) {
                    if ($current.SelectFirst) { $script:PortableEvidence[$kind].Add($child.FullName) }
                    else { $inventory[$kind].Add($child.FullName) }
                }
            }
        } catch { $script:ToolSearchErrors.Shared.Add("Cannot inspect ${directory}: $($_.Exception.Message)") }
    }
    $script:ToolInventory = $inventory
    return $inventory
}
function Get-PortableToolMessage([string]$Name) {
    if ($script:PortableEvidence[$Name].Count) {
        $examples = @($script:PortableEvidence[$Name] | Select-Object -First 3) -join ', '
        return "Possible $Name installation: $examples. Select a trusted executable or specify its directory with -AdditionalSearchPath."
    }
}
function Invoke-ToolVersion([string]$Executable, [string[]]$Arguments) {
    # Java writes its version to stderr, including on success. PS 5.1 must not
    # convert that successful native diagnostic into a terminating exception.
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $Executable @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        return @{ ok = ($exitCode -eq 0); text = (($output | ForEach-Object { "$_" }) -join "`n") }
    } catch { return @{ ok = $false; text = $_.Exception.Message } }
}
function Test-ToolCandidate([string]$Name, [string]$Executable) {
    $result = @{ state = 'incompatible'; name = $Name; path = $Executable; reason = ''; version = $null }
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { $result.reason = 'Executable is missing or inaccessible.'; return $result }
    $arguments = if ($Name -eq 'Java') { @('-XshowSettings:properties', '-version') } else { @('--version') }
    $probe = Invoke-ToolVersion $Executable $arguments
    if (-not $probe.ok) { $result.reason = "Version command failed: $($probe.text)"; return $result }
    $versionPattern = if ($Name -eq 'Java') { '(?:openjdk|java)\s+version\s+"(?<major>\d+)(?:\.(?<minor>\d+))?(?:\.(?<patch>\d+))?' } else { '(?<![\d.])v?(?<major>\d+)\.(?<minor>\d+)(?:\.(?<patch>\d+))?' }
    $match = [regex]::Match($probe.text, $versionPattern)
    if (-not $match.Success) { $result.reason = "Cannot parse version: $($probe.text)"; return $result }
    $minor = if ($match.Groups['minor'].Success) { $match.Groups['minor'].Value } else { '0' }
    $patch = if ($match.Groups['patch'].Success) { $match.Groups['patch'].Value } else { '0' }
    $version = [version]("{0}.{1}.{2}" -f $match.Groups['major'].Value, $minor, $patch)
    $result.version = $version
    switch ($Name) {
        Java {
            if ($version.Major -lt 11) { $result.reason = 'The project uses Java 11 Files.readString/writeString APIs.'; $result.canUpgrade = $true; return $result }
            # This probe reports version and the real JDK home, including for javapath shims.
            $homeMatch = [regex]::Match($probe.text, '(?m)^\s*java[.]home\s*=\s*([^\r\n]+)$')
            if (-not $homeMatch.Success) { $result.reason = 'Java did not report java.home.'; return $result }
            $runtimeHome = $homeMatch.Groups[1].Value.Trim()
            if (-not [IO.Path]::IsPathRooted($runtimeHome) -or $runtimeHome -match '[\x00\r\n]') {
                $result.reason = 'Java reported an invalid java.home.'; return $result
            }
            $canonicalJava = Join-Path ([IO.Path]::GetFullPath($runtimeHome)) 'bin\java.exe'
            if (-not (Test-Path -LiteralPath $canonicalJava -PathType Leaf)) {
                $result.reason = "Java reports '$runtimeHome', but bin\java.exe is inaccessible."; return $result
            }
            if ([IO.Path]::GetFullPath($Executable) -ne [IO.Path]::GetFullPath($canonicalJava)) {
                $actual = Invoke-ToolVersion $canonicalJava @('-version')
                $actualVersion = [regex]::Match($actual.text, $versionPattern)
                if (-not $actual.ok -or -not $actualVersion.Success -or [int]$actualVersion.Groups['major'].Value -ne $version.Major) {
                    $result.reason = 'The reported Java home does not run the selected Java major version.'; return $result
                }
            }
            $result.path = $canonicalJava
            if ($script:RejectedJava.ContainsKey($canonicalJava)) {
                $result.canUpgrade = $true; $result.reason = 'This Java failed the pinned Scala build compatibility probe.'; return $result
            }
            $result.javaHome = [IO.Path]::GetFullPath($runtimeHome)
            $result.probeBuild = $version.Major -notin @(11,17,21)
        }
        Node {
            if ($version -lt [version]'22.12.0' -or $version.Major -eq 23) { $result.reason = 'The project lock requires Node 22.12+ on 22.x, or >=24.'; $result.canUpgrade = $true; return $result }
            $npm = Find-NpmForNode $Executable
            if (-not $npm.path) {
                $result.reason = $npm.reason
                if ($npm.recoverable) { $result.state = 'npm-recovery'; $result.oldNpm = $npm.oldNpm }
                return $result
            }
            $result.npm = $npm.path
            $result.npmVersion = $npm.version
        }
        Git { if ($version -lt [version]'2.23.0') { $result.canUpgrade = $true; $result.reason = 'Git >=2.23 is required for restore and branch --show-current.'; return $result } }
        PostgreSQL {
            if ($version.Major -lt 15) { $result.canUpgrade = $true; $result.reason = 'PostgreSQL client >=15 is required.'; return $result }
            $ready = Join-Path (Split-Path $Executable -Parent) 'pg_isready.exe'
            $choices = @($ready) + @(Get-PathToolCandidates 'pg_isready.exe')
            $checked = @{}
            foreach ($phase in @('quick','inventory')) {
                if ($phase -eq 'inventory') { $choices = (Get-ToolInventory).Readiness }
                foreach ($candidate in $choices) {
                    if ($checked[$candidate] -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
                    $checked[$candidate] = $true
                    $probe = Invoke-ToolVersion $candidate @('--version')
                    if ($probe.ok -and $probe.text -match '\b(\d+)\.' -and [int]$Matches[1] -ge 15) { $result.ready = $candidate; break }
                }
                if ($result.ready) { break }
            }
            if (-not $result.ready) { $result.reason = 'No runnable pg_isready >=15 was found for this psql client.'; return $result }
        }
        Docker { if ($version.Major -lt 20) { $result.canUpgrade = $true; $result.reason = 'Docker CLI >=20 is required.'; return $result } }
    }
    $result.state = 'compatible'
    return $result
}
function Find-NpmForNode([string]$NodeExecutable) {
    $bin = Split-Path $NodeExecutable -Parent
    $candidates = @()
    if ($NpmPath) { $candidates = @([IO.Path]::GetFullPath($NpmPath)) }
    else {
        $candidates = @((Join-Path $bin 'npm.cmd')) + @(Get-PathToolCandidates 'npm.cmd')
        if ($Tools) { $candidates += Join-Path $Tools 'npm-10.9.4\npm.cmd' }
        foreach ($prefix in @($env:NPM_CONFIG_PREFIX, "$env:APPDATA\npm", $env:NVM_SYMLINK)) {
            if ($prefix) { $candidates += Join-Path $prefix 'npm.cmd' }
        }
    }
    $previous = $env:PATH
    $tested = @{}
    $oldNpm = $false
    $failedProbe = $false
    try {
        $env:PATH = Add-UniqueToolPath @($bin) $previous
        foreach ($phase in @('quick', 'inventory')) {
            if ($phase -eq 'inventory') {
                if ($NpmPath) { break }
                $candidates = (Get-ToolInventory).Npm
            }
            foreach ($candidate in $candidates) {
                if ($tested.ContainsKey($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
                $tested[$candidate] = $true
                # npm.cmd prefers node.exe beside itself. A launcher belonging to
                # another Node must never silently run npm with the wrong runtime.
                $localNode = Join-Path (Split-Path $candidate -Parent) 'node.exe'
                if ((Test-Path -LiteralPath $localNode -PathType Leaf) -and
                    [IO.Path]::GetFullPath($localNode) -ne [IO.Path]::GetFullPath($NodeExecutable)) { continue }
                $probe = Invoke-ToolVersion $candidate @('--version')
                $v = [regex]::Match($probe.text, '(?m)^\s*(\d+\.\d+\.\d+)\s*$')
                if ($probe.ok -and $v.Success) {
                    if ([version]$v.Groups[1].Value -ge [version]'10.2.3') { return @{ path=$candidate; version=$v.Groups[1].Value } }
                    $oldNpm = $true
                } else { $failedProbe = $true }
            }
        }
    } finally { $env:PATH = $previous }
    return @{ reason="No runnable npm >=10.2.3 for $NodeExecutable. Select an existing npm.cmd with -NpmPath."; recoverable=($oldNpm -or (-not $NpmPath -and -not $failedProbe)); oldNpm=$oldNpm }
}
function Get-PathToolCandidates([string]$Executable) {
    @(Get-Command $Executable -CommandType Application -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
    if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA ("Microsoft\WindowsApps\" + $Executable) }
    # This shell may predate an installation that already updated user/machine PATH.
    foreach ($scope in @('User','Machine')) {
        foreach ($entry in ([Environment]::GetEnvironmentVariable('Path',$scope) -split ';')) {
            if ($entry) {
                $directory = [Environment]::ExpandEnvironmentVariables($entry.Trim('"'))
                if ([IO.Path]::IsPathRooted($directory)) { Join-Path $directory $Executable }
            }
        }
    }
}
function Find-SystemTool([string]$Name, [string]$ExplicitPath) {
    $definition = $script:ToolDefinitions[$Name]
    if (-not $definition) { throw "Unknown tool: $Name" }
    if ($ExplicitPath) {
        # An explicit selection is authoritative, including an incorrect path.
        return (Test-ToolCandidate $Name ([IO.Path]::GetFullPath($ExplicitPath)))
    }
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $evidence = New-Object 'System.Collections.Generic.List[string]'
    if ($Name -eq 'PostgreSQL') {
        # Managed binaries must remain discoverable in a new terminal even
        # when the prior run deliberately used -SessionOnlyEnvironment.
        $managedCandidate = Get-ManagedPostgresToolCandidate
        if ($managedCandidate) { $candidates.Add($managedCandidate) }
    }
    foreach ($candidate in @(Get-PathToolCandidates $definition.executable)) { $candidates.Add($candidate) }
    foreach ($scope in @('Process','User','Machine')) {
        $hint = [Environment]::GetEnvironmentVariable($definition.hint, $scope)
        if ($hint) {
            $candidates.Add((Join-Path $hint $definition.relative))
            if (Test-Path -LiteralPath $hint) { $evidence.Add("$($definition.hint)=$hint") }
        }
    }
    $search = @{ Tested=@{}; Failures=(New-Object 'System.Collections.Generic.List[string]'); CanUpgrade=$false; Provisional=$null; NpmRecovery=$null }
    function Select-ToolCandidate($Paths) {
        foreach ($candidate in $Paths) {
            if ($search.Tested.ContainsKey($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            $search.Tested[$candidate] = $true
            $result = Test-ToolCandidate $Name $candidate
            if ($result.state -eq 'compatible') {
                if (-not $result.probeBuild) { return $result }
                if (-not $search.Provisional) { $search.Provisional = $result }
            } elseif ($result.state -eq 'npm-recovery') {
                if (-not $search.NpmRecovery) { $search.NpmRecovery = $result }
            } else {
                if ($result.canUpgrade) { $search.CanUpgrade = $true }
                $search.Failures.Add("${candidate}: $($result.reason) (version $($result.version))")
            }
        }
    }
    $choice = Select-ToolCandidate $candidates
    if ($choice) { return $choice }
    $candidates.Clear()
    Read-ToolRegistrations $Name
    foreach ($record in $script:ToolRecords[$Name]) {
        $evidence.Add($record.description)
        if ($record.location) {
            $candidates.Add((Join-Path $record.location $definition.relative))
            $candidates.Add((Join-Path $record.location $definition.executable))
            $candidates.Add((Join-Path $record.location ('bin\' + $definition.executable)))
        }
    }
    # Standard vendor paths are cheap and precede the shared recursive fallback.
    $standard = switch ($Name) {
        Java { @('Microsoft\jdk-*\bin\java.exe', 'Java\*\bin\java.exe', 'Eclipse Adoptium\*\bin\java.exe', 'Amazon Corretto\*\bin\java.exe') }
        Node { @('nodejs\node.exe') }
        Git { @('Git\cmd\git.exe', 'Git\bin\git.exe') }
        PostgreSQL { @('PostgreSQL\*\bin\psql.exe') }
        Code { @('Microsoft VS Code\bin\code.cmd') }
        Docker { @('Docker\Docker\resources\bin\docker.exe') }
    }
    $standardDirectories = switch ($Name) {
        Java { @('Microsoft\jdk-*', 'Java', 'Eclipse Adoptium', 'Amazon Corretto') }
        Node { @('nodejs') }
        Git { @('Git') }
        PostgreSQL { @('PostgreSQL') }
        Code { @('Microsoft VS Code') }
        Docker { @('Docker\Docker') }
    }
    foreach ($directory in $script:ToolRoots) {
        foreach ($relative in $standardDirectories) {
            foreach ($item in @(Get-Item -Path (Join-Path $directory $relative) -ErrorAction SilentlyContinue)) {
                if ($item.PSIsContainer) { $evidence.Add("Existing $Name installation directory: $($item.FullName)") }
            }
        }
        foreach ($relative in $standard) {
            try {
                foreach ($item in @(Get-Item -Path (Join-Path $directory $relative) -ErrorAction SilentlyContinue)) {
                    if (-not $item.PSIsContainer) { $candidates.Add($item.FullName) }
                }
            } catch { $script:ToolSearchErrors[$Name].Add("Cannot inspect vendor path under ${directory}: $($_.Exception.Message)") }
        }
    }
    $choice = Select-ToolCandidate $candidates
    if ($choice) { return $choice }
    $choice = Select-ToolCandidate ((Get-ToolInventory)[$Name])
    if ($choice) { return $choice }
    if ($search.Provisional) { return $search.Provisional }
    $errors = @($script:ToolSearchErrors.Shared.ToArray()) + @($script:ToolSearchErrors[$Name].ToArray())
    if ($errors.Count -gt 0) { return @{ state = 'inconclusive'; name = $Name; reason = ($errors -join '; ') } }
    $portable = Get-PortableToolMessage $Name
    if ($portable) { return @{ state='inconclusive'; name=$Name; reason=$portable } }
    if ($search.NpmRecovery) { return $search.NpmRecovery }
    if ($search.Failures.Count -gt 0 -or $evidence.Count -gt 0) {
        return @{ state = 'incompatible'; name = $Name; canUpgrade = $search.CanUpgrade; reason = ((@($search.Failures.ToArray()) + @($evidence.ToArray())) -join '; ') }
    }
    return @{ state = 'missing'; name = $Name; reason = 'No installation found after complete discovery.' }
}
function Test-BootstrapInteractive {
    return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and
        -not (@([Environment]::GetCommandLineArgs()) -match '^(?:-|/)(?:noni|noninteractive)$'))
}
function Confirm-ToolUpgrade([string]$Component, [string]$Detail) {
    Write-Host "$Component requires a change. $Detail"
    if ($AllowToolUpgrade) { return $true }
    if (-not (Test-BootstrapInteractive)) { return $false }
    try { $reply = Read-Host 'Proceed with this change? [y/N]' }
    catch { return $false }
    return (([string]$reply).Trim() -match '^(y|yes|d|da)$')
}
function Repair-NodeNpm($Node) {
    $portable = Get-PortableToolMessage 'Npm'
    if ($portable) { throw $portable }
    if ($script:ToolSearchErrors.Shared.Count) { throw "npm discovery incomplete: $($script:ToolSearchErrors.Shared -join '; ')" }
    if ($Node.oldNpm -and -not (Confirm-ToolUpgrade 'npm' "Keep Node $($Node.version) and add npm 10.9.4 under $Tools.")) { throw 'npm upgrade declined.' }
    $target = Join-Path $Tools 'npm-10.9.4'
    $command = Join-Path $target 'npm.cmd'
    if (Test-Path -LiteralPath $target) { throw "Existing managed npm installation is incomplete. Inspect $target before retrying." }
    $tar = Get-Command tar.exe -CommandType Application -ErrorAction Stop
    New-Item -ItemType Directory -Path $Tools -Force | Out-Null
    $archive = Join-Path $Tools 'npm-10.9.4.tgz'
    Get-VerifiedDownload -Uri 'https://registry.npmjs.org/npm/-/npm-10.9.4.tgz' -Path $archive -Sha256 '4bfba8a0c823024d1926ec9d97a37a00eb60fd2adf44b3d34a686fc32e8f51e4'
    $stage = Join-Path $Tools ("npm-stage-" + [guid]::NewGuid().ToString('N'))
    try {
        $modules = New-Item -Type Directory -Path (Join-Path $stage 'node_modules') -Force
        Run { & $tar.Source -xzf $archive -C $modules.FullName } | Out-Host
        Rename-Item -LiteralPath (Join-Path $modules.FullName 'package') -NewName 'npm'
        # Keep the chosen Node first on PATH; use this verified npm rather than
        # a different CLI from a user's global npm prefix.
        [IO.File]::WriteAllText((Join-Path $stage 'npm.cmd'), "@echo off`r`nnode.exe `"%~dp0node_modules\npm\bin\npm-cli.js`" %*`r`n", [Text.Encoding]::ASCII)
        $probe = Invoke-ToolVersion $Node.path @((Join-Path $stage 'node_modules\npm\bin\npm-cli.js'), '--version')
        if (-not $probe.ok -or $probe.text.Trim() -ne '10.9.4') { throw 'The recovered npm failed its version check.' }
        [IO.Directory]::Move($stage, $target)
    } finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
    $NpmPath = $command
    $result = Test-ToolCandidate 'Node' $Node.path
    if ($result.state -ne 'compatible') { throw "Managed npm failed under selected Node: $($result.reason)" }
    return $result
}
function Assert-PlainPostgresPath([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor -ErrorAction Stop) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "PostgreSQL setup refuses linked path '$cursor'. Select an ordinary local directory." }
        }
        $parent = Split-Path -Parent $cursor
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}
function Get-ManagedPostgresCluster {
    $directory = [IO.Path]::GetFullPath((Join-Path $Root 'postgres'))
    $recordPath = Join-Path $directory 'cluster.json'
    Assert-PlainPostgresPath $directory
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { return $null }
    Assert-PlainPostgresPath $recordPath
    $record = Get-Content -LiteralPath $recordPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $expectedData = [IO.Path]::GetFullPath((Join-Path $directory 'data'))
    if ($record.schema -ne 1 -or $record.state -cne 'ready' -or
        -not [string]::Equals([string]$record.dataDirectory, $expectedData, [StringComparison]::OrdinalIgnoreCase) -or
        -not $record.binDirectory -or -not [IO.Path]::IsPathRooted([string]$record.binDirectory) -or
        [int]$record.port -lt 1 -or [int]$record.port -gt 65535) {
        throw "Managed PostgreSQL state is incomplete or invalid at '$recordPath'. Recover that existing setup before initializing another cluster."
    }
    Assert-PlainPostgresPath $record.dataDirectory
    Assert-PlainPostgresPath $record.binDirectory
    if (-not (Test-Path -LiteralPath (Join-Path $record.dataDirectory 'PG_VERSION') -PathType Leaf)) { throw "Managed PostgreSQL data is missing at '$($record.dataDirectory)'. Recover it; no replacement cluster was created." }
    return $record
}
function Get-ManagedPostgresToolCandidate {
    $cluster = Get-ManagedPostgresCluster
    if ($cluster) { $bin = [string]$cluster.binDirectory }
    else {
        $directory = [IO.Path]::GetFullPath((Join-Path $Root 'postgres'))
        $recordPath = Join-Path $directory 'distribution.json'
        if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { return $null }
        Assert-PlainPostgresPath $recordPath
        $record = Get-Content -LiteralPath $recordPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $expected = [IO.Path]::GetFullPath((Join-Path $directory 'distribution'))
        if ($record.schema -ne 1 -or $record.state -cne 'extracted' -or
            -not [string]::Equals([string]$record.directory, $expected, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Managed PostgreSQL extraction is incomplete or invalid at '$recordPath'. Repair the preserved files; no duplicate download was attempted."
        }
        $bin = Join-Path $expected 'bin'
    }
    foreach ($name in @('psql.exe', 'postgres.exe', 'initdb.exe', 'pg_ctl.exe', 'pg_isready.exe')) {
        $executable = Join-Path $bin $name
        Assert-PlainPostgresPath $executable
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "Managed PostgreSQL tool '$executable' is missing. Repair that installation; no replacement was downloaded." }
    }
    return (Join-Path $bin 'psql.exe')
}
function Get-LocalPostgresClusterEvidence {
    # Search independently of the selected psql version: an older stopped server
    # may still own the user's data even when a newer client is first on PATH.
    $evidence = New-Object 'Collections.Generic.List[string]'
    foreach ($service in @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.Name -match 'postgres' -or $_.PathName -match '(?:pg_ctl|postgres)[.]exe' })) {
        $evidence.Add("Windows service '$($service.Name)' ($($service.State))")
    }
    if (@(Get-CimInstance Win32_Process -Filter "Name='postgres.exe'" -ErrorAction Stop).Count) { $evidence.Add('A postgres.exe process is running') }
    $candidates = New-Object 'Collections.Generic.List[string]'
    foreach ($scope in @('Process', 'User', 'Machine')) {
        $configured = [Environment]::GetEnvironmentVariable('PGDATA', $scope)
        if ($configured) { $evidence.Add("PGDATA configured in $scope environment: $configured") }
    }
    foreach ($registryRoot in @('HKLM:\SOFTWARE\PostgreSQL\Installations', 'HKLM:\SOFTWARE\WOW6432Node\PostgreSQL\Installations')) {
        if (-not (Test-Path -LiteralPath $registryRoot -ErrorAction Stop)) { continue }
        foreach ($key in @(Get-Item -LiteralPath $registryRoot) + @(Get-ChildItem -LiteralPath $registryRoot -ErrorAction Stop)) {
            $registration = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            if ($registration.'Data Directory') { $evidence.Add("Registered data directory '$($registration.'Data Directory')'") }
            if ($registration.'Base Directory') { $candidates.Add((Join-Path $registration.'Base Directory' 'data')) }
        }
    }
    foreach ($installation in @($env:PGHOME, $(if ($PsqlPath) { Split-Path (Split-Path $PsqlPath -Parent) -Parent }), 'C:\PostgreSQL')) {
        if ($installation) { $candidates.Add((Join-Path $installation 'data')) }
    }
    foreach ($programRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432)) {
        if (-not $programRoot) { continue }
        $vendorRoot = Join-Path $programRoot 'PostgreSQL'
        if (-not (Test-Path -LiteralPath $vendorRoot -PathType Container -ErrorAction Stop)) { continue }
        foreach ($version in @(Get-ChildItem -LiteralPath $vendorRoot -Directory -Force -ErrorAction Stop)) { $candidates.Add((Join-Path $version.FullName 'data')) }
    }
    foreach ($candidate in $candidates | Sort-Object -Unique) {
        if (Test-Path -LiteralPath $candidate -ErrorAction Stop) {
            Assert-PlainPostgresPath $candidate
            if (@(Get-ChildItem -LiteralPath $candidate -Force -ErrorAction Stop).Count) { $evidence.Add("Existing PostgreSQL data directory '$candidate'") }
        }
    }
    # Portable clusters within the lab or explicitly trusted search locations.
    $pending = New-Object 'Collections.Generic.Stack[string]'
    foreach ($searchRoot in @($Root) + @($AdditionalSearchPath)) {
        if ($searchRoot -and (Test-Path -LiteralPath $searchRoot -PathType Container -ErrorAction Stop)) { $pending.Push([IO.Path]::GetFullPath($searchRoot)) }
    }
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    while ($pending.Count) {
        $directory = $pending.Pop()
        if (-not $seen.Add($directory)) { continue }
        $item = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Portable PostgreSQL discovery cannot inspect linked directory '$directory'. Select/recover the intended existing cluster explicitly." }
        if (Test-Path -LiteralPath (Join-Path $directory 'PG_VERSION') -PathType Leaf -ErrorAction Stop) { $evidence.Add("Initialized PostgreSQL directory '$directory'"); continue }
        if (Test-Path -LiteralPath (Join-Path $directory '.git') -ErrorAction Stop) { continue }
        foreach ($child in @(Get-ChildItem -LiteralPath $directory -Directory -Force -ErrorAction Stop)) {
            if ($child.Name -notin @('node_modules', 'target', '.git', 'downloads', 'backups', '.metals', '.bsp', '.bloop', 'editor-profile')) { $pending.Push($child.FullName) }
        }
    }
    return @($evidence | Sort-Object -Unique)
}
function Assert-NoExistingPostgresCluster {
    $evidence = @(Get-LocalPostgresClusterEvidence)
    if ($evidence.Count) { throw ("Existing PostgreSQL evidence prevents a new cluster: " + ($evidence -join '; ') + '. Select that instance/service and recover its access; no second cluster was created.') }
}
function New-PostgresPrivateDirectory([string]$Path) {
    Assert-PlainPostgresPath $Path
    if (Test-Path -LiteralPath $Path) { throw "Refusing to overwrite existing PostgreSQL setup directory '$Path'." }
    New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
    Protect-BootstrapState $Path
}
function Save-ManagedPostgresCluster([string]$BinDirectory, [string]$ServiceName, [string]$Status) {
    Save-Json (Join-Path $Root 'postgres\cluster.json') @{
        schema = 1; state = $Status
        dataDirectory = [IO.Path]::GetFullPath((Join-Path $Root 'postgres\data'))
        binDirectory = $BinDirectory; adminUser = $PgAdminUser; port = $Port; serviceName = $ServiceName
    }
}
function Install-NewPostgresServer([string]$Winget, [string]$Package) {
    Assert-NoExistingPostgresCluster
    $managed = Join-Path $Root 'postgres'
    New-PostgresPrivateDirectory $managed
    $distribution = [IO.Path]::GetFullPath((Join-Path $managed 'distribution'))
    $record = @{ schema=1; state='extracting'; directory=$distribution; package=$Package }
    Save-Json (Join-Path $managed 'distribution.json') $record
    $options = Join-Path $managed 'installer.options'
    try {
        # EDB's regular installer starts a service listening on '*'. Extract
        # binaries only; our initdb/pg_ctl path never exposes the lab password
        # beyond loopback, even during the first server startup.
        if ($distribution -match '[\r\n]') { throw 'Unsupported newline in PostgreSQL distribution path.' }
        $text = "extract-only=1`nprefix=$distribution`n"
        [IO.File]::WriteAllText($options, $text, $Utf8)
        $override = '--mode unattended --unattendedmodeui none --optionfile ' + (ConvertTo-WindowsArgument $options)
        & $Winget install --id $Package --exact --source winget --no-upgrade --accept-source-agreements --accept-package-agreements --override $override | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "PostgreSQL extraction returned $LASTEXITCODE. Its files were preserved at '$managed'; inspect the partial extraction before retrying. No database was initialized." }
        $bin = Join-Path $distribution 'bin'
        foreach ($name in @('psql.exe', 'postgres.exe', 'initdb.exe', 'pg_ctl.exe', 'pg_isready.exe')) {
            $executable = Join-Path $bin $name
            Assert-PlainPostgresPath $executable
            $probe = Invoke-ToolVersion $executable @('--version')
            if (-not $probe.ok) { throw "Extracted PostgreSQL tool '$executable' failed validation. Repair the preserved distribution; no database was initialized." }
        }
        Assert-NoExistingPostgresCluster
        $record.state = 'extracted'
        Save-Json (Join-Path $managed 'distribution.json') $record
        return (Join-Path $bin 'psql.exe')
    } finally {
        if ([IO.File]::Exists($options)) { [IO.File]::Delete($options) }
    }
}
function Assert-ManagedPostgresDirectory {
    $directory = [IO.Path]::GetFullPath((Join-Path $Root 'postgres'))
    if (-not (Test-Path -LiteralPath $directory)) { New-PostgresPrivateDirectory $directory; return }
    Assert-PlainPostgresPath $directory
    $recordPath = Join-Path $directory 'distribution.json'
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { throw "Existing PostgreSQL directory '$directory' is not a completed managed extraction. Inspect/recover it before initializing any data." }
    Assert-PlainPostgresPath $recordPath
    $record = Get-Content -LiteralPath $recordPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $expected = [IO.Path]::GetFullPath((Join-Path $directory 'distribution'))
    if ($record.schema -ne 1 -or $record.state -cne 'extracted' -or
        -not [string]::Equals([string]$record.directory, $expected, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetFullPath($PsqlPath), (Join-Path $expected 'bin\psql.exe'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Managed PostgreSQL extraction is incomplete or differs from the selected binary. Inspect '$recordPath'; no duplicate download or initialization was attempted."
    }
    $unexpected = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop | Where-Object { $_.Name -notin @('distribution', 'distribution.json') })
    if ($unexpected.Count) { throw "Existing files in '$directory' prevent initialization. Recover that setup before retrying." }
}
function Initialize-NewLocalPostgres {
    $managed = Get-ManagedPostgresCluster
    $bin = [IO.Path]::GetFullPath((Split-Path -Parent $PsqlPath))
    foreach ($name in @('postgres.exe', 'initdb.exe', 'pg_ctl.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $bin $name) -PathType Leaf)) { throw "Server tool '$name' is missing beside '$PsqlPath'. Select a complete PostgreSQL server installation before initializing local data." }
    }
    Assert-PlainPostgresPath $bin
    $pgCtl = Join-Path $bin 'pg_ctl.exe'
    if ($managed) {
        if ($managed.serviceName) { throw "Managed PostgreSQL belongs to Windows service '$($managed.serviceName)'. Restore/start that service; no duplicate standalone server was created." }
        if ([int]$managed.port -ne $Port -or -not [string]::Equals([string]$managed.binDirectory, $bin, [StringComparison]::OrdinalIgnoreCase)) { throw 'Managed PostgreSQL binary location or port differs. Select its original configuration before starting it.' }
    } else {
        Assert-NoExistingPostgresCluster
        if ($PgAdminUser -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,62}$') { throw 'A new PostgreSQL administrator requires a simple role identifier.' }
        $directory = Join-Path $Root 'postgres'
        Assert-ManagedPostgresDirectory
        Save-ManagedPostgresCluster $bin '' 'initializing'
        $passwordFile = Join-Path $directory 'initdb.password'
        try {
            [IO.File]::WriteAllText($passwordFile, "postgres`n", $Utf8)
            $initDb = Join-Path $bin 'initdb.exe'
            $dataDirectory = Join-Path $directory 'data'
            Run { & $initDb -D $dataDirectory --username $PgAdminUser --pwfile $passwordFile --encoding UTF8 --auth-host=scram-sha-256 --auth-local=scram-sha-256 } | Out-Host
            # Persist only this newly created cluster's settings so that later
            # starts and password recovery see the same port/loopback binding.
            $listenHost = if ($PgHost -eq '::1') { '::1' } else { '127.0.0.1' }
            [IO.File]::AppendAllText((Join-Path $dataDirectory 'postgresql.conf'), "`n# Aurora local laboratory`nlisten_addresses = '$listenHost'`nport = $Port`n", $Utf8)
            Save-ManagedPostgresCluster $bin '' 'ready'
        } finally { if ([IO.File]::Exists($passwordFile)) { [IO.File]::Delete($passwordFile) } }
        $managed = Get-ManagedPostgresCluster
    }
    $server = Join-Path $bin 'postgres.exe'
    $version = Invoke-ToolVersion $server @('--version')
    $major = [regex]::Match($version.text, '(?i)PostgreSQL\)?\s+(\d+)(?:\.|\s|$)')
    $dataMajor = (Get-Content -LiteralPath (Join-Path $managed.dataDirectory 'PG_VERSION') -Raw).Trim()
    if (-not $version.ok -or -not $major.Success -or $major.Groups[1].Value -cne $dataMajor) { throw 'Managed PostgreSQL data and server binary major versions do not match. No automatic cluster upgrade was attempted.' }
    $listenHost = if ($PgHost -eq '::1') { '::1' } else { '127.0.0.1' }
    $log = Join-Path (Split-Path $managed.dataDirectory -Parent) 'server.log'
    Write-Host "Starting managed PostgreSQL at '$($managed.dataDirectory)' on ${listenHost}:$Port."
    Run { & $pgCtl -D $managed.dataDirectory -l $log -w -t $StartupTimeoutSeconds start } | Out-Host
    return $true
}
function Resolve-SystemTool([string]$Name, [string]$ExplicitPath) {
    $result = Find-SystemTool $Name $ExplicitPath
    if ($ExplicitPath -and $result.state -eq 'incompatible' -and $result.canUpgrade) {
        $alternative = Find-SystemTool $Name
        if ($alternative.state -in @('compatible','npm-recovery')) {
            Write-Host "$ExplicitPath is incompatible. Reusing an existing alternative: $($alternative.path)"
            $result = $alternative
        } elseif ($alternative.state -eq 'inconclusive') { $result = $alternative }
    }
    if ($result.state -eq 'npm-recovery') { $result = Repair-NodeNpm $result }
    if ($result.state -ne 'compatible') {
        $package = $script:ToolDefinitions[$Name].package
        $upgrade = $result.state -eq 'incompatible' -and $result.canUpgrade
        if (-not $upgrade -and $result.state -ne 'missing') { throw "$Name discovery: $($result.state). $($result.reason) Repair or select an existing executable." }
        if ($upgrade) {
            $detail = "$($result.reason) WinGet will update $package or install it alongside a different distribution, then setup will select a verified executable."
            if (-not (Confirm-ToolUpgrade $Name $detail)) { throw "$Name upgrade declined. Choose a compatible installation or rerun with -AllowToolUpgrade." }
        }
        $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue
        if (-not $winget) { throw "WinGet is unavailable. Configure $Name manually and rerun." }
        # install upgrades an existing matching package unless --no-upgrade is set.
        $arguments = @('install','--id',$package,'--exact','--source','winget','--accept-source-agreements','--accept-package-agreements')
        if (-not $upgrade) { $arguments += '--no-upgrade' }
        Write-Host "Configuring $package via WinGet."
        $installedPostgresPath = $null
        if ($Name -eq 'PostgreSQL') {
            $installedPostgresPath = Install-NewPostgresServer $winget.Source $package
        } else {
            & $winget.Source @arguments | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "$Name installer returned $LASTEXITCODE. Complete any required elevation/reboot and rerun." }
        }
        $script:ToolInventory = $null
        $script:ToolVendorLoaded.Remove($Name)
        if ($Name -eq 'PostgreSQL') { $script:ToolVendorLoaded.Remove('Services') }
        $script:UninstallRecordsLoaded = $false
        $script:ToolSearchErrors[$Name].Clear()
        $script:ToolSearchErrors.Shared.Clear()
        $script:ToolRecords[$Name].Clear()
        # The original path can still refer to the older, now side-by-side version.
        $result = Find-SystemTool $Name $installedPostgresPath
        if ($result.state -eq 'npm-recovery') { $result = Repair-NodeNpm $result }
        if ($result.state -ne 'compatible') { throw "$Name failed post-install validation ($($result.state)): $($result.reason)." }
    }
    Write-Host "Reusing $Name $($result.version): $($result.path)"
    return $result
}
function Add-UniqueToolPath([string[]]$Entries, [string]$Existing) {
    $seen = @{}; $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in @($Entries) + @($Existing -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $key = [Environment]::ExpandEnvironmentVariables($entry).Trim('"').TrimEnd('\', '/').ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $paths.Add($entry) }
    }
    return ($paths -join ';')
}
function Use-ToolEnvironment([hashtable]$Tools) {
    $entries = New-Object 'System.Collections.Generic.List[string]'
    $homes = @{}
    foreach ($name in $Tools.Keys) {
        $directory = Split-Path $Tools[$name].path -Parent
        $entries.Add($directory)
        switch ($name) {
            Java { $homes.JAVA_HOME = Split-Path $directory -Parent }
            Node { $homes.NODE_HOME = $directory; $entries.Add((Split-Path $Tools.Node.npm -Parent)) }
            PostgreSQL { $homes.PGHOME = Split-Path $directory -Parent }
        }
    }
    foreach ($name in $homes.Keys) { [Environment]::SetEnvironmentVariable($name, $homes[$name], 'Process') }
    $env:PATH = Add-UniqueToolPath @($entries) $env:PATH
    if ($SessionOnlyEnvironment) { Write-Host 'Tool environment configured for this process and its children only.'; return }
    foreach ($name in $homes.Keys) {
        if ([Environment]::GetEnvironmentVariable($name, 'User') -cne $homes[$name]) { [Environment]::SetEnvironmentVariable($name, $homes[$name], 'User') }
    }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $updatedPath = Add-UniqueToolPath @($entries) $userPath
    if ($updatedPath -cne $userPath) { [Environment]::SetEnvironmentVariable('Path', $updatedPath, 'User') }
    Write-Host 'Tool homes and PATH configured for this process and saved in the user environment. Use -SessionOnlyEnvironment to keep changes session-only. Database credentials are not persisted.'
}
function Assert-CodeEngine([string]$CodeExecutable, [string]$LangiumRoot) {
    $probe = Test-ToolCandidate 'Code' $CodeExecutable
    if ($probe.state -ne 'compatible') { throw "VS Code is unusable: $($probe.reason)" }
    # semver comes from the verified project's dependency tree. Match the actual
    # extension engine rather than guessing a hardcoded editor minimum.
    $engineCheck = @'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const version = process.argv[3];
const semver = require(require.resolve('semver', { paths: [root] }));
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'packages/extension/package.json'), 'utf8'));
if (!manifest.engines?.vscode || !semver.satisfies(version, manifest.engines.vscode)) {
    throw Error(`VS Code ${version} is incompatible with extension engine ${manifest.engines?.vscode}; explicit upgrade required.`);
}
'@
    Run { $engineCheck | node.exe - $LangiumRoot $probe.version.ToString() } | Out-Host
}

# Resolve only ordinary descendants of Root. Never cross a junction/symlink or
# operate on Root itself: replacing that directory would also move setup state.
function Resolve-ManagedPath([string]$Path, [string]$Label) {
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $Root $Path }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
    $prefix = $Root.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must be strictly inside Root '$Root': $full"
    }
    $cursor = $full
    while ($cursor.TrimEnd([char[]]'\/') -ne $Root.TrimEnd([char[]]'\/')) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "$Label crosses a link/junction at '$cursor'. External paths are not managed."
            }
            if ($cursor -ne $full -and -not $item.PSIsContainer) { throw "Not a directory: $cursor" }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}
function Test-PathOverlap([string]$First, [string]$Second) {
    $a = $First.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    $b = $Second.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    return ($a.StartsWith($b, [StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a, [StringComparison]::OrdinalIgnoreCase))
}
function Find-InstallLayout {
    $names = @('scala-testing-lab', 'langium_dsl_lab')
    $candidatesByRepo = @{}
    foreach ($name in $names) { $candidatesByRepo[$name] = New-Object 'System.Collections.Generic.List[string]' }
    $setups = New-Object 'System.Collections.Generic.List[string]'
    $overrides = @{ 'scala-testing-lab' = $ScalaRepoPath; 'langium_dsl_lab' = $LangiumRepoPath }
    foreach ($name in $names) {
        if ($overrides[$name]) { $overrides[$name] = Resolve-ManagedPath $overrides[$name] $name }
    }
    if ($SetupPath) { $SetupPath = Resolve-ManagedPath $SetupPath 'SetupPath' }
    $skip = @('.git', 'node_modules', 'target', 'out', 'dist', 'build', '.metals', '.bloop', '.bsp', '.idea', '.vscode', '.venv', 'venv', '__pycache__', 'backups', 'tools')
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($Root)
    $visited = 0
    Write-Host "Searching for repositories under: $Root"
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        $visited++
        if ($visited -gt 20000) { throw 'Repository search exceeded 20000 directories. Choose a narrower -Root; no repositories were changed.' }
        try { $children = @(Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction Stop | Sort-Object Name) }
        catch { throw "Cannot complete repository discovery in '$parent'. Choose an accessible -Root. $($_.Exception.Message)" }
        foreach ($child in $children) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if ($child.Name -in $names) { throw "Repository candidate is a link/junction: $($child.FullName). No repositories were changed." }
                continue
            }
            if ($child.Name -eq 'medication-lab-setup') {
                $automatic = Join-Path $child.FullName 'automatic'
                if (Test-Path -LiteralPath $automatic -PathType Container) { $setups.Add((Resolve-ManagedPath $automatic 'Setup directory')) }
                continue # Never rediscover archived clones in setup/backups.
            }
            if ($child.Name -in $skip -or $child.Name -like '.bootstrap-*') { continue }
            if (($SetupPath -and $child.FullName -eq $SetupPath) -or $child.FullName -in @($overrides.Values)) { continue }
            $identity = $null
            if ($child.Name -in $names) { $identity = $child.Name }
            $gitPath = Join-Path $child.FullName '.git'
            $hasGit = Test-Path -LiteralPath $gitPath
            if ($hasGit) {
                $gitItem = Get-Item -LiteralPath $gitPath -Force -ErrorAction Stop
                if (-not ($gitItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $gitItem.PSIsContainer) {
                    $origin = Read-GitMetadata $child.FullName @('remote', 'get-url', 'origin')
                    foreach ($name in $names) {
                        $url = "https://github.com/bogdanparvu18/$name.git"
                        if ($origin.ok -and $origin.text -in @($url, $url.Substring(0, $url.Length - 4), "git@github.com:bogdanparvu18/$name.git")) {
                            $identity = $name
                            break
                        }
                    }
                }
            }
            if ($identity) { $candidatesByRepo[$identity].Add($child.FullName); continue }
            if ($hasGit) { continue } # Do not search within another project's checkout.
            $queue.Enqueue($child.FullName)
        }
    }
    $selected = @{}
    foreach ($name in $names) {
        if ($overrides[$name]) { $selected[$name] = $overrides[$name]; continue }
        $candidates = @($candidatesByRepo[$name] | Sort-Object -Unique)
        if ($candidates.Count -gt 1) {
            $option = if ($name -eq 'scala-testing-lab') { '-ScalaRepoPath' } else { '-LangiumRepoPath' }
            throw "Multiple copies of $name were found:`n$($candidates -join "`n")`nSelect one with $option (absolute or relative to Root). No repositories were changed."
        }
        if ($candidates.Count -eq 1) { $selected[$name] = $candidates[0] }
    }
    # Place a missing partner beside the discovered repo. With no matches, reuse
    # Root/repos if present; otherwise retain the original direct-child layout.
    $destinationParent = $Root
    if ($selected.Count -eq 1) {
        $oneRepo = @($selected.Values)[0]
        $destinationParent = Split-Path -Parent $oneRepo
    }
    elseif ($selected.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $Root 'repos') -PathType Container)) { $destinationParent = Join-Path $Root 'repos' }
    foreach ($name in $names) {
        if (-not $selected.ContainsKey($name)) { $selected[$name] = Join-Path $destinationParent $name }
        $selected[$name] = Resolve-ManagedPath $selected[$name] $name
        $ancestor = Split-Path -Parent $selected[$name]
        while ($ancestor.TrimEnd([char[]]'\/') -ne $Root.TrimEnd([char[]]'\/')) {
            if (Test-Path -LiteralPath (Join-Path $ancestor '.git')) { throw "Managed repo is nested inside another Git checkout: $($selected[$name])" }
            if ((Split-Path -Leaf $ancestor) -in @('medication-lab-setup', 'backups')) { throw 'Archived/setup directories cannot be selected as active repositories.' }
            $ancestor = Split-Path -Parent $ancestor
        }
    }
    if (Test-PathOverlap $selected[$names[0]] $selected[$names[1]]) { throw 'The two repository paths must be separate, non-nested directories.' }
    if (-not $SetupPath) {
        $existingSetups = @($setups | Sort-Object -Unique)
        if ($existingSetups.Count -gt 1) { throw "Multiple setup directories were found:`n$($existingSetups -join "`n")`nSelect the existing automatic directory with -SetupPath. No repositories were changed." }
        $SetupPath = if ($existingSetups.Count -eq 1) { $existingSetups[0] } else { Join-Path $Root 'medication-lab-setup\automatic' }
    }
    $SetupPath = Resolve-ManagedPath $SetupPath 'SetupPath'
    foreach ($name in $names) {
        if (Test-PathOverlap $selected[$name] $SetupPath) { throw 'The setup directory must be outside both repositories.' }
    }
    return @{ repositories = $selected; automatic = $SetupPath }
}

# Clone only an absent repository. An existing copy is never moved or replaced.
function Install-FreshRepo([string]$Name, [string]$BranchName, [string]$Reason) {
    $directory = $RepoDirectories[$Name]
    if (Test-Path -LiteralPath $directory) { throw "Repository path appeared during setup: $directory. Existing files were preserved." }
    $url = "https://github.com/bogdanparvu18/$Name.git"
    $parent = Split-Path -Parent $directory
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $stage = Join-Path $parent ('.bootstrap-' + $Name + '-' + [guid]::NewGuid().ToString('N'))
    Write-Host "${Name}: $Reason. Preparing origin/$BranchName."
    try {
        Run { git.exe clone --branch $BranchName -- $url $stage } | Out-Host
        $expected = (Run { git.exe -C $stage rev-parse "refs/remotes/origin/$BranchName" }).Trim()
        $after = (Run { git.exe -C $stage rev-parse HEAD }).Trim()
        if ($after -ne $expected) { throw "$Name clone does not match origin/$BranchName." }
        # Directory.Move refuses an existing destination, including a concurrent copy.
        [IO.Directory]::Move($stage, $directory)
        return @{ repository = $Name; path = $directory; branch = $BranchName; before = $null; after = $after; action = 'clone'; backupPath = $null; reason = $Reason }
    } finally {
        if (Test-Path -LiteralPath $stage) {
            try { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop }
            catch { Write-Warning "Temporary clone could not be removed: $stage" }
        }
    }
}
function Read-GitMetadata([string]$Directory, [string[]]$Arguments) {
    # Read-only probes can identify a corrupt/partial checkout without changing it.
    $ErrorActionPreference = 'Continue'
    $output = @(& git.exe -C $Directory @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
    return @{ ok = ($exitCode -eq 0); text = ($output -join "`n").Trim() }
}
function Sync-Repo([string]$Name, [string]$BranchName, [string[]]$GeneratedPatterns) {
    if ($Name -notin @('scala-testing-lab', 'langium_dsl_lab')) { throw 'Unsupported managed repository name.' }
    $directory = $RepoDirectories[$Name]
    $url = "https://github.com/bogdanparvu18/$Name.git"
    Run { git.exe check-ref-format --branch $BranchName } | Out-Null
    $remoteRef = "refs/remotes/origin/$BranchName"
    if (-not (Test-Path -LiteralPath $directory)) {
        return (Install-FreshRepo $Name $BranchName 'No local copy exists')
    }
    $item = Get-Item -LiteralPath $directory -Force
    $gitPath = Join-Path $directory '.git'
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        -not (Test-Path -LiteralPath $gitPath -PathType Container) -or
        ((Get-Item -LiteralPath $gitPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Existing '$directory' is not an ordinary managed checkout. It was preserved; reconcile it explicitly."
    }
    $origin = Read-GitMetadata $directory @('remote', 'get-url', 'origin')
    $head = Read-GitMetadata $directory @('rev-parse', '--verify', 'HEAD')
    $currentBranch = Read-GitMetadata $directory @('branch', '--show-current')
    if (-not $origin.ok -or -not $head.ok -or -not $currentBranch.ok -or
        $origin.text -notin @($url, $url.Substring(0, $url.Length - 4), "git@github.com:bogdanparvu18/$Name.git")) {
        throw "Existing '$directory' has incompatible Git metadata/origin. It was preserved; reconcile it explicitly."
    }
    Run { git.exe -C $directory fetch --prune origin "+refs/heads/${BranchName}:${remoteRef}" } | Out-Host
    $before = $head.text
    $remote = (Run { git.exe -C $directory rev-parse $remoteRef }).Trim()
    $branch = $currentBranch.text
    if ($branch -and $branch -ne $BranchName -and $branch -ne 'main') {
        throw "$Name is on '$branch'; select the intended branch explicitly. No checkout or backup was made."
    }
    if ([int](Run { git.exe -C $directory rev-list --count "${remoteRef}..HEAD" }) -ne 0) {
        throw "$Name has local/divergent commits. Reconcile them explicitly; the checkout was preserved."
    }
    $localBranch = @(Run { git.exe -C $directory branch --list $BranchName })
    if ($localBranch.Count -gt 0 -and [int](Run { git.exe -C $directory rev-list --count "${remoteRef}..${BranchName}" }) -ne 0) {
        throw "Local $BranchName differs from its upstream. No source or history was replaced."
    }
    # A successful previous build is not a reason to stash thousands of outputs.
    if ($before -eq $remote -and $branch -eq $BranchName) {
        Write-Host "${Name}: already at $remote; preserving generated outputs and local files."
        return @{ repository = $Name; path = $directory; branch = $BranchName; before = $before; after = $remote; action = 'unchanged'; backupPath = $null }
    }
    $upstream = @(Run { git.exe -c core.quotepath=false -C $directory diff --name-only --no-renames "$before..$remote" -- })
    $changed = @(Run { git.exe -c core.quotepath=false -C $directory diff --name-only -- })
    $changed += @(Run { git.exe -c core.quotepath=false -C $directory diff --cached --name-only -- })
    $untracked = @(Run { git.exe -c core.quotepath=false -C $directory ls-files --others --exclude-standard })
    $ignored = @(Run { git.exe -c core.quotepath=false -C $directory ls-files --others --ignored --exclude-standard --directory })
    $conflictingGenerated = @()
    foreach ($path in @(@($changed) + @($untracked) + @($ignored) | Where-Object { $_ } | Sort-Object -Unique)) {
        # Git quotes unusual names. Refuse ambiguous paths instead of interpreting escapes.
        if ($path -match '["\\\x00\r\n]' -or $path -match '(^|/)\.\.(/|$)' -or [IO.Path]::IsPathRooted($path)) {
            throw "Cannot safely classify local path '$path'. No local files were cleaned."
        }
        $normalized = $path.TrimEnd('/')
        $conflicts = @($upstream | Where-Object {
            $_ -eq $normalized -or $_.StartsWith($normalized + '/', [StringComparison]::OrdinalIgnoreCase) -or
            $normalized.StartsWith($_ + '/', [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        if (-not $conflicts) { continue }
        $isGenerated = $false
        foreach ($pattern in $GeneratedPatterns) { if ($path -like $pattern) { $isGenerated = $true; break } }
        if (-not $isGenerated -or $path.EndsWith('/')) {
            throw "Upstream conflicts with local source/personal path '$path' in $Name. Preserve or reconcile it explicitly, then rerun."
        }
        $conflictingGenerated += $path
    }
    # Clean only exact conflicting, allowlisted regenerable files, one literal
    # path per command. This bounds argv and does not touch existing stashes.
    foreach ($path in $conflictingGenerated) {
        $full = Join-Path $directory $path
        $cursor = $full
        while ($cursor -ne $directory) {
            if (Test-Path -LiteralPath $cursor) {
                if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "Generated output crosses a link at '$cursor'; no cleanup is permitted."
                }
            }
            $cursor = [IO.Path]::GetDirectoryName($cursor)
        }
        if ($path -in $changed) {
            Run { git.exe -C $directory restore --source=HEAD --staged --worktree -- ":(top,literal)$path" } | Out-Host
        } elseif (Test-Path -LiteralPath $full -PathType Leaf) {
            Remove-Item -LiteralPath $full -Force
        } else { throw "Conflicting output '$path' is not a regular regenerable file." }
    }
    # Use the verified fetched commit, avoiding a second fetch/race. Git refuses
    # conflicts with source, untracked and ignored files; no fallback replacement.
    if ($branch -ne $BranchName) {
        if ($localBranch.Count -gt 0) { Run { git.exe -C $directory checkout --no-overwrite-ignore $BranchName } | Out-Host }
        else { Run { git.exe -C $directory checkout --no-overwrite-ignore --track -b $BranchName $remoteRef } | Out-Host }
    }
    Run { git.exe -C $directory merge --ff-only --no-autostash --no-overwrite-ignore $remoteRef } | Out-Host
    $after = (Run { git.exe -C $directory rev-parse HEAD }).Trim()
    if ($after -ne $remote) { throw "$Name did not reach the fetched origin/$BranchName." }
    Write-Host "${Name}: $before -> $after (origin/$BranchName)"
    return @{ repository = $Name; path = $directory; branch = $BranchName; before = $before; after = $after; action = 'pull'; backupPath = $null }
}
# Docker is strictly opt-in. No Docker command or installation check runs in local mode.
function Get-DockerType {
    $ErrorActionPreference = 'Continue'
    $value = & docker.exe info --format '{{.OSType}}' 2>$null
    if ($LASTEXITCODE -eq 0) { return ([string]$value).Trim() }
    return ''
}
function Ensure-Docker {
    if (-not $UseDocker) { return }
    if (-not (Get-Command docker.exe -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'The explicitly selected -UseDocker mode needs Docker Desktop. Omit -UseDocker to use local PostgreSQL.'
    }
    $type = Get-DockerType
    if (-not $type) {
        $desktop = Join-Path (Split-Path (Split-Path (Split-Path $DockerExecutable -Parent) -Parent) -Parent) 'Docker Desktop.exe'
        if (-not (Test-Path -LiteralPath $desktop)) { throw 'Start Docker Desktop, then rerun with -UseDocker.' }
        Write-Host 'Starting Docker Desktop and waiting for its engine...'
        Start-Process -FilePath $desktop | Out-Null
        $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
        do {
            Start-Sleep -Seconds 2
            $type = Get-DockerType
        } until ($type -or (Get-Date) -ge $deadline)
    }
    if ($type -ne 'linux') { throw 'Docker is not ready in Linux-container mode. Check Docker Desktop and rerun.' }
}
# The explicit Docker path owns a persistent Linux toolchain, not Windows tools.
function Get-DockerObject([string]$Kind, [string]$Name, [string[]]$Names) {
    if ($Name -cnotin $Names) { return $null }
    return @(Run { docker.exe $Kind inspect $Name } | ConvertFrom-Json)[0]
}
function Get-OtherPostgresEvidence($Containers) {
    foreach ($item in $Containers) {
        $official = $item.Image -match '(?:^|/)(?:postgres|postgis)(?:[:@/]|$)'
        if (-not $official -and $item.Ports -match '->5432/tcp') {
            $container = @(Run { docker.exe container inspect $item.Names } | ConvertFrom-Json)[0]
            $official = @($container.Config.Env | Where-Object { $_ -cmatch '^(PGDATA|POSTGRES_DB|POSTGRES_USER)=' }).Count -gt 0
        }
        if ($official) { "Docker container '$($item.Names)' ($($item.Status), ports: $($item.Ports))" }
    }
    # A portable PostgreSQL server can run without a registered Windows service.
    $services = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.PathName -match '(?i)(?:^|[\\/])(?:pg_ctl|postgres)\.exe(?:["\s]|$)' })
    foreach ($service in $services) { "Windows service '$($service.Name)' ($($service.State))" }
    if (-not $services.Count -and @(Get-Process -Name postgres -ErrorAction SilentlyContinue).Count) { 'Windows postgres.exe process' }
}
function Protect-BootstrapState([string]$Path) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Run { icacls.exe $Path '/inheritance:r' '/grant:r' "${identity}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' } | Out-Null
}
function Save-DockerCredentials($Path, $Secrets) {
    $bootstrapPassword = if ($Secrets.bootstrapPassword) { [string]$Secrets.bootstrapPassword } else { [string]$Secrets.password }
    if (Test-Path -LiteralPath $Path) {
        $saved = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($saved.password -ceq $Secrets.password -and $saved.bootstrapPassword -ceq $bootstrapPassword -and [int]$saved.port -eq $Port) { return }
    }
    $tempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Save-Json $tempPath @{ password = $Secrets.password; bootstrapPassword = $bootstrapPassword; port = $Port }
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tempPath, $Path, [Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($tempPath, $Path) }
    } finally { if ([IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) } }
}
function Copy-DockerWorker([string]$Source, [string]$StateDirectory) {
    $temporary = Join-Path $StateDirectory ("worker-" + [guid]::NewGuid().ToString('N') + '.sh')
    try {
        if (Test-Path -LiteralPath $Source -PathType Leaf) {
            $body = [IO.File]::ReadAllText($Source)
        } else {
            $branch = (($ScalaBranch -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
            Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/bogdanparvu18/scala-testing-lab/$branch/scripts/bootstrap-unix.sh" -OutFile $temporary
            $body = [IO.File]::ReadAllText($temporary)
        }
        if ([string]::IsNullOrWhiteSpace($body)) { throw 'The Linux bootstrap is empty.' }
        [IO.File]::WriteAllText($temporary, $body.Replace("`r`n", "`n").Replace("`r", "`n"), $Utf8)
        # Give concurrent callers independent source and destination files.
        $remote = '/tmp/' + [IO.Path]::GetFileName($temporary)
        Run { docker.exe cp $temporary "${RuntimeContainerName}:$remote" } | Out-Host
        return $remote
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Ensure-DockerImage([string]$Name) {
    $ids = @(Run { docker.exe image ls --quiet --filter "reference=$Name" } | Where-Object { $_ })
    if ($ids.Count -eq 0) {
        Write-Host "Docker image absent; pulling $Name once."
        Run { docker.exe pull $Name } | Out-Host
    }
    $image = @(Run { docker.exe image inspect $Name } | ConvertFrom-Json)[0]
    if ($image.Os -ne 'linux' -or $image.Architecture -notin @('amd64', 'arm64')) {
        throw "Existing image '$Name' is incompatible. Select a compatible Linux image explicitly; no image was replaced."
    }
    return $image
}
function Select-DockerDatabaseImage {
    # PostgreSQL 18 changed the declared volume. Inspect image metadata before
    # choosing a mount, including for a locally retagged major/minor release.
    $refs = @(Run { docker.exe image ls --format '{{.Repository}}:{{.Tag}}' } | Where-Object {
        $_ -cmatch '^(?:(?:docker\.io/)?library/|docker\.io/)?postgres:(?!<none>$).+$'
    } | Sort-Object -Unique)
    $best = $null
    foreach ($ref in $refs) {
        $metadata = @(Run { docker.exe image inspect $ref } | ConvertFrom-Json)[0]
        $majorEnv = @($metadata.Config.Env | Where-Object { $_ -cmatch '^PG_MAJOR=[0-9]+$' })
        $dataEnv = @($metadata.Config.Env | Where-Object { $_ -clike 'PGDATA=/*' })
        if ($majorEnv.Count -ne 1 -or $dataEnv.Count -ne 1) { throw "Cannot establish PostgreSQL version/data location for cached image '$ref'. Inspect and reconcile that image explicitly." }
        $major = [int]$majorEnv[0].Substring(9)
        if ($metadata.Os -ne 'linux' -or $metadata.Architecture -notin @('amd64','arm64') -or $major -lt 15) { continue }
        $dataDir = $dataEnv[0].Substring(7).TrimEnd('/')
        $mounts = @($metadata.Config.Volumes.PSObject.Properties.Name | Where-Object {
            $_ -cin @('/var/lib/postgresql','/var/lib/postgresql/data') -and ($dataDir -ceq $_ -or $dataDir.StartsWith(($_ + '/'), [StringComparison]::Ordinal))
        })
        if ($mounts.Count -ne 1) { throw "Cannot safely place PGDATA '$dataDir' on a declared volume in '$ref'." }
        $choice = @{ name = $ref; major = $major; mount = $mounts[0] }
        if ($ref -ceq 'postgres:16') { return $choice }
        if (-not $best -or $major -gt $best.major) { $best = $choice }
    }
    if ($best) { return $best }
    if ($refs.Count -and -not (Confirm-ToolUpgrade 'PostgreSQL container image' ("Cached: " + ($refs -join ', ') + ". Pull postgres:16 for a new, separate database?"))) {
        throw 'Compatible PostgreSQL image required. Pull a supported official image or approve the image change.'
    }
    $null = Ensure-DockerImage 'postgres:16'
    return @{ name = 'postgres:16'; major = 16; mount = '/var/lib/postgresql/data' }
}
function Invoke-DockerRuntime {
    function Test-ManagedAdminPassword([string]$Password) {
        $savedPassword = $env:PGPASSWORD
        $ErrorActionPreference = 'Continue'
        try {
            $env:PGPASSWORD = $Password
            $reply = @(& docker.exe exec -e PGPASSWORD $databaseContainer.Id psql -X -w -h 127.0.0.1 -p 5432 -U $workerAdmin -d postgres -v ON_ERROR_STOP=1 -Atc 'SELECT 1;' 2>$null)
            return ($LASTEXITCODE -eq 0 -and $reply.Count -eq 1 -and $reply[0] -eq '1')
        } finally { $env:PGPASSWORD = $savedPassword }
    }
    function Get-ManagedAdminPassword {
        if ($workerAdmin -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,62}$') { throw 'Docker administrator recovery requires a simple PostgreSQL role name.' }
        Write-Host "Trying the default PostgreSQL administrator password for '$workerAdmin' in '$ContainerName'."
        if (Test-ManagedAdminPassword 'postgres') { return 'postgres' }
        if ($workerAdmin -ceq $DbUser -and $env:PGPASSWORD -and $env:PGPASSWORD -cne 'postgres' -and (Test-ManagedAdminPassword $env:PGPASSWORD)) { return $env:PGPASSWORD }
        if (-not (Test-BootstrapInteractive)) { throw "Default administrator authentication failed for '$workerAdmin'. Rerun interactively to enter the existing password or recover it inside '$ContainerName'." }
        $secure = Read-Host "Existing administrator password for $workerAdmin (Enter to recover it)" -AsSecureString
        try { $knownPassword = [Net.NetworkCredential]::new('', $secure).Password }
        finally { $secure.Dispose() }
        if ($knownPassword -and (Test-ManagedAdminPassword $knownPassword)) { return $knownPassword }
        Remove-Variable knownPassword -ErrorAction SilentlyContinue
        Write-Host "The administrator password was rejected. Recovery will change only the password of '$workerAdmin' in container '$ContainerName'."
        $consent = Read-Host 'Recover this password using the container PostgreSQL account? [y/N]'
        if (([string]$consent).Trim() -notmatch '^(y|yes|d|da)$') { throw 'PostgreSQL password recovery declined. No password was changed.' }
        # Pin the inspected container ID and prove the authenticated server's
        # identity before changing a password. No HBA/ident rules are relaxed.
        $identitySql = "SELECT json_build_object('role',current_user,'data',current_setting('data_directory'),'port',current_setting('port'),'admin',rolcanlogin AND (rolsuper OR rolcreaterole)) FROM pg_catalog.pg_roles WHERE rolname=current_user;"
        try {
            $identity = (Run { docker.exe exec --user postgres -e PGPASSFILE=/dev/null -e PGPASSWORD= $databaseContainer.Id psql -X -w -h /var/run/postgresql -p 5432 -U $workerAdmin -d postgres -v ON_ERROR_STOP=1 -Atc $identitySql }) | ConvertFrom-Json
        } catch { throw "Local socket authentication inside '$ContainerName' is unavailable for '$workerAdmin'. Use an existing database administrator or the container's configured recovery procedure. Authentication configuration and passwords were not changed." }
        $expectedData = @($databaseContainer.Config.Env | Where-Object { $_ -clike 'PGDATA=*' } | ForEach-Object { $_.Substring(7).TrimEnd('/') })
        if ($expectedData.Count -ne 1 -or $identity.role -cne $workerAdmin -or $identity.data.TrimEnd('/') -cne $expectedData[0] -or $identity.port -ne '5432' -or -not $identity.admin) {
            throw 'Docker recovery identity check failed. The selected role/data directory does not match the inspected container; no password was changed.'
        }
        $first = Read-Host "New PostgreSQL password for $workerAdmin" -AsSecureString
        $second = Read-Host 'Confirm the new PostgreSQL password' -AsSecureString
        $savedEncoding = $OutputEncoding
        try {
            $newPassword = [Net.NetworkCredential]::new('', $first).Password
            $confirmation = [Net.NetworkCredential]::new('', $second).Password
            if (-not $newPassword -or $newPassword -match '[\r\n\x00]' -or $newPassword -cne $confirmation) { throw 'Passwords must be nonempty, match exactly, and contain no newline. No password was changed.' }
            $OutputEncoding = New-Object Text.UTF8Encoding($false)
            # Without a Docker TTY, psql reads its two masked password prompts
            # from stdin and sends a verifier rather than plaintext ALTER ROLE.
            $ErrorActionPreference = 'Continue'
            "$newPassword`n$newPassword" | & docker.exe exec -i --user postgres -e PGPASSFILE=/dev/null -e PGPASSWORD= -e PGCLIENTENCODING=UTF8 $databaseContainer.Id psql -X -w -h /var/run/postgresql -p 5432 -U $workerAdmin -d postgres -v ON_ERROR_STOP=1 -c '\password' *> $null
            if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL password recovery did not complete. Check the selected container and retry.' }
            if (-not (Test-ManagedAdminPassword $newPassword)) { throw 'The password command completed, but TCP authentication with the new password failed. Check the server authentication policy before continuing.' }
            if (Test-ManagedAdminPassword ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'))) {
                throw 'The password was updated, but the current TCP authentication policy also accepts an incorrect password. Password authentication could not be verified; review the server policy before continuing.'
            }
            Write-Host "Recovered PostgreSQL administrator '$workerAdmin'; authenticated TCP login passed."
            return $newPassword
        } finally {
            $OutputEncoding = $savedEncoding
            $first.Dispose(); $second.Dispose()
            Remove-Variable newPassword, confirmation -ErrorAction SilentlyContinue
        }
    }
    foreach ($name in @($ContainerName, $VolumeName, $RuntimeContainerName, $RuntimeVolumeName, $RuntimeCacheVolumeName)) {
        if ($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]+$') { throw "Unsupported Docker object name '$name'." }
    }
    if ($ContainerName -eq $RuntimeContainerName -or @($VolumeName, $RuntimeVolumeName, $RuntimeCacheVolumeName | Select-Object -Unique).Count -ne 3) {
        throw 'Database/runtime container names and database/workspace/cache volume names must be distinct.'
    }
    if ($RuntimeImage -match '[\s\x00]' -or -not $RuntimeImage) { throw 'Invalid runtime image name.' }
    $workerEnvironment = @('-e', 'PGPASSWORD')
    if (-not $DockerToolSearchPath -and $env:AURORA_DOCKER_TOOL_SEARCH_PATH) { $DockerToolSearchPath = @($env:AURORA_DOCKER_TOOL_SEARCH_PATH -split ':') }
    foreach ($directory in $DockerToolSearchPath) {
        if (-not $directory.StartsWith('/') -or $directory -match '[:\r\n\x00]') { throw '-DockerToolSearchPath requires absolute Linux directories without colon or newline.' }
    }
    if ($DockerToolSearchPath) { $workerEnvironment += @('-e', ('AURORA_TOOL_SEARCH_PATH=' + ($DockerToolSearchPath -join ':'))) }
    $Root = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $Root)) { New-Item -ItemType Directory -Path $Root | Out-Null }
    # --Docker explicitly selects the Linux workspace. Report any native copies
    # so the location change is visible; never copy or modify those repositories.
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Root)
    while ($pending.Count) {
        $current = $pending.Pop()
        $gitConfig = Join-Path $current '.git\config'
        if (Test-Path -LiteralPath $gitConfig -PathType Leaf) {
            if ((Get-Content -LiteralPath $gitConfig -Raw -ErrorAction Stop) -match 'bogdanparvu18[/:](scala-testing-lab|langium_dsl_lab)(\.git)?(?:[\s\r\n]|$)') {
                Write-Host "Native repository retained at '$current'; --Docker selects the separate persistent Linux workspace."
            }
            continue
        }
        foreach ($entry in @(Get-ChildItem -LiteralPath $current -Directory -Force -ErrorAction Stop)) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($entry.Name -in @('scala-testing-lab', 'langium_dsl_lab')) {
                Write-Host "Native repository retained at '$($entry.FullName)'; --Docker selects the separate persistent Linux workspace."
                continue
            }
            if ($entry.Name -notin @('.git', 'node_modules', 'target', '.metals', '.bloop', '.bsp', 'data', 'downloads', 'backups')) { $pending.Push($entry.FullName) }
        }
    }
    # One snapshot per kind for this decision; newly created objects are inspected directly.
    $containers = @(Run { docker.exe container ls -a --format '{{json .}}' } | ForEach-Object { $_ | ConvertFrom-Json })
    $containerNames = @($containers | ForEach-Object { $_.Names })
    $volumeNames = @(Run { docker.exe volume ls --format '{{.Name}}' })
    $databaseContainer = $null
    if (-not $DockerUseHostPostgres) {
        $databaseContainer = Get-DockerObject 'container' $ContainerName $containerNames
        if (-not $databaseContainer -and $VolumeName -cin $volumeNames) { throw "Database volume '$VolumeName' exists without its matching container. Recover its original container/credentials." }
        if (-not $databaseContainer -and -not $DockerUseManagedPostgres) {
            try { $otherServers = @(Get-OtherPostgresEvidence $containers) }
            catch { throw "Windows PostgreSQL service discovery was inconclusive. Select -DockerUseHostPostgres or -DockerUseManagedPostgres explicitly. $($_.Exception.Message)" }
            if ($otherServers.Count) {
                throw ("Existing PostgreSQL detected: " + ($otherServers -join ', ') + ". Start the selected server and make its port available on loopback, then use -DockerUseHostPostgres with its port/database/user, or -DockerUseManagedPostgres to create a separate server.")
            }
        }
    }
    $databaseWasStopped = ($null -ne $databaseContainer -and -not $databaseContainer.State.Running)
    $runtimeContainer = Get-DockerObject 'container' $RuntimeContainerName $containerNames
    if (-not $runtimeContainer -and ($RuntimeVolumeName -cin $volumeNames -or $RuntimeCacheVolumeName -cin $volumeNames)) {
        throw 'The workspace/cache exists without its runtime. Recover the matching container explicitly.'
    }
    if ($runtimeContainer -and -not $RuntimeImageSpecified) { $RuntimeImage = $runtimeContainer.Config.Image }
    $dockerState = Join-Path $Root 'docker-runtime\state'
    New-Item -ItemType Directory -Path $dockerState -Force | Out-Null
    Protect-BootstrapState $dockerState
    $runtimeHost = if ($DockerUseHostPostgres -and $PgHost -eq '::1') { '::1' } else { '127.0.0.1' }
    $runtimePort = if ($DockerUseHostPostgres) { $Port } else { 5432 }
    if ($DockerUseHostPostgres) {
        if (-not $env:PGPASSWORD -and $DbUser -ceq 'scala_lab') { $env:PGPASSWORD = 'aurora' }
        if (-not $env:PGPASSWORD) {
            if (-not (Test-BootstrapInteractive)) { throw 'Supply the existing database password via PGPASSWORD for a noninteractive run.' }
            $secure = Read-Host "Existing PostgreSQL password for $DbUser" -AsSecureString
            try { $env:PGPASSWORD = [Net.NetworkCredential]::new('', $secure).Password }
            finally { $secure.Dispose() }
        }
        if (-not $env:PGPASSWORD) { throw 'An existing database password is required.' }
    } else {
        $secretPath = Join-Path $dockerState 'secrets.json'
        $secrets = $null
        if ($databaseContainer -and (Test-Path -LiteralPath $secretPath)) { $secrets = Get-Content -LiteralPath $secretPath -Raw | ConvertFrom-Json }
        if ($databaseContainer -and -not $secrets) {
            $legacyPaths = @((Join-Path $Root 'medication-lab-setup\automatic\state\secrets.json'))
            if ($SetupPath) { $legacyPaths = @((Join-Path $SetupPath 'state\secrets.json')) + $legacyPaths }
            foreach ($candidate in $legacyPaths) {
                if (Test-Path -LiteralPath $candidate) { $secrets = Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json; break }
            }
        }
        if (-not $secrets -and $databaseContainer) {
            $existingPasswords = @($databaseContainer.Config.Env | Where-Object { $_ -like 'POSTGRES_PASSWORD=*' })
            if ($existingPasswords.Count -ne 1 -or -not $existingPasswords[0].Substring(18)) {
                throw 'Existing database container has no recoverable password. Supply its original setup credentials; no password was generated or reset.'
            }
            $secrets = @{ password = $existingPasswords[0].Substring(18); port = $Port }
        }
        if (-not $secrets) { $secrets = @{ password = $(if ($env:PGPASSWORD) { $env:PGPASSWORD } else { 'aurora' }); port = $Port } }
        $secrets = @{ password = [string]$secrets.password; bootstrapPassword = $(if ($secrets.bootstrapPassword) { [string]$secrets.bootstrapPassword } else { [string]$secrets.password }); port = $secrets.port }
        if (-not $secrets.password -or ($secrets.port -and [int]$secrets.port -ne $Port)) { throw 'Stored Docker credentials/port do not match the selected configuration.' }
        if ($databaseContainer) {
            $existingUsers = @($databaseContainer.Config.Env | Where-Object { $_ -clike 'POSTGRES_USER=*' } | ForEach-Object { $_.Substring(14) })
            if ($existingUsers.Count -ne 1 -or $existingUsers[0] -cnotin @('scala_lab', 'rxnorm_lab')) { throw 'Existing managed PostgreSQL has an unrecognized role. Select its connection explicitly with -DockerUseHostPostgres.' }
            if ($DockerDbUserSpecified -and $DbUser -cne $existingUsers[0]) { throw "Existing managed PostgreSQL uses '$($existingUsers[0])', not '$DbUser'. Omit -DbUser to reuse its original account; no account or data was changed." }
            $DbUser = $existingUsers[0]
            if ($DbUser -ceq 'rxnorm_lab') { Write-Host "Reusing the legacy Docker account 'rxnorm_lab' and its stored credentials. Existing RxNorm data and ownership are preserved." }
            $bindings = @($databaseContainer.HostConfig.PortBindings.'5432/tcp')
            $mounts = @($databaseContainer.Mounts | Where-Object { $_.Destination -in @('/var/lib/postgresql/data', '/var/lib/postgresql') })
            $pgData = @($databaseContainer.Config.Env | Where-Object { $_ -clike 'PGDATA=*' } | ForEach-Object { $_.Substring(7).TrimEnd('/') })
            if ($databaseContainer.Config.Image -notmatch '^(?:(?:docker\.io/)?library/|docker\.io/)?postgres(?:[:@]|$)' -or
                $pgData.Count -ne 1 -or $mounts.Count -ne 1 -or ($pgData[0] -cne $mounts[0].Destination -and -not $pgData[0].StartsWith($mounts[0].Destination + '/', [StringComparison]::Ordinal)) -or $bindings.Count -ne 1 -or
                $bindings[0].HostIp -ne '127.0.0.1' -or $bindings[0].HostPort -ne [string]$Port -or
                $mounts[0].Type -ne 'volume' -or $mounts[0].Name -ne $VolumeName -or -not $mounts[0].RW -or
                "POSTGRES_USER=$DbUser" -cnotin $databaseContainer.Config.Env -or 'POSTGRES_DB=rxnorm_public' -notin $databaseContainer.Config.Env -or
                "POSTGRES_PASSWORD=$($secrets.bootstrapPassword)" -cnotin $databaseContainer.Config.Env -or
                $databaseContainer.HostConfig.NetworkMode -notin @('default', 'bridge')) {
                throw 'Existing PostgreSQL container has incompatible image, mounts, network, port, or credentials. No container/volume was replaced.'
            }
        }
        if (-not $databaseContainer -and $DbUser -cne 'scala_lab') { throw 'New managed Docker databases use scala_lab. rxnorm_lab is supported only for existing legacy containers.' }
    }
    # Validate the runtime before starting or creating any service.
    if ($runtimeContainer) {
        $workMount = @($runtimeContainer.Mounts | Where-Object { $_.Destination -eq '/workspace' })
        $cacheMount = @($runtimeContainer.Mounts | Where-Object { $_.Destination -eq '/root' })
        $expectedNetwork = if ($DockerUseHostPostgres) { 'host' } elseif ($databaseContainer) { 'container:' + $databaseContainer.Id } else { '' }
        if (-not $expectedNetwork -or $runtimeContainer.Config.Image -cne $RuntimeImage -or
            $runtimeContainer.Config.Labels.'aurora.runtime.schema' -ne '1' -or $runtimeContainer.Config.Labels.'aurora.host.root' -ne $Root -or
            $workMount.Count -ne 1 -or $workMount[0].Type -ne 'volume' -or $workMount[0].Name -ne $RuntimeVolumeName -or -not $workMount[0].RW -or
            $cacheMount.Count -ne 1 -or $cacheMount[0].Type -ne 'volume' -or $cacheMount[0].Name -ne $RuntimeCacheVolumeName -or -not $cacheMount[0].RW -or
            $runtimeContainer.HostConfig.NetworkMode -ne $expectedNetwork -or
            "PGHOST=$runtimeHost" -cnotin $runtimeContainer.Config.Env -or "PGPORT=$runtimePort" -cnotin $runtimeContainer.Config.Env -or
            "PGDATABASE=$Database" -cnotin $runtimeContainer.Config.Env -or "PGUSER=$DbUser" -cnotin $runtimeContainer.Config.Env -or
            (-not $DockerUseHostPostgres -and "PGPASSWORD=$($secrets.bootstrapPassword)" -cnotin $runtimeContainer.Config.Env)) {
            throw 'Existing Linux runtime does not match its image, workspace/cache mounts, database namespace, host Root, or credentials. Recover/select the original configuration; no runtime was replaced.'
        }
    }
    if (-not $DockerUseHostPostgres) {
        if (-not $databaseContainer) { $seed = Select-DockerDatabaseImage }
        Save-DockerCredentials $secretPath $secrets
        $env:POSTGRES_PASSWORD = [string]$secrets.bootstrapPassword
        if (-not $env:PGPASSWORD) { $env:PGPASSWORD = [string]$secrets.password }
        if (-not $databaseContainer) {
            Write-Host "Using PostgreSQL image $($seed.name); mounting $VolumeName at $($seed.mount)."
            Run { docker.exe run -d --restart unless-stopped --name $ContainerName -e "POSTGRES_USER=$DbUser" -e POSTGRES_DB=rxnorm_public -e POSTGRES_PASSWORD -p "127.0.0.1:${Port}:5432" -v "${VolumeName}:$($seed.mount)" $seed.name } | Out-Host
            $databaseContainer = @(Run { docker.exe container inspect $ContainerName } | ConvertFrom-Json)[0]
        } elseif (-not $databaseContainer.State.Running) { Run { docker.exe start $ContainerName } | Out-Host }
        $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
        do {
            $probePreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & docker.exe exec $ContainerName pg_isready -h 127.0.0.1 -p 5432 -U $DbUser -d rxnorm_public -t 3 *> $null
            $databaseReady = ($LASTEXITCODE -eq 0)
            $ErrorActionPreference = $probePreference
            if (-not $databaseReady) { Start-Sleep -Seconds 1 }
        } until ($databaseReady -or (Get-Date) -ge $deadline)
        if (-not $databaseReady) { throw 'PostgreSQL container did not become ready; no runtime tools were installed.' }
        $serverVersion = $null
        try { $serverVersion = Run { docker.exe exec -e PGPASSWORD $ContainerName psql -X -w -h 127.0.0.1 -U $DbUser -d rxnorm_public -v ON_ERROR_STOP=1 -Atc 'SHOW server_version_num;' } }
        catch {
            $workerAdmin = if (-not $DockerPgAdminUserSpecified) { $DbUser } else { $PgAdminUser }
            $env:AURORA_PG_ADMIN_PASSWORD = Get-ManagedAdminPassword
            if ($workerAdmin -ceq $DbUser) {
                $env:PGPASSWORD = $env:AURORA_PG_ADMIN_PASSWORD
                $secrets.password = $env:PGPASSWORD
                Save-DockerCredentials $secretPath $secrets
                try { $serverVersion = Run { docker.exe exec -e PGPASSWORD $databaseContainer.Id psql -X -w -h 127.0.0.1 -p 5432 -U $DbUser -d rxnorm_public -v ON_ERROR_STOP=1 -Atc 'SHOW server_version_num;' } }
                catch { Write-Host 'Administrator login is verified. The Linux worker will check the missing database or its access permissions.' }
            }
            $workerEnvironment += @('-e', 'AURORA_PG_ADMIN_PASSWORD')
        }
        if ($serverVersion) { Assert-ServerVersion $serverVersion }
    }
    if (-not $runtimeContainer) {
        $null = Ensure-DockerImage $RuntimeImage
        $network = if ($DockerUseHostPostgres) { 'host' } else { 'container:' + $databaseContainer.Id }
        $passwordOption = @()
        if ($DockerUseHostPostgres) {
            # Probe the same loopback path Scala permits before creating persistent volumes.
            try { Run { docker.exe run --rm --network host --entrypoint timeout $RuntimeImage 5 bash -c 'true > /dev/tcp/$1/$2' _ $runtimeHost $Port } | Out-Null }
            catch { throw "Cannot reach the selected Windows database on port $Port from Linux. Enable host networking under Docker Desktop > Settings > Resources > Network (4.34+), check PostgreSQL, then retry." }
        } else { $passwordOption = @('-e', 'PGPASSWORD') }
        $executionPassword = $env:PGPASSWORD
        try {
            # Preserve the original container configuration; an explicit password
            # override is passed to this worker execution only.
            if (-not $DockerUseHostPostgres) { $env:PGPASSWORD = [string]$secrets.bootstrapPassword }
            Run { docker.exe run -d --restart unless-stopped --name $RuntimeContainerName --network $network --label 'aurora.runtime.schema=1' --label "aurora.host.root=$Root" -v "${RuntimeVolumeName}:/workspace" -v "${RuntimeCacheVolumeName}:/root" -e "PGHOST=$runtimeHost" -e "PGPORT=$runtimePort" -e "PGDATABASE=$Database" -e "PGUSER=$DbUser" @passwordOption $RuntimeImage sleep infinity } | Out-Host
        } finally { $env:PGPASSWORD = $executionPassword }
    } elseif (-not $runtimeContainer.State.Running) { Run { docker.exe start $RuntimeContainerName } | Out-Host }
    elseif ($databaseWasStopped) {
        # A running sibling retains the old namespace when the database restarts.
        # Restart the same container to join the restored database namespace.
        Write-Host 'Rejoining the restarted database network namespace in the existing Linux runtime.'
        Run { docker.exe restart $RuntimeContainerName } | Out-Host
    }
    Write-Host "Linux workspace: Docker volume '$RuntimeVolumeName', mounted at /workspace in '$RuntimeContainerName'. Native repositories are not copied."
    Write-Host "Persistent caches: '$RuntimeCacheVolumeName'. Database: $Database at ${runtimeHost}:$runtimePort inside the runtime."
    $remoteWorker = Copy-DockerWorker (Join-Path $PSScriptRoot 'bootstrap-unix.sh') $dockerState
    try {
        $workerOptions = @('--container-runtime', '--root', '/workspace', '--scala-branch', $ScalaBranch, '--langium-branch', $LangiumBranch, '--startup-timeout', [string]$StartupTimeoutSeconds)
        $workerAdmin = if (-not $DockerUseHostPostgres -and -not $DockerPgAdminUserSpecified) { $DbUser } else { $PgAdminUser }
        $workerOptions += @('--pg-admin-user', $workerAdmin)
        if ($ProvisionDatabase) { $workerOptions += '--provision-database' }
        $terminal = @()
        if ($AllowToolUpgrade) { $workerOptions += '--allow-tool-upgrade' }
        if ((Test-BootstrapInteractive) -and -not [Console]::IsOutputRedirected) {
            $terminal = @('-i', '-t')
        } else { $workerOptions += '--non-interactive' }
        Run { docker.exe exec @terminal @workerEnvironment $RuntimeContainerName bash $remoteWorker @workerOptions }
    } finally {
        Remove-Item Env:AURORA_PG_ADMIN_PASSWORD -ErrorAction SilentlyContinue
        & docker.exe exec $RuntimeContainerName rm -f $remoteWorker | Out-Null
    }
    # The Linux worker has already checked builds, SQL/RxNorm and the language server.
    if (-not $NoEditor) {
        $codeVersion = @(Run { code.cmd --version })[0]
        $editorCheck = "const fs=require('node:fs');const {createRequire}=require('node:module');const root='/workspace/repos/langium_dsl_lab/clinical-dsl-demo';const req=createRequire(root+'/package.json');const semver=req('semver');const pkg=JSON.parse(fs.readFileSync(root+'/packages/extension/package.json','utf8'));if(!semver.satisfies(process.argv[2],pkg.engines.vscode))throw Error('Installed VS Code '+process.argv[2]+' does not satisfy '+pkg.engines.vscode);"
        $linuxNodePath = Run { docker.exe exec $RuntimeContainerName bash -lc 'command -v node' }
        if (-not $linuxNodePath -or $linuxNodePath -notmatch '^/[^\r\n]+$') { throw 'Could not locate the verified Linux Node executable for editor checks.' }
        Run { $editorCheck | docker.exe exec -i $RuntimeContainerName $linuxNodePath - $codeVersion } | Out-Host
        $extensions = @(Run { code.cmd --list-extensions })
        if ('ms-vscode-remote.remote-containers' -notin $extensions) {
            Write-Host 'Installing missing VS Code Dev Containers extension.'
            Run { code.cmd --install-extension ms-vscode-remote.remote-containers } | Out-Host
            $extensions = @(Run { code.cmd --list-extensions })
            if ('ms-vscode-remote.remote-containers' -notin $extensions) { throw 'Dev Containers extension installation did not pass rediscovery.' }
        }
        $descriptor = @{ containerName = '/' + $RuntimeContainerName } | ConvertTo-Json -Compress
        $hex = ([Text.Encoding]::UTF8.GetBytes($descriptor) | ForEach-Object { $_.ToString('x2') }) -join ''
        $remote = 'attached-container+' + $hex
        Run { code.cmd --new-window --remote $remote "--extensionDevelopmentPath=/workspace/repos/langium_dsl_lab/clinical-dsl-demo/packages/extension" '/workspace' '/workspace/medication-lab-setup/automatic/aspirin-demo.clinical' } | Out-Host
        Write-Host 'VS Code attachment requested; extension activation must be checked in the attached editor.'
    }
    Write-Host "READY: persistent Linux runtime and authenticated PostgreSQL checks passed. Health: ${RuntimeContainerName}:/workspace/medication-lab-setup/automatic/state/health.json"
}

# Password recovery uses Windows identity authentication, never trust rules.
function Assert-PostgresRecoveryAdministrator {
    if ($env:OS -ne 'Windows_NT' -or -not (Test-BootstrapInteractive)) { throw 'PostgreSQL password recovery requires an interactive Windows terminal.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Open PowerShell as Administrator and rerun with -RecoverPostgresPassword to reset the selected local PostgreSQL password.' }
}
function Get-PostgresRecoveryDirectory {
    Join-Path $Root 'postgres-password-recovery'
}
function Protect-PostgresRecoveryObject([string]$Path, [switch]$Directory) {
    $acl = if ($Directory) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
    $acl.SetAccessRuleProtection($true, $false)
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $acl.SetOwner($administrators)
    foreach ($sid in @(([Security.Principal.SecurityIdentifier]::new('S-1-5-18')), $administrators)) {
        $inheritance = if ($Directory) { 'ContainerInherit, ObjectInherit' } else { 'None' }
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', $inheritance, 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Assert-PostgresRecoveryJournalAcl([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    $allowed = @('S-1-5-18', 'S-1-5-32-544')
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $allowed) { throw "The recovery journal is not owned by Windows Administrators/SYSTEM: $Path. Do not use an untrusted recovery record." }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $rule.IdentityReference.Value -notin $allowed) { throw "The recovery journal permits access by another identity: $Path. Recovery stopped before modifying PostgreSQL." }
    }
}
function Save-PostgresRecoveryJournal([string]$Path, $Journal) {
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Journal | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        Protect-PostgresRecoveryObject $temporary
        [IO.File]::Move($temporary, $Path)
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Assert-PostgresRecoveryPath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path)) { throw "Password recovery requires an absolute local path: $Path" }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\')) { throw 'Password recovery supports local drives only.' }
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Password recovery refuses a linked path: $current" }
        }
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) { break }
        $current = $parent
    }
    return $full
}
function Split-PostgresServiceCommand([string]$Command) {
    if (-not ('AuroraPostgresCommandLine' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AuroraPostgresCommandLine {
    [DllImport("shell32.dll", SetLastError=true)] static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string command, out int count);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr value);
    public static string[] Split(string command) {
        int count; IntPtr result=CommandLineToArgvW(command, out count);
        if(result==IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        try { var args=new string[count]; for(int i=0;i<count;i++) args[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(result,i*IntPtr.Size)); return args; }
        finally { LocalFree(result); }
    }
}
'@
    }
    [AuroraPostgresCommandLine]::Split($Command)
}
function Get-LocalPostgresRecoveryTarget {
    if ($PgHost -notin @('127.0.0.1', 'localhost', '::1')) { throw 'Password recovery applies only to the selected local PostgreSQL server.' }
    if ($PgAdminUser -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,62}$') { throw 'Password recovery requires a simple PostgreSQL administrator role name.' }
    $bin = Assert-PostgresRecoveryPath (Split-Path -Parent $PsqlPath)
    $server = Join-Path $bin 'postgres.exe'
    if (-not (Test-Path -LiteralPath $server -PathType Leaf)) { throw 'Password recovery requires the server executable belonging to the selected PostgreSQL installation.' }
    $null = Assert-PostgresRecoveryPath $server
    $null = Assert-PostgresRecoveryPath $PsqlPath
    $managed = Get-ManagedPostgresCluster
    $service = $null; $configDirectory = $null
    if ($managed -and -not $managed.serviceName -and -not $PgServiceName) {
        if ([IO.Path]::GetFullPath([string]$managed.binDirectory) -ine $bin -or [int]$managed.port -ne $Port) { throw 'The managed PostgreSQL cluster does not match the selected binary or port.' }
        $configDirectory = [string]$managed.dataDirectory
    } else {
        $services = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object {
            if ($PgServiceName) { $_.Name -eq $PgServiceName }
            else { $_.PathName -match '(?i)pg_ctl[.]exe' }
        } | Where-Object {
            $argv = @(Split-PostgresServiceCommand ([string]$_.PathName))
            $argv.Count -gt 0 -and [IO.Path]::GetFullPath($argv[0]) -ieq (Join-Path $bin 'pg_ctl.exe')
        })
        if ($services.Count -ne 1) { throw "Password recovery requires one matching local PostgreSQL service. Found $($services.Count); select its exact -PgServiceName." }
        $service = $services[0]
        if ($service.State -ne 'Running' -or [int]$service.ProcessId -le 0) { throw 'Start the selected PostgreSQL service before password recovery.' }
        $argv = @(Split-PostgresServiceCommand ([string]$service.PathName))
        if ($argv.Count -lt 2 -or $argv[1] -cne 'runservice') { throw 'Unsupported PostgreSQL service command for automatic recovery.' }
        for ($i = 2; $i -lt $argv.Count; $i++) {
            switch -CaseSensitive ($argv[$i]) {
                '-D' { $i++; if ($i -ge $argv.Count -or $configDirectory) { throw 'Ambiguous PostgreSQL service data directory.' }; $configDirectory = $argv[$i] }
                '-N' { $i++; if ($i -ge $argv.Count -or $argv[$i] -cne $service.Name) { throw 'PostgreSQL service name does not match its command.' } }
                '-t' { $i++; if ($i -ge $argv.Count -or $argv[$i] -notmatch '^[0-9]+$') { throw 'Invalid PostgreSQL service timeout.' } }
                '-w' { }
                '-s' { }
                default { throw "Unsupported PostgreSQL service option '$($argv[$i])'. Recover this customized service through its administrator." }
            }
        }
    }
    if (-not $configDirectory) { throw 'Cannot identify the selected PostgreSQL configuration directory.' }
    $configDirectory = Assert-PostgresRecoveryPath $configDirectory
    $values = @{}
    foreach ($setting in @('data_directory', 'hba_file', 'ident_file', 'port')) {
        # -C must be first: PostgreSQL permits this read-only query while elevated.
        $answer = @(Run { & $server -C $setting -D $configDirectory })
        if ($answer.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$answer[0])) { throw "Cannot establish PostgreSQL $setting for recovery." }
        $values[$setting] = ([string]$answer[0]).Trim()
    }
    if ([int]$values.port -ne $Port) { throw 'The service configuration port does not match the selected PostgreSQL endpoint.' }
    $data = Assert-PostgresRecoveryPath $values.data_directory
    $hba = Assert-PostgresRecoveryPath $values.hba_file
    $ident = Assert-PostgresRecoveryPath $values.ident_file
    if ($hba -ieq $ident) { throw 'PostgreSQL HBA and ident files must be distinct.' }
    foreach ($file in @($hba, $ident, (Join-Path $data 'PG_VERSION'), (Join-Path $data 'postmaster.pid'))) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "The initialized PostgreSQL instance is missing $file." }
        $null = Assert-PostgresRecoveryPath $file
    }
    $pidLines = [IO.File]::ReadAllLines((Join-Path $data 'postmaster.pid'))
    if ($pidLines.Length -lt 4 -or $pidLines[0] -notmatch '^[1-9][0-9]*$' -or $pidLines[3] -notmatch '^[0-9]+$' -or [int]$pidLines[3] -ne $Port -or [IO.Path]::GetFullPath($pidLines[1]) -ine $data) { throw 'PostgreSQL process metadata does not match the selected data directory and port.' }
    $serverProcessId = [int]$pidLines[0]
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $serverProcessId" -ErrorAction Stop
    if (-not $process -or [IO.Path]::GetFullPath([string]$process.ExecutablePath) -ine $server) { throw 'The PostgreSQL listener is not the verified server executable.' }
    $recoveryHost = if ($PgHost -eq '::1') { '::1' } else { '127.0.0.1' }
    $addresses = if ($PgHost -eq '::1') { @('::1', '::') } else { @('127.0.0.1', '0.0.0.0') }
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop | Where-Object { $_.LocalAddress -in $addresses })
    if (-not $listeners.Count -or @($listeners | Where-Object { [int]$_.OwningProcess -ne $serverProcessId }).Count) { throw 'Cannot prove the selected loopback listener belongs to the verified PostgreSQL process.' }
    if ($PgHost -eq 'localhost') {
        $ipv6 = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop | Where-Object { $_.LocalAddress -in @('::1', '::') })
        if (@($ipv6 | Where-Object { [int]$_.OwningProcess -ne $serverProcessId }).Count) { throw 'IPv4 and the selected localhost endpoint do not identify the same PostgreSQL server.' }
    }
    if ($service) {
        $ancestor = $process; $matchesService = $false
        for ($depth = 0; $depth -lt 5 -and $ancestor; $depth++) {
            if ([int]$ancestor.ProcessId -eq [int]$service.ProcessId) { $matchesService = $true; break }
            $parentId = [int]$ancestor.ParentProcessId
            if ($parentId -le 0) { break }
            $ancestor = Get-CimInstance Win32_Process -Filter "ProcessId = $parentId" -ErrorAction Stop
        }
        if (-not $matchesService) { throw 'The PostgreSQL listener does not belong to the selected Windows service.' }
    } elseif ([IO.Path]::GetFullPath([string]$managed.dataDirectory) -ine $data) { throw 'The running server is not the owned managed PostgreSQL cluster.' }
    return @{ bin = $bin; data = $data; hba = $hba; ident = $ident; host = $recoveryHost; port = $Port; processId = $serverProcessId; service = $(if ($service) { $service.Name } else { '' }) }
}
function Get-PostgresRecoveryHash([byte[]]$Bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToBase64String($algorithm.ComputeHash($Bytes)) } finally { $algorithm.Dispose() }
}
function Enter-PostgresRecoveryPrivilege([ValidateSet('SeRestorePrivilege', 'SeSecurityPrivilege')][string]$Name) {
    if ($env:OS -ne 'Windows_NT') { throw 'PostgreSQL file-security preservation requires Windows.' }
    if (-not ('AuroraPostgresRecoveryPrivilege' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public sealed class AuroraPostgresRecoveryPrivilege : IDisposable {
    [StructLayout(LayoutKind.Sequential)]
    private struct Luid { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)]
    private struct TokenPrivileges { public uint Count; public Luid Luid; public uint Attributes; }
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentThread();
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool OpenThreadToken(IntPtr thread, uint access, bool asSelf, out IntPtr token);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool LookupPrivilegeValue(string system, string name, out Luid luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, uint length, out TokenPrivileges previous, out uint returnedLength);
    [DllImport("advapi32.dll", EntryPoint = "AdjustTokenPrivileges", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool RestoreTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, uint length, IntPtr previous, IntPtr returnedLength);

    private IntPtr token;
    private TokenPrivileges previous;
    private readonly string name;
    private AuroraPostgresRecoveryPrivilege(string privilege) {
        if (privilege != "SeRestorePrivilege" && privilege != "SeSecurityPrivilege") throw new ArgumentException("Unsupported PostgreSQL recovery privilege.", "privilege");
        name = privilege;
        if (!OpenThreadToken(GetCurrentThread(), 0x28, true, out token)) {
            int error = Marshal.GetLastWin32Error();
            if (error != 1008) throw new Win32Exception(error, "Cannot open the effective Windows token.");
            if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot open the Windows process token.");
        }
        try {
            Luid luid;
            if (!LookupPrivilegeValue(null, name, out luid)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot resolve " + name + ".");
            TokenPrivileges desired = new TokenPrivileges { Count = 1, Luid = luid, Attributes = 2 };
            uint returnedLength;
            TokenPrivileges saved;
            bool adjusted = AdjustTokenPrivileges(token, false, ref desired, (uint)Marshal.SizeOf(typeof(TokenPrivileges)), out saved, out returnedLength);
            int error = Marshal.GetLastWin32Error();
            // TRUE with ERROR_NOT_ALL_ASSIGNED also means the right is absent.
            if (!adjusted || error != 0) throw new Win32Exception(error, "Cannot enable " + name + " for PostgreSQL file-security preservation.");
            previous = saved;
        } catch {
            try { Restore(); } finally { CloseHandle(token); token = IntPtr.Zero; }
            throw;
        }
    }
    public static IDisposable Enter(string name) { return new AuroraPostgresRecoveryPrivilege(name); }
    private void Restore() {
        if (previous.Count == 0) return;
        bool restored = RestoreTokenPrivileges(token, false, ref previous, 0, IntPtr.Zero, IntPtr.Zero);
        int error = Marshal.GetLastWin32Error();
        if (!restored || error != 0) throw new Win32Exception(error, "Cannot restore the previous state of " + name + ".");
        previous.Count = 0;
    }
    public void Dispose() {
        if (token == IntPtr.Zero) return;
        try { Restore(); } finally { CloseHandle(token); token = IntPtr.Zero; }
    }
}
'@ -ErrorAction Stop
    }
    return [AuroraPostgresRecoveryPrivilege]::Enter($Name)
}
function Get-PostgresRecoveryFileSecurity([string]$Path) {
    $scope = Enter-PostgresRecoveryPrivilege 'SeSecurityPrivilege'
    try {
        $acl = Get-Acl -LiteralPath $Path -Audit -ErrorAction Stop
        return $acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
    } finally { $scope.Dispose() }
}
function Get-PostgresRecoverySecurityPart([string]$Sddl, [ValidateSet('All', 'Access', 'AccessAudit', 'OwnerGroupAccess', 'OwnerGroup')][string]$Part = 'All') {
    $sections = switch ($Part) {
        'All' { [Security.AccessControl.AccessControlSections]::All }
        'Access' { [Security.AccessControl.AccessControlSections]::Access }
        'AccessAudit' { [Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Audit }
        'OwnerGroupAccess' { [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group -bor [Security.AccessControl.AccessControlSections]::Access }
        'OwnerGroup' { [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group }
    }
    $descriptor = New-Object Security.AccessControl.RawSecurityDescriptor($Sddl)
    return $descriptor.GetSddlForm($sections)
}
function Set-PostgresRecoveryFileSecurity([string]$Path, [string]$Sddl, [switch]$OwnershipOnly) {
    $descriptor = New-Object Security.AccessControl.RawSecurityDescriptor($Sddl)
    if (-not $descriptor.Owner -or -not $descriptor.Group) { throw 'Recorded PostgreSQL security is missing its owner or primary group.' }
    # FileSecurity can synthesize an Everyone/FullControl ACE for a null DACL.
    # Refuse that unsupported descriptor instead of changing its meaning.
    if (-not $OwnershipOnly -and $null -eq $descriptor.DiscretionaryAcl) { throw 'PostgreSQL recovery cannot preserve a null DACL automatically.' }
    $part = if ($OwnershipOnly) { 'OwnerGroup' } else { 'All' }
    $sections = if ($OwnershipOnly) { [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group } else { [Security.AccessControl.AccessControlSections]::All }
    $restore = $null; $security = $null
    try {
        $restore = Enter-PostgresRecoveryPrivilege 'SeRestorePrivilege'
        $security = Enter-PostgresRecoveryPrivilege 'SeSecurityPrivilege'
        $acl = Get-Acl -LiteralPath $Path -Audit -ErrorAction Stop
        $before = $acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
        $acl.SetSecurityDescriptorSddlForm($Sddl, $sections)
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        $applied = (Get-Acl -LiteralPath $Path -Audit -ErrorAction Stop).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
        if ((Get-PostgresRecoverySecurityPart $applied $part) -cne (Get-PostgresRecoverySecurityPart $Sddl $part)) { throw "Could not preserve the recorded PostgreSQL file security: $Path" }
        if ($OwnershipOnly -and (Get-PostgresRecoverySecurityPart $applied 'AccessAudit') -cne (Get-PostgresRecoverySecurityPart $before 'AccessAudit')) { throw "PostgreSQL access/audit rules changed during ownership restoration: $Path" }
    } finally {
        try { if ($security) { $security.Dispose() } }
        finally { if ($restore) { $restore.Dispose() } }
    }
}
function Write-PostgresRecoveryBytes([string]$Path, [byte[]]$Bytes, [string]$ExpectedSecurity = '', [string]$ExpectedHash = '') {
    $originalSecurity = Get-PostgresRecoveryFileSecurity $Path
    $originalHash = Get-PostgresRecoveryHash ([IO.File]::ReadAllBytes($Path))
    if (($ExpectedSecurity -and $originalSecurity -cne $ExpectedSecurity) -or ($ExpectedHash -and $originalHash -cne $ExpectedHash)) {
        throw "PostgreSQL configuration changed before replacement: $Path. No replacement was published."
    }
    $temporary = "$Path.aurora-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        # ReplaceFile preserves the DACL, but does not promise owner/group/SACL
        # preservation. Apply and verify the complete descriptor before publish.
        $stage = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stage.Dispose()
        Set-PostgresRecoveryFileSecurity $temporary $originalSecurity
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        if ((Get-PostgresRecoveryFileSecurity $temporary) -cne $originalSecurity -or
            (Get-PostgresRecoveryFileSecurity $Path) -cne $originalSecurity -or
            (Get-PostgresRecoveryHash ([IO.File]::ReadAllBytes($Path))) -cne $originalHash) {
            throw "PostgreSQL configuration or staged permissions changed before replacement: $Path. No replacement was published."
        }
        [IO.File]::Replace($temporary, $Path, [Management.Automation.Language.NullString]::Value)
        if ((Get-PostgresRecoveryFileSecurity $Path) -cne $originalSecurity -or
            (Get-PostgresRecoveryHash ([IO.File]::ReadAllBytes($Path))) -cne (Get-PostgresRecoveryHash $Bytes)) {
            throw "Could not verify the replaced PostgreSQL configuration and permissions: $Path. The recovery journal was retained."
        }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Restore-PostgresRecoveryJournal($Target, [string]$Directory) {
    $path = Join-Path $Directory 'journal.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    Assert-PostgresRecoveryJournalAcl $Directory
    $null = Assert-PostgresRecoveryPath $path
    Assert-PostgresRecoveryJournalAcl $path
    $journal = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ($journal.schema -notin @(1, 2) -or $journal.data -ine $Target.data -or $journal.bin -ine $Target.bin -or [int]$journal.port -ne $Target.port -or @($journal.files).Count -ne 2) { throw "The pending password-recovery journal does not match this instance: $path" }
    $expected = @($Target.hba, $Target.ident)
    # Schema 1 recorded Get-Acl without -Audit. Preserve its current SACL while
    # checking every recorded section; schema 2 also records/verifies auditing.
    $sections = if ($journal.schema -eq 1) { 'OwnerGroupAccess' } else { 'All' }
    $snapshots = @(); $repairs = @()
    for ($i = 0; $i -lt 2; $i++) {
        $entry = $journal.files[$i]
        if ($entry.path -ine $expected[$i]) { throw "Unexpected configuration path in recovery journal: $path" }
        $null = Assert-PostgresRecoveryPath $entry.path
        $original = [Convert]::FromBase64String($entry.original)
        if ((Get-PostgresRecoveryHash $original) -cne $entry.originalHash) { throw "The recovery journal failed its integrity check: $path" }
        $currentHash = Get-PostgresRecoveryHash ([IO.File]::ReadAllBytes($entry.path))
        if ($currentHash -cnotin @($entry.originalHash, $entry.temporaryHash)) { throw "Recovery stopped because '$($entry.path)' changed concurrently. Its original bytes are retained in $path; reconcile it before retrying." }
        $security = Get-PostgresRecoveryFileSecurity $entry.path
        $recorded = Get-PostgresRecoverySecurityPart $entry.acl $sections
        if ((Get-PostgresRecoverySecurityPart $security $sections) -cne $recorded) {
            if ($journal.schema -eq 1 -and
                (Get-PostgresRecoverySecurityPart $security 'Access') -ceq (Get-PostgresRecoverySecurityPart $entry.acl 'Access')) {
                # The original writer copied only the DACL to its replacement.
                # Repair only that legacy owner/group drift, with explicit consent.
                $repairs += $i
            } else { throw "Recovery stopped because recorded permissions changed for '$($entry.path)'. No automatic permission repair is allowed. Compare the current security descriptor with the protected journal: $path" }
        }
        $snapshots += @{ hash = $currentHash; security = $security; recorded = $recorded }
    }
    if ($repairs.Count) {
        Assert-PostgresRecoveryAdministrator
        Write-Host 'A previous bootstrap version could change file ownership during atomic replacement. File contents and recorded access permissions still match.'
        foreach ($i in $repairs) {
            Write-Host ("Restore recorded owner/group for '{0}': {1} -> {2}" -f $journal.files[$i].path,
                (Get-PostgresRecoverySecurityPart $snapshots[$i].security 'OwnerGroup'),
                (Get-PostgresRecoverySecurityPart $journal.files[$i].acl 'OwnerGroup'))
        }
        $answer = Read-Host 'Restore the recorded owner/group and original authentication files from this trusted journal? [y/N]'
        if (([string]$answer).Trim() -notmatch '^(y|yes|d|da)$') { throw "Recovery journal repair was declined. Files and journal were preserved: $path" }
    }
    # Recheck both snapshots after any prompt, before making the first change.
    for ($i = 0; $i -lt 2; $i++) {
        $entry = $journal.files[$i]
        if ((Get-PostgresRecoveryHash ([IO.File]::ReadAllBytes($entry.path))) -cne $snapshots[$i].hash -or
            (Get-PostgresRecoveryFileSecurity $entry.path) -cne $snapshots[$i].security) {
            throw "PostgreSQL configuration or permissions changed during recovery preflight: $($entry.path). Journal: $path"
        }
    }
    foreach ($i in $repairs) {
        $entry = $journal.files[$i]
        if ((Get-PostgresRecoveryHash ([IO.File]::ReadAllBytes($entry.path))) -cne $snapshots[$i].hash -or
            (Get-PostgresRecoveryFileSecurity $entry.path) -cne $snapshots[$i].security) { throw "Configuration changed before ownership repair: $($entry.path). Journal: $path" }
        Set-PostgresRecoveryFileSecurity $entry.path $entry.acl -OwnershipOnly
        $snapshots[$i].security = Get-PostgresRecoveryFileSecurity $entry.path
        if ((Get-PostgresRecoverySecurityPart $snapshots[$i].security $sections) -cne $snapshots[$i].recorded) { throw "Could not verify repaired ownership: $($entry.path). Journal: $path" }
    }
    # Close the temporary authentication route before removing its identity map.
    for ($i = 0; $i -lt 2; $i++) {
        $entry = $journal.files[$i]
        $currentHash = Get-PostgresRecoveryHash ([IO.File]::ReadAllBytes($entry.path))
        if ($currentHash -cne $snapshots[$i].hash -or (Get-PostgresRecoveryFileSecurity $entry.path) -cne $snapshots[$i].security) { throw "Recovery configuration changed during restoration: $($entry.path). Journal: $path" }
        if ($currentHash -ceq $entry.temporaryHash) { Write-PostgresRecoveryBytes $entry.path ([Convert]::FromBase64String($entry.original)) $snapshots[$i].security $currentHash }
        if ((Get-PostgresRecoveryHash ([IO.File]::ReadAllBytes($entry.path))) -cne $entry.originalHash -or
            (Get-PostgresRecoveryFileSecurity $entry.path) -cne $snapshots[$i].security -or
            (Get-PostgresRecoverySecurityPart $snapshots[$i].security $sections) -cne $snapshots[$i].recorded) { throw "Could not verify restored PostgreSQL configuration: $($entry.path). Journal: $path" }
    }
    [IO.File]::Delete($path)
}
function Restore-PendingLocalPostgresRecovery {
    $directory = Get-PostgresRecoveryDirectory
    if (-not (Test-Path -LiteralPath (Join-Path $directory 'journal.json'))) { return }
    Assert-PostgresRecoveryAdministrator
    $null = Assert-PostgresRecoveryPath $directory
    Assert-PostgresRecoveryJournalAcl $directory
    $target = Get-LocalPostgresRecoveryTarget
    $lock = [IO.File]::Open((Join-Path $directory 'lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Restore-PostgresRecoveryJournal $target $directory; Write-Host 'Restored authentication files from the interrupted PostgreSQL password recovery.' }
    finally { $lock.Dispose() }
    Remove-Item -LiteralPath (Join-Path $directory 'lock') -Force
    if (-not @(Get-ChildItem -LiteralPath $directory -Force).Count) { [IO.Directory]::Delete($directory) }
}
function Invoke-PostgresRecoveryClient([string]$Command, [string]$InputText = '', [string]$Password = '', [switch]$AuthenticationProbe) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $PsqlPath
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $clientHost = if ($PgHost -eq '::1') { '::1' } else { '127.0.0.1' }
    $arguments = @('-X', '-w', '-h', $clientHost, '-p', [string]$Port, '-U', $PgAdminUser, '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At', '-c', $Command)
    $start.Arguments = (@($arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
    foreach ($name in @('PGPASSWORD', 'PGHOSTADDR', 'PGSERVICE', 'PGOPTIONS')) { $start.EnvironmentVariables.Remove($name) }
    $start.EnvironmentVariables['PGCLIENTENCODING'] = 'UTF8'
    $start.EnvironmentVariables['PGCONNECT_TIMEOUT'] = '10'
    $start.EnvironmentVariables['PGSSLMODE'] = 'disable'
    # PostgreSQL's Windows prompt fallback consumes redirected stdin with this
    # setting. Password confirmation stays inside psql/libpq and is encrypted
    # client-side; the plaintext never enters SQL, argv, files, or output.
    $start.EnvironmentVariables['OSTYPE'] = 'msys'
    if ($Password) { $start.EnvironmentVariables['PGPASSWORD'] = $Password }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $inputBytes = [Text.Encoding]::UTF8.GetBytes($InputText)
        $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw 'PostgreSQL password recovery client timed out.' }
        $output = $stdout.GetAwaiter().GetResult(); $diagnostic = $stderr.GetAwaiter().GetResult()
        if ($AuthenticationProbe) { return @{ accepted = ($process.ExitCode -eq 0); rejected = ($process.ExitCode -ne 0 -and $diagnostic -match 'password authentication failed') } }
        if ($process.ExitCode -ne 0) { throw 'PostgreSQL recovery authentication or password change failed. The new password was not written to a log by bootstrap.' }
        return $output.Trim()
    } finally { $process.Dispose() }
}
function Recover-LocalPostgresPassword {
    Assert-PostgresRecoveryAdministrator
    $target = Get-LocalPostgresRecoveryTarget
    Restore-PendingLocalPostgresRecovery
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $parts = $identity.Name.Split('\')
    if ($parts.Length -ne 2 -or $identity.Name -match '["\r\n\x00]' -or -not $parts[0] -or -not $parts[1]) { throw 'Cannot construct an exact Windows identity mapping for recovery.' }
    $principalName = $parts[1] + '@' + $parts[0]
    Write-Host "Password recovery target: '$PgAdminUser' at $($target.host):$Port; data directory '$($target.data)'; Windows identity '$($identity.Name)'."
    $answer = Read-Host 'Reset this PostgreSQL account password using your Windows administrator identity? [y/N]'
    if (([string]$answer).Trim() -notmatch '^(y|yes|d|da)$') { throw 'PostgreSQL password recovery was declined.' }
    $first = Read-Host "New password for PostgreSQL account $PgAdminUser" -AsSecureString
    $second = Read-Host 'Confirm the new password' -AsSecureString
    $newPassword = $null
    try {
        $newPassword = [Net.NetworkCredential]::new('', $first).Password
        $confirmation = [Net.NetworkCredential]::new('', $second).Password
        if (-not $newPassword -or $newPassword -match '[\r\n\x00]' -or $newPassword -cne $confirmation) { throw 'The new passwords must match, be nonempty, and contain no line breaks.' }
        Remove-Variable confirmation
        $directory = Assert-PostgresRecoveryPath (Get-PostgresRecoveryDirectory)
        if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory; Protect-PostgresRecoveryObject $directory -Directory }
        else { Assert-PostgresRecoveryJournalAcl $directory }
        $lock = [IO.File]::Open((Join-Path $directory 'lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            if (Test-Path -LiteralPath (Join-Path $directory 'journal.json')) { throw 'A password-recovery journal appeared concurrently. Retry after the other operation finishes.' }
            $map = 'aurora_recovery_' + [guid]::NewGuid().ToString('N')
            $address = if ($target.host -eq '::1') { '::1/128' } else { '127.0.0.1/32' }
            $prefixes = @("host `"postgres`" `"$PgAdminUser`" $address sspi include_realm=1 compat_realm=1 upn_username=0 map=$map`r`n", "$map `"$principalName`" `"$PgAdminUser`"`r`n")
            $entries = @(); $temporaryBytes = @()
            $paths = @($target.hba, $target.ident)
            for ($i = 0; $i -lt 2; $i++) {
                $bytes = [IO.File]::ReadAllBytes($paths[$i])
                if ([Array]::IndexOf($bytes, [byte]0) -ge 0 -or ($bytes.Length -ge 2 -and (($bytes[0] -eq 255 -and $bytes[1] -eq 254) -or ($bytes[0] -eq 254 -and $bytes[1] -eq 255)))) { throw 'Recovery supports ordinary ASCII/UTF-8 PostgreSQL authentication files only.' }
                $prefix = [Text.Encoding]::UTF8.GetBytes($prefixes[$i])
                $bom = if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { 3 } else { 0 }
                $temporary = New-Object byte[] ($bytes.Length + $prefix.Length)
                [Array]::Copy($bytes, 0, $temporary, 0, $bom)
                [Array]::Copy($prefix, 0, $temporary, $bom, $prefix.Length)
                [Array]::Copy($bytes, $bom, $temporary, ($bom + $prefix.Length), ($bytes.Length - $bom))
                $temporaryBytes += ,$temporary
                $entries += @{ path = $paths[$i]; original = [Convert]::ToBase64String($bytes); originalHash = (Get-PostgresRecoveryHash $bytes); temporaryHash = (Get-PostgresRecoveryHash $temporary); acl = (Get-PostgresRecoveryFileSecurity $paths[$i]) }
            }
            Save-PostgresRecoveryJournal (Join-Path $directory 'journal.json') @{ schema = 2; data = $target.data; bin = $target.bin; port = $Port; files = $entries }
            try {
                Write-PostgresRecoveryBytes $target.ident $temporaryBytes[1] $entries[1].acl $entries[1].originalHash
                Write-PostgresRecoveryBytes $target.hba $temporaryBytes[0] $entries[0].acl $entries[0].originalHash
                $probe = Invoke-PostgresRecoveryClient "SELECT json_build_object('login',current_user,'data',current_setting('data_directory'),'hba',current_setting('hba_file'),'ident',current_setting('ident_file'))::text;" | ConvertFrom-Json
                if ($probe.login -cne $PgAdminUser -or [IO.Path]::GetFullPath([string]$probe.data) -ine $target.data -or [IO.Path]::GetFullPath([string]$probe.hba) -ine $target.hba -or [IO.Path]::GetFullPath([string]$probe.ident) -ine $target.ident) { throw 'The authenticated recovery connection does not match the verified local PostgreSQL instance.' }
                $null = Invoke-PostgresRecoveryClient '\password' ($newPassword + "`n" + $newPassword + "`n")
            } finally { Restore-PostgresRecoveryJournal $target $directory }
        } finally { $lock.Dispose() }
        Remove-Item -LiteralPath (Join-Path $directory 'lock') -Force
        if (-not @(Get-ChildItem -LiteralPath $directory -Force).Count) { [IO.Directory]::Delete($directory) }
        $verified = Invoke-PostgresRecoveryClient 'SELECT current_user;' '' $newPassword
        if ($verified -cne $PgAdminUser) { throw 'The recovered PostgreSQL password did not pass verification under the restored authentication configuration.' }
        $negative = @{ accepted = $false; rejected = $false }
        try { $negative = Invoke-PostgresRecoveryClient 'SELECT current_user;' '' ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')) -AuthenticationProbe } catch { }
        if ($negative.rejected) { Write-Host "Password recovery succeeded for '$PgAdminUser'. Original authentication files were restored and password authentication was verified." }
        elseif ($negative.accepted) { Write-Warning "The password for '$PgAdminUser' was updated and original authentication files restored, but this connection policy also accepts a different password. Password authentication could not be verified under the existing policy." }
        else { Write-Warning "The password for '$PgAdminUser' was updated and original authentication files restored. Login with the new password succeeded, but the negative authentication check was inconclusive." }
        return $newPassword
    } finally {
        $first.Dispose(); $second.Dispose()
        Remove-Variable newPassword, confirmation -ErrorAction SilentlyContinue
    }
}

function Test-PostgresReady {
    $ErrorActionPreference = 'Continue'
    & $PgIsReady -h $PgHost -p $Port -U $DbUser -d $Database -t 3 *> $null
    return ($LASTEXITCODE -eq 0)
}
function Wait-Postgres {
    $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
    do {
        if (Test-PostgresReady) { return }
        Start-Sleep -Seconds 1
    } until ((Get-Date) -ge $deadline)
    throw "PostgreSQL did not become ready at ${PgHost}:$Port. Check the selected database service and port."
}
function Ensure-LocalPostgres([switch]$ExistingOnly) {
    if (Test-PostgresReady) { return }
    $names = @(if ($PgServiceName) { $PgServiceName } else { Get-PostgresServiceCandidates $PsqlPath })
    if ($names.Count -eq 0 -and -not $PgServiceName) {
        if ($ExistingOnly -and -not (Get-ManagedPostgresCluster)) { throw 'No initialized managed PostgreSQL cluster or matching service was selected. Password recovery does not create a new instance.' }
        $null = Initialize-NewLocalPostgres
        Wait-Postgres
        return
    }
    if ($names.Count -ne 1) {
        throw "No responding PostgreSQL at ${PgHost}:$Port. Found $($names.Count) services for the selected installation. Start the intended service or pass its exact -PgServiceName."
    }
    # Match the literal service name. Get-Service -Name treats its argument as a wildcard.
    $services = @(Get-Service | Where-Object { $_.Name -eq $names[0] })
    if ($services.Count -ne 1) { throw "PostgreSQL service '$names' was not found. Check -PgServiceName." }
    $service = $services[0]
    if ($service.Status -ne 'Running') {
        Write-Host "Starting PostgreSQL Windows service: $($service.Name)"
        try {
            Start-Service -InputObject $service -ErrorAction Stop
            $service.WaitForStatus('Running', [TimeSpan]::FromSeconds($StartupTimeoutSeconds))
        } catch {
            throw "Could not start PostgreSQL service '$($service.Name)'. Start it from Windows Services with the necessary permissions, then rerun. $($_.Exception.Message)"
        }
    }
    Wait-Postgres
}
function Invoke-DatabaseSql([string]$Sql, [string]$Login = $DbUser, [string]$DbName = $Database) {
    Run { & $PsqlPath -X -w -h $PgHost -p $Port -U $Login -d $DbName -v ON_ERROR_STOP=1 -Atc $Sql }
}
function New-LabDatabaseRole([string]$Password) {
    # Send the password through stdin, never through process arguments or files.
    # Suppress SQL diagnostics here because the server may echo the statement.
    $ErrorActionPreference = 'Continue'
    $savedEncoding = $OutputEncoding
    $savedClientEncoding = $env:PGCLIENTENCODING
    try {
        $OutputEncoding = New-Object Text.UTF8Encoding($false)
        $env:PGCLIENTENCODING = 'UTF8'
        $literal = $Password.Replace("'", "''")
        $sql = "SET standard_conforming_strings = on;`nCREATE ROLE `"$DbUser`" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '$literal';"
        $sql | & $PsqlPath -X -w -h $PgHost -p $Port -U $PgAdminUser -d postgres -v ON_ERROR_STOP=1 -f - *> $null
        if ($LASTEXITCODE -ne 0) { throw "Could not create PostgreSQL role '$DbUser'. Check the administrator's CREATEROLE permission and retry. Existing roles were not changed." }
    } finally {
        $OutputEncoding = $savedEncoding
        $env:PGCLIENTENCODING = $savedClientEncoding
        Remove-Variable literal, sql -ErrorAction SilentlyContinue
    }
}
function Initialize-LabDatabase {
    # Use an authenticated catalog query to prove absence. A failed application
    # login can mean a missing role, a wrong password, or an unavailable database.
    if ($DbUser -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,62}$') { throw 'Creating a lab role requires a simple PostgreSQL identifier.' }
    $labPassword = $env:PGPASSWORD
    Write-Host "Cannot connect as '$DbUser' to '$Database'. An administrator must check whether the role or database is missing."
    $secure = $null
    try {
        $adminPassword = 'postgres'
        $env:PGPASSWORD = $adminPassword
        $serverNumber = $null
        Write-Host "Trying the default PostgreSQL administrator password for '$PgAdminUser' at ${PgHost}:$Port."
        try { $serverNumber = Invoke-DatabaseSql 'SHOW server_version_num;' $PgAdminUser 'postgres' 2>$null } catch { }
        if (-not $serverNumber) {
            if (-not (Test-BootstrapInteractive)) { throw "PostgreSQL default administrator authentication failed for '$PgAdminUser'. Rerun interactively to enter its password or recover local access. No role or database was changed." }
            $secure = Read-Host "Existing password for $PgAdminUser (leave empty for local password recovery)" -AsSecureString
            $adminPassword = [System.Net.NetworkCredential]::new('', $secure).Password
            if ($adminPassword) {
                $env:PGPASSWORD = $adminPassword
                try { $serverNumber = Invoke-DatabaseSql 'SHOW server_version_num;' $PgAdminUser 'postgres' 2>$null } catch { }
            }
            if (-not $serverNumber) {
                Write-Host 'Administrator authentication was not established. Local password recovery is available to an elevated Windows administrator.'
                $adminPassword = Recover-LocalPostgresPassword
                if ($DbUser -ceq $PgAdminUser) { $labPassword = $adminPassword }
                $env:PGPASSWORD = $adminPassword
                $serverNumber = Invoke-DatabaseSql 'SHOW server_version_num;' $PgAdminUser 'postgres'
            }
        }
        Assert-ServerVersion $serverNumber
        $hasRole = Invoke-DatabaseSql "SELECT count(*) FROM pg_catalog.pg_roles WHERE rolname='$DbUser';" $PgAdminUser 'postgres'
        $hasDb = Invoke-DatabaseSql "SELECT count(*) FROM pg_catalog.pg_database WHERE datname='$Database';" $PgAdminUser 'postgres'
        if ($hasRole -notin @('0', '1') -or $hasDb -notin @('0', '1')) { throw 'Unexpected PostgreSQL catalog response. Stopping provisioning.' }
        if ($hasRole -eq '0') {
            Write-Host "Creating missing PostgreSQL login '$DbUser'."
            New-LabDatabaseRole $labPassword
        }
        # Test an existing role's password before any database creation. Never
        # reset credentials or infer absence from an authentication failure.
        $env:PGPASSWORD = $labPassword
        $verificationDb = if ($hasDb -eq '1') { $Database } else { 'postgres' }
        try {
            if ((Invoke-DatabaseSql 'SELECT 1;' $DbUser $verificationDb) -ne '1') { throw 'Unexpected login response.' }
        } catch {
            throw "PostgreSQL authentication/access failed: role '$DbUser' exists, but the configured password or database permissions were rejected for '$verificationDb' at ${PgHost}:$Port. Supply the correct PGPASSWORD or check its LOGIN/CONNECT permissions. The existing password was not reset."
        }
        if ($hasDb -eq '0') {
            $env:PGPASSWORD = $adminPassword
            # Both identifiers were validated before use. Preserve case with quotes.
            Invoke-DatabaseSql "CREATE DATABASE `"$Database`" OWNER `"$DbUser`";" $PgAdminUser 'postgres' | Out-Host
        }
    } finally {
        $env:PGPASSWORD = $labPassword
        if ($secure) { $secure.Dispose() }
        Remove-Variable adminPassword -ErrorAction SilentlyContinue
    }
}
function Assert-ServerVersion($Number) {
    $serverNumber = 0
    if (-not [int]::TryParse(([string]$Number).Trim(), [ref]$serverNumber)) { throw "Cannot determine the version of the authenticated PostgreSQL server: '$Number'." }
    if ($serverNumber -lt 150000) {
        if (Confirm-ToolUpgrade 'PostgreSQL server' "Selected server $Number at ${PgHost}:$Port. The lab supports PostgreSQL 15+. Prepare a manual upgrade with the database administrator?") {
            Write-Host 'Back up and verify the existing cluster. The administrator can run the target PostgreSQL pg_upgrade --check with the old/new bin and data directories, and schedule migration after review. See https://www.postgresql.org/docs/current/pgupgrade.html.'
        }
        throw "Select an existing PostgreSQL 15+ cluster or finish an operator-managed upgrade, then rerun. Database files and roles were preserved."
    }
}
function Open-LabDatabase {
    Ensure-LocalPostgres
    Restore-PendingLocalPostgresRecovery
    try { $version = Invoke-DatabaseSql 'SHOW server_version_num;' }
    catch {
        if (-not $ProvisionDatabase -and $DbUser -cne 'scala_lab') { throw "PostgreSQL authentication/connection failed for '$DbUser' on ${PgHost}:$Port/$Database. Check the credentials. Use -ProvisionDatabase to check/create a custom lab role or database." }
        Initialize-LabDatabase
        $version = Invoke-DatabaseSql 'SHOW server_version_num;'
    }
    Assert-ServerVersion $version
}

function Test-ArtifactHash([string]$Path, [string]$Sha256) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Expected a regular cached file at '$Path'." }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Sha256
}
function Publish-VerifiedArtifact([string]$Temporary, [string]$Path, [string]$Sha256) {
    if (-not (Test-ArtifactHash $Temporary $Sha256)) { throw "SHA-256 verification failed for '$Path'." }
    try {
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($Temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($Temporary, $Path) }
    } catch [IO.IOException] {
        # Another run may already have published the same verified bytes.
        if (-not (Test-ArtifactHash $Path $Sha256)) { throw }
    }
}
function Get-VerifiedDownload([string]$Uri, [string]$Path, [string]$Sha256) {
    if (Test-ArtifactHash $Path $Sha256) { return }
    $part = "$Path.$([guid]::NewGuid().ToString('N')).part"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $part
        Publish-VerifiedArtifact $part $Path $Sha256
    } finally { if ([IO.File]::Exists($part)) { [IO.File]::Delete($part) } }
}
function Get-RxNormFiles([string]$RrfDirectory, [string]$Archive) {
    $hashes = @{
        'RXNCONSO.RRF' = '555730c3ff2a981796dc5d649acc482e4685f7a31f7b0442941393ae50dd5209'
        'RXNREL.RRF' = 'cca47f32a2c32ef60d65c6789851385ff5dcf287750ca01a53f800a5cf5ef694'
        'RXNSAT.RRF' = 'b5a476f2bfbef9082144fd2bf00eb0de46f7b0b63da822d856067b9935914dda'
    }
    $needed = @($hashes.Keys | Where-Object { -not (Test-ArtifactHash (Join-Path $RrfDirectory $_) $hashes[$_]) })
    if ($needed.Count -eq 0) { return }
    Get-VerifiedDownload -Uri 'https://download.nlm.nih.gov/rxnorm/RxNorm_full_prescribe_10052026.zip' -Path $Archive -Sha256 '8ed351c29f3cb56bedeb8e2bcb8fa56931f8d7eb88e2280dc9772d7d3eb16977'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($name in $needed) {
            $entry = $zip.GetEntry("rrf/$name")
            if (-not $entry) { throw "Missing rrf/$name in the verified RxNorm archive." }
            $path = Join-Path $RrfDirectory $name
            $part = "$path.$([guid]::NewGuid().ToString('N')).part"
            try {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $part)
                Publish-VerifiedArtifact $part $path $hashes[$name]
            } finally { if ([IO.File]::Exists($part)) { [IO.File]::Delete($part) } }
        }
    } finally { $zip.Dispose() }
}

function ConvertTo-SbtPath([string]$Path) {
    # Absolute paths decouple imports/results from repository depth and siblings.
    $full = [IO.Path]::GetFullPath($Path).Replace('\', '/')
    if ($full -match '["\r\n\x00]') { throw 'Unsupported character in an sbt input/output path.' }
    return '"' + $full + '"'
}
function ConvertTo-WindowsArgument([string]$Value) {
    # Preserve embedded quotes and trailing backslashes for CreateProcess/Java.
    # Avoid PowerShell 5.1 versus 7 native-argument forwarding differences.
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}
# Existing launchers can boot the project's pinned sbt even if their distribution
# version differs. Only a downloaded launcher must match our published digest.
function Get-SbtRootCandidates([string]$Required, [string]$Managed) {
    $Managed
    foreach ($homePath in @($env:SBT_HOME, $env:SBTHOME)) {
        if ($homePath) { Join-Path $homePath 'bin\sbt-launch.jar'; Join-Path $homePath 'lib\sbt-launch.jar' }
    }
    foreach ($runner in @('sbt.bat','sbt.cmd','sbt.exe')) {
        foreach ($exe in @(Get-PathToolCandidates $runner)) {
            if (Test-Path -LiteralPath $exe -PathType Leaf) { $exe }
        }
    }
    foreach ($path in @("$env:USERPROFILE\.sbt\launchers\$Required\sbt-launch.jar",
        "$env:USERPROFILE\.ivy2\cache\org.scala-sbt\sbt-launch\jars\sbt-launch-$Required.jar",
        "$env:USERPROFILE\.m2\repository\org\scala-sbt\sbt-launch\$Required\sbt-launch-$Required.jar",
        "$env:USERPROFILE\.cache\coursier\v1", "$env:LOCALAPPDATA\Coursier\Cache\v1", $env:COURSIER_CACHE)) {
        if (-not $path) { continue }
        if ($path.EndsWith('.jar')) { $path; continue }
        foreach ($hostPath in @('repo.maven.apache.org','repo1.maven.org')) {
            Join-Path $path "https\$hostPath\maven2\org\scala-sbt\sbt-launch\$Required\sbt-launch-$Required.jar"
        }
    }
}
function Test-SbtArchive([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead($Path)
        try { return ($null -ne $archive.GetEntry('xsbt/boot/Boot.class') -and $null -ne $archive.GetEntry('sbt/sbt.boot.properties')) }
        finally { $archive.Dispose() }
    } catch [IO.InvalidDataException] { return $false }
}
function Test-ProjectLauncher([string]$Jar, [string]$Required, [bool]$Compile) {
    $commands = @('show sbtVersion')
    if ($Compile) { $commands += 'compile' }
    Push-Location -LiteralPath $Scala
    try {
        $probe = Invoke-ToolVersion $Java (@('-Xmx2G','-Dsbt.supershell=false','-Dsbt.log.noformat=true','-Dsbt.server.autostart=false','-jar',$Jar) + $commands)
    } finally { Pop-Location }
    if (-not $probe.ok) {
        if ($probe.text -match '(?i)UnsupportedClassVersionError|Unsupported class file major version|class file has wrong version|does not support running the compiler on this version of the JDK') {
            return 'jdk-incompatible'
        }
        # A failed network resolution, compilation error, or unreadable repository
        # says nothing about the installed runner/JDK. Never install on this basis.
        throw "Cannot verify the existing sbt launcher with the project. $($probe.text)"
    }
    if ($probe.text -notmatch ('(?m)^\[info\]\s*' + [regex]::Escape($Required) + '\s*$')) { return 'sbt-incompatible' }
    return 'compatible'
}
function Resolve-SbtLauncher([string]$Managed) {
    $required = '1.10.2'
    $sha = 'cdd6963b622f42690cb2e3154bde3f3257a03839f216e1b5d7420000d6a71817'
    $pin = (Get-Content -LiteralPath (Join-Path $Scala 'project\build.properties') | Where-Object { $_ -match '^\s*sbt\.version\s*=' })
    if (@($pin).Count -ne 1 -or (($pin -split '=',2)[1]).Trim() -ne $required) { throw 'The checkout changed the sbt pin. Use a bootstrap matched to this project revision.' }
    $seen = @{}; $evidence = New-Object 'System.Collections.Generic.List[string]'
    $uncertain = New-Object 'System.Collections.Generic.List[string]'
    if ($SbtLauncherPath -and -not (Test-Path -LiteralPath $SbtLauncherPath -PathType Leaf)) { throw "Explicit sbt launcher is inaccessible: $SbtLauncherPath" }
    foreach ($phase in @('quick','inventory','managed')) {
        if ($SbtLauncherPath -and $phase -eq 'inventory') { continue }
        if ($phase -eq 'quick') {
            if ($SbtLauncherPath) { $paths = @([IO.Path]::GetFullPath($SbtLauncherPath)) }
            else { $paths = @(Get-SbtRootCandidates $required $Managed) }
        } elseif ($phase -eq 'inventory') {
            Read-ToolRegistrations 'Sbt'
            $paths = @((Get-ToolInventory).Sbt.ToArray())
            foreach ($record in $script:ToolRecords.Sbt) {
                $evidence.Add($record.description)
                if ($record.location) { $paths += Join-Path $record.location 'bin\sbt-launch.jar' }
            }
            foreach ($mask in @("$env:USERPROFILE\.sbt\launchers\*\sbt-launch.jar", "$env:USERPROFILE\.ivy2\cache\org.scala-sbt\sbt-launch\jars\sbt-launch-*.jar", "$env:USERPROFILE\.m2\repository\org\scala-sbt\sbt-launch\*\sbt-launch-*.jar")) {
                $paths += @(Get-Item -Path $mask -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            }
        } else {
            $portable = Get-PortableToolMessage 'Sbt'
            if ($portable) { throw $portable }
            if ($uncertain.Count) { throw ($uncertain -join [Environment]::NewLine) }
            if ($script:ToolSearchErrors.Shared.Count) { throw "Cannot determine whether an sbt launcher is installed: $($script:ToolSearchErrors.Shared -join '; ')" }
            if ($evidence.Count -and -not (Confirm-ToolUpgrade 'sbt' "Found $($evidence -join ', '). Fetch the verified $required launcher for this workspace?")) {
                throw 'sbt launcher change declined. Select an installed JAR with -SbtLauncherPath.'
            }
            Get-VerifiedDownload -Uri "https://repo.maven.apache.org/maven2/org/scala-sbt/sbt-launch/$required/sbt-launch-$required.jar" -Path $Managed -Sha256 $sha
            $seen.Remove($Managed)
            $paths = @($Managed)
        }
        foreach ($candidate in $paths) {
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            $jar = $candidate
            if ($candidate -notlike '*.jar') {
                $evidence.Add($candidate)
                $jar = Join-Path (Split-Path $candidate -Parent) 'sbt-launch.jar'
                if (-not (Test-Path -LiteralPath $jar -PathType Leaf)) { continue }
            }
            if ($seen.ContainsKey($jar)) { continue }
            $seen[$jar] = $true
            $digest = (Get-FileHash -LiteralPath $jar -Algorithm SHA256).Hash
            if ($digest -ne $sha -and -not (Test-SbtArchive $jar)) {
                if ($jar -ne $Managed) { $evidence.Add($jar) }
                continue
            }
            if ($digest -ne $sha -or $selectedTools.Java.probeBuild) {
                try { $verdict = Test-ProjectLauncher $jar $required ([bool]$selectedTools.Java.probeBuild) }
                catch { $uncertain.Add($_.Exception.Message); continue }
                while ($verdict -eq 'jdk-incompatible' -and $selectedTools.Java.probeBuild) {
                    # Search for another working JDK before offering an installation.
                    $script:RejectedJava[$Java] = $true
                    $selectedTools.Java = Resolve-SystemTool 'Java'
                    Use-ToolEnvironment @{ Java=$selectedTools.Java }
                    $script:Java = $selectedTools.Java.path
                    $script:JavaHome = $selectedTools.Java.javaHome
                    $verdict = Test-ProjectLauncher $jar $required $true
                }
                if ($verdict -eq 'jdk-incompatible') { $evidence.Add("$jar (incompatible with the selected JDK)"); continue }
                if ($verdict -ne 'compatible') { $evidence.Add($jar); continue }
            }
            # The editor reads <sbtHome>/bin/sbt-launch.jar. Use the original
            # distribution if it has this layout, otherwise alias the verified cache.
            $bin = Split-Path $jar -Parent
            if ((Split-Path $bin -Leaf) -eq 'bin' -and (Split-Path $jar -Leaf) -eq 'sbt-launch.jar') {
                Write-Host "Reusing sbt launcher: $jar"
                return $jar
            }
            $temporary = "$Managed.$([guid]::NewGuid().ToString('N')).part"
            try {
                try { New-Item -ItemType HardLink -Path $temporary -Target $jar -ErrorAction Stop | Out-Null }
                catch { Copy-Item -LiteralPath $jar -Destination $temporary -ErrorAction Stop }
                Publish-VerifiedArtifact $temporary $Managed $digest
            } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
            Write-Host "Reusing cached sbt launcher $jar in the editor layout."
            return $Managed
        }
    }
    throw "No launcher could start sbt $required."
}

function Invoke-Sbt([string[]]$Commands) {
    $arguments = @('-Xmx2G', '-Dsbt.supershell=false', '-Dsbt.log.noformat=true', '-Dsbt.server.autostart=false', '-jar', $Launcher) + $Commands
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $Java
    $start.WorkingDirectory = $Scala
    $start.UseShellExecute = $false
    $start.Arguments = (@($arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
    $process = [Diagnostics.Process]::Start($start)
    try {
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "sbt failed (exit $($process.ExitCode))." }
    } finally { $process.Dispose() }
}

if ($Help) {
    Write-Host 'Usage: .\bootstrap-windows.ps1 [-Root directory] [-ScalaRepoPath path] [-LangiumRepoPath path] [-SetupPath path] [-Port port] [-PgHost host] [-Database name] [-DbUser user] [-PsqlPath path] [-PgServiceName name] [--Docker] [-ContainerName name] [-VolumeName name] [-NoEditor] [-StartupTimeoutSeconds 180] [-ScalaBranch main] [-LangiumBranch main]'
    Write-Host 'Default folder: AuroraMedicationLab beside this script. Pass -Root to select a different local folder. Docker starts only with --Docker (also accepts -Docker / -UseDocker).'
    Write-Host 'Root is a search boundary. Discover both repositories recursively (including Root\repos), then update/build them in place; names or their Git origin identify existing clones. No duplicate copies are created when unique matches exist.'
    Write-Host 'Multiple matches require -ScalaRepoPath / -LangiumRepoPath, absolute or relative to Root. Missing partners are cloned beside the existing repo; with neither present, use Root\repos if it exists, otherwise Root.'
    Write-Host 'Discovery excludes setup/backups, tools, dependencies, build outputs, linked directories and the inside of Git checkouts. An incomplete, divergent or non-Git copy requires explicit reconciliation; it is never replaced.'
    Write-Host 'Reuse the unique existing medication-lab-setup\automatic directory below Root; otherwise create it directly below Root. Multiple setup directories require -SetupPath. Local source and personal files remain in place; upstream conflicts stop setup. Run one bootstrap at a time.'
    Write-Host 'Default: local PostgreSQL, no Docker checks or commands. Reuse an existing cluster; initialize owned loopback-only data with administrator password postgres only when no existing cluster is found. Connection defaults: PGHOST/PGPORT/PGDATABASE/PGUSER, then 127.0.0.1:5432 / scala_testing_lab / scala_lab. Explicit arguments override those defaults.'
    Write-Host 'Native mode defaults to scala_lab with password aurora; PGPASSWORD overrides it. A successful login is reused. On failure, the administrator verifies the catalog and creates only a missing role/database. Application passwords are not reset automatically. -PgAdminUser selects the administrator (default postgres). Custom roles require -ProvisionDatabase for creation.'
    Write-Host 'Administrator access first tries password postgres. If rejected, enter the existing password or choose interactive recovery. -RecoverPostgresPassword runs only local Windows recovery, with elevation and confirmation, and asks for a new password. Recovery preserves database contents and restores authentication configuration.'
    Write-Host 'A ready local RxNorm import with compatible manifests is reused. Empty databases receive the verified prescribable archive; incomplete/incompatible existing releases are not replaced.'
    Write-Host 'A stopped service can be started only when its executable belongs to the selected PostgreSQL installation. Use -PgServiceName to select another service or resolve ambiguity.'
    Write-Host 'Existing tools are discovered and version-checked outside PATH, including Program Files, registry/services and user installs. Only genuinely missing tools may use WinGet --no-upgrade.'
    Write-Host 'Optional -LocateToolsOnFixedDrives lists portable tool paths on fixed drives and exits before executing discovered files. Use -Verbose to see unreadable directories.'
    Write-Host 'Options: -JavaPath/-NodePath/-NpmPath/-GitPath/-CodePath/-DockerPath select executables; -AdditionalSearchPath adds search roots; -SessionOnlyEnvironment avoids saving tool homes/PATH to the user environment.'
    Write-Host 'For incompatible versions, setup describes the change and asks before upgrading. Default: No. -AllowToolUpgrade grants explicit unattended consent. Incomplete/inaccessible discovery needs repair. -SbtLauncherPath selects an existing launcher JAR.'
    Write-Host '--Docker selects the complete toolchain in a persistent Linux workspace; existing native repository locations are reported and their files are preserved.'
    Write-Host 'New managed Docker databases use scala_lab / aurora (PGPASSWORD overrides the default). Existing legacy rxnorm_lab containers retain their original account and data. Each run checks authentication. -PgAdminUser selects a recovery administrator; password resets require interactive confirmation.'
    Write-Host 'Docker can reuse Windows PostgreSQL or a published container: --Docker -DockerUseHostPostgres -Port 5432 -Database scala_testing_lab -DbUser scala_lab. Enable host networking in Docker Desktop 4.34+. PGPASSWORD is forwarded to the worker only; set the extension password in VS Code SecretStorage.'
    Write-Host 'If a separate server is wanted while another PostgreSQL is detected, choose -DockerUseManagedPostgres. Imported data and existing servers are never migrated automatically.'
    Write-Host 'Docker: -DockerToolSearchPath accepts additional Linux directories mounted in the runtime; use -AdditionalSearchPath for Windows executables.'
    Write-Host 'Docker selection: -RuntimeContainerName, -RuntimeVolumeName, -RuntimeCacheVolumeName and -RuntimeImage (default ubuntu:24.04). Existing volumes/credentials are reused, never reset.'
    return
}
if ($LocateToolsOnFixedDrives) { Show-FixedDriveToolLocations; return }
try {
# The two backends are explicit, never selected by probing Docker installation.
$DatabaseMode = 'local'
$RuntimeImageSpecified = $PSBoundParameters.ContainsKey('RuntimeImage')
if (($DockerUseHostPostgres -or $DockerUseManagedPostgres -or $DockerToolSearchPath) -and -not $UseDocker) { throw 'The selected Docker options require --Docker.' }
if ($DockerUseHostPostgres -and $DockerUseManagedPostgres) { throw 'Select one Docker database mode.' }
if ($UseDocker -and -not $RecoverPostgresPassword -and ($PsqlPath -or $PgServiceName)) { throw 'Select the database by port, database and user in Docker mode. Windows psql/service overrides apply only to native runs.' }
if ($UseDocker -and -not $DockerUseHostPostgres) {
    $DatabaseMode = 'docker-managed'
    $DockerDbUserSpecified = $PSBoundParameters.ContainsKey('DbUser')
    $DockerPgAdminUserSpecified = $PSBoundParameters.ContainsKey('PgAdminUser')
    if (($PgHost -and $PgHost -ne '127.0.0.1') -or ($Database -and $Database -ne 'rxnorm_public') -or ($DbUser -and $DbUser -cnotin @('scala_lab', 'rxnorm_lab'))) {
        throw 'Use -DockerUseHostPostgres to select an existing database with your own connection settings.'
    }
    if (-not $PSBoundParameters.ContainsKey('Port')) { $Port = 55433 }
    $PgHost = '127.0.0.1'; $Database = 'rxnorm_public'
    if (-not $DbUser) { $DbUser = 'scala_lab' }
} else {
    if ($DockerUseHostPostgres) { $DatabaseMode = 'docker-host-postgres' }
    if (-not $PSBoundParameters.ContainsKey('PgHost')) { $PgHost = if ($env:PGHOST) { $env:PGHOST } else { '127.0.0.1' } }
    if (-not $PSBoundParameters.ContainsKey('Database')) { $Database = if ($env:PGDATABASE) { $env:PGDATABASE } else { 'scala_testing_lab' } }
    if (-not $PSBoundParameters.ContainsKey('DbUser')) { $DbUser = if ($env:PGUSER) { $env:PGUSER } else { 'scala_lab' } }
    if (-not $PSBoundParameters.ContainsKey('Port') -and $env:PGPORT) {
        $parsedPort = 0
        if (-not [int]::TryParse($env:PGPORT, [ref]$parsedPort) -or $parsedPort -lt 1 -or $parsedPort -gt 65535) { throw 'PGPORT must be an integer from 1 to 65535.' }
        $Port = $parsedPort
    }
}
if ($PgHost -notin @('127.0.0.1', 'localhost', '::1')) { throw 'This lab supports a loopback PostgreSQL host only.' }
if ($Database -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,62}$') { throw 'Database must be a simple PostgreSQL identifier, not a connection string.' }
if ([string]::IsNullOrWhiteSpace($DbUser)) { throw 'DbUser must not be empty.' }
Write-Host "PostgreSQL mode: $DatabaseMode; endpoint: ${PgHost}:$Port; database: $Database; user: $DbUser"
# check the installed tools
$Root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
$Root = [IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
$rootItem = Get-Item -LiteralPath $Root -Force
if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Root must be an ordinary directory, not a file or link/junction.' }
if (Test-Path -LiteralPath (Join-Path $Root '.git')) { throw 'Root must be a parent/search directory, not a Git checkout itself.' }
$Root = $rootItem.FullName
Write-Host "Search root: $Root"
Initialize-ToolDiscovery
if ($RecoverPostgresPassword) {
    if ($UseDocker -and -not $DockerUseHostPostgres) { throw 'For a managed Docker database, run --Docker normally and use its interactive recovery prompt. -RecoverPostgresPassword targets a local Windows instance.' }
    $postgresTool = Find-SystemTool 'PostgreSQL' $PsqlPath
    if ($postgresTool.state -ne 'compatible') { throw 'Recovery requires an existing compatible PostgreSQL client. Select it with -PsqlPath; no software was installed.' }
    $PsqlPath = $postgresTool.path
    $PgIsReady = $postgresTool.ready
    Ensure-LocalPostgres -ExistingOnly
    $recoveredPassword = Recover-LocalPostgresPassword
    Remove-Variable recoveredPassword
    Write-Host "Password recovery completed for '$PgAdminUser'. Rerun setup to continue the lab installation."
    return
}
if ($UseDocker) {
    if ($JavaPath -or $NodePath -or $NpmPath -or $SbtLauncherPath -or $GitPath -or $ScalaRepoPath -or $LangiumRepoPath) {
        throw 'Docker uses a persistent Linux workspace and tools. Native tool/repository overrides cannot be combined with -UseDocker.'
    }
    $selectedTools = @{ Docker = (Resolve-SystemTool 'Docker' $DockerPath) }
    if (-not $NoEditor) { $selectedTools.Code = Resolve-SystemTool 'Code' $CodePath }
    Use-ToolEnvironment $selectedTools
    $DockerExecutable = $selectedTools.Docker.path
    Ensure-Docker
    Invoke-DockerRuntime
    return
}
$selectedTools = @{}
$selectedTools.Git = Resolve-SystemTool 'Git' $GitPath
$env:PATH = Add-UniqueToolPath @((Split-Path $selectedTools.Git.path -Parent)) $env:PATH
$layout = Find-InstallLayout
$Tools = Join-Path $layout.automatic 'tools'
$selectedTools.Java = Resolve-SystemTool 'Java' $JavaPath
$selectedTools.Node = Resolve-SystemTool 'Node' $NodePath
$selectedTools.PostgreSQL = Resolve-SystemTool 'PostgreSQL' $PsqlPath
if (-not $NoEditor) { $selectedTools.Code = Resolve-SystemTool 'Code' $CodePath }
Use-ToolEnvironment $selectedTools
$Java = $selectedTools.Java.path
$JavaHome = $env:JAVA_HOME
$NodeHome = $env:NODE_HOME
$PsqlPath = $selectedTools.PostgreSQL.path
$PgIsReady = $selectedTools.PostgreSQL.ready

$RepoDirectories = $layout.repositories
$Automatic = $layout.automatic
$Scala = $RepoDirectories['scala-testing-lab']
$Langium = Join-Path $RepoDirectories['langium_dsl_lab'] 'clinical-dsl-demo'
Write-Host "Scala repository: $Scala"
Write-Host "Langium repository: $($RepoDirectories['langium_dsl_lab'])"
Write-Host "Setup directory: $Automatic"
# Keep state/data separate from the discovered repositories.
$State = Join-Path $Automatic 'state'
$Downloads = Join-Path $Automatic 'downloads'
$Data = Join-Path $Automatic 'data\2026-10-05'
$Profile = Join-Path $Automatic 'editor-profile'
foreach ($directory in @($Root, $State, "$Tools\sbt\bin", $Downloads, "$Data\rrf", "$Profile\User")) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$HealthFile = Join-Path $State 'health.json'
Save-Json $HealthFile @{ status = 'running'; startedAt = (Get-Date).ToUniversalTime().ToString('o') }
# Protect local setup state; existing database credentials are never persisted here.
Protect-BootstrapState $State
if (-not $env:PGPASSWORD -and $DbUser -ceq 'scala_lab') {
    $env:PGPASSWORD = 'aurora'
    Write-Host "Using the default lab credentials for '$DbUser'. PGPASSWORD can select an existing password."
}
if (-not $env:PGPASSWORD) {
    if (-not (Test-BootstrapInteractive)) { throw 'Supply the lab password via PGPASSWORD for a noninteractive run.' }
    $securePassword = Read-Host "PostgreSQL lab password for $DbUser" -AsSecureString
    try { $env:PGPASSWORD = [System.Net.NetworkCredential]::new('', $securePassword).Password }
    finally { $securePassword.Dispose(); Remove-Variable securePassword }
    if (-not $env:PGPASSWORD) { throw 'A PostgreSQL password is required by the Scala application.' }
}
$env:PGHOST = $PgHost
$env:PGPORT = [string]$Port
$env:PGDATABASE = $Database
$env:PGUSER = $DbUser
$env:PGCONNECT_TIMEOUT = '10'
# Match the loopback-only JDBC connection; do not let inherited libpq settings
# redirect only psql to another server. The original values are restored on exit.
$env:PGSSLMODE = 'disable'
Remove-Item Env:PGHOSTADDR, Env:PGSERVICE -ErrorAction SilentlyContinue

# Verify the selected database before network synchronization or builds.
Open-LabDatabase

# Work from Root so a managed checkout is not the current directory while moved.
Set-Location -LiteralPath $Root
# Update compatible checkouts in place; preserve incompatible copies for explicit reconciliation.
$RepoHeads = @(
    Sync-Repo 'scala-testing-lab' $ScalaBranch @('target/*', 'project/target/*', 'project/project/target/*', '.metals/*', '.bsp/*', '.bloop/*')
    Sync-Repo 'langium_dsl_lab' $LangiumBranch @('clinical-dsl-demo/node_modules/*', 'clinical-dsl-demo/packages/*/node_modules/*', 'clinical-dsl-demo/packages/*/out/*', 'clinical-dsl-demo/*.tsbuildinfo', 'clinical-dsl-demo/packages/language/src/generated/*', 'clinical-dsl-demo/packages/language/syntaxes/*', 'clinical-dsl-demo/packages/extension/syntaxes/*')
)
# A downloaded/old bootstrap must use the newly fetched setup logic this run.
$UpdatedScript = Join-Path $Scala 'scripts\bootstrap-windows.ps1'
if ((Get-FileHash -LiteralPath $UpdatedScript -Algorithm SHA256).Hash -ne $EntryHash) {
    if ($RelaunchCount -ge 2) { throw 'Bootstrap changed repeatedly while updating. Rerun once upstream is stable.' }
    Write-Host 'Bootstrap changed upstream; restarting with the updated script.'
    $next = @{ Root = $Root; Port = $Port; ContainerName = $ContainerName; VolumeName = $VolumeName; ScalaBranch = $ScalaBranch; LangiumBranch = $LangiumBranch; NoEditor = [bool]$NoEditor; StartupTimeoutSeconds = $StartupTimeoutSeconds; RelaunchCount = ($RelaunchCount + 1) }
    $next.ScalaRepoPath = $Scala; $next.LangiumRepoPath = $RepoDirectories['langium_dsl_lab']; $next.SetupPath = $Automatic
    $next.UseDocker = [bool]$UseDocker
    foreach ($option in @('JavaPath', 'NodePath', 'NpmPath', 'SbtLauncherPath', 'AllowToolUpgrade', 'GitPath', 'CodePath', 'AdditionalSearchPath', 'SessionOnlyEnvironment')) {
        if ($PSBoundParameters.ContainsKey($option)) { $next[$option] = $PSBoundParameters[$option] }
    }
    if (-not $UseDocker) {
        $next.PgHost = $PgHost; $next.Database = $Database; $next.DbUser = $DbUser
        if ($PSBoundParameters.ContainsKey('PsqlPath')) { $next.PsqlPath = $PsqlPath }; $next.PgServiceName = $PgServiceName
        if ($ProvisionDatabase) { $next.ProvisionDatabase = $true }
        $next.PgAdminUser = $PgAdminUser
    }
    & $UpdatedScript @next
    return
}
# Inspect the project's exact Scala compiler before a launcher probe can resolve it.
$compilerCheck = Join-Path $Scala 'scripts\check-scala.cjs'
& $selectedTools.Node.path $compilerCheck $Scala --fast
$compilerStatus = $LASTEXITCODE
if ($compilerStatus -eq 12) {
    $scalaCandidates = @((Get-ToolInventory).Scala)
    if ($script:ToolSearchErrors.Shared.Count) { throw "Scala installation discovery was incomplete: $($script:ToolSearchErrors.Shared -join '; ')" }
    # Windows limits command-line length; the inventory may contain thousands of paths.
    $inventoryFile = Join-Path $State ('scala-inventory-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($inventoryFile, (ConvertTo-Json -Compress -InputObject @($scalaCandidates)), $Utf8)
        & $selectedTools.Node.path $compilerCheck $Scala --inventory-file $inventoryFile
        $compilerStatus = $LASTEXITCODE
    } finally {
        if (Test-Path -LiteralPath $inventoryFile) { Remove-Item -LiteralPath $inventoryFile -Force }
    }
}
if ($compilerStatus -eq 11) {
    if (-not (Confirm-ToolUpgrade 'Scala project compiler' 'Allow sbt to obtain the compiler pinned in build.sbt for this workspace, preserving the installed Scala?')) {
        throw 'Scala project compiler change declined.'
    }
} elseif ($compilerStatus -ne 0) { throw 'Scala compiler discovery was inconclusive.' }
# Select the launcher once; both the build and the editor use this verified path.
$Launcher = Resolve-SbtLauncher (Join-Path $Tools 'sbt\bin\sbt-launch.jar')
$SbtHome = Split-Path (Split-Path $Launcher -Parent) -Parent
[Environment]::SetEnvironmentVariable('SBT_HOME', $SbtHome, 'Process')
if (-not $SessionOnlyEnvironment -and [Environment]::GetEnvironmentVariable('SBT_HOME','User') -ne $SbtHome) { [Environment]::SetEnvironmentVariable('SBT_HOME', $SbtHome, 'User') }
Save-Json "$Tools\layout.json" ([ordered]@{ javaHome = $JavaHome; nodeHome = $NodeHome; sbtHome = $SbtHome })
# The verifier and the project are from the same synced Scala checkout.
$workspaceCheck = Join-Path $Scala 'scripts\check-workspace.cjs'
Push-Location $Langium
try {
    & $selectedTools.Node.path $workspaceCheck check
    $dependencyStatus = $LASTEXITCODE
    if ($dependencyStatus -in @(10, 11)) {
        $globalRoot = & $selectedTools.Node.npm root --global
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the selected npm global prefix.' }
        & $selectedTools.Node.path $workspaceCheck inspect-globals $globalRoot
        $globalStatus = $LASTEXITCODE
        if ($globalStatus -notin @(0, 11)) { throw 'Global Langium discovery was inconclusive.' }
        if (($dependencyStatus -eq 11 -or $globalStatus -eq 11) -and
            -not (Confirm-ToolUpgrade 'Langium workspace' 'Install the versions in package-lock.json in this workspace? Global packages will be preserved.')) {
            throw 'Workspace dependency version change declined.'
        }
        $before = Run { & $selectedTools.Node.path $workspaceCheck snapshot }
        Run { & $selectedTools.Node.path $workspaceCheck prepare-install $globalRoot $selectedTools.Node.npm } | Out-Host
        Run { & $selectedTools.Node.npm install --prefer-offline --no-save --ignore-scripts --include=dev --no-audit --no-fund } | Out-Host
        $after = Run { & $selectedTools.Node.path $workspaceCheck snapshot }
        if ($after -ne $before) { throw 'npm changed a source manifest; inspect the changes before proceeding.' }
        Run { & $selectedTools.Node.path $workspaceCheck check } | Out-Host
    } elseif ($dependencyStatus -ne 0) { throw 'Workspace discovery was inconclusive. Inspect the reported entries.' }
    Run { & $selectedTools.Node.npm run langium:generate } | Out-Host
    Run { & $selectedTools.Node.npm run build } | Out-Host
} finally { Pop-Location }
foreach ($artifact in @('packages\language\out\index.js', 'packages\extension\out\extension\main.cjs', 'packages\extension\out\language\main.cjs', 'packages\extension\syntaxes\clinical-dsl.tmLanguage.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Langium $artifact))) { throw "Missing build artifact: $artifact" }
}

if (-not $NoEditor) { Assert-CodeEngine $selectedTools.Code.path $Langium }
# skip the import if this data is ready
# Reuse a ready Full or prescribable archive only when release, policies and
# recorded base/product provenance agree. Authentication failures remain fatal.
$query = @"
SELECT 1 FROM rxnorm_lab.release r JOIN rxnorm_lab.product_release p USING (release)
WHERE r.release='2026-10-05' AND r.state='ready' AND p.state='ready' AND p.base_identity=r.identity
AND r.scope='all-active-rxnorm-pg-v4' AND p.policy='single-component-mass-v1'
AND r.sha256_json::jsonb->>'RXNCONSO.RRF' ~ '^[0-9a-fA-F]{64}$'
AND r.sha256_json::jsonb->>'RXNREL.RRF' ~ '^[0-9a-fA-F]{64}$'
AND p.sha256_json::jsonb->>'RXNSAT.RRF' ~ '^[0-9a-fA-F]{64}$'
AND p.sha256_json::jsonb->>'RXNCONSO.RRF'=r.sha256_json::jsonb->>'RXNCONSO.RRF'
AND p.sha256_json::jsonb->>'RXNREL.RRF'=r.sha256_json::jsonb->>'RXNREL.RRF';
"@
# Missing schema is a normal first-install state. Authentication/SQL failures
# must not be swallowed and mistaken for an absent import.
$manifest = Invoke-DatabaseSql "SELECT CASE WHEN to_regclass('rxnorm_lab.release') IS NULL THEN 'empty' WHEN to_regclass('rxnorm_lab.product_release') IS NULL THEN 'base' ELSE 'both' END;"
$ready = $false
if ($manifest -eq 'both') { $ready = (Invoke-DatabaseSql $query) -eq '1' }
$ImportCommands = @()
if (-not $ready) {
    if ($manifest -ne 'empty' -and (Invoke-DatabaseSql "SELECT count(*) FROM rxnorm_lab.release WHERE release='2026-10-05';") -ne '0') {
        throw 'The local 2026-10-05 import is incomplete or incompatible. Complete it using its original matching RxNorm archive (README section 7), or select a separate empty database. No existing release was replaced.'
    }
    $rrfDirectory = Join-Path $Data 'rrf'
    Get-RxNormFiles $rrfDirectory (Join-Path $Downloads 'RxNorm_full_prescribe_10052026.zip')
    $rrf = ConvertTo-SbtPath $rrfDirectory
    $ImportCommands = @("run import-rxnorm $rrf 2026-10-05", "run import-product-attributes $rrf 2026-10-05")
} else { Write-Host 'Verified RxNorm import reused.' }

# leave an existing demo file alone
$Demo = Join-Path $Automatic 'aspirin-demo.clinical'
if (-not (Test-Path $Demo)) { [IO.File]::WriteAllText($Demo, "Patient P9999: age 30, condition Fever`nMedication aspirin: 100 mg, strength 325 mg, doseForm Oral Tablet, route PO, frequency PRN`nPlan DemoPlan: for P9999, prescribe aspirin`nshow DemoPlan`n", $Utf8) }
# Fresh fixtures/results live outside both repositories. Never overwrite the user's demo.
$SmokeName = 'smoke-' + [guid]::NewGuid().ToString('N')
$Smoke = Join-Path $State $SmokeName
New-Item -ItemType Directory -Path $Smoke | Out-Null
$fixture = "Patient P9999: age 30, condition Fever`nMedication aspirin: 100 mg, strength 325 mg, doseForm Oral Tablet, route PO, frequency PRN`nPlan DemoPlan: for P9999, prescribe aspirin`nshow DemoPlan`n"
$SmokeCommands = @('test') + $ImportCommands
foreach ($case in @('valid', 'invalid')) {
    $text = $fixture
    if ($case -eq 'invalid') { $text = $text.Replace('strength 325 mg', 'strength 32500 mg') }
    $inputFile = Join-Path $Smoke "$case.clinical"
    $astFile = Join-Path $Smoke "$case.ast.json"
    $resultFile = Join-Path $Smoke "$case.result.json"
    [IO.File]::WriteAllText($inputFile, $text, $Utf8)
    Run { node.exe "$Scala\bridge\export-ast.mjs" --langium-root $Langium --input $inputFile --release 2026-10-05 --output $astFile } | Out-Host
    # Repository and state directories can be at different depths or contain spaces.
    $astArg = ConvertTo-SbtPath $astFile
    $resultArg = ConvertTo-SbtPath $resultFile
    $SmokeCommands += "run resolve $astArg $resultArg"
}
# test compiles the project. The same sbt process runs both imports before resolution.
Invoke-Sbt $SmokeCommands
if ($ImportCommands.Count) {
    Invoke-DatabaseSql 'ANALYZE;' | Out-Host
    if ((Invoke-DatabaseSql $query) -ne '1') { throw 'RxNorm release/product index verification failed after import.' }
}
foreach ($case in @('valid', 'invalid')) {
    $resultFile = Join-Path $Smoke "$case.result.json"
    $report = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
    $items = @($report.resolutions)
    if ($report.terminologyRelease -ne '2026-10-05' -or $items.Count -ne 1) { throw "Unexpected $case smoke-test report." }
    $item = $items[0]
    if ($case -eq 'valid') {
        if ($item.status -ne 'resolved' -or -not $item.selectedProduct.rxcui -or -not $item.productEvidence) {
            throw "Valid clinical fixture did not resolve to a supported RxNorm product. Inspect $resultFile"
        }
    } elseif ($item.status -ne 'productNotFound' -or -not (@($item.diagnostics) -match '^PRODUCT_NOT_FOUND:')) {
        throw "Invalid fixture did not produce PRODUCT_NOT_FOUND. Inspect $resultFile"
    }
    Write-Host "PASS: $case .clinical -> Langium -> Scala -> PostgreSQL/RxNorm"
}
Run { node.exe "$Scala\scripts\probe-editor.mjs" lsp "$Langium\packages\extension\out\language\main.cjs" "$Smoke\valid.clinical" } | Out-Host
if ((Invoke-DatabaseSql 'SELECT 1;') -ne '1') { throw 'Final authenticated PostgreSQL health check failed.' }
# turn on auto-save and database checks
$settings = [ordered]@{}
$settingsFile = Join-Path $Profile 'User\settings.json'
if (Test-Path $settingsFile) { (Get-Content $settingsFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $settings[$_.Name] = $_.Value } }
$requiredSettings = @{
    'clinicalDsl.rxnorm.scalaRoot' = $Scala; 'clinicalDsl.rxnorm.toolsRoot' = $Tools
    'clinicalDsl.rxnorm.release' = '2026-10-05'; 'clinicalDsl.rxnorm.onSave' = $true
    'files.autoSave' = 'afterDelay'; 'files.autoSaveDelay' = 1000
    'clinicalDsl.rxnorm.pgHost' = $PgHost; 'clinicalDsl.rxnorm.pgPort' = $Port
    'clinicalDsl.rxnorm.pgDatabase' = $Database; 'clinicalDsl.rxnorm.pgUser' = $DbUser
    'clinicalDsl.rxnorm.timeoutSeconds' = 300
}
foreach ($key in $requiredSettings.Keys) { $settings[$key] = $requiredSettings[$key] }
Save-Json $settingsFile $settings
$autocomplete = Run { node.exe "$Scala\scripts\probe-editor.mjs" autocomplete $settingsFile }
# open the demo in the editor
if (-not $NoEditor) { Run { code.cmd --new-window --user-data-dir $Profile "--extensionDevelopmentPath=$Langium\packages\extension" $Langium $Demo } }
Save-Json $HealthFile @{
    status = 'ready'; checkedAt = (Get-Date).ToUniversalTime().ToString('o')
    root = $Root; setupDirectory = $Automatic; scalaRoot = $Scala; langiumRoot = $Langium
    repositories = $RepoHeads; postgres = 'authenticated-query-pass'; rxnorm = 'ready'
    databaseMode = $DatabaseMode; pgHost = $PgHost; pgPort = $Port; pgDatabase = $Database; pgUser = $DbUser
    scala = 'incremental-compile-test-pass'; langium = 'incremental-generate-build-pass'
    clinicalValid = 'pass'; clinicalInvalid = 'pass'; languageServer = 'initialize-diagnostics-pass'
    autocomplete = $autocomplete; smokeDirectory = $Smoke; editorLaunchRequested = (-not $NoEditor)
}
& node.exe "$Scala\scripts\finish-smoke.mjs" $Smoke
Write-Host "RxNorm autocomplete: $autocomplete. See $Scala\PRODUCT-AUTOCOMPLETE.md for the editor service."
Write-Host "READY: repository updates, builds, PostgreSQL, RxNorm and runtime smoke tests passed."
Write-Host "Demo: $Demo"
Write-Host "Health report: $HealthFile"
Write-Host 'sbt/npm are completed build commands, not background services. The editor owns its Node language server.'
if (-not $NoEditor) { Write-Host 'VS Code launch requested; editor-extension activation is not asserted by this headless check.' }
Write-Host 'Change strength 325 mg to strength 32500 mg and pause to see PRODUCT_NOT_FOUND.'
} catch {
    if ($HealthFile) {
        try { Save-Json $HealthFile @{ status = 'failed'; failedAt = (Get-Date).ToUniversalTime().ToString('o'); error = $_.Exception.Message } }
        catch { Write-Warning 'Could not write the failed health report.' }
    }
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($HealthFile) { Write-Host "Details: $HealthFile" }
    if ($RelaunchCount -eq 0 -and (Test-BootstrapInteractive)) {
        try { Read-Host 'Press Enter after reading the error' | Out-Null } catch { }
    }
    throw
} finally {
    foreach ($name in $PreviousEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $PreviousEnvironment[$name], 'Process') }
    Set-Location $OriginalLocation
}
