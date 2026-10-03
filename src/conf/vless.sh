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
    echo "  3) Reality (无证书, 借用真实站点 TLS 握手)" >&2
    local c f k
    # 预置方案本身就叫 "Reality 预置", 所以默认落在 3 而不是自签 ——
    # 一路回车才是名副其实的"一键生成"。
    local cert_def=2 cert_hint=""
    case "${SB_PRESET_CERT:-}" in
        reality)  cert_def=3; cert_hint=" (预置方案指定 Reality)" ;;
        selfsign) cert_def=2; cert_hint=" (预置方案指定自签 + ECH)" ;;
    esac
    [[ -n "$cert_hint" ]] && echo -e "    ${MAGENTA}${cert_hint}${RESET}" >&2
    read -r -p "  选择 (回车=${cert_def}): " c
    c=$(clean_input "$c"); [[ -z "$c" ]] && c=$cert_def
    if [[ "$c" == "3" ]]; then
        local kp rnd sid
        [[ -f "$SB_OUT_DIR/reality-keys.json" ]] && {
            REAL_PRIV=$(jq -r .private_key "$SB_OUT_DIR/reality-keys.json")
            REAL_PUB=$(jq -r .public_key "$SB_OUT_DIR/reality-keys.json")
        }
        [[ -z "${REAL_PRIV:-}" ]] && {
            mapfile -t kp < <("$SB_BIN" generate reality-keypair 2>/dev/null | awk -F': ' '/PrivateKey/{print $2}')
            [[ ${#kp[@]} -ge 1 ]] && { REAL_PRIV="${kp[0]}"; REAL_PUB="${kp[1]}"; }
        }
        [[ -z "${REAL_PRIV:-}" ]] && { print_err "无法生成 Reality 密钥对"; return 1; }
        mkdir -p "$SB_OUT_DIR"
        printf '{"private_key":"%s","public_key":"%s"}\n' "$REAL_PRIV" "$REAL_PUB" \
            > "$SB_OUT_DIR/reality-keys.json"
        rnd=$(reality_random_domain)
        sid=$(sb_real_shortid)
        # Reality 的 server_name 就是握手目标 —— 客户端拿它当 SNI, 服务端拿它
        # 转发 TLS。必须是**真实可解析**的域名, 解析不了服务端会直接拒绝。
        [[ -z "${rnd}" ]] && { print_err "Reality 目标域名池为空"; return 1; }
        CERT_DOMAIN="$rnd"; REAL_SID="$sid"; CERT_MODE="reality"
        CERT_FILE=""; KEY_FILE=""; CERT_TRUSTED=false
        return 0
    fi
    CERT_MODE="real"
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
    print_title "新增 VLESS 节点 ($PROTO-NN.json)"
    local server_ip listen_ip listen_port uuid idx file tag json
    server_ip=$(ask_server_addr)
    listen_port=$(safe_read_port)
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
    # 预置方案放在最前面: 它同时决定传输层/流控/证书, 先问它, 后面
    # 每一步才能给出正确的默认值 / 正确地关掉互斥项。
    sb_ask_preset vless "Reality 预置方案"
    # 传输先问: ws/grpc/http/httpupgrade 四种 HTTP 类传输都能走 CDN, 裸 TCP 不能。
    SB_PRESET_TR_HINT=$(sb_preset_transport_hint)
    sb_ask_transport
    sb_warn_reality_transport "$TR_TYPE"
    ask_cert || return 1
    sb_warn_reality_transport "${TR_TYPE:-}" "${CERT_MODE:-${TLS_TYPE:-}}"
    # http 传输的 host 用证书域名 —— sing-box 会拿它做 Host 校验
    [[ -z "$TR_HOST" ]] && TR_HOST="$CERT_DOMAIN"

    # Reality 与 CDN 互斥: Cloudflare 在边缘就终止了 TLS, 端到端的 Reality
    # 握手被中间一跳打断必然失败 (实测 fscarmen 脚本的 Reality 节点也一律
    # 走直连端口)。所以 Reality 变体强制直连, 连问都不问。
    local trusted="no" ACCESS_MODE="direct"
    if [[ "${CERT_MODE:-}" != "reality" ]]; then
    # 判定"是否真证书"必须用 lib.sh 里已有的能力, 不能调 cdn.sh 的函数
    # (protocol 脚本不一定加载了 cdn.sh, 调不到就等于"不是真证书" -> CDN 选项被藏)
    sb_key_for "$CERT_FILE" >/dev/null 2>&1 && \
        cert_not_expired "$CERT_FILE" && \
        sb_cert_is_real_issuer "$CERT_FILE" && trusted="yes"
    # ask_access_mode 把结果写进全局 ACCESS_MODE (不靠 stdout):
    # 命令替换会让函数里的 read 跑在子 shell 上, stdin 可能已耗尽,
    # 结果是"明明选了 CDN+Nginx 却还在问监听地址"。
    ask_access_mode "$TR_TYPE" "$trusted"
    fi
    # XTLS Vision 流控 —— Reality 的正路, 与 multiplex **互斥**。
    # 必须排在 sb_ask_multiplex 前面: 后者会读 FLOW 决定要不要放行 mux 菜单。
    # 有传输层时 sb_flow_conflict 会直接跳过提问 (vision + ws 运行时必然失败)。
    if [[ "${CERT_MODE:-}" == "reality" ]]; then
        if [[ -n "${SB_PRESET_FLOW:-}" ]]; then
            FLOW="$SB_PRESET_FLOW"; print_ok "flow: $FLOW (预置方案指定)"
        else
            sb_ask_flow "$CERT_MODE" "$TR_TYPE"
        fi
    else
        FLOW=""
    fi
    # multiplex 仅 VLESS/VMess/Trojan/SS 支持; 服务端侧无 protocol 字段, 由内核自动识别
    sb_ask_multiplex vless server; mux_json=$(sb_mux_json_server)
    case "$ACCESS_MODE" in
        cdn)        listen_ip="0.0.0.0" ;;
        cdn-nginx)  listen_ip="127.0.0.1" ;;
        *)          listen_ip=$(ask_listen_addr) ;;
    esac

    idx=$(get_next_index "$PROTO"); file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"
    # Reality 变体的名字要带 -REALITY —— tag 会写进 inbound 和客户端产物,
    # 名字里能一眼看出这个节点是 Reality 才不会在管理界面里混淆。
    if [[ "${CERT_MODE:-}" == "reality" ]]; then
        tag="$tag$(tag_form_suffix reality "${SB_PRESET_TAG:-}")"
    else
        tag="$tag$(tag_form_suffix tls "${SB_PRESET_TAG:-}")"
    fi
    local tls_line alpn tr_json tr_line="" mux_line="" user_flow=""
    alpn=$(sb_transport_alpn "$TR_TYPE")
    user_flow=$(sb_flow_json_user)     # Reality + vision 时给 users[] 加 flow
    if [[ "${CERT_MODE:-}" == "reality" ]]; then
        # Reality 不需要证书文件, 信任来自密钥对; handshake.server 必须真实
        # 可解析 (解析不了服务端会直接 reject, 见 fscarmen 的做法)。
        tls_line="\"enabled\": true, \"server_name\": \"$CERT_DOMAIN\", \"reality\": { \"enabled\": true, \"handshake\": { \"server\": \"$CERT_DOMAIN\", \"server_port\": 443 }, \"private_key\": \"$REAL_PRIV\", \"short_id\": [ \"$REAL_SID\" ] }"
    else
        tls_line="\"enabled\": true, \"certificate_path\": \"$CERT_FILE\", \"key_path\": \"$KEY_FILE\", \"alpn\": $alpn"
    fi
    # ECH 只在 CDN 模式问 (直连时加密自己的 SNI 没有收益, 还多一份 config 要维护);
    # Reality 与 CDN 互斥, 这里不会命中。
    if [[ "${CERT_MODE:-}" != "reality" ]]; then
        sb_ask_ech "$CERT_DOMAIN" "${ACCESS_MODE:-direct}"
        local ech_srv=$(sb_ech_json_server)
        [[ -n "$ech_srv" ]] && tls_line="$tls_line, $ech_srv"
    fi
    # 裸 TCP: sing-box 里不存在 "type":"tcp", 必须**整个省略 transport 字段。
    # 整行一起加/去 —— 只在字段之间插逗号会出现 ",," 这种双逗号。
    tr_json=$(sb_transport_json_server "$TR_TYPE" "$TR_PATH" "$TR_SVC" "$TR_HOST")
    # 注意 sb_transport_json_server 返回的是**值**, "transport" 这个键要在这里补上
    [[ -n "$tr_json" ]] && tr_line="      \"transport\": $tr_json,
