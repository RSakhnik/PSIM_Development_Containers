$ErrorActionPreference='Stop'
function Test-WebSocket([string]$Uri,[string]$Token,[string]$ForwardedHost,[Net.CookieContainer]$Cookies){
    $socket=New-Object Net.WebSockets.ClientWebSocket
    if($Cookies){$socket.Options.Cookies=$Cookies}
    if($Token){$socket.Options.SetRequestHeader("Authorization","Bearer $Token")}
    if($ForwardedHost){$socket.Options.SetRequestHeader("X-Forwarded-Host",$ForwardedHost);$socket.Options.SetRequestHeader("X-Forwarded-Proto","https")}
    $cts=New-Object Threading.CancellationTokenSource
    $cts.CancelAfter(10000)
    try{
        $socket.ConnectAsync([Uri]$Uri,$cts.Token).GetAwaiter().GetResult()
        $nonce='isolation-'+[guid]::NewGuid().ToString('N')
        $payload=[Text.Encoding]::UTF8.GetBytes($nonce)
        $socket.SendAsync([ArraySegment[byte]]::new($payload),[Net.WebSockets.WebSocketMessageType]::Text,$true,$cts.Token).GetAwaiter().GetResult()
        $buffer=New-Object byte[] 4096
        $result=$socket.ReceiveAsync([ArraySegment[byte]]::new($buffer),$cts.Token).GetAwaiter().GetResult()
        if([Text.Encoding]::UTF8.GetString($buffer,0,$result.Count) -cne $nonce){throw 'WebSocket echo mismatch'}
        return $true
    }finally{$socket.Dispose();$cts.Dispose()}
}
[void](Invoke-RestMethod 'http://127.0.0.1:28080/headers' -TimeoutSec 10)
$oldFailed=$false
try{[void](Test-WebSocket 'ws://127.0.0.1:28080/ws')}catch{$oldFailed=$true;Write-Host ('BEFORE: expected WebSocket failure: '+$_.Exception.Message)}
if(-not $oldFailed){throw 'Old ingress unexpectedly passed; regression not reproduced'}
if(-not (Test-WebSocket 'ws://127.0.0.1:28081/ws')){throw 'Fixed ingress did not pass'}
$headers=Invoke-RestMethod 'http://127.0.0.1:28081/headers' -Headers @{Host='360pilot.ru:18000'} -TimeoutSec 10
if($headers.host -ne '360pilot.ru:18000' -or $headers.forwardedHost -ne '360pilot.ru:18000' -or $headers.proto -ne 'https'){throw ('Forwarded headers corrupted: '+($headers|ConvertTo-Json -Compress))}
Write-Host 'AFTER: two-hop WebSocket handshake and bidirectional nonce echo PASS; Host with port, Forwarded-Host and HTTPS scheme PASS.'