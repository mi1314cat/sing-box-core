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

# ---------- rule-set 定义 (02-rule-set.json) ----------
# 注意: 不能只判断文件是否存在。02-rule-set.json 可能已被 ruleset.sh 建成
#       {"route":{"rule_set":[]}}, 此时"文件存在"但一个 tag 都没定义,
#       而 01-dns.json 引用了它们 -> sing-box check 必然失败, 且面板所有写操作
#       都会被这个 check 挡住, 形成死锁。这里按 tag 幂等补齐。
ensure_rule_sets() {
    local ok=0
    sb_ensure_ruleset "$ADS_TAG" "$(sb_geosite_url "$ADS_TAG")" binary 1d || ok=1
    sb_ensure_ruleset "$CN_TAG"  "$(sb_geosite_url "$CN_TAG")"  binary 3d || ok=1
    (( ok == 0 )) || { print_error "规则集定义未能补齐"; return 1; }
    print_ok "规则集已就绪: $ADS_TAG / $CN_TAG  ($RS_FILE)"
}

dns_init() {
    # 先把 DNS 的依赖准备好 (rule-set + http_client), 否则模板写出来必然 check 失败
    ensure_rule_sets || { print_error "规则集依赖未就绪, 已中止 (未改动 01-dns.json)"; return 1; }
    if [[ ! -f "$SB_CONFIG_DIR/00-log.json" ]]; then
        write_config "$SB_CONFIG_DIR/00-log.json" '{"log":{"level":"info","timestamp":true}}' || return 1
    fi
    if [[ ! -f "$SB_CONFIG_DIR/00-direct.json" ]]; then
        write_config "$SB_CONFIG_DIR/00-direct.json" '{"outbounds":[{"type":"direct","tag":"direct"}]}' || return 1
    fi
    if [[ ! -f "$SB_CONFIG_DIR/00-route.json" ]]; then
        write_config "$SB_CONFIG_DIR/00-route.json" '{"route":{"default_domain_resolver":"dns-local"}}' || return 1
    fi
    sb_ensure_http_client || { print_error "http_client 未能就绪, 已中止"; return 1; }

    local existed=0 old=""
    if [[ -f "$DNS_FILE" ]]; then
        existed=1; old=$(cat "$DNS_FILE")
        sb_ask "  01-dns.json 已存在, 覆盖? [y/N]: "
        if [[ ! "$REPLY" =~ ^[yY] ]]; then
            print_info "已保留现有 01-dns.json (规则集定义已确保就绪)"
            if sb_check; then print_ok "当前配置校验通过"; else print_error "当前配置校验失败, 问题不在本次操作"; fi
            return 0
        fi
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

    # 先校验再报成功: 绝不出现 "[OK] 已生成" 紧跟着 "[Error] check 失败"
    if ! sb_check; then
        if (( existed )); then
            printf '%s\n' "$old" | jq . > "$DNS_FILE"
            print_error "sing-box check 未通过, 已把 01-dns.json 回滚到修改前"
        else
            rm -f "$DNS_FILE"
            print_error "sing-box check 未通过, 已删除新生成的 01-dns.json (未留下坏配置)"
        fi
        return 1
    fi
    print_ok "DNS 模板已生成并通过 sing-box check"
    print_info "广告=reject, 国内域名=dns-local(223.5.5.5), 其余=dns-remote(8.8.8.8 DoT)"
    sb_reload || true
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
    while true; do
        sb_ask "  server tag (字母数字/.-, 如 dns-ali): "; tag="$REPLY"
        [[ -z "$tag" ]] && { print_error "tag 不能为空"; continue; }
        # tag 是 final / dns.rules[].server 的引用键, 字符集必须与 sing-box 一致
        [[ "$tag" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || { print_error "tag 只能含字母数字 _ . - , 最长 32"; continue; }
        break
    done
    echo "  type: 1)udp(默认) 2)tcp 3)tls 4)https 5)h3" >&2
    sb_ask "  选择 (回车=1): "; t="$REPLY"
    case "$(clean_input "$t")" in
        2) stype=tcp ;; 3) stype=tls ;; 4) stype=https ;; 5) stype=h3 ;; *) stype=udp ;;
    esac
    while true; do
        sb_ask "  server 地址 (域名或 IP, 输入 0 放弃): "; server="$REPLY"
        [[ "$server" == "0" ]] && { print_warn "已放弃添加"; return 1; }
        [[ -z "$server" ]] && { print_error "地址不能为空 (输入 0 可放弃)"; continue; }
        # 原来只判空: 整条 URL / "y" / "1080" 都会被静默当成地址写进去
        [[ "$server" == *://* ]] && { print_error "地址不能带协议前缀 (直接填域名或 IP, 如 223.5.5.5)"; continue; }
        [[ "$server" =~ ^[A-Za-z0-9._:-]+$ ]] || { print_error "地址含非法字符, 只允许域名 / IPv4 / IPv6[:端口]"; continue; }
        break
    done
    jq -r '.dns.servers[].tag // empty' "$DNS_FILE" 2>/dev/null | grep -qx "$tag" && { print_error "tag 已存在: $tag"; return 1; }
    if dns_edit ".dns.servers += [{\"type\":\"$stype\",\"tag\":\"$tag\",\"server\":\"$server\"}]"; then
        print_ok "已添加 $tag ($stype://$server)"
    fi
}

del_server() {
    print_title "当前 servers"
    jq -r '.dns.servers[] | "\(.tag)\t\(.type)://\(.server)"' "$DNS_FILE" >&2
    local tag
    sb_ask "  删除哪个 tag (输入 0 取消): "; tag="$REPLY"
    tag=$(clean_input "$tag")
    [[ -z "$tag" || "$tag" == "0" ]] && { print_warn "已取消"; return 0; }
    jq -e --arg t "$tag" 'any(.dns.servers[]?; .tag == $t)' "$DNS_FILE" >/dev/null 2>&1 \
        || { print_error "没有这个 DNS 服务器: $tag"; return 1; }
    # 关键: sing-box check 不校验 final / dns.rules[].server 的 tag 引用是否存在,
    # 但运行期会 FATAL "default DNS server not found" 导致服务起不来。
    # 所以必须在写盘前自己拦, 不能指望 check 放行。
    local fin refs nf
    fin=$(jq -r '.dns.final // ""' "$DNS_FILE" 2>/dev/null)
    refs=$(jq -r --arg t "$tag" '[.dns.rules[]? | select(.server? == $t)] | length' "$DNS_FILE" 2>/dev/null || echo 0)
    if [[ "$fin" == "$tag" ]] || (( refs > 0 )); then
        print_warn "$tag 仍被引用, 直接删除会让服务启动失败 (sing-box check 查不出来):"
        [[ "$fin" == "$tag" ]] && print_warn "    dns.final 指向它"
        (( refs > 0 )) && print_warn "    $refs 条 dns.rules 指向它"
        echo "    1) 同时改掉这些引用再删除 (推荐)" >&2
        echo "    2) 取消" >&2
        sb_ask "    选择 (默认 1): "
        [[ "$REPLY" =~ ^2 ]] && { print_warn "已取消"; return 0; }
    fi
    if dns_edit --arg t "$tag" '
        .dns.servers |= map(select(.tag != $t))
        | (if .dns.final == $t then .dns.final = (.dns.servers | map(.tag) | .[0]) else . end)
        | .dns.rules |= map(select(.server? != $t))'; then
        nf=$(jq -r '.dns.final // ""' "$DNS_FILE" 2>/dev/null)
        print_ok "已删除 $tag"
        [[ "$fin" == "$tag" ]] && print_ok "  dns.final 已改指: $nf"
        (( refs > 0 )) && print_ok "  $refs 条指向它的 dns.rules 已一并移除"
    fi
}

set_final() {
    printf 'final 服务器 tag: ' >&2; read -r tag; tag=$(clean_input "$tag")
    jq -r '.dns.servers[].tag // empty' "$DNS_FILE" | grep -qx "$tag" || { print_error "不存在的 tag: $tag"; return 1; }
    dns_edit --arg t "$tag" '.dns.final = $t' && print_ok "final=$tag"
}

ads_toggle() { # 菜单 5: 依据当前真实状态询问开/关 (原来按 5 直接开, 是单向开关)
    local cur
    cur=$(jq -r --arg t "$ADS_TAG" '[.dns.rules[]? | select((.rule_set? // ["-"] | tostring) == ([$t]|tostring))] | length' \
        "$DNS_FILE" 2>/dev/null || echo 0)
    if (( cur > 0 )); then
        echo -e "  ${CYAN}当前状态: 去广告已开启${RESET} (DNS 层 reject $ADS_TAG)" >&2
    else
        echo -e "  ${CYAN}当前状态: 去广告已关闭${RESET}" >&2
    fi
    echo "    1) 关闭去广告" >&2
    echo "    2) 开启去广告" >&2
    sb_ask "    选择 (默认=与当前相反): "
    local c="$REPLY"
    if [[ -z "$c" ]]; then
        if (( cur > 0 )); then c=1; else c=2; fi
    fi
    case "$c" in
        1|off|关) ads_off ;;
        2|on|开)  ads_on ;;
        *) print_error "无效选项"; return 1 ;;
    esac
}

