$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'scripts\platform-package.ps1')
$evidence=Join-Path $repo 'test-results\update-ui-regression'
$root=Join-Path $evidence ('install-'+[guid]::NewGuid().ToString('N'))
$payload=Join-Path $repo 'test-results\ui-final-package-validation\components'
$oldUi=Join-Path $repo 'test-results\isolation-probe\validated-platform-bundle\components\web-ui'
$previous=[pscustomobject]@{schemaVersion=2;components=[pscustomobject]@{};history=@()}
foreach($kind in @('control-api','environment-engine','web-ui')){
 $source=if($kind -eq 'web-ui'){$oldUi}else{Join-Path $payload $kind}
 $hash=Get-PlatformHash (Join-Path $source 'component-manifest.json')
 $previous.components | Add-Member -NotePropertyName $kind -NotePropertyValue ([pscustomobject]@{buildHash=$hash})
 $to=Get-PlatformBuildPath $root $kind $hash
 [void](New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force)
 Copy-Item -LiteralPath $source -Destination $to -Recurse
}
Write-PlatformJson (Join-Path $root '.pilot-runtime\deployment-state.json') $previous
$runtime=Join-Path $root '.pilot-runtime\api'
[void](New-Item -ItemType Directory -Path $runtime -Force)
Copy-Item -LiteralPath (Join-Path $repo 'test-results\ui-pilot-preview\.pilot-runtime\api\secrets.json') -Destination $runtime
Write-PlatformJson (Join-Path $runtime 'hostsettings.json') @{PilotEnv=@{ListenUrl='http://127.0.0.1:17077';PublicHost='127.0.0.1';PublicScheme='http';ControlPublicPort=17077;RepositoryRoot=$root;PowerShellExecutable=(Get-PilotWindowsPowerShellPath)}}
$exe=Join-Path (Get-PlatformBuildPath $root 'control-api' $previous.components.'control-api'.buildHash) 'PilotEnv.Api.exe'
$process=$null
# Only Windows service inventory and ACL tools are mocked. Actual installer,
# package integrity checks, state switches, rollback and HTTP API/UI are real.
function Get-Service {param($Name,$ErrorAction) [pscustomobject]@{Name=$Name;Status='Running'}}
function Get-CimInstance {param($ClassName,$Filter) [pscustomobject]@{PathName=$exe;StartName='LocalSystem'}}
function icacls.exe {param([Parameter(ValueFromRemainingArguments=$true)]$Arguments) $global:LASTEXITCODE=0}
try {
 $process=Start-Process -FilePath $exe -ArgumentList @('--contentRoot',('"'+$root+'"')) -WorkingDirectory $root -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $root 'api.stdout.log') -RedirectStandardError (Join-Path $root 'api.stderr.log')
 $deadline=[DateTime]::UtcNow.AddSeconds(30)
 do{try{[void](Invoke-WebRequest 'http://127.0.0.1:17077/health/live' -UseBasicParsing -TimeoutSec 2);break}catch{if([DateTime]::UtcNow -ge $deadline){throw};Start-Sleep -Milliseconds 300}}while($true)
 $new=Join-Path $payload 'web-ui'
 $failed=$false
 try{& (Join-Path $evidence 'old-tools\update-platform.ps1') -Component web-ui -Package $new -InstallRoot $root | Out-Null}catch{$failed=$true;$oldError=$_.Exception.Message}
 if(-not $failed){throw 'Old installer did not reproduce the missing api-client.js 404'}
 $state=Get-Content (Join-Path $root '.pilot-runtime\deployment-state.json') -Raw|ConvertFrom-Json
 if($state.components.'web-ui'.buildHash -ne $previous.components.'web-ui'.buildHash){throw 'Old failed update did not roll back UI'}
 & (Join-Path $repo 'scripts\update-platform.ps1') -Component web-ui -Package $new -InstallRoot $root | Out-Null
 $newHash=Get-PlatformHash (Join-Path $new 'component-manifest.json')
 $state=Get-Content (Join-Path $root '.pilot-runtime\deployment-state.json') -Raw|ConvertFrom-Json
 if($state.components.'web-ui'.buildHash -ne $newHash){throw 'Fixed installer did not activate UI'}
 $bad=Join-Path $root 'bad-ui-package';Copy-Item -LiteralPath $new -Destination $bad -Recurse
 [IO.File]::WriteAllText((Join-Path $bad 'unsupported.js'),'console.log("missing route")')
 $m=Get-Content (Join-Path $bad 'component-manifest.json') -Raw|ConvertFrom-Json
 $m.files+=@([pscustomobject]@{path='unsupported.js';length=([IO.FileInfo](Join-Path $bad 'unsupported.js')).Length;sha256=(Get-PlatformHash (Join-Path $bad 'unsupported.js'))})
 Write-PlatformJson (Join-Path $bad 'component-manifest.json') $m
 $failed=$false
 try{& (Join-Path $repo 'scripts\update-platform.ps1') -Component web-ui -Package $bad -InstallRoot $root | Out-Null}catch{$failed=$true;$badError=$_.Exception.Message}
 if(-not $failed -or $badError -notlike '*unsupported.js*'){throw 'Missing served resource did not fail with its filename'}
 $state=Get-Content (Join-Path $root '.pilot-runtime\deployment-state.json') -Raw|ConvertFrom-Json
 if($state.components.'web-ui'.buildHash -ne $newHash){throw 'Failed resource check did not restore prior working UI'}
 & (Join-Path $repo 'scripts\update-platform.ps1') -Component web-ui -Package $oldUi -InstallRoot $root | Out-Null
 $page=Invoke-WebRequest 'http://127.0.0.1:17077/' -UseBasicParsing -TimeoutSec 10
 if(-not $page.Content.Contains($previous.components.'web-ui'.buildHash)){throw 'Legacy UI package failed'}
 Write-PlatformJson (Join-Path $evidence 'result.json') @{old404Reproduced=$true;oldFailureRolledBack=$true;fixedInstallerPassed=$true;missingResourceRejected=$true;missingResourceRolledBack=$true;legacyUiPassed=$true;realHttp=$true;windowsServiceMocked=$true;aclMocked=$true;root=$root}
 'UI INSTALLER PASS: old 404 reproduced; fixed activation; missing-resource rollback; legacy UI; actual HTTP.'
} finally {if($process -and -not $process.HasExited){$process.Kill();$process.WaitForExit()}}
