[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [PSCredential] $LegacyServiceCredential,
    [string] $ServiceName = 'PilotEnvironmentApi',
    [string] $PackageServiceDirectory,
    [ValidateRange(10, 300)][int] $HealthTimeoutSeconds = 60,
    [switch] $Start
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ps-compat.ps1')
if (-not (Test-PilotWindowsHost)) { throw 'The Pilot Environment API service supports Windows only.' }
if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'Run this script in an elevated Windows PowerShell 5.1 console.' }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdministrator -and -not $WhatIfPreference) { throw 'Administrator privileges are required.' }

$root = Split-Path -Parent $PSScriptRoot
if(Test-Path -LiteralPath (Join-Path $root 'bundle-manifest.json')){
    if($WhatIfPreference){Write-Host "Would bootstrap component-based deployment as LocalSystem (existing identity preserved).";return}
    & (Join-Path $PSScriptRoot 'update-platform.ps1') -Component all -Package $root -InstallRoot $root -ServiceName $ServiceName
    return
}
$runtime = Join-Path $root '.pilot-runtime\api'
$packagedServiceDirectory = Join-Path $root 'service'
if ([string]::IsNullOrWhiteSpace($PackageServiceDirectory) -and (Test-Path -LiteralPath (Join-Path $packagedServiceDirectory 'PilotEnv.Api.exe') -PathType Leaf)) {
    $PackageServiceDirectory = $packagedServiceDirectory
}
$secretPath = Join-Path $runtime 'secrets.json'
$settingsPath = Join-Path $runtime 'hostsettings.json'
if (-not (Test-Path -LiteralPath $secretPath)) { throw 'Run configure-api.ps1 before installing the service.' }
if (-not (Test-Path -LiteralPath $settingsPath)) { throw 'API hostsettings.json is missing.' }
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
$listenUri = [Uri]$settings.PilotEnv.ListenUrl
if ($listenUri.Scheme -ne 'http') { throw 'The local API upstream must use HTTP; TLS terminates at the external reverse proxy.' }

$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$wasRunning = $existing -and $existing.Status -eq 'Running'
$existingServiceInfo = if ($existing) { Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" } else { $null }
$existingIdentity = if ($existingServiceInfo) { [string]$existingServiceInfo.StartName } else { $null }
$existingUsesLocalSystem = $existingIdentity -in @('LocalSystem', 'NT AUTHORITY\SYSTEM')
if ($existing -and $LegacyServiceCredential -and $LegacyServiceCredential.UserName -ine $existingIdentity) {
    throw "Existing service uses '$existingIdentity'. Changing a legacy service identity during update is not supported."
}
$useLegacyIdentity = [bool]$LegacyServiceCredential -or ($existing -and -not $existingUsesLocalSystem)
$plannedIdentity = if ($LegacyServiceCredential) { $LegacyServiceCredential.UserName } elseif ($useLegacyIdentity) { $existingIdentity } else { 'LocalSystem' }
if ($existing -and -not $existingUsesLocalSystem -and -not $LegacyServiceCredential) {
    Write-Warning "Existing service '$ServiceName' uses legacy identity '$existingIdentity'; it will be preserved. New installations default to LocalSystem."
}
if ($WhatIfPreference) {
    if ([string]::IsNullOrWhiteSpace($PackageServiceDirectory)) {
        $project = Join-Path $root 'src\PilotEnv.Api\PilotEnv.Api.csproj'
        if (-not (Test-Path -LiteralPath $project -PathType Leaf)) { throw 'Source project is missing; pass -PackageServiceDirectory.' }
    }
    else {
        $source = (Resolve-Path -LiteralPath $PackageServiceDirectory -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath (Join-Path $source 'PilotEnv.Api.exe') -PathType Leaf)) { throw 'PilotEnv.Api.exe is missing from the package.' }
    }
    Write-Host "Validation succeeded. Would deploy service '$ServiceName' using '$plannedIdentity'."
    [pscustomobject][ordered]@{ serviceName = $ServiceName; identity = $plannedIdentity; state = 'what-if'; dockerReady = $null }
    return
}

$deployRoot = Join-Path $runtime 'deploy'
$staging = Join-Path $deployRoot ([Guid]::NewGuid().ToString('n'))
$publish = Join-Path $runtime 'service'
$backupRoot = Join-Path $runtime 'service-backups'
[void](New-Item -ItemType Directory -Path $staging -Force)
[void](New-Item -ItemType Directory -Path $backupRoot -Force)
$backup = $null
$swapped = $false
$createdService = $false

