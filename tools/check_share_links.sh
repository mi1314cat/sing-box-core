#!/bin/bash
# ==============================================================
# tools/check_share_links.sh — 分享链接回归检查 (可重复执行)
#
# 断言的都是**跨内核 E2E 实测出来、后果是"整条订阅归零"**的坑
# (mihomo 1.19.32 / sing-box 1.14.2, 2026-10):
#
#   1. hy2 链接不能带无效 obfs 参数
#      `obfs=none&obfs-password=` -> mihomo: missing obfs password
#      -> provider 0 节点, 同订阅的好节点一起消失。
#   2. 真开了混淆时, obfs=salamander 必须带**非空**密码。
#   3. vmess 链接必须是 vmess://base64(JSON), JSON 里必须有 ps 与 id,
#      且链接**不能带 #片段**
#      (mihomo: `convert v2ray subscribe error: format invalid` -> 0 节点)。
#   4. 链接里的 sni 不能是 IP 字面量 (mihomo: x509 ... doesn't contain any IP SANs)。
#   5. hy2 / tuic 链接必须带 alpn (SB 自己的不变量, 缺了说明模板被改坏)。
#
# 两种检查一起跑:
#   A. **动态自测**: 在 /tmp 沙箱里用 conf/*.sh 真实代码生成 hy2 (无混淆/有混淆)、
#      vmess (TLS/REALITY) 节点, 校验产出的链接。不碰防火墙、不碰 systemd、
#      不碰公共服务、不写任何生产路径 (全部落在 mktemp 目录, 跑完删)。
#   B. **产物扫描**: 扫 $SB_OUT_DIR 里的 sb_share-*.txt / sb_links-all.txt
#      (老部署里这两个文件可能是旧代码生成的, 扫一遍就知道要不要重发)。
#
# 用法:
#   bash tools/check_share_links.sh                 # 自测 + 扫默认产物目录
#   bash tools/check_share_links.sh --out-dir DIR   # 只扫指定目录
#   bash tools/check_share_links.sh --no-gen        # 跳过动态自测
#   bash tools/check_share_links.sh --fix           # 把产物里的无效 obfs 参数删掉
#   bash tools/check_share_links.sh --keep          # 保留沙箱 (排查用)
#
# 退出码: 0 = 全部通过; 1 = 有 FAIL。
# ==============================================================
set -u

SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRC="$(cd "$SELF/.." && pwd)"
OUT_DIR=""; DO_GEN=1; DO_FIX=0; KEEP=""
SHARE_URL="${SB_CHECK_SHARE_URL:-}"
CLIENT_BIN_OVERRIDE=""; CLIENT_SRC_OVERRIDE=""
while (( $# )); do
    case "$1" in
        --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
        --no-gen)  DO_GEN=0; shift ;;
        --fix)     DO_FIX=1; shift ;;
        --keep)    KEEP=1; shift ;;
        --share-url)   SHARE_URL="${2:-}"; shift 2 ;;      # E 段: 对角线 (SB 分享 -> SB 客户端)
        --client-bin)  CLIENT_BIN_OVERRIDE="${2:-}"; shift 2 ;;
        --client-src)  CLIENT_SRC_OVERRIDE="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "未知参数: $1 (试试 --help)" >&2; exit 2 ;;
    esac
done

for c in jq python3 openssl base64; do
    command -v "$c" >/dev/null 2>&1 || { echo "[SKIP] 缺少依赖 $c, 无法检查" >&2; exit 2; }
done

if [[ -z "$OUT_DIR" ]]; then
    # 与面板同一套路径规则 (lib.sh 的默认值), 但不 source lib.sh —— 那个文件在
    # 加载期会 mkdir 分享目录, 这不是一个只读检查脚本该有的副作用。
    OUT_DIR="${SB_OUT_DIR:-${SB_ROOT:-/root/catmi/sing-box}/out}"
fi

SANDBOX=$(mktemp -d /tmp/sb-linkcheck.XXXXXX)
export SANDBOX   # runner 子 shell 里要用 ($SANDBOX/src, $SANDBOX/gen-*.log)
cleanup() { [[ -n "$KEEP" ]] || rm -rf "$SANDBOX"; }
trap cleanup EXIT
mkdir -p "$SANDBOX/bin"
for c in ufw iptables nft firewall-cmd systemctl service; do
    printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/$c"; chmod +x "$SANDBOX/bin/$c"
done

