# setup options
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Root = (Join-Path $PSScriptRoot 'AuroraMedicationLab'),
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
    [string]$GitPath,
    [string]$CodePath,
    [string]$DockerPath,
    [string[]]$AdditionalSearchPath = @(),
    [switch]$SessionOnlyEnvironment,
    [string]$RuntimeContainerName = 'aurora-medication-runtime',
    [string]$RuntimeVolumeName = 'aurora-medication-workspace',
    [string]$RuntimeCacheVolumeName = 'aurora-medication-caches',
    [string]$RuntimeImage = 'ubuntu:24.04',
    [string]$PgServiceName,
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
foreach ($name in @('PGHOST', 'PGPORT', 'PGDATABASE', 'PGUSER', 'PGPASSWORD', 'POSTGRES_PASSWORD', 'PGCONNECT_TIMEOUT', 'PGSSLMODE', 'PGHOSTADDR', 'PGSERVICE')) {
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
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 8), $Utf8)
}

# Discover once, then reuse verified executables. A failed search is never absence.
function Initialize-ToolDiscovery {
    $script:ToolInventory = $null
    $script:ToolSearchErrors = New-Object 'System.Collections.Generic.List[string]'
    $script:ToolRecords = @{}
    $script:ToolRoots = New-Object 'System.Collections.Generic.List[string]'
    $script:ToolDefinitions = @{
        Java = @{ executable = 'java.exe'; hint = 'JAVA_HOME'; relative = 'bin\java.exe'; registry = 'Java|JDK|OpenJDK|Temurin|Corretto|Zulu'; package = 'Microsoft.OpenJDK.21' }
        Node = @{ executable = 'node.exe'; hint = 'NODE_HOME'; relative = 'node.exe'; registry = 'Node[.]?js|Node.js'; package = 'OpenJS.NodeJS.LTS' }
        Git = @{ executable = 'git.exe'; hint = 'GIT_HOME'; relative = 'cmd\git.exe'; registry = '^Git( |$)|Git for Windows'; package = 'Git.Git' }
        PostgreSQL = @{ executable = 'psql.exe'; hint = 'PGHOME'; relative = 'bin\psql.exe'; registry = 'PostgreSQL'; package = 'PostgreSQL.PostgreSQL.18' }
        Code = @{ executable = 'code.cmd'; hint = 'VSCODE_HOME'; relative = 'bin\code.cmd'; registry = 'Visual Studio Code'; package = 'Microsoft.VisualStudioCode' }
        Docker = @{ executable = 'docker.exe'; hint = 'DOCKER_HOME'; relative = 'resources\bin\docker.exe'; registry = 'Docker Desktop'; package = 'Docker.DockerDesktop' }
    }
    if ($UseDocker) {
        foreach ($name in @('Java', 'Node', 'Git', 'PostgreSQL')) { $script:ToolDefinitions.Remove($name) }
    } else { $script:ToolDefinitions.Remove('Docker') }
    if ($NoEditor) { $script:ToolDefinitions.Remove('Code') }
    foreach ($name in $script:ToolDefinitions.Keys) {
        $script:ToolRecords[$name] = New-Object 'System.Collections.Generic.List[object]'
    }
    # Do not use Win32_Product: it can trigger MSI repair operations.
    foreach ($registryRoot in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        try {
            if (-not (Test-Path -LiteralPath $registryRoot -ErrorAction Stop)) { continue }
            foreach ($key in Get-ChildItem -LiteralPath $registryRoot -ErrorAction Stop) {
                $record = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                foreach ($name in $script:ToolDefinitions.Keys) {
                    if ([string]$record.DisplayName -match $script:ToolDefinitions[$name].registry) {
                        $script:ToolRecords[$name].Add(@{ description = [string]$record.DisplayName; location = [string]$record.InstallLocation })
                    }
                }
            }
        } catch { $script:ToolSearchErrors.Add("Registry discovery failed at ${registryRoot}: $($_.Exception.Message)") }
    }
    # Vendor records include installations not represented by uninstall entries.
    if (-not $UseDocker) {
    foreach ($vendorRoot in @('HKLM:\SOFTWARE\JavaSoft\JDK', 'HKLM:\SOFTWARE\JavaSoft\Java Development Kit', 'HKLM:\SOFTWARE\Eclipse Adoptium\JDK', 'HKLM:\SOFTWARE\Microsoft\JDK')) {
        try {
            if (-not (Test-Path -LiteralPath $vendorRoot -ErrorAction Stop)) { continue }
            foreach ($key in @(Get-Item -LiteralPath $vendorRoot) + @(Get-ChildItem -LiteralPath $vendorRoot -Recurse -ErrorAction Stop)) {
                $record = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                foreach ($property in @('JavaHome', 'Path', 'InstallationPath')) {
                    if ($record.$property) { $script:ToolRecords.Java.Add(@{ description = "Java vendor registry: $($key.Name)"; location = [string]$record.$property }) }
                }
            }
        } catch { $script:ToolSearchErrors.Add("Java registry discovery failed at ${vendorRoot}: $($_.Exception.Message)") }
    }
    foreach ($vendor in @(
        @{ name = 'Node'; path = 'HKLM:\SOFTWARE\Node.js'; property = 'InstallPath' },
        @{ name = 'Node'; path = 'HKCU:\SOFTWARE\Node.js'; property = 'InstallPath' },
        @{ name = 'Git'; path = 'HKLM:\SOFTWARE\GitForWindows'; property = 'InstallPath' },
        @{ name = 'Git'; path = 'HKCU:\SOFTWARE\GitForWindows'; property = 'InstallPath' },
        @{ name = 'PostgreSQL'; path = 'HKLM:\SOFTWARE\PostgreSQL\Installations'; property = 'Base Directory' }
    )) {
        try {
            if (-not (Test-Path -LiteralPath $vendor.path -ErrorAction Stop)) { continue }
            foreach ($key in @(Get-Item -LiteralPath $vendor.path) + @(Get-ChildItem -LiteralPath $vendor.path -ErrorAction Stop)) {
                $record = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                if ($record.($vendor.property)) {
                    $script:ToolRecords[$vendor.name].Add(@{ description = "Vendor registry: $($key.Name)"; location = [string]$record.($vendor.property) })
                }
            }
        } catch { $script:ToolSearchErrors.Add("Vendor registry discovery failed at $($vendor.path): $($_.Exception.Message)") }
    }
    try {
        foreach ($service in @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.Name -match 'postgres' -or $_.PathName -match '(?:pg_ctl|postgres)[.]exe' })) {
            $match = [regex]::Match([string]$service.PathName, '^\s*(?:"(?<exe>[^"]+)"|(?<exe>.*?\.exe))(?:\s|$)')
            $location = if ($match.Success) { Split-Path (Split-Path $match.Groups['exe'].Value -Parent) -Parent } else { '' }
            $script:ToolRecords.PostgreSQL.Add(@{ description = "Windows service $($service.Name)"; location = $location })
        }
    } catch { $script:ToolSearchErrors.Add("PostgreSQL service discovery failed: $($_.Exception.Message)") }
    }
    foreach ($directory in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432) + @($AdditionalSearchPath)) {
        if ($directory -and -not $script:ToolRoots.Contains($directory)) { $script:ToolRoots.Add($directory) }
    }
    # User installations and version managers; never recursively search all of HOME.
    foreach ($directory in @("$env:LOCALAPPDATA\Programs", "$env:LOCALAPPDATA\Microsoft\WinGet\Packages", "$env:LOCALAPPDATA\nvm", "$env:APPDATA\nvm", "$env:USERPROFILE\.jdks", "$env:USERPROFILE\scoop\apps", $env:NVM_HOME, $env:JDK_HOME)) {
        if ($directory -and (Test-Path -LiteralPath $directory)) { $script:ToolRoots.Add($directory) }
    }
}
function Get-ToolInventory {
    if ($null -ne $script:ToolInventory) { return $script:ToolInventory }
    $inventory = @{}
    foreach ($name in $script:ToolDefinitions.Keys) { $inventory[$name] = New-Object 'System.Collections.Generic.List[string]' }
    $names = @{}
    foreach ($name in $script:ToolDefinitions.Keys) { $names[$script:ToolDefinitions[$name].executable] = $name }
    $seen = @{}
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    foreach ($directory in $script:ToolRoots) { $pending.Push($directory) }
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        if ($seen.ContainsKey($directory)) { continue }
        $seen[$directory] = $true
        try {
            if (-not (Test-Path -LiteralPath $directory -ErrorAction Stop)) {
                # Additional search roots are explicit evidence requirements.
                if ($directory -in $AdditionalSearchPath) { throw 'Configured search directory does not exist.' }
                continue
            }
            $item = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            foreach ($child in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($child.PSIsContainer) { $pending.Push($child.FullName) }
                elseif ($names.ContainsKey($child.Name)) { $inventory[$names[$child.Name]].Add($child.FullName) }
            }
        } catch { $script:ToolSearchErrors.Add("Cannot inspect ${directory}: $($_.Exception.Message)") }
    }
    $script:ToolInventory = $inventory
    return $inventory
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
    $arguments = if ($Name -eq 'Java') { @('-version') } else { @('--version') }
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
            if ($version.Major -ne 21) { $result.reason = 'Java 21 is required.'; return $result }
            # PATH can point at an Oracle javapath shim, not the runtime's bin
            # directory. Ask the selected executable which installation it uses.
            $settings = Invoke-ToolVersion $Executable @('-XshowSettings:properties', '-version')
            $homeMatch = [regex]::Match($settings.text, '(?m)^\s*java[.]home\s*=\s*([^\r\n]+)\s*$')
            if (-not $settings.ok -or -not $homeMatch.Success) {
                $result.reason = 'The selected Java cannot report java.home; repair or select a complete installation.'; return $result
            }
            $runtimeHome = $homeMatch.Groups[1].Value.Trim()
            if (-not [IO.Path]::IsPathRooted($runtimeHome) -or $runtimeHome -match '[\x00\r\n]') {
                $result.reason = 'The selected Java reported an invalid java.home.'; return $result
            }
            $canonicalJava = Join-Path ([IO.Path]::GetFullPath($runtimeHome)) 'bin\java.exe'
            if (-not (Test-Path -LiteralPath $canonicalJava -PathType Leaf)) {
                $result.reason = "Java reports '$runtimeHome', but its bin\java.exe is missing or inaccessible."; return $result
            }
            $canonicalProbe = Invoke-ToolVersion $canonicalJava @('-version')
            $canonicalMatch = [regex]::Match($canonicalProbe.text, $versionPattern)
            if (-not $canonicalProbe.ok -or -not $canonicalMatch.Success -or $canonicalMatch.Groups['major'].Value -ne '21') {
                $result.reason = 'The executable under the reported java.home is not a runnable Java 21 installation.'; return $result
            }
            $result.discoveredPath = $Executable
            $result.path = $canonicalJava
            $result.javaHome = [IO.Path]::GetFullPath($runtimeHome)
            $canonicalMinor = if ($canonicalMatch.Groups['minor'].Success) { $canonicalMatch.Groups['minor'].Value } else { '0' }
            $canonicalPatch = if ($canonicalMatch.Groups['patch'].Success) { $canonicalMatch.Groups['patch'].Value } else { '0' }
            $result.version = [version]("21.{0}.{1}" -f $canonicalMinor, $canonicalPatch)
        }
        Node {
            if ($version -lt [version]'22.12.0') { $result.reason = 'Node >=22.12 is required.'; return $result }
            $npm = Join-Path (Split-Path $Executable -Parent) 'npm.cmd'
            if (-not (Test-Path -LiteralPath $npm -PathType Leaf)) { $result.reason = 'The Node installation is incomplete: npm.cmd is missing.'; return $result }
            $previousPath = $env:PATH
            try { $env:PATH = (Split-Path $Executable -Parent) + ';' + $previousPath; $npmProbe = Invoke-ToolVersion $npm @('--version') }
            finally { $env:PATH = $previousPath }
            $npmMatch = [regex]::Match($npmProbe.text, '(?m)^\s*(\d+\.\d+\.\d+)\s*$')
            if (-not $npmProbe.ok -or -not $npmMatch.Success -or [version]$npmMatch.Groups[1].Value -lt [version]'10.2.3') {
                $result.reason = 'The installed npm must be runnable and >=10.2.3; explicit repair is required.'; return $result
            }
            $result.npm = $npm; $result.npmVersion = $npmMatch.Groups[1].Value
        }
        Git { if ($version -lt [version]'2.23.0') { $result.reason = 'Git >=2.23 is required for restore and branch --show-current.'; return $result } }
        PostgreSQL {
            if ($version.Major -lt 16) { $result.reason = 'PostgreSQL client >=16 is required.'; return $result }
            $ready = Join-Path (Split-Path $Executable -Parent) 'pg_isready.exe'
            if (-not (Test-Path -LiteralPath $ready -PathType Leaf)) { $result.reason = 'The PostgreSQL tools are incomplete: pg_isready.exe is missing.'; return $result }
            $readyProbe = Invoke-ToolVersion $ready @('--version')
            if (-not $readyProbe.ok -or $readyProbe.text -notmatch ('\b' + $version.Major + '\.')) { $result.reason = 'pg_isready must be runnable and match the selected psql major version.'; return $result }
        }
        Docker { if ($version.Major -lt 20) { $result.reason = 'Docker CLI >=20 is required.'; return $result } }
    }
    $result.state = 'compatible'
    return $result
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
    foreach ($command in @(Get-Command $definition.executable -CommandType Application -All -ErrorAction SilentlyContinue)) { $candidates.Add($command.Source) }
    $hint = [Environment]::GetEnvironmentVariable($definition.hint, 'Process')
    if ($hint) {
        $candidates.Add((Join-Path $hint $definition.relative))
        if (Test-Path -LiteralPath $hint) { $evidence.Add("$($definition.hint)=$hint") }
    }
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
            } catch { $script:ToolSearchErrors.Add("Cannot inspect vendor path under ${directory}: $($_.Exception.Message)") }
        }
    }
    $tested = @{}; $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in $candidates) {
        if ($tested.ContainsKey($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $tested[$candidate] = $true
        $result = Test-ToolCandidate $Name $candidate
        if ($result.state -eq 'compatible') { return $result }
        $failures.Add("${candidate}: $($result.reason) (version $($result.version))")
    }
    $inventory = Get-ToolInventory
    foreach ($candidate in $inventory[$Name]) {
        if ($tested.ContainsKey($candidate)) { continue }
        $tested[$candidate] = $true
        $result = Test-ToolCandidate $Name $candidate
        if ($result.state -eq 'compatible') { return $result }
        $failures.Add("${candidate}: $($result.reason) (version $($result.version))")
    }
    if ($failures.Count -gt 0 -or $evidence.Count -gt 0) {
        return @{ state = 'incompatible'; name = $Name; reason = (@($failures) + @($evidence) -join '; ') }
    }
    if ($script:ToolSearchErrors.Count -gt 0) { return @{ state = 'inconclusive'; name = $Name; reason = ($script:ToolSearchErrors -join '; ') } }
    return @{ state = 'missing'; name = $Name; reason = 'No installation found after complete discovery.' }
}
function Resolve-SystemTool([string]$Name, [string]$ExplicitPath) {
    $result = Find-SystemTool $Name $ExplicitPath
    if ($result.state -eq 'missing') {
        $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue
        if (-not $winget) { throw "$Name is not installed. WinGet is unavailable; install $($script:ToolDefinitions[$Name].package), then rerun." }
        Write-Host "$Name is not installed. Installing only $($script:ToolDefinitions[$Name].package); WinGet may request elevation, configuration, or a reboot."
        & $winget.Source install --id $script:ToolDefinitions[$Name].package --exact --source winget --no-upgrade --accept-source-agreements --accept-package-agreements
        $installerExit = $LASTEXITCODE
        if ($installerExit -ne 0) { throw "$Name installer returned $installerExit. Complete any required elevation/reboot/configuration and rerun; setup is not ready." }
        Initialize-ToolDiscovery
        $result = Find-SystemTool $Name $ExplicitPath
        if ($result.state -ne 'compatible') { throw "$Name did not pass post-install discovery/version validation ($($result.state)): $($result.reason). Complete installer configuration and rerun." }
    }
    if ($result.state -ne 'compatible') { throw "$Name discovery: $($result.state). $($result.reason) No installation or upgrade was attempted; repair/select the intended installation explicitly." }
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
            Node { $homes.NODE_HOME = $directory }
            PostgreSQL { $homes.PGHOME = Split-Path $directory -Parent }
        }
    }
    foreach ($name in $homes.Keys) { [Environment]::SetEnvironmentVariable($name, $homes[$name], 'Process') }
    $env:PATH = Add-UniqueToolPath @($entries) $env:PATH
    if ($SessionOnlyEnvironment) { Write-Host 'Tool environment configured for this process and its children only.'; return }
    foreach ($name in $homes.Keys) { [Environment]::SetEnvironmentVariable($name, $homes[$name], 'User') }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    [Environment]::SetEnvironmentVariable('Path', (Add-UniqueToolPath @($entries) $userPath), 'User')
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
function Get-DockerObject([string]$Kind, [string]$Name) {
    $names = switch ($Kind) {
        'container' { @(Run { docker.exe container ls -a --format '{{.Names}}' }) }
        'volume' { @(Run { docker.exe volume ls --format '{{.Name}}' }) }
        default { throw "Unsupported Docker object type: $Kind" }
    }
    if ($Name -notin $names) { return $null }
    return @(Run { docker.exe $Kind inspect $Name } | ConvertFrom-Json)[0]
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
function Invoke-DockerRuntime {
    foreach ($name in @($ContainerName, $VolumeName, $RuntimeContainerName, $RuntimeVolumeName, $RuntimeCacheVolumeName)) {
        if ($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]+$') { throw "Unsupported Docker object name '$name'." }
    }
    if ($ContainerName -eq $RuntimeContainerName -or @($VolumeName, $RuntimeVolumeName, $RuntimeCacheVolumeName | Select-Object -Unique).Count -ne 3) {
        throw 'Database/runtime container names and database/workspace/cache volume names must be distinct.'
    }
    if ($RuntimeImage -match '[\s\x00]' -or -not $RuntimeImage) { throw 'Invalid runtime image name.' }
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
    $databaseContainer = Get-DockerObject 'container' $ContainerName
    $databaseWasStopped = ($null -ne $databaseContainer -and -not $databaseContainer.State.Running)
    $databaseVolume = Get-DockerObject 'volume' $VolumeName
    $runtimeContainer = Get-DockerObject 'container' $RuntimeContainerName
    $workspaceVolume = Get-DockerObject 'volume' $RuntimeVolumeName
    $cacheVolume = Get-DockerObject 'volume' $RuntimeCacheVolumeName
    if (-not $databaseContainer -and $databaseVolume) { throw "Database volume '$VolumeName' exists without its matching container. Recover its original container/credentials; no database was initialized." }
    if (-not $runtimeContainer -and ($workspaceVolume -or $cacheVolume)) { throw 'The persistent runtime workspace/cache exists without its matching container. Recover that container explicitly; existing workspace data was preserved.' }
    $dockerState = Join-Path $Root 'docker-runtime\state'
    New-Item -ItemType Directory -Path $dockerState -Force | Out-Null
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Run { icacls.exe $dockerState '/inheritance:r' '/grant:r' "${identity}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' } | Out-Null
    $secretPath = Join-Path $dockerState 'secrets.json'
    $secrets = $null
    if (Test-Path -LiteralPath $secretPath) { $secrets = Get-Content -LiteralPath $secretPath -Raw | ConvertFrom-Json }
    if (-not $secrets) {
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
    if (-not $secrets) { $secrets = @{ password = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'); port = $Port } }
    if (-not $secrets.password -or ($secrets.port -and [int]$secrets.port -ne $Port)) { throw 'Stored Docker credentials/port do not match the selected configuration.' }
    if ($databaseContainer) {
        $bindings = @($databaseContainer.HostConfig.PortBindings.'5432/tcp')
        $mounts = @($databaseContainer.Mounts | Where-Object { $_.Destination -eq '/var/lib/postgresql/data' })
        if ($databaseContainer.Config.Image -ne 'postgres:16' -or $bindings.Count -ne 1 -or
            $bindings[0].HostIp -ne '127.0.0.1' -or $bindings[0].HostPort -ne [string]$Port -or
            $mounts.Count -ne 1 -or $mounts[0].Type -ne 'volume' -or $mounts[0].Name -ne $VolumeName -or -not $mounts[0].RW -or
            'POSTGRES_USER=rxnorm_lab' -notin $databaseContainer.Config.Env -or 'POSTGRES_DB=rxnorm_public' -notin $databaseContainer.Config.Env -or
            "POSTGRES_PASSWORD=$($secrets.password)" -notin $databaseContainer.Config.Env -or
            $databaseContainer.HostConfig.NetworkMode -notin @('default', 'bridge')) {
            throw 'Existing PostgreSQL container has incompatible image, mounts, network, port, or credentials. No container/volume was replaced.'
        }
    }
    # Validate the runtime before starting or creating any service.
    if ($runtimeContainer) {
        $workMount = @($runtimeContainer.Mounts | Where-Object { $_.Destination -eq '/workspace' })
        $cacheMount = @($runtimeContainer.Mounts | Where-Object { $_.Destination -eq '/root' })
        $expectedNetwork = if ($databaseContainer) { 'container:' + $databaseContainer.Id } else { '' }
        if (-not $databaseContainer -or $runtimeContainer.Config.Image -ne $RuntimeImage -or
            $runtimeContainer.Config.Labels.'aurora.runtime.schema' -ne '1' -or $runtimeContainer.Config.Labels.'aurora.host.root' -ne $Root -or
            $workMount.Count -ne 1 -or $workMount[0].Type -ne 'volume' -or $workMount[0].Name -ne $RuntimeVolumeName -or -not $workMount[0].RW -or
            $cacheMount.Count -ne 1 -or $cacheMount[0].Type -ne 'volume' -or $cacheMount[0].Name -ne $RuntimeCacheVolumeName -or -not $cacheMount[0].RW -or
            $runtimeContainer.HostConfig.NetworkMode -ne $expectedNetwork -or
            'PGHOST=127.0.0.1' -notin $runtimeContainer.Config.Env -or 'PGPORT=5432' -notin $runtimeContainer.Config.Env -or
            'PGDATABASE=rxnorm_public' -notin $runtimeContainer.Config.Env -or 'PGUSER=rxnorm_lab' -notin $runtimeContainer.Config.Env -or
            "PGPASSWORD=$($secrets.password)" -notin $runtimeContainer.Config.Env) {
            throw 'Existing Linux runtime does not match its image, workspace/cache mounts, database namespace, host Root, or credentials. Recover/select the original configuration; no runtime was replaced.'
        }
    }
    Save-Json $secretPath @{ password = $secrets.password; port = $Port }
    $env:POSTGRES_PASSWORD = [string]$secrets.password
    $env:PGPASSWORD = [string]$secrets.password
    if (-not $databaseContainer) {
        $null = Ensure-DockerImage 'postgres:16'
        Run { docker.exe run -d --restart unless-stopped --name $ContainerName -e POSTGRES_USER=rxnorm_lab -e POSTGRES_DB=rxnorm_public -e POSTGRES_PASSWORD -p "127.0.0.1:${Port}:5432" -v "${VolumeName}:/var/lib/postgresql/data" postgres:16 } | Out-Host
        $databaseContainer = Get-DockerObject 'container' $ContainerName
    } elseif (-not $databaseContainer.State.Running) { Run { docker.exe start $ContainerName } | Out-Host }
    $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
    do {
        $probePreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & docker.exe exec $ContainerName pg_isready -h 127.0.0.1 -p 5432 -U rxnorm_lab -d rxnorm_public -t 3 *> $null
        $databaseReady = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = $probePreference
        if (-not $databaseReady) { Start-Sleep -Seconds 1 }
    } until ($databaseReady -or (Get-Date) -ge $deadline)
    if (-not $databaseReady) { throw 'PostgreSQL container did not become ready; no runtime tools were installed.' }
    $authenticated = Run { docker.exe exec -e PGPASSWORD $ContainerName psql -X -w -h 127.0.0.1 -U rxnorm_lab -d rxnorm_public -v ON_ERROR_STOP=1 -Atc 'SELECT 1;' }
    if ($authenticated -ne '1') { throw 'Existing PostgreSQL credentials failed authentication; no password was reset.' }
    $serverVersion = Run { docker.exe exec -e PGPASSWORD $ContainerName psql -X -w -h 127.0.0.1 -U rxnorm_lab -d rxnorm_public -v ON_ERROR_STOP=1 -Atc 'SHOW server_version_num;' }
    if ($serverVersion -notmatch '^16[0-9]{4}$') { throw 'The existing database server is incompatible with postgres:16; no database was upgraded.' }
    if (-not $runtimeContainer) {
        $null = Ensure-DockerImage $RuntimeImage
        $network = 'container:' + $databaseContainer.Id
        Run { docker.exe run -d --restart unless-stopped --name $RuntimeContainerName --network $network --label 'aurora.runtime.schema=1' --label "aurora.host.root=$Root" -v "${RuntimeVolumeName}:/workspace" -v "${RuntimeCacheVolumeName}:/root" -e PGHOST=127.0.0.1 -e PGPORT=5432 -e PGDATABASE=rxnorm_public -e PGUSER=rxnorm_lab -e PGPASSWORD $RuntimeImage sleep infinity } | Out-Host
    } elseif (-not $runtimeContainer.State.Running) { Run { docker.exe start $RuntimeContainerName } | Out-Host }
    elseif ($databaseWasStopped) {
        # A running sibling retains the old namespace when the database restarts.
        # Restart the same container to join the restored database namespace.
        Write-Host 'Rejoining the restarted database network namespace in the existing Linux runtime.'
        Run { docker.exe restart $RuntimeContainerName } | Out-Host
    }
    Write-Host "Linux workspace: Docker volume '$RuntimeVolumeName', mounted at /workspace in '$RuntimeContainerName'. Native repositories are not copied."
    Write-Host "Persistent caches: '$RuntimeCacheVolumeName'; database volume: '$VolumeName'."
    $unixScript = Join-Path $PSScriptRoot 'bootstrap-unix.sh'
    $temporaryScript = $null
    if (-not (Test-Path -LiteralPath $unixScript -PathType Leaf)) {
        $temporaryScript = Join-Path $dockerState 'bootstrap-unix.sh'
        $branchPath = (($ScalaBranch -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
        Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/bogdanparvu18/scala-testing-lab/$branchPath/scripts/bootstrap-unix.sh" -OutFile $temporaryScript
        $unixScript = $temporaryScript
    }
    Run { docker.exe cp $unixScript "${RuntimeContainerName}:/tmp/aurora-bootstrap-unix.sh" } | Out-Host
    Run { docker.exe exec $RuntimeContainerName bash /tmp/aurora-bootstrap-unix.sh --container-runtime --root /workspace --scala-branch $ScalaBranch --langium-branch $LangiumBranch --startup-timeout $StartupTimeoutSeconds } | Out-Host
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
function Ensure-LocalPostgres {
    if (Test-PostgresReady) { return }
    if ($PgServiceName) {
        $services = @(Get-Service | Where-Object { $_.Name -eq $PgServiceName })
    } else {
        $services = @(Get-Service -Name '*postgres*' -ErrorAction SilentlyContinue)
    }
    if ($services.Count -ne 1) {
        throw "No responding PostgreSQL at ${PgHost}:$Port. Start the intended Windows PostgreSQL service, or specify its exact -PgServiceName (found $($services.Count) candidates)."
    }
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
function Invoke-DatabaseSql([string]$Sql) {
    # Ignore psqlrc, disallow additional password prompts, and stop on SQL errors.
    # Passwords are inherited via the environment, never command-line arguments.
    Run { & $PsqlPath -X -w -h $PgHost -p $Port -U $DbUser -d $Database -v ON_ERROR_STOP=1 -Atc $Sql }
}
function Assert-Postgres {
    if (-not (Test-PostgresReady)) { throw "PostgreSQL is not accepting connections at ${PgHost}:$Port." }
    try { $answer = Invoke-DatabaseSql 'SELECT 1;' }
    catch { throw "PostgreSQL login failed at ${PgHost}:$Port for database '$Database', user '$DbUser'. Check the existing database, role and password. $($_.Exception.Message)" }
    if ($answer -ne '1') { throw 'Authenticated PostgreSQL query failed.' }
    $serverVersion = Invoke-DatabaseSql 'SHOW server_version_num;'
    $serverNumber = 0
    if (-not [int]::TryParse(([string]$serverVersion).Trim(), [ref]$serverNumber) -or $serverNumber -lt 160000) {
        throw "The selected PostgreSQL server version '$serverVersion' is outside this bootstrap's supported baseline (16+). No server upgrade was attempted."
    }
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
    Write-Host 'Default: existing local PostgreSQL, no Docker checks or commands. Connection defaults: PGHOST/PGPORT/PGDATABASE/PGUSER, then 127.0.0.1:5432 / scala_testing_lab / scala_lab. Explicit arguments override those defaults.'
    Write-Host 'Local mode uses PGPASSWORD or asks securely for the existing password. The database and login must already exist; no local role/password/database is created or replaced.'
    Write-Host 'A ready local RxNorm import with compatible manifests is reused. Empty databases receive the verified prescribable archive; incomplete/incompatible existing releases are not replaced.'
    Write-Host 'psql.exe is found on PATH or under Program Files\PostgreSQL; -PsqlPath supports custom installations. A single stopped PostgreSQL Windows service can be started; use -PgServiceName when several exist.'
    Write-Host 'Existing tools are discovered and version-checked outside PATH, including Program Files, registry/services and user installs. Only genuinely missing tools may use WinGet --no-upgrade.'
    Write-Host 'Options: -JavaPath/-NodePath/-GitPath/-CodePath/-DockerPath select executables; -AdditionalSearchPath adds search roots; -SessionOnlyEnvironment avoids saving tool homes/PATH to the user environment.'
    Write-Host 'Incompatible/incomplete tools or inaccessible discovery locations require explicit repair; they never trigger an automatic reinstall.'
    Write-Host '--Docker selects the complete toolchain in a persistent Linux workspace; existing native repository locations are reported and their files are preserved.'
    Write-Host 'Docker selection: -RuntimeContainerName, -RuntimeVolumeName, -RuntimeCacheVolumeName and -RuntimeImage (default ubuntu:24.04). Existing volumes/credentials are reused, never reset.'
    return
}
try {
# The two backends are explicit, never selected by probing Docker installation.
$DatabaseMode = 'local'
if ($UseDocker) {
    $DatabaseMode = 'docker'
    if (($PgHost -and $PgHost -ne '127.0.0.1') -or ($Database -and $Database -ne 'rxnorm_public') -or
        ($DbUser -and $DbUser -ne 'rxnorm_lab') -or $PsqlPath -or $PgServiceName) {
        throw '-UseDocker uses its managed rxnorm_public / rxnorm_lab database on 127.0.0.1. Local-only connection/tool/service options cannot be combined with it.'
    }
    if (-not $PSBoundParameters.ContainsKey('Port')) { $Port = 55433 }
    $PgHost = '127.0.0.1'; $Database = 'rxnorm_public'; $DbUser = 'rxnorm_lab'
} else {
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
if ($UseDocker) {
    if ($JavaPath -or $NodePath -or $GitPath -or $ScalaRepoPath -or $LangiumRepoPath) {
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
$selectedTools.Java = Resolve-SystemTool 'Java' $JavaPath
$selectedTools.Node = Resolve-SystemTool 'Node' $NodePath
$selectedTools.PostgreSQL = Resolve-SystemTool 'PostgreSQL' $PsqlPath
if (-not $NoEditor) { $selectedTools.Code = Resolve-SystemTool 'Code' $CodePath }
Use-ToolEnvironment $selectedTools
$Java = $selectedTools.Java.path
$JavaHome = $env:JAVA_HOME
$NodeHome = $env:NODE_HOME
$PsqlPath = $selectedTools.PostgreSQL.path
$PgIsReady = Join-Path (Split-Path -Parent $PsqlPath) 'pg_isready.exe'

# Resolve both paths before modifying either checkout or requesting credentials.
$layout = Find-InstallLayout
$RepoDirectories = $layout.repositories
$Automatic = $layout.automatic
$Scala = $RepoDirectories['scala-testing-lab']
$Langium = Join-Path $RepoDirectories['langium_dsl_lab'] 'clinical-dsl-demo'
Write-Host "Scala repository: $Scala"
Write-Host "Langium repository: $($RepoDirectories['langium_dsl_lab'])"
Write-Host "Setup directory: $Automatic"
# Keep state/data separate from the discovered repositories.
$State = Join-Path $Automatic 'state'
$Tools = Join-Path $Automatic 'tools'
$Downloads = Join-Path $Automatic 'downloads'
$Data = Join-Path $Automatic 'data\2026-10-05'
$Profile = Join-Path $Automatic 'editor-profile'
foreach ($directory in @($Root, $State, "$Tools\sbt\bin", $Downloads, "$Data\rrf", "$Profile\User")) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$HealthFile = Join-Path $State 'health.json'
Save-Json $HealthFile @{ status = 'running'; startedAt = (Get-Date).ToUniversalTime().ToString('o') }
# Protect local setup state; existing database credentials are never persisted here.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
Run { icacls.exe $State '/inheritance:r' '/grant:r' "${identity}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' } | Out-Null
if (-not $env:PGPASSWORD) {
    $securePassword = Read-Host "Existing PostgreSQL password for $DbUser" -AsSecureString
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
    foreach ($option in @('JavaPath', 'NodePath', 'GitPath', 'CodePath', 'AdditionalSearchPath', 'SessionOnlyEnvironment')) {
        if ($PSBoundParameters.ContainsKey($option)) { $next[$option] = $PSBoundParameters[$option] }
    }
    if (-not $UseDocker) {
        $next.PgHost = $PgHost; $next.Database = $Database; $next.DbUser = $DbUser
        $next.PsqlPath = $PsqlPath; $next.PgServiceName = $PgServiceName
    }
    & $UpdatedScript @next
    return
}
# get the scala launcher
$Launcher = Join-Path $Tools 'sbt\bin\sbt-launch.jar'
if (-not (Test-Path $Launcher)) { Invoke-WebRequest -UseBasicParsing 'https://repo.maven.apache.org/maven2/org/scala-sbt/sbt-launch/1.10.2/sbt-launch-1.10.2.jar' -OutFile $Launcher }
if ((Get-FileHash $Launcher).Hash -ne 'cdd6963b622f42690cb2e3154bde3f3257a03839f216e1b5d7420000d6a71817') { throw 'sbt launcher checksum failed.' }
Save-Json "$Tools\layout.json" @{ javaHome = $JavaHome; nodeHome = $NodeHome; sbtHome = "$Tools\sbt" }
# Verify actual packages; lockfile timestamps are not installation evidence.
$DependencyCheck = @'
// Exit 0 = verified, 10 = genuinely missing packages, 20 = incompatible/incomplete.
const fs = require('node:fs');
const path = require('node:path');
const root = process.cwd();
const missing = [], errors = [];
function json(file) { return JSON.parse(fs.readFileSync(file, 'utf8')); }
function safe(relative) {
    const absolute = path.resolve(root, relative);
    if (!absolute.startsWith(root + path.sep)) throw Error(`Lock path escapes workspace: ${relative}`);
    return absolute;
}
function eligible(entry) {
    for (const [field, actual] of [['os', process.platform], ['cpu', process.arch]]) {
        if (!entry[field]) continue;
        const list = Array.isArray(entry[field]) ? entry[field] : [entry[field]];
        if (list.includes('!' + actual) || (list.some(x => !x.startsWith('!')) && !list.includes(actual) && !list.includes('any'))) return false;
    }
    if (entry.libc && process.platform === 'linux') {
        const libc = process.report.getReport().header.glibcVersionRuntime ? 'glibc' : 'musl';
        const list = Array.isArray(entry.libc) ? entry.libc : [entry.libc];
        if (list.includes('!' + libc) || (list.some(x => !x.startsWith('!')) && !list.includes(libc) && !list.includes('any'))) return false;
    }
    return true;
}
try {
    const lock = json('package-lock.json');
    if (![2, 3].includes(lock.lockfileVersion) || !lock.packages) throw Error('A v2/v3 package-lock.json is required.');
    for (const [relative, entry] of Object.entries(lock.packages)) {
        if (entry.optional && !eligible(entry)) continue;
        if (!relative || !relative.split('/').includes('node_modules')) {
            const manifest = json(relative ? path.join(safe(relative), 'package.json') : 'package.json');
            if (entry.version && manifest.version !== entry.version) errors.push(`${relative || '.'}: workspace version disagrees with lock`);
            for (const field of ['dependencies', 'devDependencies', 'optionalDependencies']) {
                const normalized = object => JSON.stringify(Object.entries(object || {}).sort(([a], [b]) => a.localeCompare(b)));
                if (normalized(manifest[field]) !== normalized(entry[field])) errors.push(`${relative || '.'}: ${field} disagrees with lock`);
            }
            continue;
        }
        const location = safe(relative);
        let stat;
        try { stat = fs.lstatSync(location); }
        catch (error) { if (error.code === 'ENOENT') { missing.push(relative); continue; } throw error; }
        if (entry.link) {
            const target = safe(entry.resolved);
            if (!stat.isSymbolicLink() || fs.realpathSync(location) !== fs.realpathSync(target)) errors.push(`${relative}: wrong workspace link`);
            continue;
        }
        if (!stat.isDirectory() || stat.isSymbolicLink()) { errors.push(`${relative}: unexpected installation path`); continue; }
        let manifest;
        try { manifest = json(path.join(location, 'package.json')); }
        catch (error) { errors.push(`${relative}: installed directory is incomplete (${error.code || error.message})`); continue; }
        if (manifest.version !== entry.version) errors.push(`${relative}: installed ${manifest.version}, locked ${entry.version}`);
        const bins = typeof manifest.bin === 'string' ? {[manifest.name.split('/').pop()]: manifest.bin} : manifest.bin || {};
        for (const [name, executable] of Object.entries(bins)) {
            if (!fs.existsSync(path.resolve(location, executable))) errors.push(`${relative}: missing executable ${executable}`);
            const modules = location.slice(0, location.lastIndexOf(path.sep + 'node_modules' + path.sep)) + path.sep + 'node_modules';
            const shim = path.join(modules, '.bin', name + (process.platform === 'win32' ? '.cmd' : ''));
            if (!fs.existsSync(shim)) missing.push(path.relative(root, shim));
        }
    }
    if (errors.length) {
        console.error('Dependencies are incompatible/incomplete; explicitly reconcile them before retrying. No installation attempted.\n' + errors.slice(0, 30).join('\n'));
        process.exitCode = 20;
    } else if (missing.length) {
        console.log(`Missing dependency entries (${missing.length}): ${missing.slice(0, 20).join(', ')}`);
        process.exitCode = 10;
    } else console.log('All locked dependency versions and workspace links are installed; skipping npm installation.');
} catch (error) { console.error(`Dependency discovery inconclusive: ${error.message}`); process.exitCode = 20; }

'@
Push-Location $Langium
try {
    $DependencyCheck | node.exe -
    $dependencyStatus = $LASTEXITCODE
    if ($dependencyStatus -eq 10) {
        $manifestFiles = @('package.json', 'package-lock.json') + @(Get-ChildItem -LiteralPath 'packages' -Directory | ForEach-Object { Join-Path $_.FullName 'package.json' } | Where-Object { Test-Path -LiteralPath $_ })
        $manifestHashes = @{}
        foreach ($file in $manifestFiles) { $manifestHashes[$file] = (Get-FileHash -LiteralPath $file).Hash }
        # npm install preserves a healthy tree; --no-save keeps source manifests
        # fixed. Lifecycle scripts are disabled; build/runtime checks follow.
        Run { npm.cmd install --no-save --ignore-scripts --include=dev --no-audit --no-fund } | Out-Host
        foreach ($file in $manifestFiles) {
            if ((Get-FileHash -LiteralPath $file).Hash -ne $manifestHashes[$file]) { throw "npm changed source manifest '$file'; inspect it before proceeding." }
        }
        Run { $DependencyCheck | node.exe - } | Out-Host
    } elseif ($dependencyStatus -ne 0) { throw 'Dependency verification failed; no automatic reconciliation is permitted.' }
    Run { npm.cmd run langium:generate } | Out-Host
    Run { npm.cmd run build } | Out-Host
} finally { Pop-Location }
foreach ($artifact in @('packages\language\out\index.js', 'packages\extension\out\extension\main.cjs', 'packages\extension\out\language\main.cjs', 'packages\extension\syntaxes\clinical-dsl.tmLanguage.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Langium $artifact))) { throw "Missing build artifact: $artifact" }
}

if (-not $NoEditor) { Assert-CodeEngine $selectedTools.Code.path $Langium }
Ensure-LocalPostgres
Assert-Postgres
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
$hasManifest = Invoke-DatabaseSql "SELECT CASE WHEN to_regclass('rxnorm_lab.release') IS NOT NULL AND to_regclass('rxnorm_lab.product_release') IS NOT NULL THEN 1 ELSE 0 END;"
$ready = ''
if ($hasManifest -eq '1') { $ready = Invoke-DatabaseSql $query }
if ($ready -ne '1') {
    $hasBase = Invoke-DatabaseSql "SELECT CASE WHEN to_regclass('rxnorm_lab.release') IS NOT NULL THEN 1 ELSE 0 END;"
    if ($hasBase -eq '1') {
        $existingRelease = Invoke-DatabaseSql "SELECT count(*) FROM rxnorm_lab.release WHERE release='2026-10-05';"
        if ($existingRelease -ne '0') {
            throw 'The local 2026-10-05 import is incomplete or incompatible. Complete it using its original matching RxNorm archive (README section 7), or select a separate empty database. No existing release was replaced.'
        }
    }
}
if ($ready -ne '1') {
    # download and import the rxnorm files
    $Zip = Join-Path $Downloads 'RxNorm_full_prescribe_10052026.zip'
    if (-not (Test-Path $Zip)) { Invoke-WebRequest -UseBasicParsing 'https://download.nlm.nih.gov/rxnorm/RxNorm_full_prescribe_10052026.zip' -OutFile $Zip }
    if ((Get-FileHash $Zip).Hash -ne '8ed351c29f3cb56bedeb8e2bcb8fa56931f8d7eb88e2280dc9772d7d3eb16977') { throw 'RxNorm download checksum failed.' }
    Expand-Archive -LiteralPath $Zip -DestinationPath $Data -Force
    $rrf = ConvertTo-SbtPath (Join-Path $Data 'rrf')
    Invoke-Sbt @('compile', "run import-rxnorm $rrf 2026-10-05", "run import-product-attributes $rrf 2026-10-05")
    Invoke-DatabaseSql 'ANALYZE;' | Out-Host
} else { Write-Host 'RxNorm is already imported.' }
$verified = Invoke-DatabaseSql $query
if ($verified -ne '1') { throw 'RxNorm release/product index verification failed after import.' }

# leave an existing demo file alone
$Demo = Join-Path $Automatic 'aspirin-demo.clinical'
if (-not (Test-Path $Demo)) { [IO.File]::WriteAllText($Demo, "Patient P9999: age 30, condition Fever`nMedication aspirin: 100 mg, strength 325 mg, doseForm Oral Tablet, route PO, frequency PRN`nPlan DemoPlan: for P9999, prescribe aspirin`nshow DemoPlan`n", $Utf8) }
# Fresh fixtures/results live outside both repositories. Never overwrite the user's demo.
$SmokeName = 'smoke-' + [guid]::NewGuid().ToString('N')
$Smoke = Join-Path $State $SmokeName
New-Item -ItemType Directory -Path $Smoke | Out-Null
$fixture = "Patient P9999: age 30, condition Fever`nMedication aspirin: 100 mg, strength 325 mg, doseForm Oral Tablet, route PO, frequency PRN`nPlan DemoPlan: for P9999, prescribe aspirin`nshow DemoPlan`n"
$SmokeCommands = @('compile', 'test')
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
Invoke-Sbt $SmokeCommands
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
# Keep the real language-server readiness check inside this bootstrap. Pipe its
# code to Node over stdin; do not create or depend on a separate test/helper file.
$LspCheck = @'
// Inline readiness probe: no separate helper or test file is required.
import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

async function probeLanguageServer({ serverPath, documentPath, timeoutMs = 30000 }) {
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error('Invalid probe timeout.');
    const absoluteDocument = path.resolve(documentPath);
    const text = await readFile(absoluteDocument, 'utf8');
    const uri = pathToFileURL(absoluteDocument).href;
    const normalize = value => process.platform === 'win32' ? value.toLowerCase() : value;
    const sameDocument = value => {
        try { return normalize(path.resolve(fileURLToPath(value))) === normalize(absoluteDocument); }
        catch { return false; }
    };
    return new Promise((resolve, reject) => {
        const child = spawn(process.execPath, [path.resolve(serverPath), '--stdio'], {
            cwd: path.dirname(absoluteDocument), stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true
        });
        let buffer = Buffer.alloc(0);
        let stderr = '';
        let initialized = false;
        let validated = false;
        let shutdown = false;
        let failure;
        const fail = error => {
            failure ??= error instanceof Error ? error : new Error(String(error));
            child.kill('SIGKILL');
        };
        const timer = setTimeout(() => fail(new Error(`Language server timed out after ${timeoutMs} ms.`)), timeoutMs);
        function send(message) {
            const body = Buffer.from(JSON.stringify({ jsonrpc: '2.0', ...message }), 'utf8');
            child.stdin.write(Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]));
        }
        function receive(message) {
            if (message.method && message.id !== undefined) {
                if (message.method === 'workspace/configuration') {
                    send({ id: message.id, result: (message.params?.items ?? []).map(() => null) });
                } else if (['client/registerCapability', 'window/workDoneProgress/create', 'workspace/workspaceFolders'].includes(message.method)) {
                    send({ id: message.id, result: null });
                } else {
                    send({ id: message.id, error: { code: -32601, message: 'Not implemented by bootstrap probe' } });
                }
            } else if (message.id === 1) {
                if (message.error || !message.result?.capabilities) throw new Error(`Language-server initialize failed: ${JSON.stringify(message.error ?? message.result)}`);
                initialized = true;
                send({ method: 'initialized', params: {} });
                send({ method: 'textDocument/didOpen', params: { textDocument: { uri, languageId: 'clinical-dsl', version: 1, text } } });
            } else if (message.method === 'textDocument/publishDiagnostics' && sameDocument(message.params?.uri) && initialized && !validated) {
                if (message.params.version !== undefined && message.params.version !== 1) return;
                if (!Array.isArray(message.params.diagnostics)) throw new Error('Malformed document diagnostics.');
                const errors = message.params.diagnostics.filter(d => d.severity === 1);
                if (errors.length) throw new Error(`Clinical document validation failed: ${errors.map(e => e.message).join('; ')}`);
                validated = true;
                send({ id: 2, method: 'shutdown', params: null });
            } else if (message.id === 2) {
                if (!validated || message.error || message.result !== null) throw new Error('Language-server shutdown failed.');
                shutdown = true;
                send({ method: 'exit' });
                child.stdin.end();
            }
        }
        child.stdout.on('data', chunk => {
            if (failure) return;
            try {
                buffer = Buffer.concat([buffer, chunk]);
                if (buffer.length > 8 * 1024 * 1024) throw new Error('Language-server frame exceeds 8 MiB.');
                while (true) {
                    const boundary = buffer.indexOf('\r\n\r\n');
                    if (boundary < 0) break;
                    const header = buffer.subarray(0, boundary).toString('ascii');
                    const match = /^Content-Length:\s*(\d+)\s*$/im.exec(header);
                    if (!match) throw new Error('Invalid language-server Content-Length header.');
                    const length = Number(match[1]);
                    if (!Number.isSafeInteger(length) || length > 8 * 1024 * 1024) throw new Error('Invalid language-server frame size.');
                    const end = boundary + 4 + length;
                    if (buffer.length < end) break;
                    const message = JSON.parse(buffer.subarray(boundary + 4, end).toString('utf8'));
                    buffer = buffer.subarray(end);
                    receive(message);
                }
            } catch (error) { fail(error); }
        });
        child.stderr.on('data', chunk => { stderr = (stderr + chunk.toString()).slice(-8000); });
        child.stdin.on('error', fail);
        child.on('error', fail);
        child.on('close', (code, signal) => {
            clearTimeout(timer);
            if (failure) return reject(failure);
            if (code !== 0 || !initialized || !validated || !shutdown) {
                return reject(new Error(`Language server exited before readiness (code=${code}, signal=${signal}). ${stderr}`));
            }
            resolve({ initialized: true, validated: true, shutdown: true });
        });
        send({ id: 1, method: 'initialize', params: {
            processId: process.pid, rootUri: null, workspaceFolders: null,
            capabilities: { workspace: { configuration: false, workspaceFolders: false } }
        } });
    });
}

const [serverPath, documentPath] = process.argv.slice(2);
if (!serverPath || !documentPath) {
    console.error('Bootstrap language-server check requires server and document paths.');
    process.exitCode = 1;
} else {
    probeLanguageServer({ serverPath, documentPath }).then(() => {
        console.log('PASS: Node language server initialize -> .clinical diagnostics -> clean shutdown');
    }).catch(error => { console.error(error.message); process.exitCode = 1; });
}
'@
Run { $LspCheck | node.exe --input-type=module - "$Langium\packages\extension\out\language\main.cjs" "$Smoke\valid.clinical" } | Out-Host
Assert-Postgres
# turn on auto-save and database checks
$settings = @{}
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
# open the demo in the editor
if (-not $NoEditor) { Run { code.cmd --new-window --user-data-dir $Profile "--extensionDevelopmentPath=$Langium\packages\extension" $Langium $Demo } }
Save-Json $HealthFile @{
    status = 'ready'; checkedAt = (Get-Date).ToUniversalTime().ToString('o')
    root = $Root; setupDirectory = $Automatic; scalaRoot = $Scala; langiumRoot = $Langium
    repositories = $RepoHeads; postgres = 'authenticated-query-pass'; rxnorm = 'ready'
    databaseMode = $DatabaseMode; pgHost = $PgHost; pgPort = $Port; pgDatabase = $Database; pgUser = $DbUser
    scala = 'incremental-compile-test-pass'; langium = 'incremental-generate-build-pass'
    clinicalValid = 'pass'; clinicalInvalid = 'pass'; languageServer = 'initialize-diagnostics-pass'
    smokeDirectory = $Smoke; editorLaunchRequested = (-not $NoEditor)
}
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
    throw
} finally {
    foreach ($name in $PreviousEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $PreviousEnvironment[$name], 'Process') }
    Set-Location $OriginalLocation
}
