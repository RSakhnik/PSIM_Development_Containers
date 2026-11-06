$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'scripts\platform-package.ps1')
$root=Join-Path $repo 'test-results\manifest-proxy-browser'
$token=(Get-Content (Join-Path $root 'test-token.txt') -Raw).Trim()
$echo=$null;$configPath=Join-Path $root 'fixed\.pilot-instances\fixture-a\instance.json'
$original=[IO.File]::ReadAllText($configPath)
try {
 [void](Invoke-RestMethod 'http://127.0.0.1:17110/api/v1/session' -Method Post -ContentType application/json -Body (@{token=$token}|ConvertTo-Json -Compress) -SessionVariable session -TimeoutSec 10)
 $page=Invoke-WebRequest 'http://127.0.0.1:17111/' -WebSession $session -UseBasicParsing -TimeoutSec 10
 if($page.Content -notmatch 'crossorigin="use-credentials"'){throw 'Packaged API did not rewrite manifest link'}
 $manifest=Invoke-WebRequest 'http://127.0.0.1:17111/manifest.json' -WebSession $session -UseBasicParsing -TimeoutSec 10
 $manifestText=if($manifest.Content -is [byte[]]){[Text.Encoding]::UTF8.GetString($manifest.Content)}else{[string]$manifest.Content}
 if($manifest.StatusCode -ne 200 -or ($manifestText|ConvertFrom-Json).name -ne 'Pilot manifest regression'){throw 'Credentialed manifest did not load'}
 Add-Type -AssemblyName System.Net.Http
 $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$client=[Net.Http.HttpClient]::new($handler)
 try{$anonymous=$client.GetAsync('http://127.0.0.1:17111/manifest.json').GetAwaiter().GetResult();if([int]$anonymous.StatusCode -ne 302){throw 'Anonymous manifest became public'}}finally{$client.Dispose();$handler.Dispose()}
 $exe=Join-Path $PSScriptRoot 'Ingress.WebSocketEcho\bin\Debug\net8.0\Ingress.WebSocketEcho.exe'
 $echo=Start-Process -FilePath $exe -ArgumentList @('--urls','http://127.0.0.1:17103') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $root 'echo.stdout.log') -RedirectStandardError (Join-Path $root 'echo.stderr.log')
 $deadline=[DateTime]::UtcNow.AddSeconds(20)
 do{try{[void](Invoke-RestMethod 'http://127.0.0.1:17103/headers' -TimeoutSec 2);break}catch{if([DateTime]::UtcNow -gt $deadline){throw};Start-Sleep -Milliseconds 200}}while($true)
 $config=$original|ConvertFrom-Json;$config.ports.web=17103;Write-PlatformJson $configPath $config
 $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test-IngressWebSocket.ps1'),[ref]$null,[ref]$null)
 $function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-WebSocket'},$true)
 Invoke-Expression $function.Extent.Text
 if(-not (Test-WebSocket 'ws://127.0.0.1:17110/ws' '' '127.0.0.1:17111' $session.Cookies)){throw 'WebSocket regression'}
 Write-PlatformJson (Join-Path $root 'packaged-test-result.json') @{packagedApi=$true;htmlRewritten=$true;credentialedManifest200=$true;anonymousStill302=$true;realWebSocketEcho=$true;databaseTouched=$false}
 'PACKAGED API PASS: credentialed manifest 200; anonymous 302; real authenticated WebSocket echo.'
} finally {
 [IO.File]::WriteAllText($configPath,$original,(New-Object Text.UTF8Encoding($false)))
 if($echo -and -not $echo.HasExited){$echo.Kill();$echo.WaitForExit()}
 $token=$null
}
