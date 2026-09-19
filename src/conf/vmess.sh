#!/bin/bash
# ==============================================================
# vmess.sh — VMess 节点模块（transport 可选: ws / grpc / http / tcp裸）
# TLS 可选（真证书/自签 pin 或 no-tls）；Reality 由 reality.sh 全权处理
# CLI: bash vmess.sh [add|list|del]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="vmess"
CERT_DIR="$SB_ROOT/cert"
random_domain() { reality_random_domain; }

extract_cert_domain() {
    local crt="$1" dom=""
    command -v openssl >/dev/null && [[ -f "$crt" ]] && dom=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -oE "DNS:[^,]+" | head -1 | cut -d: -f2)
    [[ -z "$dom" ]] && dom=$(basename "$crt" | sed -E 's/\.(crt|pem)$//; s/_cert$//; s/^cert-//')
    echo "$dom"
}

ask_tls() { # 输出: CERT_MODE|cert_file|key_file|cert_domain|trusted(0|1) 到 stdout
    echo "TLS 选项: 1) no-TLS(裸 ws) 2) 真证书 3) 自签(pin) 4) Reality" >&2
    read -r -p "选择 (默认 2): " c
    c=$(clean_input "$c"); [[ -z "$c" ]] && c=2
    case "$c" in
        1) echo "none|||" ;;
        3)
            local d; d=$(safe_read "自签冒充域名" "$(random_domain)")
            mkdir -p "$CERT_DIR"
            CERT_FILE="$CERT_DIR/cert-$d.crt"; KEY_FILE="$CERT_DIR/key-$d.key"
            [[ -f "$CERT_FILE" ]] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
                -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 -subj "/CN=$d" -addext "subjectAltName=DNS:$d" >/dev/null 2>&1
            echo "selfsign|$CERT_FILE|$KEY_FILE|$d"
            ;;
        4) echo "reality|||" ;;
        2)
            read -r -p "crt 路径: " f; read -r -p "key 路径: " k
            echo "real|$(clean_input "$f")|$(clean_input "$k")|$(extract_cert_domain "$f")"
            ;;
        *) echo "none|||" ;;
    esac
}

add_config() {
    print_title "新增 VMess 节点 ($PROTO-NN.json)"
    local listen_ip listen_port svc_if
    listen_ip=$(safe_read "监听地址 (0.0.0.0/::)" "0.0.0.0")
    listen_port=$(safe_read_port)
    echo "transport: 1) ws 2) grpc 3) http(H2) 4) tcp裸" >&2
    read -r -p "选择 (默认 ws): " tv; tv=$(clean_input "$tv")
    local ttype tpath svc
    case "$tv" in
        2) ttype="grpc"; svc=$(safe_read "service_name" "vmSvc") ;;
        3) ttype="http"; svc="" ;;
        4) ttype=""; svc="" ;;
        *) ttype="ws"; tpath=$(safe_read "WS path (默认 /uuid 随机)" "/$(openssl rand -hex 6)") ;;
    esac

    IFS='|' read -r CERT_MODE CERT_FILE KEY_FILE CERT_DOMAIN <<<"$(ask_tls)"
    local uuid; uuid=$(cat /proc/sys/kernel/random/uuid)
    local REAL_PRIV REAL_PUB
    if [[ "$CERT_MODE" == "reality" ]]; then
        . "$SB_OUT_DIR/reality-keys.json" 2>/dev/null || true
        [[ -f "$SB_OUT_DIR/reality-keys.json" ]] && REAL_PRIV=$(jq -r .private_key "$SB_OUT_DIR/reality-keys.json") && REAL_PUB=$(jq -r .public_key "$SB_OUT_DIR/reality-keys.json")
        [[ -z "$REAL_PRIV" ]] && { kp=$("$SB_BIN" generate reality-keypair); REAL_PRIV=$(echo "$kp"|grep -oP '^PrivateKey: \K.*'); REAL_PUB=$(echo "$kp"|grep -oP '^PublicKey: \K.*'); echo "{\"private_key\":\"$REAL_PRIV\",\"public_key\":\"$REAL_PUB\"}"|jq .>"$SB_OUT_DIR/reality-keys.json"; }
        local rnd; rnd=$(reality_random_domain)
        local sid; sid=$(openssl rand -hex 8)
    fi

    local idx file tag json
    idx=$(get_next_index "$PROTO"); file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"

    local base
    base=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "vmess",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "users": [ { "name": "user", "uuid": "$uuid", "alterId": 0 } ]
    }
  ]
}
EOF
)
    if [[ "$ttype" == "ws" ]]; then
        base=$(echo "$base" | jq --arg p "$tpath" '.inbounds[0].transport={"type":"ws","path":$p,"max_early_data":2560,"early_data_header_name":"Sec-WebSocket-Protocol"}')
    elif [[ "$ttype" == "grpc" ]]; then
        base=$(echo "$base" | jq --arg s "$svc" '.inbounds[0].transport={"type":"grpc","service_name":$s}')
    elif [[ "$ttype" == "http" ]]; then
        base=$(echo "$base" | jq '.inbounds[0].transport={"type":"http"}')
    fi

    case "$CERT_MODE" in
        real)
            base=$(echo "$base" | jq --arg c "$CERT_FILE" --arg k "$KEY_FILE" --arg d "$CERT_DOMAIN" '.inbounds[0].tls={"enabled":true,"server_name":$d,"alpn":["http/1.1"],"certificate_path":$c,"key_path":$k}')
            ;;
        selfsign)
            base=$(echo "$base" | jq --arg c "$CERT_FILE" --arg k "$KEY_FILE" '.inbounds[0].tls={"enabled":true,"alpn":["http/1.1"],"certificate_path":$c,"key_path":$k}')
            ;;
        reality)
            base=$(echo "$base" | jq --arg d "$rnd" --arg pk "$REAL_PRIV" --arg sid "$sid" '.inbounds[0].tls={"enabled":true,"server_name":$d,"reality":{"enabled":true,"handshake":{"server":$d,"server_port":443},"private_key":$pk,"short_id":[$sid]}}')
            ;;
    esac

    backup_config config
    write_config "$file" "$base" || return 1
    if ! sb_check; then rm -f "$file"; print_error "已删除非法配置（现网未受影响）"; return 1; fi
    sb_reload || true

    # server对外IP / 客户端
    local server_ip; server_ip=$(default_server_ip)
    server_ip=$(safe_read "服务器对外 IP" "$server_ip")

    local pbk sidq urlsec secpin=""
    if [[ "$CERT_MODE" == "reality" ]]; then
        pbk="$REAL_PUB"
        url="vless://$uuid@$server_ip:$listen_port?encryption=aes-128-gcm&security=reality&sni=$rnd&fp=chrome&pbk=$pbk&sid=$sid"
        [[ "$ttype" == "ws" ]] && url="$url&type=ws&path=$tpath"
        [[ "$ttype" == "grpc" ]] && url="$url&type=grpc&serviceName=$svc"
    else
        url="vmess://$(json_base64="$uuid" ; printf '{\"add\":\"%s\",\"port\":\"%s\",\"uuid\":\"%s\",\"aid\":\"0\",\"net\":\"%s\",\"path\":\"%s\",\"security\":\"none\",\"tls\":\"\"}' "$server_ip" "$listen_port" "$uuid" "${ttype:-tcp}" "$tpath" | base64 -w0)"
    fi
    if [[ "$CERT_MODE" == "selfsign" ]]; then
        secpin=$(cert_spki_pin_base64 "$CERT_FILE")
        url="$url&SNI=$CERT_DOMAIN"
        [[ -n "$secpin" ]] && url="$url&pinSHA256=$secpin"
    fi
    url="$url#$tag"
    python3 - "$SB_OUT_DIR/sb_client-$tag.json" "$tag" "$server_ip" "$listen_port" "$uuid" "$CERT_MODE" "$CERT_FILE" "$KEY_FILE" "$CERT_DOMAIN" "$ttype" "$tpath" "$svc" "$secpin" <<'PYGEN'
