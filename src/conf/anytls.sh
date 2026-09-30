#!/bin/bash
# ==============================================================
# anytls.sh — AnyTLS 节点模块 (含 REALITY 选配)
#
# 历史: 本模块原为"纯 AnyTLS"(不含 REALITY), anyreality.sh 单独管
# AnyTLS+REALITY。现在两者合并 —— 同一个协议, 只是 TLS 模式不同,
# 拆两个模块/两套编号让用户每次都要先想"我该用哪个"。
# 现在统一为一个入口, 证书选配方式与 trojan.sh 完全一致:
#     1) 真证书    2) 自签(pin)    3) Reality
#
# 关键约束 (决定了为什么要拆出纯 AnyTLS 这一支):
#   mihomo/Clash **明确不支持 AnyTLS+REALITY**
#   (官方原文: "Mihomo does not support AnyTLS+Reality, and will not
#   support this combination in the future")。
#   所以选 1)/2) 出来的节点两端都能用; 选 3) 只能给 sing-box 客户端,
#   不会产出 mihomo YAML。
#
# 迁移: 旧的 anyreality-NN.json 会在进入菜单时自动改名为 anytls-NN.json
#       (编号取空位, 端口/证书/密钥全保留, 旧分享链接继续可用)。
# CLI: bash anytls.sh [add|list|del]
# 指纹: uTLS 指纹走 lib.sh 的 ask_utls_fingerprint 选配 (默认 chrome)
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="anytls"
CERT_DIR="$SB_ROOT/cert"
REALITY_KEYS_FILE="$SB_OUT_DIR/reality-keys.json"

# REALITY 长期密钥对与 reality.sh 共享 (不重复生成)
ensure_reality_keys() {
    if [[ -f "$REALITY_KEYS_FILE" ]]; then
        local p u
        p=$(jq -r '.private_key // empty' "$REALITY_KEYS_FILE")
        u=$(jq -r '.public_key  // empty' "$REALITY_KEYS_FILE")
        [[ -n "$p" && -n "$u" ]] && { REAL_PRIV="$p"; REAL_PUB="$u"; return 0; }
    fi
    local kp
    kp=$("$SB_BIN" generate reality-keypair 2>/dev/null)
    REAL_PRIV=$(echo "$kp" | grep -oP '^PrivateKey: \K.*')
    REAL_PUB=$(echo  "$kp" | grep -oP '^PublicKey: \K.*')
    [[ -n "$REAL_PRIV" && -n "$REAL_PUB" ]] || { print_error "REALITY 密钥生成失败"; return 1; }
    echo "{\"private_key\":\"$REAL_PRIV\",\"public_key\":\"$REAL_PUB\"}" | jq . > "$REALITY_KEYS_FILE"
    print_ok "REALITY 密钥已生成: $REALITY_KEYS_FILE"
}

extract_cert_domain() {
    local crt="$1" dom=""
    command -v openssl >/dev/null && [[ -f "$crt" ]] && dom=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -oE "DNS:[^,]+" | head -1 | cut -d: -f2)
    [[ -z "$dom" ]] && dom=$(basename "$crt" | sed -E 's/\.(crt|pem)$//; s/^cert-//')
    echo "$dom"
}

ask_cert() {  # 输出 CERT_FILE/KEY_FILE/CERT_DOMAIN/CERT_TRUSTED, 或 TLS_TYPE=reality + T_RE_*
    local c
    echo "TLS 模式: 1) 真证书  2) 自签(pin)  3) Reality [默认 2]" >&2
    echo "  (选 3 = AnyTLS+REALITY, 仅 sing-box 客户端可用; mihomo/Clash 不支持该组合)" >&2
    if [[ -n "${SB_BATCH:-}" ]]; then c=2; else
        read -r -p "选择: " c; c=$(clean_input "$c"); [[ -z "$c" ]] && c=2
    fi
    if [[ "$c" == "3" ]]; then
        local d sid
        d=$(safe_read "Reality 握手目标 (统一 domains.sh)" "$(reality_random_domain)")
        ensure_reality_keys || return 1
        sid=$(openssl rand -hex 8)
        CERT_DOMAIN="$d"; CERT_TRUSTED=false; TLS_TYPE="reality"
        T_RE_PRIV="$REAL_PRIV"; T_RE_PUB="$REAL_PUB"; T_RE_SID="$sid"
        return 0
    fi
    TLS_TYPE="tls"
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
    if [[ "${TLS_TYPE:-tls}" == "reality" ]]; then
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
    fi
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
    local link
    if [[ "${TLS_TYPE:-tls}" == "reality" ]]; then
        link="anytls://$password@$server_ip:$listen_port?sni=$CERT_DOMAIN&insecure=0&pbk=$T_RE_PUB&sid=$T_RE_SID#$tag"
    elif [[ "$CERT_TRUSTED" == "true" ]]; then
        link="anytls://$password@$server_ip:$listen_port?sni=$CERT_DOMAIN&insecure=0#$tag"
    else
        link="anytls://$password@$server_ip:$listen_port?sni=$CERT_DOMAIN&insecure=1${pin:+&pinSHA256=$pin}#$tag"
    fi

    local utls_fp; utls_fp=$(ask_utls_fingerprint)
    python3 - "$utls_fp" "$SB_OUT_DIR/sb_client-$tag.json" "$tag" "$server_ip" "$listen_port" \
        "$password" "$CERT_DOMAIN" "$pin" "${TLS_TYPE:-tls}" "${T_RE_PUB-}" "${T_RE_SID-}" <<'PYGEN'
import json,sys
_,fp,ofile,tag,srv,port,pw,sni,pin,mode,pub,sid=sys.argv
if mode=="reality":
    tls={"enabled":True,"server_name":sni,
         "utls":{"enabled":True,"fingerprint":fp},
         "reality":{"enabled":True,"public_key":pub,"short_id":sid}}
else:
    tls={"enabled":True,"server_name":sni,"alpn":["h2","http/1.1"],
         "utls":{"enabled":True,"fingerprint":fp}}
    if pin: tls["certificate_public_key_sha256"]=pin
out={"type":"anytls","tag":tag,"server":srv,"server_port":int(port),"password":pw,"tls":tls}
json.dump({"outbounds":[out]},open(ofile,"w"),indent=2)
PYGEN

    # mihomo 单节点 YAML —— 仅非 Reality 形态产出。
    # mihomo/Clash 不支持 AnyTLS+Reality, 生成了也是一份用不了的配置。
    rm -f "$SB_OUT_DIR/sb_client-$tag.yaml"
    if [[ "${TLS_TYPE:-tls}" != "reality" ]]; then
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
    else
        print_warn "Reality 形态: 已跳过 mihomo YAML (mihomo/Clash 不支持 AnyTLS+Reality)"
    fi

    echo "$link" > "$SB_OUT_DIR/sb_share-$tag.txt"
    grep -vF "$link" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.$$ && mv /tmp/l.$$ "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >> "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >&2
    echo "{\"tag\":\"$tag\",\"port\":$listen_port,\"password\":\"$password\",\"pin\":\"$pin\",\"tls_mode\":\"${TLS_TYPE:-tls}\",\"utls_fingerprint\":\"$utls_fp\"}" | jq . > "$SB_OUT_DIR/sb_meta-$tag.json"
    open_port "$listen_port"
    print_ok "AnyTLS 节点添加完成: $file"
    if [[ "${TLS_TYPE:-tls}" == "reality" ]]; then
        print_warn "提示: AnyTLS+REALITY 形态, 仅 sing-box 客户端可用 (mihomo/Clash 不支持)"
    else
        print_warn "提示: AnyTLS 形态, sing-box 与 mihomo/Clash 都能用 (uTLS 指纹: $utls_fp)"
    fi
}

