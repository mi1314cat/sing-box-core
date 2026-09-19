#!/bin/bash
# ==============================================================
# tuic.sh — TUIC v5 节点模块 (quic, 需证书)
# 真证书/自签均可；uuid + password 混合认证
# CLI: bash tuic.sh [add|list|del]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="tuic"
CERT_DIR="$SB_ROOT/cert"
random_domain() { reality_random_domain; }

extract_cert_domain() {
    local crt="$1" dom=""
    command -v openssl >/dev/null && [[ -f "$crt" ]] && dom=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -oE "DNS:[^,]+" | head -1 | cut -d: -f2)
    [[ -z "$dom" ]] && dom=$(basename "$crt" | sed -E 's/\.(crt|pem)$//; s/_cert$//; s/^cert-//')
    echo "$dom"
}

ask_cert() {
    local c f k
    echo "TLS 证书：" >&2
    echo "  1) 手动输入 crt/key 路径" >&2
    echo "  2) 生成自签证书 (回车=2)" >&2
    c="" ; read -r -p "  选择 (默认 2=自签): " c
    c=$(clean_input "$c"); [[ -z "$c" ]] && c=2
    if [[ "$c" == "2" ]]; then
        local dom
        dom=$(safe_read "自签域名" "$(random_domain)")
        CERT_FILE="$CERT_DIR/cert-$dom.crt"; KEY_FILE="$CERT_DIR/key-$dom.key"
        mkdir -p "$CERT_DIR"
        if [[ ! -f "$CERT_FILE" ]]; then
            openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
                -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 \
                -subj "/CN=$dom" -addext "subjectAltName=DNS:$dom" >/dev/null 2>&1
        fi
        CERT_DOMAIN="$dom"; CERT_TRUSTED=false; return 0
    fi
    read -r -p "  crt 路径: " f; read -r -p "  key 路径: " k
    f=$(clean_input "$f"); k=$(clean_input "$k")
    [[ -f "$f" && -f "$k" ]] || { print_error "路径无效"; return 1; }
    CERT_FILE="$f"; KEY_FILE="$k"; CERT_DOMAIN=$(extract_cert_domain "$f"); CERT_TRUSTED=true
}

add_config() {
    print_title "新增 TUIC v5 节点 ($PROTO-NN.json)"
    local listen_ip listen_port uuid password idx file tag json
    listen_ip=$(safe_read "监听地址 (0.0.0.0/::)" "0.0.0.0")
    listen_port=$(safe_read_port "8443")
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
    password=$(openssl rand -hex 16)
    ask_cert || return 1
    local congestion; congestion=$(safe_read "拥塞控制 (bbr/cubic/new-reno)" "bbr")

    idx=$(get_next_index "$PROTO"); file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"
    json=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "tuic",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "users": [ { "uuid": "$uuid", "password": "$password" } ],
      "congestion_control": "$congestion",
      "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$CERT_FILE", "key_path": "$KEY_FILE" }
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
    local link="tuic://$uuid:$password@$server_ip:$listen_port?sni=$CERT_DOMAIN&congestion_control=$congestion&alpn=h3$( [[ "$CERT_TRUSTED" == "false" ]] && echo "&allow_insecure=1" )#$tag"
    cat > "$SB_OUT_DIR/sb_client-$tag.json" <<EOF
{
  "outbounds": [
    { "type": "tuic", "tag": "$tag", "server": "$server_ip", "server_port": $listen_port,
      "uuid": "$uuid", "password": "$password", "congestion_control": "$congestion",
      "tls": { "enabled": true, "server_name": "$CERT_DOMAIN", "alpn": ["h3"], "insecure": $( [[ "$CERT_TRUSTED" == "true" ]] && echo false || echo true ) } }
  ]
}
EOF
    cat > "$SB_OUT_DIR/sb_client-$tag.yaml" <<EOF
proxies:
  - name: $tag
    type: tuic
    server: $server_ip
    port: $listen_port
    uuid: $uuid
    password: $password
    congestion-controller: $congestion
    sni: $CERT_DOMAIN
    alpn: [h3]
EOF
    [[ "$CERT_TRUSTED" == "false" ]] && echo "# 自签: mihomo 侧需 skip-cert-verify: true" >> "$SB_OUT_DIR/sb_client-$tag.yaml"
    echo "$link" | tee "$SB_OUT_DIR/sb_share-$tag.txt" | tail -1 >&2
    grep -vF "$link" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.$$ && mv /tmp/l.$$ "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >> "$SB_OUT_DIR/sb_links-all.txt"
    open_port "$listen_port"
    print_ok "TUIC 节点添加完成: $file"
}

list_configs() {
    print_title "$PROTO 配置列表"
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        local idx tag port uuid
        idx=$(basename "$f" .json | cut -d'-' -f2); tag="${PROTO}${idx}"
        port=$(jq -r '.inbounds[0].listen_port' "$f")
        uuid=$(jq -r '.inbounds[0].users[0].uuid' "$f")
        printf "%s) 端口:%s  UUID:%s\n" "$idx" "$port" "$uuid" >&2
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
                print_title "TUIC 节点管理"
                echo -e "${CYAN}1)${RESET} 添加节点"; echo -e "${CYAN}2)${RESET} 列出节点"; echo -e "${CYAN}3)${RESET} 删除节点"; echo -e "${CYAN}0)${RESET} 返回"
                read -r -p "请选择: " c
                case "$c" in 1) add_config ;; 2) list_configs ;; 3) delete_config ;; 0) break ;; esac
                read -r -p "按回车继续..." _ || { echo; exit 0; }
            done ;;
    esac
fi
