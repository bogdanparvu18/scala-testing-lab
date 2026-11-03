# setup options
param(
    [string]$Root = (Get-Location).Path,
    [string]$ScalaRepoPath,
    [string]$LangiumRepoPath,
    [string]$SetupPath,
    [switch]$UseDocker,
    [ValidateRange(1, 65535)][int]$Port = 5432,
    [string]$PgHost,
    [string]$Database,
    [string]$DbUser,
    [string]$PsqlPath,
    [string]$PgServiceName,
    [string]$ContainerName = 'aurora-medication-auto-pg',
    [string]$VolumeName = 'aurora-medication-auto-pgdata',
    [string]$ScalaBranch = 'main',
    [string]$LangiumBranch = 'main',
    [switch]$NoEditor,
    [switch]$Help,
    [ValidateRange(30, 600)][int]$StartupTimeoutSeconds = 180,
    [Parameter(DontShow = $true)][ValidateRange(0, 2)][int]$RelaunchCount = 0
)

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

# Root is the search boundary: GitHub is the source of the active code.
# An incompatible existing copy is retained whole before a verified clone is
# installed. Database/state directories and copies outside Root are never moved.
function Install-FreshRepo([string]$Name, [string]$BranchName, [string]$Reason) {
    $directory = $RepoDirectories[$Name]
    $url = "https://github.com/bogdanparvu18/$Name.git"
    $parent = Split-Path -Parent $directory
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $stage = Join-Path $parent ('.bootstrap-' + $Name + '-' + [guid]::NewGuid().ToString('N'))
    $backup = $null
    $previousWasDirectory = $false
    Write-Host "${Name}: $Reason. Preparing the latest origin/$BranchName."
    Push-Location -LiteralPath $Root
    try {
        # Download and verify FIRST. A failed clone leaves the old copy in place.
        Run { git.exe clone --branch $BranchName -- $url $stage } | Out-Host
        $remoteRef = "refs/remotes/origin/$BranchName"
        $expected = (Run { git.exe -C $stage rev-parse $remoteRef }).Trim()
        $after = (Run { git.exe -C $stage rev-parse HEAD }).Trim()
        if ($after -ne $expected) { throw "$Name clone does not match origin/$BranchName." }
        if (Test-Path -LiteralPath $directory) {
            $item = Get-Item -LiteralPath $directory -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "$directory is a link/junction, not a managed copy. Choose a Root with ordinary directories; the external target was not modified."
            }
            $backups = Join-Path $Automatic 'backups'
            New-Item -ItemType Directory -Path $backups -Force | Out-Null
            $backup = Join-Path $backups ($Name + '-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N'))
            $previousWasDirectory = [bool]$item.PSIsContainer
            # Same-volume rename, not a recursive copy/delete or destructive reset.
            if ($previousWasDirectory) { [IO.Directory]::Move($directory, $backup) }
            else { [IO.File]::Move($directory, $backup) }
            Write-Host "Preserved previous copy: $backup"
        }
        try { [IO.Directory]::Move($stage, $directory) }
        catch {
            $installError = $_.Exception.Message
            if ($backup -and -not (Test-Path -LiteralPath $directory)) {
                try {
                    if ($previousWasDirectory) { [IO.Directory]::Move($backup, $directory) }
                    else { [IO.File]::Move($backup, $directory) }
                } catch { throw "Could not install $Name or restore its original path. Original copy remains at $backup. $($_.Exception.Message)" }
                throw "Could not install $Name; the previous copy was restored. $installError"
            }
            throw "Could not install $Name. Preserved copy, if any: $backup. $installError"
        }
        Write-Host "${Name}: installed $after (origin/$BranchName)."
        return @{ repository = $Name; path = $directory; branch = $BranchName; before = $null; after = $after; action = 'clone'; backupPath = $backup; reason = $Reason }
    } finally {
        # Only remove this invocation's private staging clone, never the backup.
        if (Test-Path -LiteralPath $stage) {
            try { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop }
            catch { Write-Warning "Temporary clone could not be removed: $stage" }
        }
        Pop-Location
    }
}
function Read-GitMetadata([string]$Directory, [string[]]$Arguments) {
    # Read-only probes may fail for a corrupt/partial old checkout. Such a copy
    # will be backed up, not treated as a reason to stop installing current code.
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
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "$directory is a link/junction. Choose an installation Root with ordinary directories."
    }
    $gitPath = Join-Path $directory '.git'
    if (Test-Path -LiteralPath $gitPath -PathType Leaf) {
        throw "$directory uses external Git metadata (worktree/submodule). Choose a separate installation Root; that working tree was not changed."
    }
    if (-not (Test-Path -LiteralPath $gitPath -PathType Container)) {
        return (Install-FreshRepo $Name $BranchName 'Existing files have no Git metadata')
    }
    if ((Get-Item -LiteralPath $gitPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "$gitPath is a link/junction. External Git metadata will not be modified."
    }
    $origin = Read-GitMetadata $directory @('remote', 'get-url', 'origin')
    $head = Read-GitMetadata $directory @('rev-parse', '--verify', 'HEAD')
    $currentBranch = Read-GitMetadata $directory @('branch', '--show-current')
    if (-not $origin.ok -or -not $head.ok -or -not $currentBranch.ok) {
        return (Install-FreshRepo $Name $BranchName 'Existing Git metadata is incomplete or invalid')
    }
    if ($origin.text -notin @($url, $url.Substring(0, $url.Length - 4), "git@github.com:bogdanparvu18/$Name.git")) {
        return (Install-FreshRepo $Name $BranchName 'Existing copy has a different origin')
    }
    # A failed network/authentication request is still a real failure, never READY
    # with stale code. No local source is changed by this explicit fetch.
    Run { git.exe -C $directory fetch --prune origin "+refs/heads/${BranchName}:${remoteRef}" } | Out-Host
    $before = $head.text
    $branch = $currentBranch.text
    if ($branch -and $branch -ne $BranchName -and $branch -ne 'main') {
        return (Install-FreshRepo $Name $BranchName "Existing copy is on branch '$branch'")
    }
    if ([int](Run { git.exe -C $directory rev-list --count "${remoteRef}..HEAD" }) -ne 0) {
        return (Install-FreshRepo $Name $BranchName 'Existing copy has local or divergent commits')
    }
    $localMain = @(Run { git.exe -C $directory branch --list $BranchName })
    if ($localMain.Count -gt 0 -and [int](Run { git.exe -C $directory rev-list --count "${remoteRef}..${BranchName}" }) -ne 0) {
        return (Install-FreshRepo $Name $BranchName "Local $BranchName differs from the remote history")
    }
    $changed = @(Run { git.exe -c core.quotepath=false -C $directory diff --name-only -- })
    $changed += @(Run { git.exe -c core.quotepath=false -C $directory diff --cached --name-only -- })
    $untracked = @(Run { git.exe -c core.quotepath=false -C $directory ls-files --others --exclude-standard })
    # Preserve ignored personal files too, without enumerating entire node_modules.
    $ignored = @(Run { git.exe -c core.quotepath=false -C $directory ls-files --others --ignored --exclude-standard --directory })
    $paths = @(@($changed) + @($untracked) + @($ignored) | Sort-Object -Unique)
    foreach ($path in $paths) {
        if (-not $path) { continue }
        $isGenerated = $false
        foreach ($pattern in $GeneratedPatterns) {
            if ($path -like $pattern) { $isGenerated = $true; break }
        }
        if (-not $isGenerated) {
            return (Install-FreshRepo $Name $BranchName 'Existing copy contains local source or personal files')
        }
    }
    $generated = @(@($changed) + @($untracked) | Where-Object { $_ } | Sort-Object -Unique)
    if ($generated.Count -gt 0) {
        # Legacy repos track build products. Keep their existing stash behavior
        # so unchanged reruns do not clone/archive node_modules and target again.
        $pathspec = [IO.Path]::GetTempFileName()
        try {
            $literalPaths = @($generated | ForEach-Object { ':(literal)' + $_ })
            [IO.File]::WriteAllText($pathspec, (($literalPaths -join "`0") + "`0"), $Utf8)
            $label = 'bootstrap-generated-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Run { git.exe -c 'user.name=Medication Lab Bootstrap' -c 'user.email=bootstrap@localhost' -C $directory stash push --include-untracked -m $label "--pathspec-from-file=$pathspec" --pathspec-file-nul } | Out-Host
            $backup = (Run { git.exe -C $directory rev-parse refs/stash }).Trim()
            Write-Host "Preserved generated-output changes in ${Name}: stash $backup (not reapplied)."
        } finally { Remove-Item -LiteralPath $pathspec -Force }
    }
    try {
        # Migrate the old detached checkout, then pull the moving remote branch.
        if ($branch -ne $BranchName) {
            if ($localMain.Count -gt 0) { Run { git.exe -C $directory checkout $BranchName } | Out-Host }
            else { Run { git.exe -C $directory checkout --track -b $BranchName $remoteRef } | Out-Host }
        }
        Run { git.exe -C $directory pull --ff-only --no-rebase --no-autostash origin "+refs/heads/${BranchName}:${remoteRef}" } | Out-Host
        $remote = (Run { git.exe -C $directory rev-parse $remoteRef }).Trim()
        $after = (Run { git.exe -C $directory rev-parse HEAD }).Trim()
        if ($after -ne $remote) { throw "$Name did not reach the fetched origin/$BranchName." }
    } catch {
        # A rewrite upstream or a leftover checkout conflict must not require
        # manual cleanup. A replacement download must succeed before swapping.
        Write-Warning "In-place update failed for ${Name}: $($_.Exception.Message)"
        return (Install-FreshRepo $Name $BranchName 'In-place update could not reach the remote branch')
    }
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
        $desktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
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
function Resolve-PsqlPath([string]$RequestedPath) {
    if ($RequestedPath) {
        if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) { throw "psql.exe was not found at $RequestedPath" }
        return (Get-Item -LiteralPath $RequestedPath).FullName
    }
    $command = Get-Command psql.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $installRoot = Join-Path $env:ProgramFiles 'PostgreSQL'
    if (Test-Path -LiteralPath $installRoot) {
        $versions = @(Get-ChildItem -LiteralPath $installRoot -Directory | Sort-Object -Property {
            try { [version]$_.Name } catch { [version]'0.0' }
        } -Descending)
        foreach ($version in $versions) {
            $candidate = Join-Path $version.FullName 'bin\psql.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    throw 'Local PostgreSQL mode needs psql.exe. Install PostgreSQL command-line tools or pass -PsqlPath "C:\Program Files\PostgreSQL\18\bin\psql.exe".'
}
function Test-PostgresReady {
    $ErrorActionPreference = 'Continue'
    if ($UseDocker) {
        & docker.exe exec $ContainerName pg_isready -h 127.0.0.1 -p 5432 -U $DbUser -d $Database -t 3 *> $null
    } else {
        & $PgIsReady -h $PgHost -p $Port -U $DbUser -d $Database -t 3 *> $null
    }
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
    if ($UseDocker) {
        Run { docker.exe exec -e PGPASSWORD $ContainerName psql -X -w -h 127.0.0.1 -p 5432 -U $DbUser -d $Database -v ON_ERROR_STOP=1 -Atc $Sql }
    } else {
        Run { & $PsqlPath -X -w -h $PgHost -p $Port -U $DbUser -d $Database -v ON_ERROR_STOP=1 -Atc $Sql }
    }
}
function Assert-Postgres {
    if ($UseDocker) {
        $running = Run { docker.exe inspect --format '{{.State.Running}}' $ContainerName }
        if ($running -ne 'true') { throw 'PostgreSQL container is not running.' }
    }
    if (-not (Test-PostgresReady)) { throw "PostgreSQL is not accepting connections at ${PgHost}:$Port." }
    try { $answer = Invoke-DatabaseSql 'SELECT 1;' }
    catch { throw "PostgreSQL login failed at ${PgHost}:$Port for database '$Database', user '$DbUser'. Check the existing database, role and password. $($_.Exception.Message)" }
    if ($answer -ne '1') { throw 'Authenticated PostgreSQL query failed.' }
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
    Write-Host 'Usage: .\bootstrap-windows.ps1 [-Root directory] [-ScalaRepoPath path] [-LangiumRepoPath path] [-SetupPath path] [-Port port] [-PgHost host] [-Database name] [-DbUser user] [-PsqlPath path] [-PgServiceName name] [-UseDocker] [-ContainerName name] [-VolumeName name] [-NoEditor] [-StartupTimeoutSeconds 180] [-ScalaBranch main] [-LangiumBranch main]'
    Write-Host 'Root is a search boundary. Discover both repositories recursively (including Root\repos), then update/build them in place; names or their Git origin identify existing clones. No duplicate copies are created when unique matches exist.'
    Write-Host 'Multiple matches require -ScalaRepoPath / -LangiumRepoPath, absolute or relative to Root. Missing partners are cloned beside the existing repo; with neither present, use Root\repos if it exists, otherwise Root.'
    Write-Host 'Discovery excludes setup/backups, tools, dependencies, build outputs, linked directories and the inside of Git checkouts. Old ordinary ZIP/source copies are backed up and replaced only after a successful fresh download.'
    Write-Host 'Reuse the unique existing medication-lab-setup\automatic directory below Root; otherwise create it directly below Root. Multiple setup directories require -SetupPath. Backups remain inside that automatic directory; local changes are not reapplied. Run one bootstrap at a time.'
    Write-Host 'Default: existing local PostgreSQL, no Docker checks or commands. Connection defaults: PGHOST/PGPORT/PGDATABASE/PGUSER, then 127.0.0.1:5432 / scala_testing_lab / scala_lab. Explicit arguments override those defaults.'
    Write-Host 'Local mode uses PGPASSWORD or asks securely for the existing password. The database and login must already exist; no local role/password/database is created or replaced.'
    Write-Host 'A ready local RxNorm import with compatible manifests is reused. Empty databases receive the verified prescribable archive; incomplete/incompatible existing releases are not replaced.'
    Write-Host 'psql.exe is found on PATH or under Program Files\PostgreSQL; -PsqlPath supports custom installations. A single stopped PostgreSQL Windows service can be started; use -PgServiceName when several exist.'
    Write-Host 'Install Git, Java 21 (JAVA_HOME), Node 22.12+, PostgreSQL client tools, and VS Code first. Docker Desktop is needed ONLY with -UseDocker (port 55433 by default, rxnorm_public / rxnorm_lab).'
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
foreach ($tool in @('git.exe', 'node.exe', 'npm.cmd')) { Get-Command $tool | Out-Null }
if (-not $NoEditor) { Get-Command code.cmd | Out-Null }
if (-not $env:JAVA_HOME) { throw 'Set JAVA_HOME to your Java 21 installation.' }
$JavaHome = $env:JAVA_HOME
$Java = Join-Path $JavaHome 'bin\java.exe'
if (-not (Test-Path $Java) -or (Get-Content "$JavaHome\release" -Raw) -notmatch 'JAVA_VERSION="21\.') { throw 'JAVA_HOME must point to Java 21.' }
$NodeHome = Split-Path (Get-Command node.exe).Source -Parent
$env:PATH = "$JavaHome\bin;$NodeHome;$env:PATH"
$nodeVersion = Run { node.exe --version }
if ([version]$nodeVersion.TrimStart('v') -lt [version]'22.12.0') { throw 'Install Node 22.12 or newer.' }
$npmVersion = Run { npm.cmd --version }
if ([version]$npmVersion.Trim() -lt [version]'10.2.3') { throw 'Install npm 10.2.3 or newer.' }
Run { & $Java -version } | Out-Host
if ($UseDocker) {
    Ensure-Docker
} else {
    $PsqlPath = Resolve-PsqlPath $PsqlPath
    $PgIsReady = Join-Path (Split-Path -Parent $PsqlPath) 'pg_isready.exe'
    if (-not (Test-Path -LiteralPath $PgIsReady -PathType Leaf)) { throw "pg_isready.exe is missing beside $PsqlPath. Install the PostgreSQL command-line tools." }
    Run { & $PsqlPath --version } | Out-Host
}

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
# protect setup state and (Docker mode only) its generated password
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
Run { icacls.exe $State '/inheritance:r' '/grant:r' "${identity}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' } | Out-Null
if ($UseDocker) {
    # Local mode never reads, creates or overwrites this Docker secrets file.
    $secretsFile = Join-Path $State 'secrets.json'
    if (-not (Test-Path $secretsFile)) { Save-Json $secretsFile @{ password = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'); port = $Port } }
    $secrets = Get-Content $secretsFile -Raw | ConvertFrom-Json
    if (($secrets.port -and $secrets.port -ne $Port) -or -not $secrets.password) { throw 'Use this Docker setup with its original Root and Port.' }
    $env:PGPASSWORD = $secrets.password
    $env:POSTGRES_PASSWORD = $secrets.password
} elseif (-not $env:PGPASSWORD) {
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
# Always pull both moving branches; back up and replace incompatible old copies.
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
# Reinstall locked dependencies and rebuild EVERYTHING on EVERY run.
Push-Location $Langium
try {
    Run { npm.cmd ci --include=dev } | Out-Host
    Run { npm.cmd run clean } | Out-Host
    Run { npm.cmd run langium:generate } | Out-Host
    Run { npm.cmd run build } | Out-Host
} finally { Pop-Location }
foreach ($artifact in @('packages\language\out\index.js', 'packages\extension\out\extension\main.cjs', 'packages\extension\out\language\main.cjs', 'packages\extension\syntaxes\clinical-dsl.tmLanguage.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Langium $artifact))) { throw "Missing build artifact: $artifact" }
}

if ($UseDocker) {
    # Only the explicitly selected Docker backend manages containers/volumes.
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
        Run { docker.exe run -d --restart unless-stopped --name $ContainerName -e POSTGRES_USER=rxnorm_lab -e POSTGRES_DB=rxnorm_public -e POSTGRES_PASSWORD -p "127.0.0.1:${Port}:5432" -v "${VolumeName}:/var/lib/postgresql/data" postgres:16 }
    }
    Run { docker.exe update --restart unless-stopped $ContainerName } | Out-Host
    Wait-Postgres
} else {
    Ensure-LocalPostgres
}
Assert-Postgres
Invoke-Sbt @('clean', 'compile')
# skip the import if this data is ready
$query = @"
SELECT 1 FROM rxnorm_lab.release r JOIN rxnorm_lab.product_release p USING (release)
WHERE r.release='2026-10-05' AND r.state='ready' AND p.state='ready' AND p.base_identity=r.identity
AND r.scope='all-active-rxnorm-pg-v4' AND p.policy='single-component-mass-v1'
AND r.sha256_json::jsonb->>'RXNCONSO.RRF'='555730c3ff2a981796dc5d649acc482e4685f7a31f7b0442941393ae50dd5209'
AND r.sha256_json::jsonb->>'RXNREL.RRF'='cca47f32a2c32ef60d65c6789851385ff5dcf287750ca01a53f800a5cf5ef694'
AND p.sha256_json::jsonb->>'RXNSAT.RRF'='b5a476f2bfbef9082144fd2bf00eb0de46f7b0b63da822d856067b9935914dda';
"@
# A native installation may already contain the Full archive documented in the
# README, rather than the bootstrap's prescribable subset. Reuse a ready local
# import only when its release, policies and base/product provenance agree.
if (-not $UseDocker) {
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
}
# Missing schema is a normal first-install state. Authentication/SQL failures
# must not be swallowed and mistaken for an absent import.
$hasManifest = Invoke-DatabaseSql "SELECT CASE WHEN to_regclass('rxnorm_lab.release') IS NOT NULL AND to_regclass('rxnorm_lab.product_release') IS NOT NULL THEN 1 ELSE 0 END;"
$ready = ''
if ($hasManifest -eq '1') { $ready = Invoke-DatabaseSql $query }
if (-not $UseDocker -and $ready -ne '1') {
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
    Invoke-Sbt @("run import-rxnorm $rrf 2026-10-05")
    Invoke-Sbt @("run import-product-attributes $rrf 2026-10-05")
    Invoke-DatabaseSql 'ANALYZE;' | Out-Host
} else { Write-Host 'RxNorm is already imported.' }
$verified = Invoke-DatabaseSql $query
if ($verified -ne '1') { throw 'RxNorm release/product index verification failed after import.' }
Invoke-Sbt @('test')

# leave an existing demo file alone
$Demo = Join-Path $Automatic 'aspirin-demo.clinical'
if (-not (Test-Path $Demo)) { [IO.File]::WriteAllText($Demo, "Patient P9999: age 30, condition Fever`nMedication aspirin: 100 mg, strength 325 mg, doseForm Oral Tablet, route PO, frequency PRN`nPlan DemoPlan: for P9999, prescribe aspirin`nshow DemoPlan`n", $Utf8) }
# Fresh fixtures/results live outside both repositories. Never overwrite the user's demo.
$SmokeName = 'smoke-' + [guid]::NewGuid().ToString('N')
$Smoke = Join-Path $State $SmokeName
New-Item -ItemType Directory -Path $Smoke | Out-Null
$fixture = "Patient P9999: age 30, condition Fever`nMedication aspirin: 100 mg, strength 325 mg, doseForm Oral Tablet, route PO, frequency PRN`nPlan DemoPlan: for P9999, prescribe aspirin`nshow DemoPlan`n"
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
    Invoke-Sbt @("run resolve $astArg $resultArg")
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
    scala = 'clean-compile-test-pass'; langium = 'clean-generate-build-pass'
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
