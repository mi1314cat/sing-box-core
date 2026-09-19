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

create_share() { 
    local tag="$1" max_uses="${2:-1}" ttl="${3:-24}"
    [[ -n "$tag" ]] || { print_error "用法: share.sh create <tag> [max_uses] [ttl_hours]"; return 1; }
    local client_file="$SB_OUT_DIR/sb_client-$tag.json"
    [[ -f "$client_file" ]] || { print_error "找不到 $tag 的客户端配置 ($client_file)"; return 1; }
    # 同 tag 旧 token 全部下架
    local old token now expires f
    for f in "$SHARED"/*.json; do
        [[ -f "$f" ]] || continue
        [[ "$(jq -r .tag "$f" 2>/dev/null)" == "$tag" ]] && rm -f "$f"
    done
    token=$(openssl rand -hex 16)      # 128-bit 密码学随机
    now=$(date +%s); expires=$((now + ttl*3600))
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
    print_ok "max_uses=$max_uses ttl=${ttl}h"
}

list_shares() {
    print_title "分享链接"
    local now; now=$(date +%s)
    local f
    for f in "$SHARED"/*.json; do
        [[ -f "$f" ]] || continue
        local tg tok mu u ex en st=Active
        tg=$(jq -r .tag "$f"); tok=$(jq -r .share_token "$f")
        mu=$(jq -r .max_uses "$f"); u=$(jq -r .used_count "$f")
        ex=$(jq -r .expires_at "$f"); en=$(jq -r .enabled "$f")
        [[ "$en" == "false" ]] && st=Disabled
        [[ "$ex" != "0" && "$now" -gt "$ex" ]] && st=Expired
        [[ "$mu" != "0" && "$u" -ge "$mu" ]] && st=UsedUp
        printf "%s...  tag=%s  uses=%s/%s  expires=%s  %s\n" "${tok:0:16}" "$tg" "$u" "$mu" "$([[ $ex == 0 ]] && echo never || date -d @$ex '+%F %T')" "$st"
    done
}

meta_file_for() { meta_file "$@"; }
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
        list) list_shares ;;
        del) del_share "$2" ;;
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
                    m=$(safe_read "max_uses (0=不限)" "1")
                    h=$(safe_read "ttl_hours" "24")
                    create_share "$tag" "$m" "$h" ;;
                2)
                    gen_full_profile >/dev/null 2>&1 || { print_error "聚合生成失败 (没有 sb_client-*.json?)"; continue; }
                    m=$(safe_read "max_uses (0=不限)" "2")
                    h=$(safe_read "ttl_hours" "24")
                    create_share "all" "$m" "$h" ;;
                3) list_shares ;;
                4) read -r -p "token 或 tag (回车取消): " t; [[ -n "$t" ]] && del_share "$t" ;;
                5) read -r -p "token 或 tag: " t; toggle_share "$t" ;;
                6) read -r -p "token 或 tag: " t; regen_share "$t" ;;
                0) break ;;
                *) print_error "无效选项 $c" ;;
            esac
            read -r -p "回车继续..." _
        done ;;
    esac
fi
