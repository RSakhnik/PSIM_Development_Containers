[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $LicenseFile,
    [Parameter(Mandatory = $true)][string] $ConfigurationFile,
    [Parameter(Mandatory = $true)][Alias('BaseDomain')][ValidatePattern('^[A-Za-z0-9.-]+$')][string] $PublicHost,
    [ValidateSet('Host', 'Container')][string] $ProxyTopology = 'Host',
    [string] $ListenAddress,
    [ValidatePattern('^[A-Za-z0-9_.-]+$')][string] $ProxyContainerName,
    [ValidateRange(1, 65535)][int] $ApiPort = 17070,
    [ValidateSet('https')][string] $PublicScheme = 'https',
    [ValidateRange(1, 65535)][int] $ControlPublicPort = 17443,
    [ValidateRange(1, 65535)][int] $WebPublicPortStart = 18000,
    [ValidateRange(1, 65535)][int] $WebPublicPortEnd = 18049,
    [ValidateRange(1, 65535)][int] $AdminPublicPortStart = 19000,
    [ValidateRange(1, 65535)][int] $AdminPublicPortEnd = 19049,
    [switch] $DisableMemoryAdmission,
    [PSCredential] $LegacyServiceCredential,
    [PSCredential] $AdminCredential,
    [PSCredential] $BimCredential,
    [string] $ApiTokenFile,
    [string] $ServiceName = 'PilotEnvironmentApi',
    [switch] $ForceReconfigure,
    [switch] $RemoveSchemaV3Environments,
    [switch] $ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ps-compat.ps1')
if (-not (Test-PilotWindowsHost)) { throw 'Deployment supports Windows only.' }
if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'Run deployment in Windows PowerShell 5.1 or newer.' }
$root = Split-Path -Parent $PSScriptRoot
$PublicHost = $PublicHost.Trim().TrimEnd('.')
if ($WebPublicPortEnd -lt $WebPublicPortStart -or $AdminPublicPortEnd -lt $AdminPublicPortStart) { throw 'Public port ranges are invalid.' }
if (($WebPublicPortEnd - $WebPublicPortStart) -ne ($AdminPublicPortEnd - $AdminPublicPortStart)) { throw 'Web and myAdmin public port ranges must have equal size.' }
$allPublicPorts = @($ControlPublicPort) + @($WebPublicPortStart..$WebPublicPortEnd) + @($AdminPublicPortStart..$AdminPublicPortEnd)
if (@($allPublicPorts | Group-Object | Where-Object Count -gt 1).Count -gt 0) { throw 'Control, Web and myAdmin public ports must not overlap.' }
if ([string]::IsNullOrWhiteSpace($ListenAddress)) {
    $ListenAddress = '127.0.0.1'
}
if ($ListenAddress -eq '0.0.0.0' -or $ListenAddress -eq '*') { throw 'A wildcard API bind is forbidden; specify loopback or a dedicated private host address.' }
$parsedAddress = [Net.IPAddress]::None
if (-not [Net.IPAddress]::TryParse($ListenAddress, [ref]$parsedAddress)) { throw 'ListenAddress must be an IPv4 or IPv6 address.' }
if ($ProxyTopology -eq 'Host' -and -not [Net.IPAddress]::IsLoopback($parsedAddress)) { throw 'Host proxy topology must bind the API to loopback.' }
$listenUrl = if ($parsedAddress.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) { "http://[$ListenAddress]:$ApiPort" } else { "http://${ListenAddress}:$ApiPort" }
$controlUrl = "https://${PublicHost}:$ControlPublicPort"
$proxyUpstream = 'http://127.0.0.1:' + $ApiPort
if ($ProxyTopology -eq 'Container') {
    $dockerOs = (& docker info --format '{{.OperatingSystem}}' 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Docker Engine is unavailable.' }
    if ([Net.IPAddress]::IsLoopback($parsedAddress) -and $dockerOs -notmatch 'Docker Desktop') {
        throw 'Loopback container access is supported here for Docker Desktop only. Specify a reachable host -ListenAddress for another Docker installation.'
    }
    $proxyUpstream = if ([Net.IPAddress]::IsLoopback($parsedAddress)) { "http://host.docker.internal:$ApiPort" } else { $listenUrl }
    if (-not $ProxyContainerName) {
        $containers = @(& docker ps --format '{{json .}}' | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.Image -match 'nginx' -or $_.Names -match 'nginx' })
        if ($LASTEXITCODE -ne 0 -or $containers.Count -ne 1) { throw 'Specify -ProxyContainerName with the running nginx container name; auto-detection is ambiguous or unavailable.' }
        $ProxyContainerName = [string]$containers[0].Names
    }
    $proxyRunning = (& docker inspect --format '{{.State.Running}}' $ProxyContainerName | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $proxyRunning -ne 'true') { throw 'Proxy container is not running.' }
    & docker exec $ProxyContainerName curl --version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Proxy readiness check requires curl inside the nginx container. No installation changes have been made.' }
}

