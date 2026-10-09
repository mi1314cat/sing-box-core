#!/bin/bash
# ==============================================================
# outbound.sh — 出站（outbound）管理模块
# 每条出站 = config/outbound-NN.json
#
# 设计要点 (对齐 sing-box v1.14.1 实际 schema, 见 option/*.go):
#   * 手动添加按"协议族"分流, 不同类型问不同字段 —— 不做统一 server/port 表单
#   * 分享链接每个 scheme 一个独立 parser (outbound_uri.py), 先预览再落盘
#   * 列表一律脱敏, 绝不回显 password / uuid / token
#   * 任何写盘都先 backup, 再 sing-box check, 不过则回滚本次文件
#   * 菜单项对"本内核不支持"的协议会依据真实探测结果隐藏 (如 naive 缺 cronet)
# CLI: bash outbound.sh [add|list|del|share|selftest|check]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="outbound"

# ==============================================================
# 0. 内核能力探测 —— 菜单项据实显示, 不硬编码
# ==============================================================
OB_PROBE_CACHE="$SB_OUT_DIR/.ob-type-probe"

ob_probe_sample() { # 给出该类型"最小可用"配置, 用于探测内核是否支持
    case "$1" in
        socks|http)  printf '{"outbounds":[{"type":"%s","tag":"p","server":"127.0.0.1","server_port":1}]}' "$1" ;;
        shadowsocks) printf '{"outbounds":[{"type":"shadowsocks","tag":"p","server":"127.0.0.1","server_port":1,"method":"aes-256-gcm","password":"x"}]}' ;;
        vmess|vless) printf '{"outbounds":[{"type":"%s","tag":"p","server":"127.0.0.1","server_port":1,"uuid":"11111111-1111-1111-1111-111111111111","tls":{"enabled":true,"server_name":"a"}}]}' "$1" ;;
        trojan)      printf '{"outbounds":[{"type":"trojan","tag":"p","server":"127.0.0.1","server_port":1,"password":"x","tls":{"enabled":true,"server_name":"a"}}]}' ;;
        hysteria2)   printf '{"outbounds":[{"type":"hysteria2","tag":"p","server":"127.0.0.1","server_port":1,"password":"x","tls":{"enabled":true,"server_name":"a"}}]}' ;;
        tuic)        printf '{"outbounds":[{"type":"tuic","tag":"p","server":"127.0.0.1","server_port":1,"uuid":"11111111-1111-1111-1111-111111111111","password":"x","tls":{"enabled":true,"server_name":"a"}}]}' ;;
        anytls)      printf '{"outbounds":[{"type":"anytls","tag":"p","server":"127.0.0.1","server_port":1,"password":"x","tls":{"enabled":true,"server_name":"a"}}]}' ;;
        shadowtls)   printf '{"outbounds":[{"type":"shadowtls","tag":"p","server":"127.0.0.1","server_port":1,"version":3,"password":"x","tls":{"enabled":true,"server_name":"a"}}]}' ;;
        naive)       printf '{"outbounds":[{"type":"naive","tag":"p","server":"127.0.0.1","server_port":1,"username":"u","password":"x","tls":{"enabled":true,"server_name":"a"}}]}' ;;
        *)           printf '{"outbounds":[{"type":"%s","tag":"p"}]}' "$1" ;;
    esac
}

# 某些出站类型(如 naive)依赖构建标签/cronet 之类的可选组件, 不同内核并不一致。
# 菜单不硬编码支持与否, 而是用"最小可用配置"实际探一次, 探完缓存, 避免每次渲染都探测。
OB_PROBE_TYPES="naive"
ob_unsupported() { # 输出本内核不支持的出站类型(逐行); 结果缓存
    [[ -f "$OB_PROBE_CACHE" ]] && { cat "$OB_PROBE_CACHE"; return; }
    if [[ ! -x "$SB_BIN" ]]; then echo "naive"; return; fi
    local t tmp out=""
    tmp=$(mktemp)
    for t in $OB_PROBE_TYPES; do
        ob_probe_sample "$t" > "$tmp"
        "$SB_BIN" check -c "$tmp" >/dev/null 2>&1 || out="$out$t"$'\n'
    done
    rm -f "$tmp"
    mkdir -p "$(dirname "$OB_PROBE_CACHE")"
    printf '%s' "$out" > "$OB_PROBE_CACHE"   # 即使为空也写, 保证只探测一次
    printf '%s' "$out"
}

ob_type_ok() { ! ob_unsupported | grep -qx "$1"; }

# ==============================================================
# 1. 输入 / 组装工具
# ==============================================================
jstr() { printf '%s' "${1-}" | jq -Rs .; }   # 任意文本 -> 合法 JSON 字符串字面量

ob_ask_server() { # 远程服务器地址 (不查本机端口占用 —— 那是入站才关心的)
    local v
    while true; do
        sb_ask "  服务器地址 (域名或 IP, 输入 0 放弃): "; v="$REPLY"
        v=$(clean_input "$v")
        # 原来空输入会无限重试, 除了 Ctrl-C 没有出口
        [[ "$v" == "0" ]] && { print_warn "已放弃添加"; return 1; }
        [[ -z "$v" ]] && { print_error "服务器地址不能为空 (输入 0 可放弃)"; continue; }
        [[ "$v" =~ [[:space:]] ]] && { print_error "地址不能包含空格"; continue; }
        echo "$v"; return 0
    done
}

