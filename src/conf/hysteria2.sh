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
    # 预置方案点名要真证书时, 默认值落到 2 (手动输入路径)
    local hdef=3 hhint=""
    case "${SB_PRESET_CERT:-}" in
        真证书|real) hdef=2; hhint=" (预置方案指定真证书, 请填 crt/key 路径)" ;;
        selfsign)    hhint=" (预置方案指定自签)" ;;
    esac
    [[ -n "$hhint" ]] && echo -e "    ${MAGENTA}${hhint}${RESET}" >&2
    read -r -p "  选择 (默认 ${hdef}): " c
    c=$(clean_input "$c"); [[ -z "$c" ]] && c=$hdef
    sb_batch_tls_override 2 c
    case "$c" in
        2)
            # 批量用 batch 入口选好的证书; 交互模式列出本机证书让你选
            [[ -n "${SB_BATCH:-}" ]] && { sb_apply_batch_cert; return $?; }
            pick_trusted_cert_verbose
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
    server_ip=$(ask_server_addr)
    listen_ip=$(ask_listen_addr)
    listen_port=$(safe_read_port)
    # 端口跳跃: 交互问, 批量读 SB_BATCH_HOP (空=不开)。
    # 之前这两问 (跳跃 + obfs) 只在交互路径存在, 批量生成 (stdin 是 /dev/null)
    # 永远拿到空值 -> 等于恒定关闭, 用户在批量里根本选不到。
    local yn hop=""
    if [[ -n "${SB_BATCH:-}" ]]; then
        hop="${SB_BATCH_HOP:-}"
        [[ -n "$hop" ]] && yn=y || yn=n
    else
        read -r -p "是否开启 UDP 端口跳跃? [y/N]: " yn
    fi
    if [[ "$(clean_input "${yn:-}")" =~ ^[yY] ]]; then
        # 批量下 SB_BATCH_HOP 已经在上面赋过值, 这里不能再走 safe_read ——
        # SB_BATCH 模式下 safe_read 直接返回默认值且不消费输入, 会把用户
        # 选的跳跃范围覆盖成 30000-31000。
        if [[ -n "${SB_BATCH:-}" ]]; then
            hop=$(clean_input "$hop")
            [[ -z "$hop" ]] && hop="30000-31000"
        else
            hop=$(clean_input "$(safe_read "跳跃范围 (如 30000-31000)" "30000-31000")")
        fi
        if [[ "$hop" =~ ^[0-9]+-[0-9]+$ ]]; then
            local s="${hop%-*}" e="${hop#*-}"
            # 建节点前先清掉**同跳跃范围的旧 DNAT 规则**。
            # 否则每建一个节点就多一条指向不同 --to-ports 的规则, 而它们匹配
            # 的是同一个 dport 范围 —— 客户端往跳跃端口发包时 netfilter 取第一
            # 条匹配的规则改道, 包被送到**上一个**节点的真实端口。表现是: 配置
            # 全对、服务端在监听、日志里一条连接都没有, 只有开了跳跃的 HY2
            # 100% 连不通 (实测踩过: 连开 4 个节点后其他节点都正常)。
            while iptables -t nat -C PREROUTING -p udp --dport "$s:$e" -j REDIRECT 2>/dev/null; do
                local _l1
                _l1=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -- "--dport $s:$e -j REDIRECT" | head -1 | sed 's/^-A //')
                [[ -z "$_l1" ]] && break
                iptables -t nat -D $_l1 2>/dev/null || break
            done
            while iptables -t nat -C OUTPUT -p udp --dport "$s:$e" -j REDIRECT 2>/dev/null; do
                local _l2
                _l2=$(iptables -t nat -S OUTPUT 2>/dev/null | grep -- "--dport $s:$e -j REDIRECT" | head -1 | sed 's/^-A //')
                [[ -z "$_l2" ]] && break
                iptables -t nat -D $_l2 2>/dev/null || break
            done
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
            # 防火墙放行整个跳跃范围。ufw 开着 INPUT DROP 时, DNAT 规则
            # 装上了但端口没放行 = 客户端照样连不上 —— 实测踩过: 规则齐全、
            # 服务端监听正常, 客户端就是 timeout, 因为 ufw 把包丢了。
            # 这里只**增加**跳跃范围的放行规则, 不动其他规则。
            if command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null | head -1)" == "Status: active" ]]; then
                # ufw 支持 "起始:终止" 一条规则覆盖整个范围
                ufw allow "$s:$e/udp" >/dev/null 2>&1 \
                    && print_ok "防火墙已放行 UDP $s:$e" \
                    || print_warn "防火墙放行失败 ($s:$e), 需手动: ufw allow $s:$e/udp"
            else
                print_info "ufw 未启用, 无需放行跳跃端口"
            fi
        else
            print_warn "范围格式错误，未开启跳跃"; hop=""
        fi
    fi

    sb_ask_preset hysteria2 "推荐配置"
    ask_cert || return 1

    # ECH (可选): 这三个协议没有 Reality 可选, 内核 ECH 是它们唯一的
    # SNI 隐藏手段。默认关闭; 开启后仅 sing-box 客户端可用 (需内联
    # ECHConfigList, mihomo/Clash 不支持) —— 实测 anytls/hysteria2/tuic
    # 端到端 3/3, 服务端无 "server rejected ECH"。
    # 这三个协议只走直连, 没有 CDN 在中间终结 TLS, 所以固定 direct。
    sb_ask_ech "$CERT_DOMAIN" direct
    local password="" mask="none"
    local oyn
    if [[ -n "${SB_BATCH:-}" ]]; then
        oyn=$(clean_input "${SB_BATCH_OBFS:-}")
        [[ -n "$oyn" ]] && oyn=y || oyn=n
    else
        read -r -p "是否启用 obfs 混淆? [y/N]: " oyn
    fi
    if [[ "$(clean_input "${oyn:-}")" =~ ^[yY] ]]; then
        mask=$(openssl rand -hex 12)
        print_ok "obfs password: $mask"
    fi
    local auth; auth=$(openssl rand -hex 16)

    # 端口跳跃的客户端侧字段: 开了跳跃就要让客户端知道往哪个范围发, 否则
    # 客户端一直打真实端口, 服务端 iptables 的 DNAT 规则形同虚设。
    # sing-box hysteria2 出站用 server_ports (数组, "起:止"), mihomo 用 ports。
    local hop_field=""
    if [[ -n "$hop" && "$hop" =~ ^[0-9]+-[0-9]+$ ]]; then
        # 内核要 "起:止", 不是 "起-止" —— 写成后者直接
        # "initialize outbound[0]: bad port range" (实测)。
        # 用户输入和分享链接的 mport 都用 "起-止", 这里转换一下。
        # 跳跃间隔也写进去。参考 fscarmen/sing-box 的做法: 只给 server_ports
        # 而不给间隔时, sing-box 用内核默认值; 显式给 30s/60s 与分享链接的
        # mport&hop_interval=30s 保持一致, 也让两端行为可预期。
        hop_field=", \"server_ports\": [\"${hop%-*}:${hop#*-}\"], \"hop_interval\": \"30s\", \"hop_interval_max\": \"60s\""
    fi

    local idx file tag json
    idx=$(get_next_index "$PROTO")
    file="$SB_CONFIG_DIR/$PROTO-$idx.json"
    # 名称要在 ECH 定了之后再算 (见 sb_resolve_tag)
    SB_TAG_FORM="tls"; sb_resolve_tag tls
    tag="${PROTO}${idx}$(tag_form_suffix tls "$SB_TAG_EXTRA")"   # 名字体现方案

    local cert_paths_line
    cert_paths_line="\"certificate_path\": \"$CERT_FILE\", \"key_path\": \"$KEY_FILE\""
    # 内核 ECH: 我们自己终结 TLS, 解密 inner ClientHello 靠的就是这把私钥
    local ech_srv; ech_srv=$(sb_ech_json_server)
    local ech_sep=""; [[ -n "$ech_srv" ]] && ech_sep=", $ech_srv"

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
      "tls": { "enabled": true, "alpn": ["h3"], $cert_paths_line$ech_sep }
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
    local pin="" pin_field=""
    # 真证书 (CERT_TRUSTED=true) 时 pin 是空的, 而 pin_field 也必须**整个省略**:
    # 写成 "certificate_public_key_sha256": "" 会让 sing-box 拿一个空 pin 去比对,
    # 报 "unrecognized remote public key" —— 真证书节点直接连不上。
    if [[ "$CERT_TRUSTED" == "false" ]]; then
        pin=$(cert_spki_pin_base64 "$CERT_FILE")
        pin_field=",
        \"certificate_public_key_sha256\": \"$pin\""
    fi
    local link="hysteria2://$auth@$server_ip:$listen_port?${hop:+mport=$hop&}sni=$CERT_DOMAIN&obfs=$( [[ $mask != none ]] && echo salamander || echo none )&obfs-password=$( [[ $mask != none ]] && echo $mask )&alpn=h3"
    [[ "$CERT_TRUSTED" == "false" ]] && link="$link&pinSHA256=$pin"
    link="$link$(sb_ech_link_params)#$tag"
    # 简化: 对标准客户端, 自签统一用 insecure=1 提示, 或者 pin=hex (v2rayN 等)
    # 客户端 ech 片段 (内联完整 ECHCONFIGS PEM; 只有 sing-box 客户端认)。
    # 必须在本 heredoc **之前**算好 —— heredoc 展开时变量若还没赋值就是空的。
    local ech_cli; ech_cli=$(sb_ech_json_client)
    local ech_cli_field=""; [[ -n "$ech_cli" ]] && ech_cli_field=", $ech_cli"

    cat > "$SB_OUT_DIR/sb_client-$tag.json" <<EOF
{
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "$tag",
      "server": "$server_ip",
      "server_port": $listen_port${hop_field},
      "password": "$auth",
      "up_mbps": 100,
      "down_mbps": 500,
      "obfs": { "type": "salamander", "password": "$mask" },
      "tls": {
        "enabled": true,
        "server_name": "$CERT_DOMAIN",
        "alpn": ["h3"]$pin_field$ech_cli_field
      }
    }
  ]
}
EOF

    [[ "$mask" == "none" ]] && { jq 'del(.outbounds[0].obfs)' "$SB_OUT_DIR/sb_client-$tag.json" > /tmp/hyc.$$ && mv /tmp/hyc.$$ "$SB_OUT_DIR/sb_client-$tag.json" ; }
    mkdir -p "$SB_OUT_DIR"
    echo "{\"tag\":\"$tag\",\"port\":$listen_port,\"hop\":\"$hop\",\"cert\":\"$CERT_FILE\",\"cert_trusted\":$CERT_TRUSTED,\"auth\":\"$auth\",\"mask\":\"$mask\"}" | jq . > "$SB_OUT_DIR/sb_meta-$tag.json"
    echo "$link" > "$SB_OUT_DIR/sb_share-$tag.txt"
    grep -vF "$link" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.$$ && mv /tmp/l.$$ "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >> "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >&2
    open_port "$listen_port"
    print_ok "Hysteria2 节点添加完成: $file"
    # 重建聚合: 新节点不在 sb_client-all.json 里的话, 分享链接
    # (菜单3 / all-share URL) 下发的还是旧节点列表。
    declare -F sb_regen_aggregate >/dev/null 2>&1 && sb_regen_aggregate
    gen_mihomo_yaml "$tag"
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
    read -r -p "确认删除编号 $num ($PROTO) 的节点? [y/N]: " dconfirm
    [[ "$(clean_input "$dconfirm")" =~ ^[yY] ]] || { print_warn "已取消"; return 0; }
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
    # 重建聚合产物: 少了这一步, sb_client-all.json 里会一直留着
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
                read -r -p "按回车继续..." _ || { echo; exit 0; }
            done
            ;;
    esac
fi
