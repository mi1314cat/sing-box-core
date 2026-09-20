#!/bin/bash
# ==============================================================
# trojan.sh — Trojan + TLS 节点模块
# 证书: 真证书 / 自签(pin 分享)；不支持 Reality(无先例, 参考脚本均未做)
# CLI: bash trojan.sh [add|list|del]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="trojan"
CERT_DIR="$SB_ROOT/cert"
random_domain() { reality_random_domain; }

extract_cert_domain() {
    local crt="$1" dom=""
    command -v openssl >/dev/null && [[ -f "$crt" ]] && dom=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -oE "DNS:[^,]+" | head -1 | cut -d: -f2)
    [[ -z "$dom" ]] && dom=$(basename "$crt" | sed -E 's/\.(crt|pem)$//; s/_cert$//; s/^cert-//')
    echo "$dom"
}

ask_cert() {  # 输出三种: CERT_FILE+KEY_FILE (TLS) / REALITY_ENV (Reality = TLS enabled false)
    echo "TLS 证书: 1) 真证书 2) 自签(pin) 3) Reality (AnyReality 同款) [默认 2]" >&2
    read -r -p "选择: " c; c=$(clean_input "$c"); [[ -z "$c" ]] && c=2
    if [[ "$c" == "3" ]]; then
        local dom sni
        dom=$(safe_read "Reality 握手目标 (统一 domains.sh)" "$(random_domain)")
        mkdir -p "$CERT_DIR"
        if [[ ! -f "$SB_OUT_DIR/reality-keys.json" ]]; then
            local kp=("$("$SB_BIN" generate reality-keypair 2>/dev/null | awk -F': ' "/PrivateKey|PublicKey/{print \$NF}")")
            [[ ${#kp} -lt 0 ]] || :           # awk not needed here, direct friendlier below
        fi
        if [[ ! -s "$SB_OUT_DIR/reality-keys.json" ]]; then
            local priv pub
            mapfile -t kp < <("$SB_BIN" generate reality-keypair 2>/dev/null | awk -F': ' 'NF>1 {print $NF}')
            priv="${kp[0]:-}"; pub="${kp[1]:-}"
            [[ -z "$priv" || -z "$pub" ]] && { print_error "REALITY 密钥生成失败"; return 1; }
            jq -n --arg p "$priv" --arg u "$pub" '{private_key:$p,public_key:$u}' > "$SB_OUT_DIR/reality-keys.json"
        fi
        priv=$(jq -r .private_key "$SB_OUT_DIR/reality-keys.json")
        pub=$(jq -r .public_key "$SB_OUT_DIR/reality-keys.json")
        sid=$(openssl rand -hex 8)
        CERT_DOMAIN="$dom"; TLS_TYPE="reality"
        export T_RE_PRIV="$priv" T_RE_PUB="$pub" T_RE_SID="$sid"
        return 0
    fi
    if [[ "$c" == "2" ]]; then
        local d; d=$(safe_read "自签伪装域名 (统一 domains.sh)" "$(random_domain)")
        mkdir -p "$CERT_DIR"
        CERT_FILE="$CERT_DIR/cert-$d.crt"; KEY_FILE="$CERT_DIR/key-$d.key"
        [[ -f "$CERT_FILE" ]] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
            -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 -subj "/CN=$d" -addext "subjectAltName=DNS:$d" >/dev/null 2>&1
        CERT_DOMAIN="$d"; CERT_TRUSTED=false; return 0
    fi
    read -r -p "crt 路径: " CERT_FILE; read -r -p "key 路径: " KEY_FILE
    CERT_FILE=$(clean_input "$CERT_FILE"); KEY_FILE=$(clean_input "$KEY_FILE")
    [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] || { print_error "证书路径无效"; return 1; }
    CERT_DOMAIN=$(extract_cert_domain "$CERT_FILE"); CERT_TRUSTED=true
}

add_config() {
    print_title "新增 Trojan 节点 ($PROTO-NN.json)"
    local listen_ip listen_port password file tag idx
    listen_ip=$(safe_read "监听地址 (0.0.0.0/::)" "0.0.0.0")
    listen_port=$(safe_read_port)
    password=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
    ask_cert || return 1

    idx=$(get_next_index "$PROTO"); file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"
    local json
    if [[ "${TLS_TYPE:-}" == "reality" ]]; then
        json=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "trojan",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "users": [ { "password": "$password" } ],
      "tls": {
        "enabled": true,
        "server_name": "$CERT_DOMAIN",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$CERT_DOMAIN", "server_port": 443 },
          "private_key": "$T_RE_PRIV",
          "short_id": [ "$T_RE_SID" ]
        }
      }
    }
  ]
}
EOF
)
    else
    json=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "trojan",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "users": [ { "name": "user", "password": "$password" } ],
      "tls": { "enabled": true, "alpn": ["http/1.1"], "certificate_path": "$CERT_FILE", "key_path": "$KEY_FILE" }
    }
  ]
}
EOF
)
    fi
    backup_config config
    write_config "$file" "$json" || return 1
    if ! sb_check; then rm -f "$file"; print_error "已删除非法配置（现网未受影响）"; return 1; fi
    cleanup_node_shares "$tag"
    sb_reload || true

    local server_ip pin="" mode_tls="tls"
    [[ "${TLS_TYPE:-}" == "reality" ]] && mode_tls="reality"
    server_ip=$(safe_read "服务器对外 IP" "$(default_server_ip)")
    if [[ "$CERT_TRUSTED" == "false" ]]; then pin=$(cert_spki_pin_base64 "$CERT_FILE"); fi
    local link
    if [[ "$mode_tls" == "reality" ]]; then
        link="trojan://$password@$server_ip:$listen_port?sni=$CERT_DOMAIN&security=reality&pbk=$T_RE_PUB&sid=$T_RE_SID&type=tcp#$tag"
    else
        link="trojan://$password@$server_ip:$listen_port?sni=$CERT_DOMAIN&alpn=http/1.1${pin:+&pinSHA256=$pin}#$tag"
    fi
    python3 - "$SB_OUT_DIR/sb_client-$tag.json" "$tag" "$server_ip" "$listen_port" "$password" "$CERT_DOMAIN" "$pin" "$mode_tls" "${T_RE_PUB-}" "${T_RE_SID-}" <<'PYGEN'