ob_ask_port() { # 远程端口: 只校验格式与范围; 输入 0 可随时放弃
    local v
    while true; do
        sb_ask "  服务器端口 (输入 0 放弃): "; v="$REPLY"
        v=$(clean_input "$v")
        [[ "$v" == "0" ]] && { print_warn "已放弃添加"; return 1; }
        [[ -z "$v" ]] && { print_error "端口不能为空"; continue; }
        [[ "$v" =~ ^[0-9]+$ ]] || { print_error "端口必须是数字 (如 443)"; continue; }
        # 10# 强制十进制: "08"/"09" 的前导零会被 bash 当成八进制
        (( 10#$v >= 1 && 10#$v <= 65535 )) || { print_error "端口范围 1-65535"; continue; }
        echo "$v"; return 0
    done
}

ob_ask_required() { # ob_ask_required <提示> —— 必填文本, 允许空格
    local p="$1" v
    while true; do
        sb_ask "$p"; v="$REPLY"
        v=$(clean_input "$v")
        [[ -z "$v" ]] && { print_error "该项必填, 不能为空"; continue; }
        printf '%s' "$v"; return 0
    done
}

ob_ask_optional() { # 可选文本, 回车用默认(可为空)
    local p="$1" d="${2-}" v
    sb_ask "$p"; v="$REPLY"
    v=$(clean_input "$v"); echo "${v:-$d}"
}

ob_ask_yesno() { # ob_ask_yesno <提示> <默认 y|n>
    local p="$1" d="$2" a
    # 必须区分"用户回车用默认"和"stdin 已 EOF"：
    # 旧实现两者都得到空串 -> 一律取默认, stdin 提前结束时等于未经确认就写盘 (fail-open)。
    if ! sb_ask "$p"; then
        print_warn "输入已结束, 按 [N] 处理 (不执行写操作)"
        return 1
    fi
    a="$REPLY"
    a=$(clean_input "$a"); [[ -z "$a" ]] && a="$d"
    [[ "$a" =~ ^[yY] ]]
}

ob_ask_uuid() {
    local v
    while true; do
        sb_ask "  UUID: "; v="$REPLY"
        v=$(clean_input "$v")
        [[ -z "$v" ]] && { print_error "UUID 不能为空"; continue; }
        [[ "$v" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
            || { print_error "UUID 格式非法 (应为 8-4-4-4-12 十六进制)"; continue; }
        echo "$v"; return 0
    done
}

ob_ask_auth() { # SOCKS / HTTP 共用: 认证方式 -> "username"/"password" JSON 片段
    echo "  认证方式:" >&2
    echo "    1) 无认证" >&2
    echo "    2) 用户名 + 密码" >&2
    local c
    sb_ask "  选择 (默认 1): "; c="$REPLY"
    c=$(clean_input "$c"); [[ -z "$c" ]] && c=1
    [[ "$c" == "2" ]] || return 0
    local u p
    u=$(ob_ask_required "  用户名: ")
    p=$(ob_ask_required "  密码: ")
    printf '"username": %s, "password": %s' "$(jstr "$u")" "$(jstr "$p")"
}

ob_ask_tls() { # ob_ask_tls [must]  通用 TLS 块 (1.14 OutboundTLSOptions); 输出 JSON 或空串
    # must=y: 该协议在 sing-box 1.14 中 TLS 是强制的 (缺 TLS 直接 initialize 失败:
    # "TLS required"), 这里不允许关, 免得生成一个 check 能过但永远连不上的半残配置。
    local must="${1:-n}"
    if [[ "$must" == "y" ]]; then
        if ! ob_ask_yesno "  启用 TLS? ${YELLOW}(本协议强制要求, 无法关闭)${RESET} [Y/n]: " y; then
            print_warn "已按协议要求强制启用 TLS"
        fi
    elif ! ob_ask_yesno "  启用 TLS? [y/N]: " n; then
        return 0
    fi
    local sni insecure alpn fp o
    sni=$(ob_ask_optional "  SNI / server_name (回车=与服务器地址相同): ")
    insecure=0
    ob_ask_yesno "  跳过证书校验 (insecure)? [y/N]: " n && insecure=1
    alpn=$(ob_ask_optional "  ALPN (可选, 逗号分隔, 如 h3,h2): ")
    fp=$(ob_ask_optional "  uTLS 指纹 (可选, 回车=当前默认 $(sb_fp_get)): ")
    o='{"enabled": true'
    [[ -n "$sni" ]] && o="$o, \"server_name\": $(jstr "$sni")"
    [[ "$insecure" == "1" ]] && o="$o, \"insecure\": true"
    [[ -n "$alpn" ]] && o="$o, \"alpn\": $(printf '%s' "$alpn" | awk -F, '{printf "["; for(i=1;i<=NF;i++){gsub(/^[ \t]+|[ \t]+$/,"",$i); if($i!="") printf "%s\"%s\"", (i>1?",":""), $i} printf "]"}')"
    [[ -n "$fp" ]] && o="$o, \"utls\": {\"enabled\": true, \"fingerprint\": $(jstr "$fp")}"
    echo "$o}"
}

ob_ask_transport() { # V2RayTransportOptions (1.14 枚举: http/ws/quic/grpc/httpupgrade)
    echo "  传输方式: 1)tcp(默认) 2)ws 3)grpc 4)http 5)httpupgrade" >&2
    local c
    sb_ask "  选择 (默认 1): "; c="$REPLY"
    c=$(clean_input "$c"); [[ -z "$c" ]] && c=1
    case "$c" in
        2) local p h
           p=$(ob_ask_optional "    WebSocket path (默认 /): " "/")
           h=$(ob_ask_optional "    WebSocket Host 头 (可选): ")
           if [[ -n "$h" ]]; then printf '{"type":"ws","path":%s,"headers":{"Host":%s}}' "$(jstr "$p")" "$(jstr "$h")"
           else printf '{"type":"ws","path":%s}' "$(jstr "$p")"; fi ;;
        3) local s
           s=$(ob_ask_required "    gRPC service_name: ")
           printf '{"type":"grpc","service_name":%s}' "$(jstr "$s")" ;;
        4) local h p
           h=$(ob_ask_optional "    HTTP host (可选, 逗号分隔): ")
           p=$(ob_ask_optional "    HTTP path (默认 /): " "/")
           if [[ -n "$h" ]]; then
               printf '{"type":"http","host":%s,"path":%s}' \
                 "$(printf '%s' "$h" | awk -F, '{printf "["; for(i=1;i<=NF;i++){gsub(/^[ \t]+|[ \t]+$/,"",$i); if($i!="") printf "%s\"%s\"", (i>1?",":""), $i} printf "]"}')" "$(jstr "$p")"
           else printf '{"type":"http","path":%s}' "$(jstr "$p")"; fi ;;
        5) local h p
           h=$(ob_ask_optional "    Host 头 (可选): ")
           p=$(ob_ask_optional "    path (默认 /): " "/")
           if [[ -n "$h" ]]; then printf '{"type":"httpupgrade","host":%s,"path":%s}' "$(jstr "$h")" "$(jstr "$p")"
           else printf '{"type":"httpupgrade","path":%s}' "$(jstr "$p")"; fi ;;
        *) return 0 ;;
    esac
}

ob_base() { # ob_base <type> <server> <port> -> 输出 "type"/"server"/"server_port" 片段
    printf '"type": %s, "server": %s, "server_port": %d' "$(jstr "$1")" "$(jstr "$2")" "$((10#$3))"
}

ob_ask_tag() { # 出站标识: 留空=自动; 校验字符集与唯一性
    local v
    while true; do
        sb_ask "  出站标识 tag (留空=自动): "
        v="$REPLY"
        [[ -z "$v" ]] && { echo ""; return 0; }
        if [[ ! "$v" =~ ^[A-Za-z0-9_.:-]{1,64}$ ]]; then
            print_error "tag 只允许字母/数字/ _ . : - , 最长 64 字符"
            continue
        fi
        if ob_tag_exists "$v"; then
            print_error "标识已存在: $v (请换一个或留空自动生成)"
            continue
        fi
        echo "$v"; return 0
    done
}

# ==============================================================
# 2. 各类出站的独立表单 (不同类型问不同字段)
# ==============================================================
ob_form_socks() {
    local s p auth o
    echo "  --- SOCKS 出站 ---" >&2
    s=$(ob_ask_server); p=$(ob_ask_port)
    auth=$(ob_ask_auth)
    o=$(ob_base socks "$s" "$p")
    [[ -n "$auth" ]] && o="$o, $auth"
    echo "{$o}"
}

ob_form_http() {
    local s p auth tls o
    echo "  --- HTTP 出站 ---" >&2
    s=$(ob_ask_server); p=$(ob_ask_port)
    auth=$(ob_ask_auth)
    tls=$(ob_ask_tls)
    o=$(ob_base http "$s" "$p")
    [[ -n "$auth" ]] && o="$o, $auth"
    [[ -n "$tls"  ]] && o="$o, \"tls\": $tls"
    echo "{$o}"
}

ob_form_shadowsocks() {
    local s p m pw c o
    echo "  --- Shadowsocks 出站 ---" >&2
    echo "    加密方式: 1)aes-256-gcm 2)aes-128-gcm 3)chacha20-ietf-poly1305" >&2
    echo "              4)2022-blake3-aes-256-gcm 5)xchacha20-ietf-poly1305 6)none" >&2
    sb_ask "  选择 (默认 1): "; c="$REPLY"
    c=$(clean_input "$c"); [[ -z "$c" ]] && c=1
    case "$c" in
        1) m=aes-256-gcm ;; 2) m=aes-128-gcm ;; 3) m=chacha20-ietf-poly1305 ;;
        4) m=2022-blake3-aes-256-gcm ;; 5) m=xchacha20-ietf-poly1305 ;; 6) m=none ;;
        *) m=$(ob_ask_required "  加密方式 (直接输入): ") ;;
    esac
    pw=$(ob_ask_required "  密码: ")
    s=$(ob_ask_server); p=$(ob_ask_port)
    o="$(ob_base shadowsocks "$s" "$p"), \"method\": $(jstr "$m"), \"password\": $(jstr "$pw")"
    echo "{$o}"
}

ob_form_vmess() {
    local s p uuid sec tls tr c o
    echo "  --- VMess 出站 ---" >&2
    s=$(ob_ask_server); p=$(ob_ask_port)
    uuid=$(ob_ask_uuid)
    echo "    加密方式: 1)auto(默认) 2)none 3)zero 4)aes-128-gcm" >&2
    sb_ask "  选择 (默认 1): "; c="$REPLY"
    c=$(clean_input "$c"); [[ -z "$c" ]] && c=1
    case "$c" in 1) sec=auto ;; 2) sec=none ;; 3) sec=zero ;; 4) sec=aes-128-gcm ;;
               *) sec=$(ob_ask_required "  加密方式 (直接输入): ") ;; esac
    tls=$(ob_ask_tls)
    tr=$(ob_ask_transport)
    o="$(ob_base vmess "$s" "$p"), \"uuid\": $(jstr "$uuid"), \"security\": $(jstr "$sec")"
    [[ -n "$tls" ]] && o="$o, \"tls\": $tls"
    [[ -n "$tr"  ]] && o="$o, \"transport\": $tr"
    echo "{$o}"
}

