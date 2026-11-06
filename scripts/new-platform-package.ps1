[CmdletBinding()]
param([string] $OutputDirectory)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'platform-package.ps1')
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) {
    $buildsRoot = Join-Path (Split-Path -Parent $root) 'builds'
    $moscowTime = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTimeOffset]::UtcNow, 'Russian Standard Time')
    $OutputDirectory = Join-Path $buildsRoot ($moscowTime.ToString('yyyy-MM-dd_HH-mm-ss'))
    if (Test-Path -LiteralPath $OutputDirectory) { throw 'Build directory already exists; retry in a new second or specify -OutputDirectory.' }
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
[void](New-Item -ItemType Directory -Path $output -Force)
$stage = Join-Path $output ('platform-build-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $stage)
try {
    $componentRoot = Join-Path $stage 'components'
    $apiPath = Join-Path $componentRoot 'control-api'
    $project = Join-Path $root 'src\PilotEnv.Api\PilotEnv.Api.csproj'
    & dotnet restore $project -r win-x64 --disable-parallel --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Restore failed.' }
    & dotnet publish $project -c Release -r win-x64 --self-contained true --no-restore --nologo -o $apiPath
    if ($LASTEXITCODE -ne 0) { throw 'Publish failed.' }
    $webPath = Join-Path $componentRoot 'web-ui'
    [void](New-Item -ItemType Directory -Path $webPath -Force)
    & (Join-Path $PSScriptRoot 'build-web-ui.ps1') -OutputDirectory $webPath
    $enginePath = Join-Path $componentRoot 'environment-engine'
    [void](New-Item -ItemType Directory -Path (Join-Path $enginePath 'scripts') -Force)
    foreach ($name in @('pilot-env.ps1','ps-compat.ps1','start-dev.ps1','start-bim-dev.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $enginePath 'scripts')
    }
    Copy-Item -LiteralPath (Join-Path $root 'docker-compose.yml') -Destination $enginePath
    Copy-Item -LiteralPath (Join-Path $root 'ingress') -Destination $enginePath -Recurse
    $bundleComponents = @()
    foreach ($kind in @('web-ui','control-api','environment-engine')) {
        $directory = Join-Path $componentRoot $kind
        $files = @(Get-ChildItem -LiteralPath $directory -Recurse -File | Sort-Object FullName | ForEach-Object {
            [ordered]@{path=$_.FullName.Substring($directory.Length+1).Replace('\','/');length=$_.Length;sha256=(Get-PlatformHash $_.FullName)}
        })
        # Ordered metadata, no dates/release labels: identical payload yields identical build identity.
        $manifest = [ordered]@{schemaVersion=2;component=$kind;
            provides=[ordered]@{apiContract=2;engineProtocol=1;instanceSchema=4};
            requires=[ordered]@{apiContractMin=2;apiContractMax=2;engineProtocolMin=1;engineProtocolMax=1;instanceSchemaMin=4;instanceSchemaMax=4};files=$files}
        Write-PlatformJson (Join-Path $directory 'component-manifest.json') $manifest
        $buildHash = Get-PlatformHash (Join-Path $directory 'component-manifest.json')
        $archive = Join-Path $output "PilotEnvironment-$kind.zip"
        Compress-Archive -Path (Join-Path $directory '*') -DestinationPath $archive -Force
        $hash = Get-PlatformHash $archive
        $bundleComponents += [ordered]@{component=$kind;buildHash=$buildHash}
        [pscustomobject]@{component=$kind;package=$archive;buildHash=$buildHash;sha256=$hash}
    }
    Write-PlatformJson (Join-Path $stage 'bundle-manifest.json') ([ordered]@{schemaVersion=2;components=$bundleComponents})
    Copy-Item -LiteralPath $PSScriptRoot -Destination $stage -Recurse
    Copy-Item -LiteralPath (Join-Path $root 'docker-compose.yml') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination $stage
    $bundle = Join-Path $output 'PilotEnvironment-win-x64.zip'
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $bundle -Force
    $hash = Get-PlatformHash $bundle
    [pscustomobject]@{component='all';package=$bundle;sha256=$hash}
} finally {
    $checked = Resolve-PlatformChild $output ([IO.Path]::GetFileName($stage))
    if (Test-Path -LiteralPath $checked) { Remove-Item -LiteralPath $checked -Recurse -Force }
}
