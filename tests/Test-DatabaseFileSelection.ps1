$ErrorActionPreference='Stop'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('pilot-dbp-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp)
try {
    foreach($name in @('pilot-bim_ru.journal.dbp-shm','pilot-bim_ru.dbp-wal','pilot-bim_ru.dbp-shm','pilot-bim_ru.messages.dbp','pilot-bim_ru.journal.dbp','pilot-bim_ru.dbp')) {
        [IO.File]::WriteAllText((Join-Path $temp $name),'synthetic')
    }
    $files=@(Get-ChildItem -LiteralPath $temp -File -Filter '*.dbp')
    $selected=@($files | Where-Object { $_.Extension -ieq '.dbp' -and $_.Name -notmatch '\.(messages|journal)\.dbp$' })
    if($selected.Count -ne 1 -or $selected[0].Name -ne 'pilot-bim_ru.dbp'){throw 'Auxiliary SQLite file selected as main database'}
    Write-Host 'Main database selection: OK (real PS5 filesystem wildcard, WAL/SHM and journal/message files excluded).'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
