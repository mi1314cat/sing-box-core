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
COMPAT_REV="${PROXY_NODE_COMPAT_REV:-9b73cc9}"

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
assert len(d["rules"]) >= 68, len(d["rules"])
assert len(d["evidence"]) >= 29, len(d["evidence"])
assert d["uri_rules"], "uri_rules 为空"
sb = [r for r in d["rules"] if r["target"].get("kernel") == "singbox"]
assert len(sb) >= 22, len(sb)
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

# ---- 5b: build tags 规则（canonical 9b73cc9 新补的 with_quic / with_naive_outbound）
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(COMPAT)), "lib"))
sys.path.insert(0, os.path.dirname(os.path.abspath(COMPAT)))
import compat2                                            # noqa: E402
from proxy_node_compat import Target as _T                # noqa: E402
BASE = dict(kernel="singbox", distribution="upstream",
            version=os.environ.get("SB_COMPAT_VERSION", "1.14.2"))
def tgt(tags):
    return _T(build_tags=tags, **BASE)
def j(uri=None, ob=None, tags=None):
    return compat2.judge(uri=uri, outbound=ob, tgt=tgt(tags))

hy2 = f"hysteria2://pw@1.2.3.4:8443?sni=a.com#hy2"
tuic = f"tuic://{U1}:pw@1.2.3.4:8443?sni=a.com#tuic"
naive_ob = {"type": "naive", "tag": "nv", "server": "1.2.3.4", "server_port": 443,
            "username": "u", "password": "p",
            "tls": {"enabled": True, "server_name": "a.com"}}
TAGS_OK = ["with_gvisor", "with_quic", "with_utls", "with_naive_outbound"]
TAGS_NOQUIC = ["with_gvisor", "with_utls", "with_naive_outbound"]
TAGS_NONAIVE = ["with_gvisor", "with_quic", "with_utls"]

for label, kw, tags, want in (
        ("hy2+with_quic", dict(uri=hy2), TAGS_OK, "SUPPORTED"),
        ("hy2-without_quic", dict(uri=hy2), TAGS_NOQUIC, "UNSUPPORTED"),
        ("tuic+with_quic", dict(uri=tuic), TAGS_OK, "SUPPORTED"),
        ("tuic-without_quic", dict(uri=tuic), TAGS_NOQUIC, "UNSUPPORTED"),
        ("naive+with_naive_outbound", dict(ob=naive_ob), TAGS_OK, "SUPPORTED"),
        ("naive-without_naive_outbound", dict(ob=naive_ob), TAGS_NONAIVE, "UNSUPPORTED")):
    r = j(tags=tags, **kw)
    if r["verdict"] != want:
        fails.append("build tags %s: got=%s want=%s rc=%s"
                     % (label, r["verdict"], want, r["reason_codes"]))
    if want == "UNSUPPORTED" and "BUILD_NOT_ENABLED" not in r["reason_codes"]:
        fails.append("build tags %s: 缺 reason_code BUILD_NOT_ENABLED（%s）"
                     % (label, r["reason_codes"]))
if not fails:
    print("    \033[32m✓\033[0m build tags 真的参与判定: with_quic -> hy2/tuic, with_naive_outbound -> naive")

# 回滚开关: 必须完全回到旧判定, 且不跑 compat
r = run([c for c in CASES_A if c[0].endswith("#xhttp")][0][0], {"SB_COMPAT_ENGINE": "legacy"})
if r["compat"] is not None:
    fails.append("SB_COMPAT_ENGINE=legacy 下仍然跑了 compat")
if r["verdict"] != "SUPPORTED":
    fails.append("回滚开关下应回到旧判定 SUPPORTED, got=%s" % r["verdict"])
if "回滚开关" not in (r["verdict_source"] or ""):
    fails.append("回滚开关没有在 verdict_source 里留痕")

# canonical 9b73cc9 自己修掉了 encryption=none（#716 哨兵值不再建 feature）,
# 所以适配层里的绕行已删除。这里钉住"删了以后行为不变"的两侧:
r_sent = run(CASES_A[0][0])                       # encryption=none
if r_sent["verdict"] != "SUPPORTED":
    fails.append("encryption=none 又被判死了（canonical 回归? got=%s）" % r_sent["verdict"])
