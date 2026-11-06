$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\scripts\ps-compat.ps1')
$temp=Join-Path ([IO.Path]::GetTempPath()) ('pilot-utf8-'+[guid]::NewGuid().ToString('N')+'.pilotcfx')
try {
    $xml='<?xml version="1.0" encoding="utf-8"?><Configuration><Name>Здание: стены, перекрытия и ёлка</Name></Configuration>'
    [IO.File]::WriteAllText($temp,$xml,(New-Object Text.UTF8Encoding($false)))
    $bytes=New-PilotConfigurationImportBody -LiteralPath $temp
    if($bytes -isnot [byte[]]){throw 'HTTP body must be byte[]'}
    $decoded=(New-Object Text.UTF8Encoding($false,$true)).GetString($bytes) | ConvertFrom-Json
    if($decoded.data -cne $xml -or $decoded.databaseName -ne 'pilot-bim_ru'){throw 'UTF-8 round-trip corrupted configuration'}
    # The same explicit bytes are supplied to Invoke-RestMethod; prevent string fallback in the import call.
    $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\scripts\pilot-env.ps1'))
    if($source -notmatch 'ImportConfiguration" -Method Post -ContentType ''application/json; charset=utf-8'' -Body \$importBody'){throw 'Import transport no longer uses explicit UTF-8'}
    [IO.File]::WriteAllBytes($temp,[byte[]]@(0xD1,0x20))
    $failed=$false
    try{[void](New-PilotConfigurationImportBody -LiteralPath $temp)}catch{$failed=$true}
    if(-not $failed){throw 'Invalid UTF-8 silently replaced'}
    Write-Host 'Configuration encoding: OK (BOM-less Cyrillic UTF-8, byte[] HTTP body, invalid input rejection).'
} finally {Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
