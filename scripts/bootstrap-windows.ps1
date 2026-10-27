# setup options
param(
    [string]$Root = (Get-Location).Path,
    [ValidateRange(1, 65535)][int]$Port = 55433,
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

# Never reset a user's source files or unpublished commits. Only disposable build
# outputs are stashed (and retained) so the binaries tracked by legacy clones do
# not make every subsequent run fail its clean-worktree check.
function Sync-Repo([string]$Name, [string]$BranchName, [string[]]$GeneratedPatterns) {
    $directory = Join-Path $Root $Name
    $url = "https://github.com/bogdanparvu18/$Name.git"
    Run { git.exe check-ref-format --branch $BranchName } | Out-Null
    $remoteRef = "refs/remotes/origin/$BranchName"
    if (-not (Test-Path -LiteralPath $directory)) {
        Run { git.exe clone --branch $BranchName $url $directory } | Out-Host
    }
    if (-not (Test-Path -LiteralPath (Join-Path $directory '.git'))) {
        throw "$directory is not a Git checkout. Move it aside or choose another Root."
    }
    $origin = (Run { git.exe -C $directory remote get-url origin }).Trim()
    if ($origin -notin @($url, $url.Substring(0, $url.Length - 4), "git@github.com:bogdanparvu18/$Name.git")) {
        throw "Unexpected origin in $directory. Refusing to update another repository."
    }
    # An explicit refspec also works for older/single-branch installations.
    Run { git.exe -C $directory fetch --prune origin "+refs/heads/${BranchName}:${remoteRef}" } | Out-Host
    $before = (Run { git.exe -C $directory rev-parse HEAD }).Trim()
    $remote = (Run { git.exe -C $directory rev-parse $remoteRef }).Trim()
    $branch = [string](Run { git.exe -C $directory branch --show-current })
    if ($branch -and $branch -ne $BranchName -and $branch -ne 'main') {
        throw "$directory is on branch '$branch'. Switch to $BranchName before running the bootstrap."
    }
    if ([int](Run { git.exe -C $directory rev-list --count "${remoteRef}..HEAD" }) -ne 0) {
        throw "$directory has unpublished or divergent commits. Reconcile them with origin/$BranchName first."
    }
    $localMain = @(Run { git.exe -C $directory branch --list $BranchName })
    if ($localMain.Count -gt 0 -and [int](Run { git.exe -C $directory rev-list --count "${remoteRef}..${BranchName}" }) -ne 0) {
        throw "$directory has a local $BranchName that is ahead of or diverges from origin/$BranchName. No commits were discarded."
    }
    $changed = @(Run { git.exe -c core.quotepath=false -C $directory diff --name-only -- })
    $changed += @(Run { git.exe -c core.quotepath=false -C $directory diff --cached --name-only -- })
    $untracked = @(Run { git.exe -c core.quotepath=false -C $directory ls-files --others --exclude-standard })
    $paths = @(@($changed) + @($untracked) | Sort-Object -Unique)
    $generated = @()
    foreach ($path in $paths) {
        if (-not $path) { continue }
        $isGenerated = $false
        foreach ($pattern in $GeneratedPatterns) {
            if ($path -like $pattern) { $isGenerated = $true; break }
        }
        if (-not $isGenerated) {
            throw "Local source/untracked file in ${directory}: $path. Commit, stash, or move your changes first; nothing was overwritten."
        }
        $generated += $path
    }
    if ($generated.Count -gt 0) {
        # NUL-separated literal pathspecs handle spaces and avoid Windows' argv limit.
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
    # Migrate the old detached, pinned checkout onto the moving main branch.
    if ($branch -ne $BranchName) {
        if ($localMain.Count -gt 0) { Run { git.exe -C $directory checkout $BranchName } | Out-Host }
        else { Run { git.exe -C $directory checkout --track -b $BranchName $remoteRef } | Out-Host }
    }
    Run { git.exe -C $directory merge --ff-only $remoteRef } | Out-Host
    $after = (Run { git.exe -C $directory rev-parse HEAD }).Trim()
    if ($after -ne $remote) { throw "$Name did not reach the fetched origin/$BranchName. Setup stopped." }
    Write-Host "${Name}: $before -> $after (origin/$BranchName)"
    return @{ repository = $Name; branch = $BranchName; before = $before; after = $after }
}
function Get-DockerType {
    # Expected startup failures must not terminate Windows PowerShell 5.1 here.
    $ErrorActionPreference = 'Continue'
    $value = & docker.exe info --format '{{.OSType}}' 2>$null
    if ($LASTEXITCODE -eq 0) { return ([string]$value).Trim() }
    return ''
}
function Ensure-Docker {
    $type = Get-DockerType
    if (-not $type) {
        $desktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
        if (-not (Test-Path -LiteralPath $desktop)) { throw 'Start Docker Desktop, then rerun this script.' }
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
function Assert-Postgres {
    $running = Run { docker.exe inspect --format '{{.State.Running}}' $ContainerName }
    if ($running -ne 'true') { throw 'PostgreSQL container is not running.' }
    Run { docker.exe exec $ContainerName pg_isready -h 127.0.0.1 -U rxnorm_lab -d rxnorm_public } | Out-Host
    $answer = Run { docker.exe exec -e PGPASSWORD $ContainerName psql -h 127.0.0.1 -U rxnorm_lab -d rxnorm_public -v ON_ERROR_STOP=1 -Atc 'SELECT 1;' }
    if ($answer -ne '1') { throw 'Authenticated PostgreSQL query failed.' }
}
function Invoke-Sbt([string[]]$Commands) {
    Push-Location $Scala
    try {
        Run { & $Java -Xmx2G '-Dsbt.supershell=false' '-Dsbt.log.noformat=true' '-Dsbt.server.autostart=false' -jar $Launcher @Commands } | Out-Host
    } finally { Pop-Location }
}

if ($Help) {
    Write-Host 'Usage: .\bootstrap-windows.ps1 [-Root directory] [-Port 55433] [-ContainerName name] [-VolumeName name] [-NoEditor] [-StartupTimeoutSeconds 180] [-ScalaBranch main] [-LangiumBranch main]'
    Write-Host 'The current folder is the default destination. Install Git, Java 21 (JAVA_HOME), Node 22.12+, Docker Desktop with Linux containers, and VS Code first.'
    return
}
try {
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
$npmVersion = Run { npm.cmd --version }
if ([version]$npmVersion.Trim() -lt [version]'10.2.3') { throw 'Install npm 10.2.3 or newer.' }
Run { & $Java -version } | Out-Host
Ensure-Docker

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
$HealthFile = Join-Path $State 'health.json'
Save-Json $HealthFile @{ status = 'running'; startedAt = (Get-Date).ToUniversalTime().ToString('o') }
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

# Always fetch and fast-forward both repositories; there are no pinned code SHAs.
$RepoHeads = @(
    Sync-Repo 'scala-testing-lab' $ScalaBranch @('target/*', 'project/target/*', 'project/project/target/*', '.metals/*', '.bsp/*', '.bloop/*')
    Sync-Repo 'langium_dsl_lab' $LangiumBranch @('clinical-dsl-demo/node_modules/*', 'clinical-dsl-demo/packages/*/node_modules/*', 'clinical-dsl-demo/packages/*/out/*', 'clinical-dsl-demo/*.tsbuildinfo', 'clinical-dsl-demo/packages/language/src/generated/*', 'clinical-dsl-demo/packages/language/syntaxes/*', 'clinical-dsl-demo/packages/extension/syntaxes/*')
)
$Scala = Join-Path $Root 'scala-testing-lab'
$Langium = Join-Path $Root 'langium_dsl_lab\clinical-dsl-demo'
# A downloaded/old bootstrap must use the newly fetched setup logic this run.
$UpdatedScript = Join-Path $Scala 'scripts\bootstrap-windows.ps1'
if ((Get-FileHash -LiteralPath $UpdatedScript -Algorithm SHA256).Hash -ne $EntryHash) {
    if ($RelaunchCount -ge 2) { throw 'Bootstrap changed repeatedly while updating. Rerun once upstream is stable.' }
    Write-Host 'Bootstrap changed upstream; restarting with the updated script.'
    $next = @{ Root = $Root; Port = $Port; ContainerName = $ContainerName; VolumeName = $VolumeName; ScalaBranch = $ScalaBranch; LangiumBranch = $LangiumBranch; NoEditor = [bool]$NoEditor; StartupTimeoutSeconds = $StartupTimeoutSeconds; RelaunchCount = ($RelaunchCount + 1) }
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
    Run { docker.exe run -d --restart unless-stopped --name $ContainerName -e POSTGRES_USER=rxnorm_lab -e POSTGRES_DB=rxnorm_public -e POSTGRES_PASSWORD -p "127.0.0.1:${Port}:5432" -v "${VolumeName}:/var/lib/postgresql/data" postgres:16 }
}
Run { docker.exe update --restart unless-stopped $ContainerName } | Out-Host
# wait for postgres
for ($attempt = 0; $attempt -lt $StartupTimeoutSeconds; $attempt++) {
    docker.exe exec $ContainerName pg_isready -U rxnorm_lab -d rxnorm_public | Out-Null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 1
}
if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL did not become ready. Check docker logs.' }
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
try { $ready = docker.exe exec $ContainerName psql -U rxnorm_lab -d rxnorm_public -Atc $query 2>$null; if ($LASTEXITCODE -ne 0) { $ready = '' } } catch { $ready = '' }
if ($ready -ne '1') {
    # download and import the rxnorm files
    $Zip = Join-Path $Downloads 'RxNorm_full_prescribe_10052026.zip'
    if (-not (Test-Path $Zip)) { Invoke-WebRequest -UseBasicParsing 'https://download.nlm.nih.gov/rxnorm/RxNorm_full_prescribe_10052026.zip' -OutFile $Zip }
    if ((Get-FileHash $Zip).Hash -ne '8ed351c29f3cb56bedeb8e2bcb8fa56931f8d7eb88e2280dc9772d7d3eb16977') { throw 'RxNorm download checksum failed.' }
    Expand-Archive -LiteralPath $Zip -DestinationPath $Data -Force
    $rrf = '../medication-lab-setup/automatic/data/2026-10-05/rrf'
    Invoke-Sbt @("run import-rxnorm $rrf 2026-10-05")
    Invoke-Sbt @("run import-product-attributes $rrf 2026-10-05")
    Run { docker.exe exec $ContainerName psql -U rxnorm_lab -d rxnorm_public -v ON_ERROR_STOP=1 -c 'ANALYZE;' }
} else { Write-Host 'RxNorm is already imported.' }
$verified = Run { docker.exe exec $ContainerName psql -U rxnorm_lab -d rxnorm_public -v ON_ERROR_STOP=1 -Atc $query }
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
    # Invoke-Sbt runs from the sibling Scala checkout. Relative, space-free
    # arguments avoid Windows PowerShell 5.1's nested native-argument quoting.
    # Root itself may contain spaces; only these generated relative names are used.
    $astArg = "../medication-lab-setup/automatic/state/$SmokeName/$case.ast.json"
    $resultArg = "../medication-lab-setup/automatic/state/$SmokeName/$case.result.json"
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
    'clinicalDsl.rxnorm.pgHost' = '127.0.0.1'; 'clinicalDsl.rxnorm.pgPort' = $Port
    'clinicalDsl.rxnorm.pgDatabase' = 'rxnorm_public'; 'clinicalDsl.rxnorm.pgUser' = 'rxnorm_lab'
    'clinicalDsl.rxnorm.timeoutSeconds' = 300
}
foreach ($key in $requiredSettings.Keys) { $settings[$key] = $requiredSettings[$key] }
Save-Json $settingsFile $settings
# open the demo in the editor
if (-not $NoEditor) { Run { code.cmd --new-window --user-data-dir $Profile "--extensionDevelopmentPath=$Langium\packages\extension" $Langium $Demo } }
Save-Json $HealthFile @{
    status = 'ready'; checkedAt = (Get-Date).ToUniversalTime().ToString('o')
    repositories = $RepoHeads; postgres = 'authenticated-query-pass'; rxnorm = 'ready'
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
} finally { Set-Location $OriginalLocation }