ob_form_vless() {
    local s p uuid flow tls tr o
    echo "  --- VLESS 出站 ---" >&2
    s=$(ob_ask_server); p=$(ob_ask_port)
    uuid=$(ob_ask_uuid)
    flow=$(ob_ask_optional "  flow (可选, 如 xtls-rprx-vision, 需 TLS): ")
    tls=$(ob_ask_tls)
    tr=$(ob_ask_transport)
    if [[ -n "$flow" && -z "$tls" ]]; then print_warn "flow 需要 TLS/REALITY, 本次已忽略 flow"; flow=""; fi
    o="$(ob_base vless "$s" "$p"), \"uuid\": $(jstr "$uuid")"
    [[ -n "$flow" ]] && o="$o, \"flow\": $(jstr "$flow")"
    [[ -n "$tls"  ]] && o="$o, \"tls\": $tls"
    [[ -n "$tr"   ]] && o="$o, \"transport\": $tr"
    echo "{$o}"
}

ob_form_trojan() {
    local s p pw tls tr o
    echo "  --- Trojan 出站 ---" >&2
    s=$(ob_ask_server); p=$(ob_ask_port)
    pw=$(ob_ask_required "  密码: ")
    tls=$(ob_ask_tls y)
    tr=$(ob_ask_transport)
    o="$(ob_base trojan "$s" "$p"), \"password\": $(jstr "$pw")"
    [[ -n "$tls" ]] && o="$o, \"tls\": $tls"
    [[ -n "$tr"  ]] && o="$o, \"transport\": $tr"
    echo "{$o}"
}

ob_form_hysteria2() {
    local s p pw up down obfs_pw tls c o
    echo "  --- Hysteria2 出站 (sing-box 原生支持, 不必绕 SOCKS/HTTP) ---" >&2
    s=$(ob_ask_server); p=$(ob_ask_port)
    pw=$(ob_ask_required "  密码 (auth): ")
    up=$(ob_ask_optional "  上行 Mbps (可留空): ")
    down=$(ob_ask_optional "  下行 Mbps (可留空): ")
    obfs_pw=""
    if ob_ask_yesno "  启用 Salamander 混淆? [y/N]: " n; then
        obfs_pw=$(ob_ask_required "  混淆密码 (obfs-password): ")
    fi
    tls=$(ob_ask_tls y)
    o="$(ob_base hysteria2 "$s" "$p"), \"password\": $(jstr "$pw")"
    [[ "$up"   =~ ^[0-9]+$ ]] && o="$o, \"up_mbps\": $up"
    [[ "$down" =~ ^[0-9]+$ ]] && o="$o, \"down_mbps\": $down"
    [[ -n "$obfs_pw" ]] && o="$o, \"obfs\": {\"type\": \"salamander\", \"password\": $(jstr "$obfs_pw")}"
    [[ -n "$tls" ]] && o="$o, \"tls\": $tls"
    echo "{$o}"
}

ob_form_tuic() {
    local s p uuid pw cc tls o
    echo "  --- TUIC 出站 ---" >&2
    s=$(ob_ask_server); p=$(ob_ask_port)
    uuid=$(ob_ask_uuid)
    pw=$(ob_ask_required "  密码: ")
    cc=$(ob_ask_optional "  拥塞控制 (1)cubic 2)bbr 3)new_reno, 留空=内核默认): ")
    case "$cc" in 1) cc=cubic ;; 2) cc=bbr ;; 3) cc=new_reno ;; esac
    tls=$(ob_ask_tls y)
    o="$(ob_base tuic "$s" "$p"), \"uuid\": $(jstr "$uuid"), \"password\": $(jstr "$pw")"
    [[ -n "$cc" ]] && o="$o, \"congestion_control\": $(jstr "$cc")"
    [[ -n "$tls" ]] && o="$o, \"tls\": $tls"
    echo "{$o}"
}

ob_form_anytls() {
    local s p pw tls o
    echo "  --- AnyTLS 出站 ---" >&2
    s=$(ob_ask_server); p=$(ob_ask_port)
    pw=$(ob_ask_required "  密码: ")
    tls=$(ob_ask_tls y)
    o="$(ob_base anytls "$s" "$p"), \"password\": $(jstr "$pw")"
    [[ -n "$tls" ]] && o="$o, \"tls\": $tls"
    echo "{$o}"
}

ob_form_shadowtls() {
    local s p pw tls v o
    echo "  --- ShadowTLS 出站 (一般作为传输层, 需配合 v2ray-plugin 等) ---" >&2
    s=$(ob_ask_server); p=$(ob_ask_port)
    v=$(ob_ask_optional "  版本 (默认 3): " "3")
    [[ "$v" =~ ^[123]$ ]] || v=3
    pw=$(ob_ask_required "  密码: ")
    tls=$(ob_ask_tls y)
    o="$(ob_base shadowtls "$s" "$p"), \"version\": $v, \"password\": $(jstr "$pw")"
    [[ -n "$tls" ]] && o="$o, \"tls\": $tls"
    echo "{$o}"
}

ob_form_naive() {
    local s p auth tls o
    echo "  --- NaiveProxy 出站 ---" >&2
    s=$(ob_ask_server); p=$(ob_ask_port)
    auth=$(ob_ask_auth)
    tls=$(ob_ask_tls y)
    o=$(ob_base naive "$s" "$p")
    [[ -n "$auth" ]] && o="$o, $auth"
    [[ -n "$tls"  ]] && o="$o, \"tls\": $tls"
    echo "{$o}"
}

ob_form_direct() { echo '{"type": "direct"}'; }
# 注意: 不要再提供 "block" 特殊出站。
# 它属于 sing-box 1.11.0 起的废弃特殊出站(与 "dns" 一起), 官方已改用
# rule action 表达 —— 阻断用 {"action":"reject"}, 劫持 DNS 用
# {"action":"hijack-dns"}。迁移文档:
#   https://sing-box.sagernet.org/migration/#1150 (Legacy special outbounds)
# 历史原因: 过去这个菜单项会生成 {"type":"block"} 并写进配置, 导致配置
# 带着废弃字段。现在改成提示 + 引导用规则, 不再生成。

ob_pick_tags_multi() { # 控制型出站: 从现有 tag 中多选
    local tags=() i=1 t sel
    while read -r t; do [[ -n "$t" ]] && tags+=("$t"); done < <(all_outbound_tags | grep -v '^direct$')
    if ((${#tags[@]} == 0)); then print_error "当前没有可选出站, 请先添加出站或节点"; return 1; fi
    print_title "选择成员出站 (输入编号, 空格或逗号分隔, 至少选一个)"
    for t in "${tags[@]}"; do
        printf "  %s) %s\n" "$i" "$t" >&2; i=$((i+1))
    done
    sb_ask "请选择: "; sel="$REPLY"
    sel=$(clean_input "$sel")
    [[ -z "$sel" ]] && { print_error "未选择"; return 1; }
    local out="" n
    for n in $sel; do
        n="${n//,/ }"; n=$(clean_input "$n")
        [[ "$n" =~ ^[0-9]+$ ]] || { print_error "无效编号: $n"; return 1; }
        (( n >= 1 && n <= ${#tags[@]} )) || { print_error "编号越界: $n"; return 1; }
        out="$out${out:+, }\"${tags[$((n-1))]}\""
    done
    echo "$out"
}

ob_form_selector() {
    local tags; echo "  --- selector 出站 (手动选择, 相当于策略组) ---" >&2
    tags=$(ob_pick_tags_multi) || return 1
    echo "{\"type\": \"selector\", \"outbounds\": [$tags]}"
}

ob_form_urltest() {
    local tags url iv
    echo "  --- urltest 出站 (自动测速选最快) ---" >&2
    tags=$(ob_pick_tags_multi) || return 1
    url=$(ob_ask_optional "  测速 URL (默认 https://www.gstatic.com/generate_204): " "https://www.gstatic.com/generate_204")
    iv=$(ob_ask_optional "  测试间隔 (默认 3m): " "3m")
    echo "{\"type\": \"urltest\", \"outbounds\": [$tags], \"url\": $(jstr "$url"), \"interval\": $(jstr "$iv")}"
}

manual_add() {
    print_title "添加出站 — 选择类型"
    local c
    cat >&2 <<'MENU'
  代理型 (需要 服务器 + 凭据)
   1) socks        2) http         3) shadowsocks
   4) vmess        5) vless        6) trojan
   7) hysteria2    8) tuic         9) anytls
  10) shadowtls
  控制型 (聚合已有出站, 不需要服务器)
  11) selector    12) urltest
  特殊用途
  13) direct
