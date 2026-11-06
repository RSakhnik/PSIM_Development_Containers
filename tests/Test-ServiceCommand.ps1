$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\ps-compat.ps1')
$script:actual = ''
$script:resultCode = 0
$script:corrupt = $false
function Get-CimInstance { param($ClassName,$Filter) [pscustomobject]@{PathName=$script:actual} }
function Invoke-CimMethod {
    param($InputObject,$MethodName,$Arguments)
    if($Arguments.StartMode -ne 'Automatic'){throw 'Automatic startup missing'}
    $script:actual = if($script:corrupt){$Arguments.PathName.Replace('"','')}else{$Arguments.PathName}
    [pscustomobject]@{ReturnValue=$script:resultCode}
}
$command = '"C:\Folder With Spaces\PilotEnv.Api.exe" --contentRoot "C:\Data With Spaces"'
Set-PilotServiceCommand -Name PilotEnvironmentApi -BinaryPath $command
if($script:actual -cne $command){throw 'Quotes changed'}
$script:corrupt=$true
$failed=$false
try{Set-PilotServiceCommand -Name PilotEnvironmentApi -BinaryPath $command}catch{$failed=$true}
if(-not $failed){throw 'Corrupted SCM path was accepted'}
$script:corrupt=$false;$script:resultCode=87
$failed=$false
try{Set-PilotServiceCommand -Name PilotEnvironmentApi -BinaryPath $command}catch{$failed=$true}
if(-not $failed){throw 'SCM error was ignored'}
Write-Host 'Service command contract: OK (spaces, quotes, read-back mismatch, SCM rejection).'
