#!/bin/bash
# ==============================================================
# install.sh — SB-Panel 一键拉取/安装/更新  (源自 GitHub)
#   服务端:  bash <(curl -Ls https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh) server
#   客户端:  bash <(curl -Ls https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh) client
#   升级:    bash <(curl -Ls ...) update        (更新源码并重启服务)
# 环境开关 SRV_ROOT / CLI_ROOT 可覆盖安装路径
# ==============================================================
set -u
REPO="https://github.com/mi1314cat/sing-box-core.git"
SRV_ROOT="${SRV_ROOT:-/root/catmi/sing-box}"
CLI_ROOT="${CLI_ROOT:-/opt/sb-client}"
SRC_DIR="${SRC_DIR:-/opt/sing-box-core}"
SHARE_PORT="${SHARE_PORT:-9292}"
MODE="${1:-menu}"

RED='\033[31m[ERR]  '; GRN='\033[32m[OK]   '; CYA='\033[36m[INFO] '; RST='\033[0m'
say(){ printf "${CYA}%s${RST}\n" "$*" >&2; }
say_ok(){ printf "${GRN}%s${RST}\n" "$*" >&2; }
say_err(){ printf "${RED}%s${RST}\n" "$*" >&2; }

install_deps() {
    local miss=() b
    for b in curl git jq openssl; do command -v "$b" >/dev/null 2>&1 || miss+=("$b"); done
    (( ${#miss[@]} )) || return 0
    say "安装依赖: ${miss[*]}"
    if command -v apt-get >/dev/null; then apt-get update -qq >/dev/null 2>&1; apt-get install -y --no-install-recommends "${miss[@]}" >/dev/null 2>&1
    elif command -v dnf >/dev/null; then dnf install -y "${miss[@]}" >/dev/null 2>&1
    elif command -v apk >/dev/null; then apk add --no-cache "${miss[@]}" >/dev/null 2>&1
    fi
    say_ok "依赖就绪"
}

fetch_repo() {
    if [[ -d "$SRC_DIR/.git" ]]; then
        say "更新源码 (git pull)"
        git -C "$SRC_DIR" fetch --all -q
        if git -C "$SRC_DIR" reset -q --hard origin/HEAD; then say_ok "源码 = $(git -C "$SRC_DIR" rev-parse --short HEAD)"; else say_err "git 拉取失败, 保留现有源码"; fi
    else
        say "克隆 $REPO → $SRC_DIR"
        if ! git clone --depth 1 "$REPO" "$SRC_DIR"; then say_err "git clone 失败"; return 1; fi
        say_ok "源码 = $(git -C "$SRC_DIR" rev-parse --short HEAD)"
    fi
}

install_share_service() {
    if ! command -v systemctl >/dev/null; then return 0; fi
    cat > /etc/systemd/system/sing-box-share.service <<EOF
[Unit]
Description=SB-Panel Share URL HTTP Service
After=network-online.target sing-box.service
[Service]
Type=simple
Environment=SHARE_DIR=$SRV_ROOT/share
Environment=SHARE_PORT=$SHARE_PORT
ExecStart=/usr/bin/python3 $SRV_ROOT/conf/share_server.py
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; then
        systemctl daemon-reload
        systemctl enable -q --now sing-box-share
        say_ok "sing-box-share.service (:$SHARE_PORT)"
    else
        say_err "无 systemd, 手动运行: SHARE_DIR=$SRV_ROOT/share SHARE_PORT=$SHARE_PORT python3 $SRV_ROOT/conf/share_server.py"
    fi
}

setup_server() {
    say "服务端安装 → $SRV_ROOT"
    install_deps || return 1
    mkdir -p "$SRV_ROOT"/{conf,config,out,backup,share/shares}
    cp -f "$SRC_DIR/src/sing-box.sh" "$SRV_ROOT/"
    cp -f "$SRC_DIR/src/conf/"*.sh "$SRC_DIR/src/conf/share_server.py" "$SRV_ROOT/conf/"
    chmod +x "$SRV_ROOT/sing-box.sh" "$SRV_ROOT/conf/"*.sh 2>/dev/null
    # 基础配置幂等初始化
    printf "0\n0\n" | bash "$SRV_ROOT/sing-box.sh" >/dev/null 2>&1 || true
    SB_ROOT="$SRV_ROOT" "$SRV_ROOT/sing-box.sh" check 2>&1 | tail -1
    install_share_service
    say_ok "Server 就绪: bash $SRV_ROOT/sing-box.sh"
}

setup_client() {
    say "客户端安装 → $CLI_ROOT"
    install_deps || return 1
    mkdir -p /usr/local/bin
    cp -f "$SRC_DIR/src/client/client.sh" /usr/local/bin/sb-client
    chmod +x /usr/local/bin/sb-client
    CLIENT_ROOT="$CLI_ROOT" sb-client install
    CLIENT_ROOT="$CLI_ROOT" sb-client init
    CLIENT_ROOT="$CLI_ROOT" sb-client install-ui || say_err "Web UI 下载失败, 稍后 bash /usr/local/bin/sb-client install-ui"
    say_ok "客户端入口: bash /usr/local/bin/sb-client (add <share-url> 导入节点)"
}

do_update() {
    fetch_repo || return 1
    say "热替换服务端脚本"
    cp -f "$SRC_DIR/src/sing-box.sh" "$SRV_ROOT/"; cp -f "$SRC_DIR/src/conf/"*.sh "$SRC_DIR/src/conf/share_server.py" "$SRV_ROOT/conf/"
    "$SRV_ROOT/sing-box.sh" check 2>&1 | tail -1
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; then systemctl restart sing-box sing-box-share 2>/dev/null; fi
    say_ok "服务端已更新并重启"
    echo
    if [[ -f /usr/local/bin/sb-client ]]; then
        cp -f "$SRC_DIR/src/client/client.sh" /usr/local/bin/sb-client; chmod +x /usr/local/bin/sb-client
        CLIENT_ROOT="$CLI_ROOT" sb-client restart 2>/dev/null || true
        say_ok "客户端脚本已更新"
    fi
}

menu() {
    cat <<EOM &2
sb-panel 一键管理
  1) server  传统 server 面板 ( SB 内核 + 协议 + DNS/规则/端口转发 )
  2) client  ( sing-box 客户端 + LAN HTTP/SOCKS 2080 + Web UI )
  3) update  热更新两端
  0) 退出
EOM
    read -r -p "选择: " c
    case "$c" in
        1) install_deps; fetch_repo && setup_server ;;
        2) install_deps; fetch_repo && setup_client ;;
        3) fetch_repo && do_update ;;
        0) exit 0 ;;
        *) say_err "无效选项"; ;;
    esac
}

case "$MODE" in
    menu) menu ;;
    server) SRC_DIR="${SRC_DIR:-/opt/sing-box-core-src}"; fetch_repo && setup_server ;;
    client) SRC_DIR="${SRC_DIR:-/opt/sing-box-core-src}"; fetch_repo && setup_client ;;
    update) do_update ;;
    *) say_err "用法: install.sh {server|client|update|menu}" ;;
esac
