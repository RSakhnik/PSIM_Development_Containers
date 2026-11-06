[CmdletBinding()]
param([Parameter(Mandatory = $true)][string] $LicenseFile)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$manager = Join-Path $root 'scripts\pilot-env.ps1'
$checks = [Collections.Generic.List[object]]::new()

function Add-Check([string]$Name, [bool]$Passed, [string]$Details) {
    $checks.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Details = $Details })
}
function Expect-Failure([string]$Name, [scriptblock]$Code, [string]$Pattern) {
    try { & $Code; Add-Check $Name $false 'Команда неожиданно завершилась успешно.' }
    catch { Add-Check $Name ($_.Exception.Message -match $Pattern) $_.Exception.Message }
}

Expect-Failure 'Нет лицензии' { & $manager New validation-no-license -Mode bim-dev } 'LicenseFile|лиценз'
$bad = Join-Path ([IO.Path]::GetTempPath()) "bad-$([Guid]::NewGuid().ToString('N'))"
try {
    Set-Content -LiteralPath $bad -Value '<pilot-license />' -Encoding utf8NoBOM
    Expect-Failure 'Повреждённая/неподходящая лицензия' { & $manager New validation-bad-license -Mode bim-dev -LicenseFile $bad } 'license-id|подпись|продукт'
} finally { Remove-Item -LiteralPath $bad -Force -ErrorAction SilentlyContinue }

$tampered = Join-Path ([IO.Path]::GetTempPath()) "tampered-$([Guid]::NewGuid().ToString('N'))"
try {
    $text = Get-Content -LiteralPath $LicenseFile -Raw
    $text = $text -replace '<SignatureValue>[^<]+', '<SignatureValue>not-base64!'
    Set-Content -LiteralPath $tampered -Value $text -Encoding utf8NoBOM
    Expect-Failure 'Повреждённая XML-подпись' { & $manager New validation-signature -Mode bim-dev -LicenseFile $tampered } 'подпис'
} finally { Remove-Item -LiteralPath $tampered -Force -ErrorAction SilentlyContinue }

$empty = [Security.SecureString]::new()
Expect-Failure 'Пустые пароли' { & $manager New validation-empty-password -Mode bim-dev -LicenseFile $LicenseFile -Start -AdminPassword $empty -BimPassword $empty } 'Password|парол'
Expect-Failure 'Внешний Pilot Server запрещён' { & $manager New validation-external -Mode bim-dev -LicenseFile $LicenseFile -PilotServerUrl 'https://production.example' } 'parameter|параметр'
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
try {
    $listener.Start()
    $busyPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    Expect-Failure 'Занятый порт ОС' { & $manager New validation-busy -Mode bim-dev -LicenseFile $LicenseFile -ServerPort $busyPort } 'Порт.*занят'
} finally { $listener.Stop() }

$compose = Get-Content -LiteralPath (Join-Path $root 'docker-compose.yml') -Raw
Add-Check 'Только localhost' ($compose -match '127\.0\.0\.1:\$\{PILOT_SERVER_PORT\}' -and $compose -notmatch '0\.0\.0\.0') 'Публикация жёстко привязана к loopback.'
Add-Check 'Исходящий доступ включён' ($compose -match 'internal:\s*false' -and $compose -match 'enable_ip_masquerade:\s*"true"') 'Отдельная bridge-сеть среды с NAT для внешних зависимостей.'
Add-Check 'Фиксированный внутренний URL' ($compose -match 'http://pilot-server:5545') 'Внешний Pilot Server параметром не задаётся.'
Add-Check 'BIM memory limits' ($compose -match 'PILOT_BIM_MEMORY' -and $compose -match 'PILOT_SERVER_MEMORY') 'Лимиты задаются Compose.'
Add-Check 'Нет дополнительных Pilot-служб' ($compose -notmatch 'textsearch|sign-server|cad-farm') 'TextSearch/Sign/CAD Farm отсутствуют.'
$managerSource = Get-Content -LiteralPath $manager -Raw
Add-Check 'Проверка несовпадения версий' ($managerSource -match 'Несовместимые версии core-компонентов') 'Server/BIM/Web сравниваются после старта.'
Add-Check 'Проверка недостатка RAM' ($managerSource -match 'Недостаточно памяти Docker') 'Resource guard включён.'

$licenseXml = [xml](Get-Content -LiteralPath $LicenseFile -Raw)
$id = $licenseXml.SelectSingleNode("//*[local-name()='license-id']").InnerText
$hash = (Get-FileHash -LiteralPath $LicenseFile -Algorithm SHA256).Hash
Add-Check 'Лицензия 90/91' (@($licenseXml.SelectNodes("//*[local-name()='product']") | Where-Object { $_.id -in @('90','91') }).Count -eq 2) "license-id=$id; sha256=$hash"

$checks | Format-Table Name,Passed,Details -Wrap -AutoSize
if (@($checks | Where-Object { -not $_.Passed }).Count) { exit 1 }
exit 0
