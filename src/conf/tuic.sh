#!/bin/bash
# ==============================================================
# tuic.sh — TUIC v5 节点模块 (quic, 需证书)
# 真证书/自签均可；uuid + password 混合认证
# CLI: bash tuic.sh [add|list|del]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="tuic"
CERT_DIR="$SB_ROOT/cert"
random_domain() { reality_random_domain; }

extract_cert_domain() {
    local crt="$1" dom=""
    command -v openssl >/dev/null && [[ -f "$crt" ]] && dom=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -oE "DNS:[^,]+" | head -1 | cut -d: -f2)
    [[ -z "$dom" ]] && dom=$(basename "$crt" | sed -E 's/\.(crt|pem)$//; s/_cert$//; s/^cert-//')
    echo "$dom"
}

ask_cert() {
    echo "TLS 证书：" >&2
    echo "  1) 手动输入 crt/key 路径" >&2
    echo "  2) 生成自签证书" >&2
    # 预置方案点名要真证书时, 默认值落到 1 (手动输入 crt/key); 否则默认 2=自签
    local tdef=2 thint=""
    case "${SB_PRESET_CERT:-}" in
        真证书|real) tdef=1; thint=" (预置方案指定真证书, 请填 crt/key 路径)" ;;
        selfsign)    thint=" (预置方案指定自签)" ;;
    esac
    [[ -n "$thint" ]] && echo -e "    ${MAGENTA}${thint}${RESET}" >&2
    local c=""; read -r -p "  选择 (默认 ${tdef}): " c; c=$(clean_input "$c")
    [[ -z "$c" ]] && c=$tdef
    # 批量选了真证书就改判到真证书分支, 否则这里默认 2=自签 会把 ③ 的选择架空
    sb_batch_tls_override 1 c
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
    # 批量用 batch 入口选好的证书; 交互模式列出本机证书让你选
    [[ -n "${SB_BATCH:-}" ]] && { sb_apply_batch_cert; return $?; }
    pick_trusted_cert_verbose
}

add_config() {
    print_title "新增 TUIC v5 节点 ($PROTO-NN.json)"
    local listen_ip listen_port uuid password idx file tag json
    listen_ip=$(ask_listen_addr)
    listen_port=$(safe_read_port "8443")
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
    password=$(openssl rand -hex 16)
    sb_ask_preset tuic "推荐配置"
    ask_cert || return 1

    # ECH (可选): 这三个协议没有 Reality 可选, 内核 ECH 是它们唯一的
    # SNI 隐藏手段。默认关闭; 开启后仅 sing-box 客户端可用 (需内联
    # ECHConfigList, mihomo/Clash 不支持) —— 实测 anytls/hysteria2/tuic
    # 端到端 3/3, 服务端无 "server rejected ECH"。
    # 这三个协议只走直连, 没有 CDN 在中间终结 TLS, 所以固定 direct。
    sb_ask_ech "$CERT_DOMAIN" direct
    local congestion
    congestion=$(safe_read "拥塞控制 (bbr/cubic/new-reno)" "bbr")
    case "$congestion" in bbr|cubic|new-reno) ;; *) congestion="bbr"; print_warn "未知算法, 已回落 bbr" ;; esac

    # 取序号与文件路径 (这两行之前被改 tag 时误删了 —— 结果 write_config 收到
    # 空的路径, 报 "lib.sh: line 1965: : No such file or directory")
    idx=$(get_next_index "$PROTO"); file="$SB_CONFIG_DIR/$PROTO-$idx.json"
    # 名称要在 ECH 定了之后再算 (见 sb_resolve_tag)
    SB_TAG_FORM="tls"; sb_resolve_tag tls
    tag="${PROTO}${idx}$(tag_form_suffix tls "$SB_TAG_EXTRA")"   # 名字体现方案
    # 内核 ECH: 我们自己终结 TLS, 解密 inner ClientHello 靠的就是这把私钥
    local ech_srv; ech_srv=$(sb_ech_json_server)
    local ech_sep=""; [[ -n "$ech_srv" ]] && ech_sep=", $ech_srv"
    json=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "tuic",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "users": [ { "uuid": "$uuid", "password": "$password" } ],
      "congestion_control": "$congestion",
      "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$CERT_FILE", "key_path": "$KEY_FILE"$ech_sep }
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

    local server_ip; server_ip=$(ask_server_addr)
    # 节点名前缀: 紧跟地址选择问一次, 全部协议统一入口
    sb_ask_server_name_hook
    local link="tuic://$uuid:$password@$server_ip:$listen_port?sni=$CERT_DOMAIN&congestion_control=$congestion&alpn=h3$( [[ "$CERT_TRUSTED" == "false" ]] && echo "&allow_insecure=1" )#$(sb_tag_display "$tag")"$(sb_ech_link_params)
    # 客户端 ech 片段 (内联完整 ECHCONFIGS PEM; 只有 sing-box 客户端认)。
    # 必须在本 heredoc **之前**算好 —— heredoc 展开时变量若还没赋值就是空的。
    local ech_cli; ech_cli=$(sb_ech_json_client)
    local ech_cli_field=""; [[ -n "$ech_cli" ]] && ech_cli_field=", $ech_cli"
    cat > "$SB_OUT_DIR/sb_client-$tag.json" <<EOF
{
  "outbounds": [
    { "type": "tuic", "tag": "$tag", "server": "$server_ip", "server_port": $listen_port,
      "uuid": "$uuid", "password": "$password", "congestion_control": "$congestion",
      "tls": { "enabled": true, "server_name": "$CERT_DOMAIN", "alpn": ["h3"], "insecure": $( [[ "$CERT_TRUSTED" == "true" ]] && echo false || echo true )$ech_cli_field } }
  ]
}
EOF
        gen_mihomo_yaml "$tag"
    [[ "$CERT_TRUSTED" == "false" ]] && echo "# 自签: mihomo 侧需 skip-cert-verify: true" >> "$SB_OUT_DIR/sb_client-$tag.yaml"
    echo "$link" | tee "$SB_OUT_DIR/sb_share-$tag.txt" | tail -1 >&2
    grep -vF "$link" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.$$ && mv /tmp/l.$$ "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >> "$SB_OUT_DIR/sb_links-all.txt"
    open_port "$listen_port"
    print_ok "TUIC 节点添加完成: $file"
    # 重建聚合: 新节点不在 sb_client-all.json 里的话, 分享链接
    # (菜单3 / all-share URL) 下发的还是旧节点列表。
    declare -F sb_regen_aggregate >/dev/null 2>&1 && sb_regen_aggregate
}

list_configs() {
    print_title "$PROTO 配置列表"
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        local idx tag port uuid
        idx=$(basename "$f" .json | cut -d'-' -f2); tag="${PROTO}${idx}"
        port=$(jq -r '.inbounds[0].listen_port' "$f")
        uuid=$(jq -r '.inbounds[0].users[0].uuid' "$f")
        printf "%s) 端口:%s  UUID:%s\n" "$idx" "$port" "$uuid" >&2
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
                print_title "TUIC 节点管理"
                echo -e "${CYAN}1)${RESET} 添加节点"; echo -e "${CYAN}2)${RESET} 列出节点"; echo -e "${CYAN}3)${RESET} 删除节点"; echo -e "${CYAN}0)${RESET} 返回"
                read -r -p "请选择: " c
                case "$c" in 1) add_config ;; 2) list_configs ;; 3) delete_config ;; 0) break ;; esac
                read -r -p "按回车继续..." _ || { echo; exit 0; }
            done ;;
    esac
fi