FAILED=0
ok()   { printf '  [OK]   %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; FAILED=1; }
note() { printf '  [--]   %s\n' "$*"; }

# ---------------------------------------------------------------- 校验器
# 一份链接文件逐行校验; 打印结论; 返回 1 表示有 FAIL。
# ★ 规则的真源是 `src/conf/link_guard.py`（同一份规则也是**发布闸门**:
#   conf/share.sh 发布前拿它拦下"会让对方整条订阅归零"的链接）。
#   规则写在两处必然漂移 —— 而这里的漂移后果是"门禁绿着, 线上发出死订阅"。
validate_file() { # <文件> <标签>
    python3 "$SRC/src/conf/link_guard.py" check "$1" --label "$2"
}

# ---------------------------------------------------------------- A. 动态自测
# 在沙箱里跑真实 add_config, 拿到**新生成**的链接。
#
# 注意: 用 `bash <runner>` 起一个**不带 set -u** 的子 shell 来跑真实模块 ——
# 面板入口本来就不带 -u (batch.sh 也是 `bash conf/<proto>.sh add` 起新进程),
# 而几个协议模块里存在只在 -u 下才暴露的未初始化变量 (vmess 的 REAL_PUB 已
# 顺手补上, vless 的 TLS_TYPE 仍是原样)。自测要复现的是**面板的真实运行方式**。
sandbox_runner() { # 生成 runner 脚本 (只做一次)
    local r="$SANDBOX/runner.sh"
    [[ -f "$r" ]] && return 0
    cat > "$r" <<'RUN'
#!/bin/bash
# 沙箱 runner: source 真实协议模块, 换掉会碰系统的函数, 然后 add_config
proto="$1"
source "$SANDBOX/src/conf/$proto.sh" || exit 1
sb_check() { return 0; }
sb_reload() { return 0; }
open_port() { return 0; }
close_node_port() { return 0; }
sb_regen_aggregate() { return 0; }
random_domain() { echo "check.example.com"; }
add_config >/dev/null 2>"$SANDBOX/gen-$proto.log" || exit 1
cat "$SB_OUT_DIR"/sb_share-*.txt 2>/dev/null
RUN
}

sandbox_env() { # <proto> <根目录> [KEY=VAL ...]
    local root="$2"
    mkdir -p "$root/config" "$root/out" "$root/cert"
    export PATH="$SANDBOX/bin:$PATH"
    export SB_ROOT="$root" SB_CONFIG_DIR="$root/config" SB_OUT_DIR="$root/out" \
           SB_BACKUP_DIR="$root/backup" SB_BIN="$root/sing-box" SB_SERVICE=sb-linkcheck-none \
           SB_BATCH=1 SB_BATCH_PORT_START=46000 SB_BATCH_PORT_END=46999 \
           SB_SERVER_NAME=linkcheck SB_NO_NAME_PROMPT=1 SB_SERVER_ADDR=192.0.2.10
    shift 2
    [[ $# -gt 0 ]] && export "$@"
    return 0
}

sandbox_gen() { # <proto> [KEY=VAL ...] -> stdout: 链接
    local proto="$1"; shift
    sandbox_runner
    local root="$SANDBOX/root-$proto-$$-$RANDOM"
    ( sandbox_env "$proto" "$root" "$@"; bash "$SANDBOX/runner.sh" "$proto" )
}

gen_reality_keys() { # 沙箱用: 临时造一对 X25519 密钥 (不落仓库, 只给自测用)
    local out="$1" pem="$SANDBOX/reality.pem" priv pub
    openssl genpkey -algorithm X25519 -out "$pem" >/dev/null 2>&1 || return 1
    priv=$(openssl pkey -in "$pem" -outform DER 2>/dev/null | tail -c 32 | base64 -w0 | tr '+/' '-_' | tr -d '=')
    pub=$(openssl pkey -in "$pem" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 -w0 | tr '+/' '-_' | tr -d '=')
    [[ -n "$priv" && -n "$pub" ]] || return 1
    printf '{"private_key":"%s","public_key":"%s"}\n' "$priv" "$pub" > "$out"
}

run_selftest() {
    echo "== A. 动态自测 (真实 conf/*.sh 在 /tmp 沙箱里生成) =="
    cp -r "$SRC/src" "$SANDBOX/src"
    local t="$SANDBOX/gen-links.txt"

    # A1: hy2 不开混淆 -> 链接里**不该有任何 obfs 参数**
    if sandbox_gen hysteria2 > "$SANDBOX/a1.txt" 2>/dev/null; then
        validate_file "$SANDBOX/a1.txt" "A1 hy2 (无混淆)" || FAILED=1
        grep -q "obfs=" "$SANDBOX/a1.txt" && bad "A1: 没开混淆却出现了 obfs 参数: $(cat "$SANDBOX/a1.txt")"
    else
        bad "A1: hy2 沙箱生成失败"
    fi

    # A2: hy2 开混淆 -> 必须带 salamander + 非空密码
    if sandbox_gen hysteria2 SB_BATCH_OBFS=y > "$SANDBOX/a2.txt" 2>/dev/null; then
        validate_file "$SANDBOX/a2.txt" "A2 hy2 (开 obfs)" || FAILED=1
        grep -q "obfs=salamander&obfs-password=..*" "$SANDBOX/a2.txt" \
            || bad "A2: 开了混淆但链接里没有 obfs=salamander + 密码: $(cat "$SANDBOX/a2.txt")"
    else
        bad "A2: hy2(obfs) 沙箱生成失败"
    fi

    # 自签证书 (给 vmess TLS 形态用; 只影响 sni 字符串, 不做真连接)
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -keyout "$SANDBOX/tls.key" -out "$SANDBOX/tls.crt" -days 2 \
        -subj "/CN=check.example.com" -addext "subjectAltName=DNS:check.example.com" >/dev/null 2>&1

    # A3: vmess 真证书形态 -> vmess:// + ps/id + 无 #片段
    if sandbox_gen vmess SB_BATCH_CERT=real SB_BATCH_CERT_CRT="$SANDBOX/tls.crt" \
            SB_BATCH_CERT_KEY="$SANDBOX/tls.key" SB_BATCH_CERT_DOMAIN=check.example.com \
            > "$SANDBOX/a3.txt" 2>/dev/null; then
        validate_file "$SANDBOX/a3.txt" "A3 vmess (TLS)" || FAILED=1
        grep -q "^vmess://" "$SANDBOX/a3.txt" || bad "A3: 不是 vmess:// 链接: $(cat "$SANDBOX/a3.txt")"
    else
        bad "A3: vmess 沙箱生成失败"
    fi

    # A4: vmess REALITY 形态 -> 必须是 vmess://, 且带 pbk/sid (旧代码发的是 vless://)
    local kf="$SANDBOX/reality-keys.json"
    if gen_reality_keys "$kf"; then
        sandbox_runner
        local rroot="$SANDBOX/root-reality-$$"
        rm -rf "$rroot"; mkdir -p "$rroot/config" "$rroot/out"
        cp "$kf" "$rroot/out/reality-keys.json"
        if ( sandbox_env vmess "$rroot" SB_FORCE_TLS_REALTY=1; bash "$SANDBOX/runner.sh" vmess ) \
                > "$SANDBOX/a4.txt" 2>/dev/null; then
            validate_file "$SANDBOX/a4.txt" "A4 vmess (REALITY)" || FAILED=1
            if grep -q "^vless://" "$SANDBOX/a4.txt"; then
                bad "A4: vmess+REALITY 的链接写成了 vless:// (协议名错, 对方必然连不上): $(cat "$SANDBOX/a4.txt")"
            fi
            grep -q "^vmess://" "$SANDBOX/a4.txt" || bad "A4: 不是 vmess:// 链接"
        else
            note "A4: vmess+REALITY 沙箱生成未跑起来 (见 $SANDBOX/gen-vmess.log)"
        fi
    else
        note "A4: openssl 造不出 X25519 测试密钥, 跳过 vmess+REALITY 自测"
    fi

    # A5: vless 真证书形态 -> 必须带 sni, 且不是 IP
    if sandbox_gen vless SB_BATCH_CERT=real SB_BATCH_CERT_CRT="$SANDBOX/tls.crt" \
            SB_BATCH_CERT_KEY="$SANDBOX/tls.key" SB_BATCH_CERT_DOMAIN=check.example.com \
            > "$SANDBOX/a5.txt" 2>/dev/null; then
        validate_file "$SANDBOX/a5.txt" "A5 vless (TLS)" || FAILED=1
    else
        note "A5: vless 沙箱生成跳过 (见 $SANDBOX/gen-vless.log)"
    fi
}

# ---------------------------------------------------------------- B. 产物扫描
scan_out_dir() {
    echo "== B. 产物扫描 ($OUT_DIR) =="
    if [[ ! -d "$OUT_DIR" ]]; then
        note "目录不存在, 跳过: $OUT_DIR"
        return 0
    fi
    # 显式列文件: nullglob 只对**含通配符**的 pattern 生效, 像 sb_links-all.txt
    # 这种字面量在文件不存在时仍会原样留下, 直接喂给校验器会误报"读不到"。
    local f files=()
    for f in "$OUT_DIR"/sb_share-*.txt; do [[ -f "$f" ]] && files+=("$f"); done
    [[ -f "$OUT_DIR/sb_links-all.txt" ]] && files+=("$OUT_DIR/sb_links-all.txt")
    if (( ${#files[@]} == 0 )); then
        note "没有 sb_share-*.txt / sb_links-all.txt"
        return 0
    fi
    for f in "${files[@]}"; do
        validate_file "$f" "$(basename "$f")" || FAILED=1
    done
}

# ---------------------------------------------------------------- D. 客户端导入自测
# 断言: **单条坏条目不得中断整批导入**。
# 实证: to_sb.py 的 _from_clash_list 调了只在 convert() 里存在的闭包 _note ——
# 一条认不出的代理直接 NameError, 整批 0 导入 (M 的 19 节点分享喂给 SB 客户端
# 就是这个结果; 剔掉唯一那条脏值后 18/18 通过)。
# 另外顺带验证老格式链接 (obfs=none 的 hy2、uuid 键 + #片段的 vmess) 仍能导入。
run_client_selftest() {
    echo "== D. 客户端导入自测 (src/client/to_sb.py) =="
    local d="$SANDBOX/cli"; mkdir -p "$d"
    local out rc n

    cat > "$d/batch.yaml" <<'YAML'
proxies:
- {name: good-ss, type: ss, server: 1.2.3.4, port: 8388, cipher: aes-128-gcm, password: pw1}
- {name: bad-unknown, type: totally-unknown-proto, server: 5.6.7.8, port: 1234}
- {name: good-trojan, type: trojan, server: 9.9.9.9, port: 443, password: pw2, sni: a.example.com}
- {name: bad-values, type: vmess, server: 1.1.1.1, port: not-a-number, uuid: 11111111-2222-3333-4444-555555555555}
YAML
    out=$(python3 "$SRC/src/client/to_sb.py" "$d/batch.yaml" 2>"$d/batch.err"); rc=$?
    if (( rc != 0 )) || grep -q "Traceback" "$d/batch.err"; then
        bad "D1: 一条坏条目把整批导入炸掉了 (rc=$rc): $(tail -2 "$d/batch.err" | tr '\n' ' ')"
    else
        n=$(printf '%s' "$out" | jq -r '.outbounds|length' 2>/dev/null)
        if [[ "${n:-0}" -ge 2 ]]; then
            ok "D1: 混入 2 条坏条目, 2 条好节点全部导入 (单条异常只跳过自己)"
        else
            bad "D1: 好节点被牵连丢了 (只导入 ${n:-0} 条, 期望 2)"
        fi
    fi

    # D2: 老 hy2 链接带 obfs=none -> 当"无混淆"导入, 不得报错
    printf '%s\n' 'hysteria2://pw@1.2.3.4:31001?sni=a.example.com&obfs=none&obfs-password=&alpn=h3#legacy-hy2' > "$d/hy2.txt"
    out=$(python3 "$SRC/src/client/to_sb.py" "$d/hy2.txt" 2>"$d/hy2.err"); rc=$?
    if (( rc == 0 )) && ! printf '%s' "$out" | jq -e '.outbounds[0].obfs' >/dev/null 2>&1; then
        ok "D2: 带 obfs=none 的老 hy2 链接按\"无混淆\"导入 (不报错、不写空 obfs)"
    else
        bad "D2: 老 hy2 (obfs=none) 链接导入失败或写出了非法 obfs 字段"
    fi

    # D3: 老 vmess 链接 (uuid 键 + #片段) -> 必须拿到 UUID
    printf '%s\n' 'vmess://eyJhZGQiOiIxLjIuMy40IiwicG9ydCI6IjQ0MyIsInV1aWQiOiIxMTExMTExMS0yMjIyLTMzMzMtNDQ0NC01NTU1NTU1NTU1NTUiLCJhaWQiOiIwIiwibmV0Ijoid3MiLCJwYXRoIjoiL3giLCJob3N0IjoiYS5leGFtcGxlLmNvbSIsInRscyI6InRscyIsInNuaSI6ImEuZXhhbXBsZS5jb20ifQ==#legacy-vmess' > "$d/vmess.txt"
    out=$(python3 "$SRC/src/client/to_sb.py" "$d/vmess.txt" 2>"$d/vmess.err"); rc=$?
    n=$(printf '%s' "$out" | jq -r '.outbounds[0].uuid // ""' 2>/dev/null)
    if (( rc == 0 )) && [[ -n "$n" ]]; then
        ok "D3: 老 vmess 链接 (uuid 键) 拿到了 UUID"
    else
        bad "D3: 老 vmess 链接导入后 UUID 为空 (老链接会变成永远连不通的节点)"
    fi
}

# ---------------------------------------------------------------- E. 对角线自测
# 「SB 分享 -> SB 客户端」必须一直能用 —— 这是用户点名的红线:
# "我是怕修着修着之后, 它自己这个就不认得啦。即 SB 分享给 SB。"
# 不是假想: mihomo 侧真的发生过一次(加旗帜命名把自家的分享生成打断成 0/19)。
#
# 跑的是**客户端真实代码路径**: `client.sh add <share-url>` (CLI 分派直接调
# add_node, 不碰 systemd) + 内核 check + 一次真连。
#
# 安全边界 (为什么敢在服务器上跑):
#   * CLIENT_ROOT 整个隔离到 mktemp 目录, 不读不写 /opt/sb-client 的配置;
#   * 只用 add_node + 自己起内核, **不调 apply_change/do_start** ⇒ 生产 unit
#     不会被重启; 脚本前后各取一次生产 unit 的 MainPID, 不一致就判 FAIL;
#   * 若 /etc/sb-client.env 把 CLIENT_ROOT 抢走, 立刻 fail-closed 退出该段。
#
# 需要: --share-url URL (服务器上 `bash conf/share.sh create-all 8 1` 拿到的地址)
#       --client-bin PATH (默认找 /opt/sb-client/core/sing-box)
run_diagonal() {
    echo "== E. 对角线: SB 分享 -> SB 客户端 =="
    if [[ -z "$SHARE_URL" ]]; then
        note "未提供 --share-url, 跳过对角线自测 (线上验: --share-url http://…:9443/share/<token>)"
        return 0
    fi
    local cbin="$CLIENT_BIN_OVERRIDE"
    [[ -z "$cbin" ]] && cbin="/opt/sb-client/core/sing-box"
    if [[ ! -x "$cbin" ]]; then
        note "找不到客户端内核 ($cbin), 跳过对角线自测 (可用 --client-bin 指定)"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || { note "没有 curl, 跳过对角线自测"; return 0; }
    local csrc="$CLIENT_SRC_OVERRIDE"; [[ -z "$csrc" ]] && csrc="$SRC/src/client"
    [[ -f "$csrc/client.sh" && -f "$csrc/to_sb.py" ]] || { bad "E: 找不到客户端脚本 ($csrc)"; return 1; }

    local W="$SANDBOX/client" port
    rm -rf "$W"; mkdir -p "$W/conf" "$W/nodes" "$W/share-state" "$W/core"
    ln -sf "$cbin" "$W/core/sing-box"
    port=$(python3 - <<'PYPORT'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PYPORT
)
    cat > "$W/conf/00-mixed.json" <<JSON
{ "inbounds": [ { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": $port } ] }
JSON
    # 骨架里的 DNS 片段: 客户端的 regen_selector 会给 route 写
    # default_domain_resolver={server:"doh-main"} —— 缺了这个 tag, 内核 check 直接
    # `initialize outbound[N]: default domain resolver not found: doh-main`。
    # 这里按 client.sh 的 write_dns_conf 默认值 (阿里 DoH 主 + Cloudflare 兜底,
    # IP + tls.server_name 以免引导解析泄露) 复刻一份最小骨架。
    cat > "$W/conf/02-dns.json" <<'JSON'
{
  "dns": {
    "servers": [
      { "type": "https", "tag": "doh-main", "server": "223.5.5.5", "server_port": 443,
        "path": "/dns-query", "tls": { "enabled": true, "server_name": "dns.alidns.com" } },
      { "type": "https", "tag": "doh-fallback", "server": "1.1.1.1", "server_port": 443,
        "path": "/dns-query", "tls": { "enabled": true, "server_name": "cloudflare-dns.com" } }
    ],
    "final": "doh-fallback",
    "strategy": "ipv4_only"
  }
}
JSON
    # 客户端代码用**仓库里的这一份** (自测的就是"自家代码能不能吃自家分享")
    cp "$csrc/client.sh" "$csrc/to_sb.py" "$W/share-state/" 2>/dev/null
    [[ -f "$csrc/compat2.py" ]] && cp "$csrc/compat2.py" "$W/share-state/" 2>/dev/null
    [[ -d "$csrc/lib" ]] && cp -r "$csrc/lib" "$W/share-state/lib" 2>/dev/null

    local prod_before="" prod_after=""
    command -v systemctl >/dev/null 2>&1 && prod_before=$(systemctl show -p MainPID --value sb-client 2>/dev/null || true)

    local out rc
    out=$(CLIENT_ROOT="$W" CLIENT_BIN="$W/core/sing-box" CLIENT_CONF="$W/conf"           CLIENT_NODE_DIR="$W/nodes" SB_TO_SB="$W/share-state/to_sb.py"           SB_COMPAT_PY="$W/share-state/compat2.py"           SB_COMPAT_REPORT="$W/share-state/.compat-last.json"           bash -c '[[ "$CLIENT_ROOT" == "'"$W"'" ]] || { echo "FATAL: CLIENT_ROOT 被 /etc/sb-client.env 覆盖成 $CLIENT_ROOT"; exit 9; }
                   exec bash "'"$csrc"'/client.sh" add "$1"' _ "$SHARE_URL" </dev/null 2>&1)
    rc=$?
    local n
    n=$(jq '(.outbounds | map(select(.detour != null) | .detour)) as $dep
            | [.outbounds[]? | select(.type!="selector" and .type!="urltest" and .type!="direct")
               | select((.tag as $t | $dep | index($t)) == null)] | length' \
          "$W/conf/90-outbounds.json" 2>/dev/null)
    if (( rc != 0 )) || [[ "${n:-0}" -lt 1 ]]; then
        bad "E1: 自家的分享自家客户端吃不下 (rc=$rc, 导入 ${n:-0} 个节点)"
        printf '%s\n' "$out" | grep -E "ERR|Error|失败|FATAL" | tail -3 | sed 's/^/         /'
        return 1
    fi
    ok "E1: client.sh add 导入 $n 个节点 (非 0), exit=0"

    # E5: **决策必须可见**。地址上带内核声明时同内核客户端要走原生; 不带声明
    # 时走普通话(URI 列表)。"没打出来"就等于用户不知道这次拉的是哪种产品 ——
    # 而这正是"静默降级"最容易发生的地方。
    if printf '%s' "$SHARE_URL" | grep -q 'interop=[0-9]'; then
        if printf '%s' "$out" | grep -q '本次拉取: 原生'; then
            ok "E5: 带声明的地址 → 客户端走原生（日志里有'本次拉取: 原生'）"
        else
            bad "E5: 带声明的地址没有走原生"; printf '%s\n' "$out" | grep -E "本次拉取" | sed 's/^/         /'
        fi
    else
        if printf '%s' "$out" | grep -q '本次拉取: 普通话'; then
            ok "E5: 裸地址（声明缺失）→ 走普通话, 且日志有原因行"
        else
            bad "E5: 裸地址没有走普通话 / 没有打出决策行"
        fi
    fi

    local chk; chk=$("$W/core/sing-box" check -D "$W" -C "$W/conf" 2>&1)
    if (( $? == 0 )); then ok "E2: 导入后的客户端配置 sing-box check 通过"
    else bad "E2: sing-box check 不通过"; printf '%s\n' "$chk" | tail -3 | sed 's/^/         /'; return 1; fi

    # E3: 真连 (隔离端口, 跑完就杀)
    nohup "$W/core/sing-box" run -D "$W" -C "$W/conf" > "$W/run.log" 2>&1 &
    local kp=$!
    sleep 3
    local code; code=$(curl -s -o /dev/null -w '%{http_code}|%{time_total}' --max-time 15 \
                      -x "http://127.0.0.1:$port" "https://www.gstatic.com/generate_204" 2>/dev/null)
    kill $kp 2>/dev/null; wait $kp 2>/dev/null
    if [[ "$code" == 204* ]]; then ok "E3: 真连 http=$code (走节点, 端口 $port)"
    else bad "E3: 真连失败 (http=$code)"; grep -E "FATAL|ERROR" "$W/run.log" 2>/dev/null | tail -2 | sed 's/^/         /'; fi

    if command -v systemctl >/dev/null 2>&1; then
        prod_after=$(systemctl show -p MainPID --value sb-client 2>/dev/null || true)
        if [[ "$prod_before" == "$prod_after" ]]; then
            ok "E4: 生产 sb-client MainPID 未变 ($prod_before) —— 隔离生效, 未碰生产"
        else
            bad "E4: 生产 sb-client PID 变了 ($prod_before -> $prod_after)"
        fi
    fi
    return 0
}

# ---------------------------------------------------------------- F. 三家互通
# 声明/决策/回退链的**纯函数**断言（不需要内核二进制: 本机事实用
# SB_INTEROP_VERSION 显式声明, 那是测试输入而不是生产写死）。
# 每条都对应一个真实后果:
#   · 声明缺失却报错 → 老链接(裸地址)全部拉不动
#   · 跨内核却走原生 → 客户端解析出 0 个节点
#   · 发行版不在清单却猜原生 → 静默丢字段
#   · "声明只能放 query" 被破坏(片段也算声明) → 两套语义必然漂移
run_interop_selftest() {
    echo "== F. 三家互通（声明 / 决策 / 回退链） =="
    local I="$SRC/src/conf/interop.py" IC="$SRC/src/client/lib/interop.py"
    if [[ ! -f "$I" || ! -f "$IC" ]]; then
        bad "F0: 缺 interop.py（服务端 $I / 客户端 $IC）"; return 0
    fi
    local a b
    a=$(sha256sum "$I" | awk '{print $1}'); b=$(sha256sum "$IC" | awk '{print $1}')
    if [[ "$a" = "$b" ]]; then ok "F1: 服务端与客户端的 interop.py 逐字节相同 (${a:0:16}…)"
    else bad "F1: 两份 interop.py 不一致（服务端声明的字段名与客户端读的可能已经漂移, 表现是静默全走普通话）"; fi

    local D="$SANDBOX/interop"; mkdir -p "$D"
    export SB_INTEROP_VERSION="9.9.9"
    local URL
    URL=$(SB_INTEROP_VERSION=9.9.9 python3 "$I" declare --kernel sing-box \
            --distribution sing-box --version 9.9.9 \
            --url "http://h:9443/share/tok?x=1" \
            --url-sing-box "http://h:9443/share/native" 2>/dev/null)
    case "$URL" in
        *"interop=1"*"kernel=sing-box"*"formats=uri"*) ok "F2: declare 产出的声明带 interop/kernel/formats" ;;
        *) bad "F2: declare 产出的声明不完整: $URL" ;;
    esac
    case "$URL" in
        *"url-sing-box="*) ok "F3: 原生取件地址写进声明（url-<发行版>）" ;;
        *) bad "F3: 声明里没有 url-sing-box: $URL" ;;
    esac
    case "$URL" in
        *"x=1"*) ok "F4: 地址原有的查询参数被保留（不重写别人的地址）" ;;
        *) bad "F4: 原有查询参数被吃掉了: $URL" ;;
    esac
    # 决策矩阵: 逐条都是一个真实坑
    local j
    j=$(SB_INTEROP_VERSION=9.9.9 python3 "$I" decide "$URL" 2>/dev/null)
    if printf '%s' "$j" | grep -q '"choice": "native"'; then ok "F5: 同内核同发行版 → 原生"
    else bad "F5: 同内核同发行版没有走原生: $j"; fi
    j=$(SB_INTEROP_VERSION=9.9.9 python3 "$I" decide "http://h:9443/share/tok" 2>/dev/null)
    if printf '%s' "$j" | grep -q '"reason": "no-declaration"' && printf '%s' "$j" | grep -q '"choice": "uri"'; then
        ok "F6: 声明缺失 → 普通话, 原因是 no-declaration（不报错）"
    else bad "F6: 声明缺失的处理不对: $j"; fi
    j=$(SB_INTEROP_VERSION=9.9.9 python3 "$I" decide \
          "http://h:9443/share/tok?interop=1&kernel=xray&distribution=xray&formats=uri,xray&url-xray=http%3A%2F%2Fh%2Fs" 2>/dev/null)
    if printf '%s' "$j" | grep -q '"reason": "cross-kernel"'; then ok "F7: 跨内核 → 普通话（cross-kernel）"
    else bad "F7: 跨内核没有走普通话: $j"; fi
    j=$(SB_INTEROP_VERSION=9.9.9 python3 "$I" decide \
          "http://h:9443/share/tok?interop=99&kernel=sing-box&distribution=sing-box&formats=uri,sing-box" 2>/dev/null)
    if printf '%s' "$j" | grep -q '"reason": "unknown-schema"'; then ok "F8: 规范版本不认识 → 普通话（不猜）"
    else bad "F8: 不认识的规范版本没有保守处理: $j"; fi
    j=$(SB_INTEROP_VERSION=9.9.9 python3 "$I" decide \
          "http://h:9443/share/tok?interop=1&kernel=sing-box&distribution=sing-box&formats=uri" 2>/dev/null)
    if printf '%s' "$j" | grep -q '"reason": "distribution-not-listed"'; then ok "F9: 发行版不在清单 → 普通话（不猜原生）"
    else bad "F9: 发行版不在清单时的处理不对: $j"; fi
    j=$(SB_INTEROP_VERSION=9.9.9 python3 "$I" decide \
          "http://h:9443/share/tok?interop=1&kernel=sing-box&distribution=sing-box&formats=uri,sing-box" 2>/dev/null)
    if printf '%s' "$j" | grep -q '"reason": "no-url-for-format"'; then ok "F10: 声明了格式却没给地址 → 普通话"
    else bad "F10: 缺地址时的处理不对: $j"; fi
    # 片段里的同名字段**不算**声明（同一语义只许一套载体）
    j=$(SB_INTEROP_VERSION=9.9.9 python3 "$I" decide "http://h:9443/share/tok#interop=1&kernel=sing-box" 2>/dev/null)
    if printf '%s' "$j" | grep -q '"reason": "no-declaration"'; then ok "F11: 片段里的声明不算声明（只读查询串）"
    else bad "F11: 片段被当成了声明: $j"; fi
    # 本机事实: 探测不到就**不猜**（不产出原生 / 走普通话）
    j=$(python3 "$I" decide "$URL" --distribution "" 2>/dev/null)
    if printf '%s' "$j" | grep -q '"reason": "self-unknown"'; then ok "F12: 本机发行版探测不出来 → 普通话（不猜自己是官方版）"
    else bad "F12: 探测不出来时的处理不对: $j"; fi

    # 发布闸门接线: 链接校验器必须是**同一份**规则（门禁与发布共用）
    if grep -q 'link_guard.py' "$SRC/src/conf/share.sh" \
       && grep -q 'link_guard.py' "$SRC/tools/check_share_links.sh"; then
        ok "F13: 链接校验器被发布路径与门禁共用（同一份规则, 不会漂移）"
    else bad "F13: 发布路径没有接 link_guard.py（门禁绿着, 线上却可能发出死订阅）"; fi
    if grep -q '_sb_share_uri_payload' "$SRC/src/conf/share.sh" \
       && grep -q 'uri_express.py' "$SRC/src/conf/share.sh"; then
        ok "F14: 发布前生成 URI 产品并做表达力标注"
    else bad "F14: share.sh 里缺 URI 产品生成 / 表达力标注"; fi
    if grep -q '本次拉取' "$SRC/src/client/client.sh" \
       && grep -q '原生取件失败' "$SRC/src/client/client.sh"; then
        ok "F15: 客户端的决策与回退原因都会打出来（不静默）"
    else bad "F15: 客户端没有决策日志 / 回退原因"; fi
    unset SB_INTEROP_VERSION
}

# ---------------------------------------------------------------- C. --fix
fix_out_dir() {
    echo "== C. --fix: 删掉产物里的无效 obfs 参数 ($OUT_DIR) =="
    [[ -d "$OUT_DIR" ]] || { note "目录不存在, 跳过"; return 0; }
    python3 - "$OUT_DIR" <<'PY'
import glob, os, re, sys
out = sys.argv[1]
n_files = n_lines = 0
for f in sorted(glob.glob(os.path.join(out, "sb_share-*.txt")) +
                glob.glob(os.path.join(out, "sb_links-all.txt"))):
    lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    new = []
    changed = 0
    for l in lines:
        if l.startswith(("hysteria2://", "hy2://")) and "obfs=none" in l:
            l2 = re.sub(r"[&?]obfs-password=(?=[&#]|$)", "", l)
            l2 = re.sub(r"[&?]obfs=none(?=[&#]|$)", "", l2)
            l2 = l2.replace("?&", "?").replace("&&", "&")
            if l2 != l:
                changed += 1
                l = l2
        new.append(l)
    if changed:
        open(f, "w", encoding="utf-8").write("\n".join(new) + "\n")
        n_files += 1; n_lines += changed
        print("  [FIX]  %s: 修掉 %d 行" % (os.path.basename(f), changed))
if n_files:
    print("  [OK]   共修 %d 个文件 / %d 行 —— 重新分发前建议再跑一次本脚本" % (n_files, n_lines))
else:
    print("  [--]   没有需要修的链接")
PY
}

# ---------------------------------------------------------------- main
echo "SB 分享链接回归检查 (源码: $SRC)"
(( DO_GEN )) && run_selftest
(( DO_GEN )) && run_client_selftest
run_interop_selftest
run_diagonal        # 自带开关: 没给 --share-url 就跳过
scan_out_dir
(( DO_FIX )) && fix_out_dir

echo
if (( FAILED )); then
    echo "结果: [FAIL] 有检查未通过 (详情见上)"
    exit 1
fi
echo "结果: [OK] 全部通过"
exit 0
