#!/bin/bash
# ==============================================================
# hysteria2.sh — Hysteria2 节点模块
# 职责：添加/删除/列出 config/hysteria2-NN.json + out/ 客户端产物
# 真证书扫描（xary-core 证书清单）或自签（ECDSA P-256）+ SPKI pin 分享
# CLI: bash hysteria2.sh [add|list|delerkenen]   无参数=交互菜单
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="hysteria2"
CERT_DIR="$SB_ROOT/cert"
random_domain() { reality_random_domain; }          # 自签证书目录（本模块所有）
# 自签伪装域名统一走 domains.sh (reality_random_domain)

# ---------- 证书工具（对齐 xary-core hysteria2.sh）----------
extract_cert_domain() {
    local crt="$1" dom=""
    if command -v openssl >/dev/null && [[ -f "$crt" ]]; then
        dom=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null |
            grep -oE "DNS:[^,]+" | head -1 | cut -d: -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
        [[ -z "$dom" ]] && dom=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null |
            grep -oE "CN *= *[^,]+" | head -1 | sed 's/.*CN *= *//' | tr -d '"' | tr '[:upper:]' '[:lower:]')
    fi
    [[ -z "$dom" ]] && dom=$(basename "$crt" | sed -E 's/\.(crt|pem)$//; s/_cert$//; s/^cert-//')
    echo "$dom"
}

cert_not_expired() { [[ -f "$1" ]] && openssl x509 -in "$1" -noout -checkend 86400 >/dev/null 2>&1; }

find_key_for_cert() {
    local crt="$1" k
    k="${crt%.crt}.key";  [[ -f "$k" ]] && { echo "$k"; return; }
    k="${crt%.pem}.key";  [[ -f "$k" ]] && { echo "$k"; return; }
    k="${crt%_cert.pem}_key.pem"; [[ -f "$k" ]] && { echo "$k"; return; }
    echo "$(dirname "$crt")/server.key"
}

