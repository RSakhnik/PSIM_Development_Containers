[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('web-ui','control-api','environment-engine','all')][string] $Component,
    [string] $Package,
    [string] $InstallRoot,
    [string] $ServiceName = 'PilotEnvironmentApi',
    [switch] $ValidateOnly,
    [switch] $Rollback,
    [ValidateRange(1,300)][int] $HealthTimeoutSeconds = 90,
    [ValidateRange(1,1800)][int] $DrainTimeoutSeconds = 1800
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'platform-package.ps1')
if (-not $InstallRoot) { $InstallRoot = Split-Path -Parent $PSScriptRoot }
$root = [IO.Path]::GetFullPath($InstallRoot)
$runtime = Join-Path $root '.pilot-runtime'
[void](New-Item -ItemType Directory -Path $runtime -Force)
$statePath = Join-Path $runtime 'deployment-state.json'
$maintenancePath = Join-Path $runtime 'platform-maintenance.json'
$journalPath = Join-Path $runtime 'platform-update-journal.json'
$lock = $null
$stage = Join-Path $runtime ('update-stage-' + [guid]::NewGuid().ToString('N'))
$previous = $null
$switched = $false
$serviceChanged = $false
$createdService = $false
$oldBinary = $null
$wasRunning = $false
$ownsMaintenance = $false
$bootstrap = $false
$backup = $null
$serviceIdentity = 'LocalSystem'

function Set-PlatformService($Selection) {
    $exe = Join-Path (Get-PlatformBuildPath $root 'control-api' $Selection.buildHash) 'PilotEnv.Api.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "API executable is missing: $exe" }
    $binary = '"{0}" --contentRoot "{1}"' -f $exe,$root
    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existing) {
        Set-PilotServiceCommand -Name $ServiceName -BinaryPath $binary
    } else {
        New-Service -Name $ServiceName -BinaryPathName $binary -StartupType Automatic -DisplayName 'Pilot Environment API' | Out-Null
        $script:createdService = $true
        & sc.exe config $ServiceName obj= LocalSystem | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'LocalSystem configuration failed.' }
    }
    Set-PilotServiceCommand -Name $ServiceName -BinaryPath $binary
    & sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/15000/restart/30000 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Recovery policy configuration failed.' }
}

function Get-LocalApiSettings {
    $settings = Get-Content -LiteralPath (Join-Path $runtime 'api\hostsettings.json') -Raw | ConvertFrom-Json
    return @{url=([string]$settings.PilotEnv.ListenUrl).TrimEnd('/');headers=@{Host="$($settings.PilotEnv.PublicHost):$($settings.PilotEnv.ControlPublicPort)"}}
}

function Test-PlatformHttp($Path) {
    $s = Get-LocalApiSettings
    return Invoke-WebRequest -UseBasicParsing -Uri ($s.url + $Path) -Headers $s.headers -TimeoutSec 10
}

function Test-PlatformWebUi {
    param([string] $BuildHash, $Manifest)
    $page = Test-PlatformHttp '/'
    $prefix = "/ui-assets/$BuildHash/"
    if (-not $page.Content.Contains($prefix + 'app.js')) { throw 'UI activation did not serve the selected build.' }
    # Verify this package's resources, not filenames from an older frontend layout.
    $assets = @($Manifest.files | Where-Object { $_.path -match '\.(js|css)$' })
    foreach ($asset in $assets) {
        $assetPath = $prefix + ([string]$asset.path).Replace('\','/')
        try { [void](Test-PlatformHttp $assetPath) }
        catch { throw "UI resource check failed for '$assetPath': $($_.Exception.Message)" }
    }
}

function Wait-PlatformDrain {
    $deadline = [DateTime]::UtcNow.AddSeconds($DrainTimeoutSeconds)
    do {
        $result = Test-PlatformHttp '/internal/platform/activity'
        $value = $result.Content | ConvertFrom-Json
        if ($null -eq $value.PSObject.Properties['activeOperations']) { throw 'API does not support coordinated updates. Use bootstrap migration.' }
        if ([int]$value.activeOperations -eq 0 -and $value.maintenance) { return }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Drain timeout; active operations were not interrupted.' }
        Start-Sleep -Milliseconds 500
    } while ($true)
}

function Invoke-EngineProbe([string] $EngineDirectory, [string] $Action, [string] $Name) {
    $oldData = $env:PILOT_DATA_ROOT; $oldEngine = $env:PILOT_ENGINE_ROOT
    $env:PILOT_DATA_ROOT=$root; $env:PILOT_ENGINE_ROOT=$EngineDirectory
    try {
        $argsList = @($Action)
        if ($Name) { $argsList += $Name }
        $argsList += @('-Json','-Machine')
        $result = & (Get-PilotWindowsPowerShellPath) -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $EngineDirectory 'scripts\pilot-env.ps1') @argsList 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Engine probe failed: $Action" }
        $envelope = ($result -join "`n") | ConvertFrom-Json
        if (-not $envelope.success -or $envelope.protocolVersion -ne 1) { throw "Invalid engine response: $Action" }
        return $envelope.data
    } finally { $env:PILOT_DATA_ROOT=$oldData; $env:PILOT_ENGINE_ROOT=$oldEngine }
}

