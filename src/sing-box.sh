#!/bin/bash
# ==============================================================
# sing-box.sh — SB-Panel 主入口
# 单内核 + 单 systemd service + 配置目录多文件 + 模块化 conf/*.sh
# 架构与 xary-core (xray-panel.sh) 习惯对齐
# ==============================================================
export TERM=xterm
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SB_LIB="${SB_LIB:-$SELF_DIR/conf/lib.sh}"
[[ -f "$SB_LIB" ]] && source "$SB_LIB"

# ---- 兜底 UI（防 lib 缺失）----
RED="${RED:-\e[31m}"; GREEN="${GREEN:-\e[32m}"; YELLOW="${YELLOW:-\e[33m}"; CYAN="${CYAN:-\e[96m}"; MAGENTA="${MAGENTA:-\e[95m}"; RESET="${RESET:-\e[0m}"

ensure_conf_dir() { mkdir -p "$SELF_DIR/conf"; }

run_module() { # run_module <module.sh-name> [args...]
    local mod="$1"; shift || true
    ensure_conf_dir
    if [[ ! -f "$SELF_DIR/conf/$mod" ]]; then
        bash <(curl -Ls "https://github.com/mi1314cat/sb-core/raw/refs/heads/main/conf/$mod") "$@"
        return $?
    fi
    bash "$SELF_DIR/conf/$mod" "$@"
    return $?
}

# ---- 服务管理子菜单 ----
service_menu() {
    while true; do
        print_title "服务管理"
        echo -e "${CYAN}1)${RESET} 启动服务"
        echo -e "${CYAN}2)${RESET} 停止服务"
        echo -e "${CYAN}3)${RESET} 重启服务 (restart)"
        echo -e "${CYAN}4)${RESET} 软重载配置 (SIGHUP, 零断流)"
        echo -e "${CYAN}5)${RESET} 状态查看"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请选择: " c
        case "$c" in
            1) systemctl start "$SB_SERVICE" && sleep 1 && sys_status ;;
            2) systemctl stop "$SB_SERVICE";  sys_status ;;
            3) sb_restart ;;
            4) sb_reload ;;
            5) sys_status ;;
            0) return ;;
            *) echo -e "${RED}无效选项 $c${RESET}" ;;
        esac
    done
}

sys_status() {
    echo >&2
    echo "运行状态: $(systemctl is-active "$SB_SERVICE" 2>/dev/null || echo unknown)" >&2
    echo "内核版本: $(sb_current_version 2>/dev/null || echo 未安装)" >&2
    echo "占用端口: $(ss -tuln 2>/dev/null | awk 'NR>1{print $5}' | grep -oE '[0-9]+$' | sort -un | paste -sd, -)" >&2
    echo >&2
}

check_all() {
    print_title "校验配置 + 服务状态"
    if sb_check; then
        sys_status
        read -r -p "重载 (SIGHUP) 还是重启 (restart)? [r/R=重启, 回车=软重载, n=不重载]: " m
        case "$(clean_input "$m")" in
            n|N) : ;;
            r|R) sb_restart ;;
            *)   sb_reload ;;
        esac
    fi
}

# ---- 安装 / 内核子菜单 (脚本更新与内核更新分离) ----
update_scripts() {
    local up="$SELF_DIR/src-upstream"
    if [[ ! -d "$up/.git" ]]; then
        print_info "本地无源码缓存, 全量安装后可用此热更新 (安装源: $up)"
        return 0
    fi
    git -C "$up" fetch -q origin main 2>/dev/null || { print_error "无法从 GitHub 获取最新脚本, 检查网络"; return 1; }
    local lo re; lo=$(git -C "$up" rev-parse --short HEAD); re=$(git -C "$up" rev-parse --short FETCH_HEAD)
    if [[ "$lo" == "$re" ]]; then print_ok "管理脚本已是最新版本 (当前: $lo)"; return 0; fi
    print_info "当前版本: $lo"; print_info "最新版本: $re"
    read -r -p "确认更新? [y/N]: " m
    [[ "$(clean_input "$m")" == y* || -z "$m" ]] || return 0
    git -C "$up" reset -q --hard FETCH_HEAD
    cp -f "$up/src/sing-box.sh" "$SELF_DIR/" && cp -rf "$up/src/conf/." "$SELF_DIR/conf/"
    chmod +x "$SELF_DIR/sing-box.sh" "$SELF_DIR/conf/"*.sh
    sb_check && print_ok "管理脚本已更新到 $re (配置检查通过)" || print_error "更新后配置检查失败, 请检查 config/"
}

