#!/bin/bash
# ==============================================================
# portforward.sh — 端口转发模块（sing-box 原生 direct inbound）
# 每条转发 = config/portforward-NN.json（inbound direct + override_address/override_port）
# + 03-route.json 中按 inbound tag 路由到 direct outbound
# 不支持端口范围（官方 issue #204 明确拒绝）→ 提示逐条添加
# CLI: bash portforward.sh [add|list|del]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="portforward"
ROUTE_FILE="$SB_CONFIG_DIR/03-route.json"

ensure_route_file() {
    [[ -f "$ROUTE_FILE" ]] || write_config "$ROUTE_FILE" '{"route":{"rules":[]}}'
}

ensure_route_rule() { # 确保 inbound tag → direct
    local tag="$1"
    jq -e --arg t "$tag" 'any(.route.rules[]?; ((.inbound? // ["-x-"]) | tostring) == ([$t] | tostring))' "$ROUTE_FILE" >/dev/null && return 0
    if ! write_config "$ROUTE_FILE" "$(jq --arg t "$tag" '.route.rules += [{"inbound": [$t], "outbound": "direct"}]' "$ROUTE_FILE")"; then
        print_error "添加路由规则失败"
        return 1
    fi
    print_ok "路由规则已加入: inbound $tag → direct"
}

add_config() {
    print_title "新增端口转发 ($PROTO-NN.json)"
    local listen_ip listen_port idx file tag
    listen_ip=$(safe_read "监听地址 (0.0.0.0/::)" "0.0.0.0")
    listen_port=$(safe_read_port)
    local dst_addr dst_port net
    dst_addr=$(safe_read "目标地址 (IP/域名)" "127.0.0.1")
    dst_port=$(safe_read_port)
    echo "网络: 1)TCP 2)UDP 3)TCP+UDP（拆两份, tcp/tcpUDP 合并为一条 tcp udp）"
    read -r -p "选择 (默认 TCP): " n; n=$(clean_input "$n")
    case "$n" in
        2) net=udp ;;
        3) net="" ;;  # 空值两端都监听
        *) net=tcp ;;
    esac

    idx=$(get_next_index "$PROTO")
    file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="$PROTO$idx"

    local base json
    base='{
  "inbounds": [ {
      "type": "direct",
      "tag": "'$tag'",
      "listen": "'$listen_ip'",
      "listen_port": '$listen_port',
      "network": "'$net'",
      "override_address": "'$dst_addr'",
      "override_port": '$dst_port'
  } ]
}'
    if [[ "$n" == "3" ]]; then
        # tcp+udp: 双 inbound（sing-box direct inbound network 留空也可，但多场景双端口更稳）
        base='{
  "inbounds": [
    { "type": "direct", "tag": "'$tag'tcp", "listen": "'$listen_ip'", "listen_port": '$listen_port',
      "network": "tcp", "override_address": "'$dst_addr'", "override_port": '$dst_port' },
    { "type": "direct", "tag": "'$tag'udp", "listen": "'$listen_ip'", "listen_port": '$listen_port',
      "network": "udp", "override_address": "'$dst_addr'", "override_port": '$dst_port' }
  ]
}'
        tag="$tag""tcp"
    fi
    json="$base"

    [[ -f "$ROUTE_FILE" ]] || write_config "$ROUTE_FILE" '{"route":{"rules":[]}}'
    backup_config config
    if ! write_config "$file" "$json"; then return 1; fi
    ensure_route_file || { rm -f "$file"; return 1; }
    ensure_route_rule "$tag" || { rm -f "$file"; return 1; }
    if ! sb_check; then
        rm -f "$file"
        print_error "已删除非法配置（现网未受影响）"
        return 1
    fi
    sb_reload || true
    open_port "$listen_port"
    print_ok "端口转发已添加: $file"
    print_info "本地 $listen_ip:$listen_port ($net) → $dst_addr:$dst_port"
}

list_configs() {
    print_title "$PROTO 配置"
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        local num port daddr dport net tag lis
        lis=$(jq -r ".inbounds[0].listen" "$f" 2>/dev/null)
        num=$(basename "$f" .json | cut -d'-' -f2)
        port=$(jq -r '.inbounds[0].listen_port' "$f" 2>/dev/null)
        daddr=$(jq -r '.inbounds[0].override_address' "$f" 2>/dev/null)
        dport=$(jq -r '.inbounds[0].override_port' "$f" 2>/dev/null)
        net=$(jq -r '.inbounds[0].network' "$f" 2>/dev/null)
        printf "%s) 监听 %s:%s (%s) → 目标 %s:%s\n" "$num" "$lis" "$port" "$net" "$daddr" "$dport"
    done

}

delete_config() {
    list_configs
    read -r -p "输入要删除的编号: " num
    num=$(clean_input "$num"); [[ "$num" =~ ^[0-9]+$ ]] || { print_error "编号必须数字"; return 1; }
    read -r -p "确认删除编号 $num ($PROTO) 的节点? [y/N]: " dconfirm
    [[ "$(clean_input "$dconfirm")" =~ ^[yY] ]] || { print_warn "已取消"; return 0; }
    local idx file tag
    idx=$(printf "%02d" "$num")
    file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="$PROTO$idx"
    [[ -f "$file" ]] || { print_error "编号不存在"; return 1; }

    rm -f "$file"
    # 清理对应 route 规则 (tag 或 tagtcp)
    if [[ -f "$ROUTE_FILE" ]]; then
        write_config "$ROUTE_FILE" "$(jq --arg t "$tag" --arg t2 "${tag}tcp" '.route.rules |= map(select((.inbound? // ["-x-"] | tostring) != ([$t] | tostring) and ((.inbound? // ["-y-"] | tostring) != ([$t2] | tostring))))' "$ROUTE_FILE")" || true
    fi
    sb_check && sb_reload || true
    print_ok "已删除 $tag"
}


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        add) add_config ;;
        list) list_configs ;;
        del)  delete_config ;;
        check) sb_check ;;
        *)
            while true; do
                print_title "端口转发管理"
                echo -e "${CYAN}1)${RESET} 添加转发"
                echo -e "${CYAN}2)${RESET} 列出转发"
                echo -e "${CYAN}3)${RESET} 删除转发"
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