try {
    try { $lock = [IO.File]::Open((Join-Path $runtime 'platform-update.lock'), 'OpenOrCreate','ReadWrite','None') }
    catch { throw 'Another platform update is in progress.' }
    if ((Test-Path -LiteralPath $journalPath) -and -not $ValidateOnly) {
        $pending = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
        if ($pending.phase -notin @('completed','rolled-back') -and -not $Rollback) {
            throw 'An interrupted update exists. Run with -Rollback to recover it.'
        }
        if($Rollback -and (($pending.previous -and $pending.previous.schemaVersion -ne 2) -or (-not $pending.previous -and $pending.phase -notin @('completed','rolled-back')))){
            Stop-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if($pending.oldBinary){Set-PilotServiceCommand -Name $ServiceName -BinaryPath $pending.oldBinary;if($pending.wasRunning){Start-Service -Name $ServiceName}}
            else{& sc.exe delete $ServiceName | Out-Null}
            if($pending.previous){Write-PlatformJson $statePath $pending.previous}elseif(Test-Path -LiteralPath $statePath){Remove-Item -LiteralPath $statePath -Force}
            if($pending.PSObject.Properties['backupPath'] -and $pending.backupPath -and (Test-Path -LiteralPath (Join-Path $pending.backupPath 'scripts'))){Copy-Item -Path (Join-Path $pending.backupPath 'scripts\*') -Destination (Join-Path $root 'scripts') -Recurse -Force}
            if(Test-Path -LiteralPath $maintenancePath){Remove-Item -LiteralPath $maintenancePath -Force}
            $pending.phase='rolled-back';Write-PlatformJson $journalPath $pending
            [pscustomobject]@{component=$Component;state='legacy-restored'};return
        }
    }
    if (Test-Path -LiteralPath $statePath) { $previous = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
    $legacyLayout = $previous -and $previous.schemaVersion -ne 2
    if($legacyLayout -and $Component -ne 'all'){throw 'Migrate the deployment layout using a complete current bundle.'}
    $candidate = if ($previous -and -not $legacyLayout) { $previous | ConvertTo-Json -Depth 40 | ConvertFrom-Json } else { [pscustomobject]@{schemaVersion=2;components=[pscustomobject]@{};history=@()} }
    $targets=@{}
    if ($Rollback) {
        $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
        if (-not $journal.previous) { throw 'No previous installation is available for rollback.' }
        if ($journal.component -ne $Component) { throw "Rollback must select component '$($journal.component)'." }
        $candidate=$journal.previous
        foreach($property in $candidate.components.PSObject.Properties) {
            if ($Component -eq 'all' -or $Component -eq $property.Name) { $targets[$property.Name]=Get-PlatformBuildPath $root $property.Name $property.Value.buildHash }
        }
    } else {
        if (-not $Package) { throw '-Package is required.' }
        $source=(Resolve-Path -LiteralPath $Package).Path
        if (Test-Path -LiteralPath $source -PathType Container) { $packageRoot=$source }
        else {
            [void](New-Item -ItemType Directory -Path $stage)
            Expand-PlatformArchive $source $stage
            $packageRoot=$stage
        }
        if ($Component -eq 'all') {
            $bundle=Get-Content -LiteralPath (Join-Path $packageRoot 'bundle-manifest.json') -Raw | ConvertFrom-Json
            if($bundle.schemaVersion -ne 2){throw 'Unsupported package layout. Build a bundle with the current packager.'}
            foreach($entry in $bundle.components) {
                if ($entry.component -notin @('web-ui','control-api','environment-engine')) { throw 'Invalid bundle component.' }
                Assert-PlatformBuildHash $entry.buildHash
                $dir=Join-Path $packageRoot "components\$($entry.component)"
                if ((Get-PlatformHash (Join-Path $dir 'component-manifest.json')) -ne $entry.buildHash) { throw 'Bundle manifest mismatch.' }
                $targets[$entry.component]=$dir
            }
            if ($targets.Count -ne 3) { throw 'A full bundle must contain exactly three components.' }
        } else { $targets[$Component]=$packageRoot }
        foreach($kind in @($targets.Keys)) {
            $manifest=Test-PlatformComponent $targets[$kind]
            if ($manifest.component -ne $kind) { throw 'Package component does not match -Component.' }
            $selection=[pscustomobject]@{buildHash=(Get-PlatformHash (Join-Path $targets[$kind] 'component-manifest.json'))}
            $candidate.components | Add-Member -MemberType NoteProperty -Name $kind -Value $selection -Force
        }
    }
    $manifests=@{}
    foreach($kind in @('web-ui','control-api','environment-engine')) {
        if (-not $candidate.components.PSObject.Properties[$kind]) { throw 'Initial installation requires a full bundle.' }
        $selection=$candidate.components.$kind
        Assert-PlatformBuildHash $selection.buildHash
        $dir=if($targets.ContainsKey($kind)){$targets[$kind]}else{Get-PlatformBuildPath $root $kind $selection.buildHash}
        $manifests[$kind]=Test-PlatformComponent $dir
        if((Get-PlatformHash (Join-Path $dir 'component-manifest.json')) -ne $selection.buildHash){throw "Installed manifest changed for $kind."}
    }
    Assert-PlatformCompatibility $manifests
    $instancesDirectory=Join-Path $root '.pilot-instances'
    if(Test-Path -LiteralPath $instancesDirectory){
        foreach($instance in Get-ChildItem -LiteralPath $instancesDirectory -Directory){
            $configurationPath=Join-Path $instance.FullName 'instance.json'
            if(-not (Test-Path -LiteralPath $configurationPath)){continue}
            $configuration=Get-Content -LiteralPath $configurationPath -Raw|ConvertFrom-Json
            if(-not $configuration.PSObject.Properties['schemaVersion'] -or [int]$configuration.schemaVersion -lt $manifests['environment-engine'].requires.instanceSchemaMin -or [int]$configuration.schemaVersion -gt $manifests['environment-engine'].requires.instanceSchemaMax){
                throw "Environment '$($instance.Name)' uses an unsupported schema. Migrate legacy environments with the port-routing release before component bootstrap."
            }
        }
    }
    if ($ValidateOnly) { [pscustomobject]@{valid=$true;component=$Component;builds=$candidate.components}; return }
    if(-not $Rollback -and $previous -and -not $legacyLayout){
        $changed=@($targets.Keys|Where-Object{$previous.components.$_.buildHash -ne $candidate.components.$_.buildHash})
        if($changed.Count -eq 0){[pscustomobject]@{component=$Component;state='unchanged';builds=$candidate.components;serviceRestarted=$false};return}
    }
    $bootstrap=-not $previous -or $legacyLayout
    if ($bootstrap -and $Component -ne 'all') { throw 'Bootstrap requires -Component all.' }
    $service=Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service) {
        $wasRunning=$service.Status -eq 'Running'
        $serviceInfo=Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
        $oldBinary=$serviceInfo.PathName
        $serviceIdentity=[string]$serviceInfo.StartName
        if($serviceIdentity -notin @('LocalSystem','NT AUTHORITY\SYSTEM')){Write-Warning "Preserving existing legacy service identity '$serviceIdentity'."}
    }
    # Legacy service cannot acknowledge maintenance. Require quiescent offline migration.
    if ($bootstrap -and $wasRunning) { throw 'Deployment layout migration requires a stopped API. Finish operations and stop only the API service; Pilot containers keep running.' }
    if ($bootstrap) {
        $toolRoot=$targets['control-api']
        & (Join-Path $toolRoot 'PilotEnv.Api.exe') --platform-check-quiescent $root
        if($LASTEXITCODE -ne 0){throw 'Legacy SQLite has queued/running operations. Resume the old API and finish them before migration.'}
    }
    Write-PlatformJson $journalPath @{phase='prepared';component=$Component;previous=$previous;candidate=$candidate;oldBinary=$oldBinary;wasRunning=$wasRunning}
    foreach($kind in @($targets.Keys)) {
        $buildHash=$candidate.components.$kind.buildHash
        $destination=Get-PlatformBuildPath $root $kind $buildHash
        if (Test-Path -LiteralPath $destination) {
            $installed=Test-PlatformComponent $destination
            if ((Get-PlatformHash (Join-Path $destination 'component-manifest.json')) -ne $candidate.components.$kind.buildHash) { throw 'An installed build has been modified.' }
        } else {
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force)
            Copy-Item -LiteralPath $targets[$kind] -Destination $destination -Recurse
        }
    }
    if ($Component -ne 'web-ui') {
        Write-PlatformJson $maintenancePath @{component=$Component;phase='draining'}
        $ownsMaintenance=$true
        $apiOnline=$false
        if(Test-Path -LiteralPath (Join-Path $runtime 'api\hostsettings.json')){
            try{[void](Test-PlatformHttp '/internal/platform/activity');$apiOnline=$true}catch{if($wasRunning){throw}}
        }
        if ($wasRunning -or $apiOnline) { Wait-PlatformDrain }
        if($apiOnline -and -not $service -and $Component -in @('control-api','all')){throw 'An API process is running without a Windows Service. Stop that process before installing the service.'}
    }
    if ($bootstrap) {
        $backup=Join-Path $runtime ('migration-backup-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
        [void](New-Item -ItemType Directory -Path $backup)
        $protectedRuntime=Join-Path $runtime 'api'
        if(Test-Path -LiteralPath $protectedRuntime){Set-Acl -LiteralPath $backup -AclObject (Get-Acl -LiteralPath $protectedRuntime)}
        foreach($name in @('hostsettings.json','secrets.json','pilot-env.db','pilot-env.db-wal','pilot-env.db-shm')) {
            $file=Join-Path $runtime "api\$name"
            if(Test-Path -LiteralPath $file){Copy-Item -LiteralPath $file -Destination $backup}
        }
        $adapters=Join-Path $root 'scripts'
        if(Test-Path -LiteralPath $adapters){Copy-Item -LiteralPath $adapters -Destination (Join-Path $backup 'scripts') -Recurse}
        [void](New-Item -ItemType Directory -Path $adapters -Force)
        foreach($name in @('pilot-env.ps1','ps-compat.ps1','start-dev.ps1','start-bim-dev.ps1')){
            $source=Join-Path (Get-PlatformBuildPath $root 'environment-engine' $candidate.components.'environment-engine'.buildHash) "scripts\$name"
            Copy-Item -LiteralPath $source -Destination (Join-Path $adapters $name) -Force
        }
        Write-PlatformJson $journalPath @{phase='prepared';component=$Component;previous=$previous;candidate=$candidate;oldBinary=$oldBinary;wasRunning=$wasRunning;backupPath=$backup}
    }
    if ($Component -in @('control-api','all')) {
        Write-PlatformJson $maintenancePath @{component=$Component;phase='activating'}
        $ownsMaintenance=$true
        $serviceChanged=$true
        if ($wasRunning) { Stop-Service -Name $ServiceName; (Get-Service $ServiceName).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(60)) }
        Set-PlatformService $candidate.components.'control-api'
    }
    foreach($managed in @($runtime,(Join-Path $root '.pilot-instances'),(Join-Path $root '.pilot-templates'),(Join-Path $runtime 'builds'))){
        [void](New-Item -ItemType Directory -Path $managed -Force)
        & icacls.exe $managed /grant '*S-1-5-18:(OI)(CI)M' | Out-Null
        if($LASTEXITCODE -ne 0){throw 'Could not grant LocalSystem access to installation directories.'}
        if($serviceIdentity -notin @('LocalSystem','NT AUTHORITY\SYSTEM')){
            & icacls.exe $managed /grant "${serviceIdentity}:(OI)(CI)M" | Out-Null
            if($LASTEXITCODE -ne 0){throw 'Could not grant preserved service identity access.'}
        }
    }
    $candidate.history=@($candidate.history | Select-Object -Last 30) + @([pscustomobject]@{at=[DateTimeOffset]::UtcNow.ToString('o');component=$Component;previous=if($previous){$previous.components}else{$null}})
    Write-PlatformJson $statePath $candidate
    $switched=$true
    Write-PlatformJson $journalPath @{phase='activated';component=$Component;previous=$previous;candidate=$candidate;oldBinary=$oldBinary;wasRunning=$wasRunning;backupPath=$backup}
    if ($serviceChanged) {
        Start-Service -Name $ServiceName
        $deadline=[DateTime]::UtcNow.AddSeconds($HealthTimeoutSeconds)
        $ready=$false
        do { try { [void](Test-PlatformHttp '/health/live'); [void](Test-PlatformHttp '/health/ready'); $ready=$true } catch { Start-Sleep -Seconds 1 } } while(-not $ready -and [DateTime]::UtcNow -lt $deadline)
        if(-not $ready){throw 'Updated API failed readiness.'}
    }
    if ($Component -in @('web-ui','all')) {
        $runningService=Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if (($runningService -and $runningService.Status -eq 'Running') -or (Test-Path -LiteralPath (Join-Path $runtime 'api\hostsettings.json'))) {
            Test-PlatformWebUi -BuildHash $candidate.components.'web-ui'.buildHash -Manifest $manifests['web-ui']
        }
    }
    if($Component -in @('environment-engine','all')){
        $engine=Get-PlatformBuildPath $root 'environment-engine' $candidate.components.'environment-engine'.buildHash
        [void](Invoke-EngineProbe $engine 'GetEngineInfo' '')
        $capacity=Invoke-EngineProbe $engine 'GetCapacity' ''
        if(-not $capacity.prerequisites.dockerReady){throw 'Updated engine cannot access Docker.'}
        foreach($instance in Get-ChildItem -LiteralPath (Join-Path $root '.pilot-instances') -Directory -ErrorAction SilentlyContinue){
            if(Test-Path -LiteralPath (Join-Path $instance.FullName 'instance.json')){[void](Invoke-EngineProbe $engine 'GetStatus' $instance.Name)}
        }
    }
    Write-PlatformJson $journalPath @{phase=if($Rollback){'rolled-back'}else{'completed'};component=$Component;previous=$previous;candidate=$candidate;oldBinary=$oldBinary;wasRunning=$wasRunning;backupPath=$backup}
    # Keep active + three prior content snapshots. Never touch data or Pilot containers.
    foreach($kind in @($targets.Keys)){
        $buildsRoot=Join-Path $runtime "builds\$kind"
        $active=$candidate.components.$kind.buildHash
        $obsolete=@(Get-ChildItem -LiteralPath $buildsRoot -Directory | Where-Object Name -ne $active | Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 3)
        foreach($directory in $obsolete){$checked=Resolve-PlatformChild $buildsRoot $directory.Name;Remove-Item -LiteralPath $checked -Recurse -Force -ErrorAction Continue}
    }
    [pscustomobject]@{component=$Component;state='completed';builds=$candidate.components;serviceRestarted=$serviceChanged}
} catch {
    if($switched -and $previous){Write-PlatformJson $statePath $previous}
    if($switched -and -not $previous -and (Test-Path -LiteralPath $statePath)){Remove-Item -LiteralPath $statePath -Force}
    if($serviceChanged){
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        if($oldBinary){Set-PilotServiceCommand -Name $ServiceName -BinaryPath $oldBinary; if($wasRunning){Start-Service -Name $ServiceName}}
        elseif($createdService){& sc.exe delete $ServiceName | Out-Null}
    }
    if($bootstrap -and $backup -and (Test-Path -LiteralPath (Join-Path $backup 'scripts'))){
        Copy-Item -Path (Join-Path $backup 'scripts\*') -Destination (Join-Path $root 'scripts') -Recurse -Force
    }
    if($switched){Write-PlatformJson $journalPath @{phase='rolled-back';component=$Component;previous=$previous;candidate=$candidate}}
    throw
} finally {
    if($ownsMaintenance -and (Test-Path -LiteralPath $maintenancePath)){Remove-Item -LiteralPath $maintenancePath -Force}
    if(Test-Path -LiteralPath $stage){$checked=Resolve-PlatformChild $runtime ([IO.Path]::GetFileName($stage));Remove-Item -LiteralPath $checked -Recurse -Force}
    if($lock){$lock.Dispose()}
}
