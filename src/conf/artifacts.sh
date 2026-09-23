#!/bin/bash
# ==============================================================
# artifacts.sh — 客户端产物查看器 (JSON / YAML / 分享链接 / 聚合 / 合并 yaml)
# 只读 (合并 yaml 仅生成 out/sb_client-all.yaml, 不动 server 配置).
# CLI:
#   bash artifacts.sh json [编号]   # 单节点 JSON
#   bash artifacts.sh yaml  [编号]  # 单节点 YAML
#   bash artifacts.sh merged        # 全部合并成一份 mihomo YAML
#   bash artifacts.sh links         # 全部分享链接
#   bash artifacts.sh path          # 全部文件路径
# ==============================================================
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SB_LIB="${SB_LIB:-$SELF_DIR/conf/lib.sh}"
[[ -f "$SB_LIB" ]] && source "$SB_LIB"

json_files()  { ls "$SB_OUT_DIR"/sb_client-*.json 2>/dev/null | grep -v "sb_client-all.json" | sort; }
yaml_files()  { ls "$SB_OUT_DIR"/sb_client-*.yaml 2>/dev/null | sort; }
share_files() { ls "$SB_OUT_DIR"/sb_share-*.txt 2>/dev/null | sort; }
tag_of() { basename "$1" | sed -E "s/sb_client-//; s/.json$//; s/.yaml$//"; }

