[CmdletBinding()]
param(
    [string] $NameA = 'bim-ifc-a',
    [string] $NameB = 'bim-ifc-b',
    [string] $Login = 'admin',
    [string] $Password = 'admin'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$checks = [Collections.Generic.List[object]]::new()
function Add-Check([string]$Name,[bool]$Passed,[string]$Details) {
    $checks.Add([pscustomobject]@{Name=$Name;Passed=$Passed;Details=$Details})
}
function Get-Config([string]$Name) {
    Get-Content -LiteralPath (Join-Path $root ".pilot-instances\$Name\instance.json") -Raw | ConvertFrom-Json
}
function Test-Login([object]$Config) {
    try {
        $session=[Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $body=@{username=$Login;password=$Password}|ConvertTo-Json -Compress
        $response=Invoke-WebRequest "http://127.0.0.1:$($Config.ports.web)/api/Auth/SignIn?browserContextId=$([Guid]::NewGuid())" -Method Post -ContentType 'application/json' -Body $body -WebSession $session -TimeoutSec 10
        return $response.StatusCode -eq 200
    } catch { return $false }
}

$a=Get-Config $NameA; $b=Get-Config $NameB
Add-Check 'schema v4 / bim-dev' ($a.schemaVersion -eq 4 -and $b.schemaVersion -eq 4 -and $a.mode -eq 'bim-dev' -and $b.mode -eq 'bim-dev') "$NameA, $NameB"
$portsA=@($a.ports.server,$a.ports.web,$a.ports.admin); $portsB=@($b.ports.server,$b.ports.web,$b.ports.admin)
Add-Check 'Уникальные порты' (@($portsA|Where-Object{$portsB -contains $_}).Count -eq 0) "A=$($portsA -join ','); B=$($portsB -join ',')"
Add-Check 'Разные Compose-проекты' ($a.composeProject -ne $b.composeProject) "$($a.composeProject) / $($b.composeProject)"
$runningA=@(docker ps -q --filter "label=com.docker.compose.project=$($a.composeProject)").Count
$runningB=@(docker ps -q --filter "label=com.docker.compose.project=$($b.composeProject)").Count
Add-Check 'Оба стенда одновременно запущены' ($runningA -ge 5 -and $runningB -ge 5) "A=$runningA; B=$runningB"
if ($runningA -ge 5 -and $runningB -ge 5) {
    Add-Check 'Вход в оба Web' ((Test-Login $a) -and (Test-Login $b)) 'Ожидается HTTP 200 в обоих стендах.'
    $logsA=@(docker logs "$($a.composeProject)-pilot-bim-server-1" 2>&1)-join "`n"
    $logsB=@(docker logs "$($b.composeProject)-pilot-bim-server-1" 2>&1)-join "`n"
    Add-Check 'Оба BIM online без license error' ($logsA -match 'Success connection to database' -and $logsB -match 'Success connection to database' -and ($logsA+$logsB) -notmatch 'OverflowCountServerLicenseException|Exceeded max license limit') 'Проверены последние полные логи BIM.'
}

$checks|Format-Table Name,Passed,Details -Wrap -AutoSize
if (@($checks|Where-Object{-not $_.Passed}).Count) { exit 1 }
exit 0
