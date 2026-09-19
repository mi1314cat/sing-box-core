#!/bin/bash
# ==============================================================
# outbound.sh — 出站（outbound）管理模块
# 每条出站 = config/outbound-NN.json（direct/socks/http/渗透 chain）
# reference: xary-core conf/outbound.sh 的 out-*.json 模式（简化版）
# CLI: bash outbound.sh [add|list|del]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="outbound"

add_config() {
    print_title "新增出站 ($PROTO-NN.json)"
    echo "类型: 1) direct(自由) 2) socks 3) http"
    read -r -p "选择 (默认 1): " t
    t=$(clean_input "$t")
    case "$t" in
        2) otype=socks ;;
        3) otype=http ;;
        *) otype=direct ;;
    esac
    read -r -p "$(echo -e $CYAN)_meta.name 标识 (默认 auto): $RESET" name
    name=$(clean_input "$name"); name=${name:-custom}
    idx=$(get_next_index "$PROTO")
    local file tag
    file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="$PROTO$idx"
    local json
    json=$(cat <<EOF
{
  "outbounds": [ {
      "type": "$otype",
      "tag": "$tag"
  } ]
}
EOF
)

    case "$otype" in
        socks|http)
            local addr port
            addr=$(safe_read "服务器地址" "127.0.0.1")
            port=$(safe_read_port)
            local extra="\"server\": \"$addr\", \"server_port\": $port"
            # socks 附加 auth optional
            ;;
        *) extra="" ;;
    esac
    if [[ -n "$extra" ]]; then
        json=$(cat <<EOF
{
  "outbounds": [ {
      "type": "$otype", "tag": "$tag", $extra
  } ]
}
EOF
)
    fi

    backup_config config
    write_config "$file" "$json" || return 1
    if ! sb_check; then rm -f "$file"; print_error "已删除非法配置（现网未受影响）"; return 1; fi
    sb_reload || true
    print_ok "出站已添加: $file"
}

list_configs() {
    print_title "$PROTO 配置"
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        local num tag otype
        num=$(basename "$f" .json | cut -d'-' -f2)
        jq -r '.outbounds[] | "\(.tag)\t\(.type)\t\(.server // "-"):\(.server_port // "-")"' "$f" 2>/dev/null | while IFS=$'\t' read -r tg ot sv; do
            printf "%s) %s %s %s\n" "$num" "$tg" "$ot" "$sv"
        done
    done
}

delete_config() {
    list_configs
    read -r -p "输入要删除的编号: " num
    num=$(clean_input "$num"); [[ "$num" =~ ^[0-9]+$ ]] || { print_error "编号必须数字"; return 1; }
    local idx file tag
    idx=$(printf "%02d" "$num")
    file="$SB_CONFIG_DIR/$PROTO-$idx.json"
    tag="$(jq -r '.outbounds[0].tag' "$file")"
    [[ -f "$file" ]] || { print_error "编号不存在"; return 1; }
    rm -f "$file"
    # 清理 03-route.json 中引用该 out 的规则
    local rf="$SB_CONFIG_DIR/03-route.json"
    if [[ -f "$rf" ]]; then
        write_config "$rf" "$(jq --arg t "$tag" '.route.rules |= map(select((.outbound? // "-x-") != $t))' "$rf")" || true
    fi
    sb_check && sb_reload || true
    print_ok "已删除出站 $tag 及其路由规则"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        add)  add_config ;;
        list) list_configs ;;
        del)  delete_config ;;
        check) sb_check ;;
        *)
            while true; do
                print_title "出站管理"
                echo -e "${CYAN}1)${RESET} 添加出站"
                echo -e "${CYAN}2)${RESET} 列出出站"
                echo -e "${CYAN}3)${RESET} 删除出站"
                echo -e "${CYAN}0)${RESET} 返回"
                read -r -p "请选择: " c
                case "$(clean_input "$c")" in
                    1) add_config ;;
                    2) list_configs ;;
                    3) delete_config ;;
                    0) break ;;
                    *) ;;
                esac
                read -r -p "按回车继续..." _ || { echo; exit 0; }
            done ;;
    esac
fi
