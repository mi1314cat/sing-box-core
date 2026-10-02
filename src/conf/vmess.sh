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
    # 批量 CDN: 必须真证书 (自签 Cloudflare 不接受; no-TLS 裸 ws 也走不了 CDN)
    if [[ "${SB_BATCH:-}" == "1" && "${SB_BATCH_CDN:-0}" == "1" ]]; then
        if sb_batch_cdn_pick_cert; then
            echo "real|$CERT_FILE|$KEY_FILE|$CERT_DOMAIN"
            return 0
        fi
        print_warn "批量 CDN: 未找到可用真证书, 退回 no-TLS (该节点只能直连)"
    fi
    echo "TLS 选项: 1) no-TLS(裸 ws) 2) 真证书 3) 自签(pin) 4) Reality (回车=1 no-TLS)" >&2
    # 批量生成 Reality 变体时由 batch 显式指定 (依赖应答串会因 safe_read 不消费
    # 队列而整体错位, 见 batch.sh 注释)。只替换交互输入, 复用下方原有分支。
    local c
    if [[ "${SB_FORCE_TLS_REALTY:-}" == "1" ]]; then c=4
    else
        read -r -p "选择 (默认 1): " c
        c=$(clean_input "$c"); [[ -z "$c" ]] && c=1
    fi
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

    # 不用 read 解析: batch 模式会重定义 read 并无视 herestring (旧写法导致
    # Reality 变体静默退化成无 TLS)。这里用纯参数展开, 对 read 覆盖免疫。
    local _tls; _tls=$(ask_tls)
    CERT_MODE="${_tls%%|*}"; _tls="${_tls#*|}"
    CERT_FILE="${_tls%%|*}"; _tls="${_tls#*|}"
    KEY_FILE="${_tls%%|*}";  CERT_DOMAIN="${_tls#*|}"
      
    # 接入方式必须在证书与传输都定下来之后问:
    #   - 自签证书 Cloudflare 一定拒绝回源, 问 CDN 没有意义
    #   - 传输不是 ws/grpc/http 时也没有 CDN 可用
    # 而监听地址由它决定 (CDN+Nginx 必须只听 127.0.0.1), 所以放在这里。
    #
    # 以前 vmess 根本没有这一步: 开头就直接问监听地址, ACCESS_MODE 恒为空。
    # 而 sb_cdn_finalize 里 ${ACCESS_MODE:-cdn-nginx} 会默认按 CDN+Nginx 处理,
    # 于是任何 ws + 真证书的 vmess 节点都被悄悄改成只听 127.0.0.1、客户端连
    # CDN 域名 —— 但 nginx 里并没有对应的 location, 节点彻底连不上,
    # 界面上也看不出任何异常。比直接报错更难排查。
    # 值必须是 "yes"/"no": ask_access_mode 内部判断的是 [[ "$trusted" == "yes" ]]。
    # 传 "true" 永远匹配不上, 于是 CDN 选项根本不出现, ACCESS_MODE 恒为空 ——
    # 而 sb_cdn_finalize 里 ${ACCESS_MODE:-cdn-nginx} 会默认按 CDN+Nginx 处理,
    # 结果节点只听 127.0.0.1、客户端连 CDN 域名, 而 nginx 里什么都没有。
    local _trusted="no"
    [[ "${CERT_MODE:-}" == "real" && -n "$CERT_FILE" ]] && _trusted="yes"
    ACCESS_MODE=""
    ask_access_mode "$ttype" "$_trusted"
    case "$ACCESS_MODE" in
        cdn)        listen_ip="0.0.0.0" ;;
        cdn-nginx)  listen_ip="127.0.0.1" ;;
        *)          listen_ip=$(ask_listen_addr) ;;
    esac
      
    local uuid; uuid=$(cat /proc/sys/kernel/random/uuid)
    local REAL_PRIV REAL_PUB
    if [[ "$CERT_MODE" == "reality" ]]; then
        . "$SB_OUT_DIR/reality-keys.json" 2>/dev/null || true
        [[ -f "$SB_OUT_DIR/reality-keys.json" ]] && REAL_PRIV=$(jq -r .private_key "$SB_OUT_DIR/reality-keys.json") && REAL_PUB=$(jq -r .public_key "$SB_OUT_DIR/reality-keys.json")
        [[ -z "$REAL_PRIV" ]] && { kp=$("$SB_BIN" generate reality-keypair); REAL_PRIV=$(echo "$kp"|grep -oP '^PrivateKey: \K.*'); REAL_PUB=$(echo "$kp"|grep -oP '^PublicKey: \K.*'); echo "{\"private_key\":\"$REAL_PRIV\",\"public_key\":\"$REAL_PUB\"}"|jq .>"$SB_OUT_DIR/reality-keys.json"; }
        local rnd; rnd=$(reality_random_domain)
        local sid; sid=$(openssl rand -hex 8)
    fi
    local sid="${sid:-}"  # 保证 PYGEN 位置参数在非 reality 模式下也定义为空

    local idx file tag json
    idx=$(get_next_index "$PROTO"); file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"
    # 名字体现传输方式: ask_tls 决定 reality / selfsign / real / none
    case "${CERT_MODE:-none}" in
        reality)       tag="$tag$(tag_form_suffix reality)" ;;
        selfsign|real) tag="$tag$(tag_form_suffix tls)" ;;
        *)             tag="$tag$(tag_form_suffix plain)" ;;
    esac

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
    cleanup_node_shares "$tag"
    sb_reload || true

    # server对外IP / 客户端
    local server_ip; server_ip=$(ask_server_addr)

    local DOM="$CERT_DOMAIN"; [[ "${CERT_MODE:-}" == "reality" ]] && DOM="$rnd"
    local pbk sidq urlsec secpin=""
    # CDN 节点只监听 127.0.0.1, 客户端连证书域名而非服务器 IP
    server_ip=$(sb_cdn_finalize "$file" "$server_ip")
    # CDN 只在 443 上提供服务; 沿用源站端口会得到连不通的 域名:源站端口
    sb_node_is_cdn "$file" && listen_port=443
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
    local utls_fp; utls_fp=$(ask_utls_fingerprint)
    export SB_UTLS_FP="$utls_fp"
    python3 - "$SB_OUT_DIR/sb_client-$tag.json" "$tag" "$server_ip" "$listen_port" "$uuid" "$CERT_MODE" "$CERT_DOMAIN" "$ttype" "$tpath" "$svc" "$secpin" "$REAL_PUB" "$sid" "$CERT_FILE" "$DOM" <<'PYGEN'
