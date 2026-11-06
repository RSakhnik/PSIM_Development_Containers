[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('GetEngineInfo', 'New', 'Start', 'Stop', 'Down', 'Status', 'GetStatus', 'GetCapacity', 'RestartComponent', 'Recreate', 'RefreshRelease', 'Logs', 'List', 'ConnectBim', 'Open', 'Remove', 'Doctor', 'PrepareTemplate', 'ResolveRelease')]
    [string] $Action,

    [Parameter(Position = 1)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,39}$')]
    [string] $Name,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string] $DatabaseName = 'pilot-bim_ru',
    [string] $DatabaseTemplate,
    [string] $ConfigurationFile,
    [string] $LicenseFile,
    [ValidateSet('ice-dev', 'bim-dev')] [string] $Mode,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
    [string] $ImageTag = 'release',
    [ValidateRange(0, 65535)] [int] $ServerPort,
    [ValidateRange(0, 65535)] [int] $WebPort,
    [ValidateRange(0, 65535)] [int] $AdminPort,
    [ValidateRange(0, 65535)] [int] $PublicWebPort,
    [ValidateRange(0, 65535)] [int] $PublicAdminPort,
    [ValidateSet('All', 'Password', 'Oidc')] [string] $AuthMode = 'All',
    [switch] $Start,
    [switch] $Force,
    [ValidateSet('pilot-server', 'pilot-bim-server', 'pilot-web-server', 'pilot-web-myadmin')]
    [string] $Service,
    [ValidateRange(1, 2000)] [int] $Tail = 200,
    [switch] $Cascade,
    [switch] $Json,
    [switch] $Machine,
    [string] $AdminLogin = 'admin',
    [Security.SecureString] $AdminPassword,
    [string] $BimLogin = 'bimadmin',
    [Security.SecureString] $BimPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)

# Stable protocol boundary. The ordinary CLI is invoked with the same bound arguments.
if ($Machine) {
    $invokeParameters = @{} + $PSBoundParameters
    $invokeParameters.Remove('Machine')
    $records = @()
    try {
        $records = @(& $PSCommandPath @invokeParameters *>&1)
        $data = $null
        foreach ($record in $records) {
            $line = [string]$record
            if ($invokeParameters.ContainsKey('Json') -and ($line.TrimStart().StartsWith('{') -or $line.TrimStart().StartsWith('['))) {
                try { $data = ConvertFrom-Json -InputObject $line -ErrorAction Stop; continue } catch { }
            }
            [Console]::Error.WriteLine($line)
        }
        if ($null -eq $data) { $data = ($records | ForEach-Object { [string]$_ }) -join [Environment]::NewLine }
        [Console]::Out.WriteLine((@{protocolVersion=1;success=$true;data=$data;error=$null} | ConvertTo-Json -Depth 30 -Compress))
        exit 0
    } catch {
        [Console]::Out.WriteLine((@{protocolVersion=1;success=$false;data=$null;error=@{code='engine_failed';message=$_.Exception.Message}} | ConvertTo-Json -Depth 8 -Compress))
        exit 1
    }
}

# Root CLI remains a compatible adapter after bootstrap installation.
$adapterRoot = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $adapterRoot '.pilot-runtime\deployment-state.json'
if (-not $env:PILOT_ENGINE_ROOT -and (Test-Path -LiteralPath $statePath)) {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if($state.schemaVersion -ne 2){throw 'Migrate the deployment layout using the current installer.'}
    $buildHash = [string]$state.components.'environment-engine'.buildHash
    if ($buildHash -notmatch '^[a-f0-9]{64}$') { throw 'Invalid engine build hash.' }
    $selectedRoot = Join-Path $adapterRoot ".pilot-runtime\builds\environment-engine\$buildHash"
    $env:PILOT_DATA_ROOT = $adapterRoot
    $env:PILOT_ENGINE_ROOT = $selectedRoot
    try { & (Join-Path $selectedRoot 'scripts\pilot-env.ps1') @PSBoundParameters }
    finally { Remove-Item Env:\PILOT_DATA_ROOT; Remove-Item Env:\PILOT_ENGINE_ROOT }
    return
}

if ($Action -eq 'GetEngineInfo') {
    $info = [ordered]@{buildHash='workspace';protocolVersion=1;instanceSchemaMin=4;instanceSchemaMax=4;actions=@('New','Start','Stop','Remove','RestartComponent','Recreate','RefreshRelease','GetStatus','GetCapacity','Logs','GetEngineInfo')}
    $engineManifest = Join-Path (Split-Path -Parent $PSScriptRoot) 'component-manifest.json'
    if (Test-Path -LiteralPath $engineManifest) {
        $stream=[IO.File]::OpenRead($engineManifest);$sha=[Security.Cryptography.SHA256]::Create()
        try{$info.buildHash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$stream.Dispose();$sha.Dispose()}
    }
    if ($Json) { $info | ConvertTo-Json -Depth 4 -Compress } else { [pscustomobject]$info | Format-List }
    return
}
. (Join-Path $PSScriptRoot 'ps-compat.ps1')

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:EngineRoot = if ($env:PILOT_ENGINE_ROOT) { [IO.Path]::GetFullPath($env:PILOT_ENGINE_ROOT) } else { $script:RepoRoot }
if ($env:PILOT_DATA_ROOT) { $script:RepoRoot = [IO.Path]::GetFullPath($env:PILOT_DATA_ROOT) }
$script:ComposeFile = Join-Path $script:EngineRoot 'docker-compose.yml'
$script:InstancesRoot = Join-Path $script:RepoRoot '.pilot-instances'
$script:RuntimeRoot = Join-Path $script:RepoRoot '.pilot-runtime'
$script:TemplatesRoot = Join-Path $script:RepoRoot '.pilot-templates'
$script:Registry = 'registry.ascon.ru/project/pilotdev/pilot'
$script:ReleaseOverride = $null
$script:DockerCommand = Enable-PilotDockerCompatibility
$script:ComponentImages = [ordered]@{
    server = "$($script:Registry)/pilot-server"
    bim = "$($script:Registry)/pilot-bim-server"
    web = "$($script:Registry)/pilot-web-server"
    myAdmin = "$($script:Registry)/pilot-web-myadmin"
}

if ([string]::IsNullOrWhiteSpace($LicenseFile)) { $script:LicenseFile = [Environment]::GetEnvironmentVariable('PILOT_LICENSE_FILE') }
if ([string]::IsNullOrWhiteSpace($ConfigurationFile)) { $script:ConfigurationFile = [Environment]::GetEnvironmentVariable('PILOT_CONFIGURATION_FILE') }
$configuredAdminLogin = [Environment]::GetEnvironmentVariable('PILOT_ADMIN_LOGIN')
$configuredBimLogin = [Environment]::GetEnvironmentVariable('PILOT_BIM_LOGIN')
if (-not [string]::IsNullOrWhiteSpace($configuredAdminLogin)) { $script:AdminLogin = $configuredAdminLogin }
if (-not [string]::IsNullOrWhiteSpace($configuredBimLogin)) { $script:BimLogin = $configuredBimLogin }

function Write-Info {
    param([string] $Message)
    Write-Host "[pilot-env] $Message" -ForegroundColor Cyan
}

function Get-PilotSha256 {
    param([Parameter(Mandatory = $true)][string] $LiteralPath)
    $stream = [IO.File]::OpenRead([IO.Path]::GetFullPath($LiteralPath))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
    finally { $sha.Dispose(); $stream.Dispose() }
}

function Assert-Name {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "Для действия '$Action' укажите имя стенда, например: .\scripts\pilot-env.ps1 $Action feature-a"
    }
}

function Get-InstancePath {
    param([string] $InstanceName)
    Join-Path $script:InstancesRoot $InstanceName
}

function Get-InstanceConfig {
    param([string] $InstanceName)

    $path = Join-Path (Get-InstancePath $InstanceName) 'instance.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Стенд '$InstanceName' не найден. Создайте его действием New или посмотрите список действием List."
    }

    $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($config.schemaVersion -ne 4 -or $config.mode -notin @('ice-dev', 'bim-dev')) {
        throw "Стенд '$InstanceName' использует устаревшую схему. Пересоздайте его через start-dev.ps1 или start-bim-dev.ps1."
    }
    return $config
}

function Get-LicenseMetadata {
    param([Parameter(Mandatory = $true)][string] $Path)

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Файл лицензии не найден: $Path" }
    try {
        $xml = [Xml.XmlDocument]::new()
        $xml.PreserveWhitespace = $true
        $xml.Load($resolved)
    }
    catch { throw "Лицензия не является корректным XML: $($_.Exception.Message)" }
    if ($xml.DocumentElement.LocalName -ne 'pilot-license') { throw 'Корневой XML-элемент лицензии должен называться pilot-license.' }

    $idNode = $xml.SelectSingleNode("//*[local-name()='license-id']")
    $signature = $xml.SelectSingleNode("//*[local-name()='Signature']")
    $parsedLicenseId = [Guid]::Empty
    if (-not $idNode -or -not ([Guid]::TryParse($idNode.InnerText, [ref]$parsedLicenseId))) { throw 'В лицензии отсутствует корректный license-id.' }
    if (-not $signature -or [string]::IsNullOrWhiteSpace($signature.InnerText)) { throw 'В лицензии отсутствует XML-подпись.' }
    $signatureValue = $signature.SelectSingleNode(".//*[local-name()='SignatureValue']")
    $digestValue = $signature.SelectSingleNode(".//*[local-name()='DigestValue']")
    $signatureMethod = $signature.SelectSingleNode(".//*[local-name()='SignatureMethod']")
    if (-not $signatureValue -or -not $digestValue -or -not $signatureMethod) { throw 'XML-подпись лицензии имеет неполную структуру.' }
    try {
        [void][Convert]::FromBase64String(($signatureValue.InnerText -replace '\s',''))
        [void][Convert]::FromBase64String(($digestValue.InnerText -replace '\s',''))
    } catch { throw "XML-подпись лицензии повреждена: $($_.Exception.Message)" }
    if ($signatureMethod.GetAttribute('Algorithm') -notmatch '^http://www\.w3\.org/.+rsa-') { throw 'XML-подпись лицензии использует неизвестный алгоритм.' }

    $products = @($xml.SelectNodes("//*[local-name()='product']"))
    foreach ($required in @(90, 91)) {
        $product = $products | Where-Object { [int]$_.id -eq $required -and [int]$_.workplaces -gt 0 } | Select-Object -First 1
        if (-not $product) { throw "Лицензия не содержит требуемый продукт $required с ненулевым лимитом." }
    }
    $validNode = $xml.SelectSingleNode("//*[local-name()='valid-to' or local-name()='updates-valid-to' or local-name()='expiration-date']")
    if (-not $validNode) {
        $candidate = @($xml.SelectNodes('//*[contains(local-name(), "date") or contains(local-name(), "valid")]')) |
            Where-Object { $_.InnerText -match '^20\d\d-' } | Select-Object -Last 1
        $validNode = $candidate
    }
    $validTo = if ($validNode) { [DateTime]::Parse($validNode.InnerText).ToUniversalTime() } else { [DateTime]::MinValue }
    if ($validTo -eq [DateTime]::MinValue) { throw 'В лицензии не найдена дата окончания обновлений.' }
    if ($validTo -le [DateTime]::UtcNow) { throw "Срок обновлений лицензии истёк: $($validTo.ToString('o'))" }

    [pscustomobject][ordered]@{
        id = ([Guid]$idNode.InnerText).ToString()
        sha256 = (Get-PilotSha256 -LiteralPath $resolved).ToUpperInvariant()
        updatesValidTo = $validTo.ToString('o')
        signatureCheck = 'structure-valid; cryptographic acceptance is verified by Pilot Server'
        products = @($products | ForEach-Object { [pscustomobject]@{ id = [int]$_.id; workplaces = [int]$_.workplaces } })
        source = $resolved
    }
}

