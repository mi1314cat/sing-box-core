#!/bin/bash
# ==============================================================
# shadowtls.sh — ShadowTLS v3 + 内层 Shadowsocks-2022 (双 inbound 同文件)
# 与 fscarmen e 节点等价结构；Reality 域名统一走 domains.sh
# CLI: bash shadowtls.sh [add|list|del]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="shadowtls"

add_config() {
    print_title "新增 ShadowTLS v3 节点 ($PROTO-NN.json)"
    local listen_ip listen_port idx file tag
    listen_ip=$(safe_read "监听地址 (0.0.0.0/::)" "0.0.0.0")
    listen_port=$(safe_read_port)
    local rnd; rnd=$(reality_random_domain)     # 统一 domains.sh
    print_info "伪装目标 (handshake): $rnd"
    local st_password ss_password server_ip
    st_password=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
    ss_password=$(openssl rand -base64 16 | tr -d '\n')
    idx=$(get_next_index "$PROTO"); file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"

    local json
    json=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "shadowtls",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "version": 3,
      "detour": "${tag}inner",
      "handshake": { "server": "$rnd", "server_port": 443 },
      "strict_mode": true,
      "users": [ { "name": "user", "password": "$st_password" } ]
    },
    {
      "type": "shadowsocks",
      "tag": "${tag}inner",
      "listen": "127.0.0.1",
      "listen_port": $((listen_port+1)),
      "method": "2022-blake3-aes-128-gcm",
      "password": "$ss_password",
      "multiplex": { "enabled": true, "padding": true }
    }
  ]
}
EOF
)
    backup_config config
    if ! write_config "$file" "$json"; then return 1; fi
    if ! sb_check; then rm -f "$file"; print_error "已删除非法配置（现网未受影响）"; return 1; fi
    cleanup_node_shares "$tag"
    sb_reload || true
    server_ip=$(safe_read "服务器对外 IP" "$(default_server_ip)")
    local link="shadowtls://$st_password@$server_ip:$listen_port?sni=$rnd&version=3#$tag"
    python3 - "$SB_OUT_DIR/sb_client-$tag.json" "$tag" "$server_ip" "$listen_port" "$st_password" "$ss_password" "$rnd" <<'PYGEN'
import json,sys
_,ofile,tag,srv,port,stpw,sspw,sni=sys.argv
# 内层连本机 shadowsocks(127.0.0.1:1080) —— 客户端双 outbound 结构与 fscarmen 一致
json.dump({"outbounds":[
  {"type":"shadowtls","tag":"shadowtls-out","server":srv,"server_port":int(port),
   "version":3,"password":stpw,
   "tls":{"enabled":True,"server_name":sni}},
  {"type":"shadowsocks","tag":tag,"detour":"shadowtls-out",
   "method":"2022-blake3-aes-128-gcm","password":sspw,
   "multiplex":{"enabled":True,"padding":True}}
]},open(ofile,"w"),indent=2)
PYGEN
    echo "$link" | tee "$SB_OUT_DIR/sb_share-$tag.txt" | tail -1 >&2
    grep -vF "$link" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.$$ && mv /tmp/l.$$ "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >> "$SB_OUT_DIR/sb_links-all.txt"
    open_port "$listen_port"
    print_ok "ShadowTLS 节点添加完成: $file"
    print_warn "客户端功能说明: 内层为 2022-blake3-aes-128-gcm(与 sb_client-*.json 一致)"
}

list_configs() {
    print_title "$PROTO 配置"
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        local idx tag port
        idx=$(basename "$f" .json | cut -d'-' -f2); tag="${PROTO}${idx}"
        port=$(jq -r '.inbounds[0].listen_port' "$f")
        printf "%s) 端口:%s 内层SS:%s\n" "$idx" "$port" "$(jq -r '.inbounds[1].listen_port' "$f" )" >&2
    done
}

delete_config() {
    list_configs
    read -r -p "输入要删除的编号: " num; num=$(clean_input "$num")
    [[ "$num" =~ ^[0-9]+$ ]] || { print_error "编号必须数字"; return 1; }
    read -r -p "确认删除编号 $num ($PROTO) 的节点? [y/N]: " dconfirm
    [[ "$(clean_input "$dconfirm")" =~ ^[yY] ]] || { print_warn "已取消"; return 0; }
    local idx file tag
    idx=$(printf "%02d" "$num"); file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"
    [[ -f "$file" ]] || { print_error "编号不存在"; return 1; }
    rm -f "$file" "$SB_OUT_DIR/sb_share-$tag.txt" "$SB_OUT_DIR/sb_client-$tag.json" "$SB_OUT_DIR/sb_meta-$tag.json"
    sb_check && sb_reload || true
    print_ok "已删除 $tag"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        add) add_config ;; list) list_configs ;; del) delete_config ;; check) sb_check ;;
        *) while true; do
            print_title "ShadowTLS 节点管理"
            echo -e "${CYAN}1)${RESET} 添加\n${CYAN}2)${RESET} 列出\n${CYAN}3)${RESET} 删除\n${CYAN}0)${RESET} 返回"
            read -r -p "请选择: " c
            case "$(clean_input "$c")" in 1) add_config ;; 2) list_configs ;; 3) delete_config ;; 0) break ;; esac
            read -r -p "按回车继续..." _ || { echo; exit 0; }
        done ;;
    esac
fi
