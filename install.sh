#!/bin/bash
# ==============================================================
# install.sh — SB-Panel 一键入口
#   bash <(curl -Ls https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh)
# 职责: 获取项目 → 初始化 → 立即进入 sing-box.sh 管理面板
#       (所有交互/错误处理都在面板里, 本脚本只做"取码 + 环境 + 交接")
# 交互风格自 mi1314cat/xary-core xray-panel.sh (颜色/回车返回/编号菜单)
# ==============================================================
set -u
REPO="https://github.com/mi1314cat/sing-box-core"
SRV_ROOT="${SRV_ROOT:-/root/catmi/sing-box}"
CLI_ROOT="${CLI_ROOT:-/opt/sb-client}"
SRC_DIR="${SRC_DIR:-$SRV_ROOT/src-upstream}"
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[36m'; PLAIN='\033[0m'
info(){ printf "${BLUE}[INFO] %s${PLAIN}\n" "$*"; }
ok(){   printf "${GREEN}[OK]   %s${PLAIN}\n" "$*"; }
warn(){ printf "${YELLOW}[WARN] %s${PLAIN}\n" "$*"; }
err(){  printf "${RED}[ERROR] %s${PLAIN}\n" "$*" >&2; }
die(){  err "$*"; printf "${RED}请根据上面的原因检查后重试。安装没有完成。${PLAIN}\n" >&2; exit 1; }

deps_check() {
    local miss=() b
    for b in curl git jq openssl python3 tar; do command -v "$b" >/dev/null 2>&1 || miss+=("$b"); done
    (( ${#miss[@]} > 0 )) || return 0
    info "安装依赖: ${miss[*]}"
    if command -v apt-get >/dev/null; then apt-get update -qq >/dev/null 2>&1; apt-get install -y --no-install-recommends "${miss[@]}" >/dev/null 2>&1
    elif command -v dnf >/dev/null; then dnf install -y "${miss[@]}" >/dev/null 2>&1
    elif command -v apk >/dev/null; then apk add --no-cache "${miss[@]}" >/dev/null 2>&1
    else err "未识别包管理器, 手动安装: ${miss[*]}"; return 1; fi
    ok "依赖就绪"
}

# 静默拉取源码; 失败保留简短真实错误; 返回 10 = "已最新"
fetch() {
    if [[ -d "$SRC_DIR/.git" ]]; then
        info "更新管理脚本"
        if git -C "$SRC_DIR" fetch -q origin main 2>/dev/null; then
            if [[ "$(git -C "$SRC_DIR" rev-parse HEAD)" == "$(git -C "$SRC_DIR" rev-parse FETCH_HEAD)" ]]; then
                ok "当前已是最新版本"; return 10
            fi
            git -C "$SRC_DIR" reset -q --hard FETCH_HEAD || die "更新失败"
            ok "管理脚本已更新 ($(git -C "$SRC_DIR" rev-parse --short HEAD))"
            return 0
        else
            die "无法从 GitHub 获取最新脚本 (检查网络)"
        fi
    else
        info "获取 Sing-box 管理脚本"
        git clone -q --depth 1 "$REPO" "$SRC_DIR" 2>/dev/null || {
            curl -fsSL --max-time 120 "https://github.com/mi1314cat/sing-box-core/archive/refs/heads/main.tar.gz" -o /tmp/sbcore.tar.gz 2>/dev/null \
                && mkdir -p "$SRC_DIR" \
                && tar -xzf /tmp/sbcore.tar.gz -C "$SRC_DIR" --strip-components=1 2>/dev/null \
                || die "无法从 GitHub 获取脚本 (请检查网络连接后重试)"
        }
        ok "Sing-box 管理脚本"
    fi
}

server_ver() { "$SRV_ROOT/sing-box" version 2>/dev/null | head -1 | awk '{print $3}'; }

config_ok() { SB_ROOT="$SRV_ROOT" bash "$SRV_ROOT/sing-box.sh" check >/dev/null 2>&1; }

status_block() {
    local srvSta=$( [[ -d /run/systemd/system ]] && systemctl is-active sing-box 2>/dev/null|| echo inactive)
    local st="未运行"; [[ "$srvSta" == "active" ]] && st="运行"
    local ver; ver=$(server_ver); [[ -z "$ver" && -f "$CLI_ROOT/core/sing-box" ]] && ver=$("$CLI_ROOT/core/sing-box" version 2>/dev/null|head -1|awk '{print $3}')
    local cn; cn=$(ls "$SRV_ROOT"/config/*.json 2>/dev/null | grep -cv '^-')
    printf "Sing-box 状态: %s%s%s   版本: %s%s%s   配置目录: %s   节点数: %s%s\n" \
        "$([[ $st == 运行 ]] && echo "$GREEN" || echo "$RED")" "$st" "$PLAIN" "$GREEN" "${ver:--}" "$PLAIN" "$SRV_ROOT" "$GREEN" "${cn:-0}"
    # service 状态行 (参考 xray 风格)
    [[ -d /run/systemd/system ]] && printf "服务(systemd): %s%s%s\n" "$([[ $(systemctl is-enabled sing-box 2>/dev/null) == enabled ]] && echo $GREEN已启用 || echo $YELLOW未启用)" "$PLAIN" ""
}

rsync_files() {
    cp -rf "$SRC_DIR/src/conf/." "$SRV_ROOT/conf/" 2>/dev/null
    cp -f "$SRC_DIR/src/sing-box.sh" "$SRV_ROOT/" 2>/dev/null
    chmod +x "$SRV_ROOT/sing-box.sh" "$SRV_ROOT/conf/"*.sh 2>/dev/null
    ok "服务端脚本已热更新"
}

# server 安装(非交互走一键): 每一步真实验证, 任一失败即停
do_server() {
    info "正在初始化 Sing-box 服务端..."
    mkdir -p "$SRV_ROOT"/{conf,config,out,backup,share/shares} || die "目录创建失败"
    cp -rf "$SRC_DIR/src/conf/." "$SRV_ROOT/conf/" || die "模块复制失败"
    cp -f "$SRC_DIR/src/sing-box.sh" "$SRV_ROOT/" || die "面板复制失败"
    chmod +x "$SRV_ROOT/sing-box.sh" "$SRV_ROOT/conf/"*.sh 2>/dev/null
    ok "项目文件"
    if [[ ! -x "$SRV_ROOT/sing-box" ]]; then
        info "正在安装 Sing-box 内核..."
        ( cd "$SRV_ROOT" && SB_ROOT="$SRV_ROOT" bash conf/core.sh install >/dev/null 2>&1 ) || die "Sing-box 内核下载失败"
        ok "Sing-box 核心 ($("$SRV_ROOT"/sing-box version 2>/dev/null | head -1))"
    fi
    if [[ -d /run/systemd/system ]]; then
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box unified service (sb-panel)
After=network-online.target
[Service]
Type=simple
ExecStart=$SRV_ROOT/sing-box -D $SRV_ROOT -C $SRV_ROOT/config run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
        cat > /etc/systemd/system/sing-box-share.service <<EOF
[Unit]
Description=SB-Panel Share URL HTTP Service
After=network-online.target sing-box.service
[Service]
Type=simple
Environment=SHARE_DIR=$SRV_ROOT/share
Environment=SHARE_PORT=9292
ExecStart=/usr/bin/python3 $SRV_ROOT/conf/share_server.py
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable -q sing-box
        ok "systemd 服务"
    fi
    # 全新安装: 先种下基础配置 (00-log/direct), 保证 check 有内容
    if [[ -z "$(ls "$SRV_ROOT"/config/*.json 2>/dev/null | head -1)" ]]; then
        SB_ROOT="$SRV_ROOT" bash "$SRV_ROOT/sing-box.sh" init >/dev/null 2>&1 || die "基础配置生成失败"
        ok "基础配置"
    fi
    info "正在检查配置..."
    if SB_ROOT="$SRV_ROOT" bash "$SRV_ROOT/sing-box.sh" check >/dev/null 2>&1; then
        ok "配置检查"
    else
        err "Sing-box 配置检查失败, 安装未完成。"
        echo "  原因: $(SB_ROOT="$SRV_ROOT" bash "$SRV_ROOT/sing-box.sh" check 2>&1 | tail -3 | sed 's/^/  /')"
        echo "  请检查: $SRV_ROOT/config/*.json (证书路径/字段), 修复后重新执行本命令"
        exit 1
    fi
    if [[ -d /run/systemd/system ]]; then
        info "正在启动服务..."
        if systemctl start sing-box && sleep 1 && systemctl is-active sing-box >/dev/null; then
            ok "服务启动"
        else die "sing-box.service 启动失败"; fi
        if systemctl enable -q --now sing-box-share 2>/dev/null && (sleep 1; curl -fsS localhost:9292/status >/dev/null 2>&1); then
            ok "分享服务 (9292)"
        else
            warn "分享服务未启动, 分享链接功能暂不可用 (不影响主面板)。查看: journalctl -u sing-box-share"
        fi
    fi
    echo
    echo "--------------------------------"
    ok "Sing-box 安装完成"
    echo "  版本: $(server_ver)  路径: $SRV_ROOT"
    echo "--------------------------------"
    read -r -p "按回车进入管理面板..." _
    SB_ROOT="$SRV_ROOT" bash "$SRV_ROOT/sing-box.sh"
}

do_client() {
    info "正在初始化 Sing-box 客户端..."
    mkdir -p "$CLI_ROOT"/{conf,core,nodes,share-state,ui} /usr/local/bin || die "目录创建失败"
    cp -f "$SRC_DIR/src/client/client.sh" /usr/local/bin/sb-client || die "复制失败"
    chmod +x /usr/local/bin/sb-client
    ok "项目文件"
    if [[ ! -x "$CLI_ROOT/core/sing-box" ]]; then
        info "正在安装 Sing-box 内核..."
        CLIENT_ROOT="$CLI_ROOT" bash /usr/local/bin/sb-client install >/dev/null 2>&1 || die "Sing-box 内核下载失败"
        ok "Sing-box 核心 ($("$CLI_ROOT/core/sing-box" version 2>/dev/null | head -1))"
    fi
    CLIENT_ROOT="$CLI_ROOT" bash /usr/local/bin/sb-client init >/dev/null 2>&1 || die "客户端初始化失败"
    ok "配置检查"
    CLIENT_ROOT="$CLI_ROOT" bash /usr/local/bin/sb-client install-ui >/dev/null 2>&1 && ok "Web UI (metacubexd)" || warn "UI 下载失败, 可稍后 bash sb-client install-ui"
    echo
    printf "  HTTP/SOCKS: %s:2080   Clash API: %s:19090\n" "$CLI_ROOT" "$CLI_ROOT"
    echo "--------------------------------"
    ok "客户端安装完成"
    read -r -p "按回车进入管理面板..." _
    CLIENT_ROOT="$CLI_ROOT" bash /usr/local/bin/sb-client
}

# 已装机器重复运行: 不覆盖配置, 交给面板
existing() {
    echo -e "${GREEN}Sing-box 管理脚本${PLAIN}"
    echo "----------------------"
    local srvSta=$(systemctl is-active sing-box 2>/dev/null || echo inactive)
    local col=RED; [[ $srvSta == active ]] && col=GREEN
    printf "服务状态: ${col}%s${PLAIN}\n" "$srvSta"
    printf "版本:     %s\n" "$(server_ver)"
    printf "节点数:   %s\n" "$(ls "$SRV_ROOT"/config/*.json 2>/dev/null | grep -cv '^-')"
    echo "----------------------"
    read -r -p "已安装; 回车直接进入管理面板, 输入 u 为更新脚本:" a
    case "$a" in
        u|U|更新)
            local rc=0
            fetch || rc=$?
            if [[ $rc -eq 10 ]]; then ok "当前已是最新版本"
            elif [[ $rc -eq 0 ]]; then
                rsync_files
                config_ok && ok "更新通过配置检查" || warn "更新后配置检查失败, 请按面板内 提示 修复"
            else err "更新失败, 沿用本地版本"; fi ;;
        *) : ;;
    esac
    SB_ROOT="$SRV_ROOT" bash "$SRV_ROOT/sing-box.sh"
}

if [[ -d /run/systemd/system ]] && systemctl is-active sing-box >/dev/null 2>&1 \
   && [[ -x "$SRV_ROOT/sing-box.sh" ]]; then
    existing; exit $?
fi

deps_check || exit 1
fetch
frc=$?
if [[ $frc -ne 0 && $frc -ne 10 ]]; then exit 1; fi

MODE="${1:-}"
if [[ -z "$MODE" ]]; then
    clear
    echo -e "${GREEN}sing-box 一键管理${PLAIN}"
    echo "----------------------"
    echo -e "${GREEN}1.${PLAIN} 服务端 (Sing-box 面板 + 内核 + 分享服务)"
    echo -e "${GREEN}2.${PLAIN} 客户端 (LAN HTTP/SOCKS + Web UI)"
    echo -e "${GREEN}0.${PLAIN} 退出"
    echo "----------------------"
    read -r -p "请输入选项 [0-2]: " MODE
fi
case "$MODE" in
    1|server) do_server ;;
    2|client) do_client ;;
    0) exit 0 ;;
    *) err "无效选项 $MODE"; exit 1 ;;
esac
