#!/bin/bash
# ==============================================================
# uninstall.sh — 卸载 SB-Panel 自身 (不影响 其他服务: xray/mysql/nginx等)
# 输出先列"将被影响"清单, 再列"绝不触碰"清单, 需人输入 yes 才动
# 用法: bash conf/uninstall.sh  参数 --force=跳过确认 ; --wipe=一并删除数据目录
# ==============================================================
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"     # $SB_ROOT
SB_ROOT="${SB_ROOT:-$SELF_DIR}"
SERVICES=(sing-box.service sing-box-share.service)

GREEN="${GREEN:-\e[32m}"; RED="${RED:-\e[31m}"; YELLOW="${YELLOW:-\e[33m}"; CYAN="${CYAN:-\e[96m}"; RESET="${RESET:-\e[0m}"
print_title(){ printf "\e[95m\e[1m===\e[0m ${GREEN}%s${RESET}\n" "$1" >&2; }
print_ok(){ echo -e "\e[32m[OK]  $1\e[0m" >&2; }
print_warn(){ echo -e "\e[33m[WARN]\e[0m $1" >&2; }
print_err(){ echo -e "\e[31m[Error]\e[0m $1" >&2; }

show_impact() {
    print_title "SB-Panel 卸载影响范围"
    echo "将停止/移除:" >&2
    for s in "${SERVICES[@]}"; do echo "  - $s" >&2; done
    echo "  - /etc/systemd/system/{sing-box,sing-box-share}.service" >&2
    echo "  - $SB_ROOT (面板脚本/config/out 分享链接/备份)" >&2
    echo "" >&2
    echo -e "${GREEN}绝不触碰:${RESET}" >&2
    echo "  -. systemd 上有其服务 (xray/caddy/nginx/docker/moontv 等) 均不动" >&2
    echo "  - 证书文件 (/etc/letsencrypt, /root/catmi/cloudflare/cert 等) 不动" >&2
    echo "  - /usr/local/bin/sb-client 若与本机无关, 不删" >&2
    echo "" >&2
}

do_uninstall() {
    show_impact
    read -r -p "确认执行完整卸载? 输入 yes 继续: [不存在默认输入] " a
    [[ "$(echo "$a"|tr A-Z a-z)" == "yes" ]] || { print_warn "已取消"; return 1; }
    for s in "${SERVICES[@]}"; do
        systemctl stop "$s" 2>/dev/null || true
        systemctl disable "$s" 2>/dev/null
        rm -f "/etc/systemd/system/$s"
    done
    systemctl daemon-reload
    print_ok "systemd 单元已清除"
    read -r -p "是否删除 $SB_ROOT 目录 (含全部节点配置/备份)? [y/N]: " b
    case "$(echo "$b"|tr A-Z a-z)" in
        y*|yes*) rm -rf "$SB_ROOT" && print_ok "已删除 $SB_ROOT" ;;
        *) print_warn "保留: $SB_ROOT (可手动恢复)" ;;
    esac
    echo
    print_ok "SB-Panel 服务端卸载完成 (其他服务未受影响)"
}

# CLI
[[ "${1:-}" == "--force" ]] && { FORCE=1; do_uninstall; exit $?; }
menu() {
    print_title "SB-Panel 卸载/服务清理"
    echo "1) 卸载 SB-Panel (停 sing-box/share, 不碰其它服务)" >&2
    echo "2) 仅停止服务, 保留配置" >&2
    echo "0) 返回" >&2
    read -r -p "选择: " c
    case "$(echo "$c"|tr A-Z a-z)" in
        1) do_uninstall ;;
        2) systemctl stop sing-box sing-box-share 2>/dev/null; print_ok "服务已停止 (配置未动)" ;;
        0) exit 0 ;;
        *) print_err "无效选择" ;;
    esac
}
menu