function Get-ReleaseLockPath { Join-Path $script:RuntimeRoot 'last-known-good.json' }

function Resolve-ReleaseSet {
    param([switch] $Pull)
    Assert-Docker
    [void](New-Item -ItemType Directory -Path $script:RuntimeRoot -Force)
    $refs = [ordered]@{}
    foreach ($entry in $script:ComponentImages.GetEnumerator()) {
        $tagged = "$($entry.Value):release"
        if ($Pull) {
            Write-Info "Проверяю release-образ $tagged"
            & docker pull $tagged | ForEach-Object { [Console]::Error.WriteLine([string]$_) }
            if ($LASTEXITCODE -ne 0) { throw "Не удалось загрузить $tagged" }
        }
        $digest = (& docker image inspect $tagged --format '{{index .RepoDigests 0}}' 2>$null | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($digest)) { throw "У образа $tagged отсутствует immutable RepoDigest." }
        $refs[$entry.Key] = [string]$digest
    }
    $ingressTag = 'pilot-local-ingress:1'
    $existingIngressId = [string](& docker image inspect $ingressTag --format '{{.Id}}' 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($existingIngressId)) {
        & docker build --provenance=false --tag $ingressTag (Join-Path $script:EngineRoot 'ingress') | ForEach-Object { [Console]::Error.WriteLine([string]$_) }
        if ($LASTEXITCODE -ne 0) { throw 'Не удалось собрать локальный ingress с outbound firewall.' }
    }
    $refs.ingress = $ingressTag
    [pscustomobject][ordered]@{ resolvedAt = [DateTime]::UtcNow.ToString('o'); tag = 'release'; images = [pscustomobject]$refs }
}

function Get-ReleaseSet {
    param([switch] $Refresh)
    $lockPath = Get-ReleaseLockPath
    try { return Resolve-ReleaseSet -Pull:$Refresh }
    catch {
        if (Test-Path -LiteralPath $lockPath) {
            Write-Warning "Новый release недоступен или не прошёл разрешение; использую last-known-good: $($_.Exception.Message)"
            return Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        }
        throw
    }
}

function Save-ReleaseAsKnownGood {
    param([pscustomobject] $Release)
    [void](New-Item -ItemType Directory -Path $script:RuntimeRoot -Force)
    $json = $Release | ConvertTo-Json -Depth 6
    Write-PilotUtf8NoBom -LiteralPath (Get-ReleaseLockPath) -Text $json
}

function Reset-BimInstanceForRelease {
    param([pscustomobject] $Config, [pscustomobject] $Release)
    $instancePath = Get-InstancePath $Config.name
    $template = Get-ReleaseTemplatePath -Release $Release
    $main = Get-ChildItem -LiteralPath $template -File -Filter '*.dbp' -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -ieq '.dbp' -and $_.Name -notmatch '\.(messages|journal)\.dbp$' } | Select-Object -First 1
    if (-not $main) {
        $localLicense = Get-ChildItem -LiteralPath (Join-Path $instancePath 'license') -File -Filter '*.pilotlic' | Select-Object -First 1
        $officialConfig = Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -Filter 'configuration_pilot-bim_ru.pilotcfx' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike '*\.pilot-instances\*' } | Select-Object -First 1
        if (-not $officialConfig) { throw 'Новый release требует PrepareTemplate, но официальный .pilotcfx не найден.' }
        $previousLicense = $script:LicenseFile
        $previousConfiguration = $script:ConfigurationFile
        try {
            $script:LicenseFile = $localLicense.FullName
            $script:ConfigurationFile = $officialConfig.FullName
            Prepare-BimTemplate
        } finally {
            $script:LicenseFile = $previousLicense
            $script:ConfigurationFile = $previousConfiguration
        }
    }

    Write-Warning "Проверенный release изменился. Одноразовый стенд '$($Config.name)' будет пересоздан без миграции данных."
    Invoke-Compose -Config $Config -Arguments @('down', '--remove-orphans') -AllowFailure
    foreach ($relative in @('aspnet\pilot-server','aspnet\pilot-bim-server','bim','databases','logs\pilot-server','logs\pilot-bim-server','server\settings')) {
        $path = Join-Path $instancePath $relative
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        [void](New-Item -ItemType Directory -Path $path -Force)
    }
    Write-PilotUtf8NoBom -LiteralPath (Join-Path $instancePath 'server\settings\settings.xml') -Text '<Configuration></Configuration>'
    Copy-Item -LiteralPath $template -Destination (Join-Path $instancePath 'databases\pilot-bim_ru') -Recurse
    Remove-Item -LiteralPath (Join-Path $instancePath 'initialized.json') -Force -ErrorAction SilentlyContinue
    $Config.images = $Release.images
    $Config.releaseResolvedAt = $Release.resolvedAt
    $Config.versions = [pscustomobject][ordered]@{ server = $null; bim = $null; web = $null; myAdmin = $null }
    $json = $Config | ConvertTo-Json -Depth 8
    Write-PilotUtf8NoBom -LiteralPath (Join-Path $instancePath 'instance.json') -Text $json
    Write-InstanceEnvFile -InstancePath $instancePath -Config $Config
}

