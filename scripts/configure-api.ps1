[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $LicenseFile,
    [Parameter(Mandatory = $true)][string] $ConfigurationFile,
    [Alias('BaseDomain')][string] $PublicHost = '360pilot.ru',
    [string] $ListenUrl = 'http://127.0.0.1:17070',
    [ValidateSet('http','https')][string] $PublicScheme = 'https',
    [ValidateRange(1,65535)][int] $ControlPublicPort = 17443,
    [ValidateRange(1,65535)][int] $WebPublicPortStart = 18000,
    [ValidateRange(1,65535)][int] $WebPublicPortEnd = 18049,
    [ValidateRange(1,65535)][int] $AdminPublicPortStart = 19000,
    [ValidateRange(1,65535)][int] $AdminPublicPortEnd = 19049,
    [switch] $DisableMemoryAdmission,
    [string] $PowerShellExecutable,
    [string] $ApiToken,
    [string] $AdminLogin = 'pilotadmin',
    [Security.SecureString] $AdminPassword,
    [string] $BimLogin = 'bimservice',
    [Security.SecureString] $BimPassword,
    [switch] $SuppressInstallHint,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ps-compat.ps1')
if (-not (Test-PilotWindowsHost)) { throw 'Первая версия API поддерживает только Windows.' }
if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'Требуется Windows PowerShell 5.1 или новее.' }
Add-Type -AssemblyName System.Security

$root = Split-Path -Parent $PSScriptRoot
$runtime = Join-Path $root '.pilot-runtime\api'
$runtimeAlreadyExisted = Test-Path -LiteralPath $runtime
$secretPath = Join-Path $runtime 'secrets.json'
if ((Test-Path -LiteralPath $secretPath) -and -not $Force) { throw "API уже настроен: $secretPath. Для ротации используйте -Force." }

$license = (Resolve-Path -LiteralPath $LicenseFile -ErrorAction Stop).Path
$configuration = (Resolve-Path -LiteralPath $ConfigurationFile -ErrorAction Stop).Path
if ([IO.Path]::GetExtension($configuration) -ine '.pilotcfx') { throw 'ConfigurationFile должен иметь расширение .pilotcfx.' }
$xml = [xml](Get-Content -LiteralPath $license -Raw)
$licenseIdNode = $xml.SelectSingleNode("//*[local-name()='license-id']")
$signature = $xml.SelectSingleNode("//*[local-name()='Signature']")
$licenseId = [Guid]::Empty
if (-not $licenseIdNode -or -not [Guid]::TryParse($licenseIdNode.InnerText, [ref]$licenseId)) { throw 'В лицензии отсутствует корректный license-id.' }
if (-not $signature) { throw 'В лицензии отсутствует XML-подпись.' }
foreach ($required in @(90,91)) {
    $product = @($xml.SelectNodes("//*[local-name()='product']")) | Where-Object { [int]$_.id -eq $required -and [int]$_.workplaces -gt 0 } | Select-Object -First 1
    if (-not $product) { throw "Лицензия не содержит продукт $required с ненулевым лимитом." }
}

if (-not $AdminPassword) { $AdminPassword = Read-Host "Пароль администратора Pilot '$AdminLogin'" -AsSecureString }
if (-not $BimPassword) { $BimPassword = Read-Host "Пароль сервисного пользователя BIM '$BimLogin'" -AsSecureString }
if ($AdminPassword.Length -eq 0 -or $BimPassword.Length -eq 0) { throw 'Пароли не могут быть пустыми.' }
$generatedToken = [string]::IsNullOrWhiteSpace($ApiToken)
if ($generatedToken) {
    $random = New-PilotRandomBytes -Count 32
    $ApiToken = [Convert]::ToBase64String($random).TrimEnd('=').Replace('+','-').Replace('/','_')
}
if ($ApiToken.Length -lt 32) { throw 'API-токен должен содержать не менее 32 символов.' }
if ($WebPublicPortEnd -lt $WebPublicPortStart -or $AdminPublicPortEnd -lt $AdminPublicPortStart) { throw 'Public port ranges are invalid.' }
if (($WebPublicPortEnd - $WebPublicPortStart) -ne ($AdminPublicPortEnd - $AdminPublicPortStart)) { throw 'Web and myAdmin public port ranges must have equal size.' }
$allPublicPorts = @($ControlPublicPort) + @($WebPublicPortStart..$WebPublicPortEnd) + @($AdminPublicPortStart..$AdminPublicPortEnd)
if (@($allPublicPorts | Group-Object | Where-Object Count -gt 1).Count -gt 0) { throw 'Control, Web and myAdmin public ports must not overlap.' }
if ([string]::IsNullOrWhiteSpace($PowerShellExecutable)) {
    $PowerShellExecutable = Get-PilotWindowsPowerShellPath
}
$PowerShellExecutable = (Resolve-Path -LiteralPath $PowerShellExecutable -ErrorAction Stop).Path

