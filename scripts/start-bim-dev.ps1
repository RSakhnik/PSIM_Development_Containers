[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,39}$')]
    [string] $Name,
    [string] $LicenseFile,
    [string] $ConfigurationFile,
    [string] $AdminLogin = 'pilotadmin',
    [string] $BimLogin = 'bimservice',
    [ValidateRange(0, 65535)] [int] $ServerPort,
    [ValidateRange(0, 65535)] [int] $WebPort,
    [ValidateRange(0, 65535)] [int] $AdminPort
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$manager = Join-Path $PSScriptRoot 'pilot-env.ps1'
$instanceConfig = Join-Path $repositoryRoot ".pilot-instances\$Name\instance.json"

if (Test-Path -LiteralPath $instanceConfig) {
    $config = Get-Content -LiteralPath $instanceConfig -Raw | ConvertFrom-Json
    if ($config.schemaVersion -ne 4 -or $config.mode -ne 'bim-dev') {
        throw "Стенд '$Name' имеет схему/режим '$($config.schemaVersion)/$($config.mode)', ожидался 4/bim-dev."
    }
    & $manager Start $Name
    exit $LASTEXITCODE
}

if ([string]::IsNullOrWhiteSpace($LicenseFile)) { throw 'При создании BIM-dev стенда обязателен -LicenseFile. Для последующих запусков он не нужен.' }

$adminPassword = Read-Host "Одноразовая настройка: пароль администратора Pilot Server '$AdminLogin'" -AsSecureString
$bimPassword = Read-Host "Одноразовая настройка: пароль сервисного пользователя BIM '$BimLogin'" -AsSecureString
if ($adminPassword.Length -eq 0 -or $bimPassword.Length -eq 0) { throw 'Пароли первоначальной настройки не могут быть пустыми.' }

$releaseLock = Join-Path $repositoryRoot '.pilot-runtime\last-known-good.json'
if (-not (Test-Path -LiteralPath $releaseLock)) {
    if ([string]::IsNullOrWhiteSpace($ConfigurationFile)) {
        $candidate = Get-ChildItem -LiteralPath $repositoryRoot -Recurse -Filter 'configuration_pilot-bim_ru.pilotcfx' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike '*\.pilot-instances\*' } | Select-Object -First 1
        if ($candidate) { $ConfigurationFile = $candidate.FullName }
    }
    if ([string]::IsNullOrWhiteSpace($ConfigurationFile)) { throw 'Первый запуск требует официальный configuration_pilot-bim_ru.pilotcfx.' }
    $previousEnvironment = @{}
    foreach ($key in @('PILOT_LICENSE_FILE','PILOT_CONFIGURATION_FILE','PILOT_ADMIN_LOGIN','PILOT_ADMIN_PASSWORD','PILOT_BIM_LOGIN','PILOT_BIM_PASSWORD')) {
        $previousEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
    }
    $adminPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($adminPassword)
    $bimPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($bimPassword)
    try {
        [Environment]::SetEnvironmentVariable('PILOT_LICENSE_FILE', (Resolve-Path -LiteralPath $LicenseFile).Path)
        [Environment]::SetEnvironmentVariable('PILOT_CONFIGURATION_FILE', (Resolve-Path -LiteralPath $ConfigurationFile).Path)
        [Environment]::SetEnvironmentVariable('PILOT_ADMIN_LOGIN', $AdminLogin)
        [Environment]::SetEnvironmentVariable('PILOT_ADMIN_PASSWORD', [Runtime.InteropServices.Marshal]::PtrToStringBSTR($adminPointer))
        [Environment]::SetEnvironmentVariable('PILOT_BIM_LOGIN', $BimLogin)
        [Environment]::SetEnvironmentVariable('PILOT_BIM_PASSWORD', [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bimPointer))
        & $manager RefreshRelease
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($adminPointer)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bimPointer)
        foreach ($key in $previousEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $previousEnvironment[$key]) }
    }
}

& $manager New $Name -Mode bim-dev -DatabaseName pilot-bim_ru -LicenseFile $LicenseFile `
    -ServerPort $ServerPort -WebPort $WebPort -AdminPort $AdminPort `
    -AdminLogin $AdminLogin -AdminPassword $adminPassword -BimLogin $BimLogin -BimPassword $bimPassword -Start
exit $LASTEXITCODE
