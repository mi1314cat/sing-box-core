#!/bin/bash
# 分享链接语义测试: 过期/禁用
set -u
cd /root/catmi/sing-box
T2=$(bash conf/share.sh create trojan01 2 24 2>/dev/null | head -1); echo t2=$T2
# 1) 过期
TE=$(python3 -c "
import json,glob,time
for f in glob.glob('/root/catmi/sing-box/share/shares/*.json'):
    m=json.load(open(f))
    if m['tag']=='trojan01' and m['max_uses']==2 and m['used_count']==0:
        m['expires_at']=int(time.time())-60; open(f,'w').write(json.dumps(m,indent=1)); print(m['share_token']); break")
echo expired-token=$TE
echo "expired GET: $(curl -s -o /dev/null -w '%{http_code}' localhost:9292/share/$TE)"
# 2) 禁用
TD=$(bash conf/share.sh create tuic01 2 24 2>/dev/null | head -1); TD=${TD##*/}
echo disabled-token=$TD
bash conf/share.sh toggle $TD >/dev/null 2>&1
echo "disabled GET: $(curl -s -o /dev/null -w '%{http_code}' localhost:9292/share/$TD)"
bash conf/share.sh toggle $TD >/dev/null 2>&1
curl -s -o /dev/null -w "re-enabled 1st GET: %{http_code}\n" localhost:9292/share/$TD
# 3) malformed token
curl -s -o /dev/null -w "short-token: %{http_code}\n" localhost:9292/share/abc
curl -s -o /dev/null -w "unknown: %{http_code}\n" localhost:9292/share/0000000000000000000000000000000z