if "shims" in r_sent:
    fails.append("结果里还有 shims 字段 —— 绕行的残留没删干净")
if os.environ.get("SB_COMPAT_NO_SHIMS"):
    fails.append("环境里还留着 SB_COMPAT_NO_SHIMS")

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
# xhttp / mkcp: compat 判 KERNEL_NEVER_SUPPORTED（内核从来没有这两种出站）。
# httpupgrade: 内核支持（compat 判 SUPPORTED）, 但**本转换器不会写它** —— 现在
# 明确拒绝 + 说明, 不再像以前那样静默当成 tcp（那种节点内核不报错、只会永远连不上）。
if [[ "$TAGS" == "gate-wsenone" ]]; then ok "xhttp/mkcp 被 compat 拦下; httpupgrade 明确拒绝（不静默 tcp）; ws(encryption=none) 保留"
else bad "转换结果不对: tags=$TAGS"; fi
if grep -q "KERNEL_NEVER_SUPPORTED" "$TMP/err.txt"; then ok "跳过原因带 reason_code"
else bad "跳过原因没有 reason_code"; fi
python3 - "$TMP/rep.json" "$TMP/out.json" <<'PY' || bad "compat 报告字段不全"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
out = json.load(open(sys.argv[2], encoding="utf-8"))
c = d["compat"]
assert c["target"]["version"], "target.version 空"
assert len(c["nodes"]) == 4, len(c["nodes"])
assert any(n["tag"].endswith("wsenone") and n["ok"] for n in c["nodes"]), "encryption=none 的 vless 被丢了"
n = [x for x in c["nodes"] if x["tag"].endswith("xhttp")][0]
assert n["ok"] is False and n["raw_uri"], n
assert n["message"], "没有可读文案"
assert "KERNEL_NEVER_SUPPORTED" in (n["reason_codes"] or []), n["reason_codes"]
hu = [x for x in c["nodes"] if x["tag"].endswith("hu")][0]
assert hu["client_losses"], "httpupgrade 的转换损失丢了"
# ★ 不许静默 tcp: httpupgrade 这条被拒之后, 理由必须点名传输, 且不许出现在出站里
assert hu["ok"] is False, "httpupgrade 被静默降级成 tcp 了"
assert all("httpupgrade" in m for m in hu["message"]), hu["message"]
assert not any("hu" == o["tag"].split("-")[-1] for o in out["outbounds"]), out["outbounds"]
assert hu["extensions"] is not None and hu["unknowns"] is not None
print("    \033[32m✓\033[0m 报告含 target/raw_uri/losses/unknowns/extensions/client_losses")
PY

# --------------------------------- 6b 三条缺口回归（M→SB 那格的三条根因, 逐条钉死）
title "6b · 三条缺口回归（tls.enabled / 不许静默 tcp / ECH）"
cat > "$TMP/m.yaml" <<'EOF'
proxies:
- name: m-anytls
  type: anytls
  server: 1.2.3.4
  port: 443
  password: pw
  sni: a.example.com
  alpn: h2,http/1.1
  client-fingerprint: chrome
- name: m-hy2
  type: hysteria2
  server: 1.2.3.4
  port: 8443
  password: pw
  sni: a.example.com
- name: m-tuic
  type: tuic
  server: 1.2.3.4
  port: 8443
  uuid: 11111111-1111-1111-1111-111111111111
  password: pw
  sni: a.example.com
- name: m-trojan-tls
  type: trojan
  server: 1.2.3.4
  port: 443
  password: pw
  sni: a.example.com
- name: m-vless-reality
  type: vless
  server: 1.2.3.4
  port: 443
  uuid: 11111111-1111-1111-1111-111111111111
  network: tcp
  tls: true
  servername: www.microsoft.com
  client-fingerprint: chrome
