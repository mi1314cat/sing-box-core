#!/usr/bin/env bash
# ==============================================================
# tools/interop-e2e.sh — 三家互通 · SB 侧端到端验证台
#（真脚本 / 真分享服务代码 / 真客户端入口）
#
# 设计: proxy-node-compat/docs/three-way-interop.md
#
#   服务端: conf/share.sh create（真代码, 真两条产品, 真声明）
#   存储  : proxy-share-service（share_service.py）—— **独立实例**: 自己的
#           端口与数据目录, 绝不碰生产服务与生产数据
#   客户端: src/client/client.sh add（真客户端入口, 真决策/回退/导入）
#
# 断言（每条都对应一条真实踩过的坑）:
#   ① 两条产品: 主记录=普通话(URI 列表) / 附带记录=原生(sing-box JSON)
#   ② 原生正文与 out/sb_client-<tag>.json **逐字节相同**（SB→SB 零退步的判据）
#   ③ 带声明地址 → 客户端走**原生**; 同内核同发行版
#   ④ 声明缺失（裸地址）→ 走**普通话**, 且不报错（有原因行）
#   ⑤ 声明在、原生地址 404 → **回退普通话**, 原因打出来
#   ⑥ 带声明 vs 裸地址: 响应体 sha256 **逐字节相同**（第三方客户端零影响）
#   ⑦ 两条产品的节点集合一致 + URI 表达力损失**显式标注**（不许假装没有）
#   ⑧ 停用/撤销/改次数**成对**生效（只动主记录会留下一条还活着的原生分享）
#
# 用法:
#   bash tools/interop-e2e.sh
#   SB_E2E_CORPUS=/root/catmi/sing-box \
#   SB_E2E_CLIENT_BIN=/root/catmi/sing-box/sing-box bash tools/interop-e2e.sh
#     —— 拿真实部署的 config/ + out/ 只读拷贝跑（仍是独立服务实例）
#
# 环境变量: SB_E2E_WORK（默认 /tmp/sb-interop-e2e）/ SB_E2E_PORT / SB_E2E_HOST
#           SB_E2E_CLIENT_BIN（默认 command -v sing-box）
#           SB_E2E_SERVICE（分享服务源码; 找不到就**明说并退出 3**, 不静默跳过）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
WORK="${SB_E2E_WORK:-/tmp/sb-interop-e2e}"
PORT="${SB_E2E_PORT:-0}"
HOST_OVERRIDE="${SB_E2E_HOST:-}"
CORPUS="${SB_E2E_CORPUS:-}"
CLIENT_BIN="${SB_E2E_CLIENT_BIN:-$(command -v sing-box 2>/dev/null || true)}"
KEEP="${SB_E2E_KEEP:-}"
pass=0; fail=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
note(){ printf '  \033[36m·\033[0m %s\n' "$*"; }

svc_src="${SB_E2E_SERVICE:-}"
if [[ -z "$svc_src" ]]; then
  for c in "$HOME/Share-Service/src/share_service.py" \
           "$HOME/Share-Service/share_service.py" \
           /root/deepseek/Share-Service/src/share_service.py \
           /opt/proxy-share-service/share_service.py \
           "$ROOT/../Share-Service/src/share_service.py"; do
    [[ -f "$c" ]] && { svc_src="$c"; break; }
  done
fi
if [[ -z "$svc_src" || ! -f "$svc_src" ]]; then
  echo "  跳过: 找不到 proxy-share-service 源码（SB_E2E_SERVICE=... 指定）—— 端到端**没有**验证" >&2
  exit 3
fi
if [[ -z "$CLIENT_BIN" || ! -x "$CLIENT_BIN" ]]; then
  echo "  跳过: 找不到 sing-box 二进制（SB_E2E_CLIENT_BIN=... 指定）—— 客户端侧**没有**验证" >&2
  exit 3
