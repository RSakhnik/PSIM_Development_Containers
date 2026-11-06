$ErrorActionPreference='Stop'
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\scripts\pilot-env.ps1'),[ref]$null,[ref]$null)
$definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Attach-InstanceDatabase'},$true)
Invoke-Expression $definition.Extent.Text
$config=[pscustomobject]@{databaseName='pilot-bim_ru'}
function Get-ComposePrefix {param($Config) @('compose')}
function Test-SettingsContains {param($Config,$Pattern) $script:registered}
function docker {
    $global:LASTEXITCODE=0
    if($args -contains 'test') {if($script:missing){$global:LASTEXITCODE=1};return}
    $script:attachCalls++
    $script:captured=@($args)
    if($script:sqliteFailure){'Connect failed: CantOpen (14), unable to open database file';return}
    'Database attachment completed successfully'
}
$script:missing=$false;$script:registered=$true;$script:sqliteFailure=$false;$script:attachCalls=0
Attach-InstanceDatabase $config 'pilot-bim_ru.dbp' 'archive.pilotfa'
if($script:captured -notcontains '/usr/share/ascon/databases/pilot-bim_ru/pilot-bim_ru.dbp'){throw 'Wrong database path'}
$script:missing=$true
try{Attach-InstanceDatabase $config 'pilot-bim_ru.dbp' 'archive.pilotfa';throw 'Expected unreadable file error'}catch{if($_.Exception.Message -notlike '*not readable inside*'){throw}}
if($script:attachCalls -ne 1){throw 'Attach ran with missing file'}
$script:missing=$false;$script:sqliteFailure=$true
try{Attach-InstanceDatabase $config 'pilot-bim_ru.dbp' 'archive.pilotfa';throw 'Expected SQLite error'}catch{if($_.Exception.Message -notlike '*CantOpen*'){throw}}
$script:sqliteFailure=$false;$script:registered=$false
try{Attach-InstanceDatabase $config 'pilot-bim_ru.dbp' 'archive.pilotfa';throw 'Expected registration error'}catch{if($_.Exception.Message -notlike '*did not register*'){throw}}
Write-Host 'Database attach: OK (container paths, unreadable file, SQLite failure with exit zero, registration postcondition).'
