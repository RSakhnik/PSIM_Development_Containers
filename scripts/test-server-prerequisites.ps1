[CmdletBinding()]
param(
    [string] $LicenseFile,
    [string] $ConfigurationFile,
    [ValidateRange(1, 65535)][int] $ApiPort = 17070,
    [ValidateRange(1, 1024)][double] $MinimumDockerMemoryGiB = 16,
    [ValidateRange(1, 10240)][double] $MinimumFreeDiskGiB = 20,
    [string] $ServiceName = 'PilotEnvironmentApi',
    [switch] $SkipElevationCheck,
    [switch] $NoFail,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ps-compat.ps1')
$LASTEXITCODE = 0
$checks = [Collections.Generic.List[object]]::new()

function Add-Check([string] $Name, [bool] $Ok, [string] $Detail, [string] $Severity = 'error') {
    $checks.Add([pscustomobject][ordered]@{ name = $Name; ok = $Ok; severity = $Severity; detail = $Detail })
}

$isAdministrator = $false
$isWindowsHost = Test-PilotWindowsHost
if ($isWindowsHost) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
Add-Check 'windows' $isWindowsHost $(if ($isWindowsHost) { 'Windows host detected.' } else { 'Only Windows hosts are supported.' })
$windowsPowerShellOk = $PSVersionTable.PSVersion.Major -ge 5
Add-Check 'windows-powershell' $windowsPowerShellOk "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))."
if (-not $SkipElevationCheck) { Add-Check 'administrator' $isAdministrator $(if ($isAdministrator) { 'Elevated process.' } else { 'Run deployment from an elevated Windows PowerShell 5.1 console.' }) }

$windowsPowerShell = if ($isWindowsHost) { Get-PilotWindowsPowerShellPath } else { $null }
Add-Check 'powershell-executable' ([bool]$windowsPowerShell) $(if ($windowsPowerShell) { $windowsPowerShell } else { 'Windows PowerShell executable is unavailable.' })
$docker = Enable-PilotDockerCompatibility
Add-Check 'docker-cli' ([bool]$docker) $(if ($docker) { $docker.Source } else { 'Docker CLI is not installed or not in PATH.' })

$dockerReady = $false
$dockerMemoryGiB = 0.0
if ($docker) {
    $serverVersion = (& docker info --format '{{.ServerVersion}}' 2>$null | Select-Object -First 1)
    $dockerReady = $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($serverVersion)
    Add-Check 'docker-engine' $dockerReady $(if ($dockerReady) { "Docker Engine $serverVersion." } else { 'Docker Engine is unavailable on the host.' })
    if ($dockerReady) {
        $osType = (& docker info --format '{{.OSType}}' 2>$null | Select-Object -First 1)
        Add-Check 'linux-containers' ($osType -eq 'linux') "Docker OSType: $osType."
        $rawMemory = (& docker info --format '{{.MemTotal}}' 2>$null | Select-Object -First 1)
        if ([double]::TryParse([string]$rawMemory, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$dockerMemoryGiB)) {
            $dockerMemoryGiB /= 1GB
        }
        Add-Check 'docker-memory' ($dockerMemoryGiB -ge $MinimumDockerMemoryGiB) ("Docker memory: {0:N2} GiB; required: {1:N2} GiB." -f $dockerMemoryGiB, $MinimumDockerMemoryGiB)
        & docker compose version *> $null
        Add-Check 'docker-compose' ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -eq 0) { 'docker compose is available.' } else { 'docker compose plugin is unavailable.' })
    }
}