MENU
    if ! ob_type_ok naive; then
        echo -e "  ${YELLOW}注: 本内核不含 naive(NaiveProxy) 出站所需的 cronet 库, 已隐藏该选项${RESET}" >&2
    else
        echo -e "  ${CYAN}15) naive        (本内核支持)${RESET}" >&2
    fi
    echo -e "   ${CYAN}0)${RESET} 取消" >&2
    sb_ask "请选择: "; c="$REPLY"
    c=$(clean_input "$c")
    local form
    case "$c" in
        1)  form=$(ob_form_socks) ;;
        2)  form=$(ob_form_http) ;;
        3)  form=$(ob_form_shadowsocks) ;;
        4)  form=$(ob_form_vmess) ;;
        5)  form=$(ob_form_vless) ;;
        6)  form=$(ob_form_trojan) ;;
        7)  form=$(ob_form_hysteria2) ;;
        8)  form=$(ob_form_tuic) ;;
        9)  form=$(ob_form_anytls) ;;
        10) form=$(ob_form_shadowtls) ;;
        11) form=$(ob_form_selector) ;;
        12) form=$(ob_form_urltest) ;;
        13) form=$(ob_form_direct) ;;
        14) print_error "block 出站已移除 (sing-box 1.11.0 起废弃)"
            print_info "需要阻断某些流量, 请改用路由规则: {\"action\":\"reject\", ...}"
            print_info "需要把 DNS 交给 sing-box, 用 {\"action\":\"hijack-dns\"}"
            return 1 ;;
        15) ob_type_ok naive || { print_error "本内核不支持 naive 出站"; return 1; }
            form=$(ob_form_naive) ;;
        0|"") return 0 ;;
        *) print_error "无效选项"; return 1 ;;
    esac
    [[ -n "$form" ]] || { print_error "未生成配置, 已取消"; return 1; }
    printf '%s' "$form" | jq -e . >/dev/null 2>&1 || { print_error "生成的 JSON 非法, 已放弃 (未写盘)"; return 1; }
    ob_commit "$form" "$(ob_ask_tag)"
}

# ==============================================================
# 3. 分享链接导入
# ==============================================================
OB_URI_PY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/outbound_uri.py"
OB_URI_URL="https://raw.githubusercontent.com/mi1314cat/sing-box-core/main/src/conf/outbound_uri.py"

ob_uri_parser() {
    if [[ ! -f "$OB_URI_PY" ]]; then
        print_info "解析器缺失, 正在拉取..."
        curl -fsSL --max-time 30 "$OB_URI_URL" -o "$OB_URI_PY" 2>/dev/null || : > /dev/null
    fi
    [[ -f "$OB_URI_PY" ]] || { print_error "分享链接解析器不可用: $OB_URI_PY"; return 1; }
    echo "$OB_URI_PY"
}

OB_REMOTE_PY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/outbound_remote.py"
OB_REMOTE_URL="https://raw.githubusercontent.com/mi1314cat/sing-box-core/main/src/conf/outbound_remote.py"

# 面板以 python3 "$py" 方式调用, 可执行位非必需; 但自愈下载/解压出来的文件
# 可能缺权限, 这里统一补上, 便于直接 ./执行排查问题
ob_fix_py_perm() {
    local p
    for p in "$SB_CONF_DIR"/outbound_remote.py "$SB_CONF_DIR"/outbound_uri.py; do
        [[ -f "$p" ]] && chmod 755 "$p" 2>/dev/null
    done
}

ob_remote_parser() {
    if [[ ! -f "$OB_REMOTE_PY" ]]; then
        print_info "远程配置拉取器缺失, 正在拉取..."
        curl -fsSL --max-time 30 "$OB_REMOTE_URL" -o "$OB_REMOTE_PY" 2>/dev/null || : > /dev/null
    fi
    [[ -f "$OB_REMOTE_PY" ]] || { print_error "远程配置拉取器不可用: $OB_REMOTE_PY"; return 1; }
    echo "$OB_REMOTE_PY"
}

ob_sanitize_tag() { # 分享链接名字 -> 合法且唯一的 tag
    local raw="$1" type="$2" idx="$3"
    local t
    t=$(printf '%s' "$raw" | tr -cd 'A-Za-z0-9_.-' | cut -c1-40)
    [[ -z "$t" ]] && t="$type$idx"
    local cand="$t" n=1
    if ob_tag_exists "$cand"; then
        while ob_tag_exists "$cand"; do n=$((n+1)); cand="${t}_$n"; done
        # tag 是"域名分流/入站绑定"引用的键, 静默改名会让用户按原名找不到节点
        print_warn "标识 $raw 已存在, 自动改为: $cand"
    fi
    echo "$cand"
}

