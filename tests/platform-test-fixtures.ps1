. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\platform-package.ps1')

function Initialize-TestInstallation([string]$Root,[string]$Bundle){
    Expand-PlatformArchive $Bundle $Root
    $components=@{}
    foreach($kind in @('web-ui','control-api','environment-engine')){
        $source=Join-Path $Root "components\$kind"
        [void](Test-PlatformComponent $source)
        $hash=Get-PlatformHash (Join-Path $source 'component-manifest.json')
        $destination=Get-PlatformBuildPath $Root $kind $hash
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force)
        Copy-Item -LiteralPath $source -Destination $destination -Recurse
        $components[$kind]=@{buildHash=$hash}
    }
    $state=@{schemaVersion=2;components=$components;history=@()}
    Write-PlatformJson (Join-Path $Root '.pilot-runtime\deployment-state.json') $state
    return $state
}

function Update-TestManifest([string]$Directory){
    $manifestPath=Join-Path $Directory 'component-manifest.json'
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
    $manifest.files=@(Get-ChildItem -LiteralPath $Directory -Recurse -File|Where-Object FullName -ne $manifestPath|Sort-Object FullName|ForEach-Object{
        [ordered]@{path=$_.FullName.Substring($Directory.Length+1).Replace('\','/');length=$_.Length;sha256=(Get-PlatformHash $_.FullName)}
    })
    Write-PlatformJson $manifestPath $manifest
    return Get-PlatformHash $manifestPath
}

function New-TestBuild([string]$Source,[string]$Destination,[string]$Marker){
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse
    Write-PilotUtf8NoBom -LiteralPath (Join-Path $Destination 'build-marker.txt') -Text $Marker
    return Update-TestManifest $Destination
}
