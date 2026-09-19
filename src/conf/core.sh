#!/bin/bash
# ==============================================================
# core.sh — sing-box 内核管理模块
#   bash core.sh install          安装最新 stable（默认）
#   bash core.sh install <ver>    安装指定版本（如 1.14.1）
#   bash core.sh install <ver> pre 安装 pre-release（如 1.15.0-alpha.6）
#   bash core.sh update           更新（已最新则跳过）
#   bash core.sh status           当前/最新版本
#   bash core.sh uninstall        卸载
# 所有操作事务化：备份 → 下载校验 → 新内核对现有配置 check → 替换 → 失败回滚
# ==============================================================
set -o pipefail

SB_ROOT="${SB_ROOT:-/opt/sb-panel/sing-box}"
SB_CONFIG_DIR="${SB_CONFIG_DIR:-$SB_ROOT/config}"
SB_BIN="${SB_BIN:-$SB_ROOT/sing-box}"
SB_SERVICE="${SB_SERVICE:-sing-box}"
SB_OUT_DIR="${SB_OUT_DIR:-$SB_ROOT/out}"
SB_REPO_API="${SB_REPO_API:-https://api.github.com/repos/SagerNet/sing-box}"

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[96m"; MAGENTA="\e[95m"; BOLD="\e[1m"; RESET="\e[0m" # shellcheck disable=SC2034
print_info()  { printf "${CYAN}[Info]${RESET} %s\n" "$1" >&2; }
print_ok()    { printf "${GREEN}[OK]${RESET} %s\n" "$1" >&2; }
print_warn()  { printf "${YELLOW}[Warn]${RESET} %s\n" "$1" >&2; }
print_error() { printf "${RED}[Error]${RESET} %s\n" "$1" >&2; }

# ---- 平台检测 ----
sb_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "" ;;
    esac
}

# ---- 版本工具 ----
sb_current_version() { "$SB_BIN" version 2>/dev/null | head -1 | awk '{print $3}'; }

sb_latest_version() {
    curl -s --max-time 10 "$SB_REPO_API/releases/latest" | jq -r '.tag_name // empty' | sed 's/^v//'
}

sb_latest_pre() { # 最新（含 pre-release）—— 仅 --pre 用
    curl -s --max-time 10 "$SB_REPO_API/releases?per_page=15" | jq -r '.[].tag_name' | sed 's/^v//' | head -1
}

core_status() {
    print_info "当前版本:   $(sb_current_version 2>/dev/null || echo 未安装)"
    print_info "最新 stable: $(sb_latest_version 2>/dev/null || echo 查询失败)"
    if [[ "$(sb_current_version 2>/dev/null)" == "$(sb_latest_version 2>/dev/null)" ]]; then
        print_ok "已与最新 stable 一致"
    else
        print_warn "有新稳定版可用（core.sh update 手动更新）"
    fi
}

# ---- 下载 + 校验 + 安装（事务）----
download_singbox() { # download_singbox <version> <tmpdir>
    local ver="$1" tmp="$2" arch
    arch=$(sb_arch)
    if [[ -z "$arch" ]]; then print_error "不支持的架构: $(uname -m)"; return 1; fi
    local url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}.tar.gz"
    print_info "下载: $url"
    curl -fL --max-time 300 -o "$tmp/sb.tar.gz" "$url" || { print_error "下载失败"; return 1; }
    tar -xzf "$tmp/sb.tar.gz" -C "$tmp" || { print_error "解压失败"; return 1; }
    [[ -x "$tmp/sing-box-${ver}-linux-${arch}/sing-box" ]] || { print_error "包内未找到 sing-box 二进制"; return 1; }
    mv "$tmp/sing-box-${ver}-linux-${arch}/sing-box" "$tmp/sing-box-new"
    return 0
}

do_install() { # do_install <version>
    local ver="$1" tmp bak
    [[ -n "$ver" ]] || { print_error "缺少版本号"; return 1; }
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    download_singbox "$ver" "$tmp" || return 1

    mkdir -p "$SB_ROOT" "$SB_CONFIG_DIR" "$SB_OUT_DIR"
    chmod +x "$tmp/sing-box-new"

    # 新内核对现有配置 check（若已有配置）
    if ls "$SB_CONFIG_DIR"/*.json >/dev/null 2>&1; then
        local out
        out=$("$tmp/sing-box-new" check -D "$SB_ROOT" -C "$SB_CONFIG_DIR" 2>&1) || {
            print_error "新内核无法加载现有配置，已取消安装 $ver："
            echo "$out" | tail -10 >&2
            return 1
        }
        print_ok "新内核 $ver 可正常加载现有配置"
    fi

    if [[ -f "$SB_BIN" ]]; then
        bak="$SB_ROOT/.sing-box.$(date +%s).bak"
        mv "$SB_BIN" "$bak"
    fi
    mv "$tmp/sing-box-new" "$SB_BIN"
    chmod 755 "$SB_BIN"
    if ! "$SB_BIN" version >/dev/null 2>&1; then
        [[ -n "$bak" ]] && mv "$bak" "$SB_BIN"
        print_error "新二进制无法执行，已回滚"
        return 1
    fi
    [[ -n "$bak" ]] && rm -f "$bak"
    print_ok "sing-box $ver 安装完成 → $SB_BIN"
    if [[ -z "$(ls "$SB_CONFIG_DIR"/*.json 2>/dev/null)" ]]; then
        print_warn "首次安装：回到主菜单执行『初始化基础配置』生成 00-log.json 等"
    fi
}

# ---- service 安装（仅一次骨架）----
install_service() {
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box unified service (sb-panel)
After=network.target

[Service]
ExecStart=$SB_BIN -D $SB_ROOT -C $SB_CONFIG_DIR run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    print_ok "systemd 服务已安装: /etc/systemd/system/sing-box.service (单 service 管理整个配置目录)"
}

# ---- 更新（检测最新，已是最新则跳过）----
do_update() {
    local cur latest
    cur=$(sb_current_version 2>/dev/null)
    latest=$(sb_latest_version)
    if [[ -z "$latest" ]]; then print_error "无法查询最新版本（网络/API）"; return 1; fi
    if [[ "$cur" == "$latest" ]]; then
        print_ok "当前已是最新 stable ($cur)，无需更新"
        return 0
    fi
    print_info "当前 $cur → 最新 $latest，开始更新"
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    download_singbox "$latest" "$tmp" || return 1
    chmod +x "$tmp/sing-box-new"

    # 备份
    if [[ -f "$SB_BIN" ]]; then cp -a "$SB_BIN" "$tmp/sing-box-old"; fi

    # 新内核配置检查
    if ls "$SB_CONFIG_DIR"/*.json >/dev/null 2>&1; then
        local out
        out=$("$tmp/sing-box-new" check -D "$SB_ROOT" -C "$SB_CONFIG_DIR" 2>&1) || {
            print_error "新内核无法加载当前配置，已取消更新（现网未动）:"
            echo "$out" | tail -10 >&2
            return 1
        }
        print_ok "预检通过：新内核可加载现有配置"
    fi

    systemctl stop "$SB_SERVICE" 2>/dev/null || true
    mv "$SB_BIN" "$SB_BIN.old.$$" 2>/dev/null || true
    mv "$tmp/sing-box-new" "$SB_BIN"; chmod 755 "$SB_BIN"
    systemctl start "$SB_SERVICE" 2>/dev/null || true
    sleep 1
    if systemctl is-active "$SB_SERVICE" >/dev/null 2>&1; then
        rm -f "$SB_BIN.old.$$"
        print_ok "更新完成: $cur → $latest"
    else
        print_error "新版本启动失败，回滚到 $cur"
        journalctl -u "$SB_SERVICE" -n 10 --no-pager | tail -10 >&2
        systemctl stop "$SB_SERVICE" 2>/dev/null || true
        mv "$SB_BIN.old.$$" "$SB_BIN" 2>/dev/null || true
        systemctl start "$SB_SERVICE" 2>/dev/null || true
        sleep 1
        systemctl is-active "$SB_SERVICE" >/dev/null 2>&1 \
            && print_ok "已回滚，服务恢复运行 (旧版本 $cur)" \
            || print_error "回滚后服务仍异常，请手工检查 journalctl -u $SB_SERVICE"
        return 1
    fi
}

do_uninstall() {
    print_warn "将停止并卸载 sing-box 内核与 service（保留配置目录）"
    read -r -p "确认? [y/N]: " yn
    [[ "$yn" =~ ^[yY] ]] || return 0
    systemctl stop "$SB_SERVICE" 2>/dev/null || true
    systemctl disable "$SB_SERVICE" 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload
    rm -f "$SB_BIN"
    print_ok "已卸载内核与 service。配置保留于 $SB_ROOT/config（手动确认后可删除）"
}

# ---- CLI 入口 ----
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cmd="${1:-status}"
    case "$cmd" in
        install)
            ver="${2:-$(sb_latest_version)}"
            ver="${ver#v}"
            if [[ "$#" -lt 2 && "${3:-}" != "pre" ]]; then :; fi
            if [[ -n "$ver" ]]; then
                do_install "$ver"
                if [[ ! -f /etc/systemd/system/sing-box.service ]]; then
                    install_service
                fi
            fi
            ;;
        install-pre) ver="$(sb_latest_pre)"; [[ -n "$ver" ]] && { do_install "$ver"; [[ -f /etc/systemd/system/sing-box.service ]] || install_service; } ;;
        update)      do_update ;;
        status)      core_status ;;
        service)     install_service ;;
        uninstall)   do_uninstall ;;
        *)           core_status ;;
    esac
fi