ob_tag_exists() { # ob_tag_exists <tag>
    # 必须用 -s: jq 对多个文件是"逐文档"求值, any() 只反映最后一个文件的结果,
    # 会把"前面某个文件里已存在该 tag"误判为不存在。
    jq -s -e --arg t "$1" 'any(.[]?; any(.outbounds[]?; .tag == $t))' "$SB_CONFIG_DIR"/*.json >/dev/null 2>&1
}

share_add() {
    print_title "从分享链接添加出站"
    echo -e "  ${CYAN}支持: ss:// vmess:// vless:// trojan:// hysteria2:// (hy2://) tuic://${RESET}" >&2
    local uri py res ok type name prev
    sb_ask "  粘贴分享链接: "; uri="$REPLY"
    uri=$(clean_input "$uri")
    [[ -z "$uri" ]] && { print_error "未输入链接"; return 1; }
    py=$(ob_uri_parser) || return 1
    res=$(python3 "$py" "$uri" 2>&1)
    ok=$(printf '%s' "$res" | jq -r '.ok' 2>/dev/null)
    if [[ "$ok" != "true" ]]; then
        printf '%s' "$res" | jq -r '.error // "解析器无输出"' >&2 | while IFS= read -r l; do print_error "$l"; done
        return 1
    fi
    type=$(printf '%s' "$res" | jq -r '.type')
    name=$(printf '%s' "$res" | jq -r '.name')
    # ---- 预览 (敏感信息已由解析器掩码) ----
    print_title "解析结果预览 (敏感项已脱敏)"
    printf '  协议: %s\n' "$type" >&2
    printf '  服务器: %s:%s\n' \
        "$(printf '%s' "$res" | jq -r '.outbound.server')" \
        "$(printf '%s' "$res" | jq -r '.outbound.server_port')" >&2
    printf '%s' "$res" | jq -r '.preview[] | "  " + .[0] + ": " + .[1]' >&2
    [[ -n "$name" ]] && printf '  备注: %s\n' "$name" >&2
    echo >&2
    ob_ask_yesno "  确认添加? [Y/n]: " y || { print_warn "已取消, 未写入任何文件"; return 0; }
    ob_commit "$(printf '%s' "$res" | jq -c '.outbound')" "$(ob_sanitize_tag "$name" "$type" "$(get_next_index "$PROTO")")"
}

# ==============================================================
# 4. 写入出口 (backup -> write -> check -> reload, 失败回滚本次文件)
# ==============================================================
ob_commit() { # ob_commit <outbound-json-无tag> [tag]
    local ob="$1" tag="${2:-}" idx file json
    [[ -n "$tag" ]] || tag="$PROTO$(get_next_index "$PROTO")"
    printf '%s' "$ob" | jq -e . >/dev/null 2>&1 || { print_error "生成的 JSON 非法, 已放弃 (未写盘)"; return 1; }
    ob_tag_exists "$tag" && { print_error "标识已存在: $tag"; return 1; }
    # selector/urltest 若把自身 tag 当成员会形成自引用, 必然 check 失败
    if printf '%s' "$ob" | jq -e --arg t "$tag" 'any(.outbounds[]?; . == $t)' >/dev/null 2>&1; then
        print_error "控制型出站不能把自己 ($tag) 作为成员, 已放弃"
        return 1
    fi
    idx=$(get_next_index "$PROTO")
    file="$SB_CONFIG_DIR/$PROTO-$idx.json"
    json=$(printf '%s' "$ob" | jq --arg t "$tag" '{outbounds: [ . + {tag: $t} ]}') || { print_error "组装配置失败"; return 1; }
    backup_config config
    write_config "$file" "$json" || return 1
    if ! sb_check; then
        rm -f "$file"
        if sb_check_quiet; then
            print_error "本次配置未通过 sing-box check, 已删除 $(basename "$file")"
            print_ok    "其余配置合法, 现网未受影响"
        else
            print_error "本次配置已删除, 但移除后整体 check 仍失败 —— 存在其它历史问题, 请先修复:"
            sb_check
        fi
        return 1
    fi
    sb_reload || true
    SB_LAST_OUT_FILE="$file"; SB_LAST_OUT_TAG="$tag"
    print_ok "出站已添加: $tag  ($(basename "$file"))"
    print_info "接下来: 5) 用于域名分流   8) 绑定到入站   10) 做连通性自检"
}

# 一次提交多条 outbound 到同一个文件。
# 之所以不能只靠 ob_commit: ShadowTLS 节点 = shadowtls 外壳 + 内层 SS 两条,
# 内层通过 detour 指回外壳。分两次写必然出现 "detour 找不到" 的坏配置。
ob_commit_multi() { # ob_commit_multi <outbounds-json-array> <主tag> [条数]
    local arr="$1" main_tag="$2" cnt="${3:-}"
    printf '%s' "$arr" | jq -e 'type=="array" and length>0' >/dev/null 2>&1 \
        || { print_error "要写入的 outbound 列表非法, 已放弃 (未写盘)"; return 1; }
    local dup
    dup=$(printf '%s' "$arr" | jq -r '[.[].tag] | group_by(.) | map(select(length>1) | .[0]) | join(", ")')
    [[ -z "$dup" ]] || { print_error "以下标识在本次导入中重复: $dup"; return 1; }
    local t
    for t in $(printf '%s' "$arr" | jq -r '.[].tag'); do
        ob_tag_exists "$t" && { print_error "标识已存在: $t"; return 1; }
    done
    # detour 目标必须都在本次列表内, 否则必然 check 失败
    local miss
    miss=$(printf '%s' "$arr" | jq -r '
        ([.[].tag]) as $tags
        | [.[] | .detour? // empty | select(. as $d | ($tags | index($d)) == null)]
        | unique | join(", ")')
    [[ -z "$miss" ]] || { print_error "存在指向列表外的 detour: $miss (拒绝写出必然失败的配置)"; return 1; }
    # 控制型自引用
    printf '%s' "$arr" | jq -e --arg t "$main_tag" 'any(.[]?; select(.outbounds? != null) | .outbounds | any(. == $t))' >/dev/null 2>&1 \
        && { print_error "控制型出站不能把自己 ($main_tag) 作为成员, 已放弃"; return 1; }

    local idx file json
    idx=$(get_next_index "$PROTO")
    # 一条 outbound 一个文件 —— 与项目既有约定一致。
    # 必须是"全有或全无": detour 组合(如 ShadowTLS 外壳+内层 SS)拆成两个文件后,
    # 中间态会短暂出现 "detour 找不到", 所以先全部写完再统一 check, 失败则全部删除。
    local files=() i=0 base="$idx"
    for ob in $(printf '%s' "$arr" | jq -c '.[]'); do
        file="$SB_CONFIG_DIR/$PROTO-$(printf '%02d' $((10#$base + i))).json"
        json=$(printf '%s' "$ob" | jq '{outbounds: [.]}')
        (( i == 0 )) && backup_config config      # 整批只备份一次, 免得刷屏
        if ! write_config "$file" "$json"; then
            for f in "${files[@]}"; do rm -f "$f"; done
            print_error "写入失败, 已撤销本次导入的全部文件"
            return 1
        fi
        files+=("$file"); i=$((i+1))
    done
    if ! sb_check; then
        for f in "${files[@]}"; do rm -f "$f"; done
        if sb_check_quiet; then
            print_error "本次配置未通过 sing-box check, 已删除 ${#files[@]} 个文件"
            print_ok    "其余配置合法, 现网未受影响"
        else
            print_error "本次配置已删除, 但移除后整体 check 仍失败 —— 存在其它历史问题, 请先修复:"
            sb_check
        fi
        return 1
    fi
    sb_reload || true
    SB_LAST_OUT_FILE="${files[0]}"; SB_LAST_OUT_TAG="$main_tag"
    print_ok "出站已添加: $main_tag  (${#files[@]} 个文件: $(printf '%s ' "${files[@]##*/}"))"
    [[ "$cnt" -gt 1 ]] && print_info "  其中包含随附的依赖出站 (detour 组合), 已一并写入"
    print_info "接下来: 5) 用于域名分流   8) 绑定到入站   10) 做连通性自检"
}

# ==============================================================
# 3b. 远程配置 (分享链接) 导入
#
# 复用的就是项目已有的分享服务本身, 不另造一套订阅系统:
#   对方跑 sing-box-core -> share.sh 生成 http://<ip>:9292/share/<token>
#   -> 公共分享服务下发一份 sing-box 配置 JSON (其中的 .outbounds[]
#      每一项本身就是完整可用的 outbound, 因此不需要"协议解析/字段转换")
# 客户端 client.sh add_node 拉的是同一种东西, 这里保持完全一致的
# HTTP 语义与校验顺序。
# ==============================================================
ob_remote_closure() { # <cache> <tag...> -> 选中项 + 其 detour 依赖, 空格分隔
    python3 - "$1" "${@:2}" <<'OBRC'
import json, sys
obs = json.load(open(sys.argv[1])).get("outbounds", [])
by = {o.get("tag"): o for o in obs if isinstance(o, dict)}
out, stack = [], list(sys.argv[2:])
while stack:
    t = stack.pop(0)
    if t in out or t not in by:
        continue
    out.append(t)
    d = by[t].get("detour")
    if isinstance(d, str) and d and d not in out:
        stack.append(d)
print(" ".join(out))
OBRC
}

