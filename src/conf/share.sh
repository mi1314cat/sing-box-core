#!/bin/bash
# ==============================================================
# share.sh — 分享链接管理（Server 端）
# CLI:
#   bash share.sh create <tag> [max_uses=1] [ttl_hours=24]
#   bash share.sh list | del <编号|token|tag> | toggle ... | regen ...
# URL: http://<server_ip>:<公共服务端口>/share/<token>   (端口由 sb_share_port 读, 不写死)
# 存储: **公共分享服务** proxy-share-service (provider=sing-box), 不再是本地 JSON 文件
# 并发/原子语义由公共分享服务保证 (先扣后发 + 双层互斥)
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SHARE_BASE="$SB_ROOT/share"
SHARED="$SHARE_BASE/shares"
mkdir -p "$SHARED"
touch "$SHARE_BASE/.share.lock"

# ==============================================================
# 公共分享服务适配层
#
# ★ 分享的存储与生命周期 (Token / TTL / max_uses / 次数 / 过期) 归**公共服务**
#   proxy-share-service —— 它是服务器上的公共基础服务, M / SB / X 共用,
#   不是 SB 的子服务。
#
#   SB 只负责: 生成客户端配置内容、决定什么时候创建与刷新、面板怎么展示。
#
#   provider 固定为 sing-box —— 公共服务的列表/删除接口**强制**要求带
#   provider 参数, 所以 SB 在结构上不可能看到、也不可能误删 M 的记录。
# ==============================================================
SHARE_CLIENT="${SHARE_CLIENT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/share_client.py}"

# ---------------------------------------------------------------- 三家互通
# 声明（我是哪个内核的哪个发行版、我提供哪些格式、每种格式从哪取）与
# "URI 装不下什么"的标注。设计: proxy-node-compat/docs/three-way-interop.md
_SB_CONF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SB_INTEROP_PY="${SB_INTEROP_PY:-$_SB_CONF_DIR/interop.py}"
SB_URI_EXPRESS_PY="${SB_URI_EXPRESS_PY:-$_SB_CONF_DIR/uri_express.py}"
SB_LINK_GUARD_PY="${SB_LINK_GUARD_PY:-$_SB_CONF_DIR/link_guard.py}"

# 公共服务的实际端口 —— 它可能因端口回避而不是 9443, 绝不能写死
sb_share_port() {
    local p=""
    [[ -f "$SHARE_CLIENT" ]] && p=$(python3 "$SHARE_CLIENT" port 2>/dev/null)
    printf '%s' "${p:-9443}"
}

# 确保公共服务在位 (不存在则从独立项目安装)。装有检验、幂等, 多内核共用。
# 返回值约定: 成功时 **stdout 输出端口**, 同时退出码 0; 失败退出码非 0。
# (曾经只返回退出码, 调用方却写 port=$(sb_share_ensure) 再判空 ——
#  于是服务明明活着也永远判成"不可用"。端口只在这一处吐, 不再各处自己拼。)
sb_share_ensure() {
    [[ -f "$SHARE_CLIENT" ]] || return 1
    local p
    p=$(python3 "$SHARE_CLIENT" ensure 2>/dev/null) || return 1
    printf '%s' "${p:-$(sb_share_port)}"
}

_sb_share_api() { python3 "$SHARE_CLIENT" "$@"; }

# 列出 SB 自己的分享 (JSON 数组, 创建时间倒序)。可选按 type 过滤。
_sb_share_list() {
    if [[ -n "${1:-}" ]]; then _sb_share_api list --type "$1" 2>/dev/null
    else _sb_share_api list 2>/dev/null; fi
}

# 挑一条分享: 支持 编号 / token / token 前缀 / tag。
# 输出 **token**(不再返回文件路径 —— 存储已经不在本地了)。
_sb_share_find() {
    local c="${1:-}" js
    js=$(_sb_share_list)
    [[ -z "$js" || "$js" == "[]" ]] && return 1
    printf '%s' "$js" | python3 -c '
import sys, json
c = sys.argv[1]
try: recs = json.load(sys.stdin)
except Exception: recs = []
if c.isdigit():
    i = int(c)
    if 1 <= i <= len(recs):
        print(recs[i-1]["token"]); raise SystemExit
for r in recs:
    t = r.get("token",""); tg = str((r.get("meta") or {}).get("tag",""))
    if t == c or t.startswith(c) or tg == c:
        print(t); raise SystemExit
raise SystemExit(1)
' "$c"
}

meta_file() {
    # 参数: 编号 / token / token 前缀 / tag; 输出 **token**
    _sb_share_find "$1" 2>/dev/null
}


# IPv6 必须包方括号, 否则 "http://2001:db8::1:9292/..." 里的端口会被
# 并进地址, 客户端解析成非法 host 而失败。
# 订阅地址里的主机跟着"产物地址族"走: 选了 IPv6 就下发 IPv6, 客户端拿 IPv6 去拉。
# sb_url_host 负责给 IPv6 加方括号 —— 不加的话 URL 里的端口会被当成地址的一部分,
# 客户端直接解析失败。
# 拿分享链接 / 客户端配置时问一次用哪个地址族。
# 与菜单项 7 (切换) 的区别: 那是"事后改产物", 这个是"发链接前确认",
# 避免把 IPv4 的链接发给只能用 IPv6 的人。
ask_addr_family_now() {
    local a4 a6 cur
    a4=$(sb_addr4); a6=$(sb_addr6)
    cur=$(sb_addr_family_get); [[ "$cur" == "v6" ]] && cur=2 || cur=1
    echo >&2
    echo -e "${CYAN}  客户端配置里用哪个地址连回服务器?${RESET}" >&2
    [[ -n "$a4" ]] && echo -e "    ${GREEN}1)${RESET} IPv4  ${CYAN}$a4${RESET}" >&2 || echo -e "    ${MAGENTA}(本机无 IPv4)${RESET}" >&2
    [[ -n "$a6" ]] && echo -e "    ${GREEN}2)${RESET} IPv6  ${CYAN}$a6${RESET}" >&2 || echo -e "    ${MAGENTA}(本机无 IPv6)${RESET}" >&2
    echo -e "    ${MAGENTA}服务端固定监听 :: (双栈), IPv4 与 IPv6 客户端都能连${RESET}" >&2
    local c=""
    read -r -p "    请选择 [1-2, 回车=沿用当前]: " c || { echo; return 0; }
    case "$(clean_input "${c:-}")" in
        1) sb_switch_addr_family v4 >/dev/null 2>&1 || sb_addr_family_set v4
           print_ok "本次用 IPv4 $(sb_addr4)" >&2 ;;
        2) sb_switch_addr_family v6 >/dev/null 2>&1 || { sb_addr_family_set v6; }
           print_ok "本次用 IPv6 $(sb_addr6)" >&2 ;;
        *) print_info "沿用当前: $(sb_family_label) $(sb_addr_current)" >&2 ;;
    esac
}


share_url_for() {   # 入参改成 token (存储已不在本地, 不再接受文件路径)
    local tok="${1:-}" host
    # SB_SHARE_HOST: 对外地址覆盖（用域名下发 / 多网卡机器 / 验证台）。
    # 默认仍按"产物地址族"自动选本机地址 —— 覆盖只影响下发的地址, 不改配置。
    host="${SB_SHARE_HOST:-}"
    [[ -n "$host" ]] || host=$(sb_addr_current)
    [[ -z "$host" ]] && host=$(default_server_ip)
    echo "http://$(sb_url_host "$host"):$(sb_share_port)/share/$tok"
}


# ==============================================================
# 三家互通 · 内核声明 + 两条产品
#
# 用户拍板的方案（原话）: "服务端这边加一个自己是什么内核的。如果客户端一看是
# 自己的内核, 那就直接拉取。如果不是, 就用普通话。"
#
#   · 普通话（主产品）= **URI 列表** —— 谁都能读（xbd / mihomo / 第三方面板）。
#   · 原生（附带产品）= **sing-box JSON** —— 只有同内核同发行版的客户端读,
#     它没有 URI 那层表达力损失。
#   · 声明写在**服务端自己生成的订阅地址**的查询串上, 客户端读一个地址就能
#     单方面决定拉哪一份（零往返、不猜 User-Agent、不改已发出的载荷格式）。
#
# 为什么声明能放查询串: 公共分享服务的路由先剥查询串再分发
#   (`share_service.py:768` `path = self.path.split("?", 1)[0]`) → 带声明的
#   地址与裸地址返回**逐字节相同**的内容（门禁有断言）。响应头与独立 /meta
#   端点两条路都被冻结的公共服务堵死了。
# ==============================================================