function Get-ReleaseTemplatePath {
    param([pscustomobject] $Release)
    # Invalidate snapshots previously taken while SQLite was still running.
    $identity = [Text.Encoding]::UTF8.GetBytes(([string]$Release.images.server) + '|stopped-sqlite-snapshot')
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = ([BitConverter]::ToString($sha.ComputeHash($identity))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    Join-Path $script:TemplatesRoot "$($digest.Substring(0, 16))\pilot-bim_ru"
}

function Prepare-BimTemplate {
    if ([string]::IsNullOrWhiteSpace($ConfigurationFile)) {
        $found = Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -Filter 'configuration_pilot-bim_ru.pilotcfx' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike '*\.pilot-instances\*' } | Select-Object -First 1
        if (-not $found) { throw 'Для PrepareTemplate укажите -ConfigurationFile с официальной configuration_pilot-bim_ru.pilotcfx.' }
        $script:ConfigurationFile = $found.FullName
    }
    $configuration = (Resolve-Path -LiteralPath $ConfigurationFile -ErrorAction Stop).Path
    if ([IO.Path]::GetExtension($configuration) -ine '.pilotcfx') { throw 'ConfigurationFile должен быть официальным файлом .pilotcfx.' }
    $license = if ([string]::IsNullOrWhiteSpace($LicenseFile)) { $null } else { Get-LicenseMetadata -Path $LicenseFile }
    $release = if ($script:ReleaseOverride) { $script:ReleaseOverride } else { Resolve-ReleaseSet -Pull }
    $target = Get-ReleaseTemplatePath -Release $release
    $existingMain = Get-ChildItem -LiteralPath $target -File -Filter '*.dbp' -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -ieq '.dbp' -and $_.Name -notmatch '\.(messages|journal)\.dbp$' } | Select-Object -First 1
    if ($existingMain) {
        Write-Info "BIM-ready шаблон этого release уже существует: $target"
        return
    }

    $id = ([Guid]::NewGuid().ToString('N')).Substring(0, 10)
    $root = Join-Path $script:RuntimeRoot "bootstrap-$id"
    $settings = Join-Path $root 'settings'
    $databases = Join-Path $root 'databases'
    $licenseDir = Join-Path $root 'license'
    foreach ($dir in @($settings, $databases, $licenseDir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    Write-PilotUtf8NoBom -LiteralPath (Join-Path $settings 'settings.xml') -Text '<Configuration></Configuration>'
    if ($license) { Copy-Item -LiteralPath $license.source -Destination (Join-Path $licenseDir "$($license.id).pilotlic") }

    $reserved = Get-ReservedPorts
    $serverPort = Find-FreePort -StartAt 25000 -Reserved $reserved
    $adminPort = Find-FreePort -StartAt 26000 -Reserved $reserved
    $network = "pilot-bootstrap-$id"
    $serverContainer = "$network-server"
    $adminContainer = "$network-admin"
    $dockerSettings = ConvertTo-DockerPath $settings
    $dockerDatabases = ConvertTo-DockerPath $databases
    $dockerLicense = ConvertTo-DockerPath $licenseDir
    $bootstrapStage = 'start-bootstrap'
    try {
        & docker network create --driver bridge $network | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Не удалось создать bootstrap-сеть.' }
        & docker run -d --name $serverContainer --network $network --hostname pilot-server --memory 1536m `
            -p "127.0.0.1:${serverPort}:5545" `
            -v "${dockerSettings}:/usr/share/ascon/pilot-server/settings" `
            -v "${dockerDatabases}:/usr/share/ascon/databases" `
            -v "${dockerLicense}:/usr/share/ASCON/Pilot Server/License:ro" `
            --entrypoint /App/Ascon.Pilot.Daemon $release.images.server /usr/share/ascon/pilot-server/settings/settings.xml | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Не удалось запустить bootstrap Pilot Server.' }
        $probe = [pscustomobject]@{ ports = [pscustomobject]@{ server = $serverPort } }
        Wait-PilotServer -Config $probe
        & docker exec $serverContainer /App/Ascon.Pilot.Daemon --admin /usr/share/ascon/pilot-server/settings/settings.xml admin admin
        if ($LASTEXITCODE -ne 0) { throw 'Не удалось создать временного администратора bootstrap-стека.' }
        & docker restart $serverContainer | Out-Null
        Wait-PilotServer -Config $probe
        & docker run -d --name $adminContainer --network $network --memory 512m `
            -p "127.0.0.1:${adminPort}:5200" `
            -e 'PilotServer:Url=http://pilot-server:5545' `
            -v "${dockerDatabases}:/usr/share/ascon/databases" $release.images.myAdmin | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Не удалось запустить bootstrap myAdmin.' }

        $bootstrapStage = 'signin-myadmin'
        $base = "http://127.0.0.1:$adminPort"
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $deadline = [DateTime]::UtcNow.AddMinutes(3)
        do {
            try {
                $auth = @{ username = 'admin'; password = 'admin' } | ConvertTo-Json -Compress
                Invoke-WebRequest "$base/api/auth/signin" -Method Post -ContentType 'application/json' -Body $auth -WebSession $session -UseBasicParsing | Out-Null
                break
            } catch {
                if ([DateTime]::UtcNow -ge $deadline) { throw "bootstrap myAdmin не готов: $($_.Exception.Message)" }
                Start-Sleep -Seconds 2
            }
        } while ($true)

        $create = [ordered]@{
            databaseName = 'pilot-bim_ru'
            databaseFileName = '/usr/share/ascon/databases/pilot-bim_ru'
            fileArchiveFolder = '/usr/share/ascon/databases/pilot-bim_ru/FileArchive'
            isFileSystemStorage = $true
            s3Folder = ''; accessKeyId = ''; secretAccessKey = ''; temporaryFolder = ''
        } | ConvertTo-Json -Compress
        $bootstrapStage = 'create-database'
        Invoke-RestMethod "$base/api/databases/CreateDatabaseState" -Method Post -ContentType 'application/json' -Body $create -WebSession $session | Out-Null
        do {
            Start-Sleep -Seconds 2
            $bootstrapStage = 'wait-database'
            $database = @(Invoke-RestMethod "$base/api/databases" -WebSession $session | Where-Object { $_.name -eq 'pilot-bim_ru' }) | Select-Object -First 1
            if ($database -and $database.state -in @(1, 'Launched')) { break }
            if ([DateTime]::UtcNow -ge $deadline) { throw 'myAdmin не завершил создание чистой базы за 3 минуты.' }
        } while ($true)

        $importBody = New-PilotConfigurationImportBody -LiteralPath $configuration
        $bootstrapStage = 'import-configuration'
        $importResult = Invoke-RestMethod "$base/api/Administrators/ImportConfiguration" -Method Post -ContentType 'application/json; charset=utf-8' -Body $importBody -WebSession $session
        $bootstrapStage = 'read-types'
        $types = @(Invoke-RestMethod "$base/api/pilot-bim_ru/types" -WebSession $session)
        $bootstrapStage = 'read-automations'
        $automations = @(Invoke-RestMethod "$base/api/pilot-bim_ru/automationscripts" -WebSession $session)
        if ($types.Count -eq 0) { throw 'После импорта официальной конфигурации список типов пуст.' }
        $bootstrapStage = 'stop-bootstrap-before-snapshot'
        & docker stop --time 60 $adminContainer $serverContainer | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Cannot stop bootstrap services before taking SQLite snapshot.' }
        foreach ($container in @($adminContainer,$serverContainer)) {
            $running = (& docker inspect --format '{{.State.Running}}' $container | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or $running -ne 'false') { throw 'Bootstrap service is still running; SQLite snapshot cancelled.' }
        }
        $createdDatabase = Get-ChildItem -LiteralPath (Join-Path $databases 'pilot-bim_ru') -File -Filter '*.dbp' |
            Where-Object { $_.Extension -ieq '.dbp' -and $_.Name -notmatch '\.(messages|journal)\.dbp$' } | Select-Object -First 1
        if (-not $createdDatabase) { throw 'myAdmin не создал основной файл *.dbp.' }

        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
        Move-Item -LiteralPath (Join-Path $databases 'pilot-bim_ru') -Destination $target
        $templateJson = [ordered]@{
            schemaVersion = 1; preparedAt = [DateTime]::UtcNow.ToString('o'); release = $release
            configurationSha256 = Get-PilotSha256 -LiteralPath $configuration
            typeCount = $types.Count; automationCount = $automations.Count; importResult = $importResult
        } | ConvertTo-Json -Depth 8
        Write-PilotUtf8NoBom -LiteralPath (Join-Path (Split-Path -Parent $target) 'template.json') -Text $templateJson
        Write-Info "Чистый BIM-ready шаблон подготовлен: $target"
    }
    catch {
        $failure = $_
        $details = if ($failure.ErrorDetails) { [string]$failure.ErrorDetails.Message } else { '' }
        if ([string]::IsNullOrWhiteSpace($details) -and $failure.Exception.PSObject.Properties['Response'] -and $failure.Exception.Response) {
            try {
                $reader = New-Object IO.StreamReader($failure.Exception.Response.GetResponseStream())
                try { $details = $reader.ReadToEnd() } finally { $reader.Dispose() }
            } catch { }
        }
        foreach ($secret in @($env:PILOT_ADMIN_PASSWORD,$env:PILOT_BIM_PASSWORD)) {
            if (-not [string]::IsNullOrEmpty($secret)) { $details = $details.Replace($secret,'***') }
        }
        if ($details.Length -gt 3000) { $details = $details.Substring(0,3000) }
        # Preserve server-side evidence before temporary containers are removed.
        $diagnosticPath = Join-Path $script:RuntimeRoot "diagnostics/bootstrap-$id"
        try {
            [void](New-Item -ItemType Directory -Path $diagnosticPath -Force)
            foreach ($container in @($serverContainer,$adminContainer)) {
                $containerLog = (& docker logs --tail 150 $container 2>&1 | Out-String)
                foreach ($secret in @($env:PILOT_ADMIN_PASSWORD,$env:PILOT_BIM_PASSWORD)) {
                    if (-not [string]::IsNullOrEmpty($secret)) { $containerLog = $containerLog.Replace($secret,'***') }
                }
                Write-PilotUtf8NoBom -LiteralPath (Join-Path $diagnosticPath "$container.log") -Text $containerLog
            }
        } catch { }
        throw "BIM template bootstrap failed at [$bootstrapStage]: $($failure.Exception.Message). HTTP response: $details. Local diagnostic logs: $diagnosticPath"
    }
    finally {
        & docker rm -f $adminContainer $serverContainer *> $null
        & docker network rm $network *> $null
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

function Assert-BimMemoryCapacity {
    param([string] $ExcludeName)
    if ([Environment]::GetEnvironmentVariable('PILOT_DISABLE_MEMORY_ADMISSION') -eq '1') {
        Write-Warning 'Проверка доступной памяти временно отключена конфигурацией хоста.'
        return
    }
    $info = & docker info --format '{{json .MemTotal}}'
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось определить лимит памяти Docker.' }
    $totalBytes = [int64]($info | ConvertFrom-Json)
    $running = 0
    if (Test-Path -LiteralPath $script:InstancesRoot) {
        Get-ChildItem -LiteralPath $script:InstancesRoot -Directory | ForEach-Object {
            $p = Join-Path $_.FullName 'instance.json'
            if (-not (Test-Path -LiteralPath $p) -or $_.Name -eq $ExcludeName) { return }
            try {
                $c = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
                if ($c.mode -eq 'bim-dev') {
                    $ids = @(& docker ps -q --filter "label=com.docker.compose.project=$($c.composeProject)")
                    if ($ids.Count -gt 0) { $running++ }
                }
            } catch { }
        }
    }
    $reservationBytes = [int64]8000000000
    $requiredBytes = ([int64]($running + 2)) * $reservationBytes
    if ($totalBytes -lt $requiredBytes) {
        throw ("Недостаточно памяти Docker: доступно {0:N2} GB; для ещё одного BIM-стенда и резерва 8 GB требуется {1:N0} GB." -f ($totalBytes / 1e9), ($requiredBytes / 1e9))
    }
}

function Test-PortAvailable {
    param([int] $Port)

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    try {
        $listener.Start()
        return $true
    }
    catch {
        return $false
    }
    finally {
        $listener.Stop()
    }
}

function Get-ReservedPorts {
    $reserved = [Collections.Generic.HashSet[int]]::new()
    if (-not (Test-Path -LiteralPath $script:InstancesRoot)) {
        return ,$reserved
    }

    Get-ChildItem -LiteralPath $script:InstancesRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $configPath = Join-Path $_.FullName 'instance.json'
        if (Test-Path -LiteralPath $configPath) {
            try {
                $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
                @($config.ports.server, $config.ports.web, $config.ports.admin) | ForEach-Object {
                    if ($_ -and [int]$_ -gt 0) { [void]$reserved.Add([int]$_) }
                }
            }
            catch {
                Write-Warning "Не удалось прочитать ${configPath}: $($_.Exception.Message)"
            }
        }
    }

    return ,$reserved
}

function Find-FreePort {
    param(
        [int] $StartAt,
        [Collections.Generic.HashSet[int]] $Reserved
    )

    foreach ($candidate in $StartAt..65535) {
        if (-not $Reserved.Contains($candidate) -and (Test-PortAvailable $candidate)) {
            [void]$Reserved.Add($candidate)
            return $candidate
        }
    }

    throw "Не удалось найти свободный TCP-порт начиная с $StartAt."
}

function Enter-PortAllocationLock {
    [void](New-Item -ItemType Directory -Path $script:InstancesRoot -Force)
    $path = Join-Path $script:InstancesRoot '.ports.lock'
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        try {
            return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Не удалось получить атомарную блокировку распределения портов за 30 секунд.' }
            Start-Sleep -Milliseconds 200
        }
    } while ($true)
}

function ConvertTo-DockerPath {
    param([string] $Path)
    ([IO.Path]::GetFullPath($Path) -replace '\\', '/')
}

function Quote-DotEnvValue {
    param([string] $Value)
    '"' + ($Value -replace '"', '\"') + '"'
}

function Write-InstanceEnvFile {
    param(
        [string] $InstancePath,
        [pscustomobject] $Config
    )

    $values = [ordered]@{
        PILOT_INSTANCE_DIR       = ConvertTo-DockerPath $InstancePath
        PILOT_SERVER_IMAGE       = [string]$Config.images.server
        PILOT_BIM_SERVER_IMAGE   = [string]$Config.images.bim
        PILOT_WEB_SERVER_IMAGE   = [string]$Config.images.web
        PILOT_WEB_MYADMIN_IMAGE  = [string]$Config.images.myAdmin
        PILOT_INGRESS_IMAGE      = [string]$Config.images.ingress
        PILOT_SERVER_PORT        = [string]$Config.ports.server
        PILOT_WEB_PORT           = [string]$Config.ports.web
        PILOT_ADMIN_PORT         = [string]$Config.ports.admin
        PILOT_DATABASE_NAME      = [string]$Config.databaseName
        PILOT_AUTH_MODE          = [string]$Config.authMode
        PILOT_SERVER_MEMORY      = if ($Config.mode -eq 'bim-dev') { '1536m' } else { '1024m' }
        PILOT_BIM_MEMORY         = '5g'
        PILOT_WEB_MEMORY         = '1g'
        PILOT_ADMIN_MEMORY       = '512m'
    }

    $lines = foreach ($entry in $values.GetEnumerator()) {
        '{0}={1}' -f $entry.Key, (Quote-DotEnvValue ([string]$entry.Value))
    }
    Write-PilotUtf8NoBom -LiteralPath (Join-Path $InstancePath '.env') -Text ($lines -join "`n")
}

function Get-ComposePrefix {
    param([pscustomobject] $Config)

    $instancePath = Get-InstancePath $Config.name
    $arguments = @(
        'compose',
        '--project-name', $Config.composeProject,
        '--file', $script:ComposeFile,
        '--env-file', (Join-Path $instancePath '.env')
    )
    $arguments += @('--profile', [string]$Config.mode)
    return $arguments
}

function Invoke-Compose {
    param(
        [pscustomobject] $Config,
        [string[]] $Arguments,
        [switch] $AllowFailure
    )

    $prefix = Get-ComposePrefix $Config
    & docker @prefix @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "docker compose завершился с кодом $exitCode."
    }
}

function Invoke-ComposeExec {
    param(
        [pscustomobject] $Config,
        [string] $TargetService,
        [string[]] $Arguments
    )

    $composeArguments = @('exec', '-T', $TargetService) + $Arguments
    [void](Invoke-Compose -Config $Config -Arguments $composeArguments)
}

