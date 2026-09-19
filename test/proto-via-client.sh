#!/bin/bash
set -u
RNIP="107.173.154.178"
PORT=2080
SECRET=$(cat /opt/sb-client/.clash-secret)
API="http://127.0.0.1:19090"
cli(){ curl -s -H "Authorization: Bearer $SECRET" "$@"; }
NODES=$(cli "$API/proxies/PROXY" | jq -r ".all[]")
TESTS=0 PASS=0
for N in $NODES; do
    curl -s -X PUT -H "Authorization: Bearer $SECRET" -H "Content-Type: application/json" -d "{\"name\":\"$N\"}" "$API/proxies/PROXY" -o /dev/null
    sleep 1
    ip=$(curl -s --max-time 12 -x "http://127.0.0.1:$PORT" https://api.ipify.org 2>/dev/null)
    [[ "$ip" != "$RNIP" ]] && ip=$(curl -s --max-time 12 -x "socks5h://127.0.0.1:$PORT" http://ip.sb 2>/dev/null | head -1)
    TESTS=$((TESTS+1))
    if [[ "$ip" == "$RNIP" ]]; then PASS=$((PASS+1)); ST="pass"; else ST="FAIL(ip=$ip)"; fi
    echo "$ST $N"
done
echo "=== $PASS/$TESTS REAL-PASSED via sing-box-client (egress must == $RNIP)"
