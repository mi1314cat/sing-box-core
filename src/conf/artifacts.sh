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
    # 菜单承诺 "sb_client-all.json + all-share URL", 但这里原来只 cat 文件,
    # URL 从没被生成过 —— 用户按提示去找分享链接会扑空。
    # 顺带发一个聚合 share token, 让"全量聚合"名副其实。
    if declare -F make_aggregate_share >/dev/null 2>&1; then
        local mu tt
        printf "  max_uses (0=不限, 回车=1): " >&2; read -r mu
        mu=$(clean_input "$mu"); [[ -z "$mu" ]] && mu=1
        printf "  有效期小时 (0=永久, 回车=24): " >&2; read -r tt
        tt=$(clean_input "$tt"); [[ -z "$tt" ]] && tt=24
        echo >&2
        print_title "全量分享链接 (客户端 sb-client 菜单3 直接粘这个)"
        make_aggregate_share "$mu" "$tt" >&2
        echo >&2
    else
        print_warn "分享模块未加载, 跳过 URL 生成"
    fi
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
      # Nginx 片段也要能在这里找到 —— 自动插入失败时用户要靠它手工粘贴,
      # 找不到就只剩一句"配置失败"而无从补救。已插入的目标文件也一并列出,
      # 否则用户也不知道自己的 nginx 配置被写进了哪个文件。
      if [[ -f "$SB_OUT_DIR/sb_cdn-nginx-location.conf" ]]; then
          printf "\n${CYAN}Nginx CDN 相关:%b\n" "$RESET" >&2
          printf "  %s\n" "$SB_OUT_DIR/sb_cdn-nginx-location.conf" >&2
          printf "  (手工粘贴用; 自动插入请用菜单 10 → 1)\n" >&2
      fi
      # 站点配置不固定在 /etc/nginx 下 —— Docker 部署常挂在别处
      # (如宿主 /home/web/conf.d 映射进容器)。复用 CDN 模块的探测结果,
      # 免得菜单9 在 Docker 机器上什么都列不出来。
      local _cf _dirs=()
      while read -r _dirs_r; do _dirs+=("$_dirs_r"); done < <(
          d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
          [[ -f "$d/cdn_nginx.sh" ]] && source "$d/cdn_nginx.sh"
          declare -F cdn_config_roots >/dev/null 2>&1 && cdn_config_roots 2>/dev/null
          printf '%s\n' /etc/nginx/conf.d /etc/nginx/sites-enabled
      )
      for _dir in "${_dirs[@]}"; do
          [[ -d "$_dir" ]] || continue
          for _cf in "$_dir"/*.conf; do
              [[ -f "$_cf" ]] || continue
              grep -q "SB-Panel CDN" "$_cf" 2>/dev/null && printf "  已插入: %s\n" "$_cf" >&2
          done
      done
  }

# ---------- 全部节点合并成单一 mihomo/clash 文件 ----------
#
# 修复记录 (三个用户报告的问题):
#   1) 只合并 sb_client-*.yaml, 而 yaml 只有 reality/ss/trojan/tuic/vless 五个协议产出
#      -> vmess / hysteria2 / anytls 全部丢失。改为以 sb_client-*.json (sing-box
#         outbound, 权威数据源) 为准全量转换, 不再依赖各协议脚本是否顺手产出 yaml。
#   2) yaml.safe_dump 把序列写在缩进 0 (proxies: 换行后 "- name: x" 顶格),
#      与各协议脚本自己生成的 2 空格风格不一致, 复制粘贴到编辑器里很别扭。
#      改为自写序列化, 统一 2 空格缩进。
#   3) mihomo 不支持的节点原先被静默丢弃。这里逐条列出原因, 不假装"全都导出了"。
#
# 字段名依据 mihomo 官方文档 (wiki.metacubex.one/en/config/proxies/*) 逐项核对,
# 不凭记忆书写; mihomo 明确不支持的组合 (AnyTLS+Reality) 一律跳过并说明。
merged_yaml() { # 生成 out/sb_client-all.yaml (proxies + PROXY/AUTO 组)
    local -a jarr=()
    mapfile -t jarr < <(ls "$SB_OUT_DIR"/sb_client-*.json 2>/dev/null | grep -v 'sb_client-all\.json$' | sort)
    if (( ${#jarr[@]} == 0 )); then
        print_warn "没有任何客户端产物 sb_client-<tag>.json (先在「节点管理」创建节点)"
        return 1
    fi
    python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/to_mihomo.py" --merged "$SB_OUT_DIR/sb_client-all.yaml" \
        "$SB_ROOT/cert" "${jarr[@]}"
    local rc=$?
    (( rc == 0 )) || { print_error "生成失败"; return 1; }
    return 0
}

single_yaml_view() { # 生成/刷新全部单节点 mihomo YAML (与合并 YAML 同一套转换)
    local -a jarr=()
    mapfile -t jarr < <(ls "$SB_OUT_DIR"/sb_client-*.json 2>/dev/null | grep -v 'sb_client-all\.json$' | sort)
    if (( ${#jarr[@]} == 0 )); then
        print_warn "没有任何客户端产物 sb_client-<tag>.json (先在「节点管理」创建节点)"
        return 1
    fi
    python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/to_mihomo.py" --single \
        "$SB_OUT_DIR" "$SB_ROOT/cert" "${jarr[@]}" || return 1
    return 0
}

merged_yaml_view() {
    merged_yaml || return 1
    echo >&2
    printf "${MAGENTA}════════ 全部节点合并 (sb_client-all.yaml) ════════%b\n" "$RESET" >&2
    cat "$SB_OUT_DIR/sb_client-all.yaml"
    echo >&2
    printf "${CYAN}用法: 整份可直接导入 mihomo/clash; 只换节点的话复制 proxies 段, 其余保留自己的${RESET}\n" >&2
    printf "${CYAN}文件路径: %s%b\n" "$SB_OUT_DIR/sb_client-all.yaml" "$RESET" >&2
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
        echo -e "${CYAN}8)${RESET} 逐个节点生成单节点 mihomo YAML (sb_client-<tag>.yaml)"
        echo -e "${CYAN}9)${RESET} 切换产物地址族 (IPv4 / IPv6)"
        echo -e "${CYAN}10)${RESET} 切换全部产物的 uTLS 指纹 (client-fingerprint)"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请输入选项 [0-10]: " c || { echo; exit 0; }
        case "$(clean_input "$c")" in
            1) pick_and_cat "$(json_files)" "JSON" ;;
            2) pick_and_cat "$(yaml_files)" "YAML" ;;
            3) pick_share ;;
            4) view_aggregate ;;
            5) links_all_view ;;
            6) path_view ;;
            7) merged_yaml_view ;;
            8) single_yaml_view ;;
            9) sb_menu_addr_family ;;
            10) sb_menu_utls_fingerprint ;;
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
        single) single_yaml_view ;;
        path)   path_view ;;
        *)      show_menu ;;
    esac
fi