function Invoke-ComposeWithRetry {
    param(
        [pscustomobject] $Config,
        [string[]] $Arguments,
        [ValidateRange(1, 10)] [int] $Attempts = 3
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Invoke-Compose -Config $Config -Arguments $Arguments
            return
        }
        catch {
            if ($attempt -eq $Attempts) { throw }
            $delay = 5 * $attempt
            Write-Warning "Docker Compose завершился ошибкой (попытка $attempt из $Attempts). Повтор через $delay с: $($_.Exception.Message)"
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-RequiredImages {
    param([pscustomobject] $Config)
    $images = @(
        [string]$Config.images.server,
        [string]$Config.images.web
    )
    if ($Config.enableBim) { $images += [string]$Config.images.bim }
    if ($Config.enableAdmin) { $images += [string]$Config.images.myAdmin }
    $images += [string]$Config.images.ingress
    return $images
}

function Install-RequiredImages {
    param(
        [pscustomobject] $Config,
        [ValidateRange(1, 10)] [int] $Attempts = 3
    )

    foreach ($image in (Get-RequiredImages -Config $Config)) {
        & docker image inspect $image *> $null
        if ($LASTEXITCODE -eq 0) { continue }

        for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
            Write-Info "Загружаю образ '$image' (попытка $attempt из $Attempts)."
            & docker pull $image
            if ($LASTEXITCODE -eq 0) { break }
            if ($attempt -eq $Attempts) {
                throw "Не удалось загрузить Docker-образ '$image' после $Attempts попыток."
            }
            $delay = 5 * $attempt
            Write-Warning "Загрузка образа прервана. Повтор через $delay с."
            Start-Sleep -Seconds $delay
        }
    }
}

function Assert-Docker {
    if (-not $script:DockerCommand) {
        throw 'Docker CLI не найден. Установите или запустите Docker Desktop.'
    }

    & docker info --format '{{.ServerVersion}}' *> $null
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker Engine недоступен. Запустите Docker Desktop и повторите команду.'
    }
}

function Wait-PilotServer {
    param(
        [pscustomobject] $Config,
        [int] $TimeoutSeconds = 180
    )

    $uri = "http://127.0.0.1:$($Config.ports.server)/"
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 3
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                return
            }
        }
        catch {
            Start-Sleep -Seconds 2
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Pilot Server не ответил на $uri за $TimeoutSeconds секунд. Проверьте логи действием Logs."
}

function Test-HttpReady {
    param([string] $Uri)
    try {
        $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 5
        return $response.StatusCode -ge 200 -and $response.StatusCode -lt 500
    }
    catch { return $false }
}

function Test-AndRecordRuntimeVersions {
    param([pscustomobject] $Config)
    $prefix = Get-ComposePrefix $Config
    $serverLogs = @(& docker @prefix logs --no-color --tail 500 pilot-server 2>&1) -join "`n"
    $bimLogs = if ($Config.mode -eq 'bim-dev') { @(& docker @prefix logs --no-color --tail 500 pilot-bim-server 2>&1) -join "`n" } else { '' }
    $serverVersion = if ($serverLogs -match 'Service is starting \((\d+\.\d+\.\d+)(?:\.\d+)?\)') { $Matches[1] } else { $null }
    $bimVersion = if ($bimLogs -match 'Product version:\s*(\d+\.\d+\.\d+)(?:\.\d+)?') { $Matches[1] } else { $null }
    $webId = @(& docker @prefix ps -q pilot-web-server 2>$null)[-1]
    $adminId = @(& docker @prefix ps -q pilot-web-myadmin 2>$null)[-1]
    $webVersion = if ($webId) {
        $text = @(& docker exec $webId sh -c "grep -o 'Ascon.Pilot.WebServer.SDK/[0-9.]*' /App/Pilot.Web.deps.json | head -1") -join ''
        if ($text -match '/(\d+\.\d+\.\d+)') { $Matches[1] } else { $null }
    } else { $null }
    $adminVersion = if ($adminId) {
        $text = @(& docker exec $adminId sh -c "grep -o 'Pilot.Web.myAdmin.Server/[0-9.]*' /App/*.deps.json | head -1") -join ''
        if ($text -match '/([0-9.]+)') { $Matches[1] } else { $null }
    } else { $null }

    if ($Config.mode -eq 'bim-dev') {
        if (-not $serverVersion -or -not $bimVersion -or -not $webVersion) { throw 'Не удалось определить версии Pilot Server, BIM Server и Pilot Web.' }
        if (@(@($serverVersion, $bimVersion, $webVersion) | Select-Object -Unique).Count -ne 1) {
            throw "Несовместимые версии core-компонентов: server=$serverVersion, bim=$bimVersion, web=$webVersion"
        }
        if (-not (Test-HttpReady "http://127.0.0.1:$($Config.ports.admin)/")) { throw 'myAdmin не прошёл compatibility smoke-test.' }
    }
    $Config.versions = [pscustomobject][ordered]@{ server = $serverVersion; bim = $bimVersion; web = $webVersion; myAdmin = $adminVersion }
    $json = $Config | ConvertTo-Json -Depth 8
    Write-PilotUtf8NoBom -LiteralPath (Join-Path (Get-InstancePath $Config.name) 'instance.json') -Text $json
}

function ConvertFrom-SecureValue {
    param(
        [Security.SecureString] $SecureValue,
        [string] $EnvironmentVariable,
        [string] $Prompt,
        [string] $DefaultValue
    )

    if (-not $SecureValue) {
        $fromEnvironment = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
        if (-not [string]::IsNullOrEmpty($fromEnvironment)) {
            return $fromEnvironment
        }
        if (-not [string]::IsNullOrEmpty($DefaultValue)) {
            return $DefaultValue
        }
        $SecureValue = Read-Host $Prompt -AsSecureString
    }

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Save-InstanceSecrets {
    param([string] $InstancePath)
    if (-not $AdminPassword -or -not $BimPassword) { return }
    $secretDir = Join-Path $InstancePath '.secrets'
    [void](New-Item -ItemType Directory -Path $secretDir -Force)
    [pscredential]::new($AdminLogin, $AdminPassword) | Export-Clixml -LiteralPath (Join-Path $secretDir 'pilot-admin.clixml')
    [pscredential]::new($BimLogin, $BimPassword) | Export-Clixml -LiteralPath (Join-Path $secretDir 'bim-service.clixml')
}

function Load-InstanceSecrets {
    param([pscustomobject] $Config)
    if ($Config.mode -ne 'bim-dev') { return }
    $secretDir = Join-Path (Get-InstancePath $Config.name) '.secrets'
    $adminSecret = Join-Path $secretDir 'pilot-admin.clixml'
    $bimSecret = Join-Path $secretDir 'bim-service.clixml'
    if (-not $script:AdminPassword -and (Test-Path -LiteralPath $adminSecret)) {
        $credential = Import-Clixml -LiteralPath $adminSecret
        $script:AdminLogin = $credential.UserName
        $script:AdminPassword = $credential.Password
    }
    if (-not $script:BimPassword -and (Test-Path -LiteralPath $bimSecret)) {
        $credential = Import-Clixml -LiteralPath $bimSecret
        $script:BimLogin = $credential.UserName
        $script:BimPassword = $credential.Password
    }
}

function Ensure-DatabaseAccount {
    param(
        [pscustomobject] $Config,
        [string] $ServerAdminLogin,
        [string] $ServerAdminPassword,
        [string] $AccountLogin,
        [string] $AccountPassword
    )

    if (-not $Config.enableAdmin) {
        Write-Warning "Нельзя автоматически создать пользователя БД '$AccountLogin': компонент myAdmin отключён."
        return $false
    }

    $adminBaseUri = "http://127.0.0.1:$($Config.ports.admin)"
    $webBaseUri = "http://127.0.0.1:$($Config.ports.web)"
    $databaseApi = "$adminBaseUri/api/$($Config.databaseName)"
    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $authBody = @{ username = $ServerAdminLogin; password = $ServerAdminPassword } | ConvertTo-Json -Compress

    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    do {
        try {
            Invoke-WebRequest "$adminBaseUri/api/auth/signin" -Method Post -ContentType 'application/json' -Body $authBody -WebSession $session -UseBasicParsing | Out-Null
            $people = Invoke-RestMethod "$databaseApi/persons" -WebSession $session
            break
        }
        catch {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "myAdmin не готов или не принял администратора '$ServerAdminLogin': $($_.Exception.Message)"
            }
            Start-Sleep -Seconds 2
        }
    } while ($true)

    $developer = $people | Where-Object { $_.login -eq $AccountLogin } | Select-Object -First 1
    $personData = [ordered]@{
        id = if ($developer) { $developer.id } else { 0 }
        login = $AccountLogin
        displayName = $AccountLogin
        password = $AccountPassword
        isAdmin = $true
        isInactive = $false
        isDeleted = $false
        comment = ''
        sid = ''
        uidDn = ''
        email = ''
        phone = ''
        allowedIp = ''
        timeZone = ''
    }

    if ($developer) {
        Invoke-RestMethod "$databaseApi/persons" -Method Patch -ContentType 'application/json' -Body ($personData | ConvertTo-Json -Depth 6 -Compress) -WebSession $session | Out-Null
    }
    else {
        $personJson = $personData | ConvertTo-Json -Depth 6 -Compress
        Invoke-RestMethod "$databaseApi/persons" -Method Put -ContentType 'application/json' -Body "[$personJson]" -WebSession $session | Out-Null
    }

    $people = Invoke-RestMethod "$databaseApi/persons" -WebSession $session
    $developer = $people | Where-Object { $_.login -eq $AccountLogin } | Select-Object -First 1
    if (-not $developer) { throw "Пользователь БД '$AccountLogin' не найден после создания." }

    $orgUnits = Invoke-RestMethod "$databaseApi/orgunits" -WebSession $session
    $position = $orgUnits | Where-Object { $_.kind -eq 1 -and $_.person -eq $developer.id } | Select-Object -First 1
    if (-not $position) {
        $position = $orgUnits | Where-Object { $_.kind -eq 1 -and $_.title -eq $AccountLogin -and $_.person -eq -1 } | Select-Object -First 1
        if (-not $position) {
            $parent = $orgUnits | Where-Object { $_.kind -eq 0 } | Select-Object -First 1
            if (-not $parent) { throw 'В БД нет подразделения, в котором можно создать должность admin.' }
            if ([int]$parent.id -eq 0) {
                $department = [ordered]@{
                    id = -1; title = 'Developers'; kind = 0; children = @(); isDeleted = $false
                    isBoss = $false; lastChange = 1; person = -1; vicePersons = @()
                    permanentVicePersons = @(); isCanceled = $false; groupPersons = @()
                }
                $departmentChangeset = @{ updated = $parent; created = $department; id = '' } | ConvertTo-Json -Depth 12 -Compress
                $departmentResult = Invoke-RestMethod "$databaseApi/orgunits" -Method Put -ContentType 'application/json' -Body $departmentChangeset -WebSession $session
                $parent = @($departmentResult.organisationUnits | Where-Object { $_.kind -eq 0 -and $_.title -eq 'Developers' } | Sort-Object id -Descending)[0]
                if (-not $parent) { throw 'Не удалось создать локальное подразделение Developers.' }
            }
            $newPosition = [ordered]@{
                id = -1; title = $AccountLogin; kind = 1; children = @(); isDeleted = $false
                isBoss = $false; lastChange = 1; person = -1; vicePersons = @()
                permanentVicePersons = @(); isCanceled = $false; groupPersons = @()
            }
            $changeset = @{ updated = $parent; created = $newPosition; id = '' } | ConvertTo-Json -Depth 12 -Compress
            $created = Invoke-RestMethod "$databaseApi/orgunits" -Method Put -ContentType 'application/json' -Body $changeset -WebSession $session
            $position = @($created.organisationUnits | Where-Object { $_.kind -eq 1 -and $_.title -eq $AccountLogin } | Sort-Object id -Descending)[0]
        }
        if (-not $position) { throw "Не удалось создать должность '$AccountLogin'." }
        $assignment = @{ positionId = $position.id; person = $developer.id; isRemoving = $false } | ConvertTo-Json -Compress
        Invoke-RestMethod "$databaseApi/orgunits/assign" -Method Post -ContentType 'application/json' -Body $assignment -WebSession $session | Out-Null
    }

    $webSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $webAuth = @{ username = $AccountLogin; password = $AccountPassword } | ConvertTo-Json -Compress
    $browserContextId = [Guid]::NewGuid().ToString()
    Invoke-WebRequest "$webBaseUri/api/Auth/SignIn?browserContextId=$browserContextId" -Method Post -ContentType 'application/json' -Body $webAuth -WebSession $webSession -UseBasicParsing | Out-Null
    Write-Info "Пользователь веб-клиента '$AccountLogin' готов."
    return $true
}

