#!/bin/bash
# CC 上用 share URL 导入全部节点 (pull from share-server on RN)
set -u
CLIENT="/root/catmi/sb-client-files/client.sh"
IP="107.173.154.178"   # share server host (测试期生产地址, README 已另有泛化)
# 从 RN 抓取所有 share URL 列表
declare -A T
while read -r line; do
    tag=$(echo "$line" | sed 's/.*tag=//;s/ .*//')
    tok=$(echo "$line" | awk '{print $1}' | cut -d. -f1 | head -c 32)
done < <(ssh rn "bash /root/catmi/sing-box/conf/share.sh list 2>/dev/null" 2>/dev/null | grep Active | grep -v UsedUp)
echo "importing from RN share list..."
TOKENS=$(ssh -o ConnectTimeout=15 rn 'python3 -c "
import json,glob,time,os
out={}
for f in glob.glob(\"/root/catmi/sing-box/share/shares/*.json\"):
    m=json.load(open(f))
    if not m.get(\"enabled\"): continue
    if m.get(\"expires_at\",0) and time.time()>m[\"expires_at\"]: continue
    mu,u=m.get(\"max_uses\",0),m.get(\"used_count\",0)
    if mu and u>=mu: continue
    tag=m[\"tag\"]
    if tag not in out or (out[tag][1]==0) : out[tag]=m[\"share_token\"]
for t,tk in sorted(out.items()): print(t,tk)"')
echo "tokens: $TOKENS"
while read -r tag tok; do
    [[ -z "$tok" ]] && continue
    url="http://$IP:9292/share/$tok"
    echo "--- $tag $url"
    bash "$CLIENT" add "$url"
done <<< "$TOKENS"
bash "$CLIENT" list
bash "$CLIENT" status
