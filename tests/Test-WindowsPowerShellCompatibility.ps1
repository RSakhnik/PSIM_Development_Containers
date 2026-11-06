[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scripts = Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File
$combined = ($scripts | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"

foreach ($forbidden in @('pwsh.exe', '-Encoding utf8NoBOM', '$IsWindows')) {
    if ($combined.Contains($forbidden)) { throw "PowerShell 7-only dependency remains: $forbidden" }
}
if ($combined -notmatch 'WindowsPowerShell\\v1\.0\\powershell\.exe') {
    throw 'The built-in Windows PowerShell executable is not configured.'
}

$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$parserScript = @'
$errors = @()
Get-ChildItem -LiteralPath '__SCRIPTS__' -Filter '*.ps1' -File | ForEach-Object {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { $errors += $parseErrors }
}
if ($errors) { $errors | ForEach-Object { Write-Error $_.Message }; exit 1 }
'@.Replace('__SCRIPTS__', (Join-Path $root 'scripts').Replace("'", "''"))
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($parserScript))
& $powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell 5.1 parser rejected a deployment script.' }

Write-Host 'Windows PowerShell 5.1 deployment contract: OK' -ForegroundColor Green