# 节点名里的服务器前缀。**唯一实现**: gen_full_profile 通过参数拿它, 不再
# 自己算一遍 —— 两处各算一次, 迟早有一天聚合产物的 tag 与 URI 链接文件对不上,
# 而表现是"分享里少一个节点"这种静默错误。
sb_server_slug() {
    local s h
    s=$(sb_server_name 2>/dev/null)
    s=$(printf '%s' "$s" | sed 's/[^A-Za-z0-9._-]\+/-/g; s/^-*//; s/-*$//' | cut -c1-32)
    [[ -n "$s" ]] && { printf '%s' "$s"; return 0; }
    h=$(hostname -s 2>/dev/null | sed 's/[^A-Za-z0-9._-]\+/-/g; s/^-*//; s/-*$//' | cut -c1-32)
    printf '%s' "${h:-server}"
}

# 本机内核事实（真探测）。探测不到发行版 → **不产出原生**: 不猜一个默认值。
sb_share_self_facts() { python3 "$SB_INTEROP_PY" self 2>/dev/null; }
sb_share_fact() { # <facts json> <字段名>
    printf '%s' "$1" | python3 -c 'import sys, json
try: print((json.load(sys.stdin) or {}).get(sys.argv[1], ""))
except Exception: print("")' "$2" 2>/dev/null
}

# 把声明并进订阅地址 —— 声明只有 interop.py 一处实现（客户端读的是同一份定义,
# 门禁比对两份拷贝的 sha256）。
sb_share_declare_url() { # <主地址> <发行版> <版本> [原生地址]
    local url="$1" dist="$2" ver="$3" native="${4:-}"
    local -a extra=()
    [[ -n "$native" && -n "$dist" ]] && extra=(--url-"$dist" "$native")
    python3 "$SB_INTEROP_PY" declare --kernel sing-box --distribution "$dist" \
        --version "$ver" --url "$url" "${extra[@]}" 2>/dev/null
}

# 一条分享 → 该给用户的**带声明地址**。
# 地址**不落盘**, 每次现算: 地址族切换 (sb_switch_addr_family) 会改对外 host,
# 落盘的声明会留着旧 host 而面板显示一切正常 —— 那就是一条死链。
sb_share_declared_url() { # <主 token> [原生 token]
    local tok="$1" ntok="${2:-}" port host url facts dist ver d
    port=$(sb_share_port)
    host="${SB_SHARE_HOST:-}"
    [[ -n "$host" ]] || host=$(sb_addr_current)
    [[ -z "$host" ]] && host=$(default_server_ip)
    [[ -n "$host" ]] || return 1          # 拿不到 host 时**不编**一个地址出来
    url="http://$(sb_url_host "$host"):$port/share/$tok"
    facts=$(sb_share_self_facts)
    dist=$(sb_share_fact "$facts" distribution)
    ver=$(sb_share_fact "$facts" version)
    if [[ -z "$ntok" || -z "$dist" ]]; then
        # 没有原生也要声明 —— 声明"我只提供普通话"比不声明更诚实:
        # 客户端日志里会写"服务端清单里没有本机发行版", 而不是"地址上没有声明"。
        d=$(sb_share_declare_url "$url" "" "$ver" "")
    else
        d=$(sb_share_declare_url "$url" "$dist" "$ver" \
              "http://$(sb_url_host "$host"):$port/share/$ntok")
    fi
    printf '%s' "${d:-$url}"
}

# ---- 记录级读写（一条分享 = 主记录 + 可选的附带原生记录）----
_sb_share_meta() { # <token> -> meta JSON
    _sb_share_api get --token "$1" 2>/dev/null | python3 -c 'import sys, json
try: print(json.dumps((json.load(sys.stdin) or {}).get("meta") or {}, ensure_ascii=False))
except Exception: print("{}")' 2>/dev/null
}
_sb_share_meta_field() { # <token> <字段>
    _sb_share_meta "$1" | python3 -c 'import sys, json
try: print((json.load(sys.stdin) or {}).get(sys.argv[1], "") or "")
except Exception: print("")' "$2" 2>/dev/null
}
_sb_share_native_of() { _sb_share_meta_field "$1" native_token; }
_sb_share_role_of() { _sb_share_meta_field "$1" role; }
# 用户选中的若是**原生产物**, 换回它的主记录 —— "停用/撤销/改次数"必须成对生效
_sb_share_primary_of() {
    local tok="$1" role parent
    role=$(_sb_share_role_of "$tok")
    [[ "$role" == "native" ]] || { printf '%s' "$tok"; return 0; }
    parent=$(_sb_share_meta_field "$tok" parent)
    printf '%s' "${parent:-$tok}"
}

# 发布闸门（两条产品**同一套节点集**）:
# 逐个走**原生产物**里的非控制型 outbound, 取该节点的 URI 链接文件。
#   ★ 为什么不直接用 sb_links-all.txt: 那个文件在节点删除路径里**不会被裁剪**
#     (删除只删 sb_share-<tag>.txt), 直接发布就会把已删节点继续发给用户。
#     以原生产物为准 = 两条产品的节点集合在构造上一致（设计文档 §5 的口径）。
_sb_share_node_pairs() { # <tag> -> 逐行 "<原生 tag>\t<URI 链接文件的 basename>"
    local tag="$1" native="$SB_OUT_DIR/sb_client-$tag.json" pref
    pref=$(sb_server_slug)
    jq -r --arg p "$pref-" '
        (.outbounds | map(select(.detour != null) | .detour)) as $d
        | .outbounds[]
        | select(.type != "selector" and .type != "urltest" and .type != "direct"
                 and .type != "block" and .type != "dns")
        | select((.tag as $t | $d | index($t)) == null)
        | [.tag, (.tag | if startswith($p) then .[($p | length):] else . end)]
        | @tsv' \
        "$native" 2>/dev/null
}

_sb_share_uri_payload() { # <tag> <输出文件> ; 0=成功
    local tag="$1" out="$2" native="$SB_OUT_DIR/sb_client-$tag.json" ntag base n=0 bad=0
    [[ -f "$native" ]] || { print_error "找不到原生客户端产物: $native"; return 1; }
    : > "$out"
    while IFS=$'\t' read -r ntag base; do
        [[ -n "$base" ]] || continue
        if [[ ! -s "$SB_OUT_DIR/sb_share-$base.txt" ]]; then
            print_error "节点 $base 没有 URI 产物 ($SB_OUT_DIR/sb_share-$base.txt) —— 拒绝发布: URI(普通话) 里会少一个节点"
            bad=1
            continue
        fi
        cat "$SB_OUT_DIR/sb_share-$base.txt" >> "$out" || bad=1
        n=$((n + 1))
    done < <(_sb_share_node_pairs "$tag")
    (( bad )) && return 1
    (( n > 0 )) || { print_error "URI(普通话) 一个节点都没有 (原生产物 $native 里没有可发布节点?)"; return 1; }
    return 0
}