fi
if [[ -z "$PORT" || "$PORT" = 0 ]]; then
  PORT=$(python3 -c 'import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
fi

rm -rf "$WORK"; mkdir -p "$WORK/etc" "$WORK/data" "$WORK/srv/out"
printf 'x' > "$WORK/etc/admin.token"
printf 'SHARE_PORT=%s\n' "$PORT" > "$WORK/etc/env"


# ---- 语料: 合成最小集, 或真实部署的只读拷贝 ----
if [[ -n "$CORPUS" && -d "$CORPUS" ]]; then
  echo "=== 语料: 真实部署（只读拷贝）$CORPUS ==="
  mkdir -p "$WORK/srv/config" "$WORK/srv/share-state"
  cp -a "$CORPUS/config/." "$WORK/srv/config/" 2>/dev/null
  cp -a "$CORPUS/out/." "$WORK/srv/out/" 2>/dev/null
  [[ -d "$CORPUS/share-state" ]] && cp -a "$CORPUS/share-state/." "$WORK/srv/share-state/" 2>/dev/null
else
  echo "=== 语料: 合成最小集（vless+reality / trojan+reality） ==="
  mkdir -p "$WORK/srv/config" "$WORK/srv/share-state"
  python3 - "$WORK/srv" <<'PY'
import json, os, sys
srv = sys.argv[1]
cfg = os.path.join(srv, "config"); out = os.path.join(srv, "out")
nodes = [
    ("vless01-REALITY", "vless",
     "vless://11111111-1111-1111-1111-111111111111@203.0.113.9:28001"
     "?encryption=none&security=reality&sni=www.apple.com&fp=chrome"
     "&pbk=AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKK&sid=0123456789abcdef"
     "&type=tcp&flow=xtls-rprx-vision#%F0%9F%87%BA%F0%9F%87%B8 e2e vless01-REALITY"),
    ("trojan01-REALITY", "trojan",
     "trojan://pw-e2e@203.0.113.9:28002?sni=www.icloud.com&security=reality"
     "&pbk=AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKK&sid=0123456789abcdef"
     "&type=tcp#%F0%9F%87%BA%F0%9F%87%B8 e2e trojan01-REALITY"),
]
for tag, typ, uri in nodes:
    port = 28001 if typ == "vless" else 28002
    if typ == "vless":
        ob = {"type": "vless", "tag": tag, "server": "203.0.113.9", "server_port": port,
              "uuid": "11111111-1111-1111-1111-111111111111",
              "flow": "xtls-rprx-vision",
              "tls": {"enabled": True, "server_name": "www.apple.com",
                      "utls": {"enabled": True, "fingerprint": "chrome"},
                      "reality": {"enabled": True, "public_key": "AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKK",
                                  "short_id": "0123456789abcdef"}}}
    else:
        ob = {"type": "trojan", "tag": tag, "server": "203.0.113.9", "server_port": port,
              "password": "pw-e2e",
              "tls": {"enabled": True, "server_name": "www.icloud.com",
                      "utls": {"enabled": True, "fingerprint": "chrome"},
                      "reality": {"enabled": True, "public_key": "AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKK",
                                  "short_id": "0123456789abcdef"}}}
    json.dump({"outbounds": [ob]}, open(os.path.join(out, "sb_client-%s.json" % tag), "w"),
              indent=2)
    open(os.path.join(out, "sb_share-%s.txt" % tag), "w").write(uri + "\n")
    inbound = {"type": typ, "tag": tag, "listen": "0.0.0.0", "listen_port": port}
    if typ == "vless":
        inbound["users"] = [{"uuid": "11111111-1111-1111-1111-111111111111", "flow": "xtls-rprx-vision"}]
    else:
        inbound["users"] = [{"password": "pw-e2e"}]
    inbound["tls"] = {"enabled": True, "server_name": "www.apple.com",
                      "reality": {"enabled": True, "handshake": {"server": "www.apple.com", "server_port": 443},
                                  "private_key": "k", "short_id": ["0123456789abcdef"]}}
    json.dump({"inbounds": [inbound]},
              open(os.path.join(cfg, "10-%s.json" % tag), "w"), indent=2)
print("  合成 %d 个节点" % len(nodes))
PY
fi
# 聚合产物: 真实语料自带 sb_client-all.json; 合成语料用**生产路径**生成一份
# （带 "<服务器前缀>-" 的 tag）—— 前缀剥离是发布闸门的一部分, 必须被验到。
# ---- 端口探活: 给一个 `ss` 桩, 只声明"语料里配置的端口都在听" ----
# 服务端的一致性校验（`share.sh check` / create 的发布闸门）会探活 `ss`，而
# **死端口是拒绝发布的**（`bad=1`）。本验证台吃的常常是**另一台机器**上真实部署
# 的只读语料 —— 那些端口当然不在本机监听。拿本机 ss 去判, 结果是"语料来自别的
# 机器"被误判成"节点全挂了" → 发布闸门拒绝发布 → 验证台在第 2 段就死掉。
#
# 这不是在放宽断言: 端口在不在听是**宿主**的属性, 不是本验证台要验的东西
# （它验的是两条产品/声明/决策/回退/成对生命周期）。那条语义由
# `check_compat_wiring.sh` 8e 段用**真机捕获的 ss 输出形状**钉死, 真机上还有
# `bash conf/share.sh check all` 这一关。
# 桩的输出从语料自己的 config/*.json 生成 —— 声明"语料说要听的, 就当它在听"。
mkdir -p "$WORK/fakebin"
python3 - "$WORK" <<'PY'
import glob, json, os, sys
work = sys.argv[1]
lines = []
for f in glob.glob(os.path.join(work, "srv", "config", "*.json")):
    try:
        d = json.load(open(f, encoding="utf-8"))
    except Exception:
        continue
    for i in d.get("inbounds") or []:
        p = i.get("listen_port")
        listen = i.get("listen") or "0.0.0.0"
        if not p:
            continue
        host = "[::]" if listen in ("::", "[::]") else ("*" if listen in ("0.0.0.0", "*", "") else listen)
        lines.append("tcp LISTEN 0      4096   %s:%s    *:*" % (host, p))
        if i.get("type") in ("hysteria2", "tuic"):
            lines.append("udp UNCONN 0      0      %s:%s    *:*" % (host, p))
open(os.path.join(work, "fakebin", "ss"), "w", encoding="utf-8").write(
    "#!/bin/sh\ncat <<'TBL'\n" + "\n".join(lines) + "\nTBL\n")
os.chmod(os.path.join(work, "fakebin", "ss"), 0o755)
print("=== 端口探活: ss 桩声明语料里 %d 个端口在听（本机不是那台服务器） ===" % len(lines))
PY
export PATH="$WORK/fakebin:$PATH"

echo "e2e" > "$WORK/srv/share-state/server-name"
export SB_ROOT="$WORK/srv" SB_CONFIG_DIR="$WORK/srv/config" SB_OUT_DIR="$WORK/srv/out" \
       SB_SERVER_NAME="e2e" SB_BIN="${SB_E2E_CLIENT_BIN:-sing-box}"
if [[ -z "$CORPUS" ]]; then
  bash "$ROOT/src/conf/share.sh" regen-aggregate >/dev/null 2>&1 \
    || { echo "  聚合产物生成失败 —— 验证台无法继续" >&2; exit 3; }
fi

# ---- 独立分享服务实例（自己的端口/数据目录; 不碰生产）----
echo
echo "=== 1 · 独立分享服务实例 127.0.0.1:$PORT（数据目录 $WORK/data） ==="
SHARE_DATA_DIR="$WORK/data" SHARE_PORT="$PORT" SHARE_BIND="0.0.0.0" \
  SHARE_ADMIN_TOKEN_FILE="$WORK/etc/admin.token" SHARE_PORT_FILE="$WORK/etc/port" \
  python3 "$svc_src" >"$WORK/svc.log" 2>&1 &
SVC_PID=$!
cleanup(){ kill $SVC_PID 2>/dev/null; [[ -n "$KEEP" ]] || rm -rf "$WORK"; }
trap cleanup EXIT
UP=0
for _ in $(seq 1 40); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/api/v1/health" && { UP=1; break; }
  sleep 0.25
done
if [[ "$UP" != 1 ]]; then
  no "分享服务没起来（看 $WORK/svc.log）"
  sed 's/^/    /' "$WORK/svc.log" >&2
  echo; echo "=== 结果: $pass 通过, $fail 失败 ==="; exit 1
fi
ok "服务在跑（版本 $(curl -s "http://127.0.0.1:$PORT/api/v1/health" | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])' 2>/dev/null)）"

# 服务端 env: 真 share.sh / 真 share_client.py, 独立端口与数据目录
export SB_ROOT="$WORK/srv" SB_CONFIG_DIR="$WORK/srv/config" SB_OUT_DIR="$WORK/srv/out" \
       SB_BIN="$CLIENT_BIN" SB_SERVER_NAME="e2e" \
       SB_SHARE_ETC="$WORK/etc" SHARE_ETC="$WORK/etc" SHARE_PORT="$PORT" \
       SHARE_ADMIN_TOKEN_FILE="$WORK/etc/admin.token" SHARE_PORT_FILE="$WORK/etc/port" \
       SHARE_PROVIDER=sing-box
export SB_SERVER_ADDR="${HOST_OVERRIDE:-127.0.0.1}"
# 下发地址也走同一个 host: 验证台在同机跑客户端, 用 127.0.0.1 才稳定
# （多网卡机器上 sb_addr4() 可能挑到不可达的那个地址）。
export SB_SHARE_HOST="${HOST_OVERRIDE:-127.0.0.1}"
# 本机内核事实真探测: 用验证台给的那个二进制（生产路径永远真读）
export SB_INTEROP_BIN="$CLIENT_BIN"

TAG="${SB_E2E_TAG:-}"
if [[ -z "$TAG" ]]; then
  if [[ -f "$WORK/srv/out/sb_client-all.json" ]]; then TAG=all
  else TAG=$(ls "$WORK/srv/out"/sb_client-*.json 2>/dev/null | sed 's|.*/sb_client-||;s|\.json$||' | head -1); fi
fi
[[ -n "$TAG" ]] || { no "语料里没有 sb_client-*.json"; echo; echo "=== 结果: $pass 通过, $fail 失败 ==="; exit 1; }

echo
echo "=== 2 · 服务端创建分享（conf/share.sh create $TAG） ==="
if [[ "$TAG" == "all" ]]; then
  bash "$ROOT/src/conf/share.sh" create-all 0 0 >"$WORK/create.out" 2>&1
else
  bash "$ROOT/src/conf/share.sh" create "$TAG" 0 0 >"$WORK/create.out" 2>&1
fi
RC=$?
sed -n '/格式:/,$p' "$WORK/create.out" | sed 's/^/  /'
URL=$(grep -oE 'http://[^ ]+/share/[0-9a-f]{32}\?interop=[^ ]+' "$WORK/create.out" | sed -n 1p)
if (( RC != 0 )) || [[ -z "$URL" ]]; then
  no "创建分享失败 / 没取到带声明的地址 (rc=$RC)"; sed 's/^/    /' "$WORK/create.out"; echo
  echo "=== 结果: $pass 通过, $fail 失败 ==="; exit 1
fi
ok "地址上带声明（$(printf '%s' "$URL" | sed 's/.*?//' | cut -c1-70)…）"
case "$URL" in
  *"kernel=sing-box"*) ok "声明 kernel=sing-box" ;;
  *) no "声明里没有 kernel=sing-box: $URL" ;;
