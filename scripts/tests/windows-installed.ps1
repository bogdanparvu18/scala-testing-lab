# Exercise discovery with the real Windows binaries already on a hosted runner.
if ($env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_ACTIONS -ne 'true') { return }
$ErrorActionPreference = 'Stop'
$scriptFile = Join-Path $PSScriptRoot '../bootstrap-windows.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptFile,[ref]$null,[ref]$null)
foreach ($function in $ast.EndBlock.Statements) {
    if ($function -is [Management.Automation.Language.FunctionDefinitionAst]) { Invoke-Expression $function.Extent.Text }
}
$NoEditor = $true
$SessionOnlyEnvironment = $true
Initialize-ToolDiscovery
$selected = @{}
foreach ($name in 'Java','Node','Git') {
    $tool = Find-SystemTool $name
    if ($tool.state -ne 'compatible') { throw "$name discovery: $($tool.reason)" }
    Write-Host "$name $($tool.version) at $($tool.path)"
    $selected[$name] = $tool
}
Use-ToolEnvironment $selected
if ((Get-Command java.exe).Source -ne $selected.Java.path -or $env:JAVA_HOME -ne $selected.Java.javaHome) {
    throw 'The resolved JVM is not active in the test process.'
}
if ((Get-Command node.exe).Source -ne $selected.Node.path -or -not (Test-Path $selected.Node.npm)) {
    throw 'Node/npm recovery did not select runnable commands.'
}
