[CmdletBinding()]
param([string] $Bundle, [string] $TokenFile, [switch] $IncludeExistingEnvironments, [string] $RestartEnvironment)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'platform-test-fixtures.ps1')
if(-not $Bundle){$Bundle=Join-Path $repo 'artifacts\PilotEnvironment-win-x64.zip'}
if(-not $TokenFile){throw '-TokenFile is required for the existing test secret store.'}
$root=Join-Path $repo ('artifacts\http-test-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $root)
$process=$null
try{
    $initial=Initialize-TestInstallation $root $Bundle
    $runtime=Join-Path $root '.pilot-runtime\api'
    [void](New-Item -ItemType Directory -Path $runtime -Force)
    Copy-Item -LiteralPath (Join-Path $repo '.pilot-runtime\api\secrets.json') -Destination $runtime
    if($IncludeExistingEnvironments){
        foreach($instance in Get-ChildItem -LiteralPath (Join-Path $repo '.pilot-instances') -Directory){
            if(-not (Test-Path -LiteralPath (Join-Path $instance.FullName 'instance.json'))){continue}
            $destination=Join-Path $root ".pilot-instances\$($instance.Name)"
            [void](New-Item -ItemType Directory -Path $destination -Force)
            foreach($file in @('instance.json','.env')){Copy-Item -LiteralPath (Join-Path $instance.FullName $file) -Destination $destination}
        }
    }
    Write-PlatformJson (Join-Path $runtime 'hostsettings.json') @{PilotEnv=@{RepositoryRoot=$root;ListenUrl='http://127.0.0.1:17072';PublicHost='127.0.0.1';PublicScheme='http';ControlPublicPort=17444;PowerShellExecutable=(Get-PilotWindowsPowerShellPath);SecretFile='.pilot-runtime/api/secrets.json';DatabaseFile='.pilot-runtime/api/pilot-env.db'}}
    $initialUiHash=$initial.components['web-ui'].buildHash
    $initialEngineHash=$initial.components['environment-engine'].buildHash
    $exe=Join-Path (Get-PlatformBuildPath $root 'control-api' $initial.components['control-api'].buildHash) 'PilotEnv.Api.exe'
    $process=Start-Process -FilePath $exe -ArgumentList @('--contentRoot',('"'+$root+'"')) -WorkingDirectory $root -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $root 'stdout.log') -RedirectStandardError (Join-Path $root 'stderr.log')
    $uri='http://127.0.0.1:17072'
    $headers=@{Host='127.0.0.1:17444'}
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    $ready=$false
    do{try{[void](Invoke-WebRequest -UseBasicParsing "$uri/health/live" -Headers $headers);$ready=$true}catch{Start-Sleep -Milliseconds 300}}while(-not $ready -and [DateTime]::UtcNow -lt $deadline)
    if(-not $ready){throw 'Test API failed to start.'}
    $token=[IO.File]::ReadAllText($TokenFile).Trim()
    $auth=@{Host='127.0.0.1:17444';Authorization="Bearer $token"}
    $platform=Invoke-RestMethod "$uri/api/v1/platform" -Headers $auth
    if($platform.apiContractVersion -ne 2){throw 'Platform contract mismatch.'}
    $before=@()
    if($IncludeExistingEnvironments){
        $before=Invoke-RestMethod "$uri/api/v1/environments" -Headers $auth
        if($before.Count -lt 2 -or @($before|Where-Object state -ne 'running').Count){$before|Select-Object name,state,lastError|ConvertTo-Json -Depth 3|Write-Host;throw 'Existing environment statuses did not pass through the new engine protocol.'}
    }
    $status=0
    try{Invoke-WebRequest -UseBasicParsing "$uri/api/v1/platform" -Headers $headers|Out-Null}catch{$status=[int]$_.Exception.Response.StatusCode}
    if($status -ne 401){throw 'Platform endpoint must require authentication.'}
    $status=0
    try{Invoke-WebRequest -UseBasicParsing "$uri/api/v1/missing" -Headers $auth|Out-Null}catch{$status=[int]$_.Exception.Response.StatusCode}
    if($status -ne 404){throw 'Unknown API endpoint returned frontend fallback.'}
    $body=@{token=$token}|ConvertTo-Json -Compress
    $session=Invoke-RestMethod "$uri/api/v1/session" -Headers $headers -Method Post -ContentType application/json -Body $body -SessionVariable browserSession
    $status=0
    try{Invoke-WebRequest -UseBasicParsing "$uri/api/v1/environments" -Headers $headers -WebSession $browserSession -Method Post -ContentType application/json -Body '{"name":"x","owner":"test"}'|Out-Null}catch{$status=[int]$_.Exception.Response.StatusCode}
    if($status -ne 400){throw 'CSRF protection did not reject a missing token.'}
    $activity=Invoke-RestMethod "$uri/internal/platform/activity" -Headers $headers
    if($activity.activeOperations -ne 0){throw 'Unexpected operations in isolated HTTP test.'}
    $update=Join-Path $root 'web-update'
    $nextUiHash=New-TestBuild (Get-PlatformBuildPath $root 'web-ui' $initialUiHash) $update 'updated-ui'
    $manifest=Get-Content -LiteralPath (Join-Path $update 'component-manifest.json') -Raw|ConvertFrom-Json
    Write-PlatformJson (Join-Path $update 'component-manifest.json') $manifest
    $zip=Join-Path $root 'web-next.zip'
    Compress-Archive -Path (Join-Path $update '*') -DestinationPath $zip
    & (Join-Path $repo 'scripts\update-platform.ps1') -Component web-ui -Package $zip -InstallRoot $root -ServiceName 'PilotEnvHttpTestNonexistent'|Out-Null
    if($process.HasExited){throw 'API exited during UI update.'}
    $html=Invoke-WebRequest -UseBasicParsing "$uri/" -Headers $headers
    if(-not $html.Content.Contains(("/ui-assets/$nextUiHash/app.js"))){throw 'UI version did not change.'}
    [void](Invoke-WebRequest -UseBasicParsing "$uri/ui-assets/$initialUiHash/app.js" -Headers $headers)
    & (Join-Path $repo 'scripts\update-platform.ps1') -Component web-ui -InstallRoot $root -ServiceName 'PilotEnvHttpTestNonexistent' -Rollback|Out-Null
    $html=Invoke-WebRequest -UseBasicParsing "$uri/" -Headers $headers
    if(-not $html.Content.Contains(("/ui-assets/$initialUiHash/app.js"))){throw 'Rollback did not restore previous UI.'}
    # A structurally valid package whose page fails smoke-check must roll back automatically.
    Write-PilotUtf8NoBom -LiteralPath (Join-Path $update 'index.html') -Text '<html>broken release</html>'
    foreach($entry in $manifest.files){$path=Join-Path $update $entry.path;$entry.sha256=Get-PlatformHash $path;$entry.length=(Get-Item -LiteralPath $path).Length}
    Write-PlatformJson (Join-Path $update 'component-manifest.json') $manifest
    $brokenZip=Join-Path $root 'web-broken.zip';Compress-Archive -Path (Join-Path $update '*') -DestinationPath $brokenZip
    $failed=$false
    try{& (Join-Path $repo 'scripts\update-platform.ps1') -Component web-ui -Package $brokenZip -InstallRoot $root -ServiceName 'PilotEnvHttpTestNonexistent'|Out-Null}catch{$failed=$true}
    if(-not $failed){throw 'Broken UI passed health check.'}
    $html=Invoke-WebRequest -UseBasicParsing "$uri/" -Headers $headers
    if(-not $html.Content.Contains(("/ui-assets/$initialUiHash/app.js"))){throw 'Automatic failure rollback did not restore previous UI.'}
    # Recover a simulated interruption after switching the pointer.
    $statePath=Join-Path $root '.pilot-runtime\deployment-state.json'
    $old=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
    $next=$old|ConvertTo-Json -Depth 40|ConvertFrom-Json
    $next.components.'web-ui'.buildHash=$nextUiHash
    Write-PlatformJson $statePath $next
    Write-PlatformJson (Join-Path $root '.pilot-runtime\platform-update-journal.json') @{phase='activated';component='web-ui';previous=$old;candidate=$next;oldBinary=$null;wasRunning=$false}
    & (Join-Path $repo 'scripts\update-platform.ps1') -Component web-ui -InstallRoot $root -ServiceName 'PilotEnvHttpTestNonexistent' -Rollback|Out-Null
    $html=Invoke-WebRequest -UseBasicParsing "$uri/" -Headers $headers
    if(-not $html.Content.Contains(("/ui-assets/$initialUiHash/app.js"))){throw 'Interrupted update recovery failed.'}
    if($IncludeExistingEnvironments){
        $engineUpdate=Join-Path $root 'engine-update'
        $nextEngineHash=New-TestBuild (Get-PlatformBuildPath $root 'environment-engine' $initialEngineHash) $engineUpdate 'updated-engine'
        $engineManifest=Get-Content -LiteralPath (Join-Path $engineUpdate 'component-manifest.json') -Raw|ConvertFrom-Json
        Write-PlatformJson (Join-Path $engineUpdate 'component-manifest.json') $engineManifest
        $engineZip=Join-Path $root 'engine-next.zip';Compress-Archive -Path (Join-Path $engineUpdate '*') -DestinationPath $engineZip
        & (Join-Path $repo 'scripts\update-platform.ps1') -Component environment-engine -Package $engineZip -InstallRoot $root -ServiceName 'PilotEnvHttpTestNonexistent'|Out-Null
        $platform=Invoke-RestMethod "$uri/api/v1/platform" -Headers $auth
        if($platform.components.'environment-engine'.buildHash -ne $nextEngineHash -or $process.HasExited){throw 'Live engine update failed.'}
        & (Join-Path $repo 'scripts\update-platform.ps1') -Component environment-engine -InstallRoot $root -ServiceName 'PilotEnvHttpTestNonexistent' -Rollback|Out-Null
        Write-Host 'Live engine update and rollback: OK, API process stayed running.'
    }
    if($IncludeExistingEnvironments){
        $after=Invoke-RestMethod "$uri/api/v1/environments" -Headers $auth
        foreach($previous in $before){
            $current=$after|Where-Object name -eq $previous.name
            foreach($oldComponent in $previous.components){
                $newComponent=$current.components|Where-Object name -eq $oldComponent.name
                if($newComponent.containerId -ne $oldComponent.containerId -or $newComponent.startedAt -ne $oldComponent.startedAt -or -not $newComponent.healthy){throw 'UI updates changed or degraded a real Pilot component.'}
            }
        }
        Write-Host "Existing Pilot environments: $($after.Count), component IDs/timestamps unchanged and healthy."
        if($RestartEnvironment){
            if(-not ($after|Where-Object name -eq $RestartEnvironment)){throw 'Restart target is not in the isolated test inventory.'}
            $operation=Invoke-RestMethod "$uri/api/v1/environments/$RestartEnvironment/components/pilot-web-server/restart" -Headers $auth -Method Post -ContentType application/json -Body '{"cascade":false}'
            $deadline=[DateTime]::UtcNow.AddMinutes(4)
            do{$status=Invoke-RestMethod "$uri/api/v1/operations/$($operation.operationId)" -Headers $auth;if($status.state -in @('succeeded','failed')){break};Start-Sleep -Milliseconds 500}while([DateTime]::UtcNow -lt $deadline)
            if($status.state -ne 'succeeded'){throw "Restart operation failed: $($status.error)"}
            $restarted=Invoke-RestMethod "$uri/api/v1/environments" -Headers $auth
            foreach($previous in $after){
                $current=$restarted|Where-Object name -eq $previous.name
                foreach($oldComponent in $previous.components){
                    $newComponent=$current.components|Where-Object name -eq $oldComponent.name
                    $expectedChange=$previous.name -eq $RestartEnvironment -and $oldComponent.name -eq 'pilot-web-server'
                    if($newComponent.containerId -ne $oldComponent.containerId -or -not $newComponent.healthy -or (($newComponent.startedAt -ne $oldComponent.startedAt) -ne $expectedChange)){throw 'Restart affected an unexpected component.'}
                }
            }
            Write-Host 'Restart Web through refactored API: succeeded; only selected component startedAt changed.'
        }
    }
    Write-Host "HTTP platform test: OK; content-hash UI update and rollback, unchanged API PID $($process.Id), old assets, auth, CSRF, API 404."
}catch{
    if(Test-Path -LiteralPath (Join-Path $root 'stderr.log')){Get-Content -LiteralPath (Join-Path $root 'stderr.log') -Tail 15}
    throw
}finally{
    if($process -and -not $process.HasExited){Stop-Process -Id $process.Id; $process.WaitForExit()}
    if(Test-Path -LiteralPath $root){$checked=Resolve-PlatformChild (Join-Path $repo 'artifacts') ([IO.Path]::GetFileName($root));Remove-Item -LiteralPath $checked -Recurse -Force}
}
