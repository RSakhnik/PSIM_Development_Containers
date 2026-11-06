[CmdletBinding()]
param([string]$PnpmPath='pnpm',[string]$OutputDirectory,[string]$BackendSdkVersion='26.19.0',[string]$FrontendSdkRange='26.19.0')
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
if(-not $OutputDirectory){
    $sourceRoot=Split-Path (Split-Path $root -Parent) -Parent
    $time=[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTimeOffset]::UtcNow,'Russian Standard Time')
    $OutputDirectory=Join-Path (Split-Path $sourceRoot -Parent) ('builds\'+$time.ToString('yyyy-MM-dd_HH-mm-ss')+'-isolation-probe')
}
[void](New-Item -ItemType Directory -Path $OutputDirectory -Force)
$utf8=New-Object Text.UTF8Encoding($false)
$webpackConfig=Join-Path $root 'frontend\webpack.config.js'
$configText=[IO.File]::ReadAllText($webpackConfig) -replace "requiredVersion:'[^']+'",("requiredVersion:'"+$FrontendSdkRange+"'")
[IO.File]::WriteAllText($webpackConfig,$configText,$utf8)
$variants=@(@{Marker='A1';Color='#2563eb';Version='0.0.1'},@{Marker='B1';Color='#16a34a';Version='0.0.2'},@{Marker='A2';Color='#ea580c';Version='0.0.3'})
foreach($variant in $variants){
    $marker=$variant.Marker
    $env:ISOLATION_PROBE_MARKER=$marker
    [IO.File]::WriteAllText((Join-Path $root 'backend\ProbeBuild.cs'),('namespace PilotEnvironment.IsolationProbe; internal static class ProbeBuild { public const string Marker = "'+$marker+'"; }'),$utf8)
    [IO.File]::WriteAllText((Join-Path $root 'frontend\src\build.ts'),('export const MARKER="'+$marker+'"; export const COLOR="'+$variant.Color+'";'),$utf8)
    Push-Location (Join-Path $root 'frontend')
    try{ & .\node_modules\.bin\webpack.cmd --mode production; if($LASTEXITCODE -ne 0){throw 'Frontend build failed'} }finally{Pop-Location}
    $backend=Join-Path $root ('build-output\'+$marker+'\backend')
    & dotnet build (Join-Path $root 'backend\IsolationProbe.csproj') -c Release --nologo -p:PilotWebSdkVersion=$BackendSdkVersion -o $backend
    if($LASTEXITCODE -ne 0){throw 'Backend build failed'}
    $stage=Join-Path $root ('build-output\'+$marker+'\package')
    if(Test-Path -LiteralPath $stage){$allowed=[IO.Path]::GetFullPath((Join-Path $root 'build-output'))+'\'; if(-not [IO.Path]::GetFullPath($stage).StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe stage cleanup'}; Remove-Item -LiteralPath $stage -Recurse -Force}
    [void](New-Item -ItemType Directory -Path (Join-Path $stage 'backend') -Force)
    Copy-Item (Join-Path $root 'frontend\dist') (Join-Path $stage 'frontend') -Recurse -Force
    Copy-Item (Join-Path $backend 'IsolationProbe.webext.dll') (Join-Path $stage 'backend') -Force
    Copy-Item (Join-Path $backend 'IsolationProbe.webext.deps.json') (Join-Path $stage 'backend') -Force
    $manifest=[ordered]@{manifestVersion=1;author='Pilot Environment';license='MIT';title='Isolation Probe';description="Isolation verification package $marker";version=$variant.Version;extension=@{name='pilot_environment_isolation_probe';entry=('pilot_environment_isolation_probe.'+$marker+'.js');modules=@(@{ngModuleName='IsolationProbe';exposedInterface='IToolbar<ObjectsViewContext>'})}}
    [IO.File]::WriteAllText((Join-Path $stage 'frontend\extensions.config.json'),($manifest|ConvertTo-Json -Depth 8),$utf8)
    $zip=Join-Path $OutputDirectory "IsolationProbe-$marker.zip"
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
    [pscustomobject]@{marker=$marker;package=$zip}
}