- name: m-vless-xhttp
  type: vless
  server: 1.2.3.4
  port: 443
  uuid: 11111111-1111-1111-1111-111111111111
  network: xhttp
  tls: true
  servername: a.example.com
- name: m-httpupgrade-as-ws
  type: vless
  server: 1.2.3.4
  port: 443
  uuid: 11111111-1111-1111-1111-111111111111
  network: ws
  tls: true
  servername: a.example.com
  v2ray-http-upgrade: true
EOF
# ECH 的 mihomo 形态是嵌套的 ech-opts; PyYAML 缺失时 to_sb 用极简解析器（不支持嵌套）,
# 那时不加这段, 由下面的 URI 用例覆盖 ECH。
HAVE_YAML=0
python3 -c 'import yaml' 2>/dev/null && HAVE_YAML=1
if [[ "$HAVE_YAML" == 1 ]]; then
cat >> "$TMP/m.yaml" <<'EOF'
- name: m-trojan-ech
  type: trojan
  server: 1.2.3.4
  port: 443
  password: pw
  sni: a.example.com
  tls: true
  ech-opts:
    enable: true
    query-server-name: hxicc.example.com
EOF
fi
python3 "$CLIENT/to_sb.py" "$TMP/m.yaml" --prefix gap --compat-report "$TMP/m.rep.json" \
    >"$TMP/m.out.json" 2>"$TMP/m.err.txt"
# ECH 的 URI 形态（X 侧就是这么发的: ech=域名+DoH）—— 不依赖 PyYAML, 永远跑
cat > "$TMP/ech.txt" <<'EOF'
vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443?security=tls&type=ws&sni=a.com&path=%2Fws&ech=cloudflare-ech.com%2Bhttps%3A%2F%2Fdns.alidns.com%2Fdns-query#echws
EOF
if python3 - "$TMP/m.out.json" "$TMP/m.rep.json" "$BIN" <<'PY'
import json, os, subprocess, sys
out = json.load(open(sys.argv[1], encoding="utf-8"))
rep = json.load(open(sys.argv[2], encoding="utf-8"))
BIN = sys.argv[3]
obs = out["outbounds"]
fails = []
# 只要写出 tls 段就必须有 "enabled": true。缺了它:
#   * anytls / tuic / hy2 → 整份配置 FATAL `initialize outbound[0]: TLS required`
#   * vless / trojan     → tls 段被内核**无声忽略**, 明文去连, 永远连不上
# M 分享 18 个节点真连 0/18 的根因就是它（同一批节点在 mihomo 侧 14/19 可用）。
noen = [o.get("tag") for o in obs
        if isinstance(o.get("tls"), dict) and o["tls"].get("enabled") is not True]
if noen:
    fails.append("有 tls 段缺 enabled:true: %s" % noen)
n_tls = sum(1 for o in obs if isinstance(o.get("tls"), dict))
if n_tls < 4:
    fails.append("夹具只产出 %d 个 tls 段（夹具或转换器坏了）" % n_tls)
if any(str(k).startswith("_sb_") for o in obs for k in o):
    fails.append("内部标记 _sb_* 漏进了出站配置")
# 真内核必须接受整份产出（缺 enabled 的老产物在这一步是 rc=1）
cfg = os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), "m.all.json")
json.dump({"log": {"level": "warn"},
           "outbounds": obs + [{"type": "direct", "tag": "direct"}]},
          open(cfg, "w", encoding="utf-8"), ensure_ascii=False)
if BIN and os.access(BIN, os.X_OK):
    p = subprocess.run([BIN, "check", "-c", cfg], capture_output=True, text=True)
    if p.returncode != 0:
        fails.append("内核 check 不过（%s）: %s" % (BIN, (p.stderr or "").strip()[:200]))
if fails:
    for f in fails:
        print("    \033[31m✗ %s\033[0m" % f)
    raise SystemExit(1)
print("%d 个 tls 段全部带 enabled:true%s" % (
    n_tls, "；整份产出被真内核 check 接受" if BIN and os.access(BIN, os.X_OK) else ""))
