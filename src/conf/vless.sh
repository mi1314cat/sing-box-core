#!/bin/bash
# ==============================================================
# vless.sh — VLESS (WS + TLS) 节点模块
# TLS: 使用扫描到的真证书，或与 hysteria2.sh 共享自签证书目录
# CLI: bash vless.sh [add|list|del]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="vless"
CERT_DIR="$SB_ROOT/cert"
random_domain() { reality_random_domain; }

extract_cert_domain() {
    local crt="$1" dom=""
    command -v openssl >/dev/null && [[ -f "$crt" ]] && dom=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -oE "DNS:[^,]+" | head -1 | cut -d: -f2)
    [[ -z "$dom" ]] && dom=$(basename "$crt" | sed -E 's/\.(crt|pem)$//; s/_cert$//; s/^cert-//')
    echo "$dom"
}

ask_cert() {
    # 批量生成且启用 CDN: 直接选真证书。
    # 自签无法被 Cloudflare 回源, 走 CDN 也没有意义, 所以批量 CDN 必须用真证书。
    if [[ "${SB_BATCH:-}" == "1" && "${SB_BATCH_CDN:-0}" == "1" ]]; then
        if sb_batch_cdn_pick_cert; then return 0; fi
        print_warn "批量 CDN: 未找到可用真证书, 本节点退回自签 (将只能直连)"
    fi
    echo "TLS 证书：" >&2
    echo "  1) 手动输入 crt/key 路径" >&2
    echo "  2) 生成自签证书 (客户端需 insecure/pin)" >&2
    local c f k
    read -r -p "  选择 (默认 2=自签): " c
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
      # 真证书: 从已检测到的证书里选 (域名自动带出, 与 Nginx server_name 对齐)
      pick_trusted_cert
}