function Initialize-BimConnection {
    param(
        [pscustomobject] $Config,
        [string] $Login,
        [string] $Password
    )

    if (-not $Config.enableBim) { return $false }

    $settingsPath = Join-Path (Get-InstancePath $Config.name) 'bim\settings.xml'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        Write-Info "Подключаю Pilot-BIM-Server к БД '$($Config.databaseName)' под '$Login'."
        Invoke-ComposeExec -Config $Config -TargetService 'pilot-bim-server' -Arguments @(
            './pBimAdmin',
            '-c',
            "http://pilot-server:5545/$($Config.databaseName)",
            $Login,
            $Password
        )
        [void](Invoke-Compose -Config $Config -Arguments @('restart', 'pilot-bim-server'))
    }

    $prefix = Get-ComposePrefix $Config
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        Start-Sleep -Seconds 2
        $logLines = @(& docker @prefix 'logs' '--no-color' '--tail' '200' 'pilot-bim-server' 2>&1)
        $logText = $logLines -join [Environment]::NewLine
        if ($logText -match 'OverflowCountServerLicenseException|Exceeded max license limit') {
            Write-Warning 'Pilot-BIM-Server не может работать: отсутствует доступная лицензия Pilot-BIM Server (продукт 91).'
            return $false
        }

        $stateMessages = @($logLines | Where-Object { $_ -match 'Connection state message:' })
        $lastState = if ($stateMessages.Count -gt 0) { [string]$stateMessages[-1] } else { '' }
        if ($lastState -match 'Success connection to database') {
            Write-Info 'Pilot-BIM-Server подключён и не сообщает об ошибке лицензии.'
            return $true
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    Write-Warning "Pilot-BIM-Server не перешёл в online. Последнее состояние: $lastState"
    return $false
}

function Test-SettingsContains {
    param(
        [pscustomobject] $Config,
        [string] $Pattern
    )

    $settingsPath = Join-Path (Get-InstancePath $Config.name) 'server\settings\settings.xml'
    if (-not (Test-Path -LiteralPath $settingsPath)) { return $false }
    return [bool](Select-String -LiteralPath $settingsPath -SimpleMatch -Pattern $Pattern -Quiet)
}

function Attach-InstanceDatabase {
    param([pscustomobject] $Config, [string] $DatabaseFileName, [string] $ArchiveFileName)
    if ([IO.Path]::GetExtension($DatabaseFileName) -ine '.dbp' -or $DatabaseFileName -match '\.(messages|journal)\.dbp$') {
        throw "Refusing to attach a SQLite auxiliary file as main database: $DatabaseFileName"
    }
    $containerRoot = "/usr/share/ascon/databases/$($Config.databaseName)"
    $databaseFile = "$containerRoot/$DatabaseFileName"
    $archiveFile = "$containerRoot/FileArchive/$ArchiveFileName"
    $prefix = Get-ComposePrefix $Config
    foreach ($path in @($databaseFile,$archiveFile)) {
        & docker @prefix exec -T pilot-server test -r $path
        if ($LASTEXITCODE -ne 0) { throw "Database attach preflight: file is not readable inside pilot-server: $path" }
    }
    & docker @prefix exec -T pilot-server test -w $containerRoot
    if ($LASTEXITCODE -ne 0) { throw "Database attach preflight: SQLite directory is not writable inside pilot-server: $containerRoot" }
    $output = (& docker @prefix exec -T pilot-server ./Ascon.Pilot.Daemon --attach $Config.databaseName $databaseFile $archiveFile 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or $output -match 'CantOpen|unable to open database|Connect failed|attachment failed') {
        throw "Database attach failed (exit $exitCode). Database: $databaseFile; archive: $archiveFile. Server response: $output"
    }
    if (-not (Test-SettingsContains -Config $Config -Pattern ('Name="{0}"' -f $Config.databaseName))) {
        throw "Database attach did not register the database in settings.xml. Database: $databaseFile; archive: $archiveFile. Server response: $output"
    }
}

function Initialize-Instance {
    param([pscustomobject] $Config)

    $instancePath = Get-InstancePath $Config.name
    $statePath = Join-Path $instancePath 'initialized.json'
    Wait-PilotServer -Config $Config

    if (Test-Path -LiteralPath $statePath) {
        $existingState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($existingState.databaseAttached -and $existingState.databaseAccountReady -and
            ($Config.mode -ne 'bim-dev' -or $existingState.bimReady)) {
            Write-Info 'Стенд уже инициализирован; сохранённые сервером настройки используются без повторного ввода паролей.'
            return
        }
    }

    if (-not (Test-SettingsContains -Config $Config -Pattern '<ServerAdministrator')) {
        $defaultAdminPassword = if ($Config.mode -eq 'ice-dev') { 'admin' } else { $null }
        $password = ConvertFrom-SecureValue -SecureValue $AdminPassword -EnvironmentVariable 'PILOT_ADMIN_PASSWORD' -Prompt "Пароль администратора Pilot Server '$AdminLogin'" -DefaultValue $defaultAdminPassword
        if ([string]::IsNullOrWhiteSpace($password)) { throw 'Пароль администратора Pilot Server не может быть пустым.' }
        try {
            Write-Info "Создаю администратора Pilot Server '$AdminLogin'."
            Invoke-ComposeExec -Config $Config -TargetService 'pilot-server' -Arguments @(
                './Ascon.Pilot.Daemon',
                '--admin',
                '/usr/share/ascon/pilot-server/settings/settings.xml',
                $AdminLogin,
                $password
            )
        }
        finally {
            $password = $null
        }
        [void](Invoke-Compose -Config $Config -Arguments @('restart', 'pilot-server'))
        Wait-PilotServer -Config $Config
    }

    $databasePath = Join-Path $instancePath "databases\$($Config.databaseName)"
    if (Test-Path -LiteralPath $databasePath -PathType Container) {
        if (-not (Test-SettingsContains -Config $Config -Pattern ('Name="{0}"' -f $Config.databaseName))) {
            $baseFile = Get-ChildItem -LiteralPath $databasePath -File -Filter '*.dbp' |
                Where-Object { $_.Extension -ieq '.dbp' -and $_.Name -notmatch '\.(messages|journal)\.dbp$' } | Select-Object -First 1
            $marker = Get-ChildItem -LiteralPath (Join-Path $databasePath 'FileArchive') -File -Filter '*.pilotfa' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $baseFile -or -not $marker) {
                throw "Шаблон БД '$databasePath' должен содержать основной *.dbp и маркер FileArchive/*.pilotfa."
            }

            Write-Info "Подключаю изолированную копию БД '$($Config.databaseName)'."
            Attach-InstanceDatabase -Config $Config -DatabaseFileName $baseFile.Name -ArchiveFileName $marker.Name
            [void](Invoke-Compose -Config $Config -Arguments @('restart', 'pilot-server'))
            Wait-PilotServer -Config $Config
        }
    }
    else {
        Write-Warning "БД '$($Config.databaseName)' не скопирована. Pilot Web запущен, но работать с БД начнёт только после её добавления."
    }

    $databaseAttached = Test-SettingsContains -Config $Config -Pattern ('Name="{0}"' -f $Config.databaseName)
    $databaseAccountReady = $false
    $bimPasswordValue = $null
    if ($databaseAttached) {
        $defaultAdminPassword = if ($Config.mode -eq 'ice-dev') { 'admin' } else { $null }
        $password = ConvertFrom-SecureValue -SecureValue $AdminPassword -EnvironmentVariable 'PILOT_ADMIN_PASSWORD' -Prompt "Пароль администратора Pilot Server '$AdminLogin'" -DefaultValue $defaultAdminPassword
        try {
            if ($Config.mode -eq 'ice-dev') {
                $databaseAccountReady = Ensure-DatabaseAccount -Config $Config -ServerAdminLogin $AdminLogin -ServerAdminPassword $password -AccountLogin 'admin' -AccountPassword 'admin'
            }
            else {
                $bimPasswordValue = ConvertFrom-SecureValue -SecureValue $BimPassword -EnvironmentVariable 'PILOT_BIM_PASSWORD' -Prompt "Пароль пользователя Pilot BIM '$BimLogin'"
                if ([string]::IsNullOrWhiteSpace($bimPasswordValue)) { throw 'Пароль пользователя Pilot BIM не может быть пустым.' }
                $databaseAccountReady = Ensure-DatabaseAccount -Config $Config -ServerAdminLogin $AdminLogin -ServerAdminPassword $password -AccountLogin $BimLogin -AccountPassword $bimPasswordValue
            }
        }
        finally {
            $password = $null
        }
    }
    $bimReady = if ($Config.mode -eq 'bim-dev' -and $databaseAccountReady) {
        Initialize-BimConnection -Config $Config -Login $BimLogin -Password $bimPasswordValue
    } else { $false }
    $bimPasswordValue = $null

    $stateJson = [ordered]@{
        initializedAt = [DateTime]::UtcNow.ToString('o')
        adminLogin = $AdminLogin
        databaseAttached = $databaseAttached
        mode = $Config.mode
        databaseAccountLogin = if ($Config.mode -eq 'ice-dev') { 'admin' } else { $BimLogin }
        databaseAccountReady = $databaseAccountReady
        bimReady = $bimReady
    } | ConvertTo-Json
    Write-PilotUtf8NoBom -LiteralPath $statePath -Text $stateJson
    if ($Config.mode -eq 'bim-dev' -and -not $bimReady) {
        throw 'Pilot-BIM Server не перешёл в рабочее состояние. Проверьте лицензию и логи BIM-dev стенда.'
    }
}