# 发布闸门: **链接本身**的校验（唯一真源 conf/link_guard.py, 与
# tools/check_share_links.sh 共用同一份规则）。有一条 problem 就拒绝发布 ——
# 这些规则的后果不是"那个节点连不上", 而是**整个订阅对所有非 SB 客户端归零**
# (mihomo/sing-box 遇到一条坏链接把 provider 判成 0 节点, 好节点一起消失)。
# 把 URI 列表变成主产品之后, 这层从"回归断言"升级成"发布闸门"。
_sb_share_link_guard() { # <tag> ; 输出 JSON 到 stdout, 有 problem 返回 1
    local tag="$1" native="$SB_OUT_DIR/sb_client-$tag.json" ntag base out rc=0
    local -a links=()
    while IFS=$'\t' read -r ntag base; do
        [[ -n "$base" ]] || continue
        links+=(--link "$ntag=$SB_OUT_DIR/sb_share-$base.txt")
    done < <(_sb_share_node_pairs "$tag")
    out=$(python3 "$SB_LINK_GUARD_PY" product "$native" "${links[@]}" --json 2>/dev/null) || rc=$?
    if [[ -z "$out" ]]; then
        print_error "链接校验器没有输出 ($SB_LINK_GUARD_PY) —— 拒绝静默发布"
        return 1
    fi
    printf '%s' "$out" | python3 -c '
import json, sys
r = json.load(sys.stdin)
for w in r.get("warnings") or []:
    print("  [注意] %s" % w, file=sys.stderr)
for p in r.get("problems") or []:
    print("  [FAIL] %s" % p, file=sys.stderr)
print(json.dumps({"checked": r.get("checked", 0),
                  "problems": r.get("problems") or [],
                  "warnings": r.get("warnings") or []}, ensure_ascii=False))
'
    return "$rc"
}

# URI 表达力标注（"别假装有"）: 真源是 vendored 的 URI 表达力注册表
# （`src/client/lib/.../data/rules.json` 的 uri_rules, 文档 docs/uri-representation.md）,
# conf/uri_express.py 只做"出站↔URI"映射与查表。人看的报告走 stderr;
# 机器读的摘要走 stdout（写进分享记录的 meta, 事后可核）。
_sb_share_uri_loss_report() { # <tag> <原生产物文件>
    local tag="$1" native="$2" js err rc=0 ntag base
    local -a links=()
    while IFS=$'\t' read -r ntag base; do
        [[ -n "$base" ]] || continue
        links+=(--link "$ntag=$SB_OUT_DIR/sb_share-$base.txt")
    done < <(_sb_share_node_pairs "$tag")
    js=$(mktemp); err=$(mktemp)
    python3 "$SB_URI_EXPRESS_PY" report "$native" "${links[@]}" --json \
        >"$js" 2>"$err" || rc=$?
    if (( rc != 0 )) || [[ ! -s "$js" ]]; then
        print_error "URI 表达力标注跑不起来 (rc=$rc) —— 拒绝静默发布"
        sed 's/^/    /' "$err" >&2
        rm -f "$js" "$err"
        return 1
    fi
    sed 's/^/    /' "$err" >&2
    python3 - "$js" <<'PY'
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
loss = r.get("losses") or []
unreg = r.get("unregistered") or []
uscheme = r.get("unknown_scheme") or []
# 一行总账: "标注过"这件事本身必须可见（发布 URI 产品却不标注 = 静默降级）
print("  [标注] URI 表达力标注: 逐节点查过 %d 个; 损失 %d 条; UNKNOWN %d 项 "
      "(注册表 uri_rules 逐节点查; UNKNOWN 不折算成'没损失')"
      % (r.get("nodes", 0), len(loss), len(unreg) + len(uscheme)), file=sys.stderr)
if r.get("missing_uri") or r.get("extra_uri"):
    print("  [ERR] 两条产品的节点集合不一致: 缺 URI %s / 多 URI %s"
          % (",".join(map(str, r.get("missing_uri") or [])),
             ", ".join(map(str, r.get("extra_uri") or []))), file=sys.stderr)
if loss:
    print("  [注意] URI 路径表达力损失 %d 条（原生路径没有这些损失）:" % len(loss),
          file=sys.stderr)
    for l in loss:
        print("    · %-24s %-22s %s  [%s] %s"
              % (l["tag"], l["feature"], l["kind"], l["rule"], l["what"]), file=sys.stderr)
else:
    print("  [OK]   URI 路径按注册表没有表达力损失（未入册项另计, 不折算成没损失）",
          file=sys.stderr)
if uscheme:
    print("  [UNKNOWN] scheme 没入册, 表达力判不了: %s"
          % ", ".join(sorted({u["scheme"] for u in uscheme})), file=sys.stderr)
if unreg:
    print("  [UNKNOWN] 原生有、URI 侧查不到且注册表没这一行（UNKNOWN, 不猜）: %s"
          % ", ".join(sorted({u["feature"] for u in unreg})), file=sys.stderr)
print(json.dumps({"nodes": r.get("nodes", 0), "losses": loss,
                  "unregistered": unreg, "unknown_scheme": uscheme},
                 ensure_ascii=False))
PY
    rm -f "$js" "$err"
}


# 聚合全部节点 outbound → 一份 client profile (selector PROXY + urltest AUTO + route.final)
gen_full_profile() {
    local out="$SB_OUT_DIR/sb_client-all.json"
    local srvname; srvname="$(sb_server_name)"
    # 前缀由 bash 端 sb_server_slug() 算好传进来（**唯一实现**）: 聚合产物的
    # tag 前缀必须与 "节点 tag ↔ sb_share-<tag>.txt" 的配对规则完全一致,
    # 两处各算一次的话, 迟早有一条分享的 URI 产品少一个节点而无人报错。
    python3 - "$SB_OUT_DIR" "$out" "$srvname" "$(sb_server_slug)" <<'PY'
import json,glob,sys,os,re
odir,ofile=sys.argv[1],sys.argv[2]
SRV=sys.argv[3] if len(sys.argv)>3 else ""
PREF=sys.argv[4] if len(sys.argv)>4 else ""

def slug(s):
    # tag 会进配置文件、分享链接的 # 片段、Clash API 的节点名, 还是
    # 客户端的节点**文件名** (node-<tag>.json) —— 只保留安全字符,
    # 避免空格/中文/斜杠/emoji 把配置搞坏。
    # 国旗 emoji 在这里被剥掉是**有意的**: tag 必须是稳定的 ASCII 标识,
    # 靠它区分服务器。旗帜给用户看的地方是分享链接的 # 片段。
    t=re.sub(r'[^A-Za-z0-9._-]+','-',s).strip('-')
    if t: return t[:32]
    # 名字里一个 ASCII 都没有 (纯中文/纯 emoji) 时上面会得到空串,
    # 于是前缀整个消失, 多服务器防冲突又白做了 —— 而用户完全可能就
    # 输入"我的香港"这种中文名。回退到 hostname, 保证前缀永远非空。
    import socket
    h=socket.gethostname().split('.')[0]
    h=re.sub(r'[^A-Za-z0-9._-]+','-',h).strip('-') or "server"
    return h[:32]

pref=PREF if PREF else (slug(SRV) if SRV else "")
obs=[]; seen=set()
for f in sorted(glob.glob(os.path.join(odir,"sb_client-*.json"))):
    base=os.path.basename(f)
    if base=="sb_client-all.json": continue
    for o in json.load(open(f)).get("outbounds",[]):
        # 排除控制型与特殊出站, 它们不该出现在客户端订阅里。
        # "block"/"dns" 是 sing-box 1.11.0 起的废弃特殊出站; 虽然面板已经
        # 不再生成它们, 过滤列表仍保留 —— 这样万一配置里存着历史遗留的
        # block 出站, 也不会被带进客户端(客户端同样会带着废弃字段)。
        if o.get("type") in ("selector","urltest","direct","block","dns"): continue
        if o.get("tag") in seen: continue
        seen.add(o.get("tag")); obs.append(o)

# 加服务器前缀 (解决多台服务器节点同名冲突)。
# shadowtls 是两层结构: shadowsocks(tag=X) detour→ shadowtls(tag=X-out),
# 引用和被引用**都要**改。之前的实现只改了 outbound["tag"], 没改 detour 字段,
# 主节点于是指向一个不存在的前缀名, 客户端切节点后内核启动即 FATAL:
#   dependency[shadowtls01-TLS-out] not found
# 所以这里先建 旧tag→新tag 的映射, 再统一改写 tag 与 detour。
    if pref:
        mapping={o["tag"]: pref+"-"+o["tag"] for o in obs
                 if o.get("tag") and not o["tag"].startswith(pref+"-")}
        for o in obs:
            if o.get("tag") in mapping: o["tag"]=mapping[o["tag"]]
            d=o.get("detour")
            if d and d in mapping: o["detour"]=mapping[d]

helper=set(o["detour"] for o in obs if o.get("detour"))
taglist=[o["tag"] for o in obs if o["tag"] not in helper]
if not taglist:
    print("no node payloads", file=sys.stderr); sys.exit(1)
cfg={"outbounds":obs+[
    {"type":"selector","tag":"PROXY","outbounds":taglist,"default":taglist[0]},
    {"type":"urltest","tag":"AUTO","outbounds":taglist,
     "url":"https://www.gstatic.com/generate_204","interval":"3m"}],
    "route":{"final":"PROXY"}}
json.dump(cfg,open(ofile,"w"),indent=1)
PY
    printf "%s" "$out"
}

