#!/bin/bash
# ==============================================================
# shadowsocks.sh — Shadowsocks-2022 节点模块
# 方法: 2022-blake3-aes-128-gcm（默认）/ 2022-blake3-aes-256-gcm（手动key）
# CLI: bash shadowsocks.sh [add|list|del]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="shadowsocks"
add_config() {
    print_title "新增 Shadowsocks-2022 节点 ($PROTO-NN.json)"
    local listen_ip listen_port idx file tag json method key
    listen_ip=$(safe_read "监听地址 (0.0.0.0/::)" "0.0.0.0")
    listen_port=$(safe_read_port)
    read -r -p "方法 [1=2022-blake3-aes-128-gcm (默认), 2=2022-blake3-aes-256-gcm]: " mc
    mc=$(clean_input "$mc")
    if [[ "$mc" == "2" ]]; then
        method="2022-blake3-aes-256-gcm"
        key=$(safe_read "PSK (base64, 32字节 => 43字符)" "$(openssl rand -base64 32 | tr -d '\n')")
    else
        method="2022-blake3-aes-128-gcm"
        key=$(safe_read "PSK (base64, 16字节 => 22字符)" "$(openssl rand -base64 16 | tr -d '\n')")
    fi

    idx=$(get_next_index "$PROTO"); file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"
    json=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "method": "$method",
      "password": "$key"
    }
  ]
}
EOF
)
    backup_config config
    write_config "$file" "$json" || return 1
    if ! sb_check; then rm -f "$file"; print_error "已删除非法配置文件（现网未受影响）"; return 1; fi
    cleanup_node_shares "$tag"
    sb_reload || print_warn "请确认服务状态"

    local server_ip; server_ip=$(default_server_ip)
    local link="ss://$(printf '%s' "$method:$key" | base64 -w0)@$server_ip:$listen_port#$tag"
    cat > "$SB_OUT_DIR/sb_client-$tag.json" <<EOF
{
  "outbounds": [
    { "type": "shadowsocks", "tag": "$tag", "server": "$server_ip", "server_port": $listen_port,
      "method": "$method", "password": "$key", "udp_over_tcp": true }
  ]
}
EOF
    cat > "$SB_OUT_DIR/sb_client-$tag.yaml" <<EOF
proxies:
  - name: $tag
    type: ss
    server: $server_ip
    port: $listen_port
    cipher: $method
    password: "$key"
EOF
    echo "$link" | tee "$SB_OUT_DIR/sb_share-$tag.txt" | tail -1 >&2
    grep -vF "$link" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.$$ && mv /tmp/l.$$ "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >> "$SB_OUT_DIR/sb_links-all.txt"
    open_port "$listen_port"
    print_ok "Shadowsocks 节点添加完成: $file"
}

list_configs() {
    print_title "$PROTO 配置列表"
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        local idx tag port method
        idx=$(basename "$f" .json | cut -d'-' -f2); tag="${PROTO}${idx}"
        port=$(jq -r '.inbounds[0].listen_port' "$f")
        method=$(jq -r '.inbounds[0].method' "$f")
        printf "%s) 端口:%s  方法:%s\n" "$idx" "$port" "$method" >&2
    done
}

delete_config() {
    list_configs
    read -r -p "输入要删除的编号: " num
    num=$(clean_input "$num"); [[ "$num" =~ ^[0-9]+$ ]] || { print_error "编号必须数字"; return 1; }
    read -r -p "确认删除编号 $num ($PROTO) 的节点? [y/N]: " dconfirm
    [[ "$(clean_input "$dconfirm")" =~ ^[yY] ]] || { print_warn "已取消"; return 0; }
    local idx file tag
    idx=$(printf "%02d" "$num"); file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"
    [[ -f "$file" ]] || { print_error "编号不存在"; return 1; }
    rm -f "$file" "$SB_OUT_DIR/sb_share-$tag.txt" "$SB_OUT_DIR/sb_client-$tag.json" "$SB_OUT_DIR/sb_client-$tag.yaml"
    sb_check && sb_reload || print_warn "请手动确认服务状态"
    print_ok "已删除 $tag"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        add) add_config ;; list) list_configs ;; del) delete_config ;; check) sb_check ;;
        *)
            while true; do
                print_title "Shadowsocks 节点管理"
                echo -e "${CYAN}1)${RESET} 添加节点"; echo -e "${CYAN}2)${RESET} 列出节点"; echo -e "${CYAN}3)${RESET} 删除节点"; echo -e "${CYAN}0)${RESET} 返回"
                read -r -p "请选择: " c
                case "$c" in 1) add_config ;; 2) list_configs ;; 3) delete_config ;; 0) break ;; esac
                read -r -p "按回车继续..." _ || { echo; exit 0; }
            done ;;
    esac
fi
