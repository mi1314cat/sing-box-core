#!/usr/bin/env bash
# ==============================================================================
# tools/check_compat_wiring.sh — SB 客户端 × proxy-node-compat 接线门禁
#
# 这个仓库没有现成门禁（没有 CI、没有 lint 配置）, 所以这是最小可用的一道:
#   * 只读、不联网、不写任何生产路径; 需要写只在 mktemp 目录里写, 退出即清
#   * 可重复执行: 同一份代码跑多少次结论都一样
#   * 判"接线"而不是判"能力": 能力规则全在 vendored 的 proxy-node-compat 里,
#     这里只验证 ① 那份 vendored 副本与上游逐字节一致（= 没改语义）
#     ② 适配层能跑 ③ 双跑保险丝成立 ④ 回滚开关有效 ⑤ 边界没越线
#
# 用法:
#   bash tools/check_compat_wiring.sh                # 有 sing-box 二进制就真探测
#   bash tools/check_compat_wiring.sh --verbose
#
# 无内核二进制的机器上, 语料回归用**离线夹具**（GATE_OFFLINE_*）跑。夹具是写死的,
# 但只用于门禁; 运行时路径(client.sh / to_sb.py)永远是 `sing-box version` 真读。
# ==============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

CLIENT="$REPO/src/client"
COMPAT_PY="$CLIENT/compat2.py"
LIB="$CLIENT/lib/proxy_node_compat"
COMPAT_REPO="${PROXY_NODE_COMPAT_DIR:-$REPO/../proxy-node-compat}"
UPSTREAM="$COMPAT_REPO/proxy_node_compat"
# vendored 快照钉在 proxy-node-compat 的**提交版**上（不是谁的工作区）:
# 上游仓库当时有未提交的在途改动（mihomo 的 trojan uri_rule）, 那些不属于"已完成"的快照。
COMPAT_REV="${PROXY_NODE_COMPAT_REV:-3a75ba5}"

# 离线夹具: 两台真实部署机（CC/RW）上 `sing-box version` 打印的 Tags
GATE_OFFLINE_VERSION="${GATE_OFFLINE_VERSION:-1.14.2}"
GATE_OFFLINE_TAGS="${GATE_OFFLINE_TAGS:-with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,with_tailscale,with_ccm,with_ocm,with_cloudflared,with_naive_outbound,with_usbip,with_openvpn,with_openconnect,badlinkname,tfogo_checklinkname0}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$*"; }
info() { [[ "$VERBOSE" == 1 ]] && printf '    · %s\n' "$*"; return 0; }
title(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

TMP="$(mktemp -d /tmp/sb-compat-gate.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------------ 1 语法
title "1 · 语法（bash -n / py_compile）"
for f in "$REPO/install.sh" "$CLIENT/client.sh" "$CLIENT/compat2.py" "$CLIENT/to_sb.py"; do
    [[ -f "$f" ]] || { bad "缺文件: $f"; continue; }
    case "$f" in
        *.sh) if bash -n "$f" 2>"$TMP/err"; then ok "bash -n $(basename "$f")"
              else bad "bash -n $(basename "$f"): $(head -1 "$TMP/err")"; fi ;;
        *.py) if python3 -m py_compile "$f" 2>"$TMP/err"; then ok "py_compile $(basename "$f")"
              else bad "py_compile $(basename "$f"): $(head -1 "$TMP/err")"; fi ;;
    esac