# ---- 面板辅助: 节点列表 (供分享链接选择) ----
node_tags(){ ls "$SB_OUT_DIR"/sb_client-*.json 2>/dev/null | sed "s|.*/sb_client-||;s|\.json$||" | grep -v "^all$" | sort -u; }

pick_node_tag() {
    local i=1 t f proto port
    echo >&2
    echo -e "${CYAN}可选节点 (0 = 全部节点一条链接):${RESET}" >&2
    echo "--------------------------------------------------------" >&2
    for t in $(node_tags); do
        f="$SB_OUT_DIR/sb_client-$t.json"
        proto=$(jq -r '.outbounds[0].type // "?"' "$f" 2>/dev/null)
        port=$(jq -r '.outbounds[0].server_port // "-"' "$f" 2>/dev/null)
        echo -e "${GREEN}$i${RESET}) ${YELLOW}$t${RESET} | 协议: ${CYAN}$proto${RESET} | 端口: ${BLUE}$port${RESET}" >&2
        i=$((i+1))
    done
    echo "--------------------------------------------------------" >&2
    read -r -p "选择编号 / 直接输入 tag (默认 0=全部): " n
    n=$(clean_input "$n"); [[ -z "$n" ]] && n="0"
    if [[ "$n" == "0" || "$n" == "all" ]]; then echo "all"; return; fi
    if [[ "$n" =~ ^[0-9]+$ ]]; then
        local idx=1
        for t in $(node_tags); do
            [[ "$idx" == "$n" ]] && { echo "$t"; return; }
            idx=$((idx+1))
        done
        echo ""
        return
    fi
    echo "$n"
}

node_list_banner(){
    print_title "按编号选择要分享的节点"
}

ttl_prompt() {
    echo "有效期:" >&2
    echo "  1) 1 小时   2) 24 小时 (默认)   3) 7 天   4) 30 天   5) 永久   6) 自定义小时" >&2
    local c; read -r -p "选择 (回车=2): " c
    c=$(clean_input "$c")
    case "$c" in
        1) echo 1 ;;
        2|"") echo 24 ;;
        3) echo 168 ;;
        4) echo 720 ;;
        5) echo 0 ;;
        6) read -r -p "小时数: " x; [[ "$x" =~ ^[0-9]+$ ]] && echo "$x" || { print_error "无效小时数, 已回退 24"; echo 24; } ;;
        *) echo 24 ;;
    esac
}


