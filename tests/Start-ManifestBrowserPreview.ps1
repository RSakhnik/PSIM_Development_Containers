$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Security
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'scripts\platform-package.ps1')
$root=Join-Path $repo 'test-results\manifest-proxy-browser'
[void](New-Item -ItemType Directory -Path $root -Force)
$token=[guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N')
$salt=New-PilotRandomBytes -Count 32
$derive=New-Object Security.Cryptography.Rfc2898DeriveBytes($token,$salt,210000,[Security.Cryptography.HashAlgorithmName]::SHA256)
try{$hash=$derive.GetBytes(32)}finally{$derive.Dispose()}
$tokenHash="v1.210000.$([Convert]::ToBase64String($salt)).$([Convert]::ToBase64String($hash))"
$protected=[Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes('admin'),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine))
[IO.File]::WriteAllText((Join-Path $root 'test-token.txt'),$token)
$pids=@()
foreach($variant in @('old','fixed')){
 $base=Join-Path $root $variant
 [void](New-Item -ItemType Directory -Path (Join-Path $base 'scripts') -Force)
 Copy-Item (Join-Path $PSScriptRoot 'fixtures\engine-status.fixture.ps1') (Join-Path $base 'scripts\pilot-env.ps1')
 Write-PlatformJson (Join-Path $base '.pilot-runtime\deployment-state.json') @{schemaVersion=2;components=@{}}
 Write-PlatformJson (Join-Path $base '.pilot-runtime\api\secrets.json') @{tokenHash=$tokenHash;adminPasswordProtected=$protected;bimPasswordProtected=$protected}
 $control=if($variant -eq 'old'){17100}else{17110};$web=if($variant -eq 'old'){17101}else{17111};$admin=if($variant -eq 'old'){19101}else{19111}
 Write-PlatformJson (Join-Path $base '.pilot-runtime\api\hostsettings.json') @{PilotEnv=@{RepositoryRoot=$base;ListenUrl="http://127.0.0.1:$control";PublicHost='127.0.0.1';PublicScheme='http';ControlPublicPort=$control;WebPublicPortStart=$web;WebPublicPortEnd=$web;AdminPublicPortStart=$admin;AdminPublicPortEnd=$admin;PowerShellExecutable=(Get-PilotWindowsPowerShellPath)}}
 Write-PlatformJson (Join-Path $base '.pilot-instances\fixture-a\instance.json') @{name='fixture-a';schemaVersion=4;mode='bim-dev';ports=@{web=17102;admin=15200;server=15545};publicPorts=@{web=$web;admin=$admin}}
 & (Join-Path $repo 'scripts\build-web-ui.ps1') -OutputDirectory (Join-Path $base 'src\PilotEnv.Web')
 $webSource=Join-Path $base 'src\PilotEnv.Web'
 $uiHash=Get-PlatformHash (Join-Path $webSource 'app.js')
 $uiBuild=Join-Path $base ".pilot-runtime\builds\web-ui\$uiHash"
 [void](New-Item -ItemType Directory -Path $uiBuild -Force);Copy-Item -Path (Join-Path $webSource '*') -Destination $uiBuild -Force
 Write-PlatformJson (Join-Path $base '.pilot-runtime\deployment-state.json') @{schemaVersion=2;components=@{'web-ui'=@{buildHash=$uiHash}}}
 $exe=if($variant -eq 'old'){Join-Path $repo 'test-results\ui-final-package-validation\components\control-api\PilotEnv.Api.exe'}else{Join-Path $repo 'src\PilotEnv.Api\bin\Debug\net9.0\PilotEnv.Api.exe'}
 $p=Start-Process -FilePath $exe -ArgumentList @('--contentRoot',('"'+$base+'"')) -WorkingDirectory $base -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $base 'api.stdout.log') -RedirectStandardError (Join-Path $base 'api.stderr.log')
 $pids+=@{variant=$variant;pid=$p.Id;control=$control;web=$web}
}
$p=Start-Process python -ArgumentList @('tests\manifest-browser-fixture.py') -WorkingDirectory $repo -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $root 'fixture.stdout.log') -RedirectStandardError (Join-Path $root 'fixture.stderr.log')
$pids+=@{variant='fixture';pid=$p.Id}
Write-PlatformJson (Join-Path $root 'processes.json') $pids
$token=$null
'Local OLD control=17100 Web=17101; FIXED control=17110 Web=17111. Temporary fixture credentials only.'