function New-Instance {
    Assert-Name
    if ([string]::IsNullOrWhiteSpace($Mode)) {
        throw 'Для нового стенда обязателен режим -Mode ice-dev или -Mode bim-dev.'
    }
    $licenseMetadata = $null
    if (($PublicWebPort -eq 0) -xor ($PublicAdminPort -eq 0)) {
        throw 'Публичные Web и myAdmin порты должны передаваться только парой.'
    }
    if ($PublicWebPort -gt 0 -and $PublicWebPort -eq $PublicAdminPort) {
        throw 'Публичные Web и myAdmin порты должны различаться.'
    }
    if ($Mode -eq 'ice-dev') {
        if ($DatabaseName -eq 'pilot-bim_ru') { $DatabaseName = 'pilot-ice_ru' }
        if (-not [string]::IsNullOrWhiteSpace($LicenseFile)) { throw 'ice-dev не принимает лицензию Pilot-BIM.' }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($LicenseFile)) { throw 'bim-dev при создании требует -LicenseFile или PILOT_LICENSE_FILE.' }
        $licenseMetadata = Get-LicenseMetadata -Path $LicenseFile
        $adminPasswordAvailable = ($AdminPassword -and $AdminPassword.Length -gt 0) -or -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('PILOT_ADMIN_PASSWORD'))
        $bimPasswordAvailable = ($BimPassword -and $BimPassword.Length -gt 0) -or -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('PILOT_BIM_PASSWORD'))
        if ($Start -and -not $adminPasswordAvailable) { throw 'Первый запуск bim-dev требует непустой -AdminPassword или PILOT_ADMIN_PASSWORD.' }
        if ($Start -and -not $bimPasswordAvailable) { throw 'Первый запуск bim-dev требует непустой -BimPassword или PILOT_BIM_PASSWORD.' }
    }
    $instancePath = Get-InstancePath $Name
    if (Test-Path -LiteralPath $instancePath) {
        throw "Стенд '$Name' уже существует: $instancePath"
    }

    Assert-Docker
    $release = if ($script:ReleaseOverride) {
        $script:ReleaseOverride
    } elseif (Test-Path -LiteralPath (Get-ReleaseLockPath)) {
        Get-Content -LiteralPath (Get-ReleaseLockPath) -Raw | ConvertFrom-Json
    } else {
        Get-ReleaseSet -Refresh
    }
    $portLock = Enter-PortAllocationLock
    $reserved = Get-ReservedPorts
    if ($ServerPort -eq 0) { $ServerPort = Find-FreePort -StartAt 15545 -Reserved $reserved }
    elseif (-not (Test-PortAvailable $ServerPort) -or $reserved.Contains($ServerPort)) { throw "Порт $ServerPort занят или уже назначен другому стенду." }
    else { [void]$reserved.Add($ServerPort) }

    if ($WebPort -eq 0) { $WebPort = Find-FreePort -StartAt 18080 -Reserved $reserved }
    elseif (-not (Test-PortAvailable $WebPort) -or $reserved.Contains($WebPort)) { throw "Порт $WebPort занят или уже назначен другому стенду." }
    else { [void]$reserved.Add($WebPort) }

    if ($AdminPort -eq 0) { $AdminPort = Find-FreePort -StartAt 15200 -Reserved $reserved }
    elseif (-not (Test-PortAvailable $AdminPort) -or $reserved.Contains($AdminPort)) { throw "Порт $AdminPort занят или уже назначен другому стенду." }

    $config = [pscustomobject][ordered]@{
        schemaVersion = 4
        mode = $Mode
        name = $Name
        composeProject = "pilot-$Name"
        createdAt = [DateTime]::UtcNow.ToString('o')
        releaseResolvedAt = $release.resolvedAt
        images = $release.images
        versions = [pscustomobject][ordered]@{ server = $null; bim = $null; web = $null; myAdmin = $null }
        databaseName = $DatabaseName
        authMode = $AuthMode
        product = if ($Mode -eq 'ice-dev') { 'Pilot-ICE' } else { 'Pilot-BIM' }
        publishAddress = '127.0.0.1'
        pilotServerUrl = 'http://pilot-server:5545'
        memoryLimitGiB = if ($Mode -eq 'bim-dev') { 8 } else { 3 }
        disposable = $true
        enableBim = $Mode -eq 'bim-dev'
        enableAdmin = $true
        license = if ($licenseMetadata) { [pscustomobject][ordered]@{
            id = $licenseMetadata.id
            sha256 = $licenseMetadata.sha256
            updatesValidTo = $licenseMetadata.updatesValidTo
            signatureCheck = $licenseMetadata.signatureCheck
            products = $licenseMetadata.products
        } } else { $null }
        ports = [pscustomobject][ordered]@{
            server = $ServerPort
            web = $WebPort
            admin = $AdminPort
        }
        publicPorts = if ($PublicWebPort -gt 0) { [pscustomobject][ordered]@{
            web = $PublicWebPort
            admin = $PublicAdminPort
        } } else { $null }
    }

    if ($Mode -eq 'bim-dev' -and [string]::IsNullOrWhiteSpace($DatabaseTemplate)) {
        $DatabaseTemplate = Get-ReleaseTemplatePath -Release $release
        $templateMain = Get-ChildItem -LiteralPath $DatabaseTemplate -File -Filter '*.dbp' -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -ieq '.dbp' -and $_.Name -notmatch '\.(messages|journal)\.dbp$' } | Select-Object -First 1
        if (-not $templateMain) {
            throw "Для release ещё нет BIM-ready шаблона. Сначала выполните PrepareTemplate с официальным .pilotcfx: $DatabaseTemplate"
        }
    }
    $resolvedTemplate = $null
    if (-not [string]::IsNullOrWhiteSpace($DatabaseTemplate)) {
        $resolvedTemplate = (Resolve-Path -LiteralPath $DatabaseTemplate).Path
        if (-not (Test-Path -LiteralPath $resolvedTemplate -PathType Container)) {
            throw "Каталог шаблона БД не найден: $DatabaseTemplate"
        }
        $templateMain = Get-ChildItem -LiteralPath $resolvedTemplate -File -Filter '*.dbp' |
            Where-Object { $_.Extension -ieq '.dbp' -and $_.Name -notmatch '\.(messages|journal)\.dbp$' } | Select-Object -First 1
        if (-not $templateMain) {
            throw "В шаблоне БД отсутствует основной *.dbp: $resolvedTemplate"
        }
    }

    $resolvedLicense = if ($licenseMetadata) { $licenseMetadata.source } else { $null }

    if (-not $PSCmdlet.ShouldProcess($instancePath, 'Создать изолированный стенд Pilot')) { return }

    try {
        $directories = @(
            'aspnet\pilot-server',
            'aspnet\pilot-bim-server',
            'bim',
            'databases',
            'ingress',
            'license',
            'logs\pilot-server',
            'logs\pilot-bim-server',
            'server\settings'
        )
        foreach ($directory in $directories) {
            [void](New-Item -ItemType Directory -Path (Join-Path $instancePath $directory) -Force)
        }
        if ($Mode -eq 'bim-dev') { Save-InstanceSecrets -InstancePath $instancePath }

        Write-PilotUtf8NoBom -LiteralPath (Join-Path $instancePath 'server\settings\settings.xml') -Text '<Configuration></Configuration>'
        [void](Update-InstanceIngressConfig -Config $config)

        if ($resolvedTemplate) {
            $installedRoot = [IO.Path]::GetFullPath('C:\ProgramData\ASCON\Pilot Server\Databases')
            if ($resolvedTemplate.StartsWith($installedRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $service = Get-Service -Name 'PilotServer' -ErrorAction SilentlyContinue
                if ($service -and $service.Status -eq 'Running') {
                    Write-Warning 'Исходная Windows-служба PilotServer запущена. Для гарантированно согласованной копии остановите её или используйте заранее подготовленный backup БД.'
                }
            }

            Write-Info "Копирую шаблон БД из '$resolvedTemplate'."
            Copy-Item -LiteralPath $resolvedTemplate -Destination (Join-Path $instancePath "databases\$DatabaseName") -Recurse
        }

        if ($resolvedLicense) {
            Copy-Item -LiteralPath $resolvedLicense -Destination (Join-Path $instancePath "license\$($licenseMetadata.id).pilotlic")
        }

        $json = $config | ConvertTo-Json -Depth 5
        Write-PilotUtf8NoBom -LiteralPath (Join-Path $instancePath 'instance.json') -Text $json
        Write-InstanceEnvFile -InstancePath $instancePath -Config $config
    }
    catch {
        if (Test-Path -LiteralPath $instancePath) {
            Remove-Item -LiteralPath $instancePath -Recurse -Force
        }
        throw
    }
    finally {
        if ($portLock) { $portLock.Dispose() }
    }

    $publicMessage = if ($PublicWebPort -gt 0) { ", public Web :$PublicWebPort, public Admin :$PublicAdminPort" } else { '' }
    Write-Info "Стенд '$Name' ($($config.product)) создан. Pilot: http://127.0.0.1:$ServerPort, Web: http://127.0.0.1:$WebPort, Admin: http://127.0.0.1:$AdminPort$publicMessage"
    if ($Start) {
        Start-Instance -Config $config
    }
}

function Update-InstanceIngressConfig {
    param([pscustomobject] $Config)
    $source = Join-Path $script:EngineRoot 'ingress/instance-nginx.conf'
    $target = Join-Path (Get-InstancePath $Config.name) 'ingress/nginx.conf'
    $desired = [IO.File]::ReadAllText($source)
    if ((Test-Path -LiteralPath $target) -and [IO.File]::ReadAllText($target) -ceq $desired) { return $false }
    Write-PilotUtf8NoBom -LiteralPath $target -Text $desired
    return $true
}

function Start-Instance {
    param([pscustomobject] $Config)
    if ($Config.mode -eq 'bim-dev') {
        $licenseFiles = @(Get-ChildItem -LiteralPath (Join-Path (Get-InstancePath $Config.name) 'license') -File -Filter '*.pilotlic' -ErrorAction SilentlyContinue)
        if ($licenseFiles.Count -eq 0) { throw "BIM-dev стенд '$($Config.name)' не содержит локальную копию .pilotlic." }
        $actualHash = (Get-PilotSha256 -LiteralPath $licenseFiles[0].FullName).ToUpperInvariant()
        if ($actualHash -ne $Config.license.sha256) { throw 'Локальная копия лицензии повреждена: SHA-256 не совпадает с instance.json.' }
        Assert-BimMemoryCapacity -ExcludeName $Config.name
        Load-InstanceSecrets -Config $Config
    }
    Assert-Docker
    Write-Info "Запускаю стенд '$($Config.name)' по закреплённым immutable digest."
    Install-RequiredImages -Config $Config -Attempts 3
    $ingressChanged = Update-InstanceIngressConfig -Config $Config
    Invoke-ComposeWithRetry -Config $Config -Arguments @('up', '-d', '--remove-orphans', '--pull', 'never') -Attempts 3
    if ($ingressChanged) {
        Invoke-ComposeExec -Config $Config -TargetService 'pilot-ingress' -Arguments @('nginx','-t')
        Invoke-ComposeExec -Config $Config -TargetService 'pilot-ingress' -Arguments @('nginx','-s','reload')
    }
    Initialize-Instance -Config $Config
    if ($Config.mode -eq 'bim-dev') { Ensure-StartedBimReady -Config $Config }
    Test-AndRecordRuntimeVersions -Config $Config
    if ($Config.mode -eq 'bim-dev' -and -not (Test-Path -LiteralPath (Get-ReleaseLockPath))) {
        Save-ReleaseAsKnownGood -Release ([pscustomobject]@{ resolvedAt = $Config.releaseResolvedAt; tag = 'release'; images = $Config.images })
    }
    Write-Info "Стенд готов: Web http://127.0.0.1:$($Config.ports.web), Pilot Server http://127.0.0.1:$($Config.ports.server)"
}

function Connect-BimInstance {
    param([pscustomobject] $Config)
    if ($Config.mode -ne 'bim-dev') { throw "ConnectBim разрешён только для BIM-dev стендов." }
    Assert-Docker

    $password = ConvertFrom-SecureValue -SecureValue $BimPassword -EnvironmentVariable 'PILOT_BIM_PASSWORD' -Prompt "Пароль пользователя Pilot BIM '$BimLogin'"
    try {
        Invoke-ComposeExec -Config $Config -TargetService 'pilot-bim-server' -Arguments @(
            './pBimAdmin',
            '-c',
            "http://pilot-server:5545/$($Config.databaseName)",
            $BimLogin,
            $password
        )
    }
    finally {
        $password = $null
    }

    [void](Invoke-Compose -Config $Config -Arguments @('restart', 'pilot-bim-server'))
    Write-Info "Pilot-BIM-Server подключён к БД '$($Config.databaseName)'."
}