create_share() { # <tag> [max_uses=1] [ttl_hours=24]
    local tag="$1" max_uses="${2:-1}" ttl="${3:-24}"
    [[ -n "$tag" ]] || { print_error "用法: share.sh create <tag> [max_uses] [ttl_hours]"; return 1; }
    local client_file="$SB_OUT_DIR/sb_client-$tag.json"
    [[ -f "$client_file" ]] || { print_error "找不到 $tag 的客户端配置 ($client_file)"; return 1; }
    [[ "$max_uses" =~ ^[0-9]+$ ]] || { print_error "max_uses 必须是非负整数 (0=不限), 收到: $max_uses"; return 1; }
    [[ "$ttl" =~ ^[0-9]+$ ]] || { print_error "ttl_hours 必须是小时数 (0=永久), 收到: $ttl"; return 1; }

    # 公共服务不在就装 (幂等; 已有则空操作)
    local port; port=$(sb_share_ensure)
    [[ -n "$port" ]] || { print_error "公共分享服务不可用 —— 分享链接暂时发不出去"; return 1; }

    # 同 tag 旧 token 全部下架 —— 设计如此(一个 tag 只保留一个有效链接),
    # 但要让用户知道哪些链接失效了(原来是静默删除)。
    local old tok revoked=0
    while IFS= read -r old; do
        [[ -n "$old" ]] || continue
        if (( revoked == 0 )); then
            echo "  [注意] $tag 已存在旧链接, 重建会让它们立即失效:" >&2
        fi
        echo "    - ${old:0:16}…" >&2
        _sb_share_api delete --token "$old" >/dev/null 2>&1 && revoked=$((revoked+1))
    done < <(_sb_share_list | python3 -c '
import sys, json
tag = sys.argv[1]
try: recs = json.load(sys.stdin)
except Exception: recs = []
for r in recs:
    if str((r.get("meta") or {}).get("tag","")) == tag: print(r.get("token",""))
' "$tag" 2>/dev/null)
    (( revoked > 0 )) && print_warn "已作废 $revoked 个旧链接"

    local tmp rec token expires
    tmp=$(mktemp)
    if ! _sb_share_content_file "$tag" "$tmp"; then
        rm -f "$tmp"; print_error "读取客户端配置失败: $client_file"; return 1
    fi
    # 发布前校验: 内容里的节点必须还在真实配置里、端口必须与真实监听一致。
    # 不通过就**不发** —— 发出去的是死节点, 而且冻结在服务里不会自愈。
    if ! sb_share_consistency_check "$tag"; then
        rm -f "$tmp"
        print_error "分享内容与服务端真实配置不一致, 已中止发布 ($tag)"
        return 1
    fi
    local ttl_s=0; [[ "$ttl" -gt 0 ]] && ttl_s=$((ttl * 3600))

    # ---- 两条产品 + 内核声明（三家互通）----
    # 主产品 = **普通话(URI 列表)**: xbd / mihomo / 第三方面板都读得懂它。
    # 附带产品 = **原生(sing-box JSON)**: 只有同内核同发行版的客户端读, 零损失。
    # 声明写在给用户的地址上 —— 客户端据此单方面决定拉哪一份。
    local uri_payload loss_json native_tok="" declared="" nrec meta2 facts dist ver
    uri_payload=$(mktemp) || { rm -f "$tmp"; print_error "临时文件创建失败"; return 1; }
    if ! _sb_share_uri_payload "$tag" "$uri_payload"; then
        rm -f "$tmp" "$uri_payload"
        print_error "URI(普通话)产品生成失败 —— 拒绝发布（不许发一份少节点的订阅）"
        return 1
    fi
    # ---- 发布闸门 1: 链接本身对不对 ----
    local guard_json
    if ! guard_json=$(_sb_share_link_guard "$tag"); then
        rm -f "$tmp" "$uri_payload"
        print_error "分享链接校验不通过 —— 拒绝发布（这些链接会让对方整条订阅归零）"
        print_error "把上面对应的节点产物重新生成一次（面板重建该节点 / 批量重建），再发分享"
        return 1
    fi
    # URI 表达力损失必须**显式标注**再发布（"别假装有"）。标注失败 = 不发。
    if ! loss_json=$(_sb_share_uri_loss_report "$tag" "$tmp"); then
        rm -f "$tmp" "$uri_payload"
        print_error "URI 表达力标注失败 —— 拒绝发布"
        return 1
    fi
    local uri_bytes; uri_bytes=$(wc -c < "$uri_payload" | tr -d ' ')
    rec=$(_sb_share_api create --type node --content-type "text/plain; charset=utf-8" \
            --content-file "$uri_payload" --ttl "$ttl_s" \
            --max-uses "$max_uses" --meta "{\"tag\":\"$tag\"}" 2>/dev/null)
    token=$(printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
    if [[ -z "$token" ]]; then
        rm -f "$tmp" "$uri_payload"
        print_error "公共服务创建分享失败 (普通话)"
        return 1
    fi

    # 附带记录: 原生产物。TTL 与次数上限**同源** —— 一条永久一条 24 小时会让
    # 用户以为"原生自己坏了"。（地址就写在主记录的声明里, 额度不同 = 后门。）
    facts=$(sb_share_self_facts)
    dist=$(sb_share_fact "$facts" distribution)
    ver=$(sb_share_fact "$facts" version)
    if [[ -z "$dist" ]]; then
        print_warn "内核发行版探测不到 ($(sb_share_fact "$facts" note)) —— 不产出原生, 只发普通话(URI)"
    else
        nrec=$(_sb_share_api create --type node --content-type "application/json" \
                 --content-file "$tmp" --ttl "$ttl_s" --max-uses "$max_uses" \
                 --meta "$(python3 -c '
import json, sys
print(json.dumps({"tag": sys.argv[1], "role": "native", "kernel": "sing-box",
                  "distribution": sys.argv[2], "kernel_version": sys.argv[3],
                  "parent": sys.argv[4]}, ensure_ascii=False))
' "$tag" "$dist" "$ver" "$token")" 2>/dev/null)
        native_tok=$(printf '%s' "$nrec" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("token",""))
except Exception: print("")' 2>/dev/null)
        if [[ -z "$native_tok" ]]; then
            print_error "原生产物的分享记录没建起来 —— 已建好的普通话记录将被撤销（两条记录必须成对）"
            _sb_share_api delete --token "$token" >/dev/null 2>&1
            rm -f "$tmp" "$uri_payload"
            return 1
        fi
    fi

    # 声明与"原生产物在哪"写进主记录的 meta —— 列表/刷新/吊销都靠它。
    # meta 是**整体替换**, 所以 tag 必须一起带上。
    meta2=$(python3 -c '
import json, sys
print(json.dumps({"tag": sys.argv[1], "role": "primary", "kernel": "sing-box",
                  "distribution": sys.argv[2], "kernel_version": sys.argv[3],
                  "formats": ["uri"] + ([sys.argv[2]] if sys.argv[4] else []),
                  "native_token": sys.argv[4],
                  "uri_bytes": int(sys.argv[6]),
                  "uri_losses": json.loads(sys.argv[5] or "{}"),
                  "link_guard": json.loads(sys.argv[7] or "{}")}, ensure_ascii=False))
' "$tag" "$dist" "$ver" "$native_tok" "$loss_json" "$uri_bytes" "$guard_json" 2>/dev/null)
    if [[ -n "$meta2" ]]; then
        _sb_share_api update --token "$token" --meta "$meta2" >/dev/null 2>&1 \
            || print_warn "声明没写进 meta (分享本身可用, 但列表里看不到原生地址)"
    else
        print_warn "声明 meta 组装失败 (分享本身可用, 但列表里看不到原生地址)"
    fi
    rm -f "$tmp" "$uri_payload"

    local url; url="$(share_url_for "$token")"
    declared=$(sb_share_declared_url "$token" "$native_tok"); [[ -n "$declared" ]] || declared="$url"
    # 落盘的是**裸地址**: 地址族切换 (switch-family) 会改写这个文件里的 host,
    # 而带声明的地址里还嵌着一条百分号编码的原生地址 —— 落盘它会变成死链。
    # 带声明的地址每次**现算**并打印给用户（列表里也是现算）。
    echo "$url" | tee "$SB_OUT_DIR/share_tag-$tag.txt"
    if [[ -n "$native_tok" ]]; then
        print_info "格式: 普通话(URI 列表, N 行) + 原生(sing-box JSON) —— 同内核同发行版的客户端自动拉原生, 其余走普通话"
    else
        print_info "格式: 仅普通话(URI 列表) —— 地址上仍带声明, 客户端据此走通用格式"
    fi
    print_info "带声明的地址(客户端据此决策, 从**这里**复制): $declared"
    expires=$(printf '%s' "$rec" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("expires_at",0)))' 2>/dev/null)
    if [[ "${expires:-0}" -gt 0 ]]; then
        print_ok "max_uses=$max_uses, 有效期 ${ttl} 小时 ($(date -d @$expires '+%F %T'))"
    else
        print_ok "max_uses=$max_uses, 有效期: 永久"
    fi
}


  # 为聚合配置 (sb_client-all.json) 单独发一个 share token。
  # create_share 走单节点文件路径 (sb_client-<tag>.json), 聚合产物走不了那条路,
  # 于是菜单"全量聚合"承诺的 all-share URL 实际上从来没被生成过。
  # 这里直接对聚合文件发 token, 与单节点链接同一套元数据/消费语义。

# 为聚合配置 (sb_client-all.json) 单独发一个 share token。
# 与单节点链接同一套元数据/消费语义, 只是内容换成聚合产物。


# 分享内容 = 客户端配置文件的**内容**(公共服务不解析它, 只存字节)。
#
# 旧实现存的是**文件路径**(client_file), 服务端访问时再去读那个文件 ——
# 那要求内容一直留在本机、且路径不变。改成创建时读一次写入公共服务;
# 内容变了由 share_refresh_all 主动 PUT 刷新(token/URL 不变)。
_sb_share_content_file() { # <tag> <输出文件>  0=成功
    local tag="$1" out="$2" src="$SB_OUT_DIR/sb_client-$tag.json"
    [[ -f "$src" ]] || return 1
    cp -f "$src" "$out" || return 1
    grep -q '"outbounds"' "$out" 2>/dev/null
}

# ==============================================================
# 生成后一致性校验: 分享内容 ↔ 真实配置 / 真实监听
#
# 为什么需要: 分享内容 = out/sb_client-<tag>.json 的**字节副本**, 这比 M / X
# 那种"再渲染一遍"干净 (不存在"分享层与产物不一致"的可能) —— 但副本在创建
# 那一刻**冻结**, 于是引入另一类不一致: **产物 vs 真实配置**。
# 实证过的后果: 节点删掉/端口改掉之后, 公共服务里的记录仍然活着, 继续下发
# 指向已删节点的内容; 而 share_refresh_all 找不到产物只能 continue ⇒ 那条
# 记录永远不会自愈, 用户手上的订阅是死的 (与 M 的 P-M2 同后果)。
#
# 校验收口 (权威是 config/*.json 的 inbounds, 不是产物文件):
#   1) 分享内容里每个 outbound 的 tag 必须能在 inbounds[].tag 里找到
#      (兼容聚合产物的 "<服务器前缀>-" 前缀, 与 shadowtls 的内层 "<tag>-out");
#   2) 直连节点的 server_port 必须等于该 inbound 的 listen_port;
#      CDN 节点跳过 —— 它只监听 127.0.0.1, 客户端走 域名:443, 两者本来不同;
#   3) 端口当前是否真的在监听 (ss): 只告警不拦 —— 刚写完配置还没 reload 时
#      会短暂为假, 但必须让人看见。
# 失败一律"报告 + 拒绝发布", 绝不偷偷改产物。
# ==============================================================

# 真实 inbound 索引: 每行 "tag\tlisten\tlisten_port"
_sb_live_index_file() {
    local f c; f=$(mktemp)
    for c in "$SB_CONFIG_DIR"/*.json; do
        [[ -f "$c" ]] || continue
        jq -r '.inbounds[]? | select(.tag != null) | [.tag, (.listen // ""), (.listen_port // "")] | @tsv' \
            "$c" 2>/dev/null
    done | sort -u > "$f"
    printf '%s' "$f"
}

# 在索引里找 tag (允许 "<前缀>-<tag>" 与 "<tag>-out" 两种写法)
_sb_live_lookup() { # <tag> <索引文件> -> "listen\tport" (找不到则空)
    local t="$1" ix="$2" base="${1%-out}"
    # 末尾的 length(...) > length($1) 守卫是必须的: awk 的 index() 找不到时
    # 返回 0, 而"恰好等长"时 length(b)-length($1) 也是 0 —— 少了守卫就会把
    # "base 正好等于索引里的 tag" 当成"后缀匹配"而误命中别的节点。
    awk -F'\t' -v t="$t" -v b="$base" '
        $1 == t { print; exit }
        $1 == b { print; exit }
        index(t, "-" $1) == length(t) - length($1) && length(t) > length($1) { print; exit }
        index(b, "-" $1) == length(b) - length($1) && length(b) > length($1) { print; exit }
    ' "$ix"
}

# 校验一份客户端产物 (单节点或聚合) -> 0=一致, 1=有不一致 (原因写 stderr)
_sb_share_verify_file() { # <产物文件> <索引文件>
    local f="$1" ix="$2" bad=0 tag lport aport
    # 套接字快照只取一次, 并且必须把两种"看不到端口"分开:
    #   · ss 能用, 但**这个端口**没在听      → 真问题 → bad=1（拒发）
    #   · ss **一条套接字都看不到**（或干脆没有 ss）→ 是**工具**的问题
    #     （容器/权限/netns/精简系统）, 这时逐个端口判"没在听"会把**每个**节点
    #     都判死, 于是发布闸门全量拒发 —— 那不是"发现了死节点", 那是我们瞎了
    #     却假装看见。与"配置目录为空就跳过校验"同一条 fail-open 原则:
    #     **明确告警说这一项本轮没验**, 不假装知道, 也不拿它去拦发布。
    local ss_tbl="" ss_ok=0 ss_dim=0
    if command -v ss >/dev/null 2>&1; then
        ss_tbl=$(ss -tulnH 2>/dev/null | awk '{print $5}')
        [[ -n "$ss_tbl" ]] && ss_ok=1
    fi
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        case "$tag" in PROXY|AUTO|direct|block|dns) continue ;; esac
        local row; row=$(_sb_live_lookup "$tag" "$ix")
        if [[ -z "$row" ]]; then
            print_error "分享内容里的节点在服务端配置里不存在 (产物是旧的): $tag"
            bad=1; continue
        fi
        local lip lport
        lip=$(printf '%s' "$row" | cut -f2)
        lport=$(printf '%s' "$row" | cut -f3)
        # CDN 节点: 服务端只听 127.0.0.1, 客户端连 域名:443 —— 端口不参与比对
        if [[ "$lip" == "127.0.0.1" || "$lip" == "::1" ]]; then continue; fi
        aport=$(jq -r --arg t "$tag" '.outbounds[]? | select(.tag == $t) | .server_port // empty' "$f" 2>/dev/null | head -1)
        if [[ -n "$aport" && -n "$lport" && "$aport" != "$lport" ]]; then
            print_error "分享内容里的端口 ($aport) 与真实监听配置 ($lport) 不一致: $tag"
            bad=1
        elif [[ -n "$lport" ]]; then
            if (( ss_ok )); then
                # 探活。★ 字符类是 `[]:]`, **不是** `[:]` 后面跟个 `]`:
                #   · `[:]]PORT$` 在 ERE 里是「字符类 `[:]`（只有 `:`）+ 字面 `]`」,
                #     只匹配 `:]PORT` 这种 ss 从不输出的形状 → **全量误报**:
                #     每个非 loopback 节点都被判"没在听"（真机实测 11/11）,
                #     而告警长得和"端口真的挂了"一模一样 —— 假绿 + 告警疲劳,
                #     真的挂掉时反而没人信。
                #   · 本意 `[]:]PORT$` =「`]` 或 `:` 任一个, 再接 PORT」,
                #     覆盖 `*:31000` / `0.0.0.0:31000`(IPv4) 与 `[::]:31000`(IPv6)。
                #
                # 归到 bad（不只是告警）: 一致性校验同时是 create_share 的**发布
                # 闸门**, 而「端口必须与真实监听一致, 不通过就不发」是它写在
                # create_share 里的既有约定 —— 发出去的是一条死节点, 且冻结在
                # 公共分享服务里不会自愈。
                if ! printf '%s\n' "$ss_tbl" | grep -qE "[]:]${lport}$"; then
                    print_error "服务端当前没有监听 $lport (配置里有, 套接字不在 —— 这个节点现在连不上): $tag"
                    bad=1
                fi
            elif (( ss_dim == 0 )); then
                print_warn "套接字探活**跳过**: ss 看不到任何套接字（或没有 ss）—— 容器/权限/命名空间问题。端口一致性这一项本轮没验, 别当成验过了"
                ss_dim=1
            fi
        fi
    done < <(jq -r '.outbounds[]?.tag // empty' "$f" 2>/dev/null)
    return "$bad"
}

sb_share_consistency_check() { # <tag|all> -> 0=一致
    local tag="${1:-}" f ix rc=0
    [[ -n "$tag" ]] || { print_error "用法: sb_share_consistency_check <tag|all>"; return 1; }
    f="$SB_OUT_DIR/sb_client-$tag.json"
    [[ -f "$f" ]] || { print_error "找不到客户端产物: $f"; return 1; }
    ix=$(_sb_live_index_file)
    # 只有"这个部署根本还没建过节点"才跳过校验 (fail-open)。
    # 配置目录里有 json 但索引为空 = 一个 inbound 都没有 ⇒ 产物全是幽灵,
    # 这时候必须报错而不是跳过 —— 否则单节点部署删掉唯一节点后, 残留产物
    # 照样能被发出去。
    if [[ ! -s "$ix" ]] && ! compgen -G "$SB_CONFIG_DIR/*.json" >/dev/null 2>&1; then
        rm -f "$ix"
        print_warn "配置目录为空, 跳过一致性校验 ($SB_CONFIG_DIR)"
        return 0
    fi
    _sb_share_verify_file "$f" "$ix" || rc=1
    rm -f "$ix"
    (( rc == 0 )) && print_ok "分享内容与真实配置一致: $tag ($(jq -r '.outbounds|length' "$f" 2>/dev/null) 个 outbound)"
    return "$rc"
}

# 删除某个 tag 在公共服务上的全部分享记录。
# 节点被删除时必须调用 —— 否则记录留着, 内容就是"已删节点的死配置",
# 而且 share_refresh_all 再也刷不动它 (产物已经没了)。
revoke_tag() { # <tag>
    local tag="${1:-}" t n=0
    [[ -n "$tag" ]] || return 0
    _sb_share_list >/dev/null 2>&1 || return 0
    while IFS= read -r t; do
        [[ -n "$t" ]] || continue
        _sb_share_api delete --token "$t" >/dev/null 2>&1 && n=$((n+1))
    done < <(_sb_share_list | python3 -c '
import sys, json
tag = sys.argv[1]
try: recs = json.load(sys.stdin)
except Exception: recs = []
for r in recs:
    if str((r.get("meta") or {}).get("tag","")) == tag: print(r.get("token",""))
' "$tag" 2>/dev/null)
    (( n > 0 )) && print_info "已下架 $n 条指向 $tag 的分享链接 (节点已删除)" >&2
    return 0
}

# ---------------------------------------------------------------- 内容保鲜
#
# SB 的客户端配置文件会被 regen-aggregate / 节点增删重新生成, 而已发出去的
# 链接里存的是**创建时的快照**。这里在节点变化后主动刷新 —— token / URL /
# TTL / 使用次数全部不变, 只换内容。内容没变就不写(比对 content_sha256)。
share_refresh_all() {
    local js; js=$(_sb_share_list)
    [[ -z "$js" || "$js" == "[]" ]] && return 0
    # 刷新是"尽力而为": 绝不为了刷新去装服务(节点生成路径不能被网络阻塞),
    # 但服务不可达时必须**说出来** —— 否则已有链接会一直发旧内容而无人察觉。
    if ! _sb_share_api health >/dev/null 2>&1; then
        print_warn "公共分享服务不可达, 已有分享链接的内容未刷新" >&2
        return 0
    fi
    local n=0 nn=0 tok tag ntok tmp newh curh dead=0
    # ★ 只遍历**主记录**(role=primary/空), 由它带着自己的原生记录一起走。
    #   为什么不能逐条独立遍历: 两条产品的节点集合必须一致, 一条刷新成功
    #   另一条失败, 地址上却还声明着"原生在那边" —— 同内核客户端拉过去
    #   解析出 0 个节点, 看起来像"订阅空了", 而面板上一切正常。
    while IFS=$'\t' read -r tok tag ntok; do
        [[ -n "$tok" ]] || continue
        tmp=$(mktemp)
        if ! _sb_share_uri_payload "$tag" "$tmp"; then
            # 主产品(URI)建不出来 = 这条分享指向的节点/产物已经不完整, 而且
            # 再也刷不动。留着它等于长期给用户发死订阅 —— **两条记录一起下架**
            # (只删主记录会留下一条还活着的原生分享, 这个错误是静默的)。
            rm -f "$tmp"
            local del=0
            _sb_share_api delete --token "$tok" >/dev/null 2>&1 && del=1
            [[ -n "$ntok" ]] && _sb_share_api delete --token "$ntok" >/dev/null 2>&1
            if (( del )); then
                dead=$((dead+1))
                print_warn "已下架指向已删/不完整节点 $tag 的分享链接 (主记录与原生记录一起)" >&2
            else
                print_warn "$tag 的内容无法再刷新, 但下架失败, 请到菜单手动删除" >&2
            fi
            continue
        fi
        newh=$(sha256sum "$tmp" | awk '{print $1}')
        curh=$(_sb_share_api get --token "$tok" 2>/dev/null \
               | python3 -c 'import sys,json;print(json.load(sys.stdin).get("content_sha256",""))' 2>/dev/null)
        if [[ "$newh" != "$curh" ]]; then
            _sb_share_api update --token "$tok" --content-file "$tmp" >/dev/null 2>&1 && n=$((n+1))
        fi
        rm -f "$tmp"
        # ---- 附带的原生产物 ----
        [[ -n "$ntok" ]] || continue
        tmp=$(mktemp)
        if ! _sb_share_content_file "$tag" "$tmp"; then
            # 产物没了 ⇒ 声明里不许再挂着一条取不到的原生地址: 删掉原生记录,
            # 并把主记录 meta 里的 native_token/formats 清掉(地址是现算的,
            # 清掉后声明自动变成"只有普通话")。绝不留下一个假的"原生在那边"。
            rm -f "$tmp"
            if _sb_share_api delete --token "$ntok" >/dev/null 2>&1; then
                _sb_share_api update --token "$tok" --meta "$(python3 -c '
import json, sys
print(json.dumps({"tag": sys.argv[1], "role": "primary", "kernel": "sing-box",
                  "distribution": sys.argv[2], "kernel_version": sys.argv[3],
                  "formats": ["uri"], "native_token": ""}, ensure_ascii=False))
' "$tag" "$(_sb_share_fact "$(sb_share_self_facts)" distribution)" \
   "$(_sb_share_fact "$(sb_share_self_facts)" version)")" >/dev/null 2>&1
                print_warn "$tag 的原生产物已不存在, 已下架原生记录并清除声明里的原生地址 (普通话照常)" >&2
            else
                print_warn "$tag 的原生产物已不存在, 但原生记录下架失败 —— 那条地址还能拉到旧内容" >&2
            fi
            continue
        fi
        newh=$(sha256sum "$tmp" | awk '{print $1}')
        curh=$(_sb_share_api get --token "$ntok" 2>/dev/null \
               | python3 -c 'import sys,json;print(json.load(sys.stdin).get("content_sha256",""))' 2>/dev/null)
        if [[ "$newh" != "$curh" ]]; then
            _sb_share_api update --token "$ntok" --content-file "$tmp" >/dev/null 2>&1 && nn=$((nn+1))
        fi
        rm -f "$tmp"
    done < <(_sb_share_list | python3 -c '
import sys, json
try: recs = json.load(sys.stdin)
except Exception: recs = []
for r in recs:
    m = r.get("meta") or {}
    if m.get("role") == "native":
        continue                      # 原生记录跟着它的主记录走
    print("%s\t%s\t%s" % (r.get("token",""), m.get("tag",""), m.get("native_token","")))
' 2>/dev/null)
    (( n > 0 )) && print_info "已刷新 ${n} 条分享链接的普通话(URI)内容 (token 与地址未变)"
    (( nn > 0 )) && print_info "已刷新 ${nn} 条分享链接的原生(sing-box JSON)内容"
    (( dead > 0 )) && print_info "已下架 ${dead} 条指向已删节点的分享链接"
    return 0
}



list_shares() {
    print_title "分享链接"
    local js; js=$(_sb_share_list)
    if [[ -z "$js" || "$js" == "[]" ]]; then
        print_warn "当前没有任何分享链接"
        return 0
    fi
    # 编号 -> token 的映射由 _sb_share_find 按同一份 JSON 顺序现算,
    # 所以这里只要保证打印顺序 == JSON 顺序即可。
    #
    # 注意: 不要把字段用制表符吐出来再交给 bash read —— tag 为空时连续的
    # 两个制表符会被 IFS(制表符属空白符)折叠, 整行左移一列,
    # 表现为 "tag=0 uses=5/2026-10-09..." 这种错位。直接在这里排版。
    printf '%s' "$js" | python3 -c '
import sys, json, time
try: recs = json.load(sys.stdin)
except Exception: recs = []
now = int(time.time())
for i, r in enumerate(recs, 1):
    ex = int(r.get("expires_at", 0)); mu = int(r.get("max_uses", 0)); u = int(r.get("used_count", 0))
    st = "Active"
    if not r.get("enabled", True): st = "Disabled"
    elif ex and now > ex: st = "Expired"
    elif mu and u >= mu: st = "UsedUp"
    exp = "永久" if not ex else time.strftime("%F %T", time.localtime(ex))
    m = r.get("meta") or {}
    tag = m.get("tag", "") or "-"
    # 一条分享是**两条记录**(普通话主 + 原生附带)。不给格式列的话, 用户会
    # 把附带记录也当成一条独立入口去复制地址 —— 那条只有同内核客户端读得懂。
    role = m.get("role") or ""
    fmts = m.get("formats") or []
    if isinstance(fmts, str): fmts = [fmts]
    if role == "native":
        kind = "原生(附带)"
    elif fmts:
        kind = "普通话+" + ",".join(x for x in fmts if x != "uri")
    else:
        kind = "普通话"
    print("%s) %s…  tag=%s  uses=%s/%s  有效期=%s  %s  [%s]" % (
        i, str(r.get("token",""))[:16], tag, u, "∞" if not mu else mu, exp, st, kind))
' 2>/dev/null
    # ★ 打印**带声明的地址** —— 用户从这里复制的地址才带内核声明; 复制的若是
    #   裸地址, 同内核客户端也只能走普通话(URI), 而这一点不会报错。
    #   地址每次现算, 不落盘: 地址族切换会改对外 host。
    printf '\n' >&2
    print_info "拉取地址 (带内核声明; 客户端据此决定拉原生还是普通话):"
    local i=1 tok tag ntok decl
    while IFS=$'\t' read -r tok tag ntok; do
        [[ -n "$tok" ]] || continue
        decl=$(sb_share_declared_url "$tok" "$ntok") || decl=""
        if [[ -z "$decl" ]]; then
            print_warn "  $i) 取不到对外 host, 地址算不出来 (先跑一次「切换地址族」或用 share_url_for)"
        else
            printf '    %s) %s\n' "$i" "$decl" >&2
        fi
        i=$((i + 1))
    done < <(printf '%s' "$js" | python3 -c '
import sys, json
try: recs = json.load(sys.stdin)
except Exception: recs = []
for r in recs:
    m = r.get("meta") or {}
    if m.get("role") == "native":
        continue                      # 原生产物是附带记录, 不作为独立入口列出
    print("%s\t%s\t%s" % (r.get("token",""), m.get("tag",""), m.get("native_token","")))
' 2>/dev/null)
    printf '    %s(裸地址=不带声明, 任何客户端都能拉; 机器可读、地址族切换会改写它: out/share_tag-*.txt)%s\n' \
        "${DIM:-}" "${RESET:-}" >&2
    print_info "原生(附带)记录不单独列出; 撤销/停用主记录会**连带**处理它"
}

meta_file_for() { meta_file "$1"; }

# ★ 一条分享有**两条记录**: 普通话(主) 与 原生(附带)。停用/撤销必须成对 ——
#   只处理主记录的话, 原生产物**还活着**: 用户以为停了/撤了, 而挂在声明里的
#   那个地址依然能拉到同一批节点。这个错误是静默的(面板上主记录显示"已停用"),
#   所以这里一律连带, 并且把连带结果**打出来**。
del_share() {
    local tok ntok; tok=$(meta_file_for "$1")
    [[ -z "$tok" ]] && { print_error "token|tag|编号 不存在: $1"; return 1; }
    tok=$(_sb_share_primary_of "$tok")     # 选中的若是原生记录, 换回主记录
    ntok=$(_sb_share_native_of "$tok")
    _sb_share_api delete --token "$tok" >/dev/null 2>&1 || { print_error "删除失败"; return 1; }
    # 回读确认 (静默失败在旧实现里踩过)
    _sb_share_api get --token "$tok" >/dev/null 2>&1 && { print_error "删除未生效"; return 1; }
    print_ok "已删除 $tok"
    if [[ -n "$ntok" ]]; then
        if _sb_share_api delete --token "$ntok" >/dev/null 2>&1; then
            print_ok "  连带: 已删除原生产物 ${ntok:0:12}…"
        else
            print_warn "  原生产物 ${ntok:0:12}… 删除失败 —— 那个地址还能拉到节点"
        fi
    fi
}

toggle_share() {
    local tok ntok; tok=$(meta_file_for "$1")
    [[ -z "$tok" ]] && { print_error "token|tag|编号 不存在: $1"; return 1; }
    tok=$(_sb_share_primary_of "$tok")
    ntok=$(_sb_share_native_of "$tok")
    local cur want now
    cur=$(_sb_share_api get --token "$tok" 2>/dev/null \
          | python3 -c 'import sys,json;print("true" if json.load(sys.stdin).get("enabled",True) else "false")' 2>/dev/null)
    [[ "$cur" == "true" ]] && want=false || want=true
    _sb_share_api update --token "$tok" --enabled "$want" >/dev/null 2>&1
    now=$(_sb_share_api get --token "$tok" 2>/dev/null \
          | python3 -c 'import sys,json;print("true" if json.load(sys.stdin).get("enabled",False) else "false")' 2>/dev/null)
    [[ "$now" == "$want" ]] || { print_error "切换未生效"; return 1; }
    print_ok "$1 -> enabled=$want"
    if [[ -n "$ntok" ]]; then
        if _sb_share_api update --token "$ntok" --enabled "$want" >/dev/null 2>&1; then
            print_ok "  连带: 原生产物 ${ntok:0:12}… 同样$([[ "$want" == true ]] && echo 启用 || echo 停用)"
        else
            print_warn "  原生产物 ${ntok:0:12}… 没切换成功 —— 它还会应答, 建议手动检查"
        fi
    fi
}

regen_share() {
    # 公共服务的 token 就是主键, 没有"改名"这种操作 ——
    # 语义上用「建新的 + 删旧的」等价实现: 旧链接立刻失效, 新链接可用。
    # 内容/范围/次数上限/有效期全部照搬。
    local tok ntok; tok=$(meta_file_for "$1")
    [[ -z "$tok" ]] && { print_error "token|tag|编号 不存在: $1"; return 1; }
    tok=$(_sb_share_primary_of "$tok")
    ntok=$(_sb_share_native_of "$tok")
    local rec tag maxu
    rec=$(_sb_share_api get --token "$tok" 2>/dev/null)
    tag=$(printf '%s' "$rec" | python3 -c 'import sys,json;print((json.load(sys.stdin).get("meta") or {}).get("tag",""))' 2>/dev/null)
    maxu=$(printf '%s' "$rec" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("max_uses",1)))' 2>/dev/null)
    [[ -n "$tag" ]] || { print_error "读不到该分享的 tag"; return 1; }
    _sb_share_api delete --token "$tok" >/dev/null 2>&1
    # 原生记录**一起**删: 只删主记录的话, 旧的原生地址还活着(它不在列表里,
    # 用户看不见), 而新建的那一对又挂了新 token —— 静默留下一条后门。
    [[ -n "$ntok" ]] && _sb_share_api delete --token "$ntok" >/dev/null 2>&1
    create_share "$tag" "${2:-${maxu:-1}}" "${3:-24}"
}


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        create) shift; create_share "$@" ;;
        create-all)
            # share.sh create-all <max_uses> <ttl_hours>: 一个链接承载全部节点
            gen_full_profile >/dev/null 2>&1 || { print_error "聚合生成失败 (out/sb_client-*.json 为空?)"; exit 1; }
            shift; create_share "all" "$@"
            ;;
        regen-aggregate)
            # 这个动词是所有节点增删的**收口点**: 11 个协议脚本在 add/delete 之后
            # 都会调 sb_regen_aggregate -> 这里 (共 22 处), 所以刷新分享内容挂在
            # 这一处就覆盖了全部增删路径, 不用去每个协议里各插一遍。
            #
            # 两件事的顺序不能反: 必须先重建聚合产物, 再拿新产物去刷新 ——
            # 反过来会把**旧内容**当成最新重新推一遍, 看起来"刷新成功"却没变化。
            gen_full_profile >/dev/null 2>&1 || { print_error "聚合生成失败"; exit 1; }
            # 刷新是尽力而为: 服务不可达只告警, 绝不让节点增删失败。
            declare -F share_refresh_all >/dev/null 2>&1 && share_refresh_all >&2
            ;;
        list) list_shares ;;
        check)
            # 生成后一致性校验 (只读, 不改任何东西):
            #   bash conf/share.sh check all
            #   bash conf/share.sh check hysteria201-TLS
            shift; sb_share_consistency_check "${1:-all}" || exit 1 ;;
        revoke-tag)
            # 节点删除路径调用: 把该 tag 在公共服务上的记录一并下架
            revoke_tag "${2:-}" || exit 1 ;;
        del)
            # 走适配层 —— 原来这里是直接 rm 本地元数据文件, 存储搬到公共服务
            # 之后那个文件根本不存在, rm 对不存在的路径返回 0, 于是**报"已删除"
            # 而什么都没删**(静默假成功)。这类"看起来成功"的失败在本项目出现过。
            del_share "${2:-}" || exit 1 ;;
        toggle) toggle_share "$2" ;;
        regen) regen_share "$2" ;;
        *) while true; do
            print_title "分享链接管理 (share)"
            echo -e "${CYAN}1)${RESET} 生成链接 (选节点)"
            echo -e "${CYAN}2)${RESET} 生成全部节点链接 (一个链接带全部)"
            echo -e "${CYAN}3)${RESET} 列出全部链接"
            echo -e "${CYAN}4)${RESET} 删除链接"
            echo -e "${CYAN}5)${RESET} 禁用/启用 (toggle)"
            echo -e "${CYAN}6)${RESET} 重新生成 token (regen)"
            echo -e "${CYAN}7)${RESET} 切换地址族 (IPv4 / IPv6)"
            echo -e "${CYAN}0)${RESET} 返回"
            read -r -p "选择: " c
            case "$(clean_input "$c")" in
                1)
                    node_list_banner
                    tag=$(pick_node_tag)
                    [[ -n "$tag" ]] || { print_error "无节点可选 / 无效选择"; continue; }
                    ask_addr_family_now
                    m=$(safe_read "max_uses (0=不限, 回车=1)" "1")
                    h=$(ttl_prompt)
                    create_share "$tag" "$m" "$h" ;;
                2)
                    ask_addr_family_now
                    gen_full_profile >/dev/null 2>&1 || { print_error "聚合生成失败 (没有 sb_client-*.json?)"; continue; }
                    n=$(ls "$SB_OUT_DIR"/sb_client-*.json 2>/dev/null | grep -v all | wc -l)
                    echo "当前共有 $n 个可分享节点, 将全部包含:" >&2
                    ls "$SB_OUT_DIR"/sb_client-*.json 2>/dev/null | grep -v all | sed "s|.*/sb_client-||; s/.json//; s/^/  [node] /" >&2
                    m=$(safe_read "max_uses (0=不限, 回车=2)" "2")
                    h=$(ttl_prompt)
                    create_share "all" "$m" "$h" ;;
                3) list_shares ;;
                4) list_shares; read -r -p "输入编号/token/tag (回车取消): " t; [[ -n "$t" ]] && del_share "$t" ;;
                5) list_shares; read -r -p "输入编号/token/tag (回车取消): " t; [[ -n "$t" ]] && toggle_share "$t" ;;
                6) list_shares; read -r -p "输入编号/token/tag (回车取消): " t; [[ -n "$t" ]] && regen_share "$t" ;;
                7) sb_menu_addr_family ;;
                0) break ;;
                *) print_error "无效选项 $c" ;;
            esac
            read -r -p "回车继续..." _ || { echo; exit 0; }
        done ;;
    esac
fi