function ConvertFrom-Secure([Security.SecureString] $Value) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}
function Protect-String([string] $Value) {
    $clear = [Text.Encoding]::UTF8.GetBytes($Value)
    try { [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($clear, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)) }
    finally { [Array]::Clear($clear, 0, $clear.Length) }
}
function Get-TokenHash([string] $Token) {
    $iterations = 210000
    $salt = New-PilotRandomBytes -Count 32
    $derive = New-Object Security.Cryptography.Rfc2898DeriveBytes($Token, $salt, $iterations, [Security.Cryptography.HashAlgorithmName]::SHA256)
    try { $hash = $derive.GetBytes(32) } finally { $derive.Dispose() }
    "v1.$iterations.$([Convert]::ToBase64String($salt)).$([Convert]::ToBase64String($hash))"
}

$adminClear = ConvertFrom-Secure $AdminPassword
$bimClear = ConvertFrom-Secure $BimPassword
try {
    [void](New-Item -ItemType Directory -Path (Join-Path $runtime 'license') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $runtime 'keys') -Force)
    Copy-Item -LiteralPath $license -Destination (Join-Path $runtime 'license\current.pilotlic') -Force
    Copy-Item -LiteralPath $configuration -Destination (Join-Path $runtime 'configuration_pilot-bim_ru.pilotcfx') -Force
    $secretJson = [ordered]@{
        schemaVersion = 1
        tokenHash = Get-TokenHash $ApiToken
        adminLogin = $AdminLogin
        adminPasswordProtected = Protect-String $adminClear
        bimLogin = $BimLogin
        bimPasswordProtected = Protect-String $bimClear
    } | ConvertTo-Json
    Write-PilotUtf8NoBom -LiteralPath $secretPath -Text $secretJson
    $settingsJson = [ordered]@{
        PilotEnv = [ordered]@{
            PublicHost = $PublicHost.Trim().TrimEnd('.')
            ListenUrl = $ListenUrl
            PublicScheme = $PublicScheme
            ControlPublicPort = $ControlPublicPort
            WebPublicPortStart = $WebPublicPortStart
            WebPublicPortEnd = $WebPublicPortEnd
            AdminPublicPortStart = $AdminPublicPortStart
            AdminPublicPortEnd = $AdminPublicPortEnd
            DisableMemoryAdmission = [bool]$DisableMemoryAdmission
            SecretFile = '.pilot-runtime/api/secrets.json'
            LicenseFile = '.pilot-runtime/api/license/current.pilotlic'
            ConfigurationFile = '.pilot-runtime/api/configuration_pilot-bim_ru.pilotcfx'
            DatabaseFile = '.pilot-runtime/api/pilot-env.db'
            PowerShellExecutable = $PowerShellExecutable
        }
    } | ConvertTo-Json -Depth 4
    Write-PilotUtf8NoBom -LiteralPath (Join-Path $runtime 'hostsettings.json') -Text $settingsJson
}
finally {
    $adminClear = $null
    $bimClear = $null
}

if (-not $runtimeAlreadyExisted) { & icacls.exe $runtime /inheritance:r | Out-Null }
& icacls.exe $runtime /grant:r "$([Security.Principal.WindowsIdentity]::GetCurrent().Name):(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Не удалось ограничить ACL каталога API.' }

if ($generatedToken) {
    Write-Host "API настроен. Общий токен (показывается один раз): $ApiToken" -ForegroundColor Green
    Write-Host 'Сохраните токен в менеджере секретов.'
}
else {
    Write-Host 'API настроен. Переданный токен принят и не выведен в журнал.' -ForegroundColor Green
}
if (-not $SuppressInstallHint) {
    Write-Host "Выполните .\scripts\install-api-service.ps1"
}