function Get-ComponentStatus {
    param([pscustomobject] $Config, [string] $Component)
    $prefix = Get-ComposePrefix $Config
    $id = [string](@(& docker @prefix ps -q $Component 2>$null) | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($id)) {
        return [pscustomobject][ordered]@{
            name = $Component; state = 'stopped'; healthy = $false; containerId = $null
            restartCount = 0; startedAt = $null; lastError = $null
        }
    }
    try {
        $container = (& docker inspect $id --format '{{json .}}' 2>$null | ConvertFrom-Json)
        $containerState = $container.State
        $running = [string]$containerState.Status -eq 'running'
        $healthy = $running
        if ($running) {
            switch ($Component) {
                'pilot-server' { $healthy = Test-HttpReady "http://127.0.0.1:$($Config.ports.server)/" }
                'pilot-web-server' { $healthy = Test-HttpReady "http://127.0.0.1:$($Config.ports.web)/" }
                'pilot-web-myadmin' { $healthy = Test-HttpReady "http://127.0.0.1:$($Config.ports.admin)/" }
                'pilot-bim-server' {
                    $logs = Get-CurrentBimLogs -Config $Config
                    $healthy = Test-BimLogOnline -Logs $logs
                }
            }
        }
        [pscustomobject][ordered]@{
            name = $Component
            state = [string]$containerState.Status
            healthy = [bool]$healthy
            containerId = $id
            restartCount = [int]$container.RestartCount
            startedAt = if ($containerState.StartedAt -and $containerState.StartedAt -ne '0001-01-01T00:00:00Z') { ([DateTimeOffset]$containerState.StartedAt).ToString('o') } else { $null }
            lastError = if ([string]::IsNullOrWhiteSpace([string]$containerState.Error)) { $null } else { [string]$containerState.Error }
        }
    }
    catch {
        [pscustomobject][ordered]@{
            name = $Component; state = 'unknown'; healthy = $false; containerId = $id
            restartCount = 0; startedAt = $null; lastError = $_.Exception.Message
        }
    }
}

function Get-StatusSnapshot {
    param([pscustomobject] $Config)
    $dockerReady = $false
    if ($script:DockerCommand) {
        & docker info --format '{{.ServerVersion}}' *> $null
        $dockerReady = $LASTEXITCODE -eq 0
    }
    $expected = if ($Config.mode -eq 'bim-dev') {
        @('pilot-server','pilot-bim-server','pilot-web-server','pilot-web-myadmin')
    } else {
        @('pilot-server','pilot-web-server','pilot-web-myadmin')
    }
    $components = if ($dockerReady) {
        @($expected | ForEach-Object { Get-ComponentStatus -Config $Config -Component $_ } |
            Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['name'] })
    } else { @() }
    $running = @($components | Where-Object { $_.state -eq 'running' }).Count
    $healthy = @($components | Where-Object { $_.healthy }).Count
    $state = if (-not $dockerReady) { 'failed' }
        elseif ($running -eq 0) { 'stopped' }
        elseif ($healthy -eq $expected.Count) { 'running' }
        else { 'degraded' }
    $lastError = if (-not $dockerReady) { 'Docker Engine недоступен.' }
        else {
            $failedComponent = $components | Where-Object { $_.PSObject.Properties['lastError'] -and $_.lastError } | Select-Object -First 1
            if ($failedComponent) { [string]$failedComponent.lastError } else { $null }
        }
    [pscustomobject][ordered]@{
        name = $Config.name
        mode = $Config.mode
        product = $Config.product
        state = $state
        webPort = [int]$Config.ports.web
        adminPort = [int]$Config.ports.admin
        serverPort = [int]$Config.ports.server
        publicPorts = $Config.publicPorts
        images = $Config.images
        versions = $Config.versions
        components = @($components)
        lastError = if ([string]::IsNullOrWhiteSpace($lastError)) { $null } else { $lastError }
    }
}

function Get-CapacitySnapshot {
    $minimumDiskGiB = 20.0
    $configuredMinimum = [Environment]::GetEnvironmentVariable('PILOT_MIN_FREE_DISK_GIB')
    if (-not [string]::IsNullOrWhiteSpace($configuredMinimum)) { $minimumDiskGiB = [double]::Parse($configuredMinimum, [Globalization.CultureInfo]::InvariantCulture) }
    $perEnvironmentGiB = 8.0
    $safetyReserveGiB = 8.0
    $blockers = [Collections.Generic.List[object]]::new()
    $dockerReady = $false
    $totalGiB = 0.0
    if ($script:DockerCommand) {
        $raw = & docker info --format '{{json .MemTotal}}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $totalGiB = [double]([int64]($raw | ConvertFrom-Json)) / 1GB
            $dockerReady = $true
        }
    }
    if (-not $dockerReady) { $blockers.Add([pscustomobject]@{ code='docker_unavailable'; message='Docker Engine недоступен.' }) }

    $runningNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($dockerReady -and (Test-Path -LiteralPath $script:InstancesRoot)) {
        Get-ChildItem -LiteralPath $script:InstancesRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $path = Join-Path $_.FullName 'instance.json'
            if (-not (Test-Path -LiteralPath $path)) { return }
            try {
                $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                if ($config.mode -eq 'bim-dev') {
                    $ids = @(& docker ps -q --filter "label=com.docker.compose.project=$($config.composeProject)" 2>$null)
                    if ($ids.Count -gt 0) { [void]$runningNames.Add([string]$config.name) }
                }
            } catch { }
        }
    }
    $reservedGiB = $runningNames.Count * $perEnvironmentGiB
    $memoryAdmissionDisabled = [Environment]::GetEnvironmentVariable('PILOT_DISABLE_MEMORY_ADMISSION') -eq '1'
    $availableSlots = if ($memoryAdmissionDisabled -and $dockerReady) { 2147483647 } elseif ($dockerReady) { [math]::Max(0, [math]::Floor(($totalGiB - $safetyReserveGiB - $reservedGiB) / $perEnvironmentGiB)) } else { 0 }
    if (-not $memoryAdmissionDisabled -and $dockerReady -and $availableSlots -lt 1) { $blockers.Add([pscustomobject]@{ code='insufficient_memory'; message='Недостаточно памяти Docker для ещё одного BIM-стенда и резерва 8 ГБ.' }) }

    [void](New-Item -ItemType Directory -Path $script:InstancesRoot -Force)
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($script:InstancesRoot)))
    $freeDiskGiB = [double]$drive.AvailableFreeSpace / 1GB
    if ($freeDiskGiB -lt $minimumDiskGiB) { $blockers.Add([pscustomobject]@{ code='insufficient_disk'; message="Свободно менее $minimumDiskGiB ГБ на диске стендов." }) }

    $portsReady = $true
    try {
        $reservedPorts = Get-ReservedPorts
        [void](Find-FreePort -StartAt 15545 -Reserved $reservedPorts)
        [void](Find-FreePort -StartAt 18080 -Reserved $reservedPorts)
        [void](Find-FreePort -StartAt 15200 -Reserved $reservedPorts)
    }
    catch {
        $portsReady = $false
        $blockers.Add([pscustomobject]@{ code='ports_unavailable'; message=$_.Exception.Message })
    }

    $licenseReady = $false
    if (-not [string]::IsNullOrWhiteSpace($LicenseFile) -and (Test-Path -LiteralPath $LicenseFile -PathType Leaf)) {
        try { [void](Get-LicenseMetadata -Path $LicenseFile); $licenseReady = $true } catch { $blockers.Add([pscustomobject]@{ code='license_invalid'; message=$_.Exception.Message }) }
    }
    if (-not $licenseReady -and -not @($blockers | Where-Object code -eq 'license_invalid').Count) { $blockers.Add([pscustomobject]@{ code='license_missing'; message='Хостовая лицензия API не настроена.' }) }

    $releaseReady = Test-Path -LiteralPath (Get-ReleaseLockPath)
    $templateReady = $false
    if ($releaseReady) {
        try {
            $release = Get-Content -LiteralPath (Get-ReleaseLockPath) -Raw | ConvertFrom-Json
            $template = Get-ReleaseTemplatePath -Release $release
            $templateReady = @(Get-ChildItem -LiteralPath $template -File -Filter '*.dbp' -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq '.dbp' -and $_.Name -notmatch '\.(messages|journal)\.dbp$' }).Count -gt 0
        } catch { }
    }
    if (-not $releaseReady) { $blockers.Add([pscustomobject]@{ code='release_missing'; message='Нет проверенного last-known-good release.' }) }
    elseif (-not $templateReady) { $blockers.Add([pscustomobject]@{ code='template_missing'; message='Нет BIM-ready шаблона для активного release.' }) }

    [pscustomobject][ordered]@{
        canStart = $dockerReady -and $licenseReady -and $releaseReady -and $templateReady -and $portsReady -and $availableSlots -gt 0 -and $freeDiskGiB -ge $minimumDiskGiB
        availableSlots = [int]$availableSlots
        blockers = @($blockers)
        memory = [pscustomobject][ordered]@{ dockerTotalGiB=$totalGiB; reservedGiB=$reservedGiB; safetyReserveGiB=$safetyReserveGiB; perEnvironmentGiB=$perEnvironmentGiB }
        disk = [pscustomobject][ordered]@{ freeGiB=$freeDiskGiB; minimumFreeGiB=$minimumDiskGiB }
        prerequisites = [pscustomobject][ordered]@{ dockerReady=$dockerReady; licenseReady=$licenseReady; releaseReady=$releaseReady; templateReady=$templateReady }
    }
}

function Get-CurrentBimLogs {
    param([pscustomobject] $Config)
    $prefix = Get-ComposePrefix $Config
    $id = [string](@(& docker @prefix ps -q pilot-bim-server 2>$null) | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($id)) { return '' }
    $startedAt = [string](& docker inspect $id --format '{{.State.StartedAt}}' 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($startedAt)) { throw 'Cannot inspect the current BIM container launch.' }
    # Old successful connections must not make a later offline launch healthy.
    return (@(& docker @prefix logs --no-color --since $startedAt.Trim() pilot-bim-server 2>&1) -join "`n")
}

function Test-BimLogOnline {
    param([string] $Logs)
    $online = [regex]::Matches($Logs, 'Success connection to database')
    if ($online.Count -eq 0) { return $false }
    if ($Logs -match 'OverflowCountServerLicenseException|Exceeded max license limit|LicenseNotFound|InvalidLicense') { return $false }
    $offline = [regex]::Matches($Logs, 'Force offline|Pilot-BIM-Server is already offline|PilotServerOfflineException')
    return $offline.Count -eq 0 -or $online[$online.Count - 1].Index -gt $offline[$offline.Count - 1].Index
}

function Ensure-StartedBimReady {
    param([pscustomobject] $Config, [int] $TimeoutSeconds = 180)
    # An HTTP-ready Pilot Server may still be initializing the database.
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try { Test-WebDatabaseLogin -Config $Config; break }
        catch {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Pilot database login did not become ready after Start.' }
            Start-Sleep -Seconds 2
        }
    } while ($true)
    $logs = Get-CurrentBimLogs -Config $Config
    if ($logs -match 'OverflowCountServerLicenseException|Exceeded max license limit|LicenseNotFound|InvalidLicense') { throw 'Pilot-BIM Server reported a license error after Start.' }
    if (-not (Test-BimLogOnline -Logs $logs)) {
        Write-Info 'Database login is ready; restarting the offline BIM component only.'
        [void](Invoke-Compose -Config $Config -Arguments @('restart', 'pilot-bim-server'))
    }
    Wait-BimComponent -Config $Config -TimeoutSeconds $TimeoutSeconds
}

