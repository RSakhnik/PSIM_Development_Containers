[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')][string] $LocalAddress,
    [string] $InterfaceAlias,
    [ValidateRange(1, 65535)][int] $Port = 17070,
    [string] $RuleName = 'Pilot Environment API - VPN'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
if ($existing) {
    $existing | Remove-NetFirewallRule
}

$parameters = @{
    DisplayName = $RuleName
    Description = 'Pilot BIM development control API, selected VPN address only'
    Direction = 'Inbound'
    Action = 'Allow'
    Enabled = 'True'
    Profile = 'Any'
    Protocol = 'TCP'
    LocalPort = $Port
    LocalAddress = $LocalAddress
}
if (-not [string]::IsNullOrWhiteSpace($InterfaceAlias)) {
    $parameters.InterfaceAlias = $InterfaceAlias
}
New-NetFirewallRule @parameters | Out-Null