scan_certs() {
    FOUND_CERTS=()
    local d f k lbl dir dirs=() labels=()
    dirs=(/root/catmi/cloudflare/certs /root/catmi /etc/v2ray-agent/tls /root/.acme.sh /etc/nginx/certs /etc/nginx/ssl /home/web/certs)
    labels=(catmi-cloudflare catmi-root v2ray-agent acme nginx-certs nginx-ssl web-certs)
    local i
    for ((i=0; i<${#dirs[@]}; i++)); do
        d="${dirs[$i]}"
        [[ -d "$d" ]] || continue
        for f in "$d"/*.pem "$d"/*.crt; do
            [[ -f "$f" ]] || continue
            [[ "$f" == *key* ]] && continue
            case "$(basename "$f")" in ca.cer|fullchain.cer|*.issuer.cer|chain.cer|key.pem) continue ;; esac
            openssl x509 -in "$f" -noout -text 2>/dev/null | grep -q "CA:TRUE" && continue
            k=$(find_key_for_cert "$f")
            [[ -f "$k" ]] && cert_not_expired "$f" && FOUND_CERTS+=("$f|$k|${labels[$i]}")
        done
    done
}

generate_cert() {
    local dom; dom=$(safe_read "自签伪装域名" "$(random_domain)")
    [[ -z "$dom" || "$dom" == " " ]] && dom=$(random_domain)
    CERT_FILE="$CERT_DIR/cert-$dom.crt"
    KEY_FILE="$CERT_DIR/key-$dom.key"
    mkdir -p "$CERT_DIR"
    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        print_ok "复用自签证书: $dom"
        CERT_DOMAIN="$dom"; CERT_TRUSTED=false
        return 0
    fi
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -pkeyopt ec_param_enc:named_curve -nodes \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 \
        -subj "/CN=$dom" -addext "subjectAltName=DNS:$dom" >/dev/null 2>&1
    if [[ -f "$CERT_FILE" ]]; then CERT_DOMAIN="$dom"; CERT_TRUSTED=false; print_ok "自签证书已生成: $dom"; return 0; fi
    print_error "自签失败"; return 1
}

ask_cert() {
    local c f k
    echo "证书方案：" >&2
    echo "  1) 扫描本机已有证书 (CA可信)" >&2
    echo "  2) 手动输入路径" >&2
    echo "  3) 生成自签证书 (无需域名, 用 pin 校验)" >&2
    read -r -p "  选择 (默认 3): " c
    c=$(clean_input "$c"); [[ -z "$c" ]] && c=3
    case "$c" in
        2)
            read -r -p "  crt 路径: " f; read -r -p "  key 路径: " k
            f=$(clean_input "$f"); k=$(clean_input "$k")
            if [[ -f "$f" && -f "$k" ]]; then
                CERT_FILE="$f"; KEY_FILE="$k"
                CERT_DOMAIN=$(extract_cert_domain "$f")
                cert_not_expired "$f" || { print_warn "证书已过期"; return 1; }
                CERT_TRUSTED=true; print_ok "使用手动证书: $CERT_DOMAIN"; return 0
            fi
            print_error "路径无效，改用自签"; generate_cert; return $?
            ;;
    esac
    if [[ "$c" == "1" ]]; then
        scan_certs
        if ((${#FOUND_CERTS[@]} > 0)); then
            local i=1 pair
            for pair in "${FOUND_CERTS[@]}"; do
                f="${pair%%|*}"; k="${pair#*|}"; k="${k%%|*}"
                echo "  $i) $(extract_cert_domain "$f")" >&2
                ((i++))
            done
            read -r -p "  选择 (默认 1): " pick
            pick=$(clean_input "$pick"); [[ -z "$pick" ]] && pick=1
            pair="${FOUND_CERTS[$((pick-1))]}"
            CERT_FILE="${pair%%|*}"; KEY_FILE="${pair#*|}"; KEY_FILE="${KEY_FILE%%|*}"
            CERT_DOMAIN=$(extract_cert_domain "$CERT_FILE"); CERT_TRUSTED=true
            print_ok "使用证书: $CERT_DOMAIN (crt=$CERT_FILE key=$KEY_FILE)"
            return 0
        fi
        print_warn "未扫描到可用证书，改用自签"
    fi
    generate_cert
}


# ---------- add ----------
add_config() {
    print_title "新增 Hysteria2 节点 ($PROTO-NN.json)"
    local server_ip listen_ip listen_port idx
    server_ip=$(safe_read "服务器对外 IP" "$(default_server_ip)")
    listen_ip=$(safe_read "监听地址 (0.0.0.0/::)" "0.0.0.0")
    listen_port=$(safe_read_port)
    read -r -p "是否开启 UDP 端口跳跃? [y/N]: " yn
    local hop=""
    if [[ "$(clean_input "$yn")" =~ ^[yY] ]]; then
        hop=$(clean_input "$(safe_read "跳跃范围 (如 30000-31000)" "30000-31000")")
        if [[ "$hop" =~ ^[0-9]+-[0-9]+$ ]]; then
            local s="${hop%-*}" e="${hop#*-}"
            if command -v iptables >/dev/null && ! iptables -C INPUT -p udp --dport "$s:$e" -j ACCEPT 2>/dev/null; then
                # 吸附到 DNAT
                if iptables -t nat -C PREROUTING -p udp --dport "$s:$e" -j REDIRECT --to-ports "$listen_port" 2>/dev/null; then
                    print_warn "范围已存在规则"
                else
                    iptables -t nat -A PREROUTING -p udp --dport "$s:$e" -j REDIRECT --to-ports "$listen_port"
                    iptables -C OUTPUT -p udp --dport "$s:$e" -j REDIRECT --to-ports "$listen_port" 2>/dev/null || \
                        iptables -t nat -A OUTPUT -p udp --dport "$s:$e" -j REDIRECT --to-ports "$listen_port" 2>/dev/null
                    print_ok "端口跳跃 DNAT 已添加: $hop -> $listen_port"
                fi
            fi
        else
            print_warn "范围格式错误，未开启跳跃"; hop=""
        fi
    fi

    ask_cert || return 1
    local password="" mask="none"
    read -r -p "是否启用 obfs 混淆? [y/N]: " oyn
    if [[ "$(clean_input "$yn")" =~ ^[yY] ]]; then
        mask=$(openssl rand -hex 12)
        print_ok "obfs password: $mask"
    fi
    local auth; auth=$(openssl rand -hex 16)

    local idx file tag json
    idx=$(get_next_index "$PROTO")
    file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"

    local cert_paths_line
    cert_paths_line="\"certificate_path\": \"$CERT_FILE\", \"key_path\": \"$KEY_FILE\""

    local json
    json=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "users": [ { "name": "user", "password": "$auth" } ],
      "up_mbps": 100,
      "down_mbps": 500,
      "obfs": { "type": "salamander", "password": "$mask" },
      "tls": { "enabled": true, "alpn": ["h3"], $cert_paths_line }
    }
  ]
}
EOF
)
    # mask="none" 时去掉 obfs 一行与逗号
    if [[ "$mask" == "none" ]]; then
        json=$(echo "$json" | jq 'del(.inbounds[0].obfs)')
    fi

    backup_config config
    write_config "$file" "$json" || return 1
    if ! sb_check; then
        rm -f "$file"
        print_error "已删除非法配置文件（现网未受影响，请检查错误信息）"
        return 1
    fi
    sb_reload || print_warn "请确认服务状态"

    # ---- 客户端产物 ----
    local pin="" pin_q=""
    if [[ "$CERT_TRUSTED" == "false" ]]; then
        pin=$(cert_spki_pin_base64 "$CERT_FILE")
    fi
    local link="hysteria2://$auth@$server_ip:$listen_port?${hop:+mport=$hop&}sni=$CERT_DOMAIN&obfs=$( [[ $mask != none ]] && echo salamander || echo none )&obfs-password=$( [[ $mask != none ]] && echo $mask )&alpn=h3"
    [[ "$CERT_TRUSTED" == "false" ]] && link="$link&pinSHA256=$pin"
    link="$link#$tag"
    # 简化: 对标准客户端, 自签统一用 insecure=1 提示, 或者 pin=hex (v2rayN 等)
    cat > "$SB_OUT_DIR/sb_client-$tag.json" <<EOF
{
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "$tag",
      "server": "$server_ip",
      "server_port": $listen_port,
      "password": "$auth",
      "up_mbps": 100,
      "down_mbps": 500,
      "tls": {
        "enabled": true,
        "server_name": "$CERT_DOMAIN",
        "alpn": ["h3"],
        "certificate_public_key_sha256": "$pin"
      }
    }
  ]
}
EOF
    mkdir -p "$SB_OUT_DIR"
    echo "{\"tag\":\"$tag\",\"port\":$listen_port,\"hop\":\"$hop\",\"cert\":\"$CERT_FILE\",\"cert_trusted\":$CERT_TRUSTED,\"auth\":\"$auth\",\"mask\":\"$mask\"}" | jq . > "$SB_OUT_DIR/sb_meta-$tag.json"
    echo "$link" > "$SB_OUT_DIR/sb_share-$tag.txt"
    grep -vF "$link" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.$$ && mv /tmp/l.$$ "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >> "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >&2
    open_port "$listen_port"
    print_ok "Hysteria2 节点添加完成: $file"
}

# ---------- list / del ----------
list_configs() {
    print_title "$PROTO 配置列表"
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        local idx tag port auth cert
        idx=$(basename "$f" .json | cut -d'-' -f2); tag="${PROTO}${idx}"
        port=$(jq -r '.inbounds[0].listen_port' "$f")
        auth=$(jq -r '.inbounds[0].users[0].password' "$f")
        printf "%s) 端口:%s  auth:%s\n" "$idx" "$port" "$auth" >&2
    done
}

delete_config() {
    list_configs
    read -r -p "输入要删除的编号: " num
    num=$(clean_input "$num")
    [[ "$num" =~ ^[0-9]+$ ]] || { print_error "编号必须数字"; return 1; }
    local idx file tag hop port
    idx=$(printf "%02d" "$num")
    file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"
    [[ -f "$file" ]] || { print_error "编号不存在"; return 1; }
    hop=$(jq -r '.hop // empty' "$SB_OUT_DIR/sb_meta-$tag.json" 2>/dev/null)
    if [[ -n "$hop" && "$hop" =~ ^[0-9]+-[0-9]+$ ]]; then
        local s="${hop%-*}" e="${hop#*-}"
        iptables -t nat -D PREROUTING -p udp --dport "$s:$e" -j REDIRECT --to-ports "$(jq -r '.port' "$SB_OUT_DIR/sb_meta-$tag.json")" 2>/dev/null || true
        iptables -t nat -D OUTPUT -p udp --dport "$s:$e" -j REDIRECT --to-ports "$(jq -r '.port' "$SB_OUT_DIR/sb_meta-$tag.json")" 2>/dev/null || true
        echo "端口跳跃 DNAT 已撤销: $hop" >&2
    fi
    rm -f "$file" "$SB_OUT_DIR/sb_share-$tag.txt" "$SB_OUT_DIR/sb_client-$tag.json" "$SB_OUT_DIR/sb_meta-$tag.json"
    sb_check && sb_reload || print_warn "请手动确认服务状态"
    print_ok "已删除 $tag"
}

# ---- CLI / 菜单 ----
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        add)   add_config ;;
        list)  list_configs ;;
        del)   delete_config ;;
        check) sb_check ;;
        *)
            while true; do
                print_title "Hysteria2 节点管理"
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
