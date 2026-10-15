#Requires -Version 5.1
# Run once from the root of the delivered ZIP, after gh authentication.
# This creates a PRIVATE personal repository and a DRAFT PR; it never merges.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = 'bogdanparvu18/scala-testing-lab'
$featureBranch = 'feat/rxnorm-zio-postgresql'
$expectedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\', '/')
$currentRoot = (Get-Location).ProviderPath.TrimEnd('\', '/')
if (-not [string]::Equals($expectedRoot, $currentRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Run this script from the project root: $expectedRoot"
}
foreach ($program in @('git', 'gh')) {
    if (-not (Get-Command $program -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $program. See docs/PUBLISH.md."
    }
}
foreach ($variable in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE')) {
    if ([Environment]::GetEnvironmentVariable($variable, 'Process')) {
        throw "Unset the process variable $variable before publishing; it can redirect Git operations."
    }
}
if ($env:GH_HOST -and $env:GH_HOST -ne 'github.com') {
    throw 'GH_HOST selects a different GitHub host. This script publishes only to github.com.'
}
if (Test-Path -LiteralPath (Join-Path $expectedRoot '.git')) {
    throw 'This directory already contains .git. Nothing was changed. Inspect its state and use docs/PUBLISH.md recovery steps.'
}
$parentDirectory = [IO.Directory]::GetParent($expectedRoot)
while ($null -ne $parentDirectory) {
    if (Test-Path -LiteralPath (Join-Path $parentDirectory.FullName '.git')) {
        throw 'The extracted project is inside another Git checkout. Move this ZIP extraction to a separate directory first.'
    }
    $parentDirectory = $parentDirectory.Parent
}

$allowlist = @(
    '.gitignore', '.env.example', 'build.sbt', 'project/build.properties',
    'README.md', 'compose.yaml', 'bridge', 'docs', 'examples', 'scripts', 'src'
)
foreach ($path in ($allowlist + @('docs/PR.md'))) {
    if (-not (Test-Path -LiteralPath (Join-Path $expectedRoot $path))) {
        throw "Expected package file/directory missing: $path. Nothing was initialized."
    }
}

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE. Stop here; inspect state using docs/PUBLISH.md before resuming."
    }
}

$activeLogin = & gh api --hostname github.com user --jq .login
if ($LASTEXITCODE -ne 0) { throw 'GitHub authentication check failed. See docs/PUBLISH.md.' }
if (($activeLogin -join '').Trim() -ne 'bogdanparvu18') {
    throw 'The active GitHub identity is not bogdanparvu18. Switch accounts as described in docs/PUBLISH.md.'
}
$gitIdentity = & git var GIT_AUTHOR_IDENT
if ($LASTEXITCODE -ne 0 -or -not $gitIdentity) {
    throw 'Configure your intended Git author name/email before publishing; see docs/PUBLISH.md.'
}

Write-Host "Creating private repository $repository and a draft PR from $featureBranch."
Invoke-Checked -Program 'git' -Arguments @('init', '-b', 'main')
Invoke-Checked -Program 'git' -Arguments @('commit', '--allow-empty', '-m', 'Initialize personal Scala testing lab')
Invoke-Checked -Program 'gh' -Arguments @('repo', 'create', $repository, '--private', '--source', '.', '--remote', 'origin')
Invoke-Checked -Program 'git' -Arguments @('push', '-u', 'origin', 'main')
Invoke-Checked -Program 'git' -Arguments @('checkout', '-b', $featureBranch)
Invoke-Checked -Program 'git' -Arguments (@('add', '--') + $allowlist)
Invoke-Checked -Program 'git' -Arguments @('diff', '--cached', '--stat')
Invoke-Checked -Program 'git' -Arguments @('commit', '-m', 'Add ZIO PostgreSQL RxNorm terminology mapping lab')
Invoke-Checked -Program 'git' -Arguments @('push', '-u', 'origin', $featureBranch)
Invoke-Checked -Program 'gh' -Arguments @(
    'pr', 'create', '--repo', $repository, '--draft', '--base', 'main', '--head', $featureBranch,
    '--title', 'Add Scala ZIO and PostgreSQL RxNorm mapping lab', '--body-file', 'docs/PR.md'
)
Write-Host "Published $repository with the implementation on $featureBranch. The draft PR has not been merged."
