[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateRange(1,65535)][int] $ControlPublicPort = 17443,
    [ValidateRange(1,65535)][int] $WebPublicPortStart = 18000,
    [ValidateRange(1,65535)][int] $WebPublicPortEnd = 18049,
    [ValidateRange(1,65535)][int] $AdminPublicPortStart = 19000,
    [ValidateRange(1,65535)][int] $AdminPublicPortEnd = 19049,
    [string] $RulePrefix = 'Pilot Environment HTTPS'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ps-compat.ps1')
if (-not (Test-PilotWindowsHost)) { throw 'Windows Firewall configuration is supported only on Windows.' }
if ($WebPublicPortEnd -lt $WebPublicPortStart -or $AdminPublicPortEnd -lt $AdminPublicPortStart) { throw 'Invalid public port range.' }

$rules = @(
    [pscustomobject]@{ Name="$RulePrefix Control"; Ports=[string]$ControlPublicPort },
    [pscustomobject]@{ Name="$RulePrefix Web"; Ports="$WebPublicPortStart-$WebPublicPortEnd" },
    [pscustomobject]@{ Name="$RulePrefix myAdmin"; Ports="$AdminPublicPortStart-$AdminPublicPortEnd" }
)
foreach ($rule in $rules) {
    if (-not $PSCmdlet.ShouldProcess($rule.Name, "Allow inbound TCP $($rule.Ports)")) { continue }
    Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $rule.Ports -Profile Any | Out-Null
}
$rules