remote_add() {
    print_title "从远程配置导入出站"
    echo -e "  ${CYAN}填对方的分享链接 / 远程配置 URL (http://<ip>:9292/share/<token>)${RESET}" >&2
    local url py cache res ok
    sb_ask "  远程配置 URL: "; url="$REPLY"
    url=$(clean_input "$url")
    [[ -z "$url" ]] && { print_error "未输入 URL"; return 1; }
    [[ "$url" =~ ^https?:// ]] || { print_error "必须以 http:// 或 https:// 开头"; return 1; }

    py=$(ob_remote_parser) || return 1
    cache=$(mktemp "$SB_OUT_DIR/.remote-XXXXXX.json") || { print_error "无法创建临时文件"; return 1; }
    print_info "正在拉取远程配置..."
    res=$(python3 "$py" fetch "$url" "$cache" 2>&1)
    if [[ "$(printf '%s' "$res" | jq -r '.ok' 2>/dev/null)" != "true" ]]; then
        rm -f "$cache"
        print_error "无法使用该远程配置"
        printf '%s' "$res" | jq -r '.error // "拉取器无输出"' >&2 | while IFS= read -r l; do
            [[ -n "$l" ]] && printf '  %s\n' "$l" >&2
        done
        return 1
    fi
    print_ok "远程配置已获取"
    local has_kernel=1
    [[ "$(printf '%s' "$res" | jq -r '[.nodes[]|select(.valid==false)]|length')" -gt 0 ]] && has_kernel=0

    # ---- 节点清单 ----
    local total main_n
    total=$(printf '%s' "$res" | jq -r '.nodes|length')
    main_n=$(printf '%s' "$res" | jq -r '[.nodes[]|select(.role=="main")]|length')
    print_title "检测到 $total 个出站 (其中 $main_n 个是可直接使用的节点)"
    printf '%s' "$res" | jq -r '.nodes[] |
        "  \(.tag)  | 协议: \(.type)  | 端点: \(if .server==null then "(经 detour 转发)" else "\(.server):\(.port)" end)"
        + (if .role=="main" then "" else "  ↳ 随附(被 detour 引用)" end)
        + (if .valid then "" else "\n      ✗ 本机内核不可用: \(.err)" end)' >&2
    if (( has_kernel == 0 )); then
        print_warn "带 ✗ 的出站无法在本机内核上通过 sing-box check, 不能导入"
    fi
    local probs; probs=$(printf '%s' "$res" | jq -r '.problems|join("\n")')
    if [[ -n "$probs" && "$probs" != "null" ]]; then
        print_warn "以下出站缺少必要字段, 导入后很可能连不通 (sing-box check 并不校验这些):"
        printf '%s\n' "$probs" | sed 's/^/    /' >&2
    fi

    # ---- 选择 ----
    echo >&2
    local c picks
    sb_ask "  导入哪个? (编号=单个节点 / all=全部可用 / 0=取消): "; c="$REPLY"
    c=$(clean_input "$c")
    if [[ -z "$c" || "$c" == "0" ]]; then print_warn "已取消, 未写入任何文件"; rm -f "$cache"; return 0; fi
    if [[ "$c" == "all" ]]; then
        picks=$(printf '%s' "$res" | jq -r '[.nodes[]|select(.role=="main" and .valid)|.tag]|join(" ")')
        [[ -n "$picks" ]] || { print_error "没有可导入的节点"; rm -f "$cache"; return 1; }
        local skipped
        skipped=$(printf '%s' "$res" | jq -r '[.nodes[]|select(.role=="main" and (.valid|not))|.tag]|join(", ")')
        [[ -z "$skipped" ]] || print_warn "将跳过 (本机内核不支持): $skipped"
    elif [[ "$c" =~ ^[0-9]+$ ]]; then
        local sel
        sel=$(printf '%s' "$res" | jq -r --argjson i "$c" '.nodes | if ($i>=1 and $i<=length) then .[$i-1] else empty end')
        [[ -n "$sel" ]] || { print_error "编号超出范围 (可选 1-$total)"; rm -f "$cache"; return 1; }
        if [[ "$(printf '%s' "$sel" | jq -r '.valid')" != "true" ]]; then
            print_error "该出站在本机内核上不可用, 已放弃导入:"
            # 原这行第二个括号没闭合, bash 把 $(( ... )) 当成算术展开,
            # 界面会漏出 "line NNN: .type: command not found"。下面这行才是实际输出。
            printf '%s' "$sel" | jq -r '"  " + .tag + " (" + .type + "): " + (.err // "?")' >&2
            rm -f "$cache"; return 1
        fi
        picks=$(printf '%s' "$sel" | jq -r '.tag')
    else
        # 直接输入 tag: 必须确认它确实存在, 否则后面会一路走到"列表非法"并泄漏内部报错
        # 输入既不是编号也不是已存在的 tag -> 统一按"编号不合法"提示,
        # 而不是回一句"没有这个 tag", 会让人以为自己输入的 tag 有拼写问题
        if [[ "$c" =~ ^[0-9]+$ ]]; then
            print_error "编号超出范围 (可选 1-$total, 或输入 all, 或 0 取消)"
            rm -f "$cache"; return 1
        fi
        if [[ "$(printf '%s' "$res" | jq -r --arg t "$c" '[.nodes[]|select(.tag==$t)]|length')" == "0" ]]; then
            print_error "无效输入: $c"
            print_error "请输入列表里的编号 (1-$total), 或 all, 或 0 取消; 也可直接输入清单里存在的 tag"
            rm -f "$cache"; return 1
        fi
        picks="$c"
    fi

    # ---- detour 依赖闭包 ----
    local full extra
    full=$(ob_remote_closure "$cache" $picks)
    if [[ "$(printf '%s' "$full" | tr ' ' '\n' | wc -l)" -gt "$(printf '%s' "$picks" | wc -w)" ]]; then
        extra=$(printf '%s\n' $full | tr ' ' '\n' | grep -vxF "$(printf '%s' "$picks" | tr ' ' '\n')" | tr '\n' ' ')
        print_info "所选节点依赖以下出站, 将一并导入: $extra"
    fi

    # ---- 预览 (脱敏) ----
    print_title "导入预览 (敏感项已脱敏)"
    local t
    for t in $full; do
        printf '  • %s\n' "$t" >&2
        python3 "$py" preview "$cache" "$t" 2>&1 | sed 's/^/      /' >&2
    done
    echo >&2
    ob_ask_yesno "  确认导入以上出站? [Y/n]: " y || { print_warn "已取消, 未写入任何文件"; rm -f "$cache"; return 0; }

    # ---- tag 改名, detour 指向同步跟随 ----
    local idx map_json="" nt
    idx=$(get_next_index "$PROTO")
    for t in $full; do
        nt=$(ob_sanitize_tag "$t" "out$idx" "$idx")
        [[ "$nt" != "$t" ]] && map_json=$(printf '%s' "$map_json" | jq -s --arg o "$t" --arg n "$nt" '.[0] + {($o):$n}')
    done
    local arr cnt
    arr=$(python3 - "$cache" "$full" "$map_json" <<'OBRA'
import json, sys
obs = json.load(open(sys.argv[1])).get("outbounds", [])
rmap = json.loads(sys.argv[3]) if sys.argv[3].strip() else {}
by = {o.get("tag"): o for o in obs if isinstance(o, dict)}
res = []
for t in sys.argv[2].split():
    o = by.get(t)
    if not o:
        continue
    o = json.loads(json.dumps(o))
    d = o.get("detour")
    if isinstance(d, str) and d:
        o["detour"] = rmap.get(d, d)
    o["tag"] = rmap.get(t, t)
    res.append(o)
print(json.dumps(res, ensure_ascii=False))
OBRA
)
    cnt=$(printf '%s' "$arr" | jq -r 'length')
    rm -f "$cache"
    ob_commit_multi "$arr" "$(printf '%s' "$arr" | jq -r '.[0].tag')" "$cnt"
}

add_config() {
    while true; do
        print_title "新增出站"
        echo -e "${CYAN}1)${RESET} 手动添加出站 (按协议填写字段)" >&2
        echo -e "${CYAN}2)${RESET} 从分享链接添加出站 (粘贴节点 URI)" >&2
        echo -e "${CYAN}3)${RESET} 从远程配置导入 (对方分享链接 / URL)" >&2
        echo -e "${CYAN}0)${RESET} 取消" >&2
        sb_ask "请选择: "; c="$REPLY"
        case "$(clean_input "$c")" in
            1) manual_add; return $? ;;
            2) share_add; return $? ;;
            3) remote_add; return $? ;;
            0|"") return 0 ;;
            *) print_error "无效选项" ;;
        esac
    done
}

