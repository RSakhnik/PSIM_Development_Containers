[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $PublicHost,
    [ValidateRange(1,65535)][int] $ControlPublicPort = 17443,
    [ValidateRange(1,65535)][int] $WebPublicPortStart = 18000,
    [ValidateRange(1,65535)][int] $WebPublicPortEnd = 18049,
    [ValidateRange(1,65535)][int] $AdminPublicPortStart = 19000,
    [ValidateRange(1,65535)][int] $AdminPublicPortEnd = 19049,
    [string] $Upstream = 'http://host.docker.internal:17070',
    [Parameter(Mandatory = $true)][string] $OutputFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ps-compat.ps1')
if ($WebPublicPortEnd -lt $WebPublicPortStart -or $AdminPublicPortEnd -lt $AdminPublicPortStart) { throw 'Invalid public port range.' }
if (($WebPublicPortEnd - $WebPublicPortStart) -ne ($AdminPublicPortEnd - $AdminPublicPortStart)) { throw 'Web and myAdmin ranges must have equal size.' }

$listenLines = @($ControlPublicPort) + @($WebPublicPortStart..$WebPublicPortEnd) + @($AdminPublicPortStart..$AdminPublicPortEnd) |
    ForEach-Object { "listen $_ ssl;" }
$text = @"
# Generated Pilot Environment port-routing fragment.
# Include this file INSIDE a dedicated nginx `server { ... }` block that contains
# the existing ssl_certificate / ssl_certificate_key directives for $PublicHost.
$($listenLines -join [Environment]::NewLine)
server_name $PublicHost;

client_max_body_size 2g;

location / {
    proxy_pass $Upstream;
    proxy_http_version 1.1;
    proxy_set_header Upgrade `$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host `$host:`$server_port;
    proxy_set_header X-Forwarded-Host `$host:`$server_port;
    proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_request_buffering off;
    proxy_buffering off;
    proxy_cache off;
    proxy_connect_timeout 10s;
    proxy_send_timeout 86400s;
    proxy_read_timeout 86400s;
    send_timeout 86400s;
}
"@
$parent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputFile))
if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
Write-PilotUtf8NoBom -LiteralPath $OutputFile -Text $text
[pscustomobject]@{ outputFile = [IO.Path]::GetFullPath($OutputFile); publicHost = $PublicHost; controlPort = $ControlPublicPort; webPorts = "$WebPublicPortStart-$WebPublicPortEnd"; adminPorts = "$AdminPublicPortStart-$AdminPublicPortEnd" }