# 旧 anyreality-NN.json → anytls-NN.json 自动改名迁移。
# 只改名, 不动内容: 端口/证书/REALITY 密钥/分享链接全部保持有效。
migrate_legacy_anyreality() {
    local -a olds=( "$SB_CONFIG_DIR"/anyreality-*.json )
    local f target n
    for f in "${olds[@]}"; do
        [[ -f "$f" ]] || continue
        n=$(basename "$f" .json | cut -d'-' -f2)
        target="$SB_CONFIG_DIR/anytls-$n.json"
        if [[ -e "$target" ]]; then
            # 编号已占用: 往后找一个空位
            local k
            for k in $(seq -w 1 99); do
                [[ -e "$SB_CONFIG_DIR/anytls-$k.json" ]] || { target="$SB_CONFIG_DIR/anytls-$k.json"; break; }
            done
        fi
        if mv "$f" "$target"; then
            local ot nt
            ot=$(basename "$f" .json | tr -d '-'); nt=$(basename "$target" .json | tr -d '-')
            # 文件名改了, 配置内部的 inbound tag 也必须跟着改, 且必须按
            # **目标文件名**推导 —— 目标编号可能与源编号不同 (源 01 被占用时会挪到 02)。
            # 早先版本误用源编号 n, 结果两个文件的 tag 都变成 anytls01,
            # sing-box check 直接因 tag 重复失败。
            local newtag="$nt" tmpj
            if [[ -f "$target" ]]; then
                tmpj=$(mktemp)
                if jq --arg t "$newtag" '(.inbounds[]? | select(.tag != null) | .tag) = $t' \
                       "$target" > "$tmpj" 2>/dev/null && [[ -s "$tmpj" ]]; then
                    mv -f "$tmpj" "$target"
                else
                    rm -f "$tmpj"
                fi
            fi
            # 客户端产物跟着改名, 否则旧 tag 的产物会变成孤儿
            for ext in json yaml; do
                [[ -f "$SB_OUT_DIR/sb_client-$ot.$ext" ]] && mv -f "$SB_OUT_DIR/sb_client-$ot.$ext" "$SB_OUT_DIR/sb_client-$nt.$ext"
            done
            [[ -f "$SB_OUT_DIR/sb_share-$ot.txt" ]] && mv -f "$SB_OUT_DIR/sb_share-$ot.txt" "$SB_OUT_DIR/sb_share-$nt.txt"
            [[ -f "$SB_OUT_DIR/sb_meta-$ot.json" ]] && mv -f "$SB_OUT_DIR/sb_meta-$ot.json" "$SB_OUT_DIR/sb_meta-$nt.json"
            # share 元数据里的 tag 也要跟着改
            [[ -d "$SB_ROOT/share/shares" ]] && grep -l "\"tag\": \"*$ot\"" "$SB_ROOT/share/shares"/*.json 2>/dev/null | \
                xargs -r sed -i "s/\"tag\": \"$ot\"/\"tag\": \"$nt\"/"
            print_ok "已迁移: $(basename "$f") → $(basename "$target")  (端口/密钥/链接均不变)"
        fi
    done
    # 旧入口文件不再使用, 留个提示桩避免有人直接调用报错
    return 0
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
                migrate_legacy_anyreality
                print_title "AnyTLS 节点管理 (可选 REALITY)"
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
