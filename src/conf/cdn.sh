#!/usr/bin/env bash
# cdn.sh — Cloudflare CDN 前置: 节点支持 + Nginx location 片段生成
#
# 原理:
#   Cloudflare 边缘 →(回源 443)→ 你的 Nginx →(按 path)→ sing-box(127.0.0.1:端口)
#
# sing-box 节点只监听 127.0.0.1, 端口不再对外暴露; 客户端连的是你的 CDN
# 域名而不是服务器 IP, 由 Cloudflare 隐藏源站 IP。
#
# 重要设计 —— 本模块绝不碰你的 Nginx:
#   你的 Nginx 是独立部署的, 通常还兼着正常网站业务。本模块只做两件事:
#     1. 把可走 CDN 的节点切到 CDN 模式(监听 127.0.0.1 + 分享链接用域名)
#     2. 生成 **location 片段** 文本, 打印出来 + 存文件, 由你复制粘贴
#   绝不自动写入你的 Nginx 配置目录, 绝不 reload/restart 任何服务。
#   原因: 你的站点已 listen 443 且配好 ssl_certificate, 再加一个同
#   server_name 的 server 块会让 nginx "Address already in use" 起不来。
#   所以只给 location 片段, 让你贴进已有的 server{} 里。
#
# 只有 ws / grpc / http(2) 这类跑在 HTTP 之上的传输能走 CDN;
# REALITY / AnyTLS / Hysteria2 / TUIC / SS / naive / ShadowTLS 是原生 TCP/UDP
# 或专用协议, Cloudflare 代理不了, 必须直连。

SB_CDN_TRANSPORTS=(ws grpc http)

# ---------- 判断某传输是否支持 CDN ----------
cdn_transport_supported() {
    local t="$1" x
    for x in "${SB_CDN_TRANSPORTS[@]}"; do [[ "$t" == "$x" ]] && return 0; done
    return 1
}

# ---------- 判断证书是否"真签" (Cloudflare 信任) ----------
# 自签证书 Cloudflare 一定拒绝回源, 必须排除。
# 判据: 有配对私钥 + 未过期 + 签发者不是自己。
# 本项目生成的自签只落 .crt 不落 key, 所以"有配对私钥"就能把自签筛掉。
sb_cert_is_trusted() {
    local crt="$1" k found="" subj issuer
    [[ -f "$crt" ]] || return 1
    for k in "${crt%.crt}_key.pem" "${crt%.crt}.key" "${crt%_cert.pem}_key.pem" \
             "${crt%.pem}_key.pem" "${crt%_cert.pem}.key"; do
        [[ -f "$k" ]] && { found="$k"; break; }
    done
    [[ -z "$found" ]] && return 1
    cert_not_expired "$crt" || return 1
    subj=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null | sed 's/^subject=//')
    issuer=$(openssl x509 -in "$crt" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
    [[ -z "$subj" || -z "$issuer" ]] && return 1
    [[ "$subj" == "$issuer" ]] && return 1
    return 0
}

# ---------- 判断某配置是否支持 CDN ----------
# 必须同时满足:
#   1) 传输是 ws / grpc / http(2) —— 跑在 HTTP 之上, Cloudflare 才能代理
#   2) 用的是真证书             —— 自签 Cloudflare 一定拒绝回源
cdn_config_supported() {
    local f="$1" t crt
    t=$(jq -r '.inbounds[0].transport.type // "tcp"' "$f" 2>/dev/null)
    cdn_transport_supported "$t" || return 1
    crt=$(jq -r '.inbounds[0].tls.certificate_path // ""' "$f" 2>/dev/null)
    [[ -n "$crt" ]] || return 1
    sb_cert_is_trusted "$crt" || return 1
    return 0
}

# ---------- 取节点的 CDN 路径 ----------
cdn_node_path() {
    jq -r '.inbounds[0].transport.path // ""' "$1" 2>/dev/null
}
cdn_node_service() {
    jq -r '.inbounds[0].transport.service_name // ""' "$1" 2>/dev/null
}

# ---------- 证书里的域名 ----------
cdn_cert_domain() {
    openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null \
        | grep -oE 'DNS:[^ ,]+' | head -1 | cut -d: -f2
}

