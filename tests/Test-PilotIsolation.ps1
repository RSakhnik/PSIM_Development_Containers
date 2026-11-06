[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $DatabaseTemplate,
    [string] $DatabaseName = 'pilot-ice_ru',
    [string] $ImageTag = '26.9.0',
    [ValidateRange(30, 900)] [int] $StartupTimeoutSeconds = 240,
    [switch] $KeepEnvironments,
    [string] $JsonReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'PilotIsolation\PilotIsolation.psm1'
Import-Module $modulePath -Force

$arguments = @{
    DatabaseTemplate = $DatabaseTemplate
    DatabaseName = $DatabaseName
    ImageTag = $ImageTag
    StartupTimeoutSeconds = $StartupTimeoutSeconds
    KeepEnvironments = $KeepEnvironments
}
$report = Test-PilotInstanceIsolation @arguments

Write-Host ''
Write-Host 'Результаты проверки изоляции:' -ForegroundColor Cyan
$report.Checks | Format-Table Name, Passed, Details -Wrap -AutoSize

if (-not [string]::IsNullOrWhiteSpace($JsonReportPath)) {
    $reportDirectory = Split-Path -Parent $JsonReportPath
    if (-not [string]::IsNullOrWhiteSpace($reportDirectory)) {
        [void](New-Item -ItemType Directory -Path $reportDirectory -Force)
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $JsonReportPath -Encoding utf8NoBOM
    Write-Host "JSON-отчёт: $([IO.Path]::GetFullPath($JsonReportPath))"
}

if ($report.Passed) {
    Write-Host 'PASS: два изолированных стенда могут работать одновременно.' -ForegroundColor Green
    exit 0
}

Write-Host 'FAIL: одна или несколько проверок изоляции не пройдены.' -ForegroundColor Red
if ($report.FatalError) { Write-Host $report.FatalError -ForegroundColor Red }
exit 1