add_config() {
    print_title "新增 VLESS-WS-TLS 节点 ($PROTO-NN.json)"
    local server_ip listen_ip listen_port uuid path idx file tag json
    server_ip=$(safe_read "服务器对外 IP" "$(default_server_ip)")
    listen_port=$(safe_read_port)
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
    path=$(safe_read "WS 路径 (以 / 开头)" "/$(openssl rand -hex 4)")
    ask_cert || return 1

    # 接入方式在证书选定之后询问: 只有"真证书 + ws/grpc/http"才有 CDN 可选。
    # 监听地址由它决定 (CDN+Nginx 必须只听 127.0.0.1), 所以放到这一步问。
    local ttype="ws" trusted="no"
    # 判定"是否真证书"必须用 lib.sh 里已有的能力, 不能调 cdn.sh 的函数
    # (protocol 脚本不一定加载了 cdn.sh, 调不到就等于"不是真证书" -> CDN 选项被藏)
    sb_key_for "$CERT_FILE" >/dev/null 2>&1 && \
        cert_not_expired "$CERT_FILE" && \
        sb_cert_is_real_issuer "$CERT_FILE" && trusted="yes"
    # ask_access_mode 把结果写进全局 ACCESS_MODE (不靠 stdout):
    # 命令替换会让函数里的 read 跑在子 shell 上, stdin 可能已耗尽,
    # 结果是"明明选了 CDN+Nginx 却还在问监听地址"。
    ask_access_mode "$ttype" "$trusted"
    case "$ACCESS_MODE" in
        cdn)        listen_ip="0.0.0.0" ;;
        cdn-nginx)  listen_ip="127.0.0.1" ;;
        *)          listen_ip=$(safe_read "监听地址 (0.0.0.0/::)" "0.0.0.0") ;;
    esac

    idx=$(get_next_index "$PROTO"); file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"
    tag="$tag$(tag_form_suffix tls)"   # 名字体现传输方式
    local tls_line
    tls_line="\"enabled\": true, \"certificate_path\": \"$CERT_FILE\", \"key_path\": \"$KEY_FILE\", \"alpn\": [\"http/1.1\"]"

    json=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "users": [ { "name": "user", "uuid": "$uuid" } ],
      "transport": { "type": "ws", "path": "$path", "early_data_header_name": "Sec-WebSocket-Protocol" },
      "tls": { $tls_line }
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

    # CDN 节点只监听 127.0.0.1, 客户端连证书域名而非服务器 IP
    server_ip=$(sb_cdn_finalize "$file" "$server_ip")
    # CDN 只在 443 上提供服务; 沿用源站端口会得到连不通的 域名:源站端口
    sb_node_is_cdn "$file" && listen_port=443
    local link="vless://$uuid@$server_ip:$listen_port?encryption=none&security=tls&sni=$CERT_DOMAIN&type=ws&host=$CERT_DOMAIN&path=$path#$tag"
    local utls_fp; utls_fp=$(ask_utls_fingerprint)
    cat > "$SB_OUT_DIR/sb_client-$tag.json" <<EOF
{
  "outbounds": [
    { "type": "vless", "tag": "$tag", "server": "$server_ip", "server_port": $listen_port,
      "uuid": "$uuid",
      "tls": { "enabled": true, "server_name": "$CERT_DOMAIN", "insecure": $( [[ "$CERT_TRUSTED" == "true" ]] && echo false || echo true ), "utls": { "enabled": true, "fingerprint": "$utls_fp" } },
      "transport": { "type": "ws", "path": "$path" } }
  ]
}
EOF
        gen_mihomo_yaml "$tag"

    # CDN 节点额外产出 .cdn 版产物 (连域名走 Cloudflare), 与直连版并存
    if sb_cdn_enabled "$file"; then
        cdn_node_gen_all "$tag" >/dev/null 2>&1 || true
    fi
    [[ "$CERT_TRUSTED" == "false" ]] && echo "# 自签证书: 为 mihomo 加 skip-cert-verify: true" >> "$SB_OUT_DIR/sb_client-$tag.yaml"
    echo "$link" | tee "$SB_OUT_DIR/sb_share-$tag.txt" | tail -1 >&2
    grep -vF "$link" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.$$ && mv /tmp/l.$$ "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >> "$SB_OUT_DIR/sb_links-all.txt"
    open_port "$listen_port"
    print_ok "VLESS 节点添加完成: $file"
}

list_configs() {
    print_title "$PROTO 配置列表"
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        local idx tag port uuid path
        idx=$(basename "$f" .json | cut -d'-' -f2); tag="${PROTO}${idx}"
        port=$(jq -r '.inbounds[0].listen_port' "$f")
        uuid=$(jq -r '.inbounds[0].users[0].uuid' "$f")
        path=$(jq -r '.inbounds[0].transport.path' "$f")
        printf "%s) 端口:%s  WS路径:%s  UUID:%s\n" "$idx" "$port" "$path" "$uuid" >&2
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
    rm -f "$file" "$SB_OUT_DIR/sb_share-$tag.txt" "$SB_OUT_DIR/sb_client-$tag.json" "$SB_OUT_DIR/sb_client-$tag.yaml"
    [[ -n "$fw_port" ]] && close_node_port "$fw_port" "$tag"
    sb_check && sb_reload || print_warn "请手动确认服务状态"
    print_ok "已删除 $tag"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        add) add_config ;; list) list_configs ;; del) delete_config ;; check) sb_check ;;
        *)
            while true; do
                print_title "VLESS 节点管理"
                echo -e "${CYAN}1)${RESET} 添加节点"; echo -e "${CYAN}2)${RESET} 列出节点"; echo -e "${CYAN}3)${RESET} 删除节点"; echo -e "${CYAN}0)${RESET} 返回"
                read -r -p "请选择: " c
                case "$c" in 1) add_config ;; 2) list_configs ;; 3) delete_config ;; 0) break ;; esac
                read -r -p "按回车继续..." _ || { echo; exit 0; }
            done ;;
    esac
fi
