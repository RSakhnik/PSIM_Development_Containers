[CmdletBinding()]
param([string] $Bundle)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'platform-test-fixtures.ps1')
if(-not $Bundle){$Bundle=Join-Path $repo 'artifacts\PilotEnvironment-win-x64.zip'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('pilot-scm-test-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $root)
# Model only SCM and HTTP; packages, state files, journal, validation and rollback are real.
$scm=[pscustomobject]@{Exists=$true;Status='Running';Binary='old-api.exe';Stops=0;Starts=0;FailBuildHash='';DrainReads=0}
function Get-Service([string]$Name){
    if(-not $scm.Exists){return $null}
    $service=[pscustomobject]@{Name=$Name;Status=$scm.Status}
    $service|Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {param($state,$timeout)}
    return $service
}
function Get-CimInstance([string]$ClassName,[string]$Filter){[pscustomobject]@{PathName=$scm.Binary;StartName='LocalSystem'}}
function Invoke-CimMethod { param($InputObject,[string]$MethodName,$Arguments)
    if($MethodName -ne 'Change'){throw 'Unexpected CIM method'}
    $scm.Binary=$Arguments.PathName
    [pscustomobject]@{ReturnValue=0}
}
function Stop-Service([string]$Name,[switch]$Force){$scm.Status='Stopped';$scm.Stops++}
function Start-Service([string]$Name){$scm.Status='Running';$scm.Starts++}
function New-Service([string]$Name,[string]$BinaryPathName,[string]$StartupType,[string]$DisplayName){$scm.Exists=$true;$scm.Binary=$BinaryPathName;$scm.Status='Stopped'}
function sc.exe {
    $nativeArguments=@($args)
    if($nativeArguments[0] -eq 'config'){
        foreach($argument in $nativeArguments){if([string]$argument -like 'binPath= *'){$scm.Binary=([string]$argument).Substring(9)}}
    }
    if($nativeArguments[0] -eq 'delete'){$scm.Exists=$false;$scm.Status='Stopped'}
    $global:LASTEXITCODE=0
}
function icacls.exe {$global:LASTEXITCODE=0}
function Invoke-WebRequest {
    [CmdletBinding()]param([string]$Uri,[switch]$UseBasicParsing,$Headers,[int]$TimeoutSec)
    $path=([Uri]$Uri).AbsolutePath
    if(-not $scm.Exists -or $scm.Status -ne 'Running'){throw 'Service is offline.'}
    if($path -eq '/internal/platform/activity'){
        $scm.DrainReads++
        return [pscustomobject]@{StatusCode=200;Content='{"activeOperations":0,"maintenance":{"component":"control-api"}}'}
    }
    if($path -eq '/health/ready' -and $scm.FailBuildHash -and $scm.Binary.Contains($scm.FailBuildHash)){throw 'Simulated readiness failure.'}
    return [pscustomobject]@{StatusCode=200;Content='{}'}
}
try{
    $initial=Initialize-TestInstallation $root $Bundle
    $statePath=Join-Path $root '.pilot-runtime\deployment-state.json'
    $settings=Join-Path $root '.pilot-runtime\api\hostsettings.json'
    Write-PlatformJson $settings @{PilotEnv=@{ListenUrl='http://127.0.0.1:17070';PublicHost='360pilot.ru';ControlPublicPort=17443}}
    $initialApiHash=$initial.components['control-api'].buildHash
    $packageDirectory=Join-Path $root 'new-api'
    $nextApiHash=New-TestBuild (Get-PlatformBuildPath $root 'control-api' $initialApiHash) $packageDirectory 'next-api'
    $zip=Join-Path $root 'api-next.zip';Compress-Archive -Path (Join-Path $packageDirectory '*') -DestinationPath $zip
    & (Join-Path $repo 'scripts\update-platform.ps1') -Component control-api -Package $zip -InstallRoot $root -ServiceName 'PilotEnvMock'|Out-Null
    if(-not $scm.Binary.Contains($nextApiHash) -or $scm.Stops -ne 1 -or $scm.Starts -ne 1 -or $scm.DrainReads -lt 1){throw 'API service switch did not drain and restart correctly.'}
    $repeated=& (Join-Path $repo 'scripts\update-platform.ps1') -Component control-api -Package $zip -InstallRoot $root -ServiceName 'PilotEnvMock'
    if($repeated.state -ne 'unchanged' -or $scm.Stops -ne 1 -or $scm.Starts -ne 1){throw 'Installing identical content restarted the service.'}
    $workingBinary=$scm.Binary
    Write-PilotUtf8NoBom -LiteralPath (Join-Path $packageDirectory 'build-marker.txt') -Text 'broken-api'
    $brokenApiHash=Update-TestManifest $packageDirectory
    $zip=Join-Path $root 'api-broken.zip';Compress-Archive -Path (Join-Path $packageDirectory '*') -DestinationPath $zip
    $scm.FailBuildHash=$brokenApiHash
    $failed=$false
    try{& (Join-Path $repo 'scripts\update-platform.ps1') -Component control-api -Package $zip -InstallRoot $root -ServiceName 'PilotEnvMock' -HealthTimeoutSeconds 1|Out-Null}catch{$failed=$true}
    $state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
    if(-not $failed -or $state.components.'control-api'.buildHash -ne $nextApiHash -or $scm.Binary -ne $workingBinary -or $scm.Status -ne 'Running'){throw 'Readiness failure did not restore the API state and service binary.'}
    if(Test-Path -LiteralPath (Join-Path $root '.pilot-runtime\platform-maintenance.json')){throw 'Maintenance marker was not released.'}
    # Legacy layout is detected by format only, regardless of release labels.
    $legacy=[pscustomobject]@{schemaVersion=1;components=[pscustomobject]@{'control-api'=@{version='arbitrary-legacy-label'}};history=@()}
    Write-PlatformJson $statePath $legacy
    $scm.Status='Stopped';$scm.FailBuildHash=$initialApiHash
    $failed=$false
    try{& (Join-Path $repo 'scripts\update-platform.ps1') -Component all -Package $root -InstallRoot $root -ServiceName 'PilotEnvMock' -HealthTimeoutSeconds 1|Out-Null}catch{$failed=$true}
    $restored=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
    if(-not $failed -or $restored.schemaVersion -ne 1 -or $scm.Binary -ne $workingBinary){throw 'Layout migration did not roll back the legacy state and binary.'}
    # Initial installation also cleans up its new service and active pointer on failure.
    Remove-Item -LiteralPath $statePath -Force
    Remove-Item -LiteralPath (Join-Path $root '.pilot-runtime\platform-update-journal.json') -Force
    $scm.Exists=$false;$scm.Status='Stopped';$scm.Binary='';$scm.FailBuildHash=$initialApiHash
    $failed=$false
    try{& (Join-Path $repo 'scripts\update-platform.ps1') -Component all -Package $root -InstallRoot $root -ServiceName 'PilotEnvMock' -HealthTimeoutSeconds 1|Out-Null}catch{$failed=$true}
    if(-not $failed -or $scm.Exists -or (Test-Path -LiteralPath $statePath)){throw 'Failed first installation left a service or active deployment pointer.'}
    Write-Host 'SCM model test: OK (drain, API switch, readiness failure, binary/state rollback, maintenance cleanup).'
}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
