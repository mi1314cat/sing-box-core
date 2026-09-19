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
        list) list_shares ;;
        del) del_share "$2" ;;
        toggle) toggle_share "$2" ;;
        regen) regen_share "$2" ;;
        *) while true; do
            print_title "分享链接管理"
            echo -e "${CYAN}1)${RESET} 生成   bash share.sh create <tag> [max_uses=1] [ttl_hours=24]"
            echo -e "${CYAN}2)${RESET} 列表\n${CYAN}3)${RESET} 删除\n${CYAN}0)${RESET} 返回"
            read -r -p "选项: " c
            case "$(clean_input "$c")" in
                1) t=$(safe_read "节点 tag [default reality01]" "reality01"); \
                   m=$(safe_read "max_uses (0=不限)" 1); h=$(safe_read "ttl_hours" 24); create_share "$t" "$m" "$h" ;;
                2) list_shares ;;
                3) t=$(safe_read "token|tag"); del_share "$t" ;;
                0) break ;;
            esac
            read -r -p "回车继续..." _
        done ;;
    esac
fi