PY
then ok "缺口① 产出的 tls 段一律带 enabled: true"
else bad "缺口① 产出缺 tls.enabled:true"
fi

if python3 - "$TMP/m.out.json" "$TMP/m.rep.json" <<'PY'
import json, sys
out = json.load(open(sys.argv[1], encoding="utf-8"))
rep = json.load(open(sys.argv[2], encoding="utf-8"))
tags = [o.get("tag") for o in out["outbounds"]]
nodes = (rep.get("compat") or {}).get("nodes") or []
fails = []
# 不许静默 tcp: xhttp 节点不许出现在产出里, 且拒绝理由必须点名传输 + 带 compat 的
# reason_code（sing-box 内核从来没有 xhttp/splithttp 出站; 硬造 transport 会让整份
# 配置 FATAL `unknown transport type: xhttp`, 静默成 tcp 则节点永远连不上）。
if "gap-m-vless-xhttp" in tags:
    fails.append("xhttp 节点被静默降级成 tcp 导入了")
xn = [n for n in nodes if str(n.get("tag", "")).endswith("xhttp")]
if not xn or xn[0].get("ok"):
    fails.append("xhttp 没有被明确拒绝（报告里没有这条记录）")
else:
    if "KERNEL_NEVER_SUPPORTED" not in (xn[0].get("reason_codes") or []):
        fails.append("拒绝理由没有 compat 的 reason_code: %s" % xn[0].get("reason_codes"))
    if not any("xhttp" in m for m in (xn[0].get("message") or [])):
        fails.append("文案没点名 xhttp: %s" % xn[0].get("message"))
# mihomo 把 httpupgrade 写成 network: ws + ws-opts.v2ray-http-upgrade: true。
# 只按 ws 读 = 把 httpupgrade 静默换成 ws（同样是"看着对、连不上"）—— 必须拒绝。
if "gap-m-httpupgrade-as-ws" in tags:
    fails.append("mihomo 的 httpupgrade(network:ws + v2ray-http-upgrade) 被静默当成 ws 导入了")
hu = [n for n in nodes if str(n.get("tag", "")).endswith("httpupgrade-as-ws")]
if not hu or hu[0].get("ok"):
    fails.append("mihomo 的 httpupgrade 没有被明确拒绝（报告里没有这条记录）")
elif not any("httpupgrade" in m for m in (hu[0].get("message") or [])):
    fails.append("httpupgrade 的文案没点名传输: %s" % hu[0].get("message"))
if fails:
    for f in fails:
        print("    \033[31m✗ %s\033[0m" % f)
    raise SystemExit(1)
print("xhttp 被明确拒绝（compat: %s）, 没有静默 tcp" % ",".join(xn[0]["reason_codes"]))
PY
then ok "缺口② xhttp 明确拒绝, 不静默降级成 tcp"
else bad "缺口② xhttp 被静默降级成 tcp"
fi

if python3 - "$TMP/m.out.json" "$TMP/m.rep.json" "$TMP/ech.txt" "$HAVE_YAML" "$CLIENT/to_sb.py" <<'PY'
import json, subprocess, sys
out = json.load(open(sys.argv[1], encoding="utf-8"))
rep = json.load(open(sys.argv[2], encoding="utf-8"))
ECH_URI_FILE, have_yaml, TO_SB = sys.argv[3], sys.argv[4] == "1", sys.argv[5]
obs = out["outbounds"]
tags = [o.get("tag") for o in obs]
nodes = (rep.get("compat") or {}).get("nodes") or []
fails = []
# sing-box 的 tls.ech.config 只认 PEM（-----BEGIN ECH CONFIGS-----）。实测喂 base64 →
# `FATAL initialize outbound[0]: invalid ECH configs pem`（整份配置作废）。链接/mihomo
# 给的是"运行时查 DNS"的形态, 转换器不联网取不到 → 一律**不写**, 但必须显式声明。
for o in obs:
    if (o.get("tls") or {}).get("ech"):
        fails.append("往 tls.ech 里写了值（内核只认 PEM）: %s" % o.get("tag"))