done
for f in "$LIB"/*.py; do
    python3 -m py_compile "$f" 2>"$TMP/err" || bad "py_compile $(basename "$f")"
done
[[ "$FAIL" == 0 ]] && ok "vendored lib 全部可编译"

# ------------------------------------------------- 2 vendored 副本与上游一致
title "2 · vendored 副本（判定层语义未被改动）"
VENDOR_FILES="__init__.py __main__.py cli.py engine.py model.py registry.py uri.py data/rules.json"
if [[ -d "$UPSTREAM" ]]; then
    if git -C "$COMPAT_REPO" rev-parse --git-dir >/dev/null 2>&1; then
        rev="$(git -C "$COMPAT_REPO" rev-parse --short "$COMPAT_REV" 2>/dev/null || echo "")"
        if [[ -z "$rev" ]]; then
            bad "指定的 compat 快照 $COMPAT_REV 在 $COMPAT_REPO 里不存在"
        fi
        drift=0
        for f in $VENDOR_FILES; do
            a="$(git -C "$COMPAT_REPO" show "$COMPAT_REV:proxy_node_compat/$f" 2>/dev/null | sha256sum | cut -d' ' -f1)"
            b="$(sha256sum "$LIB/$f" 2>/dev/null | cut -d' ' -f1)"
            [[ -n "$a" && "$a" == "$b" ]] || { bad "vendored $f 与 proxy-node-compat@$rev 不一致"; drift=1; }
        done
        [[ "$drift" == 0 ]] && ok "vendored 副本 == proxy-node-compat@$rev（8 个文件, 逐字节）"
        # 上游工作区/后续提交有漂移只提示, 不算失败 —— 判定层是外部依赖, 门禁只盯"我们没改它"
        if [[ -n "$(git -C "$COMPAT_REPO" status --porcelain -- proxy_node_compat 2>/dev/null)" ]]; then
            info "上游工作区有在途改动（不属于本快照, 已忽略）"
        fi
    else
        diff -r -x '__pycache__' -x '*.pyc' "$UPSTREAM" "$LIB" >"$TMP/diff" 2>&1
        if [[ ! -s "$TMP/diff" ]]; then ok "vendored 副本与上游工作区逐字节一致"
        else bad "vendored 副本与上游不一致:"; head -5 "$TMP/diff" | sed 's/^/      /'; fi
    fi
else
    info "找不到上游 $UPSTREAM, 跳过逐字节比对"
fi
python3 - "$LIB/data/rules.json" <<'PY' || bad "rules.json 结构不对"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(d["rules"]) >= 67, len(d["rules"])
assert len(d["evidence"]) >= 26, len(d["evidence"])
assert d["uri_rules"], "uri_rules 为空"
sb = [r for r in d["rules"] if r["target"].get("kernel") == "singbox"]
assert len(sb) >= 21, len(sb)
print("  \033[32m✓\033[0m rules.json 可加载: %d 规则 / %d 证据 / %d URI 规则（singbox %d）"
      % (len(d["rules"]), len(d["evidence"]), len(d["uri_rules"]), len(sb)))
PY

# --------------------------------------------------------- 3 目标四元组真探测
title "3 · 目标四元组（版本 + build tags）"
BIN="${SB_COMPAT_BIN:-}"
[[ -z "$BIN" ]] && for c in "$REPO/../../core/sing-box" /opt/sb-client/core/sing-box; do
    [[ -x "$c" ]] && BIN="$c" && break
done
[[ -z "$BIN" ]] && BIN="$(command -v sing-box || true)"
if [[ -n "$BIN" && -x "$BIN" ]]; then
    info "用真实内核: $BIN"
    VOUT="$(python3 "$COMPAT_PY" --bin "$BIN" version 2>&1)"
    REAL_VERSION="$(printf '%s' "$VOUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["probe"]["version"] or "")' 2>/dev/null)"
    REAL_TAGS="$(printf '%s' "$VOUT" | python3 -c 'import json,sys;t=json.load(sys.stdin)["probe"]["build_tags"];print(",".join(t) if t is not None else "")' 2>/dev/null)"
    if [[ -n "$REAL_VERSION" ]]; then ok "真探测到 version=$REAL_VERSION"
    else bad "真探测拿不到版本: $(printf '%s' "$VOUT" | head -2)"; fi
    if [[ -n "$REAL_TAGS" ]]; then ok "真探测到 build tags ($(printf '%s' "$REAL_TAGS" | tr ',' '\n' | wc -l) 个)"
    else bad "真探测拿不到 Tags（build_tags 必须是真读的, 不能写死）"; fi
else
    info "本机没有 sing-box 二进制 → 语料用离线夹具 $GATE_OFFLINE_VERSION"
fi
export SB_COMPAT_VERSION="${REAL_VERSION:-$GATE_OFFLINE_VERSION}"
export SB_COMPAT_TAGS="${REAL_TAGS:-$GATE_OFFLINE_TAGS}"
if [[ -z "$REAL_VERSION" ]]; then
    printf '    \033[33m! 离线夹具: version=%s（仅门禁用; 运行时永远真探测）\033[0m\n' "$SB_COMPAT_VERSION"
fi

# ------------------------------------------------------------- 4 适配层自检
title "4 · 适配层 selftest"
if python3 "$COMPAT_PY" selftest 2>&1 | sed 's/^/    /'; then ok "compat2.py selftest 通过"
else bad "compat2.py selftest 失败"; fi

# --------------------------------------------- 5 双跑语料（保险丝: 只许收紧）
title "5 · 双跑语料（旧判定 vs compat vs 合并）"
# 语料分两组, 因为"版本无关的规则"和"有版本区间的规则"不能用同一个断言:
#   组 A 用**真探测到的目标**跑（这些都是 range=* 的规则, 结论与版本无关）
#   组 B 钉死一个夹具目标（Reality/ECH/flow 的规则证据区间从 1.14.2 起）
# 组 B 的夹具是门禁产物, 不是运行时行为 —— client.sh/to_sb.py 永远真探测。
python3 - "$COMPAT_PY" <<'PY' || bad "双跑语料回归失败"
import json, os, subprocess, sys

COMPAT = sys.argv[1]
U1 = "11111111-1111-1111-1111-111111111111"
H = "1.2.3.4:443"

# 组 A: 规则 range=*（版本无关）, 期望值在任何版本上都成立
CASES_A = [
    # encryption=none 是 VLESS 链接的「不加密」哨兵值（v2rayN/Xray 一律会写）,
    # 必须判 SUPPORTED —— 否则真实 vless 链接会被整批丢掉（CC 实测过的假 UNSUPPORTED）
    (f"vless://{U1}@{H}?encryption=none&security=tls&sni=a.com&type=ws&path=%2Fws#ws",
     "SUPPORTED", "SUPPORTED", "SUPPORTED", None),
    (f"vless://{U1}@{H}?type=ws&security=tls&sni=a.com&path=%2Fws#ws",
     "SUPPORTED", "SUPPORTED", "SUPPORTED", None),
    (f"vless://{U1}@{H}?type=xhttp&security=tls&sni=a.com&path=%2Fx#xhttp",
     "SUPPORTED", "UNSUPPORTED", "UNSUPPORTED", None),   # KERNEL_NEVER_SUPPORTED
    (f"vless://{U1}@{H}?type=kcp&headerType=wireguard&seed=z&security=none#kcp",
     "SUPPORTED", "UNSUPPORTED", "UNSUPPORTED", None),   # sing-box 没有 mKCP
    (f"trojan://pw@{H}?type=httpupgrade&security=tls&sni=a.com&path=%2Fhu#hu",
     "SUPPORTED", "SUPPORTED", "SUPPORTED", None),       # 内核支持, 但 to_sb 会丢传输
    ("ss://YWVzLTEyOC1nY206cHc@1.2.3.4:8388#ss", "SUPPORTED", "SUPPORTED", "SUPPORTED", None),
    (f"hysteria2://pw@{H}?sni=a.com&insecure=1#hy2", "SUPPORTED", "SUPPORTED", "SUPPORTED", None),
    (f"tuic://{U1}:pw@{H}?sni=a.com#tuic", "SUPPORTED", "SUPPORTED", "SUPPORTED", None),
    # 真的 VLESS Encryption（非 none）仍然必须判死
    (f"vless://{U1}@{H}?encryption=mlkem768x25519plus.native.0rtt&security=tls&sni=a.com#enc",
     "SUPPORTED", "UNSUPPORTED", "UNSUPPORTED", None),
    (f"vless://{U1}@{H}?encryption=aes-128-gcm&security=reality&sni=a.com&type=tcp#enc2",
     "SUPPORTED", "UNSUPPORTED", "UNSUPPORTED", None),
]

# 组 B: 有版本区间。Reality/ECH/flow 的证据从 1.14.2 起 —— 1.14.2 上必须 SUPPORTED,
#        1.14.1 上 compat 只能 UNKNOWN（不许外推）, 于是退回旧判定, 节点照样保留。
PINNED = {"SB_COMPAT_VERSION": "1.14.2",
          "SB_COMPAT_TAGS": "with_gvisor,with_quic,with_utls,with_acme,with_clash_api"}
REALITY = (f"vless://{U1}@{H}?security=reality&pbk=AAA&sid=00&type=tcp#reality")
CASES_B = [
    (REALITY, "SUPPORTED", "SUPPORTED", "SUPPORTED", PINNED),
    (REALITY, "SUPPORTED", "UNKNOWN", "SUPPORTED",
     {"SB_COMPAT_VERSION": "1.14.1", "SB_COMPAT_TAGS": PINNED["SB_COMPAT_TAGS"]}),
]

def run(uri, extra_env=None):
    env = dict(os.environ)
    env.pop("SB_COMPAT_VERSION", None) if extra_env else None
    if extra_env:
        env.update(extra_env)
    p = subprocess.run([sys.executable, COMPAT, "check-uri", uri, "--json"],
                       capture_output=True, text=True, env=env)
    if p.returncode not in (0, 1):
        raise SystemExit("check-uri 崩了: %s" % p.stderr[-400:])
    return json.loads(p.stdout)

fails, tightened, relaxed, fb = [], 0, 0, 0
n_case = 0
for group, cases in (("A", CASES_A), ("B", CASES_B)):
    for uri, want_old, want_compat, want_merged, env in cases:
        n_case += 1
        r = run(uri, env)
        tag = "%s/%s" % (group, uri[-14:])
        got_old = (r["legacy"] or {}).get("verdict")
        got_compat = (r["compat"] or {}).get("status")
        if got_old != want_old:
            fails.append("旧判定 %s: got=%s want=%s" % (tag, got_old, want_old))
        if got_compat != want_compat:
            fails.append("compat %s: got=%s want=%s" % (tag, got_compat, want_compat))
        if r["verdict"] != want_merged:
            fails.append("合并 %s: got=%s want=%s" % (tag, r["verdict"], want_merged))
        # 保险丝 1: 旧说不行 → 合并绝不能变成行（放松）
        if got_old == "UNSUPPORTED" and r["verdict"] != "UNSUPPORTED":
            relaxed += 1
        # 保险丝 2: compat 说不行 → 合并必须不行
        if got_compat == "UNSUPPORTED" and r["verdict"] != "UNSUPPORTED":
            relaxed += 1
        if got_old == "SUPPORTED" and r["verdict"] == "UNSUPPORTED":
            tightened += 1
        if "legacy（" in (r["verdict_source"] or ""):
            fb += 1
        for k in ("raw_uri", "extensions", "unknowns", "downgrades", "client_losses", "target"):
            if k not in r:
                fails.append("结果缺字段 %s（%s）" % (k, tag))
# 组 B 第二例就是"UNKNOWN 必须回退旧判定、不许判死"的回归
if "legacy（" not in (run(REALITY, {"SB_COMPAT_VERSION": "1.14.1",
                                    "SB_COMPAT_TAGS": PINNED["SB_COMPAT_TAGS"]})["verdict_source"] or ""):
    fails.append("1.14.1 上 Reality 应回退旧判定（UNKNOWN 不等于不支持）")

# 回滚开关: 必须完全回到旧判定, 且不跑 compat
r = run([c for c in CASES_A if c[0].endswith("#xhttp")][0][0], {"SB_COMPAT_ENGINE": "legacy"})
if r["compat"] is not None:
    fails.append("SB_COMPAT_ENGINE=legacy 下仍然跑了 compat")
if r["verdict"] != "SUPPORTED":
    fails.append("回滚开关下应回到旧判定 SUPPORTED, got=%s" % r["verdict"])
if "回滚开关" not in (r["verdict_source"] or ""):
    fails.append("回滚开关没有在 verdict_source 里留痕")

# 已知缺陷绕行必须可关: 关掉以后 encryption=none 要回到 compat 的原判（UNSUPPORTED）
r_off = run(CASES_A[0][0], {"SB_COMPAT_NO_SHIMS": "1"})
if r_off["verdict"] != "UNSUPPORTED" or not r_off.get("shims") == []:
    fails.append("SB_COMPAT_NO_SHIMS=1 没能复现 compat 原判（got=%s shims=%s）"
                 % (r_off["verdict"], r_off.get("shims")))
r_on = run(CASES_A[0][0])
if not r_on.get("shims"):
    fails.append("encryption=none 的绕行没有留痕（shims 为空）")

# 客户端转换损失: httpupgrade 节点必须被报出来（to_sb.py 静默降级 tcp 的那个坑）
r = run([c for c in CASES_A if c[0].endswith("#hu")][0][0])
if not r["client_losses"]:
    fails.append("httpupgrade 的客户端转换损失没被报出来")
else:
    print("    · httpupgrade 损失已报: %s" % r["client_losses"][0]["what"][:60])

if fails:
    for f in fails:
        print("    \033[31m✗ %s\033[0m" % f)
    raise SystemExit(1)
print("    \033[32m✓\033[0m %d 条语料: 收紧 %d / 放松 %d（必须 0）/ 回退旧判定 %d"
      % (n_case, tightened, relaxed, fb))
if relaxed:
    raise SystemExit(1)
PY

# --------------------------------------------- 6 端到端: to_sb.py + 文件闸门
title "6 · 端到端（to_sb.py 转换闸门）"
cat > "$TMP/sub.txt" <<'EOF'
vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443?encryption=none&type=ws&security=tls&sni=a.com&path=%2Fws#wsenone
vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443?type=xhttp&security=tls&sni=a.com&path=%2Fx#xhttp
vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443?type=kcp&headerType=wireguard&seed=z#kcp
trojan://pw@1.2.3.4:443?type=httpupgrade&security=tls&sni=a.com&path=%2Fhu#hu
EOF
python3 "$CLIENT/to_sb.py" "$TMP/sub.txt" --prefix gate --compat-report "$TMP/rep.json" \
    >"$TMP/out.json" 2>"$TMP/err.txt"
TAGS="$(python3 -c 'import json;print(",".join(o["tag"] for o in json.load(open("'"$TMP"'/out.json"))["outbounds"]))' 2>/dev/null)"
if [[ "$TAGS" == "gate-wsenone,gate-hu" ]]; then ok "xhttp/mkcp 被拦下; ws(encryption=none)/httpupgrade 保留"
else bad "转换结果不对: tags=$TAGS"; fi
if grep -q "KERNEL_NEVER_SUPPORTED" "$TMP/err.txt"; then ok "跳过原因带 reason_code"
else bad "跳过原因没有 reason_code"; fi
python3 - "$TMP/rep.json" <<'PY' || bad "compat 报告字段不全"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
c = d["compat"]
assert c["target"]["version"], "target.version 空"
assert len(c["nodes"]) == 4, len(c["nodes"])
assert any(n["tag"].endswith("wsenone") and n["ok"] for n in c["nodes"]), "encryption=none 的 vless 被丢了"
n = [x for x in c["nodes"] if x["tag"].endswith("xhttp")][0]
assert n["ok"] is False and n["raw_uri"], n
assert n["message"], "没有可读文案"
hu = [x for x in c["nodes"] if x["tag"].endswith("hu")][0]
assert hu["client_losses"], "httpupgrade 的转换损失丢了"
assert hu["extensions"] is not None and hu["unknowns"] is not None
print("    \033[32m✓\033[0m 报告含 target/raw_uri/losses/unknowns/extensions/client_losses")
PY

# ---------------------------------------------------------- 7 单节点 JSON 闸门
title "7 · 单节点 sing-box JSON 闸门（filter-json）"
cat > "$TMP/one.json" <<'EOF'
{"outbounds":[
 {"type":"vless","tag":"ok-ws","server":"1.2.3.4","server_port":443,"uuid":"11111111-1111-1111-1111-111111111111",
  "tls":{"enabled":true,"server_name":"a.com"},"transport":{"type":"ws","path":"/ws"}},
 {"type":"shadowsocks","tag":"bad-ss-reality","server":"1.2.3.4","server_port":1,"method":"aes-128-gcm",
  "password":"x","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"AAA"}}},
 {"type":"selector","tag":"PROXY","outbounds":["ok-ws"]}
]}
EOF
python3 "$COMPAT_PY" filter-json "$TMP/one.json" --out "$TMP/one.out.json" --report "$TMP/one.rep.json" \
    >/dev/null 2>"$TMP/one.err"
python3 - "$TMP/one.out.json" "$TMP/one.rep.json" <<'PY' || bad "filter-json 行为不对"
import json, sys
out = json.load(open(sys.argv[1], encoding="utf-8"))
rep = json.load(open(sys.argv[2], encoding="utf-8"))
tags = [o["tag"] for o in out["outbounds"]]
assert tags == ["ok-ws", "PROXY"], tags          # ss+reality 被拿掉, selector 保留
d = rep["dropped_nodes"][0]
assert d["type"] == "shadowsocks" and "KERNEL_NEVER_SUPPORTED" in d["reason_codes"], d
print("    \033[32m✓\033[0m ss+Reality 被拦下（%s）, selector 原样保留" % ",".join(d["reason_codes"]))
PY

# ------------------------------------------------------------- 8 接线存在性
title "8 · 接线存在性 + 边界"
grep -q 'SB_COMPAT_PY=' "$CLIENT/client.sh" && ok "client.sh 认 SB_COMPAT_PY" || bad "client.sh 没有 SB_COMPAT_PY"
grep -q 'compat_gate_json' "$CLIENT/client.sh" && ok "client.sh 有 compat 闸门" || bad "client.sh 没有闸门"
grep -q -- '--compat-report' "$CLIENT/client.sh" && ok "client.sh 传 --compat-report" || bad "client.sh 没传报告路径"
grep -q 'compat2.py' "$REPO/install.sh" && ok "install.sh 会装适配层" || bad "install.sh 不装适配层"
grep -q 'compat_brief' "$CLIENT/client.sh" && ok "client.sh 会打印 compat 摘要" || bad "client.sh 不打印摘要"
if grep -q 'SB_COMPAT_ENGINE' "$CLIENT/compat2.py" && grep -q 'SB_COMPAT_ENGINE' "$CLIENT/to_sb.py"; then
    ok "回滚开关读得到 SB_COMPAT_ENGINE"
else bad "回滚开关没有实现"; fi

if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    CHANGED="$(git -C "$REPO" status --porcelain | awk '{print $2}')"
    info "改动: $(printf '%s' "$CHANGED" | tr '\n' ' ')"
    # conf/share.sh / share_client.py 归另一个 agent。它俩在同一个工作区里必然也是
    # dirty 的, 所以这里**不能**按"文件是否 dirty"判; 判的是"我们的改动有没有渗进去":
    # 只要那两个文件的 diff 里出现本任务的任何标记就算越界。
    if git -C "$REPO" status --porcelain | grep -qE 'conf/share(_client)?\.(sh|py)'; then
        if git -C "$REPO" diff -- src/conf/share.sh src/conf/share_client.py 2>/dev/null \
             | grep -qE 'compat2|proxy_node_compat|SB_COMPAT'; then
            bad "conf/share.sh / share_client.py 的 diff 里出现了本任务的标记（越界）"
        else
            ok "conf/share.sh / share_client.py 的改动与本任务无关（另一个 agent 的）"
        fi
    else
        ok "conf/share.sh / share_client.py 没被动过"
    fi
    if printf '%s' "$CHANGED" | grep -qE '^(\.\./|/root/deepseek/repos/(xray|mihomo))'; then
        bad "改了 sing-box-core 之外的仓库"
    else
        ok "改动都在 sing-box-core 内"
    fi
fi

# ------------------------------------------------------------------ 汇总
title "汇总"
printf '  \033[32m通过 %d\033[0m / \033[31m失败 %d\033[0m\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
echo "  ✓ 接线完好（判定层未改语义; compat 只许收紧; 回滚开关可用）"
