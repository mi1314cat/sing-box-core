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
    host=$(sb_addr_current)
    [[ -z "$host" ]] && host=$(default_server_ip)
    echo "http://$(sb_url_host "$host"):$(sb_share_port)/share/$tok"
}


# 聚合全部节点 outbound → 一份 client profile (selector PROXY + urltest AUTO + route.final)
gen_full_profile() {
    local out="$SB_OUT_DIR/sb_client-all.json"
    local srvname; srvname="$(sb_server_name)"
    python3 - "$SB_OUT_DIR" "$out" "$srvname" <<'PY'
import json,glob,sys,os,re
odir,ofile=sys.argv[1],sys.argv[2]
SRV=sys.argv[3] if len(sys.argv)>3 else ""

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

pref=slug(SRV) if SRV else ""
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
    rec=$(_sb_share_api create --type node --content-file "$tmp" --ttl "$ttl_s" \
            --max-uses "$max_uses" --meta "{\"tag\":\"$tag\"}" 2>/dev/null)
    rm -f "$tmp"
    token=$(printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
    [[ -n "$token" ]] || { print_error "公共服务创建分享失败"; return 1; }

    local url; url="$(share_url_for "$token")"
    echo "$url" | tee "$SB_OUT_DIR/share_tag-$tag.txt"
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
        elif [[ -n "$lport" ]] && command -v ss >/dev/null 2>&1; then
            ss -tulnH 2>/dev/null | awk '{print $5}' | grep -qE "[:]]${lport}$" \
                || print_warn "服务端当前没有监听 $lport (配置里有, 套接字不在 —— 这个节点现在连不上): $tag"
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
    local n=0 tok tag tmp newh curh dead=0
    while IFS=$'\t' read -r tok tag; do
        [[ -n "$tok" ]] || continue
        tmp=$(mktemp)
        if ! _sb_share_content_file "$tag" "$tmp"; then
            # 产物已经不在了 ⇒ 这条记录指向一个**已删除的节点**, 而且再也
            # 刷不动 (没有内容可刷)。留着它等于长期给用户发死节点 —— 直接下架。
            rm -f "$tmp"
            if _sb_share_api delete --token "$tok" >/dev/null 2>&1; then
                dead=$((dead+1))
                print_warn "已下架指向已删节点 $tag 的分享链接 (内容无法再刷新)" >&2
            else
                print_warn "$tag 的客户端产物已不存在, 但下架失败, 请到菜单手动删除" >&2
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
    done < <(_sb_share_list | python3 -c '
import sys, json
try: recs = json.load(sys.stdin)
except Exception: recs = []
for r in recs:
    print("%s\t%s" % (r.get("token",""), (r.get("meta") or {}).get("tag","")))
' 2>/dev/null)
    (( n > 0 )) && print_info "已刷新 ${n} 条分享链接的内容 (token 与地址未变)"
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
    tag = (r.get("meta") or {}).get("tag", "") or "-"
    print("%s) %s…  tag=%s  uses=%s/%s  有效期=%s  %s" % (
        i, str(r.get("token",""))[:16], tag, u, "∞" if not mu else mu, exp, st))
' 2>/dev/null
}

meta_file_for() { meta_file "$1"; }

del_share() {
    local tok; tok=$(meta_file_for "$1")
    [[ -z "$tok" ]] && { print_error "token|tag|编号 不存在: $1"; return 1; }
    _sb_share_api delete --token "$tok" >/dev/null 2>&1 || { print_error "删除失败"; return 1; }
    # 回读确认 (静默失败在旧实现里踩过)
    _sb_share_api get --token "$tok" >/dev/null 2>&1 && { print_error "删除未生效"; return 1; }
    print_ok "已删除"
}

toggle_share() {
    local tok; tok=$(meta_file_for "$1")
    [[ -z "$tok" ]] && { print_error "token|tag|编号 不存在: $1"; return 1; }
    local cur want now
    cur=$(_sb_share_api get --token "$tok" 2>/dev/null \
          | python3 -c 'import sys,json;print("true" if json.load(sys.stdin).get("enabled",True) else "false")' 2>/dev/null)
    [[ "$cur" == "true" ]] && want=false || want=true
    _sb_share_api update --token "$tok" --enabled "$want" >/dev/null 2>&1
    now=$(_sb_share_api get --token "$tok" 2>/dev/null \
          | python3 -c 'import sys,json;print("true" if json.load(sys.stdin).get("enabled",False) else "false")' 2>/dev/null)
    [[ "$now" == "$want" ]] || { print_error "切换未生效"; return 1; }
    print_ok "$1 -> enabled=$want"
}

regen_share() {
    # 公共服务的 token 就是主键, 没有"改名"这种操作 ——
    # 语义上用「建新的 + 删旧的」等价实现: 旧链接立刻失效, 新链接可用。
    # 内容/范围/次数上限/有效期全部照搬。
    local tok; tok=$(meta_file_for "$1")
    [[ -z "$tok" ]] && { print_error "token|tag|编号 不存在: $1"; return 1; }
    local rec tag maxu
    rec=$(_sb_share_api get --token "$tok" 2>/dev/null)
    tag=$(printf '%s' "$rec" | python3 -c 'import sys,json;print((json.load(sys.stdin).get("meta") or {}).get("tag",""))' 2>/dev/null)
    maxu=$(printf '%s' "$rec" | python3 -c 'import sys,json;print(int(json.load(sys.stdin).get("max_uses",1)))' 2>/dev/null)
    [[ -n "$tag" ]] || { print_error "读不到该分享的 tag"; return 1; }
    _sb_share_api delete --token "$tok" >/dev/null 2>&1
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
