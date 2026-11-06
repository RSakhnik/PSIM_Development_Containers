param([ValidateSet('ice-dev','bim-dev')][string]$Mode)
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\scripts\pilot-env.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$null,[ref]$null)
$definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Refresh-VerifiedRelease'},$true)
Invoke-Expression $definition.Extent.Text
$script:RuntimeRoot=$env:TEMP;$LicenseFile='synthetic';$ConfigurationFile='synthetic';$script:ReleaseOverride=$null
function Assert-BimMemoryCapacity {}
function Resolve-ReleaseSet { param([switch]$Pull) [pscustomobject]@{images=@{}} }
function Prepare-BimTemplate { if($script:failTemplate){throw 'synthetic template failure'} }
function Get-InstancePath {param($Name) Join-Path $env:TEMP ('nonexistent-'+$Name)}
function New-Instance { if($Mode -ne 'bim-dev' -or -not $Start -or $Name -notlike 'validation-*'){throw 'Validation scope missing'} }
function Save-ReleaseAsKnownGood {param($Release) $script:saved=$true}
function Write-Info {param($Message)}
$script:failTemplate=$false;$script:saved=$false
Refresh-VerifiedRelease
if(-not $script:saved -or $Mode -or $script:ReleaseOverride){throw 'Validation scope leaked'}
$script:failTemplate=$true
try { Refresh-VerifiedRelease; throw 'Expected template error' } catch { if($_.Exception.Message -notlike '*synthetic template failure*'){throw} }
Write-Host 'Release validation scope: OK (omitted Mode, successful cleanup, original failure preserved).'
