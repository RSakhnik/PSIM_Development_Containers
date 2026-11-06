[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$installPath = Join-Path $root 'scripts\install-api-service.ps1'
$deployPath = Join-Path $root 'scripts\deploy-server.ps1'
$install = Get-Content -LiteralPath $installPath -Raw
$deploy = Get-Content -LiteralPath $deployPath -Raw

function Get-ParameterNames([string] $Path) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors) { throw "PowerShell parse failed: $Path" }
    @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
}

$installParameters = Get-ParameterNames $installPath
$deployParameters = Get-ParameterNames $deployPath
if ('ServiceCredential' -in $installParameters -or 'ServiceCredential' -in $deployParameters) { throw 'ServiceCredential must not be part of the standard deployment interface.' }
if ('LegacyServiceCredential' -notin $installParameters -or 'LegacyServiceCredential' -notin $deployParameters) { throw 'Explicit legacy identity compatibility is missing.' }
if ($install -match 'Get-Credential') { throw 'The Windows Service installer must not request credentials.' }
if ($install -match 'docker-users') { throw 'The Windows Service installer must not modify docker-users.' }
foreach ($required in @('\*S-1-5-18', 'obj= LocalSystem', '/health/ready', "\.pilot-templates")) {
    if ($install -notmatch $required) { throw "LocalSystem invariant is missing: $required" }
}
if ($deploy -notmatch 'dockerReady' -or $deploy -notmatch 'serviceIdentity') { throw 'Deployment result must include service identity and Docker readiness.' }
if ($install -notmatch '\$packagedServiceDirectory\s*=\s*Join-Path\s+\$root\s+''service''' -or $install -notmatch 'PilotEnv\.Api\.exe') {
    throw 'The packaged service directory must be discovered automatically.'
}
if ($deploy -notmatch 'SuppressInstallHint') { throw 'The one-step deployment must suppress the standalone installer hint.' }
if ((Get-Content -LiteralPath (Join-Path $root 'src\PilotEnv.Api\AppOptions.cs') -Raw) -notmatch 'PowerShellExecutable.*powershell\.exe') {
    throw 'The API must default to the built-in Windows PowerShell executable.'
}

Write-Host 'LocalSystem deployment contract: OK' -ForegroundColor Green