try {
    if ([string]::IsNullOrWhiteSpace($PackageServiceDirectory)) {
        $project = Join-Path $root 'src\PilotEnv.Api\PilotEnv.Api.csproj'
        if (-not (Test-Path -LiteralPath $project)) { throw 'Source project is missing; pass -PackageServiceDirectory.' }
        & dotnet restore $project -r win-x64 --disable-parallel --nologo
        if ($LASTEXITCODE -ne 0) { throw 'Runtime-specific dotnet restore failed.' }
        & dotnet publish $project -c Release -r win-x64 --self-contained true --no-restore --nologo -o $staging
        if ($LASTEXITCODE -ne 0) { throw 'Self-contained dotnet publish failed.' }
    }
    else {
        $source = (Resolve-Path -LiteralPath $PackageServiceDirectory -ErrorAction Stop).Path
        Copy-Item -Path (Join-Path $source '*') -Destination $staging -Recurse -Force
    }
    $executable = Join-Path $staging 'PilotEnv.Api.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'PilotEnv.Api.exe is missing from the staged deployment.' }

    if ($wasRunning -and $PSCmdlet.ShouldProcess($ServiceName, 'Stop service for atomic update')) {
        Stop-Service -Name $ServiceName -Force
        (Get-Service -Name $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    if (Test-Path -LiteralPath $publish) {
        $backup = Join-Path $backupRoot ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
        if ($PSCmdlet.ShouldProcess($publish, "Move current service to $backup")) { Move-Item -LiteralPath $publish -Destination $backup }
    }
    if ($PSCmdlet.ShouldProcess($staging, "Activate service in $publish")) {
        Move-Item -LiteralPath $staging -Destination $publish
        $swapped = $true
    }

    $managedDirectories = @($runtime, (Join-Path $root '.pilot-instances'), (Join-Path $root '.pilot-templates'))
    foreach ($directory in $managedDirectories) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
        $aclIdentity = if ($useLegacyIdentity) { $plannedIdentity } else { '*S-1-5-18' }
        & icacls.exe $directory /grant:r "${aclIdentity}:(OI)(CI)M" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not grant filesystem permissions to '$plannedIdentity' for '$directory'." }
    }

    $activeExecutable = Join-Path $publish 'PilotEnv.Api.exe'
    $binaryPath = '"{0}"' -f $activeExecutable
    if (-not $existing -and $PSCmdlet.ShouldProcess($ServiceName, 'Install Windows Service')) {
        $newServiceParameters = @{
            Name = $ServiceName
            BinaryPathName = $binaryPath
            DisplayName = 'Pilot Environment API'
            Description = 'Control API and reverse proxy for isolated Pilot-BIM development environments.'
            StartupType = 'Automatic'
        }
        if ($LegacyServiceCredential) { $newServiceParameters.Credential = $LegacyServiceCredential }
        New-Service @newServiceParameters | Out-Null
        $createdService = $true
        if (-not $LegacyServiceCredential) {
            & sc.exe config $ServiceName obj= LocalSystem | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not configure the Windows Service to use LocalSystem.' }
        }
        $existing = Get-Service -Name $ServiceName
    }
    elseif ($existing -and $PSCmdlet.ShouldProcess($ServiceName, 'Update Windows Service executable path')) {
        Set-PilotServiceCommand -Name $ServiceName -BinaryPath $binaryPath
    }
    & sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/15000/restart/30000 | Out-Null

    if (($Start -or $wasRunning) -and $PSCmdlet.ShouldProcess($ServiceName, 'Start and verify Windows Service')) {
        Start-Service -Name $ServiceName
        (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
        $deadline = [DateTime]::UtcNow.AddSeconds($HealthTimeoutSeconds)
        if (-not $settings.PilotEnv.PSObject.Properties['PublicHost'] -or -not $settings.PilotEnv.PSObject.Properties['ControlPublicPort']) {
            throw 'Port-routing settings are missing. Run deploy-server.ps1 to migrate the API configuration.'
        }
        $controlHost = "$([string]$settings.PilotEnv.PublicHost):$([int]$settings.PilotEnv.ControlPublicPort)"
        $healthUri = "$($listenUri.GetLeftPart([UriPartial]::Authority))/health/ready"
        $healthy = $false
        do {
            try {
                $response = Invoke-WebRequest -Uri $healthUri -Headers @{ Host = $controlHost; 'X-Forwarded-Host' = $controlHost; 'X-Forwarded-Proto' = 'https' } -UseBasicParsing -TimeoutSec 5
                $healthy = $response.StatusCode -eq 200
            }
            catch { Start-Sleep -Seconds 2 }
        } while (-not $healthy -and [DateTime]::UtcNow -lt $deadline)
        if (-not $healthy) { throw "Service did not pass health check at $healthUri." }
    }

    Get-ChildItem -LiteralPath $backupRoot -Directory | Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 3 | Remove-Item -Recurse -Force
    $installedInfo = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
    $installedIdentity = [string]$installedInfo.StartName
    Write-Host "Service '$ServiceName' deployed successfully as '$installedIdentity'. Upstream: $($settings.PilotEnv.ListenUrl)" -ForegroundColor Green
    [pscustomobject][ordered]@{
        serviceName = $ServiceName
        identity = $installedIdentity
        state = [string](Get-Service -Name $ServiceName).Status
        dockerReady = if ($Start -or $wasRunning) { $healthy } else { $null }
        upstream = [string]$settings.PilotEnv.ListenUrl
    }
}
catch {
    if ($swapped -and $backup -and (Test-Path -LiteralPath $backup)) {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $publish) { Remove-Item -LiteralPath $publish -Recurse -Force }
        Move-Item -LiteralPath $backup -Destination $publish
        if ($wasRunning) { Start-Service -Name $ServiceName -ErrorAction SilentlyContinue }
    }
    elseif ($createdService) {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        & sc.exe delete $ServiceName | Out-Null
        if (Test-Path -LiteralPath $publish) { Remove-Item -LiteralPath $publish -Recurse -Force }
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}

