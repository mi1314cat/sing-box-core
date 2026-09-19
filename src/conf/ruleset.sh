#!/bin/bash
# ==============================================================
# ruleset.sh — 规则集管理模块
# 管理 config/02-rule-set.json（rule_set 定义）与 03-route.json（路由规则）
# 预设源: SagerNet/sing-geosite rule-set 分支（官方 .srs），可手填 MetaCubeX 镜像
# CLI: bash ruleset.sh [list|add|del|route|check]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

RS_FILE="$SB_CONFIG_DIR/02-rule-set.json"
ROUTE_FILE="$SB_CONFIG_DIR/03-route.json"

preset_url() {
    case "$1" in
        ads)      echo "geosite-category-ads-all" ;;
        cn)       echo "geosite-cn" ;;
        telegram) echo "geosite-telegram" ;;
        twitter)  echo "geosite-twitter" ;;
        netflix)  echo "geosite-netflix" ;;
        disney)   echo "geosite-disney" ;;
        openai)   echo "geosite-openai" ;;
        google)   echo "geosite-google" ;;
        *)        echo "" ;;
    esac
}

preset_full_url() {
    local name; name=$(preset_url "$1")
    [[ -z "$name" ]] && return 1
    echo "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/${name}.srs"
}

ensure_files() {
    [[ -f "$RS_FILE" ]] || write_config "$RS_FILE" '{"route":{"rule_set":[]}}'
}

# 通用编辑: rs_edit <file> <filter-file>
apply_edit() {
    local file="$1" filter="$2"
    local old; old=$(jq . "$file")
    if ! write_config "$file" "$(jq "$filter" "$file")"; then print_error "jq 过滤器错误"; return 1; fi
    if ! sb_check; then
        echo "$old" | jq . > "$file"
        print_error "已回滚（check 未通过）"
        return 1
    fi
    sb_reload; return 0
}

# ---------- add ----------
add_ruleset() {
    ensure_files
    echo -e "预设: ${CYAN}ads cn telegram twitter netflix disney openai google${RESET} 或 ${CYAN}custom${RESET}(手填URL)"
    read -r -p "选择: " p; p=$(clean_input "$p")
    local tag url interval update
    if [[ "$p" == "custom" ]]; then
        read -r -p "tag (如 geosite-xxx): " tag; tag=$(clean_input "$tag")
        read -r -p "URL (.srs 或 .json): " url; url=$(clean_input "$url")
    else
        tag=$(preset_url "$p")
        url=$(preset_full_url "$p") || { print_error "未知预设: $p"; return 1; }
        jq -e --arg t "$tag" 'any(.route.rule_set[]?; .tag==$t)' "$RS_FILE" >/dev/null && { print_warn "已存在: $tag"; return 0; }
    fi
    [[ -z "$tag" && -z "$url" ]] && { print_error "缺少参数"; return 1; }
    case "$url" in
        *.srs)   fmt=binary ;;
        *.json)  fmt=source  ;;
        *)       fmt=binary ;; # remote 默认
    esac
    read -r -p "update_interval (默认 1d): " interval; interval=$(clean_input "$interval"); interval=${interval:-1d}

    local json entry
    entry=$(cat <<EOF
{ "type": "remote", "tag": "$tag", "format": "$fmt", "url": "$url",
  "http_client": "http-direct", "update_interval": "$interval" }
EOF
)
    if ! write_config "$RS_FILE" "$(jq --argjson e "$entry" '.route.rule_set += [$e]' "$RS_FILE")"; then return 1; fi
    if ! sb_check; then
        # 回滚
        write_config "$RS_FILE" "$(jq --arg t "$tag" '.route.rule_set |= map(select(.tag != $t))' "$RS_FILE")" || true
        print_error "添加失败已回滚（运行 check 可能看到 URL 不可达等）"
        return 1
    fi
    sb_reload && print_ok "规则集已添加: $tag"
    return 0
}

# ---------- del ----------
del_ruleset() {
    [[ -f "$RS_FILE" ]] || { print_warn "无规则集文件"; return 1; }
    print_title "已定义 rule-set"
    jq -r '.route.rule_set[]? | "\(.tag)\t\(.type)\t\(.url // .path)"' "$RS_FILE" >&2
    read -r -p "删除哪个 tag: " t; t=$(clean_input "$t")
    apply_edit "$RS_FILE" --arg t "$t" '.route.rule_set |= map(select(.tag != $t))' \
        && print_ok "已删除规则集 $t"
}

# ---------- route 规则 ----------
init_route() {
    if [[ ! -f "$ROUTE_FILE" ]]; then
        write_config "$ROUTE_FILE" '{
  "route": {
    "rules": [
      { "rule_set": ["'"$(preset_url ads)"'"], "action": "reject" },
      { "rule_set": ["'"$(preset_url cn)"'"], "action": "sniff" }
    ]
  }
}' || return 1
        print_ok "03-route.json 骨架已生成"
    fi
}

route_menu() {
    print_title "路由规则 (03-route.json)"
    [[ -f "$ROUTE_FILE" ]] && cat "$ROUTE_FILE" >&2 || print_warn "无 03-route.json（可 init）"
    echo -e "${CYAN}1)${RESET} 初始化骨架"
    echo -e "${CYAN}2)${RESET} 添加规则 (rule_set 出站 direct)"
    echo -e "${CYAN}3)${RESET} 添加 reject 规则"
    echo -e "${CYAN}4)${RESET} 删除规则 (按 rule_set tag)"
    echo -e "${CYAN}0)${RESET} 返回"
    read -r -p "选择: " c; c=$(clean_input "$c")
    case "$c" in
        1) init_route ;;
        2)
            read -r -p "rule_set tag: " tag
            apply_edit "$ROUTE_FILE" --arg t "$tag" '.route.rules += [{ "rule_set": [$t], "outbound": "direct" }]' \
                && print_ok "规则已添加"
            ;;
        3)
            read -r -p "rule_set tag: " tag
            apply_edit "$ROUTE_FILE" --arg t "$tag" '.route.rules += [{ "rule_set": [$t], "action": "reject" }]' \
                && print_ok "规则已添加"
            ;;
        4)
            read -r -p "rule_set tag: " tag
            apply_edit "$ROUTE_FILE" --arg t "$tag" '.route.rules |= map(select((.rule_set? // ["-x-"] | tostring) != ([$t] | tostring)))' \
                && print_ok "规则已删除"
            ;;
    esac
}

# ---------- list ----------
list_ruleset() {
    print_title "rule-set 定义 (02-rule-set.json)"
    [[ -f "$RS_FILE" ]] || { print_warn "无"; return 1; }
    jq -r '.route.rule_set[]? | "\(.tag)\t\(.type)\t\(.format)\t\(.update_interval)\t\(.url // .path)"' "$RS_FILE" >&2
}

# ---------- 菜单 ----------
menu() {
    while true; do
        print_title "规则集管理"
        list_ruleset
        echo -e "${CYAN}1)${RESET} 添加规则集 (预设/custom)"
        echo -e "${CYAN}2)${RESET} 删除规则集"
        echo -e "${CYAN}3)${RESET} 路由规则 (route.rules)"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请选择: " c
        case "$(clean_input "$c")" in
            1) add_ruleset ;;
            2) del_ruleset ;;
            3) route_menu ;;
            0) break ;;
            *) print_error "无效选项" ;;
        esac
        read -r -p "按回车继续..." _
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        list)  list_ruleset ;; add) add_ruleset ;; del) del_ruleset ;; route) route_menu ;; check) sb_check ;;
        *)     menu ;;
    esac
fi