function Test-DeploymentProxy {
    if ($ProxyTopology -ne 'Container') { return }
    # Pass a discrete argument array; do not invoke a shell inside the container.
    $body = & docker exec $ProxyContainerName curl -fsS --connect-timeout 5 --max-time 60 -H "Host: ${PublicHost}:$ControlPublicPort" "$proxyUpstream/health/ready" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "API installed, but nginx-to-API readiness failed. Upstream: $proxyUpstream. Check proxy routing/firewall and curl availability in the container. Deployment is not complete."
    }
    try { $ready = ($body -join "`n") | ConvertFrom-Json } catch { throw 'Proxy readiness returned invalid JSON.' }
    if ($ready.status -ne 'ready') { throw 'Proxy cannot confirm Docker-ready API.' }
}


$legacyInstances = @()
$instancesRoot = Join-Path $root '.pilot-instances'
if (Test-Path -LiteralPath $instancesRoot) {
    $legacyInstances = @(Get-ChildItem -LiteralPath $instancesRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $configPath = Join-Path $_.FullName 'instance.json'
        if (Test-Path -LiteralPath $configPath) {
            try { $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json; if ([int]$config.schemaVersion -eq 3) { [pscustomobject]@{ path=$_.FullName; config=$config } } } catch { }
        }
    })
}
if ($legacyInstances.Count -gt 0 -and -not $RemoveSchemaV3Environments) {
    $names = @($legacyInstances | ForEach-Object { $_.config.name }) -join ', '
    throw "Schema v3 environments must be removed for port routing: $names. Repeat with -RemoveSchemaV3Environments; their data will not be backed up."
}

$manifestPath = Join-Path $root 'deployment-manifest.json'
if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($entry in $manifest.files) {
        $path = Join-Path $root ([string]$entry.path).Replace('/', '\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Deployment package is incomplete: $($entry.path)" }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne [string]$entry.sha256) { throw "Deployment package hash mismatch: $($entry.path)" }
    }
}

