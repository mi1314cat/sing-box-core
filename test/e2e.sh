#!/bin/bash
# ==============================================================
# e2e-tests.sh — SB-Panel 真实连通性三级测试 (CC 端运行)
# Level1: config check / Level2: service+listen / Level3: 真实客户端连接→公网
# 使用服务端 sb_client-<tag>.json (真实产物) 组装本地 mixed 客户端,
# curl -x 通过节点请求 http://ip.sb, 结果必须 == 203.0.113.10
# ==============================================================
SB_BASE="${SB_BASE:-/opt/sb-panel/sing-box}"
BIN="$SB_BASE/sing-box"
CLIENT_OUT="$SB_BASE/test-configs"          # 客户端 out 片目录 (从 RN 同步)
RESULTS_DIR="${TEST_RESULTS:-/opt/sb-panel/sb-test-results}"
RN_IP="203.0.113.10"
BASE_PORT=21000
mkdir -p "$RESULTS_DIR" "$CLIENT_OUT"

# 期望的 (tag, client_file, listen_port) 三元组
declare -a TAGS=("reality03" "vmess02" "trojan01" "naive01" "anyresanity001" "shadowtlsm1" "shadowsocks01" "vless01" "hysteria201" "tuic01" "anyreality01" "reality01")
declare -a FILES=("sb_client-reality03.json" "sb_client-vmess01.json" "sb_client-vmess02.json" "sb_client-trojan01.json" "sb_client-naive01.json" "sb_client-shadowtls01.json" "sb_client-shadowsocks01.json" "sb_client-vless01.json" "sb_client-hysteria201.json" "sb_client-tuic01.json" "sb_client-anyreality01.json" "sb_client-reality01.json" "sb_client-reality02.json")

run_test() {
    local name="$1" file="$2" port="$3"
    local cfg="$CLIENT_OUT/cfg-$name.json"
    python3 - "$file" "$cfg" "$port" <<'PYGEN'
import json,sys
src,dst,port=sys.argv[1],sys.argv[2],int(sys.argv[3])
c=json.load(open(src))
cfg={"inbounds":[{"type":"mixed","tag":"m","listen":"127.0.0.1","listen_port":port}],
     "outbounds":c["outbounds"],
     "route":{"final":c["outbounds"][-1]["tag"]}}
json.dump(cfg,open(dst,"w"),indent=1)
PYGEN
    local log="$RESULTS_DIR/$name-serverlog.txt"
    nohup "$BIN" run -c "$cfg" > "$log" 2>&1 &
    local pid=$!
    sleep 2
    local res
    res=$(curl -s --max-time 15 -x "socks5h://127.0.0.1:$port" http://ip.sb | head -1)
    [[ -z "$res" ]] && res=$(curl -s --max-time 15 -x "http://127.0.0.1:$port" https://api.ipify.org | head -1)
    local st="FAIL"
    [[ "$res" == "$RN_IP" ]] && st="PASS"
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null
    echo "$name:$st:$res"
}

echo "protocol,status,ip" > "$RESULTS_DIR/e2e-results.csv"
i=0
for f in "${FILES[@]}"; do
    # 从 RN 拉取
    scp -q "rn:/opt/sb-panel/sing-box/out/$f" "$CLIENT_OUT/" 2>/dev/null || { echo "?,$f,scp-fail" >> "$RESULTS_DIR/summary.log"; continue; }
    name=$(basename "$f" | sed 's/sb_client-//;s/\.json//')
    ((i++)); port=$((BASE_PORT+i))
    run_test "$name" "$CLIENT_OUT/$f" "$port" | tee -a "$RESULTS_DIR/e2e-results.csv"
done
echo DONE
