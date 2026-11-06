param([string]$ApiExecutable)
Add-Type -AssemblyName System.Security
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'scripts\platform-package.ps1')
. (Join-Path $PSScriptRoot 'Test-IngressWebSocket.ps1')
$root=Join-Path $repo ('test-results\local-api-ingress-'+[guid]::NewGuid().ToString('N'))
$process=$null
try{
    $apiRoot=Join-Path $root '.pilot-runtime\api'
    [void](New-Item -ItemType Directory -Path $apiRoot -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $root 'scripts') -Force)
    Copy-Item (Join-Path $PSScriptRoot 'fixtures\engine-status.fixture.ps1') (Join-Path $root 'scripts\pilot-env.ps1')
    Write-PlatformJson (Join-Path $root '.pilot-runtime\deployment-state.json') @{schemaVersion=2;components=@{}}
    $token=[guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N')
    $salt=New-PilotRandomBytes -Count 32
    $derive=New-Object Security.Cryptography.Rfc2898DeriveBytes($token,$salt,210000,[Security.Cryptography.HashAlgorithmName]::SHA256)
    try{$hash=$derive.GetBytes(32)}finally{$derive.Dispose()}
    $tokenHash="v1.210000.$([Convert]::ToBase64String($salt)).$([Convert]::ToBase64String($hash))"
    $protected=[Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes('admin'),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine))
    Write-PlatformJson (Join-Path $apiRoot 'secrets.json') @{tokenHash=$tokenHash;adminPasswordProtected=$protected;bimPasswordProtected=$protected}
    Write-PlatformJson (Join-Path $apiRoot 'hostsettings.json') @{PilotEnv=@{RepositoryRoot=$root;ListenUrl='http://127.0.0.1:17074';PublicHost='127.0.0.1';PublicScheme='http';ControlPublicPort=17444;PowerShellExecutable=(Get-PilotWindowsPowerShellPath)}}
    foreach($name in @('fixture-a','fixture-b')){
        $instance=Join-Path $root ".pilot-instances\$name"
        [void](New-Item -ItemType Directory -Path $instance -Force)
        $index=if($name -eq 'fixture-a'){0}else{1}
        Write-PlatformJson (Join-Path $instance 'instance.json') @{name=$name;schemaVersion=4;mode='bim-dev';ports=@{web=28081;admin=15200;server=15545};publicPorts=@{web=18000+$index;admin=19000+$index}}
    }
    $exe=if($ApiExecutable){[IO.Path]::GetFullPath($ApiExecutable)}else{Join-Path $repo 'test-results\local-api-publish\PilotEnv.Api.exe'}
    $process=Start-Process -FilePath $exe -ArgumentList @('--contentRoot',('"'+$root+'"')) -WorkingDirectory $root -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $root 'api.stdout.log') -RedirectStandardError (Join-Path $root 'api.stderr.log')
    $auth=@{Authorization="Bearer $token";Host='127.0.0.1:17444'}
    $base='http://127.0.0.1:17074'
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    do{try{[void](Invoke-RestMethod "$base/health/live" -Headers $auth -TimeoutSec 2);break}catch{if([DateTime]::UtcNow -gt $deadline){throw};Start-Sleep -Milliseconds 300}}while($true)
    $envs=Invoke-RestMethod "$base/api/v1/environments" -Headers $auth -TimeoutSec 30
    if($envs.Count -ne 2){throw 'Expected two local fixture environments'}
    foreach($environment in $envs){
        if($environment.adminPort -ne 15200){throw 'Short password corrupted adminPort key'}
        if($environment.components[-1].name -ne 'pilot-web-myadmin'){throw 'Short password corrupted component identity'}
        if($environment.images.myAdmin -ne 'fixture/pilot-web-myadmin:release'){throw 'Short password corrupted image reference'}
        if($environment.lastError -ne 'Диагностика: credentials *** are never exposed'){throw 'Secret diagnostic not redacted'}
    }
    [void](Invoke-RestMethod "$base/api/v1/session" -Headers @{Host="127.0.0.1:17444"} -Method Post -ContentType application/json -Body (@{token=$token}|ConvertTo-Json -Compress) -SessionVariable browserSession)
    foreach($port in @(18000,18001)){
        if(-not (Test-WebSocket "ws://127.0.0.1:17074/ws" "" "127.0.0.1:$port" $browserSession.Cookies)){throw 'API reverse-proxy WebSocket failed'}
    }
    $ready=Invoke-RestMethod "$base/health/ready" -Headers $auth -TimeoutSec 30
    if($ready.status -ne 'ready'){throw 'Local API not ready'}
    Write-PlatformJson (Join-Path $root 'result.json') @{passed=$true;localApi=$base;typedStatusFixture=$true;realDockerWebSocket=$true;routes=@(18000,18001);shortPasswordRedaction=$true}
    Write-Host "LOCAL API PASS: real API+YARP -> outer nginx -> fixed inner nginx -> real WebSocket echo on both routes; typed fixture JSON identities intact; diagnostics redacted. Evidence: $root"
}finally{
    if($process -and -not $process.HasExited){$process.Kill();$process.WaitForExit()}
    $token=$null;$auth=$null
}
