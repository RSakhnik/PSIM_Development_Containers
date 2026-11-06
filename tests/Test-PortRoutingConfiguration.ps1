[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([IO.Path]::GetTempPath()) "pilot-nginx-$([Guid]::NewGuid().ToString('N')).conf"
try {
    & (Join-Path $root 'scripts\new-nginx-port-config.ps1') -PublicHost '360pilot.ru' -OutputFile $temp | Out-Null
    $nginx = Get-Content -LiteralPath $temp -Raw
    foreach ($expected in @(
        'listen 17443 ssl;', 'listen 18000 ssl;', 'listen 18049 ssl;',
        'listen 19000 ssl;', 'listen 19049 ssl;',
        'proxy_pass http://host.docker.internal:17070;',
        'proxy_set_header Host $host:$server_port;',
        'proxy_set_header X-Forwarded-Host $host:$server_port;',
        'proxy_set_header Upgrade $http_upgrade;')) {
        if (-not $nginx.Contains($expected)) { throw "Generated nginx fragment is missing: $expected" }
    }
    $listenCount = ([regex]::Matches($nginx, '(?m)^listen \d+ ssl;\r?$')).Count
    if ($listenCount -ne 101) { throw "Expected 101 public listen directives, got $listenCount." }

    $manager = Get-Content -LiteralPath (Join-Path $root 'scripts\pilot-env.ps1') -Raw
    if ($manager -notmatch 'schemaVersion\s*=\s*4') { throw 'The environment engine does not write schema v4.' }
    if ($manager -notmatch 'publicPorts\s*=') { throw 'The environment engine does not persist public ports.' }
    if ($manager -notmatch 'PILOT_DISABLE_MEMORY_ADMISSION') { throw 'The temporary memory-admission override is not wired into the engine.' }

    $deploy = Get-Content -LiteralPath (Join-Path $root 'scripts\deploy-server.ps1') -Raw
    if ($deploy -notmatch '\[switch\]\s*\$DisableMemoryAdmission') { throw 'Deployment does not expose the temporary memory-admission override.' }

    $panel = Get-Content -LiteralPath (Join-Path $root 'src\PilotEnv.Web\app.js') -Raw
    if ($panel -notmatch "action === 'restart-web'[\s\S]+body = \{ cascade:false \}") { throw 'Restart Web must send an explicit JSON body so ASP.NET maps the endpoint.' }

    $compose = Get-Content -LiteralPath (Join-Path $root 'docker-compose.yml') -Raw
    if ($compose -notmatch '127\.0\.0\.1:\$\{PILOT_WEB_PORT\}') { throw 'Pilot Web is not restricted to loopback.' }
    if ($compose -notmatch '127\.0\.0\.1:\$\{PILOT_ADMIN_PORT\}') { throw 'myAdmin is not restricted to loopback.' }
    Write-Host 'Port routing static contract: OK' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
