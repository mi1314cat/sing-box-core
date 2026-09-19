#!/bin/bash
# ==============================================================
# naive.sh — NaiveProxy (HTTP/2 H2 CONNECT) inbound
# sing-box 新版: naive inbound; auth: user/password; 需 TLS 证书
# 自签用 200 天特有自签 + pin 分享（对齐 fscarmen cert_200.pem 思路）
# CLI: bash naive.sh [add|list|del]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="naive"
CERT_DIR="$SB_ROOT/cert"
random_domain() { reality_random_domain; }
extract_cert_domain() {
    local crt="$1" dom=""
    command -v openssl >/dev/null && [[ -f "$crt" ]] && dom=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -oE "DNS:[^,]+" | head -1 | cut -d: -f2)
    [[ -z "$dom" ]] && dom=$(basename "$crt" | sed -E 's/\.(crt|pem)$//; s/_cert$//; s/^cert-//')
    echo "$dom"
}

add_config() {
    print_title "新增 NaiveProxy 节点 ($PROTO-NN.json)"
    local listen_ip listen_port idx file tag
    listen_ip=$(safe_read "监听地址 (0.0.0.0/::)" "::")
    listen_port=$(safe_read_port)
    local user pass
    user=$(openssl rand -hex 6)
    pass=$(openssl rand -hex 6)
    echo "TLS 证书: 1) 真证书 2) 自签(200天+pin) [默认2]" >&2
    read -r -p "选择: " c; c=$(clean_input "$c"); [[ -z "$c" ]] && c=2
    if [[ "$c" == "1" ]]; then
        read -r -p "crt: " CERT_FILE; read -r -p "KEY: " KEY_FILE
        CERT_FILE=$(clean_input "$CERT_FILE"); KEY_FILE=$(clean_input "$KEY_FILE")
        [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] || { print_error "路径无效"; return 1; }
        CERT_DOMAIN=$(extract_cert_domain "$CERT_FILE"); CERT_TRUSTED=true
    else
        local d; d=$(safe_read "自签伪装域名 (domains.sh)" "$(random_domain)")
        mkdir -p "$CERT_DIR"
        CERT_FILE="$CERT_DIR/cert200-$d.crt"; KEY_FILE="$CERT_DIR/key200-$d.key"
        [[ -f "$CERT_FILE" ]] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
            -keyout "$KEY_FILE" -out "$CERT_FILE" -days 200 -subj "/CN=$d" -addext "subjectAltName=DNS:$d" >/dev/null 2>&1
        CERT_DOMAIN="$d"; CERT_TRUSTED=false
    fi

    idx=$(get_next_index "$PROTO"); file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"
    local json
    json=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "naive",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "users": [ { "username": "$user", "password": "$pass" } ],
      "tls": { "enabled": true, "certificate_path": "$CERT_FILE", "key_path": "$KEY_FILE" }
    }
  ]
}
EOF
)
    backup_config config
    write_config "$file" "$json" || return 1
    if ! sb_check; then rm -f "$file"; print_error "已删除非法配置（现网未受影响）"; return 1; fi
    sb_reload || true

    server_ip=$(safe_read "服务器对外 IP" "$(default_server_ip)")
    local pin=""
    [[ "$CERT_TRUSTED" == "false" ]] && pin=$(cert_spki_pin_base64 "$CERT_FILE")
    local link="naive+https://$user:$pass@$server_ip:$listen_port?sni=$CERT_DOMAIN${pin:+&pinSHA256=$pin}#$tag"
    local pin_json="" pin_val=""
    if [[ "$CERT_TRUSTED" == "false" ]]; then
        pin_val=$(cert_spki_pin_base64 "$CERT_FILE")
        pin_json=",\"certificate_public_key_sha256\": \"$pin_val\""
    fi
    cat > "$SB_OUT_DIR/sb_client-$tag.json" <<EOF
{
  "outbounds": [ {
      "type": "naive", "tag": "$tag",
      "server": "$server_ip", "server_port": $listen_port,
      "username": "$user", "password": "$pass",
      "tls": { "enabled": true, "server_name": "$CERT_DOMAIN"$pin_json }
    }
  ]
}
EOF
    echo "$link" | tee "$SB_OUT_DIR/sb_share-$tag.txt" | tail -1 >&2
    grep -vF "$link" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.$$ && mv /tmp/l.$$ "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >> "$SB_OUT_DIR/sb_links-all.txt"
    open_port "$listen_port"
    print_ok "NaiveProxy 节点添加完成: $file"
}

list_configs() {
    print_title "$PROTO 配置"
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        local idx tag port u
        idx=$(basename "$f" .json | cut -d'-' -f2); tag="${PROTO}${idx}"
        port=$(jq -r '.inbounds[0].listen_port' "$f")
        u=$(jq -r '.inbounds[0].users[0].username' "$f")
        printf "%s) 端口:%s user:%s\n" "$idx" "$port" "$u" >&2
    done
}

delete_config() {
    list_configs
    read -r -p "输入要删除的编号: " num; num=$(clean_input "$num")
    [[ "$num" =~ ^[0-9]+$ ]] || { print_error "编号必须数字"; return 1; }
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
            print_title "NaiveProxy 节点管理"
            echo -e "${CYAN}1)${RESET} 添加\n${CYAN}2)${RESET} 列出\n${CYAN}3)${RESET} 删除\n${CYAN}0)${RESET} 返回"
            read -r -p "请选择: " c
            case "$(clean_input "$c")" in 1) add_config ;; 2) list_configs ;; 3) delete_config ;; 0) break ;; esac
            read -r -p "按回车继续..." _
        done ;;
    esac
fi