ads_on() {
    ensure_rule_sets || { print_error "规则集未就绪, 去广告未开启"; return 1; }
    # 顺带把"规则集定义在、DNS 规则却没了"的孤儿状态补回来
    # (删掉 geosite-cn 再加回来时, 国内域名会悄悄改走 final 服务器, 而 check 照样通过)
    sb_ensure_dns_rule "$CN_TAG" '.dns.rules += [{"rule_set":[$t],"server":"dns-local"}]' "-> dns-local" || true
    sb_ruleset_defined "$ADS_TAG" || { print_error "规则集 $ADS_TAG 仍未定义, 去广告未开启 (不会写出无效配置)"; return 1; }
    if dns_edit --arg t "$ADS_TAG" '
        .dns.rules = ([{"rule_set": [$t], "action": "reject"}] + [(.dns.rules // [])[] | select((.rule_set? // ["-x-"] | tostring) != ([$t] | tostring))])'; then
        print_ok "去广告已启用 (DNS 层 reject $ADS_TAG)"
    fi
}

ads_off() {
    dns_edit --arg t "$ADS_TAG" '
        .dns.rules |= map(select((.rule_set? // ["-x-"] | tostring) != ([$t] | tostring)))' || return 1
    print_ok "去广告已关闭 (01-dns.json 不再引用 $ADS_TAG)"
    local rf="$SB_CONFIG_DIR/03-route.json"
    if [[ -f "$rf" ]] && jq -e --arg t "$ADS_TAG" \
        'any(.route.rules[]?; ((.rule_set? // ["-x-"] | tostring) == ([$t] | tostring)))' "$rf" >/dev/null 2>&1; then
        print_warn "注意: 03-route.json (路由层) 仍在引用 $ADS_TAG —— 那是流量层拦截, 与 DNS 去广告开关独立"
        print_warn "      如需一并关闭: 规则集管理 -> 3 路由规则 -> 4 删除规则"
    fi
    sb_check && print_ok "sing-box check 通过"
}

fakeip_toggle() { # 菜单 6: 依据当前真实状态询问开/关
    if jq -e 'any(.dns.servers[]?; .tag=="fakeip")' "$DNS_FILE" >/dev/null 2>&1; then
        echo -e "  ${CYAN}当前状态: FakeIP 已开启${RESET}" >&2
        echo "    1) 关闭 FakeIP" >&2; echo "    2) 保持开启" >&2
        sb_ask "    选择 (默认 1): "
        [[ "$REPLY" == 2 ]] && { print_info "保持开启"; return 0; }
        fakeip_off; return $?
    fi
    echo -e "  ${CYAN}当前状态: FakeIP 未开启${RESET}" >&2
    fakeip_on
}

fakeip_on() {
    local in4="${1:-198.18.0.0/15}"
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
        echo -e "${CYAN}5)${RESET} 去广告开关 (会询问开启/关闭)"
        echo -e "${CYAN}6)${RESET} FakeIP 开关 (会询问开启/关闭)"
        echo -e "${CYAN}0)${RESET} 返回"
        printf '请选择: ' >&2; read -r c
        case "$(clean_input "$c")" in
            1) dns_init ;;
            2) add_server ;;
            3) del_server ;;
            4) set_final ;;
            5-on|on) ads_on ;;
            5-off|off) ads_off ;;
            5) ads_toggle ;;
            6-on|6on) fakeip_on ;;
            6-off|6off) fakeip_off ;;
            6) fakeip_toggle ;;
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
