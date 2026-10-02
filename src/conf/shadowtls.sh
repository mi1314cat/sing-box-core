#!/bin/bash
# ==============================================================
# shadowtls.sh — ShadowTLS v3 + 内层 Shadowsocks-2022 (双 inbound 同文件)
# 与 fscarmen e 节点等价结构；Reality 域名统一走 domains.sh
# CLI: bash shadowtls.sh [add|list|del]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="shadowtls"

add_config() {
    print_title "新增 ShadowTLS v3 节点 ($PROTO-NN.json)"
    local listen_ip listen_port idx file tag
    listen_ip=$(ask_listen_addr)
    listen_port=$(safe_read_port)
    local rnd; rnd=$(reality_random_domain)     # 统一 domains.sh
    print_info "伪装目标 (handshake): $rnd"
    local st_password ss_password server_ip
    st_password=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
    ss_password=$(openssl rand -base64 16 | tr -d '\n')
    idx=$(get_next_index "$PROTO"); file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"
    tag="$tag$(tag_form_suffix tls)"   # 名字体现传输方式

    local json
    json=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "shadowtls",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "version": 3,
      "detour": "${tag}inner",
      "handshake": { "server": "$rnd", "server_port": 443 },
      "strict_mode": true,
      "users": [ { "name": "user", "password": "$st_password" } ]
    },
    {
      "type": "shadowsocks",
      "tag": "${tag}inner",
      "listen": "127.0.0.1",
      "listen_port": $((listen_port+1)),
      "method": "2022-blake3-aes-128-gcm",
      "password": "$ss_password",
      "multiplex": { "enabled": true, "padding": true }
    }
  ]
}
EOF
)
    backup_config config
    if ! write_config "$file" "$json"; then return 1; fi
    if ! sb_check; then rm -f "$file"; print_error "已删除非法配置（现网未受影响）"; return 1; fi
    cleanup_node_shares "$tag"
    sb_reload || true
    server_ip=$(ask_server_addr)
    local link="shadowtls://$st_password@$server_ip:$listen_port?sni=$rnd&version=3#$tag"
    local utls_fp; utls_fp=$(ask_utls_fingerprint)
    python3 - "$utls_fp" "$SB_OUT_DIR/sb_client-$tag.json" "$tag" "$server_ip" "$listen_port" "$st_password" "$ss_password" "$rnd" <<'PYGEN'
import json,sys
_,fp,ofile,tag,srv,port,stpw,sspw,sni=sys.argv
# 内层连本机 shadowsocks(127.0.0.1:1080) —— 客户端双 outbound 结构与 fscarmen 一致
# 外壳 tag 必须带节点 tag (形如 shadowtls01-out): 多个 shadowtls 节点各用
# 不同端口/密码, 若共用固定 tag, 聚合成一份配置时会互相覆盖, 导致除第一个
# 以外的节点全部指向错误的外壳而永久连不上。
SHELL_TAG=tag+"-out"
json.dump({"outbounds":[
  {"type":"shadowtls","tag":SHELL_TAG,"server":srv,"server_port":int(port),
   "version":3,"password":stpw,
   "tls":{"enabled":True,"server_name":sni,"utls":{"enabled":True,"fingerprint":fp}}},
  {"type":"shadowsocks","tag":tag,"detour":SHELL_TAG,
   "method":"2022-blake3-aes-128-gcm","password":sspw,
   "multiplex":{"enabled":True,"padding":True}}
]},open(ofile,"w"),indent=2)
PYGEN
    echo "$link" | tee "$SB_OUT_DIR/sb_share-$tag.txt" | tail -1 >&2
    grep -vF "$link" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.$$ && mv /tmp/l.$$ "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >> "$SB_OUT_DIR/sb_links-all.txt"
    open_port "$listen_port"
    print_ok "ShadowTLS 节点添加完成: $file"
    # 重建聚合: 新节点不在 sb_client-all.json 里的话, 分享链接
    # (菜单3 / all-share URL) 下发的还是旧节点列表。
    declare -F sb_regen_aggregate >/dev/null 2>&1 && sb_regen_aggregate
    gen_mihomo_yaml "$tag"
    print_warn "客户端功能说明: 内层为 2022-blake3-aes-128-gcm(与 sb_client-*.json 一致)"
}

list_configs() {
    print_title "$PROTO 配置"
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        local idx tag port
        idx=$(basename "$f" .json | cut -d'-' -f2); tag="${PROTO}${idx}"
        port=$(jq -r '.inbounds[0].listen_port' "$f")
        printf "%s) 端口:%s 内层SS:%s\n" "$idx" "$port" "$(jq -r '.inbounds[1].listen_port' "$f" )" >&2
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
            print_title "ShadowTLS 节点管理"
            echo -e "${CYAN}1)${RESET} 添加\n${CYAN}2)${RESET} 列出\n${CYAN}3)${RESET} 删除\n${CYAN}0)${RESET} 返回"
            read -r -p "请选择: " c
            case "$(clean_input "$c")" in 1) add_config ;; 2) list_configs ;; 3) delete_config ;; 0) break ;; esac
            read -r -p "按回车继续..." _ || { echo; exit 0; }
        done ;;
    esac
fi
