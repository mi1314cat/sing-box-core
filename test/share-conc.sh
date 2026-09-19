#!/bin/bash
# 在 RN 上生成并发消费测试产物
set -u
cd /root/catmi/sing-box
# 找一个 max_uses=1, tag=vmess01 的已有 token, 否则新建 (先删除旧 1x)
python3 -c "
import json,glob
for f in glob.glob('/root/catmi/sing-box/share/shares/*.json'):
    m=json.load(open(f))
    if m['tag']=='vmess01' and m['max_uses']==1:
        print(m['share_token']); break
else:
    print('NONE')"
T=$(python3 -c "
import json,glob
for f in glob.glob('/root/catmi/sing-box/share/shares/*.json'):
    m=json.load(open(f))
    if m['tag']=='vmess01' and m['max_uses']==1:
        print(m['share_token']); break
else:
    print('NONE')")
echo "1use-token=$T"
if [[ "$T" == NONE ]]; then
    out=$(bash /root/catmi/sing-box/conf/share.sh create vmess01 1 24 2>/dev/null | head -1)
    T=${out##*/}
fi
echo "TOKEN=$T"
: > /tmp/conc-codes.log
for i in $(seq 1 10); do (curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:9292/share/$T") >> /root/catmi/sing-box/share/conc-codes.log & done
wait
echo "codes:"; sort /root/catmi/sing-box/share/conc-codes.log | uniq -c
python3 -c "
import json,glob
for f in glob.glob('/root/catmi/sing-box/share/shares/*.json'):
    m=json.load(open(f))
    if m.get('tag')=='vmess01' and m['max_uses']==1:
        print('final uses:',m['used_count'],'/',m['max_uses'])"