# ---------- 通用: 编号选择 + cat ----------
pick_and_cat() { # pick_and_cat "<file list>\n" "<kind>"
    local list="$1" kind="$2" i f n
    [[ -z "$list" ]] && { print_warn "没有产物文件 (先添加节点)"; return 1; }
    printf "${CYAN}可用 %s 产物:%b\n" "$kind" "$RESET" >&2
    local -a arr=()
    while IFS= read -r f; do arr+=("$f"); done <<<"$list"
    for i in "${!arr[@]}"; do printf " %s) %-18s %s\n" $((i+1)) "$(tag_of "${arr[i]}")" "${arr[i]}" >&2; done
    read -r -p "查看第几项 (0=返回): " n || { echo >&2; return 1; }
    n=$(clean_input "$n")
    [[ -z "$n" || "$n" == "0" ]] && return 1
    if [[ ! "$n" =~ ^[0-9]+$ ]]; then print_error "编号必须数字"; return 1; fi
    if (( n < 1 || n > ${#arr[@]} )); then print_error "编号无效 (1-$(( ${#arr[@]} )))"; return 1; fi
    printf "${MAGENTA}════════ 分享链接 (%s · %s) ════════%b\n" "$(tag_of "${arr[n-1]}")" "$kind" "$RESET" >&2
    cat "${arr[n-1]}"
    echo >&2
    printf "${CYAN}复制路径: %s%b\n" "${arr[n-1]}" "$RESET" >&2
}

pick_share() {
    local list; list=$(share_files)
    [[ -z "$list" ]] && { print_warn "没有 sb_share-*.txt"; return 1; }
    local -a arr=(); local f i n
    while IFS= read -r f; do arr+=("$f"); done <<<"$list"
    echo >&2
    for i in "${!arr[@]}"; do printf " %s) %s\n" $((i+1)) "$(tag_of "${arr[i]}")" >&2; done
    read -r -p "查看第几项 (0=返回): " n || { echo >&2; return 1; }
    n=$(clean_input "$n"); [[ -z "$n" || "$n" == "0" ]] && return 1
    if (( n < 1 || n > ${#arr[@]} )); then print_error "编号无效"; return 1; fi
    printf "${MAGENTA}════════ 分享链接 (%s) ════════%b\n" "$(tag_of "${arr[n-1]}")" "$RESET" >&2
    cat "${arr[n-1]}"
}

view_aggregate() {
    local f="$SB_OUT_DIR/sb_client-all.json"
    [[ -f "$f" ]] || { print_warn "聚合文件不存在 (可运行: bash conf/share.sh regen-aggregate)"; return 1; }
    printf "${MAGENTA}════════ sb_client-all.json ════════%b\n" "$RESET" >&2
    cat "$f"
    echo >&2
    printf "${CYAN}复制路径: %s%b\n" "$f" "$RESET" >&2
}

links_all_view() {
    local f="$SB_OUT_DIR/sb_links-all.txt"
    [[ -f "$f" ]] || { print_warn "没有 sb_links-all.txt"; return 1; }
    printf "${MAGENTA}════════ 全部节点分享链接 ════════%b\n" "$RESET" >&2
    cat "$f"
}

path_view() {
    printf "${CYAN}客户端产物路径 (可 cp/scp/复制):%b\n" "$RESET" >&2
    for f in "$SB_OUT_DIR"/sb_client-*.json "$SB_OUT_DIR"/sb_client-*.yaml "$SB_OUT_DIR"/sb_share-*.txt "$SB_OUT_DIR/sb_links-all.txt"; do
        [[ -f "$f" ]] && printf "  %s\n" "$f"
    done
}

# ---------- 全部 YAML 合并成单一 mihomo/clash 文件 ----------
merged_yaml() { # 生成 out/sb_client-all.yaml (proxies + PROXY/AUTO 组) — 交给 python 一次性合并
    local t
    t=$(yaml_files)
    [[ -z "$t" ]] && { print_warn "没有任何 YAML 产物 (先添加节点)"; return 1; }
    local -a yarr=()
    [[ -n "$t" ]] && mapfile -t yarr <<<"$t"
    python3 - "$SB_OUT_DIR/sb_client-all.yaml" "${yarr[@]}" <<PY
import sys, yaml
out = sys.argv[1]
proxies, names = [], []
for f in sys.argv[2:]:
    try:
        obj = yaml.safe_load(open(f))
    except Exception as e:
        print(f"WARN: {f}: {e}", file=sys.stderr); continue
    for p in (obj.get("proxies") or []):
        name = p.get("name")
        if not name or name in names: continue
        names.append(name); proxies.append(p)
if not proxies:
    sys.exit("no proxies parsed")
doc = {
    "mixed-port": 7890,
    "log-level": "info",
    "proxies": proxies,
    "proxy-groups": [
        {"name":"PROXY","type":"select","proxies": names + ["AUTO"]},
        {"name":"AUTO","type":"url-test","url":"https://www.gstatic.com/generate_204","interval":300,"proxies": names},
    ],
    "rules": ["MATCH,PROXY"],
}
yaml.safe_dump(doc, open(out,"w"), sort_keys=False, allow_unicode=True)
print(f"merged {len(proxies)} proxies -> {out}", file=sys.stderr)
PY
    local rc=$?
    (( rc == 0 )) || { print_error "合并失败 (pyYAML)"; return 1; }
}

merged_yaml_view() {
    merged_yaml || return 1
    echo >&2
    printf "${MAGENTA}════════ 全部节点合并 (sb_client-all.yaml) ════════%b\n" "$RESET" >&2
    cat "$SB_OUT_DIR/sb_client-all.yaml"
    echo >&2
    printf "${CYAN}复制路径: %s%b\n" "$SB_OUT_DIR/sb_client-all.yaml" "$RESET" >&2
}

# ---------- 菜单 ----------
show_menu() {
    while true; do
        print_title "客户端产物 / 配置文件 (JSON·YAML·链接)"
        echo -e "${CYAN}1)${RESET} 单节点 JSON (客户端配置, 复制用)"
        echo -e "${CYAN}2)${RESET} 单节点 YAML  (mihomo/clash 兼容)"
        echo -e "${CYAN}3)${RESET} 单节点分享链接 (trojan:// etc.)"
        echo -e "${CYAN}4)${RESET} 全量聚合 (sb_client-all.json + all-share URL)"
        echo -e "${CYAN}5)${RESET} sb_links-all.txt (一键复制所有节点链接)"
        echo -e "${CYAN}6)${RESET} 全部文件路径 (给 shell/cp/复制用)"
        echo -e "${CYAN}7)${RESET} 全部节点合并成一份 mihomo YAML (sb_client-all.yaml)"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请输入选项 [0-7]: " c || { echo; exit 0; }
        case "$(clean_input "$c")" in
            1) pick_and_cat "$(json_files)" "JSON" ;;
            2) pick_and_cat "$(yaml_files)" "YAML" ;;
            3) pick_share ;;
            4) view_aggregate ;;
            5) links_all_view ;;
            6) path_view ;;
            7) merged_yaml_view ;;
            0) return ;;
            *) print_error "无效选项" ;;
        esac
        read -r -p "按回车键返回主菜单..." _ || { echo; exit 0; }
    done
}

# ---------- CLI ----------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        json)   pick_and_cat "$(json_files)" "JSON" ;;
        yaml)   pick_and_cat "$(yaml_files)" "YAML" ;;
        share)  pick_share ;;
        all)    view_aggregate ;;
        links)  links_all_view ;;
        merged) merged_yaml_view ;;
        path)   path_view ;;
        *)      show_menu ;;
    esac
fi