# ---------- 渲染单个节点的 location 片段 ----------
#
# 架构 (与参考脚本 vlessxhttpecn.sh 一致) —— 注意是**双层 TLS**:
#     客户端 ──TLS──► Cloudflare ──TLS──► Nginx ──TLS──► sing-box
#     客户端 ──TLS──► Cloudflare ──TLS──► Nginx ──TLS──► sing-box
#
# 所以 proxy_pass 必须是 https:// 而不是 http://:
#   nginx 终止掉 Cloudflare 的 TLS 之后, 会用**新的 TLS 连接**去连 sing-box;
#   而 sing-box 的 inbound 仍然开着 TLS(它自己也有证书)。
#   若写成 http:// 就会向期待 TLS 的 sing-box 发明文, sing-box 立刻关连接
#   —— 表现为 502 / connection reset by peer, 且 sing-box 侧毫无日志。
# proxy_ssl_server_name on: 回源时带上 TLS SNI, sing-box 才能正确选证书。
#
# 另外不能写死 proxy_set_header Upgrade "websocket": Cloudflare 在边缘
# 终止 WebSocket, 回源时不带 Upgrade 头, $http_upgrade 取到空值。
# 但 sing-box 需要看到 Upgrade 才会接受 —— 这里的正确做法是依赖
# map $http_upgrade $connection_upgrade (你的 map.conf 已有)。
cdn_render_location() {
    local f="$1" tag port path svc ttype
    tag=$(jq -r '.inbounds[0].tag' "$f")
    port=$(jq -r '.inbounds[0].listen_port' "$f")
    ttype=$(jq -r '.inbounds[0].transport.type // "ws"' "$f")
    path=$(cdn_node_path "$f")
    svc=$(cdn_node_service "$f")

    printf '    # ---- %s  (回源 TLS → 127.0.0.1:%s, %s) ----\n' "$tag" "$port" "$ttype"
    case "$ttype" in
        grpc)
            printf '    location /%s {\n' "$svc"
            printf '        proxy_ssl_server_name on;\n'
            printf '        proxy_ssl_verify off;\n'
            printf '        proxy_pass https://127.0.0.1:%s;\n' "$port"
            printf '        proxy_http_version 2;\n'
            printf '        proxy_set_header Host $host;\n'
            printf '        proxy_set_header X-Real-IP $remote_addr;\n'
            printf '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
            printf '        proxy_read_timeout 600s;\n'
            printf '        proxy_send_timeout 600s;\n'
            printf '        grpc_read_timeout 600s;\n'
            printf '        grpc_send_timeout 600s;\n'
            printf '    }\n\n'
            ;;
        *)
            printf '    location %s {\n' "$path"
            printf '        proxy_ssl_server_name on;              # 回源 TLS SNI\n'
            printf '        proxy_ssl_verify off;                   # Origin CA 不在系统信任库\n'
            printf '        proxy_pass https://127.0.0.1:%s;         # https:// —— 必须是 TLS\n' "$port"
            printf '        proxy_http_version 1.1;\n'
            printf '        proxy_set_header Upgrade $http_upgrade;         # WebSocket 升级\n'
            printf '        proxy_set_header Connection $connection_upgrade;\n'
            printf '        proxy_set_header Host $host;\n'
            printf '        proxy_set_header X-Real-IP $remote_addr;\n'
            printf '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
            printf '        proxy_buffering off;\n'
            printf '        proxy_read_timeout 600s;\n'
            printf '        proxy_send_timeout 600s;\n'
            printf '    }\n\n'
            ;;
    esac
}