import json,sys
_,ofile,tag,srv,port,pw,sni,pin,mtype,pub,sid=sys.argv
tls={"enabled":True,"server_name":sni}
if pin: tls["certificate_public_key_sha256"]=pin
out={"type":"trojan","tag":tag,"server":srv,"server_port":int(port),"password":pw,"tls":tls}
if pub and sid:
    # reality: 不需要 certificate, 信任来自 REALITY 密钥对 (sing-box 1.14 OutboundRealityOptions)
    out["tls"]["utls"]={"enabled":True,"fingerprint":"chrome"}
    out["tls"]["reality"]={"enabled":True,"public_key":pub,"short_id":sid}
json.dump({"outbounds":[out]},open(ofile,"w"),indent=2)
PYGEN
    cat > "$SB_OUT_DIR/sb_client-$tag.yaml" <<EOF
proxies:
  - name: $tag
    type: trojan
    server: $server_ip
    port: $listen_port
    password: $password
    sni: $CERT_DOMAIN
EOF
    [[ -n "$pin" ]] && echo "  # 自签: mihomo 需 skip-cert-verify: true" >> "$SB_OUT_DIR/sb_client-$tag.yaml"
    echo "$link" | tee "$SB_OUT_DIR/sb_share-$tag.txt" | tail -1 >&2
    grep -vF "$link" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.$$ && mv /tmp/l.$$ "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >> "$SB_OUT_DIR/sb_links-all.txt"
    echo "{\"tag\":\"$tag\",\"port\":$listen_port,\"pin\":\"$pin\",\"password\":\"$password\"}" | jq . > "$SB_OUT_DIR/sb_meta-$tag.json"
    open_port "$listen_port"
    print_ok "Trojan 节点添加完成: $file"
}

list_configs() {
    print_title "$PROTO 配置"
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        local idx tag port pw
        idx=$(basename "$f" .json | cut -d'-' -f2); tag="${PROTO}${idx}"
        port=$(jq -r '.inbounds[0].listen_port' "$f")
        pw=$(jq -r '.inbounds[0].users[0].password' "$f")
        printf "%s) 端口:%s\n" "$idx" "$port" >&2
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
    rm -f "$file" "$SB_OUT_DIR/sb_share-$tag.txt" "$SB_OUT_DIR/sb_client-$tag.json" "$SB_OUT_DIR/sb_client-$tag.yaml" "$SB_OUT_DIR/sb_meta-$tag.json"
    sb_check && sb_reload || true
    print_ok "已删除 $tag"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        add) add_config ;; list) list_configs ;; del) delete_config ;; check) sb_check ;;
        *) while true; do
            print_title "Trojan 节点管理"
            echo -e "${CYAN}1)${RESET} 添加\n${CYAN}2)${RESET} 列出\n${CYAN}3)${RESET} 删除\n${CYAN}0)${RESET} 返回"
            read -r -p "请选择: " c
            case "$(clean_input "$c")" in 1) add_config ;; 2) list_configs ;; 3) delete_config ;; 0) break ;; esac
            read -r -p "按回车继续..." _ || { echo; exit 0; }
        done ;;
    esac
fi
