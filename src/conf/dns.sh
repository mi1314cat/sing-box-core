#!/bin/bash
# ==============================================================
# dns.sh — DNS 模块（管理 config/01-dns.json）
# sing-box v1.14 对象格式；红线字段（老式 address/dns.fakeip/
# independent_cache/store_rdrc/inline server）永不生成。
# init 会同步创建 02-rule-set.json（官方 geosite .srs 预设），
# 使 DNS 分流/去广告开箱即可通过 sing-box check。
# CLI: bash dns.sh [init|show|addserver|delserver|final|ads|ads-off|fakeip|fakeip-off|check]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

DNS_FILE="$SB_CONFIG_DIR/01-dns.json"
RS_FILE="$SB_CONFIG_DIR/02-rule-set.json"
ADS_TAG="geosite-category-ads-all"
CN_TAG="geosite-cn"

# ---------- rule-set 定义（02-rule-set.json; 有则跳过）----------
ensure_rule_sets() {
    [[ -f "$RS_FILE" ]] && { print_ok "规则集定义已存在: $RS_FILE"; return 0; }
    write_config "$RS_FILE" '{
  "route": {
    "rule_set": [
      {
        "type": "remote",
        "tag": "'"$ADS_TAG"'",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs",
        "http_client": "http-direct",
        "update_interval": "1d"
      },
      {
        "type": "remote",
        "tag": "'"$CN_TAG"'",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
        "http_client": "http-direct",
        "update_interval": "3d"
      }
    ]
  }
}'
}

dns_init() {
    if [[ -f "$DNS_FILE" ]]; then
        read -r -p "01-dns.json 已存在，覆盖？[y/N]: " yn
        [[ "$(clean_input "$yn")" =~ ^[yY] ]] || return 0
    fi
    ensure_rule_sets
    if [[ ! -f "$SB_CONFIG_DIR/00-log.json" ]]; then
        write_config "$SB_CONFIG_DIR/00-log.json" '{"log":{"level":"info","timestamp":true}}' || return 1
    fi
    if [[ ! -f "$SB_CONFIG_DIR/00-direct.json" ]]; then
        write_config "$SB_CONFIG_DIR/00-direct.json" '{"outbounds":[{"type":"direct","tag":"direct"}]}' || return 1
    fi
    if [[ ! -f "$SB_CONFIG_DIR/00-route.json" ]]; then
        write_config "$SB_CONFIG_DIR/00-route.json" '{"route":{"default_domain_resolver":"dns-local"}}' || return 1
    fi
    if [[ ! -f "$SB_CONFIG_DIR/00-http.json" ]]; then
        # 1.14: http_clients 顶层，替代已 deprecated 的 download_detour
        write_config "$SB_CONFIG_DIR/00-http.json" '{"http_clients":[{"tag":"http-direct"}]}' || return 1
    fi
    write_config "$DNS_FILE" '{
  "dns": {
    "servers": [
      { "type": "udp", "tag": "dns-local", "server": "223.5.5.5" },
      { "type": "tls", "tag": "dns-remote", "server": "8.8.8.8", "domain_resolver": "dns-local" }
    ],
    "rules": [
      { "rule_set": ["'"$ADS_TAG"'"], "action": "reject" },
      { "rule_set": ["'"$CN_TAG"'"], "server": "dns-local" }
    ],
    "final": "dns-remote",
    "strategy": "prefer_ipv4",
    "cache_capacity": 4096,
    "optimistic": true,
    "timeout": "5s"
  }
}' || return 1
    print_ok "DNS 模板已生成: 广告=reject, 国内域名=dns-local(223.5.5.5), 其余=dns-remote(8.8.8.8 DoT)"
    sb_check && sb_reload || true
}

dns_show() {
    if [[ -f "$DNS_FILE" ]]; then
        print_title "当前 DNS 配置 (01-dns.json)"
        cat "$DNS_FILE" >&2
    else
        print_warn "尚无 01-dns.json（先 init）"
    fi
}

dns_edit() { # dns_edit "<jq-filter>" — check+重载，任一失败回滚到改前版本
    [[ -f "$DNS_FILE" ]] || { print_error "先 dns.sh init"; return 1; }
    local old
    old=$(jq . "$DNS_FILE")
    if ! write_config "$DNS_FILE" "$(jq "$@" "$DNS_FILE")"; then print_error "jq 过滤器错误"; return 1; fi
    if ! sb_check; then
        echo "$old" | jq . > "$DNS_FILE"
        print_error "已回滚（check 未通过）"
        return 1
    fi
    if ! sb_reload; then
        echo "$old" | jq . > "$DNS_FILE"   # 运行期失败（如 rule-set 下载崩溃）回滚并恢复
        sb_check && sb_restart && print_ok "已回滚到改前配置并恢复服务"
        return 1
    fi
}