# ---------- 主入口: 生成 location 片段 ----------
# 只生成文本, 不写你的 Nginx 目录。
cdn_gen_nginx_conf() {
    local out="${1:-$SB_OUT_DIR/sb_cdn-nginx-location.conf}"
    local f crt d key found
    local -A by_dom=()
    local -a NODES=()

    shopt -s nullglob
    for f in "$SB_CONFIG_DIR"/*.json; do
        [[ "$(basename "$f")" =~ ^(00-|01-|02-|03-) ]] && continue
        cdn_config_supported "$f" && NODES+=("$f")
    done
    shopt -u nullglob

    if ((${#NODES[@]} == 0)); then
        print_warn "没有可走 CDN 的节点"
        print_warn "  CDN 需要同时满足: 传输为 ws/grpc/http(2)  且  使用真证书"
        print_warn "  自签证书无法被 Cloudflare 信任, 只能直连"
        print_warn "  建节点时在 TLS 选项里选真证书 (从已检测到的证书中选) 即可"
        return 1
    fi

    for f in "${NODES[@]}"; do
        crt=$(jq -r '.inbounds[0].tls.certificate_path // ""' "$f" 2>/dev/null)
        d=$(cdn_cert_domain "$crt")
        [[ -z "$d" ]] && continue
        by_dom["$d"]+="$f"$'\n'
    done

    {
        cat <<'EOF'
# ============================================================================
#  SB-Panel 生成 —— Cloudflare CDN location 片段
#  生成时间: __NOW__
#
#  【怎么用】把下面的 location 块复制粘贴进你已有的 Nginx 站点 server{} 块内
#           (建议放在 location / 之前 —— 更具体的路径会优先匹配)。
#
#  【不要】新建 server{} 块 —— 你的站点已经 listen 443 且配好了 ssl_certificate,
#         再加一个同 server_name 的 server 块会导致 nginx 起不来。
#
#  【前提】对应节点的端口只监听 127.0.0.1, 外部无法直连 (CDN 生效的基础)。
#  【验证】nginx -t 通过后再 reload。
#  =============================================================================
EOF
        for d in "${!by_dom[@]}"; do
            local sample; sample=$(head -1 <<<"${by_dom[$d]}")
            crt=$(jq -r '.inbounds[0].tls.certificate_path' "$sample")
            found=""
            for key in "${crt%.crt}_key.pem" "${crt%.crt}.key" "${crt%_cert.pem}_key.pem" \
                       "${crt%.pem}_key.pem" "${crt%_cert.pem}.key"; do
                [[ -f "$key" ]] && { found="$key"; break; }
            done
            if [[ -z "$found" ]]; then
                sb_scan_certs >/dev/null 2>&1 || true
                local e
                for e in "${sb_FOUND_CERTS[@]}"; do
                    [[ "$(cdn_cert_domain "${e%%|*}")" == "$d" ]] || continue
                    found="${e#*|}"; found="${found%%|*}"; break
                done
            fi
            printf '\n# ===== 回源域名: %s  (%s 个节点) =====\n' "$d" "$(grep -c . <<<"${by_dom[$d]}")"
            printf '# 粘贴到 server_name %s; 的那个 server{} 内\n' "$d"
            printf '# 证书: %s\n' "$(basename "$crt")"
            [[ -n "$found" ]] && printf '# 私钥: %s\n' "$(basename "$found")"
            printf '\n'
            local nf
            while read -r nf; do
                [[ -f "$nf" ]] || continue
                cdn_render_location "$nf"
            done <<<"${by_dom[$d]}"
        done
    } | sed "s/__NOW__/$(date '+%F %T')/" > "$out"

    print_ok "location 片段已生成: $out"
    print_info "共 ${#NODES[@]} 个节点, 分 ${#by_dom[@]} 个回源域名"
    echo
    cat "$out"
    echo
    print_info "验证: docker exec nginx nginx -t   (或在容器内直接 nginx -t)"
    print_info "重载: docker exec nginx nginx -s reload"
    printf '%s\n' "$out"
}

# ---------- 子模块 ----------
_CDN_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "$_CDN_HERE/cdn_nginx.sh" ]] && source "$_CDN_HERE/cdn_nginx.sh"
# shellcheck source=/dev/null
[[ -f "$_CDN_HERE/cdn_node.sh" ]] && source "$_CDN_HERE/cdn_node.sh"

# ---------- 直接执行入口 ----------
# 用法: bash conf/cdn.sh            打开菜单
#       bash conf/cdn.sh nginx      生成 location 片段
#       bash conf/cdn.sh certs      列出证书
#       bash conf/cdn.sh nodes      列出节点 (标注能否走 CDN)
#       bash conf/cdn.sh artifacts  生成全部 CDN 版客户端产物
_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# SELF_DIR 只在 sing-box.sh 里定义; 单独执行时必须用 _here 兜底,
# 否则 source "/conf/lib.sh" 落空, print_* 与 SB_* 变量全部缺失
_conf_dir="$SELF_DIR/conf"
[[ -f "$_conf_dir/lib.sh" ]] || _conf_dir="$_here"
# shellcheck source=/dev/null
source "$_conf_dir/lib.sh"
# shellcheck source=/dev/null
[[ -f "$_here/cdn_menu.sh" ]] && source "$_here/cdn_menu.sh"

# 只有被直接执行时才走下面的派发。被 lib.sh 懒加载 source 时必须跳过 ——
# 否则一 source 就弹出菜单, 协议脚本刚加完节点突然冒出一个菜单框。
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    _here="$SELF_DIR/conf"
    _conf_dir="$_here"
    [[ -f "$_conf_dir/lib.sh" ]] || _conf_dir="$_here"
    source "$_conf_dir/lib.sh"
    [[ -f "$_here/cdn_menu.sh" ]] && source "$_here/cdn_menu.sh"
    
    case "${1:-}" in
        nginx)     cdn_gen_nginx_conf ;;
        certs)     cdn_show_certs ;;
        nodes)     cdn_list_nodes ;;
        artifacts) cdn_gen_all_nodes ;;
        remove)     cdn_auto_remove ;;
        help|-h|--help) cdn_show_help ;;
        *)         cdn_menu ;;
    esac
fi