$preflightJson = & (Join-Path $PSScriptRoot 'test-server-prerequisites.ps1') `
    -LicenseFile $LicenseFile -ConfigurationFile $ConfigurationFile -ApiPort $ApiPort -ServiceName $ServiceName -Json -NoFail
$preflight = $preflightJson | ConvertFrom-Json
if (-not $preflight.ready) {
    $details = @($preflight.checks | Where-Object { -not $_.ok -and $_.severity -eq 'error' } | ForEach-Object { "$($_.name): $($_.detail)" }) -join [Environment]::NewLine
    throw "Server preflight failed:$([Environment]::NewLine)$details"
}
if ($ValidateOnly) {
    [pscustomobject][ordered]@{ valid = $true; listenUrl = $listenUrl; controlUrl = $controlUrl; publicHost = $PublicHost; proxyTopology = $ProxyTopology; preflight = $preflight; legacyEnvironments = @($legacyInstances | ForEach-Object {$_.config.name}) } | ConvertTo-Json -Depth 8
    return
}

if ($legacyInstances.Count -gt 0) {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    foreach ($legacy in $legacyInstances) {
        $config = $legacy.config
        & docker compose --project-name ([string]$config.composeProject) --file (Join-Path $root 'docker-compose.yml') --env-file (Join-Path $legacy.path '.env') --profile ([string]$config.mode) down --remove-orphans 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Could not remove legacy Docker stack '$($config.name)'." }
        $resolved = [IO.Path]::GetFullPath($legacy.path)
        $expectedRoot = [IO.Path]::GetFullPath($instancesRoot) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolved.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe legacy path: $resolved" }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

if (-not $AdminCredential) { $AdminCredential = Get-Credential -UserName 'admin' -Message 'Pilot Server administrator credentials' }
if (-not $BimCredential) { $BimCredential = Get-Credential -UserName 'bimservice' -Message 'Pilot-BIM service credentials' }
$apiToken = $null
if (-not [string]::IsNullOrWhiteSpace($ApiTokenFile)) {
    $apiToken = (Get-Content -LiteralPath $ApiTokenFile -Raw -ErrorAction Stop).Trim()
    if ($apiToken.Length -lt 32) { throw 'API token file must contain at least 32 characters.' }
}

$configureParameters = @{
    LicenseFile = $LicenseFile
    ConfigurationFile = $ConfigurationFile
    PublicHost = $PublicHost
    ListenUrl = $listenUrl
    PublicScheme = $PublicScheme
    ControlPublicPort = $ControlPublicPort
    WebPublicPortStart = $WebPublicPortStart
    WebPublicPortEnd = $WebPublicPortEnd
    AdminPublicPortStart = $AdminPublicPortStart
    AdminPublicPortEnd = $AdminPublicPortEnd
    DisableMemoryAdmission = $DisableMemoryAdmission
    AdminLogin = $AdminCredential.UserName
    AdminPassword = $AdminCredential.Password
    BimLogin = $BimCredential.UserName
    BimPassword = $BimCredential.Password
    SuppressInstallHint = $true
}
if ($apiToken) { $configureParameters.ApiToken = $apiToken }
if ($ForceReconfigure) { $configureParameters.Force = $true }
& (Join-Path $PSScriptRoot 'configure-api.ps1') @configureParameters

$nginxConfigPath = Join-Path $root 'nginx-pilot-environment-ports.conf'
& (Join-Path $PSScriptRoot 'new-nginx-port-config.ps1') -PublicHost $PublicHost -ControlPublicPort $ControlPublicPort `
    -WebPublicPortStart $WebPublicPortStart -WebPublicPortEnd $WebPublicPortEnd `
    -AdminPublicPortStart $AdminPublicPortStart -AdminPublicPortEnd $AdminPublicPortEnd -Upstream $proxyUpstream -OutputFile $nginxConfigPath

$bundleManifest = Join-Path $root 'bundle-manifest.json'
if(Test-Path -LiteralPath $bundleManifest){
    & (Join-Path $PSScriptRoot 'update-platform.ps1') -Component all -Package $root -InstallRoot $root -ServiceName $ServiceName | Out-Host
    Test-DeploymentProxy
    $serviceInfo=Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
    [pscustomobject]@{serviceName=$ServiceName;serviceIdentity=$serviceInfo.StartName;serviceState=$serviceInfo.State;dockerReady=$true;proxyReady=($ProxyTopology -eq 'Container');upstream=$proxyUpstream;controlUrl=$controlUrl;nginxConfig=$nginxConfigPath}
    return
}

$packageService = Join-Path $root 'service'
$installParameters = @{ ServiceName = $ServiceName; Start = $true }
if ($LegacyServiceCredential) { $installParameters.LegacyServiceCredential = $LegacyServiceCredential }
if (Test-Path -LiteralPath (Join-Path $packageService 'PilotEnv.Api.exe')) { $installParameters.PackageServiceDirectory = $packageService }
$installOutput = @(& (Join-Path $PSScriptRoot 'install-api-service.ps1') @installParameters)
$installResult = $installOutput | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['serviceName'] } | Select-Object -Last 1
if (-not $installResult) { throw 'Service installer did not return a deployment result.' }
if (-not $installResult.dockerReady) { throw 'Windows Service started, but Docker readiness was not confirmed.' }

Test-DeploymentProxy
Write-Host "Deployment completed as '$($installResult.identity)'. Control URL: $controlUrl. Install nginx fragment: $nginxConfigPath" -ForegroundColor Green
[pscustomobject][ordered]@{
    serviceName = $installResult.serviceName
    serviceIdentity = $installResult.identity
    serviceState = $installResult.state
    dockerReady = [bool]$installResult.dockerReady
    proxyReady = ($ProxyTopology -eq 'Container')
    upstream = $proxyUpstream
    publicHost = $PublicHost
    controlUrl = $controlUrl
    webPublicPorts = "$WebPublicPortStart-$WebPublicPortEnd"
    adminPublicPorts = "$AdminPublicPortStart-$AdminPublicPortEnd"
    nginxConfig = $nginxConfigPath
    proxyTopology = $ProxyTopology
}

