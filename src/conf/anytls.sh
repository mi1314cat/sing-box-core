#!/bin/bash
# ==============================================================
# anytls.sh — AnyTLS (纯 AnyTLS, 不带 REALITY) 节点模块
#
# 为什么单独建这个模块:
#   anyreality.sh = AnyTLS + REALITY, 而 mihomo/Clash **明确不支持**
#   anytls+reality 组合 (官方: "will not support this combination in the
#   future")。所以此前"一键生成所有协议"产出的 anytls 系节点只有
#   anyreality 一个, 在 mihomo 客户端里一个都用不了。
#   本模块生成不带 REALITY 的纯 AnyTLS (自签证书 + SPKI 钉扎),
#   sing-box 与 mihomo 都能用, 两边都覆盖到。
#
# 证书: 真证书 / 自签(pin)
# CLI: bash anytls.sh [add|list|del]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="anytls"
CERT_DIR="$SB_ROOT/cert"

extract_cert_domain() {
    local crt="$1" dom=""
    command -v openssl >/dev/null && [[ -f "$crt" ]] && dom=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -oE "DNS:[^,]+" | head -1 | cut -d: -f2)
    [[ -z "$dom" ]] && dom=$(basename "$crt" | sed -E 's/\.(crt|pem)$//; s/^cert-//')
    echo "$dom"
}

ask_cert() {  # 输出 CERT_FILE / KEY_FILE / CERT_DOMAIN / CERT_TRUSTED
    local c
    echo "TLS 证书: 1) 真证书 2) 自签(pin) [默认 2]" >&2
    read -r -p "选择: " c; c=$(clean_input "$c"); [[ -z "$c" ]] && c=2
    if [[ "$c" == "2" ]]; then
        local d; d=$(safe_read "自签伪装域名 (统一 domains.sh)" "$(reality_random_domain)")
        mkdir -p "$CERT_DIR"
        CERT_FILE="$CERT_DIR/cert-$d.crt"; KEY_FILE="$CERT_DIR/key-$d.key"
        [[ -f "$CERT_FILE" ]] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
            -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 -subj "/CN=$d" -addext "subjectAltName=DNS:$d" >/dev/null 2>&1
        [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] || { print_error "证书生成失败"; return 1; }
        CERT_DOMAIN="$d"; CERT_TRUSTED=false; return 0
    fi
    read -r -p "crt 路径: " CERT_FILE; read -r -p "key 路径: " KEY_FILE
    CERT_FILE=$(clean_input "$CERT_FILE"); KEY_FILE=$(clean_input "$KEY_FILE")
    [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] || { print_error "证书路径无效"; return 1; }
    CERT_DOMAIN=$(extract_cert_domain "$CERT_FILE"); CERT_TRUSTED=true
}

# 证书 DER 的 SHA256 (mihomo 的 fingerprint 语义: 证书指纹, 不是 SPKI 哈希)
cert_fingerprint_hex() {
    command -v openssl >/dev/null || return 1
    openssl x509 -in "$1" -outform DER 2>/dev/null | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}'
}

add_config() {
    print_title "新增 AnyTLS 节点 ($PROTO-NN.json)"
    local listen_ip listen_port password file tag idx server_ip pin=""
    listen_ip=$(safe_read "监听地址 (0.0.0.0/::)" "0.0.0.0")
    listen_port=$(safe_read_port)
    password=$(openssl rand -base64 18 | tr -d '/+=\n' | head -c 24)
    ask_cert || return 1

    idx=$(get_next_index "$PROTO"); file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"
    local json
    json=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "anytls",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "users": [ { "name": "user", "password": "$password" } ],
      "tls": { "enabled": true, "alpn": ["h2", "http/1.1"], "certificate_path": "$CERT_FILE", "key_path": "$KEY_FILE" }
    }
  ]
}
EOF
)
    backup_config config
    write_config "$file" "$json" || return 1
    if ! sb_check; then
        rm -f "$file"
        print_error "已删除非法配置（现网未受影响）"
        return 1
    fi
    cleanup_node_shares "$tag"
    sb_reload || true

    server_ip=$(safe_read "服务器对外 IP" "$(default_server_ip)")
    [[ "$CERT_TRUSTED" == "false" ]] && pin=$(cert_spki_pin_base64 "$CERT_FILE")
    local fp=""; [[ "$CERT_TRUSTED" == "false" ]] && fp=$(cert_fingerprint_hex "$CERT_FILE")

    # anytls:// 分享链接 (自签走 pinSHA256, 与 trojan 同一套语义)
    local link="anytls://$password@$server_ip:$listen_port?sni=$CERT_DOMAIN&insecure=1${pin:+&pinSHA256=$pin}#$tag"
    [[ "$CERT_TRUSTED" == "true" ]] && link="anytls://$password@$server_ip:$listen_port?sni=$CERT_DOMAIN&insecure=0#$tag"

    python3 - "$SB_OUT_DIR/sb_client-$tag.json" "$tag" "$server_ip" "$listen_port" "$password" "$CERT_DOMAIN" "$pin" <<'PYGEN'