$root = Split-Path -Parent $PSScriptRoot
$driveRoot = [IO.Path]::GetPathRoot($root)
$drive = Get-PSDrive -Name $driveRoot.TrimEnd('\').TrimEnd(':') -ErrorAction SilentlyContinue
$freeDiskGiB = if ($drive) { $drive.Free / 1GB } else { 0 }
Add-Check 'free-disk' ($freeDiskGiB -ge $MinimumFreeDiskGiB) ("Free disk: {0:N2} GiB; required: {1:N2} GiB." -f $freeDiskGiB, $MinimumFreeDiskGiB)

$existingService = if ($isWindowsHost) { Get-Service -Name $ServiceName -ErrorAction SilentlyContinue } else { $null }
$currentServiceIdentity = if ($existingService) { [string](Get-CimInstance Win32_Service -Filter "Name='$ServiceName'").StartName } else { $null }
$serviceUsesLocalSystem = -not $existingService -or $currentServiceIdentity -in @('LocalSystem', 'NT AUTHORITY\SYSTEM')
Add-Check 'service-identity' $serviceUsesLocalSystem $(if (-not $existingService) { 'New service will use LocalSystem.' } elseif ($serviceUsesLocalSystem) { 'Existing service uses LocalSystem.' } else { "Existing legacy identity '$currentServiceIdentity' will be preserved." }) $(if ($serviceUsesLocalSystem) { 'error' } else { 'warning' })
$listener = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object Port -eq $ApiPort | Select-Object -First 1
$portOk = -not $listener -or [bool]$existingService
Add-Check 'api-port' $portOk $(if (-not $listener) { "TCP $ApiPort is free." } elseif ($existingService) { "TCP $ApiPort is occupied; existing service '$ServiceName' will be updated." } else { "TCP $ApiPort is already occupied." })

if (-not [string]::IsNullOrWhiteSpace($LicenseFile)) {
    $licenseOk = Test-Path -LiteralPath $LicenseFile -PathType Leaf
    $licenseDetail = if ($licenseOk) { 'License file exists.' } else { 'License file is missing.' }
    if ($licenseOk) {
        try {
            $xml = [xml](Get-Content -LiteralPath $LicenseFile -Raw)
            $id = $xml.SelectSingleNode("//*[local-name()='license-id']")
            $signature = $xml.SelectSingleNode("//*[local-name()='Signature']")
            $products = @($xml.SelectNodes("//*[local-name()='product']"))
            $licenseOk = $id -and $signature -and (@($products | Where-Object { [int]$_.id -eq 90 -and [int]$_.workplaces -gt 0 }).Count -gt 0) -and (@($products | Where-Object { [int]$_.id -eq 91 -and [int]$_.workplaces -gt 0 }).Count -gt 0)
            $licenseDetail = if ($licenseOk) { 'License XML contains ID, signature and products 90/91.' } else { 'License XML does not contain all required fields.' }
        }
        catch { $licenseOk = $false; $licenseDetail = "License XML is invalid: $($_.Exception.Message)" }
    }
    Add-Check 'license' $licenseOk $licenseDetail
}

if (-not [string]::IsNullOrWhiteSpace($ConfigurationFile)) {
    $configurationOk = (Test-Path -LiteralPath $ConfigurationFile -PathType Leaf) -and ([IO.Path]::GetExtension($ConfigurationFile) -ieq '.pilotcfx')
    Add-Check 'pilot-configuration' $configurationOk $(if ($configurationOk) { 'Pilot BIM configuration exists.' } else { 'A readable .pilotcfx file is required.' })
}

$errors = @($checks | Where-Object { -not $_.ok -and $_.severity -eq 'error' })
$result = [pscustomobject][ordered]@{
    ready = $errors.Count -eq 0
    checkedAt = [DateTimeOffset]::UtcNow.ToString('o')
    expectedServiceIdentity = if ($existingService) { $currentServiceIdentity } else { 'LocalSystem' }
    checks = $checks
}
if ($Json) { $result | ConvertTo-Json -Depth 6 -Compress }
else { $checks | Format-Table name, ok, severity, detail -AutoSize; Write-Host "Ready: $($result.ready)" }
if (-not $result.ready -and -not $NoFail) { exit 2 }

