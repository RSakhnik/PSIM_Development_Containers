$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\pilot-env.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Test-BimLogOnline','Ensure-StartedBimReady')) {
 $d=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 Invoke-Expression $d.Extent.Text
}
function Assert-Equal($expected,$actual,$label){if($expected -ne $actual){throw "Failed: $label"}}
Assert-Equal $false (Test-BimLogOnline 'Starting; database Initializing; Force offline') 'startup offline'
Assert-Equal $false (Test-BimLogOnline "Success connection to database`nForce offline") 'later disconnect'
Assert-Equal $true (Test-BimLogOnline "Force offline`nSuccess connection to database") 'reconnected'
Assert-Equal $false (Test-BimLogOnline 'Success connection to database InvalidLicense') 'license rejected'
$script:events=New-Object 'Collections.Generic.List[string]'
function Test-WebDatabaseLogin {param($Config) $script:events.Add('login')}
function Get-CurrentBimLogs {param($Config) $script:logs}
function Invoke-Compose {param($Config,$Arguments) $script:events.Add(($Arguments -join ' '))}
function Wait-BimComponent {param($Config,$TimeoutSeconds) $script:events.Add('wait');if($script:failWait){throw 'BIM offline'}}
function Write-Info {param($Message)}
$c=[pscustomobject]@{name='test'}
$script:logs='Database Initializing; Force offline';$script:failWait=$false
Ensure-StartedBimReady $c
Assert-Equal 'login,restart pilot-bim-server,wait' ($events -join ',') 'recover after DB readiness'
$events.Clear();$script:logs='Success connection to database'
Ensure-StartedBimReady $c
Assert-Equal 'login,wait' ($events -join ',') 'healthy BIM not restarted'
$events.Clear();$script:logs='Force offline';$script:failWait=$true
$failed=$false;try{Ensure-StartedBimReady $c}catch{$failed=$true}
Assert-Equal $true $failed 'failed readiness must fail Start'
$events.Clear();$script:failWait=$false;$script:logs='InvalidLicense'
$failed=$false;try{Ensure-StartedBimReady $c}catch{$failed=$true}
Assert-Equal $true $failed 'license failure rejected'
Assert-Equal 'login' ($events -join ',') 'license failure not restarted'
'BIM Start readiness regressions: PASS'