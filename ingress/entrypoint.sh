#!/bin/sh
set -eu

# DNS is required only to resolve Compose service names. All other outbound
# traffic is blocked before nginx starts.
iptables -P OUTPUT DROP
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -d 127.0.0.11 -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -d 127.0.0.11 -p tcp --dport 53 -j ACCEPT

for pair in pilot-server:5545 pilot-web-server:80 pilot-web-myadmin:5200; do
  host="${pair%:*}"
  port="${pair#*:}"
  ip="$(getent hosts "$host" | awk 'NR==1 { print $1 }')"
  test -n "$ip"
  iptables -A OUTPUT -d "$ip" -p tcp --dport "$port" -j ACCEPT
done

exec /docker-entrypoint.sh "$@"
