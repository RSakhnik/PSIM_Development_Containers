[CmdletBinding()]
param(
    [string] $ServiceName = 'PilotEnvironmentApi',
    [string] $ApiTokenFile,
    [string] $ExternalControlUrl,
    [ValidatePattern('^[A-Za-z0-9_.-]+$')][string] $ProxyContainerName,
    [string] $ResultFile,
    [switch] $AllowLegacyServiceIdentity,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ps-compat.ps1')
$root = Split-Path -Parent $PSScriptRoot
$settingsPath = Join-Path $root '.pilot-runtime\api\hostsettings.json'
if (-not (Test-Path -LiteralPath $settingsPath)) { throw 'API is not configured.' }
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
$listen = [Uri]$settings.PilotEnv.ListenUrl
$publicHost = [string]$settings.PilotEnv.PublicHost
$controlPublicPort = [int]$settings.PilotEnv.ControlPublicPort
$controlHost = "${publicHost}:$controlPublicPort"
$localBase = $listen.GetLeftPart([UriPartial]::Authority)
$checks = [Collections.Generic.List[object]]::new()
function Check([string] $Name, [scriptblock] $Action) {
    try { $detail = & $Action; $checks.Add([pscustomobject]@{ name = $Name; ok = $true; detail = [string]$detail }) }
    catch { $checks.Add([pscustomobject]@{ name = $Name; ok = $false; detail = $_.Exception.Message }) }
}

Check 'windows-service' {
    $service = Get-Service -Name $ServiceName -ErrorAction Stop
    if ($service.Status -ne 'Running') { throw "Service state: $($service.Status)" }
    'Running'
}
Check 'service-identity' {
    $service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
    $identity = [string]$service.StartName
    if (-not $AllowLegacyServiceIdentity -and $identity -notin @('LocalSystem', 'NT AUTHORITY\SYSTEM')) { throw "Unexpected identity: $identity" }
    $identity
}
Check 'automatic-start' {
    $service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
    if ($service.StartMode -ne 'Auto') { throw "StartMode: $($service.StartMode)" }
    'Automatic'
}
Check 'recovery-policy' {
    $output = @(& sc.exe qfailure $ServiceName 2>&1) -join [Environment]::NewLine
    if ($output -notmatch '(?i)RESTART|перезапуск') { throw "Restart recovery actions are not configured: $output" }
    'restart actions configured'
}
Check 'localsystem-acl' {
    if ($AllowLegacyServiceIdentity) { return 'skipped for legacy identity' }
    $sid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    foreach ($path in @((Join-Path $root '.pilot-runtime\api'), (Join-Path $root '.pilot-instances'), (Join-Path $root '.pilot-templates'))) {
        $rules = (Get-Acl -LiteralPath $path).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
        $rule = $rules | Where-Object { $_.IdentityReference -eq $sid -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Modify) } | Select-Object -First 1
        if (-not $rule) { throw "LocalSystem Modify ACL is missing: $path" }
    }
    'runtime, instances, templates'
}
Check 'health-live' {
    $response = Invoke-RestMethod -Uri "$localBase/health/live" -Headers @{ Host = $controlHost; 'X-Forwarded-Host' = $controlHost; 'X-Forwarded-Proto' = 'https' } -TimeoutSec 10
    if ($response.status -ne 'live') { throw 'Unexpected live response.' }
    'live'
}
Check 'health-ready' {
    $response = Invoke-RestMethod -Uri "$localBase/health/ready" -Headers @{ Host = $controlHost; 'X-Forwarded-Host' = $controlHost; 'X-Forwarded-Proto' = 'https' } -TimeoutSec 60
    if ($response.status -ne 'ready') { throw 'API is not ready.' }
    'ready'
}
if (-not [string]::IsNullOrWhiteSpace($ApiTokenFile)) {
    Check 'authenticated-capacity' {
        $token = (Get-Content -LiteralPath $ApiTokenFile -Raw).Trim()
        $response = Invoke-RestMethod -Uri "$localBase/api/v1/capacity" -Headers @{ Host = $controlHost; 'X-Forwarded-Host' = $controlHost; 'X-Forwarded-Proto' = 'https'; Authorization = "Bearer $token" } -TimeoutSec 60
        "canStart=$($response.canStart); availableSlots=$($response.availableSlots)"
    }
    Check 'authenticated-environments' {
        $token = (Get-Content -LiteralPath $ApiTokenFile -Raw).Trim()
        $response = @(Invoke-RestMethod -Uri "$localBase/api/v1/environments" -Headers @{ Host = $controlHost; 'X-Forwarded-Host' = $controlHost; 'X-Forwarded-Proto' = 'https'; Authorization = "Bearer $token" } -TimeoutSec 90)
        "environments=$($response.Count)"
    }
}
if (-not [string]::IsNullOrWhiteSpace($ExternalControlUrl)) {
    Check 'external-proxy' {
        $response = Invoke-WebRequest -Uri "$($ExternalControlUrl.TrimEnd('/'))/health/live" -TimeoutSec 15
        "HTTP $($response.StatusCode)"
    }
}
if (-not [string]::IsNullOrWhiteSpace($ProxyContainerName)) {
    Check 'container-proxy-upstream' {
        $probe = if ($listen.IsLoopback) { "http://host.docker.internal:$($listen.Port)/health/live" } else { "$localBase/health/live" }
        $shell = "if command -v curl >/dev/null 2>&1; then curl -fsS --connect-timeout 5 --max-time 15 -H 'Host: $controlHost' -H 'X-Forwarded-Host: $controlHost' -H 'X-Forwarded-Proto: https' '$probe'; else wget -T 15 -qO- --header='Host: $controlHost' --header='X-Forwarded-Host: $controlHost' --header='X-Forwarded-Proto: https' '$probe'; fi"
        $output = @(& docker exec $ProxyContainerName sh -c $shell 2>&1) -join [Environment]::NewLine
        if ($LASTEXITCODE -ne 0 -or $output -notmatch '"status"\s*:\s*"live"') { throw "Proxy container cannot reach API: $output" }
        'host.docker.internal upstream reachable'
    }
}
$result = [pscustomobject][ordered]@{ healthy = @($checks | Where-Object { -not $_.ok }).Count -eq 0; checks = $checks }
$jsonResult = $result | ConvertTo-Json -Depth 5 -Compress
if (-not [string]::IsNullOrWhiteSpace($ResultFile)) { Write-PilotUtf8NoBom -LiteralPath $ResultFile -Text $jsonResult }
if ($Json) { $jsonResult } else { $checks | Format-Table -AutoSize; Write-Host "Healthy: $($result.healthy)" }
if (-not $result.healthy) { exit 3 }

