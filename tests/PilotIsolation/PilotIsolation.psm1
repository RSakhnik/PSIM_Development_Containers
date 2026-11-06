Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-CheckResult {
    param(
        [string] $Name,
        [bool] $Passed,
        [string] $Details
    )

    [pscustomobject][ordered]@{
        Name = $Name
        Passed = $Passed
        Details = $Details
    }
}

function Wait-HttpEndpoint {
    param(
        [string] $Uri,
        [int] $TimeoutSeconds = 180
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastError = $null
    do {
        try {
            $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                return [pscustomobject]@{
                    Available = $true
                    StatusCode = [int]$response.StatusCode
                    Content = [string]$response.Content
                }
            }
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds 2
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    return [pscustomobject]@{
        Available = $false
        StatusCode = $null
        Content = $lastError
    }
}

function Test-HttpEndpointUnavailable {
    param([string] $Uri)

    try {
        [void](Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 5)
        return $false
    }
    catch {
        return $true
    }
}

function Test-WebLogin {
    param([string] $BaseUri)

    try {
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $body = @{ username = 'admin'; password = 'admin' } | ConvertTo-Json -Compress
        $contextId = [Guid]::NewGuid().ToString()
        $response = Invoke-WebRequest "$BaseUri/api/Auth/SignIn?browserContextId=$contextId" -Method Post -ContentType 'application/json' -Body $body -WebSession $session -UseBasicParsing -TimeoutSec 10
        return [pscustomobject]@{ Passed = $response.StatusCode -eq 200; StatusCode = [int]$response.StatusCode }
    }
    catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
        return [pscustomobject]@{ Passed = $false; StatusCode = $status }
    }
}

function Get-InstanceConfig {
    param(
        [string] $RepositoryRoot,
        [string] $Name
    )

    $path = Join-Path $RepositoryRoot ".pilot-instances\$Name\instance.json"
    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Get-ProjectContainers {
    param([string] $ProjectName)

    $lines = @(& docker ps --all --filter "label=com.docker.compose.project=$ProjectName" --format '{{json .}}')
    if ($LASTEXITCODE -ne 0) {
        throw "Не удалось получить контейнеры Docker Compose-проекта '$ProjectName'."
    }

    @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-ContainerInspection {
    param([string[]] $ContainerIds)

    if ($ContainerIds.Count -eq 0) { return @() }
    $json = & docker inspect @ContainerIds
    if ($LASTEXITCODE -ne 0) {
        throw 'docker inspect завершился с ошибкой.'
    }
    @((($json -join [Environment]::NewLine) | ConvertFrom-Json))
}

function Get-ServiceInspection {
    param(
        [object[]] $Inspections,
        [string] $ServiceName
    )

    $Inspections | Where-Object {
        $_.Config.Labels.'com.docker.compose.service' -eq $ServiceName
    } | Select-Object -First 1
}

function Get-MountSource {
    param(
        [object] $Inspection,
        [string] $Destination
    )

    if (-not $Inspection) { return $null }
    $mount = $Inspection.Mounts | Where-Object { $_.Destination -eq $Destination } | Select-Object -First 1
    if (-not $mount) { return $null }
    return $mount.Source
}

function Get-NetworkNames {
    param([object] $Inspection)

    if (-not $Inspection) { return @() }
    @($Inspection.NetworkSettings.Networks.PSObject.Properties.Name)
}

function Invoke-PilotManager {
    param(
        [string] $ManagerPath,
        [string] $Action,
        [string] $Name,
        [hashtable] $Parameters = @{}
    )

    & $ManagerPath $Action $Name @Parameters | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "pilot-env.ps1 завершился с кодом ${LASTEXITCODE}: $Action $Name"
    }
}

function Test-PilotInstanceIsolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string] $DatabaseTemplate,

        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
        [string] $DatabaseName = 'pilot-ice_ru',

        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
        [string] $ImageTag = '26.9.0',

        [ValidateRange(30, 900)] [int] $StartupTimeoutSeconds = 240,
        [switch] $KeepEnvironments
    )

    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $managerPath = Join-Path $repositoryRoot 'scripts\pilot-env.ps1'
    if (-not (Test-Path -LiteralPath $managerPath -PathType Leaf)) {
        throw "Не найден управляющий скрипт: $managerPath"
    }

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'Docker CLI не найден.'
    }
    & docker info --format '{{.ServerVersion}}' *> $null
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker Engine недоступен. Запустите Docker Desktop.'
    }

    $runId = ([Guid]::NewGuid().ToString('N')).Substring(0, 8)
    $nameA = "iso-$runId-a"
    $nameB = "iso-$runId-b"
    $createdNames = [Collections.Generic.List[string]]::new()
    $checks = [Collections.Generic.List[object]]::new()
    $startedAt = [DateTime]::UtcNow
    $fatalError = $null
    $configA = $null
    $configB = $null

    try {
        $commonNewParameters = @{
            DatabaseTemplate = (Resolve-Path -LiteralPath $DatabaseTemplate).Path
            DatabaseName = $DatabaseName
            ImageTag = $ImageTag
            Mode = 'ice-dev'
            AdminLogin = 'admin'
            Start = $true
        }

        Write-Host "[isolation-test] Создаю первый стенд '$nameA'." -ForegroundColor Cyan
        [void]$createdNames.Add($nameA)
        Invoke-PilotManager -ManagerPath $managerPath -Action 'New' -Name $nameA -Parameters $commonNewParameters

        Write-Host "[isolation-test] Создаю второй стенд '$nameB'." -ForegroundColor Cyan
        [void]$createdNames.Add($nameB)
        Invoke-PilotManager -ManagerPath $managerPath -Action 'New' -Name $nameB -Parameters $commonNewParameters

        $configA = Get-InstanceConfig -RepositoryRoot $repositoryRoot -Name $nameA
        $configB = Get-InstanceConfig -RepositoryRoot $repositoryRoot -Name $nameB

        [void]$checks.Add((New-CheckResult -Name 'Оба стенда в режиме ice-dev/Pilot-ICE' -Passed ($configA.schemaVersion -eq 4 -and $configB.schemaVersion -eq 4 -and $configA.mode -eq 'ice-dev' -and $configB.mode -eq 'ice-dev' -and $configA.product -eq 'Pilot-ICE' -and $configB.product -eq 'Pilot-ICE') -Details "A=$($configA.mode)/$($configA.product); B=$($configB.mode)/$($configB.product)"))

        $portsA = @([int]$configA.ports.server, [int]$configA.ports.web, [int]$configA.ports.admin)
        $portsB = @([int]$configB.ports.server, [int]$configB.ports.web, [int]$configB.ports.admin)
        $duplicatePorts = @($portsA | Where-Object { $portsB -contains $_ })
        [void]$checks.Add((New-CheckResult -Name 'Разные host-порты' -Passed ($duplicatePorts.Count -eq 0) -Details "A=$($portsA -join ', '); B=$($portsB -join ', ')"))

        $containersA = Get-ProjectContainers -ProjectName $configA.composeProject
        $containersB = Get-ProjectContainers -ProjectName $configB.composeProject
        $idsA = @($containersA.ID)
        $idsB = @($containersB.ID)
        $duplicateIds = @($idsA | Where-Object { $idsB -contains $_ })
        [void]$checks.Add((New-CheckResult -Name 'Разные контейнеры' -Passed ($idsA.Count -ge 4 -and $idsB.Count -ge 4 -and $duplicateIds.Count -eq 0) -Details "A=$($idsA.Count); B=$($idsB.Count)"))
        $bimContainers = @($containersA + $containersB | Where-Object { $_.Names -match 'pilot-bim-server' })
        [void]$checks.Add((New-CheckResult -Name 'Pilot-BIM Server отсутствует в dev' -Passed ($bimContainers.Count -eq 0) -Details "BIM containers=$($bimContainers.Count)"))

        $inspectionsA = Get-ContainerInspection -ContainerIds $idsA
        $inspectionsB = Get-ContainerInspection -ContainerIds $idsB
        $serverA = Get-ServiceInspection -Inspections $inspectionsA -ServiceName 'pilot-server'
        $serverB = Get-ServiceInspection -Inspections $inspectionsB -ServiceName 'pilot-server'

        $networksA = @(Get-NetworkNames -Inspection $serverA)
        $networksB = @(Get-NetworkNames -Inspection $serverB)
        $sharedNetworks = @($networksA | Where-Object { $networksB -contains $_ })
        [void]$checks.Add((New-CheckResult -Name 'Разные Docker-сети' -Passed ($networksA.Count -gt 0 -and $networksB.Count -gt 0 -and $sharedNetworks.Count -eq 0) -Details "A=$($networksA -join ', '); B=$($networksB -join ', ')"))

        $settingsA = Get-MountSource -Inspection $serverA -Destination '/usr/share/ascon/pilot-server/settings'
        $settingsB = Get-MountSource -Inspection $serverB -Destination '/usr/share/ascon/pilot-server/settings'
        $databasesA = Get-MountSource -Inspection $serverA -Destination '/usr/share/ascon/databases'
        $databasesB = Get-MountSource -Inspection $serverB -Destination '/usr/share/ascon/databases'
        $separateMounts = $settingsA -and $settingsB -and $databasesA -and $databasesB -and
            ($settingsA -ne $settingsB) -and ($databasesA -ne $databasesB)
        [void]$checks.Add((New-CheckResult -Name 'Разные settings и databases mounts' -Passed ([bool]$separateMounts) -Details "settings: '$settingsA' <> '$settingsB'; databases: '$databasesA' <> '$databasesB'"))

        $instancePathA = Join-Path $repositoryRoot ".pilot-instances\$nameA"
        $instancePathB = Join-Path $repositoryRoot ".pilot-instances\$nameB"
        $sentinelA = Join-Path $instancePathA 'databases\isolation-a.txt'
        $sentinelB = Join-Path $instancePathB 'databases\isolation-b.txt'
        Set-Content -LiteralPath $sentinelA -Value $nameA -Encoding utf8NoBOM
        Set-Content -LiteralPath $sentinelB -Value $nameB -Encoding utf8NoBOM
        $sentinelsIsolated = (Test-Path -LiteralPath $sentinelA) -and (Test-Path -LiteralPath $sentinelB) -and
            -not (Test-Path -LiteralPath (Join-Path $instancePathA 'databases\isolation-b.txt')) -and
            -not (Test-Path -LiteralPath (Join-Path $instancePathB 'databases\isolation-a.txt'))
        [void]$checks.Add((New-CheckResult -Name 'Изоляция файлов БД' -Passed $sentinelsIsolated -Details 'Контрольные файлы видны только внутри соответствующего bind mount.'))

        $serverUriA = "http://127.0.0.1:$($configA.ports.server)/"
        $serverUriB = "http://127.0.0.1:$($configB.ports.server)/"
        $webUriA = "http://127.0.0.1:$($configA.ports.web)/"
        $webUriB = "http://127.0.0.1:$($configB.ports.web)/"

        $serverProbeA = Wait-HttpEndpoint -Uri $serverUriA -TimeoutSeconds $StartupTimeoutSeconds
        $serverProbeB = Wait-HttpEndpoint -Uri $serverUriB -TimeoutSeconds $StartupTimeoutSeconds
        [void]$checks.Add((New-CheckResult -Name 'Оба Pilot Server доступны' -Passed ($serverProbeA.Available -and $serverProbeB.Available) -Details "A=$($serverProbeA.StatusCode); B=$($serverProbeB.StatusCode)"))

        $webProbeA = Wait-HttpEndpoint -Uri $webUriA -TimeoutSeconds $StartupTimeoutSeconds
        $webProbeB = Wait-HttpEndpoint -Uri $webUriB -TimeoutSeconds $StartupTimeoutSeconds
        [void]$checks.Add((New-CheckResult -Name 'Оба Pilot Web доступны' -Passed ($webProbeA.Available -and $webProbeB.Available) -Details "A=$($webProbeA.StatusCode); B=$($webProbeB.StatusCode)"))

        $loginA = Test-WebLogin -BaseUri $webUriA.TrimEnd('/')
        $loginB = Test-WebLogin -BaseUri $webUriB.TrimEnd('/')
        [void]$checks.Add((New-CheckResult -Name 'Вход admin/admin в оба Pilot Web' -Passed ($loginA.Passed -and $loginB.Passed) -Details "A=$($loginA.StatusCode); B=$($loginB.StatusCode)"))

        Write-Host "[isolation-test] Останавливаю '$nameA' и проверяю независимость '$nameB'." -ForegroundColor Cyan
        Invoke-PilotManager -ManagerPath $managerPath -Action 'Stop' -Name $nameA
        $aStopped = Test-HttpEndpointUnavailable -Uri $serverUriA
        $bAfterAStop = Wait-HttpEndpoint -Uri $serverUriB -TimeoutSeconds 30
        [void]$checks.Add((New-CheckResult -Name 'Остановка A не влияет на B' -Passed ($aStopped -and $bAfterAStop.Available) -Details "A stopped=$aStopped; B status=$($bAfterAStop.StatusCode)"))

        Write-Host "[isolation-test] Повторно запускаю '$nameA'." -ForegroundColor Cyan
        Invoke-PilotManager -ManagerPath $managerPath -Action 'Start' -Name $nameA -Parameters @{
            AdminLogin = 'admin'
        }
        $aAfterRestart = Wait-HttpEndpoint -Uri $serverUriA -TimeoutSeconds $StartupTimeoutSeconds
        $bAfterRestart = Wait-HttpEndpoint -Uri $serverUriB -TimeoutSeconds 30
        [void]$checks.Add((New-CheckResult -Name 'Повторный запуск A сохраняет B' -Passed ($aAfterRestart.Available -and $bAfterRestart.Available) -Details "A=$($aAfterRestart.StatusCode); B=$($bAfterRestart.StatusCode)"))
    }
    catch {
        $fatalError = $_.Exception.Message
        [void]$checks.Add((New-CheckResult -Name 'Выполнение интеграционного сценария' -Passed $false -Details $fatalError))
    }
    finally {
        if (-not $KeepEnvironments) {
            foreach ($createdName in $createdNames) {
                $createdConfig = Join-Path $repositoryRoot ".pilot-instances\$createdName\instance.json"
                if (-not (Test-Path -LiteralPath $createdConfig -PathType Leaf)) { continue }
                try {
                    Write-Host "[isolation-test] Удаляю тестовый стенд '$createdName'." -ForegroundColor DarkGray
                    Invoke-PilotManager -ManagerPath $managerPath -Action 'Remove' -Name $createdName -Parameters @{ Force = $true }
                }
                catch {
                    [void]$checks.Add((New-CheckResult -Name "Очистка $createdName" -Passed $false -Details $_.Exception.Message))
                }
            }
        }
    }

    $failedChecks = @($checks | Where-Object { -not $_.Passed })
    [pscustomobject][ordered]@{
        TestRunId = $runId
        Passed = $failedChecks.Count -eq 0
        StartedAt = $startedAt.ToString('o')
        FinishedAt = [DateTime]::UtcNow.ToString('o')
        InstanceA = if ($configA) { $configA.name } else { $nameA }
        InstanceB = if ($configB) { $configB.name } else { $nameB }
        KeptEnvironments = $KeepEnvironments.IsPresent
        FatalError = $fatalError
        Checks = @($checks)
    }
}

Export-ModuleMember -Function Test-PilotInstanceIsolation

