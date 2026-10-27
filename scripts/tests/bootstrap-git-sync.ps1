# No Pester, network, Java, Docker or PostgreSQL needed. Run with Windows
# PowerShell 5.1 AND PowerShell 7. Only temporary repositories are modified.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$RealGit = (Get-Command git -CommandType Application).Source
$ScriptPath = Join-Path $PSScriptRoot '..\bootstrap-windows.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw ($errors | Out-String) }
# Load only the two pure Git helpers, never the bootstrap's top-level actions.
$definitions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Run', 'Sync-Repo') }, $true)
foreach ($definition in $definitions) { Invoke-Expression $definition.Extent.Text }
$Utf8 = New-Object Text.UTF8Encoding($false)
$Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('bootstrap git tests ' + [guid]::NewGuid().ToString('N'))
$Root = Join-Path $Sandbox 'install root'
$Remote = Join-Path $Sandbox 'remote.git'
$Seed = Join-Path $Sandbox 'seed'
$ExpectedUrl = 'https://github.com/bogdanparvu18/scala-testing-lab.git'
$FailFetch = $false
function Git([string[]]$Arguments) {
    & $RealGit @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Fixture git command failed: $Arguments" }
}
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    $message = $null
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    if (-not $message -or $message -notmatch $Pattern) { throw "Expected '$Pattern', received '$message'." }
}
# Redirect ONLY clone/fetch transport to the fixture. All Git operations remain
# real native commands; the origin URL stored in the clone stays production-like.
function git.exe {
    $arguments = @($args)
    if ($arguments -contains 'clone') {
        $i = [array]::IndexOf($arguments, $ExpectedUrl)
        if ($i -lt 0) { throw 'Test attempted an unexpected network clone.' }
        $arguments[$i] = $Remote
        & $RealGit @arguments
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            & $RealGit -C $arguments[-1] remote set-url origin $ExpectedUrl
            $code = $LASTEXITCODE
        }
    } elseif ($arguments -contains 'fetch') {
        if ($FailFetch) { $global:LASTEXITCODE = 1; return }
        $i = [array]::IndexOf($arguments, 'origin')
        if ($i -lt 0) { throw 'Test attempted an unexpected network fetch.' }
        $arguments[$i] = $Remote
        & $RealGit @arguments
        $code = $LASTEXITCODE
    } else {
        & $RealGit @arguments
        $code = $LASTEXITCODE
    }
    $global:LASTEXITCODE = $code
}
try {
    New-Item -ItemType Directory -Path $Root, $Seed -Force | Out-Null
    Git @('init', '--bare', $Remote)
    Git @('-C', $Seed, 'init', '-b', 'main')
    Git @('-C', $Seed, 'config', 'user.name', 'Bootstrap Test')
    Git @('-C', $Seed, 'config', 'user.email', 'bootstrap@example.invalid')
    New-Item -ItemType Directory -Path (Join-Path $Seed 'target') | Out-Null
    [IO.File]::WriteAllText((Join-Path $Seed 'source.txt'), 'first', $Utf8)
    [IO.File]::WriteAllText((Join-Path $Seed 'target\cache.bin'), 'tracked output', $Utf8)
    Git @('-C', $Seed, 'add', '.')
    Git @('-C', $Seed, 'commit', '-m', 'first')
    Git @('-C', $Seed, 'remote', 'add', 'origin', $Remote)
    Git @('-C', $Seed, 'push', '-u', 'origin', 'main')
    $first = Sync-Repo 'scala-testing-lab' 'main' @('target/*')
    $Local = Join-Path $Root 'scala-testing-lab'
    Git @('-C', $Local, 'config', 'user.name', 'Bootstrap Test')
    Git @('-C', $Local, 'config', 'user.email', 'bootstrap@example.invalid')
    [IO.File]::WriteAllText((Join-Path $Seed 'source.txt'), 'second', $Utf8)
    Git @('-C', $Seed, 'commit', '-am', 'second')
    Git @('-C', $Seed, 'push')
    $updated = Sync-Repo 'scala-testing-lab' 'main' @('target/*')
    Assert ($updated.after -ne $first.after) 'New remote commit was not installed.'
    $repeat = Sync-Repo 'scala-testing-lab' 'main' @('target/*')
    Assert ($repeat.after -eq $updated.after) 'Unchanged rerun moved HEAD unexpectedly.'
    Git @('-C', $Local, 'checkout', '--detach', $first.after)
    $migrated = Sync-Repo 'scala-testing-lab' 'main' @('target/*')
    Assert ($migrated.after -eq $updated.after) 'Legacy detached checkout was not migrated.'
    [IO.File]::WriteAllText((Join-Path $Local 'source.txt'), 'user edits', $Utf8)
    Expect-Failure { Sync-Repo 'scala-testing-lab' 'main' @('target/*') } 'Local source'
    Assert ((Get-Content (Join-Path $Local 'source.txt') -Raw) -eq 'user edits') 'Source edits were lost.'
    Git @('-C', $Local, 'restore', 'source.txt')
    [IO.File]::WriteAllText((Join-Path $Local 'notes.txt'), 'user notes', $Utf8)
    Expect-Failure { Sync-Repo 'scala-testing-lab' 'main' @('target/*') } 'Local source'
    Remove-Item -LiteralPath (Join-Path $Local 'notes.txt')
    [IO.File]::WriteAllText((Join-Path $Local 'target\cache.bin'), 'new build', $Utf8)
    [IO.File]::WriteAllText((Join-Path $Local 'target\new.bin'), 'new output', $Utf8)
    $rebuilt = Sync-Repo 'scala-testing-lab' 'main' @('target/*')
    Assert ($rebuilt.after -eq $updated.after) 'Generated outputs prevented rerun.'
    $stash = & $RealGit -C $Local stash list
    Assert ([bool]($stash -match 'bootstrap-generated')) 'Generated output backup missing.'
    $FailFetch = $true
    Expect-Failure { Sync-Repo 'scala-testing-lab' 'main' @('target/*') } 'Command failed'
    $FailFetch = $false
    Git @('-C', $Local, 'checkout', '-b', 'my-work')
    Expect-Failure { Sync-Repo 'scala-testing-lab' 'main' @('target/*') } 'is on branch'
    Git @('-C', $Local, 'checkout', 'main')
    [IO.File]::WriteAllText((Join-Path $Local 'source.txt'), 'unpublished', $Utf8)
    Git @('-C', $Local, 'commit', '-am', 'local work')
    Expect-Failure { Sync-Repo 'scala-testing-lab' 'main' @('target/*') } 'unpublished or divergent'
    Write-Host 'PASS: parser, clone, update, unchanged rerun, detached migration, source/untracked protection, generated backup, fetch failure, feature branch and unpublished-commit protection.'
} finally {
    Remove-Item Function:\git.exe -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Sandbox) { Remove-Item -LiteralPath $Sandbox -Recurse -Force }
}
