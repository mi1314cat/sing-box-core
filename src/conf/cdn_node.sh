#!/usr/bin/env bash
# cdn_node.sh — 单节点 CDN 客户端产物
#
# 直连节点和 CDN 节点要能分别导出:
#   sb_client-<tag>.json / .yaml       直连版 (连服务器 IP)
#   sb_client-<tag>.cdn.json / .yaml   CDN 版 (连域名, 走 Cloudflare)
#
# CDN 版不是简单替换地址 —— Cloudflare 在边缘终止 TLS 并按 path 转发,
# 客户端只需连域名:443, 不再关心源站端口。
# 两个文件同时产出, 用户按需选, 互不干扰。

# ---------- 连接地址选择 (IPv4 / 真实 IPv6, 绝不用 WARP 的) ----------
# 用户可能套了 WARP: 那时 WARP 接口上的 IPv6 只能经 WARP 出口访问,
# 客户端拿去直连必然失败。所以这里显式排除隧道接口。
sb_pick_connect_addr() {
    local v4 v6
    v4=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 |
         grep -vE '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -1)
    v6=$(sb_real_ipv6 2>/dev/null)

    if [[ -n "$v4" && -n "$v6" ]]; then
        echo "$v4"; return 0
    elif [[ -n "$v6" ]]; then
        print_info "无公网 IPv4, 使用网卡真实 IPv6: $v6"
        sb_warp_active && print_info "检测到 WARP 在运行 —— 已排除 WARP 地址"
        echo "$v6"; return 0
    fi
    v4=$(default_server_ip 2>/dev/null)
    [[ -n "$v4" ]] && { echo "$v4"; return 0; }
    return 1
}

# ---------- 单节点 CDN 分享链接 ----------
# 主链接生成时已按 CDN 模式写成 域名:443, 这里派生一份带 .cdn 标记的副本
cdn_node_share_link() {
    local tag="$1" src="$SB_OUT_DIR/sb_share-$tag.txt" out
    [[ -f "$src" ]] || return 1
    out="$SB_OUT_DIR/sb_share-$tag.cdn.txt"
    cp -f "$src" "$out" 2>/dev/null && print_ok "CDN 分享链接: $out"
}

# ---------- 单节点 CDN mihomo YAML ----------
# to_mihomo.py 是 YAML 转换的唯一真源, 这里复用它, 不另写转换逻辑
cdn_node_client_yaml() {
    local tag="$1"
    local here; here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
    [[ -f "$SB_OUT_DIR/sb_client-$tag.cdn.json" ]] || return 1
    python3 "$here/to_mihomo.py" --single "$SB_OUT_DIR" "$SB_ROOT/cert" \
        "$SB_OUT_DIR/sb_client-$tag.cdn.json" >/dev/null 2>&1
    [[ -f "$SB_OUT_DIR/sb_client-$tag.cdn.yaml" ]] && print_ok "CDN YAML: $SB_OUT_DIR/sb_client-$tag.cdn.yaml"
}

# ---------- 为单个节点生成 CDN 版产物 ----------
# 建节点时主产物 (sb_client-<tag>.json) 已按 CDN 模式生成 (域名:443),
# 这里补齐两样:
#   .cdn.*  —— 显式标记 CDN 版的副本, 便于批量收集/分发时一眼区分
#   .cdn.yaml —— mihomo YAML, 同一份 to_mihomo.py 转换
# 主产物本身已是 CDN 版, 不再重复改写服务器地址。
cdn_node_gen_all() {
    local tag="$1" src="$SB_OUT_DIR/sb_client-$tag.json"
    [[ -f "$src" ]] || return 1
    cp -f "$src" "$SB_OUT_DIR/sb_client-$tag.cdn.json" 2>/dev/null \
        && print_ok "CDN 客户端配置: $SB_OUT_DIR/sb_client-$tag.cdn.json"
    cdn_node_client_yaml "$tag"
}

# ---------- 直连版产物: 连接地址按 IPv4/真实 IPv6 选择 ----------
cdn_direct_addr_hint() {
    local a; a=$(sb_pick_connect_addr) || return 1
    [[ "$a" == *:* ]] && print_info "直连地址使用网卡真实 IPv6: $a"
    printf '%s' "$a"
}

# ---------- 为所有 CDN 节点生成产物 ----------
cdn_gen_all_nodes() {
    local f tag n=0
    shopt -s nullglob
    for f in "$SB_CONFIG_DIR"/*.json; do
        [[ "$(basename "$f")" =~ ^(00-|01-|02-|03-) ]] && continue
        sb_cdn_enabled "$f" || continue
        tag=$(jq -r '.inbounds[0].tag' "$f" 2>/dev/null)
        cdn_node_gen_all "$tag" >/dev/null 2>&1 && n=$((n+1))
    done
    shopt -u nullglob
    if (( n == 0 )); then
        print_warn "没有可走 CDN 的节点 (需: ws/grpc/http 传输 + 真证书)"
        return 1
    fi
    print_ok "已生成 $n 个节点的 CDN 版产物 (文件名带 .cdn)"
}