function Wait-BimComponent {
    param([pscustomobject] $Config, [int] $TimeoutSeconds = 180)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $prefix = Get-ComposePrefix $Config
    do {
        $logs = Get-CurrentBimLogs -Config $Config
        if ($logs -match 'OverflowCountServerLicenseException|Exceeded max license limit|LicenseNotFound|InvalidLicense') { throw 'Pilot-BIM Server сообщил об ошибке лицензии после перезапуска.' }
        if (Test-BimLogOnline -Logs $logs) { return }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Pilot-BIM Server не перешёл в online после перезапуска.'
}

function Test-WebDatabaseLogin {
    param([pscustomobject] $Config)
    $password = ConvertFrom-SecureValue -SecureValue $BimPassword -EnvironmentVariable 'PILOT_BIM_PASSWORD' -Prompt "Пароль пользователя '$BimLogin'"
    try {
        $body = @{ username=$BimLogin; password=$password } | ConvertTo-Json -Compress
        $response = Invoke-WebRequest "http://127.0.0.1:$($Config.ports.web)/api/Auth/SignIn?browserContextId=$([Guid]::NewGuid())" -Method Post -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 15
        if ($response.StatusCode -ne 200) { throw "Pilot Web login вернул HTTP $($response.StatusCode)." }
    }
    finally { $password = $null }
}

function Restart-InstanceComponent {
    param([pscustomobject] $Config)
    if ([string]::IsNullOrWhiteSpace($Service)) { throw 'Для RestartComponent обязателен -Service.' }
    if ($Config.mode -ne 'bim-dev') { throw 'API-перезапуск компонентов разрешён только для bim-dev.' }
    Assert-Docker
    Load-InstanceSecrets -Config $Config
    [void](Invoke-Compose -Config $Config -Arguments @('restart', $Service))
    switch ($Service) {
        'pilot-server' {
            Wait-PilotServer -Config $Config
            if ($Cascade) {
                foreach ($dependent in @('pilot-bim-server','pilot-web-server','pilot-web-myadmin')) {
                    [void](Invoke-Compose -Config $Config -Arguments @('restart', $dependent))
                    if ($dependent -eq 'pilot-bim-server') { Wait-BimComponent -Config $Config }
                    elseif ($dependent -eq 'pilot-web-server') { Wait-PilotServer -Config ([pscustomobject]@{ ports=[pscustomobject]@{ server=$Config.ports.web } }); Test-WebDatabaseLogin -Config $Config }
                    else {
                        $deadline=[DateTime]::UtcNow.AddMinutes(3)
                        while (-not (Test-HttpReady "http://127.0.0.1:$($Config.ports.admin)/")) { if ([DateTime]::UtcNow -ge $deadline) { throw 'myAdmin не готов после перезапуска.' }; Start-Sleep -Seconds 2 }
                    }
                }
            }
        }
        'pilot-bim-server' { Wait-BimComponent -Config $Config }
        'pilot-web-server' {
            $deadline=[DateTime]::UtcNow.AddMinutes(3)
            while (-not (Test-HttpReady "http://127.0.0.1:$($Config.ports.web)/")) { if ([DateTime]::UtcNow -ge $deadline) { throw 'Pilot Web не готов после перезапуска.' }; Start-Sleep -Seconds 2 }
            Test-WebDatabaseLogin -Config $Config
        }
        'pilot-web-myadmin' {
            $deadline=[DateTime]::UtcNow.AddMinutes(3)
            while (-not (Test-HttpReady "http://127.0.0.1:$($Config.ports.admin)/")) { if ([DateTime]::UtcNow -ge $deadline) { throw 'myAdmin не готов после перезапуска.' }; Start-Sleep -Seconds 2 }
        }
    }
    Write-Info "Компонент '$Service' стенда '$($Config.name)' перезапущен и прошёл readiness-check."
}

function Recreate-Instance {
    param([pscustomobject] $Config)
    if (-not $Force) { throw 'Recreate безвозвратно удаляет данные. Требуется -Force.' }
    if ($Config.mode -ne 'bim-dev') { throw 'Recreate через API разрешён только для bim-dev.' }
    if (-not (Test-Path -LiteralPath (Get-ReleaseLockPath))) { throw 'Отсутствует last-known-good release.' }
    $release = Get-Content -LiteralPath (Get-ReleaseLockPath) -Raw | ConvertFrom-Json
    Assert-BimMemoryCapacity -ExcludeName $Config.name
    Load-InstanceSecrets -Config $Config
    Reset-BimInstanceForRelease -Config $Config -Release $release
    Start-Instance -Config (Get-InstanceConfig $Config.name)
}

function Refresh-VerifiedRelease {
    if ([string]::IsNullOrWhiteSpace($LicenseFile)) { throw 'RefreshRelease требует PILOT_LICENSE_FILE.' }
    if ([string]::IsNullOrWhiteSpace($ConfigurationFile)) { throw 'RefreshRelease требует PILOT_CONFIGURATION_FILE.' }
    Assert-BimMemoryCapacity
    $candidate = Resolve-ReleaseSet -Pull
    $oldOverride = $script:ReleaseOverride
    $validationName = "validation-$(([Guid]::NewGuid().ToString('N')).Substring(0,12))"
    try {
        $script:ReleaseOverride = $candidate
        Prepare-BimTemplate
        $Name = $validationName
        $Mode = 'bim-dev'
        $DatabaseName = 'pilot-bim_ru'
        $Start = $true
        $ServerPort = 0; $WebPort = 0; $AdminPort = 0
        $PublicWebPort = 0; $PublicAdminPort = 0
        New-Instance
        Save-ReleaseAsKnownGood -Release $candidate
        Write-Info "Release проверен временным полным стеком и сохранён как last-known-good."
    }
    catch {
        $failure = $_
        $diagnosticPath = Join-Path $script:RuntimeRoot "diagnostics/$validationName"
        $bimExcerpt = ''
        try {
            [void](New-Item -ItemType Directory -Path $diagnosticPath -Force)
            $failedConfig = Get-InstanceConfig $validationName
            $prefix = Get-ComposePrefix $failedConfig
            foreach ($component in @('pilot-server','pilot-bim-server','pilot-web-server','pilot-web-myadmin')) {
                $text = (& docker @prefix logs --no-color --tail 150 $component 2>&1 | Out-String)
                foreach ($secret in @($env:PILOT_ADMIN_PASSWORD,$env:PILOT_BIM_PASSWORD)) {
                    if (-not [string]::IsNullOrEmpty($secret)) { $text = $text.Replace($secret,'***') }
                }
                Write-PilotUtf8NoBom -LiteralPath (Join-Path $diagnosticPath "$component.log") -Text $text
                if ($component -eq 'pilot-bim-server') { $bimExcerpt = $text }
            }
        } catch { }
        if ($bimExcerpt.Length -gt 6000) { $bimExcerpt = $bimExcerpt.Substring($bimExcerpt.Length-6000) }
        throw "Release validation failed: $($failure.Exception.Message). BIM log: $bimExcerpt. Local diagnostic logs: $diagnosticPath"
    }
    finally {
        $validationPath = Get-InstancePath $validationName
        if (Test-Path -LiteralPath (Join-Path $validationPath 'instance.json')) {
            try { $validationConfig = Get-InstanceConfig $validationName; [void](Invoke-Compose -Config $validationConfig -Arguments @('down','--remove-orphans') -AllowFailure) } catch { }
        }
        if (Test-Path -LiteralPath $validationPath) { Remove-Item -LiteralPath $validationPath -Recurse -Force }
        $script:ReleaseOverride = $oldOverride
    }
}

function Show-Doctor {
    $result = [ordered]@{
        DockerCli = [bool]$script:DockerCommand
        DockerEngine = $false
        DockerCompose = $false
        ProductionAccess = 'DISABLED: проект управляет только disposable ice-dev/bim-dev'
    }

    if ($result.DockerCli) {
        & docker info --format '{{.ServerVersion}}' *> $null
        $result.DockerEngine = $LASTEXITCODE -eq 0
        & docker compose version *> $null
        $result.DockerCompose = $LASTEXITCODE -eq 0
    }

    [pscustomobject]$result | Format-List
    if (-not $result.DockerEngine) {
        Write-Warning 'Docker Engine недоступен. Обычно достаточно запустить Docker Desktop.'
    }
}

switch ($Action) {
    'New' {
        New-Instance
    }
    'List' {
        if (-not (Test-Path -LiteralPath $script:InstancesRoot)) {
            Write-Info 'Стенды ещё не созданы.'
            break
        }
        $instances = Get-ChildItem -LiteralPath $script:InstancesRoot -Directory | ForEach-Object {
            $path = Join-Path $_.FullName 'instance.json'
            if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
        }
        $instances | Select-Object name, mode, product, databaseName, memoryLimitGiB, @{n='server';e={$_.ports.server}}, @{n='web';e={$_.ports.web}} | Format-Table -AutoSize
    }
    'Doctor' {
        Show-Doctor
    }
    'ResolveRelease' {
        $resolved = Resolve-ReleaseSet -Pull
        if ($Json) { $resolved | ConvertTo-Json -Depth 8 -Compress } else { $resolved | Format-List }
    }
    'PrepareTemplate' {
        Prepare-BimTemplate
    }
    'RefreshRelease' {
        Refresh-VerifiedRelease
    }
    'GetCapacity' {
        $capacity = Get-CapacitySnapshot
        if ($Json) { $capacity | ConvertTo-Json -Depth 8 -Compress } else { $capacity | Format-List }
    }
    default {
        Assert-Name
        $config = Get-InstanceConfig $Name
        switch ($Action) {
            'Start' { Start-Instance -Config $config }
            'Stop' {
                Assert-Docker
                [void](Invoke-Compose -Config $config -Arguments @('stop'))
            }
            'Down' {
                Assert-Docker
                [void](Invoke-Compose -Config $config -Arguments @('down', '--remove-orphans'))
            }
            'Status' {
                $snapshot = Get-StatusSnapshot -Config $config
                $snapshot | Format-List
                if ($snapshot.state -ne 'failed') { Invoke-Compose -Config $config -Arguments @('ps') }
            }
            'GetStatus' {
                $snapshot = Get-StatusSnapshot -Config $config
                if ($Json) { $snapshot | ConvertTo-Json -Depth 10 -Compress } else { $snapshot | Format-List }
            }
            'RestartComponent' {
                Restart-InstanceComponent -Config $config
            }
            'Recreate' {
                Recreate-Instance -Config $config
            }
            'Logs' {
                Assert-Docker
                $arguments = @('logs', '--no-color', '--tail', [string]$Tail)
                if (-not [string]::IsNullOrWhiteSpace($Service)) { $arguments += $Service }
                Invoke-Compose -Config $config -Arguments $arguments
            }
            'ConnectBim' { Connect-BimInstance -Config $config }
            'Open' {
                Start-Process "http://127.0.0.1:$($config.ports.web)"
            }
            'Remove' {
                if (-not $Force) { throw "Удаление уничтожит данные стенда. Повторите с -Force: .\scripts\pilot-env.ps1 Remove $Name -Force" }
                $instancePath = [IO.Path]::GetFullPath((Get-InstancePath $Name))
                $rootPath = [IO.Path]::GetFullPath($script:InstancesRoot) + [IO.Path]::DirectorySeparatorChar
                if (-not $instancePath.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Небезопасный путь удаления: $instancePath"
                }
                if ($PSCmdlet.ShouldProcess($instancePath, 'Удалить контейнеры и все данные стенда')) {
                    if ($script:DockerCommand) {
                        [void](Invoke-Compose -Config $config -Arguments @('down', '--remove-orphans') -AllowFailure)
                    }
                    Remove-Item -LiteralPath $instancePath -Recurse -Force
                    Write-Info "Стенд '$Name' и его локальные данные удалены."
                }
            }
        }
    }
}

