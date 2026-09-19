#!/bin/bash
# ==============================================================
# anyreality.sh — AnyReality (AnyTLS + REALITY) 节点模块
# sing-box 1.12.0+ anytls inbound + tls.reality
# 注意：mihomo/Clash 不支持 anytls+reality（无 reality-opts 字段），
#       客户端产物输出 sing-box outbound 片段 + anytls:// 分享链接
# REALITY 密钥与 reality.sh 共享（out/reality-keys.json）
# CLI: bash anyreality.sh [add|list|del]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="anyreality"
REALITY_KEYS_FILE="$SB_OUT_DIR/reality-keys.json"

ensure_reality_keys() {
    if [[ -f "$REALITY_KEYS_FILE" ]]; then
        REAL_PRIV=$(jq -r '.private_key // empty' "$REALITY_KEYS_FILE")
        REAL_PUB=$(jq -r '.public_key // empty' "$REALITY_KEYS_FILE")
        [[ -n "$REAL_PRIV" && -n "$REAL_PUB" ]] && { print_ok "复用已有 REALITY 密钥"; return 0; }
    fi
    local kp
    kp=$("$SB_BIN" generate reality-keypair 2>/dev/null)
    REAL_PRIV=$(echo "$kp" | grep -oP '^PrivateKey: \K.*')
    REAL_PUB=$(echo "$kp" | grep -oP '^PublicKey: \K.*')
    echo "{\"private_key\":\"$REAL_PRIV\",\"public_key\":\"$REAL_PUB\"}" | jq . > "$REALITY_KEYS_FILE"
    print_ok "REALITY 密钥已生成: $REALITY_KEYS_FILE"
}

pick_dest() {
    local rnd; rnd=$(reality_random_domain)   # 统一来源: One-click-script domains.sh
    echo >&2
    echo "Reality 握手目标 (统一 domains.sh): $rnd" >&2
    read -r -p "手动输入自定义目标? [y/N, 默认随机]: " c
    if [[ "$(clean_input "$c")" =~ ^[yY] ]]; then
        local d p
        d=$(safe_read "目标域名" "$rnd"); p=$(safe_read "目标端口" "443"); echo "$d|$p"
    else
        echo "$rnd|443"
    fi
}

add_config() {
    print_title "新增 AnyReality 节点 ($PROTO-NN.json)"
    ensure_reality_keys
    local server_ip listen_ip listen_port idx
    server_ip=$(safe_read "服务器对外 IP" "$(default_server_ip)")
    listen_ip=$(safe_read "监听地址 (0.0.0.0/::)" "0.0.0.0")
    listen_port=$(safe_read_port)
    local pick d p dest port destport
    pick=$(pick_dest); d="${pick%%|*}"; p="${pick##*|}"
    local sid password
    sid=$(openssl rand -hex 8)
    password=$(openssl rand -base64 18 | tr -d '/+=\n' | head -c 24)

    local idx file tag json
    idx=$(get_next_index "$PROTO")
    file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"

    json=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "anytls",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "users": [ { "name": "user", "password": "$password" } ],
      "tls": {
        "enabled": true,
        "server_name": "$d",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$d", "server_port": $p },
          "private_key": "$REAL_PRIV",
          "short_id": [ "$sid" ]
        }
      }
    }
  ]
}
EOF
)

    backup_config config
    write_config "$file" "$json" || return 1
    if ! sb_check; then
        rm -f "$file"
        print_error "已删除非法配置文件（现网未受影响）"
        return 1
    fi
    sb_reload || print_warn "请确认服务状态"

    # anytls:// 分享链接（eooce 风格）
    local link="anytls://$password@$server_ip:$listen_port?insecure=0&sni=$d&pbk=$REAL_PUB&sid=$sid#$tag"
    cat > "$SB_OUT_DIR/sb_client-$tag.json" <<EOF
{
  "outbounds": [
    {
      "type": "anytls",
      "tag": "$tag",
      "server": "$server_ip",
      "server_port": $listen_port,
      "password": "$password",
      "tls": {
        "enabled": true,
        "server_name": "$d",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": { "enabled": true, "public_key": "$REAL_PUB", "short_id": "$sid" }
      }
    }
  ]
}
EOF
    echo "{\"tag\":\"$tag\",\"port\":$listen_port,\"password\":\"$password\",\"pbk\":\"$REAL_PUB\",\"sid\":\"$sid\"}" | jq . > "$SB_OUT_DIR/sb_meta-$tag.json"
    echo "$link" > "$SB_OUT_DIR/sb_share-$tag.txt"
    grep -vF "$link" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.$$ && mv /tmp/l.$$ "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >> "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >&2
    print_warn "提示: mihomo/Clash 不支持 anytls+reality，请使用 sing-box 客户端 (CC 侧 sb_client-$tag.json)"
    open_port "$listen_port"
    print_ok "AnyReality 节点添加完成: $file"
}

list_configs() {
    print_title "$PROTO 配置列表"
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        local idx tag port
        idx=$(basename "$f" .json | cut -d'-' -f2); tag="${PROTO}${idx}"
        port=$(jq -r '.inbounds[0].listen_port' "$f")
        printf "%s) 端口:%s\n" "$idx" "$port" >&2
    done
}

delete_config() {
    list_configs
    read -r -p "输入要删除的编号: " num
    num=$(clean_input "$num")
    [[ "$num" =~ ^[0-9]+$ ]] || { print_error "编号必须数字"; return 1; }
    local idx file tag
    idx=$(printf "%02d" "$num")
    file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"
    [[ -f "$file" ]] || { print_error "编号不存在"; return 1; }
    rm -f "$file" "$SB_OUT_DIR/sb_share-$tag.txt" "$SB_OUT_DIR/sb_client-$tag.json" "$SB_OUT_DIR/sb_meta-$tag.json"
    sb_check && sb_reload || print_warn "请手动确认服务状态"
    print_ok "已删除 $tag"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        add)   add_config ;;
        list)  list_configs ;;
        del)   delete_config ;;
        check) sb_check ;;
        *)
            while true; do
                print_title "AnyReality 节点管理"
                echo -e "${CYAN}1)${RESET} 添加节点"
                echo -e "${CYAN}2)${RESET} 列出节点"
                echo -e "${CYAN}3)${RESET} 删除节点"
                echo -e "${CYAN}0)${RESET} 返回"
                read -r -p "请选择: " c
                case "$c" in
                    1) add_config ;;
                    2) list_configs ;;
                    3) delete_config ;;
                    0) break ;;
                    *) ;;
                esac
                read -r -p "按回车继续..." _
            done
            ;;
    esac
fi
