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
            *) ;;
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

# ---- 主菜单 ----
show_menu() {
    local version_line status_text
    status_text=$(systemctl is-active "$SB_SERVICE" 2>/dev/null || echo "inactive")
    version_line=$(sb_current_version 2>/dev/null || echo "未安装")
    clear
    echo -e "
${GREEN}SB-Panel — sing-box 管理脚本${RESET}
----------------------
${GREEN}1.${RESET} 初始化基础配置 (00-log / direct outbound)
${GREEN}2.${RESET} 安装/重装内核          ${GREEN}3.${RESET} 更新内核 (已是最新则跳过)
${GREEN}4.${RESET} 版本管理 (当前/最新/指定)
${GREEN}5.${RESET} 卸载内核
----------------------
${GREEN}6.${RESET} 添加节点 (add_node_menu)
${GREEN}7.${RESET} 端口转发管理 (direct inbound)
${GREEN}8.${RESET} DNS 管理 (服务器/分流/去广告/FakeIP)
${GREEN}9.${RESET} 规则集管理 (rule-set)
${GREEN}10.${RESET} 出站管理 (outbound)
----------------------
${GREEN}11.${RESET} 服务管理 (启动/停止/重启/软重载)
${GREEN}12.${RESET} 校验配置 + 重载
${GREEN}13.${RESET} 查看日志
${GREEN}14.${RESET} 列出全部配置文件
${GREEN}0.${RESET} 退出
----------------------
sing-box 状态: $([[ "$status_text" == "active" ]] && echo -e "${GREEN}运行中${RESET}" || echo -e "${RED}未运行${RESET}")
内核版本:      ${GREEN}$version_line${RESET}
----------------------"
    read -r -p "请输入选项 [0-14]: " choice
    case "$choice" in
        1)  init_base ;;
        2)  run_module core.sh install ;;
        3)  run_module core.sh update ;;
        4)  version_menu ;;
        5)  run_module core.sh uninstall ;;
        6)  add_node_menu ;;
        7)  run_module portforward.sh ;;
        8)  run_module dns.sh ;;
        9)  run_module ruleset.sh ;;
        10) run_module outbound.sh ;;
        11) service_menu ;;
        12) check_all ;;
        13) sb_journal 100; read -r -p "按回车返回..." ;;
        14) list_configs ;;
        0)  clear; exit 0 ;;
        *)  echo -e "${RED}无效选项 $choice${RESET}" ;;
    esac
    echo && read -r -p "按回车键返回主菜单..." && echo
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

add_node_menu() {
    clear
    echo -e "
${GREEN}添加节点${RESET}
----------------------
${GREEN}1.${RESET} 添加 Reality 节点 (VLESS-REALITY/Vision)
${GREEN}2.${RESET} 添加 Hysteria2 节点
${GREEN}3.${RESET} 添加 AnyReality 节点 (AnyTLS+REALITY)
${GREEN}4.${RESET} 添加 VLESS 节点 (WS+TLS)
${GREEN}5.${RESET} 添加 Shadowsocks 节点 (2022)
${GREEN}6.${RESET} 添加 TUIC 节点 (v5)
${GREEN}7.${RESET} 添加 VMess 节点 (ws/grpc/h2/tcp + TLS/Reality)
${GREEN}8.${RESET} 添加 Trojan 节点 (TCP+TLS)
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
    # CLI 模式（供自动化/其他模块调用）
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
    exit 0
fi

while true; do
    show_menu
done