core_menu() {
    while true; do
        print_title "安装 / 内核管理"
        echo -e "${CYAN}1)${RESET} 初始化基础配置 (00-log / direct)"
        echo -e "${CYAN}2)${RESET} 安装/重装内核"
        echo -e "${CYAN}3)${RESET} 更新内核 (已是最新则跳过)"
        echo -e "${CYAN}4)${RESET} 版本管理 (当前/最新/指定)"
        echo -e "${CYAN}5)${RESET} 卸载内核"
        echo -e "${CYAN}6)${RESET} 更新管理脚本 (git, 与内核更新分离)"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请选择: " c || { clear; exit 0; }
        case "$c" in
            1) init_base ;;
            2) run_module core.sh install ;;
            3) run_module core.sh update ;;
            4) version_menu ;;
            5) run_module core.sh uninstall ;;
            6) update_scripts ;;
            7) run_module uninstall.sh ;;
            0) return ;;
            *) echo -e "${RED}无效选项 $c${RESET}" ;;
        esac
        read -r -p "按回车键返回..." _ || return 0
    done
}

net_menu() {
    while true; do
        print_title "网络管理 (转发/DNS/规则/出站)"
        echo -e "${CYAN}1)${RESET} 端口转发 (direct inbound)"
        echo -e "${CYAN}2)${RESET} DNS 管理"
        echo -e "${CYAN}3)${RESET} 规则集管理 (rule-set)"
        echo -e "${CYAN}4)${RESET} 出站管理 (outbound)"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请选择: " c || { clear; exit 0; }
        case "$c" in
            1) run_module portforward.sh ;;
            2) run_module dns.sh ;;
            3) run_module ruleset.sh ;;
            4) run_module outbound.sh ;;
            0) return ;;
            *) echo -e "${RED}无效选项 $c${RESET}" ;;
        esac
        read -r -p "按回车键返回..." _ || { clear; exit 0; }
    done
}

sys_info() {
    print_title "系统信息"
    sys_status
    echo -e "系统: $(uname -srm)   在线: $(awk '{u=$2+$4; t=$2+$4+$5; if (NR==1){x=u; y=t}} END{printf "%.0f%%", (x*100/y)}' /proc/uptime 2>/dev/null || echo -)"
    echo -e "端口占用 (本机):"
    ss -tlnp 2>/dev/null | awk 'NR>1 {print $4}' | grep -oE "[0-9]+$" | sort -un | tr '\n' ' '; echo
}

