#!/bin/bash
# ==============================================================
# artifacts.sh — 客户端产物查看器 (JSON / YAML / 分享链接 / 聚合)
# 完全只读; 不改任何配置。view_mode 可用于非交互:
#   bash artifacts.sh json [tag]    cat /out/sb_client-<tag>.json
#   bash artifacts.sh yaml [tag]    cat /out/sb_client-<tag>.yaml
#   bash artifacts.sh links         单节点分享链接 (sb_share-*.txt)
#   bash artifacts.sh all           聚合 sb_client-all.json + all 分享链接
# 菜单模式: 编号选择查看单个; 项不存在则提示.
# ==============================================================
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SB_LIB="${SB_LIB:-$SELF_DIR/conf/lib.sh}"
[[ -f "$SB_LIB" ]] && source "$SB_LIB"

json_files()  { ls "$SB_OUT_DIR"/sb_client-*.json 2>/dev/null | grep -v "sb_client-all.json" | sort; }
yaml_files()  { ls "$SB_OUT_DIR"/sb_client-*.yaml 2>/dev/null | sort; }
share_files() { ls "$SB_OUT_DIR"/sb_share-*.txt 2>/dev/null | sort; }
tag_of() { basename "$1" | sed -E "s/sb_client-//; s/.json$//; s/.yaml$//"; }

show_menu() {
    while true; do
        print_title "客户端产物 / 配置文件 (JSON·YAML·链接)"
        echo -e "${CYAN}1)${RESET} 单节点 JSON (客户端配置, 复制用)"
        echo -e "${CYAN}2)${RESET} 单节点 YAML  (mihomo/clash 兼容)"
        echo -e "${CYAN}3)${RESET} 单节点分享链接 (trojan:// etc.)"
        echo -e "${CYAN}4)${RESET} 全量聚合 (sb_client-all.json + all-share URL)"
        echo -e "${CYAN}5)${RESET} sb_links-all.txt (一键复制所有节点链接)"
        echo -e "${CYAN}6)${RESET} 全部文件路径 (给 shell/cp/复制用)"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请输入选项 [0-6]: " c || { echo; exit 0; }
        case "$(clean_input "$c")" in
            1) pick_and_cat "$(json_files)" "JSON" ;;
            2) pick_and_cat "$(yaml_files)" "YAML" ;;
            3) pick_cat_shares ;;
            4) view_aggregate ;;
            5) links_all_view ;;
            6) path_view ;;
            0) return ;;
            *) print_error "无效选项" ;;
        esac
        read -r -p "按回车键返回主菜单..." _ || { echo; exit 0; }
    done
}

pick_and_cat() { # pick_and_cat "<file list>" "<kind>"
    local list="$1" kind="$2" i=0 pick arr=()
    [[ -z "$list" ]] && { print_warn "没有产物文件 (先添加节点)"; return; }
    printf "${CYAN}可用 %s 产物:%b\n" "$kind" "$RESET" >&2
    local f
    while IFS= read -r f; do arr+=("$f"); done <<<"$list"
    for i in "${!arr[@]}"; do printf " %s) %-18s %s\n" $((i+1)) "$(tag_of ${arr[i]})" "${arr[i]}" >&2; done
    read -r -p "查看第几项 (0=返回): " n || { echo; return; }
    n=$(clean_input "$n"); [[ "$n" =~ ^[0-9]+$ && "$n" -lt ${#arr[@]}+1 ]] && { n=0; return 1; } || true
    (( n >= 1 && n <= ${#arr[@]} )) || { print_error "编号无效"; return 1; }
    echo
    printf "${MAGENTA}════════ %s (%s) ════════%b\n" "$(tag_of ${arr[n-1]})" "$kind" "$RESET" >&2
    cat "${arr[i]}"
    printf "${MAGENTA}════════ 复制路径: %s ════════%b\n" "${arr[i]}" "$RESET" >&2
}

pick_cat_shares() {
    local list; list=$(share_files); [[ -z "$list" ]] && { print_warn "没有 sb_share-*.txt"; return 1; }
    local -a arr=(); local f i
    while IFS= read -r f; do arr+=("$f"); done <<<"$list"
    echo >&2
    for i in "${!arr[@]}"; do printf " %s) %s\n" $((i+1)) "$(tag_of ${arr[i]})" >&2; done
    read -r -p "查看第几项 (0=返回): " n || { echo; exit 0; }
    n=$(clean_input "$n"); [[ -z "$n" ]] && return 0
    (( n-1 < ${#arr[@]} )) || { print_error "编号无效"; return 1; }
    printf "${MAGENTA}════════ 分享链接 (%s) ════════%b\n" "$(tag_of ${arr[n-1]})" "$RESET" >&2
    cat "${arr[n-1]}"
}

view_aggregate() {
    local f="$SB_OUT_DIR/sb_client-all.json"
    [[ -f "$f" ]] || { print_warn "聚合文件不存在 (重新生成: bash conf/share.sh regen-aggregate)"; return 1; }
    printf "${MAGENTA}════════ sb_client-all.json ════════%b\n" "$RESET" >&2
    jq -e . "$f" >/dev/null 2>&1 && { echo "unified OK"; cat "$f"; }
    printf "${CYAN}导出 all-share URL (重新生成→复制)${RESET}:\n" >&2
    bash "$SELF_DIR/conf/share.sh" create-all </dev/null 2>&1 | tail -1
}

links_all_view() { local f="$SB_OUT_DIR/sb_links-all.txt"; [[ -f "$f" ]] || { print_warn "没有 sb_links-all.txt"; return 1; }; cat "$f"; }

path_view() {
    echo >&2
    printf "${CYAN}客户端产物路径 (可 cp/scp/复制):%b\n" "$RESET" >&2
    for f in "$SB_OUT_DIR"/sb_client-*.json "$SB_OUT_DIR"/sb_client-*.yaml "$SB_OUT_DIR"/sb_share-*.txt "$SB_OUT_DIR/sb_links-all.txt"; do
        [[ -f "$f" ]] && printf "  %s\n" "$f"
    done >&2
}

# ---------- CLI ----------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        json)  pick_and_cat "$(json_files)" "JSON" ;;
        yaml)  pick_and_cat "$(yaml_files)" "YAML" ;;
        share) pick_cat_shares ;;
        all)   view_aggregate ;;
        links) links_all_view ;;
        *)     show_menu ;;
    esac
fi
