[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,39}$')]
    [string] $Name,
    [string] $DatabaseTemplate = 'C:\ProgramData\ASCON\Pilot Server\Databases\pilot-ice_ru',
    [ValidateRange(0, 65535)] [int] $ServerPort,
    [ValidateRange(0, 65535)] [int] $WebPort,
    [ValidateRange(0, 65535)] [int] $AdminPort
)

$ErrorActionPreference = 'Stop'
$manager = Join-Path $PSScriptRoot 'pilot-env.ps1'
$instanceConfig = Join-Path (Split-Path -Parent $PSScriptRoot) ".pilot-instances\$Name\instance.json"

if (Test-Path -LiteralPath $instanceConfig) {
    $config = Get-Content -LiteralPath $instanceConfig -Raw | ConvertFrom-Json
    if ($config.mode -ne 'ice-dev') { throw "Стенд '$Name' имеет режим '$($config.mode)', ожидался ice-dev." }
    & $manager Start $Name
}
else {
    & $manager New $Name -Mode ice-dev -DatabaseName pilot-ice_ru -DatabaseTemplate $DatabaseTemplate -ServerPort $ServerPort -WebPort $WebPort -AdminPort $AdminPort -AdminLogin admin -Start
}
exit $LASTEXITCODE