import json,sys
_,ofile,tag,srv,port,pw,sni,pin=sys.argv
tls={"enabled":True,"server_name":sni,"alpn":["h2","http/1.1"],
     "utls":{"enabled":True,"fingerprint":"chrome"}}
if pin: tls["certificate_public_key_sha256"]=pin
out={"type":"anytls","tag":tag,"server":srv,"server_port":int(port),"password":pw,"tls":tls}
json.dump({"outbounds":[out]},open(ofile,"w"),indent=2)
PYGEN

    # mihomo 单节点 YAML (纯 AnyTLS 是 mihomo 支持的类型, 走证书钉扎)
    {
        echo "proxies:"
        echo "  - name: $tag"
        echo "    type: anytls"
        echo "    server: $server_ip"
        echo "    port: $listen_port"
        echo "    password: $password"
        echo "    client-fingerprint: chrome"
        [[ -n "$fp" ]] && echo "    fingerprint: $fp"
        [[ "$CERT_TRUSTED" == "false" ]] && echo "    skip-cert-verify: true"
        echo "    sni: $CERT_DOMAIN"
        echo "    alpn:"
        echo "      - h2"
        echo "      - http/1.1"
    } > "$SB_OUT_DIR/sb_client-$tag.yaml"

    echo "$link" > "$SB_OUT_DIR/sb_share-$tag.txt"
    grep -vF "$link" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.$$ && mv /tmp/l.$$ "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >> "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >&2
    echo "{\"tag\":\"$tag\",\"port\":$listen_port,\"password\":\"$password\",\"pin\":\"$pin\"}" | jq . > "$SB_OUT_DIR/sb_meta-$tag.json"
    open_port "$listen_port"
    print_ok "AnyTLS 节点添加完成: $file"
    print_warn "提示: 纯 AnyTLS (不带 REALITY), sing-box 与 mihomo/Clash 都能用"
}

list_configs() {
    print_title "$PROTO 配置列表"
    local found=0
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        found=1
        local idx tag port
        idx=$(basename "$f" .json | cut -d'-' -f2); tag="${PROTO}${idx}"
        port=$(jq -r '.inbounds[0].listen_port' "$f")
        printf "  %s) %s 端口:%s\n" "$idx" "$tag" "$port" >&2
    done
    (( found )) || print_warn "暂无 $PROTO 节点"
    return 0
}

delete_config() {
    list_configs
    read -r -p "输入要删除的编号: " num
    num=$(clean_input "$num")
    [[ "$num" =~ ^[0-9]+$ ]] || { print_error "编号必须数字"; return 1; }
    read -r -p "确认删除编号 $num ($PROTO) 的节点? [y/N]: " dconfirm
    [[ "$(clean_input "$dconfirm")" =~ ^[yY] ]] || { print_warn "已取消"; return 0; }
    local idx file tag
    idx=$(printf "%02d" "$num")
    file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"
    [[ -f "$file" ]] || { print_error "编号不存在"; return 1; }
    rm -f "$file" "$SB_OUT_DIR/sb_share-$tag.txt" "$SB_OUT_DIR/sb_client-$tag.json" \
          "$SB_OUT_DIR/sb_client-$tag.yaml" "$SB_OUT_DIR/sb_meta-$tag.json"
    cleanup_node_shares "$tag"
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
                print_title "AnyTLS 节点管理 (纯 AnyTLS, 不带 REALITY)"
                echo -e "${CYAN}1)${RESET} 添加节点"
                echo -e "${CYAN}2)${RESET} 列出节点"
                echo -e "${CYAN}3)${RESET} 删除节点"
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
            done
            ;;
    esac
fi