"
    # tr_line 已经带尾逗号, 所以这里直接接空格, 不再补逗号
    [[ -n "$mux_json" ]] && mux_line=" $mux_json,"

    json=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "users": [ { "name": "user", "uuid": "$uuid"$user_flow } ],
$tr_line$mux_line      "tls": { $tls_line }
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
    local link_params utls_fp ctr_json ctr_sep=""
    # 公共参数已在服务端那一步问过 (sb_ask_multiplex / sb_ask_ech),
    # 这里只按同一个决定分别渲染, 不再问第二遍 —— 同一个问题问两次、
    # 两次菜单文案还完全一样, 极易答错导致双端不一致。
    local muxc=$(sb_mux_json_client)
    local ech_cli=$(sb_ech_json_client)
    sb_ask_fragment "${mode_tls:-$TLS_TYPE}"; local frag_cli=$(sb_fragment_json_client)
    local fr_link; fr_link=$(sb_fragment_link_params)
    link_params=$(sb_transport_link_params "$TR_TYPE" "$TR_PATH" "$TR_SVC" "$TR_HOST")
    # 裸 TCP 客户端同样不能写 "transport":{} —— sing-box 会当成空类型报错
    ctr_json=$(sb_transport_json_client "$TR_TYPE" "$TR_PATH" "$TR_SVC" "$TR_HOST")
    # 同样: 函数返回的是**值**, "transport" 键要在这里补
    [[ -n "$ctr_json" ]] && ctr_sep=",
      \"transport\": $ctr_json"
    local mux_link ech_link
    mux_link=$(sb_mux_link_params); ech_link=$(sb_ech_link_params)
    # Reality 客户端的 tls 块与证书形态完全不同: 要 pbk/sid, 不要
    # certificate_path 也不需要 insecure/pin —— 信任由公钥校验建立。
    # uTLS 指纹必须在拼链接**之前**问 (两条分支都要用到 fp), 所以统一提前。
    utls_fp=$(ask_utls_fingerprint)
    local tls_cli flow_link="" flow_cli="" link
    if [[ -n "$FLOW" ]]; then
        flow_cli=", \"flow\": \"$FLOW\""      # outbound 顶层 (JSON)
        flow_link="&flow=$FLOW"              # 分享链接 (URL query)
    fi
    if [[ "${CERT_MODE:-}" == "reality" ]]; then
        tls_cli="\"enabled\": true, \"server_name\": \"$CERT_DOMAIN\", \"utls\": { \"enabled\": true, \"fingerprint\": \"$utls_fp\" }, \"reality\": { \"enabled\": true, \"public_key\": \"$REAL_PUB\", \"short_id\": \"$REAL_SID\" }${frag_cli:+, $frag_cli}"
        link="vless://$uuid@$server_ip:$listen_port?encryption=none&security=reality&sni=$CERT_DOMAIN&fp=$utls_fp&pbk=$REAL_PUB&sid=$REAL_SID$link_params$flow_link$fr_link#$tag"
    else
        tls_cli="\"enabled\": true, \"server_name\": \"$CERT_DOMAIN\", \"insecure\": $( [[ "$CERT_TRUSTED" == "true" ]] && echo false || echo true ), \"utls\": { \"enabled\": true, \"fingerprint\": \"$utls_fp\" }${ech_cli:+, $ech_cli}${frag_cli:+, $frag_cli}"
        link="vless://$uuid@$server_ip:$listen_port?encryption=none&security=tls&sni=$CERT_DOMAIN$link_params$mux_link$ech_link$fr_link#$tag"
    fi
    cat > "$SB_OUT_DIR/sb_client-$tag.json" <<EOF
{
  "outbounds": [
    { "type": "vless", "tag": "$tag", "server": "$server_ip", "server_port": $listen_port,
      "uuid": "$uuid"$flow_cli,
      "tls": { $tls_cli }$ctr_sep${muxc:+,
        $muxc} }
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
    # CDN 节点只监听 127.0.0.1, 源站端口不对外暴露, **不需要放行防火墙**;
    # 而且此时 listen_port 已被改成 443 (客户端侧端口), 直接拿去 open_port
    # 会给 443 加放行规则 —— 那是用户 nginx 的端口, 与节点无关。
    # 所以这里一律放行源站真实端口, 且 CDN 模式跳过。
    local _fw_port
    _fw_port=$(jq -r '.inbounds[0].listen_port // empty' "$file" 2>/dev/null)
    sb_node_is_cdn "$file" || open_port "$_fw_port"
    print_ok "VLESS 节点添加完成: $file"
    # 重建聚合: 新节点不在 sb_client-all.json 里的话, 分享链接
    # (菜单3 / all-share URL) 下发的还是旧节点列表。
    declare -F sb_regen_aggregate >/dev/null 2>&1 && sb_regen_aggregate
      # 走 CDN 的节点, 客户端连的是域名:443, nginx 里必须有对应的 location。
      # 之前单协议路径**什么都不提示**, 节点看着生成成功, 却因为 nginx 没配而
      # 连不上, 用户完全无从查起。这里直接自动配好。
      #
      # 必须写成 if 而不是 [[ ... ]] && ...: 后者条件不成立时整条语句返回 1,
      # 而它又是本函数的最后一句, 于是 add_config 的退出码变成 1 —— 批量生成
      # 里表现为"vless 失败", 但配置其实早就写好了, 极具迷惑性。
      if [[ "${ACCESS_MODE:-}" == cdn* ]]; then sb_cdn_autosetup; fi
      return 0
}

list_configs() {
    print_title "$PROTO 配置列表"
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        local idx tag port uuid ttype detail
        idx=$(basename "$f" .json | cut -d'-' -f2); tag="${PROTO}${idx}"
        port=$(jq -r '.inbounds[0].listen_port' "$f")
        uuid=$(jq -r '.inbounds[0].users[0].uuid' "$f")
        # 裸 TCP 没有 transport 字段, .transport.path 取到 null —— 显示成
        # "tcp" 而不是 "null", 否则用户会以为节点坏了
        ttype=$(jq -r '.inbounds[0].transport.type // "tcp"' "$f")
        detail=$(jq -r '.inbounds[0].transport.path // .inbounds[0].transport.service_name // "-"' "$f")
        printf "%s) 端口:%s  传输:%s  %s  UUID:%s\n" "$idx" "$port" "$ttype" "$detail" "$uuid" >&2
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
