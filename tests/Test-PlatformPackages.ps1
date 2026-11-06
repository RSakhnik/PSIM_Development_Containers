[CmdletBinding()]
param([string] $Bundle)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\platform-package.ps1')
if(-not $Bundle){$Bundle=Join-Path $root 'artifacts\PilotEnvironment-win-x64.zip'}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('pilot-package-test-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp)
try{
    Expand-PlatformArchive $Bundle $temp
    $bundleInfo=Get-Content -LiteralPath (Join-Path $temp 'bundle-manifest.json') -Raw|ConvertFrom-Json
    if($bundleInfo.PSObject.Properties['version']){throw 'Bundle must not contain a release number.'}
    $manifests=@{}
    foreach($entry in $bundleInfo.components){$dir=Join-Path $temp "components\$($entry.component)";$manifests[$entry.component]=Test-PlatformComponent $dir;if((Get-PlatformHash (Join-Path $dir 'component-manifest.json')) -ne $entry.buildHash){throw 'Build identity mismatch.'}}
    Assert-PlatformCompatibility $manifests
    foreach($manifest in $manifests.Values){if($manifest.PSObject.Properties['version']){throw 'Component identity must be a content hash, not a release number.'}}
    & (Join-Path $root 'scripts\update-platform.ps1') -Component all -Package $temp -InstallRoot (Join-Path $temp 'install') -ValidateOnly | Out-Null
    $webEntry=$bundleInfo.components|Where-Object component -eq 'web-ui'
    $web=Join-Path $temp 'components\web-ui'
    Add-Content -LiteralPath (Join-Path $web 'app.js') -Value '// tampered'
    $rejected=$false
    try{Test-PlatformComponent $web|Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'Corrupted package was accepted.'}
    $manifests['web-ui'].requires.apiContractMin=99
    $rejected=$false
    try{Assert-PlatformCompatibility $manifests}catch{$rejected=$true}
    if(-not $rejected){throw 'Incompatible contract was accepted.'}
    $rejected=$false
    try{Resolve-PlatformChild $temp '..\outside'|Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'Escaping package path was accepted.'}
    Write-Host 'Platform package validation: OK (bundle, hashes, compatibility, corruption, path traversal).'
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
