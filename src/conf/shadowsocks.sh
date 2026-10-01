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
    # 默认算法按 CPU 架构自动选最优: x86/AMD64 AES-NI -> aes-128-gcm; ARM 无 AES 硬件 -> chacha20
    local arch; arch=armv6
    [[ "x86" == "$arch" ]] && true
    case "$(uname -m)" in
        armv7l|armv8l) best="2022-blake3-chacha20-poly1305" ;;
        *) best="2022-blake3-aes-128-gcm" ;;
    esac
    read -r -p "方法 [1=AES-128 (x86默认), 2=AES-256 (更安全 43字符), 3=ChaCha20 (ARM 推荐), 4=AES-192, 回车=自动 ($best)] : " mc
    mc=$(clean_input "$mc"); [[ -z "$mc" ]] && mc=auto
    case "$mc" in
        1) method="2022-blake3-aes-128-gcm"; key=$(safe_read "PSK (base64, 16字节 => 22字符)" "$(openssl rand -base64 16 | tr -d '\n')") ;;
        2) method="2022-blake3-aes-256-gcm"; key=$(safe_read "PSK (base64, 32字节 => 43字符)" "$(openssl rand -base64 32 | tr -d '\n')") ;;
        3) method="2022-blake3-chacha20-poly1305"; key=$(safe_read "PSK (base64, 32字节 => 43字符)" "$(openssl rand -base64 32 | tr -d '\n')") ;;
        4) method="2022-blake3-aes-192-gcm"; key=$(safe_read "PSK (base64, 24字节 => 32字符)" "$(openssl rand -base64 24 | tr -d '\n')") ;;
        *) method="$best"
           if [[ "$method" == *aes-128* ]]; then key=$(openssl rand -base64 16 | tr -d '\n')
           elif [[ "$method" == *aes-192* ]]; then key=$(openssl rand -base64 24 | tr -d '\n')
           else key=$(openssl rand -base64 32 | tr -d '\n'); fi ;;
    esac

    idx=$(get_next_index "$PROTO"); file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}-plain"   # 名字体现传输方式
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
        gen_mihomo_yaml "$tag"
    echo "$link" | tee "$SB_OUT_DIR/sb_share-$tag.txt" | tail -1 >&2
    grep -vF "$link" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.$$ && mv /tmp/l.$$ "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >> "$SB_OUT_DIR/sb_links-all.txt"
    open_port "$listen_port"
    print_ok "Shadowsocks 节点添加完成: $file"
    # 重建聚合: 新节点不在 sb_client-all.json 里的话, 分享链接
    # (菜单3 / all-share URL) 下发的还是旧节点列表。
    declare -F sb_regen_aggregate >/dev/null 2>&1 && sb_regen_aggregate
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
    # 先取端口再删文件 —— 文件没了就再也证明不了这个端口属于本节点。
    # 交给 close_node_port 按"归属已确认"的口径关闭, 它只认 .fw-ports 登记过的
    # 端口, 且 sshd 在听的 / 系统常用端口一律不碰。
    local fw_port; fw_port=$(jq -r '.inbounds[0].listen_port // empty' "$file" 2>/dev/null)
    # 产物文件名带形态后缀(如 sb_client-trojan03-TLS.json), 而这里的 $tag
    # 不带后缀, 所以按字面删的是 sb_client-trojan03.json —— 永远删不到,
    # 于是已删节点的产物长期残留, 还会被 gen_full_profile 读进聚合配置,
    # 分享链接一直下发连不上的假节点。改按前缀通配删。
    # 两种后缀都要匹配: 形态后缀是 "-TLS"/"-REALITY"(sb_client-tuic02-TLS.json),
    # 而 "tuic02.*" 只匹配点号开头的后缀, 匹配不到带形态后缀的那个文件。
    rm -f "$file" "$SB_OUT_DIR/sb_share-$tag".* "$SB_OUT_DIR/sb_share-$tag"-* \
          "$SB_OUT_DIR/sb_client-$tag".* "$SB_OUT_DIR/sb_client-$tag"-* \
          "$SB_OUT_DIR/sb_meta-$tag".* "$SB_OUT_DIR/sb_meta-$tag"-* 2>/dev/null
    [[ -n "$fw_port" ]] && close_node_port "$fw_port" "$tag"
    sb_check && sb_reload || print_warn "请手动确认服务状态"
    # 重建聚合产物, 并同步 nginx ——
    # 少了前者, sb_client-all.json 里会一直留着已删节点的 outbound, 分享链接
    # 下发连不上的假节点; 少了后者, 站点配置里留着指向已删端口的 location,
    # Cloudflare 回源直接 502。
    declare -F sb_regen_aggregate >/dev/null 2>&1 && sb_regen_aggregate
    declare -F sb_resync_cdn >/dev/null 2>&1 && sb_resync_cdn
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