import json,sys,os
_,ofile,tag,srv,port,uuid,mode,crt,key,ttype,tpath,svc,pin=sys.argv
ob={"type":"vmess","tag":tag,"server":srv,"server_port":int(port),"uuid":uuid,"alterId":0}
if ttype=="ws": ob["transport"]={"type":"ws","path":tpath}
if ttype=="grpc": ob["transport"]={"type":"grpc","service_name":svc}
if ttype=="http": ob["transport"]={"type":"http"}
if mode=="real":
    ob["tls"]={"enabled":True,"server_name":os.popen(f'openssl x509 -in {crt} -noout -ext subjectAltName 2>/dev/null | grep -oE "DNS:[^,]+" | head -1 | cut -d: -f2').read().strip() or "unknown"}
elif mode=="selfsign":
    ob["tls"]={"enabled":True,"certificate_public_key_sha256":pin}
json.dump({"outbounds":[ob]},open(ofile,"w"),indent=2)
PYGEN
    echo "$link" | tee "$SB_OUT_DIR/sb_share-$tag.txt" | tail -1 >&2
    grep -vF "$link" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.$$ && mv /tmp/l.$$ "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >> "$SB_OUT_DIR/sb_links-all.txt"
    echo "{\"tag\":\"$tag\",\"port\":$listen_port,\"mode\":\"$CERT_MODE\",\"path\":\"$tpath\",\"svc\":\"$svc\"}" | jq . > "$SB_OUT_DIR/sb_meta-$tag.json"
    open_port "$listen_port"
    print_ok "VMess 节点添加完成: $file"
}

list_configs() {
    print_title "$PROTO 配置"
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        local idx tag port uuid
        idx=$(basename "$f" .json | cut -d'-' -f2); tag="${PROTO}${idx}"
        port=$(jq -r '.inbounds[0].listen_port' "$f")
        uuid=$(jq -r '.inbounds[0].users[0].uuid' "$f")
        printf "%s) 端口:%s UUID:%s\n" "$idx" "$port" "$uuid" >&2
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
            print_title "VMess 节点管理"
            echo -e "${CYAN}1)${RESET} 添加\n${CYAN}2)${RESET} 列出\n${CYAN}3)${RESET} 删除\n${CYAN}0)${RESET} 返回"
            read -r -p "请选择: " c
            case "$(clean_input "$c")" in 1) add_config ;; 2) list_configs ;; 3) delete_config ;; 0) break ;; esac
            read -r -p "按回车继续..." _
        done ;;
    esac
fi