# ---- 主菜单 ----
show_menu() {
    local version_line status_text
    status_text=$(systemctl is-active "$SB_SERVICE" 2>/dev/null || echo "inactive")
    version_line=$(sb_current_version 2>/dev/null || echo "未安装")
    clear
    cat <<CATART
                       |\__/,|   (\\
                     _.|o o  |_   ) )
   -------------(((---(((-------------------
                   catmi.singbox
   -----------------------------------------
CATART
    echo -e "
${GREEN}SB-Panel — Sing-box 管理脚本${RESET}   ${GREEN}[ 服务端 · SERVER ]${RESET}
----------------------
${GREEN}1.${RESET} 安装 / 内核 (初始化/安装/更新/版本/卸载/脚本更新)
${GREEN}2.${RESET} 节点管理
${GREEN}3.${RESET} 分享链接管理
${GREEN}4.${RESET} 网络 (端口转发/DNS/规则集/出站)
${GREEN}5.${RESET} 服务管理 (启动/停止/重启/软重载)
${GREEN}6.${RESET} 校验配置 + 重载
${GREEN}7.${RESET} 查看日志
${GREEN}8.${RESET} 列出全部配置文件
${GREEN}0.${RESET} 退出
----------------------
sing-box 服务状态: $([[ "$status_text" == "active" ]] && echo -e "${GREEN}运行中${RESET}" || echo -e "${RED}未运行${RESET}")
内核版本: ${GREEN}$version_line${RESET}
节点数:   ${GREEN}$(ls "$SB_CONFIG_DIR"/*.json 2>/dev/null | grep -v 'config/00-' | grep -cv '^-')${RESET}
----------------------"
    read -r -p "请输入选项 [0-8]: " choice || { clear; exit 0; }
    case "$choice" in
        1)  core_menu ;;
        2)  add_node_menu ;;
        3)  run_module share.sh ;;
        4)  net_menu ;;
        5)  service_menu ;;
        6)  check_all ;;
        7)  sb_journal 100; read -r -p "按回车键返回主菜单..." ;;
        8)  list_configs ;;
        0)  clear; exit 0 ;;
        *)  echo -e "${RED}无效选项 $choice${RESET}" ;;
    esac
    echo && read -r -p "按回车键返回主菜单..." _ || true
}

init_base() {
    [[ -x "$SB_BIN" ]] || { print_error "请先安装内核 (菜单 2)"; return 1; }
    mkdir -p "$SB_CONFIG_DIR" "$SB_OUT_DIR" "$SB_BACKUP_DIR"
    if [[ ! -f "$SB_CONFIG_DIR/00-log.json" ]]; then
        write_config "$SB_CONFIG_DIR/00-log.json" '{"log":{"level":"info","timestamp":true}}' || return 1
    fi
    if [[ ! -f "$SB_CONFIG_DIR/00-direct.json" ]]; then
        write_config "$SB_CONFIG_DIR/00-direct.json" '{"outbounds":[{"type":"direct","tag":"direct"}]}' || return 1
    fi
    sb_check || return 1
    if [[ ! -f /etc/systemd/system/sing-box.service ]]; then
        bash "$SELF_DIR/conf/core.sh" service
    fi
    sb_restart || sb_reload
}

version_menu() {
    while true; do
        print_title "版本管理"
        echo -e "${CYAN}1)${RESET} 当前版本"
        echo -e "${CYAN}2)${RESET} 最新 stable"
        echo -e "${CYAN}3)${RESET} 安装指定版本"
        echo -e "${CYAN}4)${RESET} 安装最新 pre-release (默认不推荐)"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请选择: " vc
        case "$vc" in
            1) sb_current_version; read -r -p "按回车继续..." ;;
            2) sb_latest_version;  read -r -p "按回车继续..." ;;
            3)
                read -r -p "版本号 (如 1.14.1): " vv
                run_module core.sh install "${vv#v}"
                read -r -p "按回车继续..."
                ;;
            4) run_module core.sh install-pre; read -r -p "按回车继续..." ;;
            0) return ;;
            *) ;;
        esac
    done
}

list_configs() {
    print_title "config/ 配置文件"
    ls -1 "$SB_CONFIG_DIR"/*.json 2>/dev/null || print_warn "目录为空"
}

client_info_menu() {
    print_title "客户端地址 / Web UI 信息"
    local ip; ip=$(default_server_ip)
    local share_base="$(grep -h 'share_tag-' "$SB_OUT_DIR"/share_tag-*.txt 2>/dev/null | head -1)"
    echo -e "${CYAN}HTTP / SOCKS (mixed):${RESET}   http://<LAN-IP>:2080  ·  socks5://<LAN-IP>:2080  (客户端 machine 上)"
    echo -e "${CYAN}Clash API:${RESET}            http://<LAN-IP>:19090  (secret 调用必经)"
    echo -e "${CYAN}Web UI (metacubexd):${RESET}  http://<LAN-IP>:19090/ui/"
    echo -e "${CYAN}分享链接样例:${RESET}        $(ls "$SB_OUT_DIR"/share_tag-*.txt 2>/dev/null | head -1 >/dev/null && cat "$SB_OUT_DIR/share_tag-*.txt" | head -1 || echo '尚未生成')"
    echo
    echo "—— 本机端口占用 (避让参考) ——"
    ss -tlnp 2>/dev/null | awk 'NR>1 {print $4}' | grep -oE "[0-9]+$" | sort -un | tr '\n' ' '
    echo
}

add_node_menu() {
    clear
    echo -e "
${GREEN}添加节点${RESET}
----------------------
${GREEN}1.${RESET} 添加 Reality 节点 (VLESS-REALITY/Vision | TLS 或 Reality)
${GREEN}2.${RESET} 添加 Hysteria2 节点
${GREEN}3.${RESET} 添加 AnyReality 节点 (AnyTLS+REALITY, 选配)
${GREEN}4.${RESET} 添加 VLESS 节点 (WS+TLS)
${GREEN}5.${RESET} 添加 Shadowsocks 节点 (2022)
${GREEN}6.${RESET} 添加 TUIC 节点 (v5 · 仅 TLS, 不支持 Reality)
${GREEN}7.${RESET} 添加 VMess 节点 (ws/grpc/h2/tcp + TLS/Reality)
${GREEN}8.${RESET} 添加 Trojan 节点 (TCP+TLS 或 TLS+Reality)
${GREEN}9.${RESET} 添加 NaiveProxy 节点 (HTTP/2)
${GREEN}10.${RESET} 添加 ShadowTLS+v3 节点 (内层 SS-2022)
${GREEN}0.${RESET} 返回主菜单
----------------------"
    read -r -p "请输入选项 [0-10]: " nchoice
    local module
    case "$nchoice" in
        1) module=reality.sh ;;
        2) module=hysteria2.sh ;;
        3) module=anyreality.sh ;;
        4) module=vless.sh ;;
        5) module=shadowsocks.sh ;;
        6) module=tuic.sh ;;
        7) module=vmess.sh ;;
        8) module=trojan.sh ;;
        9) module=naive.sh ;;
        10) module=shadowtls.sh ;;
        0) return ;;
        *) print_error "无效选项"; return ;;
    esac
    if [[ -f "$SELF_DIR/conf/$module" ]]; then
        bash "$SELF_DIR/conf/$module"
    else
        print_warn "协议模块 $module 尚未实现 (Phase 3 开发中)"
    fi
    # 协议模块内部已走 check+重载；此处不再重复重启
}

if [[ -n "${1:-}" ]]; then
    # CLI 模式（供自动化/其他模块调用）; 各分支透传真实 exit code
    case "$1" in
        init)    init_base ;;
        check)   sb_check ;;
        reload)  sb_reload ;;
        restart) sb_restart ;;
        status)  sys_status ;;
        list)    list_configs ;;
        node)    add_node_menu ;;
        menu)    while true; do show_menu; done ;;
        *) echo "用法: sing-box.sh [init|check|reload|restart|status|list|node|menu]" >&2 ;;
    esac
    exit $?
fi

while true; do
    show_menu
done