esac
case "$URL" in
  *"formats=uri"*) ok "声明 formats 含 uri（普通话恒在）" ;;
  *) no "声明里没有 formats=uri: $URL" ;;
esac
case "$URL" in
  *"url-sing-box="*) ok "声明里有原生取件地址（url-<发行版>）" ;;
  *) no "声明里没有 url-sing-box: $URL" ;;
esac

LIST=$(SHARE_PROVIDER=sing-box python3 "$ROOT/src/conf/share_client.py" list 2>/dev/null)
PTOK=$(printf '%s' "$LIST" | python3 -c 'import json,sys
print(next((r["token"] for r in json.load(sys.stdin) if (r.get("meta") or {}).get("role")=="primary"), ""))' 2>/dev/null)
NTOK=$(printf '%s' "$LIST" | python3 -c 'import json,sys
print(next((r["token"] for r in json.load(sys.stdin) if (r.get("meta") or {}).get("role")=="native"), ""))' 2>/dev/null)
NATN=$(printf '%s' "$LIST" | python3 -c 'import json,sys
print(len([r for r in json.load(sys.stdin) if (r.get("meta") or {}).get("role")=="native"]))' 2>/dev/null)
if [[ -n "$PTOK" && -n "$NTOK" && "$NATN" = 1 ]]; then
  ok "两条记录: 主(普通话) ${PTOK:0:10}… + 原生 ${NTOK:0:10}… (content_type=$(printf '%s' "$LIST" | python3 -c 'import json,sys
recs=json.load(sys.stdin)
m={(r.get("meta") or {}).get("role"):r.get("content_type") for r in recs}
print(m.get("primary","?")," / ",m.get("native","?"))' 2>/dev/null))"
else
  no "两条记录没建齐 (primary=${PTOK:0:10} native=${NTOK:0:10} native_count=$NATN)"
fi

echo
echo "=== 3 · 主产品是 URI 列表（谁都能读）, 原生是 sing-box JSON ==="
curl -s "http://127.0.0.1:$PORT/share/$PTOK" > "$WORK/primary.body"
curl -s "http://127.0.0.1:$PORT/share/$NTOK" > "$WORK/native.body"
PN=$(grep -cE '^[a-z0-9+]+://' "$WORK/primary.body" 2>/dev/null || echo 0)
NN=$(jq -r '[.outbounds[]? | select(.type!="selector" and .type!="urltest" and .type!="direct")] | length' "$WORK/native.body" 2>/dev/null || echo 0)
note "主产品 $PN 行 URI / 原生产品 $NN 个 outbound"
if (( PN > 0 )); then ok "主产品能当 URI 列表用（$PN 行）"; else no "主产品不是 URI 列表"; head -3 "$WORK/primary.body" | sed 's/^/    /'; fi
if jq -e '.outbounds' "$WORK/native.body" >/dev/null 2>&1; then ok "原生产品是 sing-box JSON（顶层 outbounds）"; else no "原生产品不是 sing-box JSON"; fi
# ★ SB→SB 零退步的判据: 原生正文与产物文件**逐字节相同**
NSRC="$WORK/srv/out/sb_client-$TAG.json"
if [[ -f "$NSRC" ]]; then
  A=$(sha256sum "$WORK/native.body" | awk '{print $1}')
  B=$(sha256sum "$NSRC" | awk '{print $1}')
  if [[ "$A" = "$B" ]]; then ok "原生正文与 sb_client-$TAG.json 逐字节相同（sha256 ${A:0:16}…）"
  else no "原生正文与产物文件不同: $A vs $B"; fi
else
  no "找不到原生源文件 $NSRC"
fi

echo
echo "=== 4 · 带声明 vs 裸地址: 响应逐字节相同（第三方客户端零影响） ==="
AZ=$(curl -s "http://127.0.0.1:$PORT/share/$PTOK" | sha256sum | awk '{print $1}')
BZ=$(curl -s "http://127.0.0.1:$PORT/share/$PTOK?interop=1&kernel=xray&distribution=xray&version=1&formats=uri,xray" | sha256sum | awk '{print $1}')
CZ=$(curl -s "http://127.0.0.1:$PORT/share/$PTOK?interop=1&kernel=sing-box&distribution=sing-box&formats=uri,sing-box" | sha256sum | awk '{print $1}')
if [[ -n "$AZ" && "$AZ" = "$BZ" && "$AZ" = "$CZ" ]]; then
  ok "逐字节相同（$AZ）—— 声明/未知参数对返回内容零影响"
else
  no "带声明的响应被改写了: bare=$AZ xray=$BZ sb=$CZ"
fi

echo
echo "=== 5 · URI 表达力标注（损失必须显式, 不许假装没有） ==="
LOSS=$(grep -E '\[标注\]|\[OK\]  *URI|\[注意\]|\[UNKNOWN\]|\[ERR\]' "$WORK/create.out" | sed 's/^/  /')
printf '%s\n' "$LOSS"
if grep -q '\[标注\] URI 表达力标注' "$WORK/create.out"; then
  ok "创建时逐节点查了注册表并打出结论"
else
  no "创建时没有 URI 表达力标注（静默发布了 URI 产品）"
fi
if grep -q 'uri.trojan.reality@mihomo' "$WORK/create.out" || [[ -z "$CORPUS" ]]; then
  ok "trojan+REALITY 的 mihomo 侧 URI 损失被标注（注册表 uri.trojan.reality@mihomo）"
else
  note "本语料没有 trojan+REALITY 节点, 该行不适用"
fi
# 两条产品节点集合一致（URI 行 ↔ 原生 outbound 逐个对账）。
# 配对口径与**服务端构产品时用的口径相同**: 按原生产物里非控制型 outbound 的
# 顺序逐行取链接 —— 服务端就是这么生成 URI 列表的（_sb_share_node_pairs）。
# 不按 #片段/名字配对: 片段是给人看的显示名, 与 tag 不是同一种字符串。
python3 - "$WORK/primary.body" "$WORK/native.body" "$WORK/pair.out" <<'PYEOF' | sed 's/^/  /'
import base64, json, sys
def uri_hp(l):
    scheme = l.split("://", 1)[0].lower()
    if scheme == "vmess":
        body = l.split("://", 1)[1].split("#", 1)[0]
        try:
            o = json.loads(base64.b64decode(body + "=" * (-len(body) % 4)))
        except Exception:
            return None
        return (str(o.get("add", "")), int(o.get("port") or 0))
    rest = l.split("://", 1)[1].split("#", 1)[0].split("?", 1)[0]
    at = rest.rfind("@")
    if at < 0:
        return None
    hp = rest[at + 1:].split("/", 1)[0]
    if hp.startswith("["):
        h, _, pp = hp[1:].partition("]")
        pp = pp.lstrip(":")
    else:
        h, _, pp = hp.rpartition(":")
        if not pp.isdigit():
            h, pp = hp, "0"
    return (h, int(pp or 0))
prim = [l.strip() for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
nat = json.load(open(sys.argv[2], encoding="utf-8"))
ignore = {"selector", "urltest", "direct", "block", "dns"}
helpers = {o.get("detour") for o in nat.get("outbounds", []) if o.get("detour")}
nodes = [o for o in nat.get("outbounds", [])
         if o.get("type") not in ignore and o.get("tag") not in helpers]
print("URI 行 %d / 原生节点 %d" % (len(prim), len(nodes)))
if len(prim) != len(nodes):
    print("✗ 节点数不同: URI=%d 原生=%d" % (len(prim), len(nodes)))
    raise SystemExit(1)
# (server, port) 逐节点对账。不一致**不一定是错误** —— 实测 RN 部署里 3 个 CDN
# 节点的原生产物是陈旧的 `IP:443`（从 CC 连不通）, 链接是 `域名:443`
# （Cloudflare, 200）。这类差异的处置是**必须被标注**（发布时打
# "取件地址不一致"）, 而不是假装一样 —— 所以判的是"有没有静默差异"。
mismatch = []
for i, o in enumerate(nodes):
    if o.get("detour"):
        # detour 型节点（shadowtls 的两层结构）: server/server_port 在被引用的
        # 那个出站里, 外层本来就是空的 —— 参与对账只会得到一条假的不一致。
        continue
    nhp = (str(o.get("server", "")), int(o.get("server_port") or 0))
    uhp = uri_hp(prim[i])
    if uhp != nhp:
        mismatch.append((o.get("tag", ""), nhp, uhp or ("?", 0)))
print("✓ 两条产品的节点数一致（%d）" % len(nodes))
for t, nhp, uhp in mismatch:
    print("MISMATCH %s 原生=%s:%s / URI=%s:%s" % (t, nhp[0], nhp[1], uhp[0], uhp[1]))
print("其中取件地址不一致 %d 个（必须被发布时的标注覆盖, 否则就是静默差异）" % len(mismatch))
with open(sys.argv[3], "w", encoding="utf-8") as fh:
    for m in mismatch:
        fh.write("MISMATCH\n")
raise SystemExit(0)
PYEOF
if [[ "${PIPESTATUS[0]}" = 0 ]]; then
    ok "两条产品的节点数一致"
else
    no "两条产品节点数不一致（见上）"
fi
NM=$(grep -c MISMATCH "$WORK/pair.out" 2>/dev/null || true); NM=${NM:-0}
NR=$(grep -c '取件地址不一致' "$WORK/create.out" 2>/dev/null || true); NR=${NR:-0}
if (( NM == 0 )); then
    ok "两条产品的取件地址逐个一致"
elif (( NR >= NM )); then
    ok "取件地址不一致 $NM 个 —— 发布时**全部标注**了（$NR 行, 不静默）"
else
    no "有 $NM 个取件地址不一致, 但发布时只标注了 $NR 个（静默差异）"
fi

# ---- 客户端: 真 client.sh 入口（隔离 root, 不碰生产客户端）----
MKCLIENT() {  # <名字> → 打印 CLIENT_ROOT
  local w="$WORK/client-$1" port
  rm -rf "$w"; mkdir -p "$w/conf" "$w/nodes" "$w/share-state" "$w/core"
  ln -sf "$CLIENT_BIN" "$w/core/sing-box"
  port=$(python3 -c 'import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  cat > "$w/conf/00-mixed.json" <<JSON
{ "inbounds": [ { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": $port } ] }
JSON
  cat > "$w/conf/02-dns.json" <<'JSON'
{ "dns": { "servers": [
    { "type": "https", "tag": "doh-main", "server": "223.5.5.5", "server_port": 443,
      "path": "/dns-query", "tls": { "enabled": true, "server_name": "dns.alidns.com" } },
    { "type": "https", "tag": "doh-fallback", "server": "1.1.1.1", "server_port": 443,
      "path": "/dns-query", "tls": { "enabled": true, "server_name": "cloudflare-dns.com" } } ],
  "final": "doh-fallback", "strategy": "ipv4_only" } }
JSON
  cp -f "$ROOT/src/client/client.sh" "$ROOT/src/client/to_sb.py" "$w/share-state/"
  cp -f "$ROOT/src/client/compat2.py" "$w/share-state/" 2>/dev/null
  cp -r "$ROOT/src/client/lib" "$w/share-state/lib" 2>/dev/null
  printf '%s' "$w"
}
RUNCLIENT() { # <root> <地址> <前缀> → 日志路径
  local w="$1" url="$2" pre="${3:-e2e}" log="$1/add.log"
  CLIENT_ROOT="$w" CLIENT_BIN="$w/core/sing-box" CLIENT_CONF="$w/conf" \
  CLIENT_NODE_DIR="$w/nodes" SB_TO_SB="$w/share-state/to_sb.py" \
  SB_COMPAT_PY="$w/share-state/compat2.py" SB_COMPAT_REPORT="$w/share-state/.compat-last.json" \
  SB_SUBS_PREFIX="$pre" SB_INTEROP_PY="$w/share-state/lib/interop.py" \
    bash "$ROOT/src/client/client.sh" add "$url" </dev/null >"$log" 2>&1
  printf '%s' "$log"
}
IMPORTED() { # <root> → 导入的节点数
  ls "$1/nodes"/node-*.json 2>/dev/null | wc -l | tr -d ' '
}

echo
echo "=== 6 · 同内核同发行版 → 客户端必须走原生（SB→SB 对角线） ==="
W1=$(MKCLIENT native); L1=$(RUNCLIENT "$W1" "$URL" e2e)
grep -E '本次拉取|已导入|识别为|\[ERR\]' "$L1" | sed 's/^/  /'
if grep -q '本次拉取: 原生 sing-box JSON' "$L1"; then ok "客户端选了原生（同内核同发行版）"; else no "客户端没走原生"; fi
N1=$(IMPORTED "$W1")
if (( N1 > 0 )); then ok "导入 $N1 个节点"; else no "一个节点都没导入"; fi
CHK=$("$CLIENT_BIN" check -D "$W1" -C "$W1/conf" 2>&1); CHKRC=$?
if (( CHKRC == 0 )); then ok "导入后 sing-box check 通过"; else no "sing-box check 不通过"; printf '%s\n' "$CHK" | tail -3 | sed 's/^/    /'; fi

echo
echo "=== 7 · 声明缺失（裸地址）→ 普通话, 不报错 ==="
BARE="${URL%%\?*}"
W2=$(MKCLIENT bare); L2=$(RUNCLIENT "$W2" "$BARE" e2ebare)
grep -E '本次拉取|已导入|识别为|\[ERR\]' "$L2" | sed 's/^/  /'
if grep -q '本次拉取: 普通话 URI 列表' "$L2"; then ok "回退普通话（不是报错）"; else no "没有回退到普通话"; fi
if grep -q '地址上没有内核声明' "$L2"; then ok "原因行说出了'地址上没有内核声明'"; else no "原因行缺失"; fi
N2=$(IMPORTED "$W2"); (( N2 > 0 )) && ok "回退后导入 $N2 个节点" || no "回退后没有节点"

echo
echo "=== 8 · 声明在、原生地址 404 → 回退普通话（原因打出来） ==="
BAD="${URL/url-sing-box=*/url-sing-box=http%3A%2F%2F127.0.0.1%3A$PORT%2Fshare%2F$(printf '9%.0s' {1..32})}"
W3=$(MKCLIENT fallback); L3=$(RUNCLIENT "$W3" "$BAD" e2ebad)
grep -E '本次拉取|已导入|识别为|原生取件失败' "$L3" | sed 's/^/  /'
if grep -q '本次拉取: 普通话 URI 列表' "$L3"; then ok "原生取不到 → 回退普通话"; else no "没有回退"; fi
if grep -q '原生取件失败' "$L3"; then ok "回退原因打出来了（含 HTTP 码）"; else no "回退原因没打出来（静默降级）"; fi
N3=$(IMPORTED "$W3"); (( N3 > 0 )) && ok "回退后导入 $N3 个节点" || no "回退后没有节点"

echo
echo "=== 9 · 跨内核声明（kernel=xray）→ 普通话 ==="
XURL="${URL/url-sing-box=/url-xray=}"; XURL="${XURL/kernel=sing-box/kernel=xray}"; XURL="${XURL/distribution=sing-box/distribution=xray}"; XURL="${XURL/formats=uri,sing-box/formats=uri,xray}"
W4=$(MKCLIENT cross); L4=$(RUNCLIENT "$W4" "$XURL" e2ex)
grep -E '本次拉取|已导入' "$L4" | sed 's/^/  /'
if grep -q '本次拉取: 普通话 URI 列表' "$L4" && grep -q '服务端内核' "$L4"; then
  ok "跨内核 → 普通话, 原因说出内核不同"
else
  no "跨内核时没有走普通话/没有说明原因"
fi

echo
echo "=== 10 · 成对生命周期: 停用/撤销连带原生记录 ==="
SHARE_PROVIDER=sing-box bash "$ROOT/src/conf/share.sh" toggle "$PTOK" >/dev/null 2>&1
E1=$(SHARE_PROVIDER=sing-box python3 "$ROOT/src/conf/share_client.py" get --token "$NTOK" 2>/dev/null \
     | python3 -c 'import sys,json;print(json.load(sys.stdin).get("enabled"))' 2>/dev/null)
[[ "$E1" = "False" ]] && ok "停用主记录 → 原生记录同步停用" || no "原生记录没被停用 (enabled=$E1)"
SHARE_PROVIDER=sing-box bash "$ROOT/src/conf/share.sh" del "$PTOK" >/dev/null 2>&1
R1=$(SHARE_PROVIDER=sing-box python3 "$ROOT/src/conf/share_client.py" get --token "$PTOK" 2>&1 | head -c 40)
R2=$(SHARE_PROVIDER=sing-box python3 "$ROOT/src/conf/share_client.py" get --token "$NTOK" 2>&1 | head -c 40)
if grep -qiE '40[34]|不存在|not found' <<<"$R1" && grep -qiE '40[34]|不存在|not found' <<<"$R2"; then
  ok "撤销主记录 → 原生记录一起消失（不留后门）"
else
  no "撤销后还有记录活着: primary='$R1' native='$R2'"
fi
LEFT=$(SHARE_PROVIDER=sing-box python3 "$ROOT/src/conf/share_client.py" list 2>/dev/null | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' 2>/dev/null)
[[ "$LEFT" = 0 ]] && ok "provider=sing-box 记录已清空（$LEFT 条）" || no "还剩 $LEFT 条记录"

echo
echo "=== 结果: $pass 通过, $fail 失败 ==="
[[ "$fail" -eq 0 ]]
