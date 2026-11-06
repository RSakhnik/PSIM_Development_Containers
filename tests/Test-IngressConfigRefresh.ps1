$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'scripts\ps-compat.ps1')
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\pilot-env.ps1'),[ref]$null,[ref]$null)
$definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-InstanceIngressConfig'},$true)
Invoke-Expression $definition.Extent.Text
$script:EngineRoot=$repo
$temp=Join-Path ([IO.Path]::GetTempPath()) ('pilot-ingress-refresh-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path (Join-Path $temp 'ingress') -Force)
function Get-InstancePath {param($Name) $temp}
try{
    [IO.File]::WriteAllText((Join-Path $temp 'ingress\nginx.conf'),'old config without upgrade')
    $config=[pscustomobject]@{name='local-test'}
    if(-not (Update-InstanceIngressConfig $config)){throw 'Old instance config was not refreshed'}
    if([IO.File]::ReadAllText((Join-Path $temp 'ingress\nginx.conf')) -cne [IO.File]::ReadAllText((Join-Path $repo 'ingress\instance-nginx.conf'))){throw 'Config differs from installed resource'}
    if(Update-InstanceIngressConfig $config){throw 'Unchanged ingress should not reload'}
    Write-Host 'Ingress refresh: PASS (existing config upgraded once, stable subsequent Start).'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