import json,sys,os
_,ofile,tag,srv,port,uuid,mode,domain,ttype,tpath,svc,pin,pbk,xsid,crt,dom2=sys.argv
ob={"type":"vmess","tag":tag,"server":srv,"server_port":int(port),"uuid":uuid,"alter_id":0}
if ttype=="ws": ob["transport"]={"type":"ws","path":tpath}
if ttype=="grpc": ob["transport"]={"type":"grpc","service_name":svc}
if ttype=="http": ob["transport"]={"type":"http"}
if mode=="real":
    sn = os.popen(f'openssl x509 -in {crt} -noout -ext subjectAltName 2>/dev/null | grep -oE "DNS:[^,]+" | head -1 | cut -d: -f2').read().strip()
    ob["tls"]={"enabled":True,"insecure":True,"server_name": sn or domain,"utls":{"enabled":True,"fingerprint":os.environ.get("SB_UTLS_FP","chrome")}}
elif mode=="selfsign":
    ob["tls"]={"enabled":True,"insecure":True,"server_name":dom2,
               "certificate_public_key_sha256":pin,
               "utls":{"enabled":True,"fingerprint":os.environ.get("SB_UTLS_FP","chrome")}}
elif mode=="reality":
    ob["tls"]={"enabled":True,"server_name":dom2,"utls":{"enabled":True,"fingerprint":os.environ.get("SB_UTLS_FP","chrome")},
               "reality":{"enabled":True,"public_key":pbk,"short_id":xsid}}
json.dump({"outbounds":[ob]},open(ofile,"w"),indent=2)
PYGEN
    echo "$url" | tee "$SB_OUT_DIR/sb_share-$tag.txt" | tail -1 >&2
    if [[ -n "$url" ]]; then
        grep -vF "$url" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.$$ && mv /tmp/l.$$ "$SB_OUT_DIR/sb_links-all.txt"
        echo "$url" >> "$SB_OUT_DIR/sb_links-all.txt"
    fi
    echo "{\"tag\":\"$tag\",\"port\":$listen_port,\"mode\":\"$CERT_MODE\",\"path\":\"$tpath\",\"svc\":\"$svc\"}" | jq . > "$SB_OUT_DIR/sb_meta-$tag.json"
    # CDN 节点只监听 127.0.0.1, 源站端口不对外暴露, **不需要放行防火墙**;
    # 而且此时 listen_port 已被改成 443 (客户端侧端口), 直接拿去 open_port
    # 会给 443 加放行规则 —— 那是用户 nginx 的端口, 与节点无关。
    # 所以这里一律放行源站真实端口, 且 CDN 模式跳过。
    local _fw_port
    _fw_port=$(jq -r '.inbounds[0].listen_port // empty' "$file" 2>/dev/null)
    sb_node_is_cdn "$file" || open_port "$_fw_port"
    print_ok "VMess 节点添加完成: $file"
    # 重建聚合: 新节点不在 sb_client-all.json 里的话, 分享链接
    # (菜单3 / all-share URL) 下发的还是旧节点列表。
    declare -F sb_regen_aggregate >/dev/null 2>&1 && sb_regen_aggregate
      # 走 CDN 的节点, 客户端连的是域名:443, nginx 里必须有对应的 location。
      # 之前单协议路径**什么都不提示**, 节点看着生成成功, 却因为 nginx 没配而
      # 连不上, 用户完全无从查起。这里直接自动配好。
      [[ "${ACCESS_MODE:-}" == cdn* ]] && sb_cdn_autosetup
    gen_mihomo_yaml "$tag"

    # CDN 节点额外产出 .cdn 版产物 (连域名走 Cloudflare), 与直连版并存
    if sb_cdn_enabled "$file"; then
        cdn_node_gen_all "$tag" >/dev/null 2>&1 || true
    fi
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
        *) while true; do
            print_title "VMess 节点管理"
            echo -e "${CYAN}1)${RESET} 添加\n${CYAN}2)${RESET} 列出\n${CYAN}3)${RESET} 删除\n${CYAN}0)${RESET} 返回"
            read -r -p "请选择: " c
            case "$(clean_input "$c")" in 1) add_config ;; 2) list_configs ;; 3) delete_config ;; 0) break ;; esac
            read -r -p "按回车继续..." _ || { echo; exit 0; }
        done ;;
    esac
fi
