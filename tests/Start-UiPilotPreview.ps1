$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'scripts\platform-package.ps1')
$root=Join-Path $repo 'test-results\ui-pilot-preview'
$original='C:\Users\roman\Documents\ChatGPT\Изолированная среда разработки для веб ПСИМ'
[void](New-Item -ItemType Directory -Path (Join-Path $root '.pilot-runtime\api') -Force)
if(-not(Test-Path (Join-Path $root '.pilot-instances'))){[void](New-Item -ItemType Junction -Path (Join-Path $root '.pilot-instances') -Target (Join-Path $original '.pilot-instances'))}
if(-not(Test-Path (Join-Path $root '.pilot-templates'))){[void](New-Item -ItemType Junction -Path (Join-Path $root '.pilot-templates') -Target (Join-Path $original '.pilot-templates'))}
Copy-Item -LiteralPath (Join-Path $original '.pilot-runtime\last-known-good.json') -Destination (Join-Path $root '.pilot-runtime') -Force
Copy-Item -LiteralPath (Join-Path $original '.pilot-runtime\api\secrets.json') -Destination (Join-Path $root '.pilot-runtime\api') -Force
Copy-Item -LiteralPath (Join-Path $repo 'scripts') -Destination $root -Recurse -Force
Copy-Item -LiteralPath (Join-Path $repo 'docker-compose.yml'),(Join-Path $repo 'ingress') -Destination $root -Recurse -Force
[void](New-Item -ItemType Directory -Path (Join-Path $root 'src\PilotEnv.Web') -Force)
& (Join-Path $repo 'scripts\build-web-ui.ps1') -OutputDirectory (Join-Path $root 'src\PilotEnv.Web')
$license=Get-ChildItem (Join-Path $original '.pilot-instances\port-test-a\license') -File -Filter '*.pilotlic' | Select-Object -First 1
Write-PlatformJson (Join-Path $root '.pilot-runtime\api\hostsettings.json') @{PilotEnv=@{RepositoryRoot=$root;ListenUrl='http://127.0.0.1:17075';PublicHost='127.0.0.1';PublicScheme='http';ControlPublicPort=17075;PowerShellExecutable=(Get-PilotWindowsPowerShellPath);LicenseFile=$license.FullName;ConfigurationFile=(Join-Path $original '.pilot-runtime\api\configuration_pilot-bim_ru.pilotcfx')}}
$token=[Convert]::ToBase64String((New-PilotRandomBytes -Count 32))
$salt=New-PilotRandomBytes -Count 32
$derive=New-Object Security.Cryptography.Rfc2898DeriveBytes($token,$salt,210000,[Security.Cryptography.HashAlgorithmName]::SHA256)
try{$hash=$derive.GetBytes(32)}finally{$derive.Dispose()}
$secretPath=Join-Path $root '.pilot-runtime\api\secrets.json'
$secrets=Get-Content $secretPath -Raw | ConvertFrom-Json
$secrets.tokenHash="v1.210000.$([Convert]::ToBase64String($salt)).$([Convert]::ToBase64String($hash))"
Write-PlatformJson $secretPath $secrets
[IO.File]::WriteAllText((Join-Path $root 'preview-token.txt'),$token)
$token=$null
$exe=Join-Path $repo 'src\PilotEnv.Api\bin\Debug\net9.0\PilotEnv.Api.exe'
$process=Start-Process -FilePath $exe -ArgumentList @('--contentRoot',('"'+$root+'"')) -WorkingDirectory $root -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $root 'api.stdout.log') -RedirectStandardError (Join-Path $root 'api.stderr.log')
$process.Id | Set-Content (Join-Path $root 'api.pid')
[pscustomobject]@{url='http://127.0.0.1:17075';processId=$process.Id;root=$root}