# ==============================================================
# 5. 列出 (脱敏)
# ==============================================================
list_configs() {
    print_title "出站列表 (密码 / UUID / token 一律脱敏)"
    local f num
    shopt -s nullglob
    local files=("$SB_CONFIG_DIR"/$PROTO-*.json)
    shopt -u nullglob
    if ((${#files[@]} == 0)); then print_warn "还没有自定义出站"; return 0; fi
    for f in "${files[@]}"; do
        num=$(basename "$f" .json | cut -d'-' -f2)
        jq -r '.outbounds[]? |
            def authstate:
                if   (.password? // "") != "" or (.uuid? // "") != "" or (.method? // "") != "" then "已配置"
                elif (.username? // "") != "" then "已配置(仅用户名)" else "无" end;
            def tlsstate: if .tls? then (if .tls.enabled == true then "开启" else "关闭" end) else "-" end;
            [ "[" + $num + "]", (.tag // "-"), (.type // "-"),
              ((.server // "-") + ":" + ((.server_port // "-")|tostring)),
              "认证=" + authstate, "TLS=" + tlsstate, "传输=" + (.transport.type? // "-") ]
            | join("  ")' --arg num "$num" "$f" 2>/dev/null | while IFS= read -r line; do printf "%s\n" "$line" >&2; done
    done
    echo >&2
    print_info "原始配置(含凭据)位于: $SB_CONFIG_DIR/$PROTO-NN.json"
}

# ==============================================================
# 6. 删除 (引用保护 + 自检失败自动回退 direct)
# ==============================================================
delete_config() {
    list_configs
    sb_ask "输入要删除的编号: "; num="$REPLY"
    num=$(clean_input "$num")
    [[ "$num" =~ ^[0-9]+$ ]] || { print_error "编号必须数字"; return 1; }
    local idx file tag refs otype swapped
    idx=$(printf "%02d" "$num")
    file="$SB_CONFIG_DIR/$PROTO-$idx.json"
    if [[ ! -f "$file" ]]; then
        print_error "编号不存在: $PROTO-$idx.json"
        # 编号按文件名走, 删过文件后会出现空洞, 直接把当前可删的编号列出来
        print_info "当前可删除的编号: $(ls "$SB_CONFIG_DIR"/$PROTO-*.json 2>/dev/null \
            | xargs -r -n1 basename | sed "s/\.json$//" | tr "\n" " ")"
        return 1
    fi
    tag="$(jq -r '.outbounds[0].tag // empty' "$file" 2>/dev/null)"
    [[ -n "$tag" ]] || { print_error "读不出 tag, 已放弃"; return 1; }
    otype="$(jq -r '.outbounds[0].type // empty' "$file" 2>/dev/null)"
    refs=$(jq '[.route.rules[]? | select(.outbound? == $t)] | length' --arg t "$tag" "$ROUTE_FILE" 2>/dev/null || echo 0)
    if (( refs > 0 )); then
        sb_ask "该出站被 $refs 条 分流/绑定 规则引用; 删除后规则改回 direct? [Y/n]: "; fc="$REPLY"
        fc=$(clean_input "$fc"); [[ -z "$fc" ]] && fc=y
        [[ "$fc" =~ ^[yY] ]] || { print_warn "已取消"; return 0; }
    fi
    case "$otype" in
        direct|block) print_info "$otype 为特殊出站, 跳过连通性自检" ;;
        *) selftest_outbound "$file" "$tag" 2 || {
                # 不要无条件承诺"会把规则改回 direct": 没有任何规则引用它时这句话
                # 与结尾的"没有规则引用它, 无需改写路由"同屏自相矛盾
                if (( refs > 0 )); then
                    print_warn "$tag 自检失败, 下面会把引用它的 $refs 条规则改回 direct"
                else
                    print_warn "$tag 自检失败 (没有规则引用它, 路由无需改写)"
                fi
            } ;;
    esac
    rm -f "$file"
    # 关键: 用户同意删除时, 引用保护必须真的执行, 且与自检成败无关。
    # 旧实现只在"自检失败"分支里改写, 自检通过时却照样打印 "已切回 direct",
    # 留下悬空 tag -> 运行时报 outbound not found, 该域名直接黑洞(不是降级直连),
    # 而 sing-box check 对此完全无感, 用户拿不到任何预警。
    if swap_outbound_rules "$tag"; then
        swapped=1
    else
        swapped=0
    fi
    if sb_check; then
        sb_reload || true
        print_ok "已删除出站 $tag"
        if (( swapped )); then
            print_ok "引用它的规则已改回 direct"
        elif (( refs > 0 )); then
            print_warn "仍有 $refs 条规则引用 $tag —— 已无法解析, 建议手动检查 $ROUTE_FILE"
        else
            print_info "没有规则引用它, 无需改写路由"
        fi
    else
        print_error "删除后 sing-box check 失败; 若是悬空 tag 引用, 请检查 $ROUTE_FILE"
        return 1
    fi
}

# ==============================================================
# 7. 域名分流 + 入站绑定 (沿用既有交互, 仅修正无出站时的空标签)
# ==============================================================
ROUTE_FILE="$SB_CONFIG_DIR/03-route.json"
all_outbound_tags() {
    # 排除"00-direct"之类的固定项, 以及被别的出站通过 detour 引用的外壳:
    # 外壳自身没有协议, 单独选它必然连不通 (ShadowTLS 就是这种结构)
    local dep
    dep=$(jq -s -r '[.[]?.outbounds[]? | .detour? // empty] | unique | .[]' \
        "$SB_CONFIG_DIR"/*.json 2>/dev/null)
    jq -r '.outbounds[]?.tag' "$SB_CONFIG_DIR"/*.json 2>/dev/null |
        grep -vE "^(00-(direct|dns))" | sort -u |
        while read -r t; do
            [[ -n "$t" ]] || continue
            if printf '%s\n' "$dep" | grep -qxF "$t"; then continue; fi
            echo "$t"
        done
}

outbound_pick() {
    local i=1 t choices=()
    echo -e "${CYAN}可选出站/节点 tag:${RESET}" >&2
    echo "--------------------------------------------------------" >&2
    for t in $(all_outbound_tags); do
        echo -e "  ${GREEN}$i${RESET}) ${YELLOW}$t${RESET}" >&2
        choices+=("$t"); i=$((i+1))
    done
    echo -e "    ${CYAN}$i${RESET}) direct (默认)" >&2
    echo "--------------------------------------------------------" >&2
    sb_ask "选择编号 / 直接输入 tag (默认 direct): "; n="$REPLY"
    n=$(clean_input "$n"); [[ -z "$n" ]] && { echo "direct"; return; }
    if [[ "$n" =~ ^[0-9]+$ ]]; then
        (( n <= ${#choices[@]} )) && { echo "${choices[$((n-1))]}"; return; }
        echo ""; return
    fi
    echo "$n"
}

split_add() {
    local dom out
    dom=$(safe_read "要分流的域名 (支持子域 suffix 匹配, 如 example.com)" "")
    [[ -z "$dom" ]] && { print_error "未输入域名"; return 1; }
    out=$(outbound_pick); [[ -z "$out" ]] && { print_error "未选择出站/编号无效"; return 1; }
    local replaced
    replaced=$(python3 - "$ROUTE_FILE" "$dom" "$out" <<'PYS'
import json,sys
rf,dom,out=sys.argv[1:]
try: d=json.load(open(rf))
except Exception: d={}
d.setdefault("route",{}).setdefault("rules",[])
rules=d["route"]["rules"]
# sing-box 路由是"先匹配先赢", 同域名再追加一条只会永远匹配不到(死代码),
# 却让用户以为流量已经切过去了。这里改为替换。
hit=[r for r in rules if dom in (r.get("domain_suffix") or [])]
if hit:
    for r in hit:
        r["outbound"]=out
    print(len(hit))
else:
    rules.append({"domain_suffix":[dom],"outbound":out})
    print(0)
json.dump(d,open(rf,"w"),indent=2)
PYS
)
    if (( replaced > 0 )); then
        print_info "已替换同域名 $dom 的既有规则 $replaced 条 (追加会让新规则永远匹配不到)"
    fi
    sb_check && sb_reload && print_ok "域名分流已生效: *$dom -> $out"
}

split_list() {
    jq -r '.route.rules[]? | select(.domain_suffix != null) | "\(.domain_suffix|join(","))  ->  \(.outbound)"' "$ROUTE_FILE" 2>/dev/null | nl -ba
}

split_del() {
    local n; n=$(safe_read "要删除第几条分流 (0=全部)" "0")
    [[ "$n" =~ ^[0-9]+$ ]] || { print_error "请输入编号"; return 1; }
    python3 - "$ROUTE_FILE" "$n" <<'PYS'
import json,sys
rf,n=sys.argv[1:3]
d=json.load(open(rf))
rules=d.get("route",{}).get("rules",[])
keep=[]; i=0
for r in rules:
    if "domain_suffix" in r:
        i+=1
        if n!="0" and str(i)!=n: keep.append(r)
        continue
    keep.append(r)
d["route"]["rules"]=keep
json.dump(d,open(rf,"w"),indent=2)
PYS
    sb_check && sb_reload && print_ok "分流规则已更新"
}

all_inbound_tags() {
    jq -r '.inbounds[]?.tag' "$SB_CONFIG_DIR"/*.json 2>/dev/null | sort -u
}

bind_add() {
    local i=1 in_ choices=() out
    echo -e "${CYAN}可选入站 (节点/端口转发):${RESET}" >&2
    echo "--------------------------------------------------------" >&2
    for in_ in $(all_inbound_tags); do
        echo -e "  ${GREEN}$i${RESET}) ${YELLOW}$in_${RESET}" >&2
        choices+=("$in_"); i=$((i+1))
    done
    [[ ${#choices[@]} -eq 0 ]] && { print_warn "当前没有入站"; return 1; }
    echo "--------------------------------------------------------" >&2
    sb_ask_loop "选择入站编号: " || return 1; c="$REPLY"
    c=$(clean_input "$c")
    if [[ "$c" =~ ^[0-9]+$ ]]; then
        (( c >= 1 && c <= ${#choices[@]} )) || { print_error "无效编号"; return 1; }
        in_="${choices[$((c-1))]}"
    else in_="$c"; fi
    # 面板对 rule_set / dns.final / detour 都做了"引用必须真实存在"的校验
    # (sing-box check 查不出这些, 只能自己拦); 入站 tag 同理, 写一个不存在的
    # inbound 会让该规则永远匹配不到, 面板却显示"已生效"。
    # 必须用 -s 汇总成单个文档: jq -e 在多文件输入时, 退出码只反映**最后一个**文档
    # 的结果, 最后一个文件没有 inbound 就会把存在的 tag 误判为不存在
    if ! jq -s -e --arg t "$in_" 'any(.[]?; any(.inbounds[]?; .tag == $t))' "$SB_CONFIG_DIR"/*.json >/dev/null 2>&1; then
        print_error "入站不存在: $in_"
        print_info "当前可用入站: $(all_inbound_tags | tr "\n" " ")"
        return 1
    fi
    out=$(outbound_pick); [[ -z "$out" ]] && { print_error "未选择出站"; return 1; }
    python3 - "$ROUTE_FILE" "$in_" "$out" <<'PYS'
import json,sys
rf,ib,out=sys.argv[1:]
try: d=json.load(open(rf))
except Exception: d={}
rules=d.setdefault("route",{}).get("rules",[])
rules=[r for r in rules if not ("inbound" in r and r["inbound"]==[ib])]
rules.append({"inbound":[ib],"outbound":out})
d["route"]["rules"]=rules
json.dump(d,open(rf,"w"),indent=2)
PYS
    sb_check && sb_reload && print_ok "入站绑定已生效: $in_ -> $out"
}

bind_del() {
    local n cnt
    cnt=$(jq -r '[.route.rules[]? | select(.inbound != null and .outbound != null)] | length' "$ROUTE_FILE" 2>/dev/null || echo 0)
    n=$(safe_read "要删除第几条绑定 (0=全部)" "")
    [[ "$n" =~ ^[0-9]+$ ]] || { print_error "请输入编号"; return 1; }
    # 原来的默认值是 0 = 全部: 回车或 stdin EOF 都会静默清空所有入站绑定, 且只提示"已更新"
    if [[ "$n" == "0" ]] && (( cnt > 0 )); then
        print_warn "这将删除全部 $cnt 条入站绑定"
        sb_ask "  确认清空? [y/N]: "
        [[ "$REPLY" =~ ^[yY] ]] || { print_warn "已取消"; return 0; }
    fi
    python3 - "$ROUTE_FILE" "$n" <<'PYS'
import json,sys
rf,n=sys.argv[1:3]
d=json.load(open(rf))
rules=d.get("route",{}).get("rules",[])
keep=[]; i=0
for r in rules:
    if "inbound" in r and "outbound" in r:
        i+=1
        if n!="0" and str(i)!=n: keep.append(r)
        continue
    keep.append(r)
d.setdefault("route",{})["rules"]=keep
json.dump(d,open(rf,"w"),indent=2)
PYS
    sb_check && sb_reload && print_ok "绑定规则已更新"
}
bind_list() { jq -r '.route.rules[]? | select(.inbound != null) | "\(.inbound|join(","))  ->  \(.outbound)"' "$ROUTE_FILE" 2>/dev/null | nl -ba; }

# ==============================================================
# 8. QA: 自检 + 失败自动回退 direct
# ==============================================================
# 该 outbound 是否只是别人的 detour 外壳 (自身没有协议, 单独测必然失败)
is_detour_dep() { # <tag>
    jq -s -e --arg t "$1" 'any(.[]?; any(.outbounds[]?; .detour? == $t))' "$SB_CONFIG_DIR"/*.json >/dev/null 2>&1
}

selftest_outbound() { # selftest_outbound <out_file> <tag> [tries]
    local file="$1" tag="$2" tries="${3:-2}" k port pid r ok=0
    [[ -f "$file" ]] || return 1
    for ((k=1; k<=tries; k++)); do
        port=$(( 23000 + RANDOM % 2000 ))
        python3 - "$file" "$port" "$tag" "$SB_CONFIG_DIR" <<'PYS'
import json,os,sys
f,port,tag,cfgdir=sys.argv[1:5]
o=json.load(open(f))["outbounds"]
# detour 组合 (如 ShadowTLS 外壳 + 内层 SS) 必须成对加载, 单独测内层必然失败
need=[ob.get("detour") for ob in o if isinstance(ob.get("detour"),str)]
if need:
    have={x.get("tag") for x in o}
    for g in sorted(os.listdir(cfgdir)):
        if not g.endswith(".json"): continue
        try: d=json.load(open(os.path.join(cfgdir,g)))
        except Exception: continue
        for x in d.get("outbounds",[]):
            if isinstance(x,dict) and x.get("tag") in need and x.get("tag") not in have:
                o.append(x); have.add(x.get("tag"))
cfg={"log":{"level":"warn"},
     "inbounds":[{"type":"mixed","tag":"mix","listen":"127.0.0.1","listen_port":int(port)}],
     "outbounds":o,
     "route":{"final":tag}}
json.dump(cfg,open("/tmp/sb-out-selftest.json","w"))
PYS
        timeout 20 "$SB_BIN" run -c /tmp/sb-out-selftest.json >/dev/null 2>/tmp/sb-selftest.err &
        pid=$!
        sleep 1
        r=$(timeout 12 curl -s --max-time 10 -x "http://127.0.0.1:$port" -o /dev/null -w "%{http_code}" https://www.gstatic.com/generate_204 2>/dev/null)
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        [[ "$r" == "204" ]] && ok=$((ok+1))
    done
    if (( ok == tries )); then print_ok "出站 [$tag] 自检通过 ($tries/$tries)"; return 0
    elif (( ok > 0 )); then print_warn "出站 [$tag] 自检部分通过 ($ok/$tries) - 按可用处理"; return 0
    else print_error "出站 [$tag] 自检失败 0/$tries (无法连通, 可能是服务器地址/凭据/防火墙问题)"; return 1; fi
}

swap_outbound_rules() { # <tag> -> 0=确有规则被改回 direct / 1=没有任何规则引用它
    local tag="$1" rf="$ROUTE_FILE"
    [[ -f "$rf" ]] || return 1
    jq -e --arg t "$tag" 'any(.route.rules[]?; .outbound? == $t)' "$rf" >/dev/null 2>&1 || return 1
    jq --arg t "$tag" '.route.rules |= map(if (.outbound? == $t) then (.outbound = "direct") else . end)' "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
}

selftest_all() {
    local f tag otype n=0
    shopt -s nullglob
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        tag=$(jq -r '.outbounds[0].tag // empty' "$f" 2>/dev/null)
        otype=$(jq -r '.outbounds[0].type // empty' "$f" 2>/dev/null)
        [[ -n "$tag" ]] || continue
        n=$((n+1))
        case "$otype" in
            direct|block) print_info "$tag ($otype) 特殊出站, 跳过自检" ;;
            *) if is_detour_dep "$tag"; then
                    print_info "$tag 是 detour 外壳 (被别的出站通过 detour 引用), 单独不连通属正常; 已随宿主一起测试"
                   elif selftest_outbound "$f" "$tag" 2; then :
                   elif swap_outbound_rules "$tag"; then print_warn "$tag 自检失败 -> 引用它的规则已改回 direct"
                   else print_warn "$tag 自检失败 (没有规则引用它)"; fi ;;
        esac
    done
    shopt -u nullglob
    (( n == 0 )) && { print_warn "没有可自检的自定义出站"; return 0; }
    print_info "自检结束: 共检查 $n 个出站 (回退结果见上方逐条提示)"
    sb_check && sb_reload || true
}

# ==============================================================
# 菜单
# ==============================================================
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        add)  add_config ;;
        list) list_configs ;;
        del)  delete_config ;;
        share) share_add ;;
        check) sb_check ;;
        selftest) shift; selftest_outbound "$@" || true ;;
        swap) swap_outbound_rules "$2"; sb_check && sb_reload || true ;;
        *)
            while true; do
                print_title "出站管理"
                echo -e "${CYAN}1)${RESET} 手动添加出站 (socks/http/ss/vmess/vless/trojan/hy2/tuic/anytls/shadowtls + selector/urltest)"
                echo -e "${CYAN}2)${RESET} 从分享链接添加出站 (ss/vmess/vless/trojan/hy2/tuic)"
                echo -e "${CYAN}3)${RESET} 列出出站 (脱敏)"
                echo -e "${CYAN}4)${RESET} 删除出站"
                echo -e "${CYAN}5)${RESET} 域名分流 (添加规则: 指定域名 → 指定出站)"
                echo -e "${CYAN}6)${RESET} 域名分流 (列出规则)"
                echo -e "${CYAN}7)${RESET} 域名分流 (删除规则)"
                echo -e "${CYAN}8)${RESET} 入站绑定出站 (添加: 节点/端口 → 出站)"
                echo -e "${CYAN}9)${RESET} 入站绑定出站 (删除)"
                echo -e "${CYAN}10)${RESET} 出站自检 + 失败自动回退 direct (全量自检)"
                echo -e "${CYAN}0)${RESET} 返回"
                sb_ask "请选择: "; c="$REPLY"
                case "$(clean_input "$c")" in
                    1)  add_config ;;
                    2)  share_add ;;
                    3)  list_configs ;;
                    4)  delete_config ;;
                    5)  split_add ;;
                    6)  split_list ;;
                    7)  split_del ;;
                    8)  bind_add ;;
                    9)  bind_del ;;
                    10) selftest_all ;;
                    0)  break ;;
                    *)  ;;
                esac
                read -r -p "按回车继续..." _ || { echo; exit 0; }
            done ;;
    esac
fi