if have_yaml:      # mihomo 的 ech-opts 是嵌套结构, 极简 YAML 解析器不支持
    if "gap-m-trojan-ech" not in tags:
        fails.append("带 ech-opts 的节点被丢了（ECH ≠ 节点不可用）")
    en = [n for n in nodes if str(n.get("tag", "")).endswith("ech")]
    if not en:
        fails.append("带 ech-opts 的节点没有报告记录")
    elif not any((c or {}).get("feature") == "standard:ech"
                 for c in (en[0].get("client_losses") or [])):
        fails.append("ECH 被静默丢了（没有 standard:ech 的转换损失声明）")
# URI 形态（X 侧就是这么发的: ech=域名+DoH）—— 不依赖 PyYAML, 永远跑
p = subprocess.run([sys.executable, TO_SB, ECH_URI_FILE, "--prefix", "gap",
                    "--compat-report", ECH_URI_FILE + ".rep.json"],
                   capture_output=True, text=True)
if p.returncode != 0:
    fails.append("ECH 链接转换失败 rc=%s %s" % (p.returncode, p.stderr[-200:]))
else:
    eo = json.loads(p.stdout)["outbounds"]
    if not eo:
        fails.append("ECH 链接被整条丢了")
    elif (eo[0].get("tls") or {}).get("ech"):
        fails.append("ECH 链接写了 tls.ech（内核只认 PEM）")
    else:
        erep = json.load(open(ECH_URI_FILE + ".rep.json", encoding="utf-8"))
        en = ((erep.get("compat") or {}).get("nodes") or [{}])[0]
        if not any((c or {}).get("feature") == "standard:ech"
                   for c in (en.get("client_losses") or [])):
            fails.append("ECH 链接的 ECH 被静默丢了（报告里没有 standard:ech 声明）")
if fails:
    for f in fails:
        print("    \033[31m✗ %s\033[0m" % f)
    raise SystemExit(1)
print("ECH 一律不写进配置, 并在报告里声明（standard:ech 转换损失）")
PY
then ok "缺口③ ECH 不写非 PEM 值, 且显式声明不可用"
else bad "缺口③ ECH 被静默丢弃"
fi

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

# 三家互通接线: 声明/决策/回退链（服务端 conf/interop.py + 客户端读同一个文件）。
# 这几条判的都是"**静默**失效"的形状: 少一个文件、少一行日志, 表现都是
# "一切正常, 只是原生格式永远拿不到 / 用户不知道这次拉的是哪种产品"。
if grep -q 'SB_INTEROP_PY' "$CLIENT/client.sh" && grep -q 'interop.py' "$CLIENT/client.sh"; then
    ok "client.sh 认 SB_INTEROP_PY（客户端读声明）"
else bad "client.sh 没接声明解析器"; fi
if grep -q '本次拉取' "$CLIENT/client.sh"; then
    ok "client.sh 把本次拉取的产品打到日志（原生/普通话一眼可见）"
else bad "client.sh 没有决策日志 —— 用户看不出这次拉的是哪种"; fi
if grep -q '原生取件失败' "$CLIENT/client.sh"; then
    ok "原生取件失败会**回退**并打出原因（不静默降级）"
else bad "缺回退链"; fi
if grep -q 'share-state/lib/interop.py' "$REPO/install.sh"; then
    ok "install.sh 会装消费者侧的 interop.py"
else bad "install.sh 不装 interop.py（客户端只会走普通话, 且不报错）"; fi
if [[ -f "$REPO/src/conf/interop.py" && -f "$CLIENT/lib/interop.py" ]] \
   && cmp -s "$REPO/src/conf/interop.py" "$CLIENT/lib/interop.py"; then
    ok "服务端与客户端的声明实现逐字节相同（字段名不会各写一套）"
else bad "两份 interop.py 缺失或已漂移"; fi
if grep -q 'interop.py' "$REPO/src/conf/share.sh"; then
    ok "conf/share.sh 会在地址上写内核声明"
else bad "conf/share.sh 没有产出声明"; fi

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