add_server() {
    local tag stype server t
    printf 'server tag (如 dns-ali): ' >&2; read -r tag; tag=$(clean_input "$tag")
    echo "type: 1)udp 2)tcp 3)tls 4)https 5)h3" >&2
    printf '选择: ' >&2; read -r t
    case "$(clean_input "$t")" in tcp=2) ;; esac
    case "$(clean_input "$t")" in
        2) stype=tcp ;; 3) stype=tls ;; 4) stype=https ;; 5) stype=h3 ;; *) stype=udp ;;
    esac
    printf 'server 地址: ' >&2; read -r server; server=$(clean_input "$server")
    [[ -z "$server" ]] && { print_error "地址不能为空"; return 1; }
    jq -r '.dns.servers[].tag // empty' "$DNS_FILE" 2>/dev/null | grep -qx "$tag" && { print_error "tag 已存在: $tag"; return 1; }
    if dns_edit ".dns.servers += [{\"type\":\"$stype\",\"tag\":\"$tag\",\"server\":\"$server\"}]"; then
        print_ok "已添加 $tag ($stype://$server)"
    fi
}

del_server() {
    print_title "当前 servers"
    jq -r '.dns.servers[] | "\(.tag)\t\(.type)://\(.server)"' "$DNS_FILE" >&2
    printf '删除哪个 tag: ' >&2; read -r tag; tag=$(clean_input "$tag")
    dns_edit --arg t "$tag" '.dns.servers |= map(select(.tag != $t))'
    print_ok "已删除 $tag"
}

set_final() {
    printf 'final 服务器 tag: ' >&2; read -r tag; tag=$(clean_input "$tag")
    jq -r '.dns.servers[].tag // empty' "$DNS_FILE" | grep -qx "$tag" || { print_error "不存在的 tag: $tag"; return 1; }
    dns_edit --arg t "$tag" '.dns.final = $t' && print_ok "final=$tag"
}

ads_on() {
    [[ -f "$RS_FILE" ]] || { print_error "未找到规则集定义（先 init 或 ruleset.sh）"; return 1; }
    if dns_edit --arg t "$ADS_TAG" '
        .dns.rules = ([{"rule_set": [$t], "action": "reject"}] + [(.dns.rules // [])[] | select((.rule_set? // ["-x-"] | tostring) != ([$t] | tostring))])'; then
        print_ok "去广告已启用 (DNS reject $ADS_TAG)"
    fi
}

ads_off() {
    if dns_edit --arg t "$ADS_TAG" '
        .dns.rules |= map(select((.rule_set? // ["-x-"] | tostring) != ([$t] | tostring)))'; then
        print_ok "去广告已关闭"
    fi
}

fakeip_on() {
    local in4="${1:-198.18.0.0/15}"
    jq -e '.dns.servers[] | select(.tag=="fakeip")' "$DNS_FILE" >/dev/null 2>&1 && [[ $? -eq 0 || $? -eq 1 ]] || true
    if jq -e 'any(.dns.servers[]; .tag=="fakeip")' "$DNS_FILE" >/dev/null 2>&1; then
        print_warn "fakeip 已存在"; return 0
    fi
    dns_edit '.dns.servers += [{"type":"fakeip","tag":"fakeip","inet4_range":"'"$in4"'"}] |
              .dns.rules += [{"query_type":["A","AAAA"],"server":"fakeip","rewrite_ttl":5, "action":"route"}]' \
        && print_ok "FakeIP 已开启 ($in4)
（提醒: fakeip 只供 A/AAAA 查询；勿设 final；需 TUN/hijack-dns 才有意义）"
}

fakeip_off() {
    dns_edit '.dns.servers |= map(select(.tag != "fakeip"))
              | .dns.rules  |= map(select((.server? // "") != "fakeip"))'
    print_ok "FakeIP 已关闭"
}

# ---------- 菜单 ----------
menu() {
    while true; do
        print_title "DNS 管理"
        dns_show || true
        echo -e "${CYAN}1)${RESET} 初始化基础模板（含去广告/分流预设）"
        echo -e "${CYAN}2)${RESET} 添加 DNS 服务器"
        echo -e "${CYAN}3)${RESET} 删除 DNS 服务器"
        echo -e "${CYAN}4)${RESET} 设置 final"
        echo -e "${CYAN}5)${RESET} 去广告开关 5-on / 5-off"
        echo -e "${CYAN}6)${RESET} FakeIP 开关 6-on / 6-off"
        echo -e "${CYAN}0)${RESET} 返回"
        printf '请选择: ' >&2; read -r c
        case "$(clean_input "$c")" in
            1) dns_init ;;
            2) add_server ;;
            3) del_server ;;
            4) set_final ;;
            5|5-on) ads_on ;;
            5-off|5o) ads_off ;;
            6|6-on) fakeip_on ;;
            6-off) fakeip_off ;;
            0) break ;;
            *) print_error "无效选项" ;;
        esac
        printf '按回车继续...' >&2; read -r _ || true
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        init) dns_init ;; show) dns_show ;;
        addserver) add_server ;; delserver) del_server ;; final) set_final ;;
        ads) ads_on ;; ads-off) ads_off ;;
        fakeip) fakeip_on "$2" ;; fakeip-off) fakeip_off ;;
        check) sb_check ;;
        *) menu ;;
    esac
fi
