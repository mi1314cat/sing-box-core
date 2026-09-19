#!/bin/bash
# ==============================================================
# share.sh — 分享链接管理（Server 端）
# CLI:
#   bash share.sh create <tag> [max_uses=1] [ttl_hours=24]
#   bash share.sh list | del <token|tag> | toggle <token|tag> | regen <token|tag>
# URL: http://<server_ip>:9292/share/<token>
# 目录: $SB_ROOT/share/shares/<token>.json (元数据); client_file 指向 out/sb_client-<tag>.json
# 并发/原子语义由 share_server.py 的 flock 保证
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SHARE_BASE="$SB_ROOT/share"
SHARED="$SHARE_BASE/shares"
mkdir -p "$SHARED"
touch "$SHARE_BASE/.share.lock"

meta_file() {
    # 参数: token 或 tag; 输出元数据文件路径
    [[ -f "$SHARED/$1.json" ]] && { echo "$SHARED/$1.json"; return; }
    local f
    for f in "$SHARED"/*.json; do
        [[ -f "$f" ]] || continue
        if [[ "$(jq -r .tag "$f" 2>/dev/null)" == "$1" ]]; then echo "$f"; return; fi
    done
}

share_url_for() { echo "http://$(default_server_ip):9292/share/$(jq -r .share_token "$1")"; }

# 聚合全部节点 outbound → 一份 client profile (selector PROXY + urltest AUTO + route.final)
gen_full_profile() {
    local out="$SB_OUT_DIR/sb_client-all.json"
    python3 - "$SB_OUT_DIR" "$out" <<'PY'
import json,glob,sys,os
odir,ofile=sys.argv[1],sys.argv[2]
obs=[]; seen=set()
for f in sorted(glob.glob(os.path.join(odir,"sb_client-*.json"))):
    base=os.path.basename(f)
    if base=="sb_client-all.json": continue
    for o in json.load(open(f)).get("outbounds",[]):
        if o.get("type") in ("selector","urltest","direct","block","dns"): continue
        if o.get("tag") in seen: continue
        seen.add(o.get("tag")); obs.append(o)
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

create_share() { 
    local tag="$1" max_uses="${2:-1}" ttl="${3:-24}"
    [[ -n "$tag" ]] || { print_error "用法: share.sh create <tag> [max_uses] [ttl_hours]"; return 1; }
    local client_file="$SB_OUT_DIR/sb_client-$tag.json"
    [[ -f "$client_file" ]] || { print_error "找不到 $tag 的客户端配置 ($client_file)"; return 1; }
    # 参数校验 (在任何旧数据被改动之前)
    [[ "$max_uses" =~ ^[0-9]+$ ]] || { print_error "max_uses 必须是非负整数 (0=不限), 收到: $max_uses"; return 1; }
    [[ "$ttl" =~ ^[0-9]+$ ]] || { print_error "ttl_hours 必须是小时数 (0=永久), 收到: $ttl"; return 1; }
    # 同 tag 旧 token 全部下架
    local old token now expires f
    for f in "$SHARED"/*.json; do
        [[ -f "$f" ]] || continue
        [[ "$(jq -r .tag "$f" 2>/dev/null)" == "$tag" ]] && rm -f "$f"
    done
    token=$(openssl rand -hex 16)      # 128-bit 密码学随机
    now=$(date +%s)
    # ttl=0 => 永久 (expires_at=0 表示永不过期; 服务端 0 跳过过期检查)
    if [[ "$ttl" -gt 0 ]]; then expires=$((now + ttl*3600)); else expires=0; fi
    python3 - "$SHARED" "$token" "$tag" "$client_file" "$max_uses" "$expires" <<'PY'
import json,sys,os,time
d,token,tag,cf,maxu,exp = sys.argv[1:7]
meta={"share_token":token,"tag":tag,"client_file":cf,"created_at":int(time.time()),
      "expires_at":int(exp),"max_uses":int(maxu),"used_count":0,
      "enabled":True,"last_used_at":0}
open(os.path.join(d,f"{token}.json"),"w").write(json.dumps(meta,indent=1))
PY
    local url; url="$(share_url_for "$SHARED/$token.json")"
    echo "$url" | tee "$SB_OUT_DIR/share_tag-$tag.txt"
    if [[ "$ttl" -gt 0 ]]; then
        print_ok "max_uses=$max_uses, 有效期 ${ttl} 小时 ($(date -d @$expires '+%F %T'))"
    else
        print_ok "max_uses=$max_uses, 有效期: 永久"
    fi
}

share_files_sorted() { ls "$SHARED"/*.json 2>/dev/null | sort; }

list_shares() {
    print_title "分享链接"
    local now; now=$(date +%s)
    local f i=0
    local entries=()
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        local tg tok mu u ex en st=Active
        tg=$(jq -r .tag "$f"); tok=$(jq -r .share_token "$f")
        mu=$(jq -r .max_uses "$f"); u=$(jq -r .used_count "$f")
        ex=$(jq -r .expires_at "$f"); en=$(jq -r .enabled "$f")
        [[ "$en" == "false" ]] && st=Disabled
        [[ "$ex" != "0" && "$now" -gt "$ex" ]] && st=Expired
        [[ "$mu" != "0" && "$u" -ge "$mu" ]] && st=UsedUp
        i=$((i+1)); entries+=("$f")
        printf "%s) %s…  tag=%s  uses=%s/%s  有效期=%s  %s\n" "$i" "${tok:0:16}" "$tg" "$u" "$mu" "$([[ $ex == 0 ]] && echo 永久 || date -d @$ex '+%F %T')" "$st"
    done < <(share_files_sorted)
    [[ $i -eq 0 ]] && { print_warn "当前没有任何分享链接"; return 0; }
    printf '%s\n' "${entries[@]}" > /tmp/.sb-share-entries
}

meta_file_for() {
    local out
    out=$(meta_file "$@" 2>/dev/null || true)
    if [[ -z "$out" ]]; then out=$(_ByNumber "$1" 2>/dev/null || true); fi
    echo "$out"
}
_ByNumber() { # ByNumber <choice> -> token file (auto pick when multiple match)
    local c="$1"
    if [[ "$c" =~ ^[0-9]+$ ]]; then
        local files=(); local f
        for f in $(share_files_sorted); do files+=("$f"); done
        local n=${#files[@]}
        (( n > 0 && c >= 1 && c <= n )) || { echo ""; return 1; }
        echo "${files[c-1]}"; return 0
    fi
    local hit
    hit=$(for f in $(share_files_sorted); do
        local tok tg; tok=$(jq -r .share_token "$f"); tg=$(jq -r .tag "$f")
        [[ "$tok" == "*$c*" || "$tok" == "$c" || "$tg" == "$c" ]] && echo "$f"
    done | head -1)
    [[ -n "$hit" ]] && { echo "$hit"; return 0; }
    return 1
}

del_share() {
    local f; f=$(meta_file_for "$1")
    [[ -z "$f" ]] && { print_error "token|tag 不存在: $1"; return 1; }
    rm -f "$f"
    print_ok "已删除"
}

toggle_share() {
    local f; f=$(meta_file_for "$1")
    [[ -z "$f" ]] && { print_error "token|tag 不存在: $1"; return 1; }
    local cur nv
    cur=$(jq -r .enabled "$f")
    [[ "$cur" == "false" ]] && nv=true || nv=false
    if [[ "$cur" == "false" ]]; then
        jq '.enabled = true' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    else
        jq '.enabled = false' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
    print_ok "$1 -> enabled=$nv"
}

regen_share() {
    local f; f=$(meta_file_for "$1")
    [[ -z "$f" ]] && { print_error "token|tag 不存在: $1"; return 1; }
    local tag maxu
    tag=$(jq -r .tag "$f"); maxu=$(jq -r .max_uses "$f")
    rm -f "$f"
    create_share "$tag" "${2:-$maxu}" "${3:-24}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        create) shift; create_share "$@" ;;
        create-all)
            # share.sh create-all <max_uses> <ttl_hours>: 一个链接承载全部节点
            gen_full_profile >/dev/null 2>&1 || { print_error "聚合生成失败 (out/sb_client-*.json 为空?)"; exit 1; }
            shift; create_share "all" "$@"
            ;;
        regen-aggregate) gen_full_profile >/dev/null 2>&1 || { print_error "聚合生成失败"; exit 1; } ;;
        list) list_shares ;;
        del)
            f=$(meta_file_for "$2" 2>/dev/null); [[ -z "$f" ]] && f=$( _ByNumber "$2" )
            [[ -n "$f" ]] && { rm -f "$f" && print_ok "分享已删除"; } || { print_error "token|tag|编号 不存在: $2"; return 1; } ;;
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
            echo -e "${CYAN}0)${RESET} 返回"
            read -r -p "选择: " c
            case "$(clean_input "$c")" in
                1)
                    node_list_banner
                    tag=$(pick_node_tag)
                    [[ -n "$tag" ]] || { print_error "无节点可选 / 无效选择"; continue; }
                    m=$(safe_read "max_uses (0=不限, 回车=1)" "1")
                    h=$(ttl_prompt)
                    create_share "$tag" "$m" "$h" ;;
                2)
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
                0) break ;;
                *) print_error "无效选项 $c" ;;
            esac
            read -r -p "回车继续..." _ || { echo; exit 0; }
        done ;;
    esac
fi
