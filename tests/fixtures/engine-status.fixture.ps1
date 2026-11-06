param($Action,$Name,[switch]$Json,[switch]$Machine)
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$data=switch($Action){
 'GetCapacity' { @{canStart=$true;availableSlots=2;blockers=@();memory=@{dockerTotalGiB=32;reservedGiB=16;safetyReserveGiB=8;perEnvironmentGiB=8};disk=@{freeGiB=100;minimumFreeGiB=20};prerequisites=@{dockerReady=$true;licenseReady=$true;releaseReady=$true;templateReady=$true}} }
 'GetEngineInfo' { @{buildHash='workspace';protocolVersion=1} }
 'GetStatus' { @{name=$Name;mode='bim-dev';product='Pilot-BIM';state='running';webPort=28081;adminPort=15200;serverPort=15545;images=@{myAdmin='fixture/pilot-web-myadmin:release'};versions=@{myAdmin='1.0.0'};lastError='Диагностика: credentials admin are never exposed';components=@(@{name='pilot-server';state='running';healthy=$true;containerId='fixture-server';restartCount=0},@{name='pilot-bim-server';state='running';healthy=$true;containerId='fixture-bim';restartCount=0},@{name='pilot-web-server';state='running';healthy=$true;containerId='fixture-web';restartCount=0},@{name='pilot-web-myadmin';state='running';healthy=$true;containerId='fixture-admin';restartCount=0})} }
 default {throw 'Read-only test engine: mutation forbidden'}
}
@{protocolVersion=1;success=$true;data=$data;error=$null}|ConvertTo-Json -Depth 20 -Compress
