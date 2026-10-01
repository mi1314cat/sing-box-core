#!/bin/bash
# ==============================================================
# client.sh — SB-Panel Sing-box Client (正式客户端)
# 内核: sing-box(唯一)  |  入站: mixed(HTTP+SOCKS)
# 多节点: 每节点一个 nodes/node-<tag>.json, conf/90-outbounds.json 自动聚合
# 管理: Clash API (external_controller) + metacubexd Web UI
# 服务: systemd sb-client.service (缺失时回退 transient sb-client-adhoc)
# 导入: client.sh add <share-url | local.json>
# CLI: bash client.sh {install|init|add|list|update|del|start|stop|restart|reload|status|info|check|install-ui|service|settings}
# 部署根目录默认 /opt/sb-client (可在 /etc/sb-client.env 覆盖)
# ==============================================================
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# 非交互/无 TERM 环境 (cron, ssh 无 pty, 管道) 下 clear 会报错, 这里兜底
export TERM="${TERM:-xterm}"

# ---------- 环境 ----------
if [[ -f /etc/sb-client.env ]]; then source /etc/sb-client.env; fi

# ---------- 下载代理探测 ----------
# curl 本身支持 http_proxy/https_proxy, 但用户通常只写在 /etc/profile.d/ 下,
# 而非登录 shell (ssh host 'cmd'、面板内执行、定时任务) 不加载该文件 ——
# 结果就是本机明明开着代理, 下载却走直连直到超时。
# 这里主动探测本机常见代理端口, 能用就导出变量, curl 会自动采用。
# 不覆盖用户显式设置: 已有 http_proxy/https_proxy 时原样交给 curl。
sb_detect_proxy() {
    if [[ -n "${https_proxy:-}${http_proxy:-}" ]]; then
        SB_PROXY_MODE="环境变量 ($(echo "${https_proxy:-$http_proxy}"))"
        return 0
    fi
    local host port code
    for host in 127.0.0.1 localhost; do
        for port in 7890 7891 7897 10808 10809 8080 8118 1080 1081 20171 33211; do
            # 探测必须带超时。裸的 (exec 3<>/dev/tcp/...) 在端口被防火墙
            # DROP (而不是 REJECT) 时不会立刻失败, 而是挂满整个 TCP 超时
            # (Linux 默认约 130 秒)。11 个端口 x 2 个 host 串下来就是几分钟,
            # 表现为"选了菜单 3 之后界面卡住不动"。
            # 端口没开时 REJECT 会秒回, 所以卡住只发生在被静默丢弃的端口上,
            # 但只要有一个中招, 整轮探测就废了。
            timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null || continue
            # (fd 3 在上面的 timeout 子 shell 里, 父进程无需再关)
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                   --proxy "http://$host:$port" https://github.com/ 2>/dev/null)
            [[ "$code" =~ ^[1-4] ]] || continue
            export http_proxy="http://$host:$port" https_proxy="http://$host:$port"
            export all_proxy="http://$host:$port"
            export no_proxy="127.0.0.1,localhost,::1${no_proxy:+,$no_proxy}"
            SB_PROXY_MODE="自动探测 $host:$port"
            return 0
        done
    done
    SB_PROXY_MODE="直连 (未发现本机可用代理)"
    return 1
}

# ---------- 客户端下载代理 ----------
# curl 本身支持 http_proxy/https_proxy, 但很多机器把代理只写在
# /etc/profile.d/ 下, 而非登录 shell (ssh host 'cmd'、面板内执行、定时任务)
# 不加载该文件 —— 结果本机明明开着代理, 内核/UI 下载却走直连直到超时。
#
# 处理原则:
#   1. 用户显式设过 http_proxy/https_proxy -> 原样用, 不干预
#   2. 否则探测本机常见代理端口, 列出可用的让用户选
#   3. 默认是直连; 没探测到任何代理时不打扰用户
#   4. 非交互 (无 TTY, 管道/cron) 不提问, 静默直连
# 只用于客户端安装路径; 服务端不需要, 故不放在 lib.sh。
SB_PROXY_CANDS=()

sb_proxy_scan() { # 探测本机可用 HTTP 代理, 结果放进 SB_PROXY_CANDS
    SB_PROXY_CANDS=()
    [[ -n "${https_proxy:-}${http_proxy:-}" ]] && return 0
    local host port code
    for host in 127.0.0.1 localhost; do
        for port in 7890 7891 7897 10808 10809 8080 8118 1080 1081 20171 33211; do
            # 探测必须带超时。裸的 (exec 3<>/dev/tcp/...) 在端口被防火墙
            # DROP (而不是 REJECT) 时不会立刻失败, 而是挂满整个 TCP 超时
            # (Linux 默认约 130 秒)。11 个端口 x 2 个 host 串下来就是几分钟,
            # 表现为"选了菜单 3 之后界面卡住不动"。
            # 端口没开时 REJECT 会秒回, 所以卡住只发生在被静默丢弃的端口上,
            # 但只要有一个中招, 整轮探测就废了。
            timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null || continue
            # (fd 3 在上面的 timeout 子 shell 里, 父进程无需再关)
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                   --proxy "http://$host:$port" https://github.com/ 2>/dev/null)
            # 1xx~4xx 都算可用 (GitHub 会 3xx 重定向); 000 才是不可用
            [[ "$code" =~ ^[1-4] ]] || continue
            SB_PROXY_CANDS+=("http://$host:$port")
        done
    done
    return 0
}

sb_proxy_apply() { # $1 = 代理地址; 空 = 直连
    if [[ -n "$1" ]]; then
        export http_proxy="$1" https_proxy="$1" all_proxy="$1"
        export no_proxy="127.0.0.1,localhost,::1${no_proxy:+,$no_proxy}"
    fi
}

sb_pick_proxy() { # 让用户选下载通道; 默认直连。$1 = 用途说明(给提示文案用)
    # 已显式配置: 不打扰
    if [[ -n "${https_proxy:-}${http_proxy:-}" ]]; then
        print_msg "下载通道: 环境变量 ${https_proxy:-$http_proxy}"
        return 0
    fi
    sb_proxy_scan
    (( ${#SB_PROXY_CANDS[@]} == 0 )) && return 0   # 没代理 -> 静默直连
    # 非交互: 静默直连
    [[ -t 0 ]] || return 0
    print_warn "检测到本机可用代理 (${1:-内核/UI 将从 GitHub 下载}):"
    local i c
    for i in "${!SB_PROXY_CANDS[@]}"; do
        printf "  %d) 使用 %s\n" "$((i+1))" "${SB_PROXY_CANDS[$i]}" >&2
    done
    printf "  0) 不使用代理, 直连 (默认)\n" >&2
    local c=""
    read -r -p "请选择下载通道 [0-${#SB_PROXY_CANDS[@]}, 默认 0]: " c || c=""
    c="${c// /}"
    if [[ "$c" =~ ^[1-9][0-9]*$ ]] && (( c >= 1 && c <= ${#SB_PROXY_CANDS[@]} )); then
        sb_proxy_apply "${SB_PROXY_CANDS[$((c-1))]}"
        print_ok "下载通道: ${SB_PROXY_CANDS[$((c-1))]}"
    else
        print_ok "下载通道: 直连"
    fi
    return 0
}

CLIENT_ROOT="${CLIENT_ROOT:-/opt/sb-client}"
CLIENT_BIN="${CLIENT_BIN:-$CLIENT_ROOT/core/sing-box}"   # 客户端自己配置片段
CLIENT_CONF="${CLIENT_CONF:-$CLIENT_ROOT/conf}"
CLIENT_UI="${CLIENT_UI:-$CLIENT_ROOT/ui}"                # external_ui 目录
CLIENT_NODE_DIR="${CLIENT_NODE_DIR:-$CLIENT_ROOT/nodes}" # 节点片段
PORT_MIXED="${PORT_MIXED:-2080}"                         # LAN HTTP/SOCKS 入站 (避开 1080 10809)
PORT_CLASH="${PORT_CLASH:-19090}"                        # 避碰: mihomo/clash 常占 9090
BIND_LAN="${BIND_LAN:-0.0.0.0}"                          # LAN 支持; 127.0.0.1=仅本机
CLASH_LISTEN="${CLASH_LISTEN:-0.0.0.0}"                  # LAN Web UI(ui 由 secret 保护)
CLASH_SECRET_FILE="${CLASH_SECRET_FILE:-$CLIENT_ROOT/.clash-secret}"
UI_ZIP_URL="${UI_ZIP_URL:-https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip}"
SB_UNIT_NAME="sb-client"        # 常驻 unit
SB_UNIT_ADHOC="sb-client-adhoc" # 临时 unit (仅当未安装常驻 unit 时)

# ---------- 颜色 / 输出 ----------
# 颜色变量允许被环境覆盖, 但覆盖值可能写成 '\e[31m' 这种字面量,
# 这里统一用 printf %b 归一化成真正的 ESC 字节, 否则作为 printf 参数传入时会原样打印
_c(){ printf '%b' "$1"; }
RED="$(_c "${RED:-\e[31m}")"; GREEN="$(_c "${GREEN:-\e[32m}")"; YELLOW="$(_c "${YELLOW:-\e[33m}")"
CYAN="$(_c "${CYAN:-\e[96m}")"; RESET="$(_c "${RESET:-\e[0m}")"
print_msg(){ printf "${CYAN}[SB-Client] %s${RESET}\n" "$1" >&2; }
print_ok(){ printf "${GREEN}[OK]   %s${RESET}\n" "$1" >&2; }
print_warn(){ printf "${YELLOW}[WARN] %s${RESET}\n" "$1" >&2; }
print_err(){ printf "${RED}[ERR]  %s${RESET}\n" "$1" >&2; }

# ---------- 基础 UI (纵向排版, 不依赖终端能力) ----------
ui_w() { # 规则线宽度: 跟随终端, 夹在 [36,66]
    # 注意: tput cols 在命令替换子 shell 中依然能读到真实宽度 (ncurses 会退回 /dev/tty),
    # 不能用 [[ -t 1 ]] 判断 —— 子 shell 里 stdout 是管道, 恒为假
    local w="${COLUMNS:-}"
    [[ "$w" =~ ^[0-9]+$ ]] || w="$(tput cols 2>/dev/null || true)"
    [[ "$w" =~ ^[0-9]+$ ]] || w=80
    (( w > 66 )) && w=66
    (( w < 36 )) && w=36
    echo $(( w - 4 ))
}
ui_rule(){ local n; n=$(ui_w); local line=""; local i=0
    while (( i < n )); do line+="─"; i=$((i+1)); done
    printf "${CYAN}%s${RESET}\n" "$line"; }
ui_title(){ ui_rule; printf "  %s%s%s\n" "$CYAN" "$1" "$RESET"; ui_rule; }
# 键值行: 标签统一 4 个全角字符(=8 显示列), 值列天然对齐; 状态符号放行尾, 避免宽度歧义
ui_kv(){ printf "  %s   %s\n" "$1" "$2"; }
ui_kv_ascii(){ printf "    %-12s : %s\n" "$1" "$2"; }
ui_clear(){ clear 2>/dev/null || printf '\033[H\033[2J\033[3J'; }
ui_menu(){ printf "  ${CYAN}%2s${RESET}. %s\n" "$1" "$2"; }

crand(){ openssl rand -hex 16; }

# ---------- 端口探测 (ss) ----------
# 返回 0=空闲 1=被本客户端占用 2=被其它进程占用 3=无法判断
# 用 ss 原生过滤 "sport = :PORT", 避免依赖不同 iproute2 版本的列位置
port_state() { # $1=port ; 端口信息写入 PORT_WHO / PORT_NAME
    local p="$1" line pid name
    PORT_WHO=""; PORT_NAME=""
    command -v ss >/dev/null 2>&1 || return 3
    line=$(ss -H -lntup "sport = :$p" 2>/dev/null | head -1)
    [[ -n "$line" ]] || return 0
    pid=$(printf '%s' "$line" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
    name=$(printf '%s' "$line" | grep -oE 'users:\(\("[^"]+"' | head -1 | sed 's/.*("//; s/"$//')
    PORT_WHO="$pid"; PORT_NAME="$name"
    if [[ -n "$pid" ]] && [[ "$(readlink -f /proc/$pid/exe 2>/dev/null)" == "$(readlink -f "$CLIENT_BIN" 2>/dev/null)" ]]; then
        return 1
    fi
    return 2
}
port_desc() { # $1=port -> 可读状态
    local rc=0; port_state "$1" || rc=$?
    case "$rc" in
        0) echo "空闲" ;;
        1) echo "已占用 · 本客户端 (PID $PORT_WHO)" ;;
        2) echo "已被占用 · ${PORT_NAME:-未知进程} (PID $PORT_WHO)" ;;
        *) echo "无法检测" ;;
    esac
}
lan_ip() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }
# 通配监听地址 (0.0.0.0 / ::) 不能直接当 URL 用, 解析成可连接的真实地址
host_addr() { # $1=listen
    case "$1" in
        ""|0.0.0.0|"::"|"[::]") lan_ip ;;
        *) echo "$1" ;;
    esac
}

# ---------- 实际生效配置的读取 (conf/*.json 为唯一事实来源) ----------
_cfgq(){ local f="$1" q="$2"; [[ -s "$f" ]] || return 1; jq -r "$q" "$f" 2>/dev/null; }
load_effective() {
    local mp cc
    EF_MIXED_PORT=""; EF_MIXED_LISTEN=""; EF_CLASH_HOST=""; EF_CLASH_PORT=""
    EF_UI=""; EF_SECRET=""
    if mp=$(_cfgq "$CLIENT_CONF/00-mixed.json" \
            '[.inbounds[]?|select(.type=="mixed")|.listen_port][0] // empty' 2>/dev/null) && [[ "$mp" =~ ^[0-9]+$ ]]; then
        EF_MIXED_PORT="$mp"
        EF_MIXED_LISTEN=$(_cfgq "$CLIENT_CONF/00-mixed.json" '[.inbounds[]?|select(.type=="mixed")|.listen][0] // "0.0.0.0"' 2>/dev/null)
    fi
    if cc=$(_cfgq "$CLIENT_CONF/01-clash.json" '.experimental.clash_api.external_controller // empty' 2>/dev/null) && [[ -n "$cc" ]]; then
        EF_CLASH_HOST="${cc%:*}"; EF_CLASH_PORT="${cc##*:}"
        EF_UI=$(_cfgq "$CLIENT_CONF/01-clash.json" '.experimental.clash_api.external_ui // empty' 2>/dev/null)
        EF_SECRET=$(_cfgq "$CLIENT_CONF/01-clash.json" '.experimental.clash_api.secret // empty' 2>/dev/null)
    fi
    # 回落到环境变量 (JSON 缺失/损坏时仍能显示并提示)
    [[ -n "$EF_MIXED_PORT" ]] || EF_MIXED_PORT="$PORT_MIXED"
    [[ -n "$EF_MIXED_LISTEN" ]] || EF_MIXED_LISTEN="$BIND_LAN"
    [[ -n "$EF_CLASH_PORT" ]] || { EF_CLASH_HOST="$CLASH_LISTEN"; EF_CLASH_PORT="$PORT_CLASH"; }
    return 0
}

# ---------- systemd unit ----------
have_systemd(){ [[ -d /run/systemd/system ]]; }
unit_installed(){ [[ -f "/etc/systemd/system/$SB_UNIT_NAME.service" ]]; }
active_unit() { # 实际承载本客户端的 unit 名
    if unit_installed; then echo "$SB_UNIT_NAME"; return 0; fi
    if have_systemd && systemctl is-active --quiet "$SB_UNIT_ADHOC" 2>/dev/null; then echo "$SB_UNIT_ADHOC"; return 0; fi
    return 1
}
do_service_install() { # 生成常驻 systemd unit
    have_systemd || { print_warn "无 systemd, 启动时使用临时 unit (重启后失效)"; return 0; }
    mkdir -p "$CLIENT_ROOT"
    cat > "/etc/systemd/system/$SB_UNIT_NAME.service" <<EOF
[Unit]
Description=SB-Panel sing-box client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$CLIENT_BIN run -D $CLIENT_CONF -C $CLIENT_CONF
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable -q "$SB_UNIT_NAME" 2>/dev/null || true
    print_ok "已安装 systemd 服务: $SB_UNIT_NAME.service (开机自启)"
}

# ---------- 服务状态 (systemd → 进程 → 端口 → 配置) ----------
find_sb_pid() { # 只认本客户端的 sing-box 进程, 避免误判其它实例
    local p exe want
    want="$(readlink -f "$CLIENT_BIN" 2>/dev/null)"
    for p in $(pgrep -x sing-box 2>/dev/null); do
        exe="$(readlink -f "/proc/$p/exe" 2>/dev/null)"
        [[ -n "$exe" && "$exe" == "$want" ]] || continue
        tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qF "$CLIENT_CONF" && { echo "$p"; return 0; }
    done
    return 1
}
cfg_check() { # 不再吞掉返回码
    "$CLIENT_BIN" check -D "$CLIENT_CONF" -C "$CLIENT_CONF" 2>&1
}
ST_SERVICE=""; ST_REASON=""; ST_CONF=""; ST_CONF_ERR=""; ST_CONF_OUT=""; ST_PID=""; ST_UNIT=""
collect_status() {
    load_effective
    ST_CONF_ERR=""
    ST_PID="$(find_sb_pid || true)"
    ST_UNIT="$(active_unit || true)"

    if [[ ! -d "$CLIENT_CONF" || ! -f "$CLIENT_CONF/00-mixed.json" ]]; then
        ST_CONF="未初始化"; ST_SERVICE="未初始化"
        ST_REASON="没有 $CLIENT_CONF/00-mixed.json, 请先执行“初始化基础配置”"
        return 0
    fi
    if [[ ! -x "$CLIENT_BIN" ]]; then
        ST_CONF="未知"; ST_SERVICE="未安装内核"
        ST_REASON="内核不存在: $CLIENT_BIN"
        return 0
    fi
    if ST_CONF_OUT="$(cfg_check 2>&1)"; then
        ST_CONF="正常"; ST_CONF_ERR=""
    else
        ST_CONF="异常"
        ST_CONF_ERR="$(printf '%s' "$ST_CONF_OUT" | grep -vE '^\[' | tail -2 | tr -d '\r' | head -1)"
    fi

    if [[ -n "$ST_PID" ]]; then
        local st=0; port_state "$EF_MIXED_PORT" || st=$?
        if (( st == 0 )); then
            ST_SERVICE="异常"
            ST_REASON="sing-box 进程 (PID $ST_PID) 存活, 但没有监听 $EF_MIXED_PORT"
        else
            ST_SERVICE="运行中"; ST_REASON=""
        fi
    else
        local u="${ST_UNIT:-$SB_UNIT_NAME}"
        local ua; ua="$(systemctl is-active "$u" 2>/dev/null || echo inactive)"
        local ue; ue="$(systemctl is-failed "$u" 2>/dev/null || echo no-failed)"
        if [[ "$ua" == "active" ]]; then
            ST_SERVICE="异常"
            ST_REASON="systemd 报 active, 但 sing-box 进程不存在 (可能已被 OOM/手动 kill)"
        elif [[ "$ue" == "failed" || "$ua" == "failed" ]]; then
            ST_SERVICE="启动失败"
            if [[ "$ST_CONF" == "异常" ]]; then
                ST_REASON="配置检查未通过, 服务无法启动"
            else
                ST_REASON="上次启动失败, 详见: journalctl -u $u -n 20"
            fi
        elif [[ -z "$ST_UNIT" && ! -f "/etc/systemd/system/$u.service" ]]; then
            ST_SERVICE="未安装服务"
            ST_REASON="没有 $u.service, 且 sing-box 未运行"
        else
            ST_SERVICE="未运行"
            ST_REASON="sing-box 未运行 (配置 $( [[ "$ST_CONF" == "正常" ]] && echo 正常 || echo 异常 ))"
        fi
    fi
}

# ---------- 节点数 (以实际加载的出站为准) ----------
node_count() {
    local f="$CLIENT_CONF/90-outbounds.json" n=0
    if [[ -s "$f" ]]; then
        n=$(jq '[.outbounds[]?|select(.type!="selector" and .type!="urltest" and .type!="direct")]|length' "$f" 2>/dev/null) || n=0
    fi
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    echo "$n"
}
node_file_count(){ local n=0; for f in "$CLIENT_NODE_DIR"/node-*.json; do [[ -f "$f" ]] && n=$((n+1)); done; echo "$n"; }

# ---------- install: 单独下载内核到 client 目录 ----------
# ---------- 卸载 ----------
# 服务端有 uninstall.sh, 客户端此前没有卸载入口 —— 换机/重装时只能手工清理。
# 这里补上, 与服务端行为对齐: 停服务 -> 删 unit -> 删目录 -> 删入口脚本。
do_uninstall() {
    print_title "SB-Panel 客户端卸载"
    echo "将停止/移除:" >&2
    echo "  - 服务 $SB_UNIT_NAME / $SB_UNIT_ADHOC" >&2
    echo "  - /etc/systemd/system/$SB_UNIT_NAME.service" >&2
    echo "  - $CLIENT_ROOT (内核/节点/配置/Web UI)" >&2
    echo "  - /usr/local/bin/sb-client" >&2
    echo "  - /etc/sb-client.env" >&2
    echo "" >&2
    echo -e "${GREEN}绝不触碰:${RESET}" >&2
    echo "  - 本机其它服务 (xray/mihomo/docker 等) 均不动" >&2
    echo "  - 本机其它代理/面板目录均不动" >&2
    echo "" >&2
    local a
    read -r -p "确认执行完整卸载? 输入 yes 继续: " a
    [[ "$(echo "$a" | tr A-Z a-z)" == "yes" ]] || { print_warn "已取消"; return 1; }
    local s
    for s in "$SB_UNIT_NAME" "$SB_UNIT_ADHOC"; do
        systemctl stop "$s" 2>/dev/null || true
        systemctl disable "$s" 2>/dev/null || true
        rm -f "/etc/systemd/system/$s.service"
    done
    systemctl daemon-reload 2>/dev/null
    print_ok "systemd 单元已清除"
    local b
    read -r -p "是否删除 $CLIENT_ROOT 目录 (内核/节点/配置/UI)? [y/N]: " b
    case "$(echo "$b" | tr A-Z a-z)" in
        y*|yes*)
            rm -rf "$CLIENT_ROOT" && print_ok "已删除 $CLIENT_ROOT"
            rm -f /usr/local/bin/sb-client /etc/sb-client.env
            print_ok "已删除 /usr/local/bin/sb-client"
            ;;
        *) print_warn "保留: $CLIENT_ROOT (可手动恢复)" ;;
    esac
    echo
    print_ok "SB-Panel 客户端卸载完成 (本机其它服务未受影响)"
}

do_install() {
    local ver_url arch
    arch=$(uname -m); case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) print_err "arch=$arch"; return 1 ;; esac
    mkdir -p "$CLIENT_ROOT/core" "$CLIENT_ROOT/nodes" "$CLIENT_ROOT/share-state" "$CLIENT_UI"
    [[ -x "$CLIENT_BIN" ]] && { print_ok "内核已存在: $($CLIENT_BIN version|head -1)"; return 0; }
    # 内核/UI 都要从 GitHub 下载: 让用户选通道 (默认直连; 没探测到代理则不打扰)
    sb_pick_proxy
    ver_url=$(curl -fsSL --max-time 20 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null | grep -oE '"tag_name": *"[^"]+' | cut -d'"' -f4 | head -1)
    # 降级: GitHub API 限流 (403) 时, 从 releases/latest 的重定向地址解析版本号
    if [[ -z "$ver_url" ]]; then
        ver_url=$(curl -sIL --max-time 20 -o /dev/null -w '%{url_effective}' \
                  "https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null \
                  | sed -E -n 's|.*/tag/v([0-9][^/]*)$|v\1|p')
    fi
    if [[ -z "$ver_url" ]]; then
        print_err "获取最新版本号失败 (GitHub API 可能限流, 请稍后重试或改用直连)"
        return 1
    fi
    local tag="$ver_url"
    local ok=0 url vn="${ver_url#v}"
    [[ "$vn" == "$ver_url" ]] && vn="$ver_url"
    local libc_suffix=""
    for libc_suffix in "-glibc" "" "-musl"; do
        url="https://github.com/SagerNet/sing-box/releases/download/$tag/sing-box-${vn}-linux-${arch}${libc_suffix}.tar.gz"
        if curl -fsSL --max-time 300 "$url" -o "$CLIENT_ROOT/core/core.tgz" 2>/dev/null; then ok=1; break; fi
    done
    [[ "$ok" == 1 ]] || { print_err "内核下载失败 (试过 glibc/generic/musl 命名)"; return 1; }
    tar -xzf "$CLIENT_ROOT/core/core.tgz" -C "$CLIENT_ROOT/core" --strip-components=1 "sing-box-${vn}-linux-${arch}${libc_suffix}/sing-box" \
        || { print_err "解包失败"; return 1; }
    rm -f "$CLIENT_ROOT/core/core.tgz"
    chmod +x "$CLIENT_BIN" 2>/dev/null || true
    print_ok "client 内核: $($CLIENT_BIN version 2>/dev/null | head -1)"
}

gen_clash_secret() {
    if [[ "${1:-$CLASH_LISTEN}" != "127.0.0.1" && "${1:-$CLASH_LISTEN}" != "::1" && ! -s "$CLASH_SECRET_FILE" ]]; then
        crand > "$CLASH_SECRET_FILE"; chmod 600 "$CLASH_SECRET_FILE"
        print_ok "已生成 Clash API secret (监听 ${1:-$CLASH_LISTEN}, sing-box 官方要求非 lo 监听必须设置 secret)"
    fi
}

# ---------- init / 写配置 ----------
write_mixed_conf() { # $1=listen $2=port
    cat > "$CLIENT_CONF/00-mixed.json" <<EOF
{ "inbounds": [ { "type": "mixed", "tag": "mixed-in", "listen": "$1", "listen_port": $2 } ] }
EOF
}
write_clash_conf() { # $1=host:port $2=ui_dir(空=不启用) $3=secret
    local secret_line="" sl2=""
    [[ -n "$3" ]] && secret_line=", \"secret\": \"$3\""
    [[ -n "$2" ]] && sl2=", \"external_ui\": \"$2\""
    cat > "$CLIENT_CONF/01-clash.json" <<EOF
{
  "experimental": {
    "clash_api": {
      "external_controller": "$1"$sl2$secret_line
    }
  }
}
EOF
}
do_init() {
    mkdir -p "$CLIENT_CONF" "$CLIENT_NODE_DIR" "$CLIENT_ROOT/share-state" "$CLIENT_UI"
    gen_clash_secret "$CLASH_LISTEN"
    local secret=""; [[ -s "$CLASH_SECRET_FILE" ]] && secret=$(cat "$CLASH_SECRET_FILE")
    write_mixed_conf "$BIND_LAN" "$PORT_MIXED"
    write_clash_conf "$CLASH_LISTEN:$PORT_CLASH" "$CLIENT_UI" "$secret"
    regen_selector
    do_service_install
    print_ok "基础配置完成 ($CLIENT_CONF): mixed=$BIND_LAN:$PORT_MIXED clash_api=$CLASH_LISTEN:$PORT_CLASH"
    if [[ ! -x "$CLIENT_BIN" ]]; then
        print_err "内核不存在 ($CLIENT_BIN), 无法校验或启动; 请先执行“1. 安装内核”"
        return 1
    fi
    # 初始化即启动: 新手不应该出现“配置好了但不知道下一步”的死路
    if cfg_check >/dev/null 2>&1; then
        if do_start; then sleep 1; print_ok "服务已启动, 可直接使用"; else print_warn "服务启动失败, 请查看“查看运行状态”"; return 1; fi
    else
        print_err "配置检查未通过, 服务未启动"; cfg_check 2>&1 | tail -3 >&2
        return 1
    fi
    return 0
}

# 读 nodes/*.json 聚合 selector + urltest
regen_selector() {
    python3 - "$CLIENT_ROOT/nodes" "$CLIENT_CONF/90-outbounds.json" <<'PYGEN'
import json,sys,glob,os
ndir,ofile=sys.argv[1],sys.argv[2]
obs=[]
for f in sorted(glob.glob(os.path.join(ndir,"node-*.json"))):
    j=json.load(open(f))
    obs.extend(j.get("outbounds",[]))
htags=set(o["detour"] for o in obs if o.get("detour"))
tags=[o["tag"] for o in obs if o.get("type")!="direct" and o["tag"] not in htags]
tags=tags or [o["tag"] for o in obs]
if not tags:
    cfg={"outbounds":[]}
else:
    cfg={"outbounds":obs+[
       {"type":"selector","tag":"PROXY","outbounds":tags,"default":tags[0]},
       {"type":"urltest","tag":"AUTO","outbounds":tags,"url":"https://www.gstatic.com/generate_204","interval":"3m"}],
       "route":{"final":"PROXY"}}
json.dump(cfg,open(ofile,"w"),indent=2)
PYGEN
}

# ---------- 变更后应用 (软重载优先, 失败再重启) ----------
apply_change() { # $1=说明 ; 0=成功
    local what="${1:-配置}"
    load_effective
    if ! cfg_check >/tmp/.sbapply.$$ 2>&1; then
        print_err "$what 之后配置检查未通过, 未应用到运行中的服务:"
        tail -2 /tmp/.sbapply.$$ >&2; rm -f /tmp/.sbapply.$$
        return 1
    fi
    rm -f /tmp/.sbapply.$$
    if [[ -n "$(find_sb_pid || true)" ]]; then
        do_reload && { print_ok "$what 已生效 (软重载, 零断流)"; return 0; }
        print_warn "软重载未成功, 改为重启"
    fi
    do_start && print_ok "$what 已生效 (已启动服务)" || { print_err "启动失败"; return 1; }
}

# ---------- add: share URL / 本地文件导入 ----------
add_node() {
    local src="$1"
    [[ -n "$src" ]] || { print_err "用法: client.sh add <share-url|本地配置文件>"; return 1; }
    local tmp; tmp=$(mktemp "$CLIENT_ROOT/share-state/.import.XXXXXX.json")
    if [[ "$src" =~ ^https?:// ]]; then
        # 拉分享链接同样会卡: 服务端在境外/被墙时直连就是干等 30 秒超时。
        # 安装时本来就有这个选项, 但只在安装流程里问过 (sb_pick_proxy 仅被
        # install 调用), 菜单 3 的拉取完全直连 —— 用户没安装时选过的通道,
        # 后面每次更新节点都用不上。这里复用同一个选择逻辑。
        sb_pick_proxy "拉取分享链接 (直连不通时可走本机代理)"
        local code
        code=$(curl -sSL -o "$tmp" -w '%{http_code}' --max-time 30 "$src" 2>/dev/null) || { rm -f "$tmp"; print_err "网络错误, 下载失败"
            print_warn "可重试并在提示时选择走本机代理"; return 1; }
        case "$code" in
            200) ;;
            410) rm -f "$tmp"; print_err "分享链接已失效(用尽/过期/禁用)"; return 1 ;;
            404) rm -f "$tmp"; print_err "链接不存在"; return 1 ;;
            503) rm -f "$tmp"; print_err "服务端配置暂不可用, 未消耗次数"; return 1 ;;
            *)   rm -f "$tmp"; print_err "HTTP $code"; return 1 ;;
        esac
        print_ok "分享配置已获取"
        IF_SOURCE="$src"
    else
        cp "$src" "$tmp" || { rm -f "$tmp"; print_err "无法读取 $src"; return 1; }
        export IF_SOURCE="$src"
    fi
    if ! "$CLIENT_BIN" check -c "$tmp" >/dev/null 2>&1 && ! "$CLIENT_BIN" check "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"; print_err "sing-box check 失败, 旧配置未变"; return 1
    fi
    local n_count
      # 被别的 outbound 当作 detour 依赖的 tag (如 shadowtls 的 "<tag>-out" 包装层)
      # 不是独立节点, 必须排除, 否则:
      #   - 它会单独建一个 node-<tag>-out.json, 与主节点文件里的依赖层重复
      #   - regen_selector 聚合时出现 duplicate outbound tag, 内核 check 直接失败
      # 与服务端 share.sh 的 gen_full_profile 保持同一套判定。
      HELPER_JQ='(.outbounds | map(select(.detour != null) | .detour)) as $deps
                 | .outbounds[]
                 | select(.type != "selector" and .type != "urltest" and .type != "direct")
                 | select((.tag as $t | $deps | index($t)) == null)'
      n_count=$(jq "[$HELPER_JQ] | length" "$tmp" 2>/dev/null || echo 1)
    if (( n_count <= 1 )); then
        import_one_outbound "$tmp"
    else
        local n=0 t tags
          tags=$(jq -r "$HELPER_JQ | .tag" "$tmp" 2>/dev/null)
        for t in $tags; do
            [[ -n "$t" ]] || continue
              # 必须连 detour 依赖一起切出来。
              # shadowtls 是两层结构: shadowsocks(tag=X) detour→ shadowtls(tag=X-out, 带
              # server/port)。只按 tag 选主节点会把 X-out 丢掉, 得到一份
              # server=null 且引用不存在 outbound 的坏配置 —— 内核启动即报
              # "dependency[X-out] not found", 表现为该节点连不上。
              jq --arg t "$t" '
                  [.outbounds[] | select(.tag == $t)] as $main
                  | (.outbounds[] | select(.tag == $t) | .detour) as $dep
                  | (if $dep == null then [] else [.outbounds[] | select(.tag == $dep)] end) as $helper
                  | {outbounds: ($helper + $main)}
              ' "$tmp" > "$CLIENT_NODE_DIR/node-$t.json"
            echo "$src" > "$CLIENT_NODE_DIR/node-$t.txt"
            echo "{\"tag\":\"$t\",\"source\":\"share\",\"imported_at\":\"$(date -Is)\"}" > "$CLIENT_NODE_DIR/node-$t.meta"
            n=$((n+1))
        done
          for t in $(jq -r '.outbounds[] | select(.type == "selector" or .type == "urltest" or .type == "direct") | .tag' "$tmp" 2>/dev/null) \
                   $(jq -r '(.outbounds | map(select(.detour != null) | .detour)) as $deps | .outbounds[] | select((.tag as $t | $deps | index($t)) != null) | .tag' "$tmp" 2>/dev/null); do
              [[ -n "$t" ]] || continue
            rm -f "$CLIENT_NODE_DIR/node-$t.json" "$CLIENT_NODE_DIR/node-$t.txt" "$CLIENT_NODE_DIR/node-$t.meta"
        done
        rm -f "$tmp"
        regen_selector
        print_ok "已导入 $n 个节点 (单个链接全量分享); 现 $(node_count) 个可用节点"
    fi
}

import_one_outbound() {
    local tmp="$1" tag
    tag=$(jq -r '.outbounds[0].tag // empty' "$tmp" 2>/dev/null)
    [[ -n "$tag" ]] || { rm -f "$tmp"; print_err "配置无 outbound"; return 1; }
    jq '{outbounds}' "$tmp" > "$CLIENT_NODE_DIR/node-$tag.json"
    echo "$IF_SOURCE" > "$CLIENT_NODE_DIR/node-$tag.txt"
    echo "{\"tag\":\"$tag\",\"source\":\"share\",\"imported_at\":\"$(date -Is)\"}" > "$CLIENT_NODE_DIR/node-$tag.meta"
    rm -f "$tmp"
    regen_selector
    print_ok "节点 $tag 已导入; 共 $(node_count) 个可用节点"
}

update_node() {
    # 同一个 share URL 会被多个节点共用, 必须去重, 否则重复下载会消耗服务端 max_uses
    local f src done_src=" " n=0 bad=0
    for f in "$CLIENT_NODE_DIR"/node-*.txt; do
        [[ -f "$f" ]] || continue
        src=$(cat "$f" 2>/dev/null)
        [[ "$src" == http* ]] || continue
        case "$done_src" in *" $src "*) continue ;; esac
        done_src="$done_src$src "
        local shared; shared=$(grep -lF "$src" "$CLIENT_NODE_DIR"/node-*.txt 2>/dev/null | wc -l)
        print_msg "重新拉取分享链接 ($shared 个节点共用)"
        if add_node "$src"; then n=$((n+1)); else bad=$((bad+1)); fi
    done
    if (( n == 0 && bad == 0 )); then
        print_warn "没有可更新的 share 链接 (仅本地导入的节点无法重拉)"
    elif (( bad > 0 )); then
        print_warn "$bad 个分享来源拉取失败 (链接可能已过期/用尽), 原有配置保持不变"
    fi
    (( n > 0 )) && print_ok "已更新 $n 个分享来源, 现 $(node_count) 个可用节点"
    return 0
}

del_node() {
    local tag="$1"
    [[ -f "$CLIENT_NODE_DIR/node-$tag.json" ]] || { print_err "无此节点: $tag"; return 1; }
    rm -f "$CLIENT_NODE_DIR"/node-"$tag".{json,txt,meta,meta.json}
    regen_selector
    print_ok "已删除 $tag, 现 $(node_count) 个可用节点"
}

# ---------- 服务控制 ----------
do_start(){
    if ! have_systemd; then
        nohup "$CLIENT_BIN" run -D "$CLIENT_CONF" -C "$CLIENT_CONF" >/dev/null 2>&1 &
        sleep 1; return 0
    fi
    unit_installed || do_service_install
    # 常驻 unit 与临时 unit 不能同时占用端口
    if [[ "$SB_UNIT_NAME" != "$SB_UNIT_ADHOC" ]]; then
        systemctl stop "$SB_UNIT_ADHOC" 2>/dev/null || true
    fi
    systemctl start "$SB_UNIT_NAME" && return 0
    print_err "systemd 启动失败, 诊断信息:"
    systemctl is-active "$SB_UNIT_NAME" >&2 || true
    journalctl -u "$SB_UNIT_NAME" -n 8 --no-pager 2>&1 | sed 's/^/  /' >&2
    return 1
}
do_stop(){
    if have_systemd; then
        systemctl stop "$SB_UNIT_NAME" 2>/dev/null || true
        systemctl stop "$SB_UNIT_ADHOC" 2>/dev/null || true
    fi
    local p; for p in $(pgrep -x sing-box 2>/dev/null); do
        [[ "$(readlink -f "/proc/$p/exe" 2>/dev/null)" == "$(readlink -f "$CLIENT_BIN" 2>/dev/null)" ]] || continue
        tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qF "$CLIENT_CONF" && kill "$p" 2>/dev/null || true
    done
    return 0
}
do_restart(){ do_stop; sleep 1; do_start; }
do_reload(){
    local p; p="$(find_sb_pid || true)"
    [[ -n "$p" ]] || { print_err "sing-box 未运行, 无需重载 (请先启动)"; return 1; }
    if have_systemd && unit_installed && systemctl is-active --quiet "$SB_UNIT_NAME" 2>/dev/null; then
        systemctl reload "$SB_UNIT_NAME" 2>/dev/null && return 0
    fi
    kill -HUP "$p" 2>/dev/null || return 1
    sleep 1
    [[ -d "/proc/$p" ]] || { print_err "重载后进程退出"; return 1; }
    return 0
}

do_status(){ # 详细状态
    collect_status
    ui_title "运行状态"
    case "$ST_SERVICE" in
        "运行中") ui_kv "服务状态" "${GREEN}● 运行中${RESET}" ;;
        "未运行") ui_kv "服务状态" "${YELLOW}○ 未运行${RESET}" ;;
        "启动失败") ui_kv "服务状态" "${RED}✗ 启动失败${RESET}" ;;
        "未初始化") ui_kv "服务状态" "${YELLOW}○ 未初始化${RESET}" ;;
        *) ui_kv "服务状态" "${RED}⚠ ${ST_SERVICE}${RESET}" ;;
    esac
    [[ -n "$ST_REASON" ]] && ui_kv "原    因" "$ST_REASON"
    case "$ST_CONF" in
        正常) ui_kv "配置状态" "${GREEN}✓ 正常${RESET}" ;;
        异常) ui_kv "配置状态" "${RED}✗ 检查失败${RESET}"; ui_kv "错    误" "$ST_CONF_ERR" ;;
        *) ui_kv "配置状态" "${YELLOW}⚠ $ST_CONF${RESET}" ;;
    esac
    ui_kv "内核版本" "$([[ -x "$CLIENT_BIN" ]] && "$CLIENT_BIN" version 2>/dev/null | head -1 || echo '未安装')"
    ui_kv "服务单元" "${ST_UNIT:-未安装 (无 systemd unit)}"
    ui_kv "进程 PID " "${ST_PID:-无}"
    ui_kv "节点数量" "$(node_count) (配置文件 $(node_file_count) 个)"
    echo
    ui_kv_ascii "HTTP/SOCKS" "$EF_MIXED_LISTEN:$EF_MIXED_PORT   $(port_state_mark "$EF_MIXED_PORT")"
    ui_kv_ascii "Clash API" "$EF_CLASH_HOST:$EF_CLASH_PORT   $(port_state_mark "$EF_CLASH_PORT")"
    echo
    functional_probe
    echo
    ui_kv_ascii "systemd" "$(systemctl is-enabled "$SB_UNIT_NAME" 2>/dev/null || echo '未安装') / $(systemctl is-active "${ST_UNIT:-$SB_UNIT_NAME}" 2>/dev/null || echo inactive)"
}
port_state_mark(){ # 端口 -> 简短标记
    local rc=0; port_state "$1" || rc=$?
    case "$rc" in
        0) printf "${GREEN}✓ 空闲${RESET}" ;;
        1) printf "${GREEN}✓ 监听中${RESET}" ;;
        2) printf "${RED}✗ ${PORT_NAME:-占用}${RESET}" ;;
        *) printf "${YELLOW}⚠ 未知${RESET}" ;;
    esac
}
functional_probe(){ # 真实可用性
    local code
    ui_kv_ascii "HTTP 实测" "$(code=$(curl -sS -m 12 -x "http://127.0.0.1:$EF_MIXED_PORT" -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null); if [[ "$code" == "204" ]]; then echo "${GREEN}✓ 代理可用 (204)${RESET}"; else echo "${YELLOW}⚠ 未通过 (code=${code:-无响应})${RESET}"; fi)"
    local sec=""; [[ -s "$CLASH_SECRET_FILE" ]] && sec=$(cat "$CLASH_SECRET_FILE")
    local h=(); [[ -n "$sec" ]] && h=(-H "Authorization: Bearer $sec")
    code=$(curl -sS -m 8 "${h[@]}" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$EF_CLASH_PORT/version" 2>/dev/null)
    ui_kv_ascii "API 实测" "$([[ "$code" == "200" ]] && echo "${GREEN}✓ 可访问${RESET}" || echo "${RED}✗ 不可访问 (code=${code:-无响应})${RESET}")"
    code=$(curl -sS -m 8 "${h[@]}" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$EF_CLASH_PORT/ui/" 2>/dev/null)
    ui_kv_ascii "WebUI 实测" "$([[ "$code" == "200" ]] && echo "${GREEN}✓ 可访问${RESET}" || echo "${YELLOW}⚠ 不可访问 (code=${code:-无响应})${RESET}")"
}

do_info(){ # Web UI / Clash API
    load_effective
    ui_title "Web UI / Clash API"
    local sec=""; [[ -s "$CLASH_SECRET_FILE" ]] && sec=$(cat "$CLASH_SECRET_FILE")
    local chost; chost="$(host_addr "$EF_CLASH_HOST")"
    printf "  ${CYAN}Clash API${RESET}\n"
    ui_kv_ascii "地址" "$chost:$EF_CLASH_PORT   (监听 $EF_CLASH_HOST)"
    ui_kv_ascii "端口状态" "$(port_desc "$EF_CLASH_PORT")"
    local code; code=$(curl -sS -m 8 ${sec:+-H "Authorization: Bearer $sec"} -o /dev/null -w '%{http_code}' "http://127.0.0.1:$EF_CLASH_PORT/version" 2>/dev/null)
    ui_kv_ascii "访问状态" "$([[ "$code" == "200" ]] && echo "${GREEN}● 可访问${RESET}" || echo "${RED}✗ 不可访问 (code=${code:-无响应})${RESET}")"
    ui_kv_ascii "密钥" "${sec:-无 (仅监听 127.0.0.1 时 sing-box 才允许无密钥)}"
    echo
    printf "  ${CYAN}Web UI${RESET}\n"
    if [[ -n "$EF_UI" ]]; then
        ui_kv_ascii "地址" "http://$chost:$EF_CLASH_PORT/ui/"
        ui_kv_ascii "本地地址" "http://127.0.0.1:$EF_CLASH_PORT/ui/"
        ui_kv_ascii "目录" "$EF_UI ($( [[ -f "$EF_UI/index.html" ]] && echo '已就绪' || echo '缺少 index.html' ))"
        local uic; uic=$(curl -sS -m 8 ${sec:+-H "Authorization: Bearer $sec"} -o /dev/null -w '%{http_code}' "http://127.0.0.1:$EF_CLASH_PORT/ui/" 2>/dev/null)
        ui_kv_ascii "访问状态" "$([[ "$uic" == "200" ]] && echo "${GREEN}● 可访问${RESET}" || echo "${RED}✗ 不可访问 (code=${uic:-无响应})${RESET}")"
        if [[ -n "$sec" ]]; then
            echo
            printf "  ${YELLOW}注意${RESET}\n"
            printf "  Web UI 由 sing-box 的 Clash API 提供, 不是独立页面。\n"
            printf "  浏览器打开后需在设置里填入上面的“密钥”才能连接。\n"
        fi
    else
        ui_kv_ascii "状态" "${YELLOW}未启用 (配置中没有 external_ui)${RESET}"
        echo "  可在“客户端设置 → Web UI”中启用或重新下载。"
    fi
    echo
    printf "  ${CYAN}HTTP / SOCKS (mixed)${RESET}\n"
    ui_kv_ascii "地址" "http://$chost:$EF_MIXED_PORT   (监听 $EF_MIXED_LISTEN)"
    ui_kv_ascii "SOCKS5" "socks5://$chost:$EF_MIXED_PORT"
    ui_kv_ascii "本机地址" "http://127.0.0.1:$EF_MIXED_PORT"
    ui_kv_ascii "端口状态" "$(port_desc "$EF_MIXED_PORT")"
    echo
    printf "  ${CYAN}本机端口占用 (避让参考)${RESET}\n"
    ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -oE "[0-9]+$" | sort -un | tr '\n' ' '
    echo; echo
}

check_menu(){ # 配置检查
    collect_status
    ui_title "配置检查"
    if [[ "$ST_CONF" == "未初始化" ]]; then print_warn "$ST_REASON"; return 1; fi
    if [[ "$ST_CONF" == "正常" ]]; then
        print_ok "配置检查通过"
        ui_kv_ascii "配置目录" "$CLIENT_CONF"
        ui_kv_ascii "已加载文件" "$(ls -1 "$CLIENT_CONF"/*.json 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
        ui_kv_ascii "出站数量" "$(node_count)"
        echo
        printf "  ${CYAN}注意${RESET}: sing-box check 只校验配置语法, 不检测端口冲突。\n"
        printf "  端口是否被占用请用“客户端设置 → 端口占用检测”确认。\n"
        if [[ -n "$(find_sb_pid || true)" ]]; then
            echo
            read -r -p "  是否现在软重载应用? [y/N]: " a
            [[ "$(printf '%s' "$a" | tr 'A-Z' 'a-z')" == y* ]] && do_reload && print_ok "已重载"
        fi
        return 0
    else
        print_err "配置检查未通过:"
        printf '%s\n' "$ST_CONF_OUT" | tail -3 | sed 's/^/  /' >&2
        return 1
    fi
}
# CLI check: 返回真实 exit code (0=通过)
client_check_cli(){ collect_status; [[ "$ST_CONF" == "正常" ]] || { [[ -n "$ST_CONF_OUT" ]] && printf '%s\n' "$ST_CONF_OUT" >&2; return 1; }; print_ok "配置检查通过"; return 0; }

# ---------- 客户端设置 ----------
settings_menu(){
    while true; do
        load_effective
        ui_title "客户端设置"
        ui_kv_ascii "HTTP/SOCKS" "$EF_MIXED_LISTEN:$EF_MIXED_PORT  $(port_state_mark "$EF_MIXED_PORT")"
        ui_kv_ascii "Clash API" "$EF_CLASH_HOST:$EF_CLASH_PORT  $(port_state_mark "$EF_CLASH_PORT")"
        ui_kv_ascii "Web UI" "$([[ -n "$EF_UI" ]] && echo "启用 ($EF_CLASH_HOST:$EF_CLASH_PORT/ui/)" || echo '未启用')"
        echo
        ui_menu 1 "HTTP/SOCKS 端口"
        ui_menu 2 "Clash API 端口"
        ui_menu 3 "监听地址 (仅本机 / 局域网)"
        ui_menu 4 "Web UI"
        ui_menu 5 "查看当前配置文件"
        ui_menu 6 "端口占用检测"
        ui_menu 7 "查看/显示 Clash 密钥"
        ui_menu 0 "返回主菜单"
        ui_rule
        read -r -p "请输入选项 [0-7]: " c || return 0
        case "$c" in
            1) set_mixed_port ;;
            2) set_clash_port ;;
            3) set_bind ;;
            4) webui_menu ;;
            5) show_conf ;;
            6) port_check_menu ;;
            7) show_secret ;;
            0) return ;;
            *) print_err "无效选项 $c" ;;
        esac
        echo; read -r -p "按回车键返回设置菜单..." _ || return 0
    done
}
set_mixed_port(){
    load_effective
    echo; printf "  当前 HTTP/SOCKS 端口: %s (监听 %s)\n" "$EF_MIXED_PORT" "$EF_MIXED_LISTEN"
    printf "  说明: 这是本机代理入口端口, 浏览器/系统代理填这个。\n"
    read -r -p "  新端口 [回车取消]: " np || return 0
    [[ -z "$np" ]] && { print_warn "已取消"; return 0; }
    [[ "$np" =~ ^[0-9]+$ ]] && (( np >= 1 && np <= 65535 )) || { print_err "端口必须是 1-65535 的数字"; return 1; }
    (( np == EF_CLASH_PORT )) && { print_err "不能与 Clash API 端口 $np 相同 (sing-box 不支持两个监听共用一个端口)"; return 1; }
    local rc=0; port_state "$np" || rc=$?
    if (( rc == 2 )); then
        print_err "端口 $np 已被 ${PORT_NAME:-其它进程} (PID $PORT_WHO) 占用, 请换一个"
        return 1
    elif (( rc == 1 )); then
        print_warn "端口 $np 当前被本客户端占用 (PID $PORT_WHO), 改端口后需要重启服务"
    fi
    write_mixed_conf "$EF_MIXED_LISTEN" "$np"
    if ! cfg_check >/dev/null 2>&1; then
        print_err "写入后配置检查失败, 已回滚"
        write_mixed_conf "$EF_MIXED_LISTEN" "$EF_MIXED_PORT"; return 1
    fi
    print_ok "HTTP/SOCKS 端口: $EF_MIXED_PORT → $np  (已写入 $CLIENT_CONF/00-mixed.json)"
    PORT_MIXED="$np"
    apply_change "端口变更" || print_warn "服务尚未应用新端口, 启动后生效"
    do_status >/dev/null 2>&1
}
set_clash_port(){
    load_effective
    echo; printf "  当前 Clash API 端口: %s (监听 %s)\n" "$EF_CLASH_PORT" "$EF_CLASH_HOST"
    printf "  说明: Web UI 和 clash 订阅都走这个端口, 换端口后 URL 也要换。\n"
    read -r -p "  新端口 [回车取消]: " np || return 0
    [[ -z "$np" ]] && { print_warn "已取消"; return 0; }
    [[ "$np" =~ ^[0-9]+$ ]] && (( np >= 1 && np <= 65535 )) || { print_err "端口必须是 1-65535 的数字"; return 1; }
    (( np == EF_MIXED_PORT )) && { print_err "不能与 HTTP/SOCKS 端口 $np 相同 (sing-box 不支持两个监听共用一个端口)"; return 1; }
    local rc=0; port_state "$np" || rc=$?
    if (( rc == 2 )); then
        print_err "端口 $np 已被 ${PORT_NAME:-其它进程} (PID $PORT_WHO) 占用, 请换一个"
        return 1
    elif (( rc == 1 )); then
        print_warn "端口 $np 当前被本客户端占用 (PID $PORT_WHO), 改端口后需要重启服务"
    fi
    local sec=""; [[ -s "$CLASH_SECRET_FILE" ]] && sec=$(cat "$CLASH_SECRET_FILE")
    write_clash_conf "$EF_CLASH_HOST:$np" "$EF_UI" "$sec"
    if ! cfg_check >/dev/null 2>&1; then
        print_err "写入后配置检查失败, 已回滚"
        write_clash_conf "$EF_CLASH_HOST:$EF_CLASH_PORT" "$EF_UI" "$sec"; return 1
    fi
    print_ok "Clash API 端口: $EF_CLASH_PORT → $np  (已写入 $CLIENT_CONF/01-clash.json)"
    PORT_CLASH="$np"
    apply_change "端口变更" || print_warn "服务尚未应用新端口, 启动后生效"
    do_info >/dev/null 2>&1
}
set_bind(){
    load_effective
    echo
    printf "  当前监听: HTTP/SOCKS=%s   Clash API=%s\n" "$EF_MIXED_LISTEN" "$EF_CLASH_HOST"
    printf "  ${YELLOW}0.0.0.0${RESET} = 局域网其他设备也能用;  ${YELLOW}127.0.0.1${RESET} = 只有本机能用 (更安全)\n"
    printf "  Clash API 监听 0.0.0.0 时 sing-box 强制要求设置密钥。\n"
    read -r -p "  新监听地址 (0.0.0.0 / 127.0.0.1) [回车取消]: " nb || return 0
    [[ -z "$nb" ]] && { print_warn "已取消"; return 0; }
    case "$nb" in 0.0.0.0|127.0.0.1) ;; *) print_err "只支持 0.0.0.0 或 127.0.0.1"; return 1 ;; esac
    gen_clash_secret "$nb"
    local sec=""; [[ -s "$CLASH_SECRET_FILE" ]] && sec=$(cat "$CLASH_SECRET_FILE")
    write_mixed_conf "$nb" "$EF_MIXED_PORT"
    write_clash_conf "$nb:$EF_CLASH_PORT" "$EF_UI" "$sec"
    if ! cfg_check >/dev/null 2>&1; then
        print_err "配置检查失败, 已回滚"
        write_mixed_conf "$EF_MIXED_LISTEN" "$EF_MIXED_PORT"
        write_clash_conf "$EF_CLASH_HOST:$EF_CLASH_PORT" "$EF_UI" "$sec"; return 1
    fi
    print_ok "监听地址已改为 $nb (已写入配置)"
    BIND_LAN="$nb"; CLASH_LISTEN="$nb"
    # 监听地址属于启动期参数: 已在运行时 systemctl start 是空操作, 必须重启才会重新 bind
    if [[ -n "$(find_sb_pid || true)" ]]; then
        if do_restart; then sleep 1; print_ok "服务已重启, 新监听地址已生效"; else print_warn "重启失败, 请手动选择“9. 重启服务”"; return 1; fi
    else
        do_start || { print_warn "服务未启动, 启动后生效"; return 1; }
    fi
    do_status >/dev/null 2>&1
}
webui_menu(){
    load_effective
    while true; do
        ui_title "Web UI"
        ui_kv_ascii "状态" "$([[ -n "$EF_UI" ]] && echo "已启用 ($EF_UI)" || echo '未启用')"
        ui_kv_ascii "访问地址" "http://127.0.0.1:$EF_CLASH_PORT/ui/"
        ui_kv_ascii "目录内容" "$([[ -d "$CLIENT_UI" ]] && echo "$(find "$CLIENT_UI" -maxdepth 1 -type f 2>/dev/null | wc -l) 个文件" || echo '目录不存在')"
        echo
        ui_menu 1 "启用 Web UI"
        ui_menu 2 "停用 Web UI"
        ui_menu 3 "重新下载 (metacubexd)"
        ui_menu 0 "返回"
        ui_rule
        read -r -p "请输入选项 [0-3]: " c || return 0
        case "$c" in
            1)
                [[ -d "$CLIENT_UI" && -f "$CLIENT_UI/index.html" ]] || { print_err "$CLIENT_UI 下没有 index.html, 请先执行 3 重新下载"; continue; }
                local sec=""; [[ -s "$CLASH_SECRET_FILE" ]] && sec=$(cat "$CLASH_SECRET_FILE")
                write_clash_conf "$EF_CLASH_HOST:$EF_CLASH_PORT" "$CLIENT_UI" "$sec"
                cfg_check >/dev/null 2>&1 || { print_err "配置检查失败"; continue; }
                print_ok "已启用 Web UI"
                apply_change "Web UI 启用" || true
                ;;
            2)
                local sec2=""; [[ -s "$CLASH_SECRET_FILE" ]] && sec2=$(cat "$CLASH_SECRET_FILE")
                write_clash_conf "$EF_CLASH_HOST:$EF_CLASH_PORT" "" "$sec2"
                cfg_check >/dev/null 2>&1 || { print_err "配置检查失败"; continue; }
                print_ok "已停用 Web UI (external_ui 已移除)"
                apply_change "Web UI 停用" || true
                ;;
            3) download_ui && apply_change "Web UI 更新" || print_warn "更新后服务未自动重载" ;;
            0) return ;;
            *) print_err "无效选项 $c" ;;
        esac
        load_effective
    done
}
show_conf(){
    load_effective
    ui_title "当前配置文件"
    ui_kv_ascii "配置目录" "$CLIENT_CONF"
    echo
    for f in "$CLIENT_CONF"/*.json; do
        [[ -f "$f" ]] || continue
        printf "  ${CYAN}%s${RESET}\n" "$(basename "$f")"
        jq . "$f" 2>/dev/null | sed 's/^/    /' || { print_err "  (JSON 解析失败)"; head -5 "$f" | sed 's/^/    /'; }
        echo
    done
}
port_check_menu(){
    load_effective
    ui_title "端口占用检测"
    ui_kv_ascii "HTTP/SOCKS" "$EF_MIXED_PORT   $(port_state_mark "$EF_MIXED_PORT")   $(port_desc "$EF_MIXED_PORT")"
    ui_kv_ascii "Clash API" "$EF_CLASH_PORT   $(port_state_mark "$EF_CLASH_PORT")   $(port_desc "$EF_CLASH_PORT")"
    echo
    if [[ "$EF_MIXED_PORT" == "$EF_CLASH_PORT" ]]; then
        print_err "两个端口相同! sing-box 不支持 mixed 与 clash API 共用一个端口, 服务会启动失败"
    fi
    printf "  ${CYAN}提示${RESET}: sing-box check 不检测端口占用, 端口冲突只会在启动时暴露。\n"
    echo
    printf "  ${CYAN}本机已监听端口${RESET}: "
    ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -oE "[0-9]+$" | sort -un | tr '\n' ' '
    echo; echo
}
show_secret(){
    load_effective
    ui_title "Clash API 密钥"
    if [[ -s "$CLASH_SECRET_FILE" ]]; then
        ui_kv_ascii "密钥" "$(cat "$CLASH_SECRET_FILE")"
        ui_kv_ascii "文件" "$CLASH_SECRET_FILE"
        ui_kv_ascii "写入位置" "$CLIENT_CONF/01-clash.json (experimental.clash_api.secret)"
        echo
        printf "  Web UI 打开后填入这个密钥即可连接。\n"
    else
        ui_kv_ascii "状态" "未设置"
        echo
        printf "  监听 %s 时 sing-box 允许无密钥 (仅本机安全)。\n" "$EF_CLASH_HOST"
        printf "  若要开放给局域网, 请在“初始化基础配置”时让脚本自动生成密钥。\n"
    fi
    echo
}

download_ui() {
    print_msg "下载 metacubexd UI"
    local tmp; tmp=$(mktemp -d)
    curl -fsSL --max-time 240 "$UI_ZIP_URL" -o "$tmp/ui.zip" || { print_err "UI 下载失败"; rm -rf "$tmp"; return 1; }
    unzip -q -o "$tmp/ui.zip" -d "$tmp/x" || { print_err "UI 解包失败"; rm -rf "$tmp"; return 1; }
    rm -rf "$CLIENT_UI"; mkdir -p "$(dirname "$CLIENT_UI")"
    mv "$tmp/x/metacubexd-gh-pages" "$CLIENT_UI" || { print_err "UI 目录结构异常"; rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    print_ok "UI 已就绪: $CLIENT_UI (访问 http://127.0.0.1:${EF_CLASH_PORT:-$PORT_CLASH}/ui/ )"
}

# ---------- 交互面板 ----------
show_panel() {
    collect_status
    local ver n
    ver=$("$CLIENT_BIN" version 2>/dev/null | head -1 | awk '{print $3}')
    n=$(node_count)
    ui_clear
    ui_title "SB-Panel — Sing-box 客户端"
    case "$ST_SERVICE" in
        "运行中")   ui_kv "服务状态" "${GREEN}● 运行中${RESET} (PID $ST_PID)" ;;
        "未运行")   ui_kv "服务状态" "${YELLOW}○ 未运行${RESET}" ;;
        "启动失败") ui_kv "服务状态" "${RED}✗ 启动失败${RESET}" ;;
        "未初始化") ui_kv "服务状态" "${YELLOW}○ 未初始化${RESET}" ;;
        "未安装服务") ui_kv "服务状态" "${YELLOW}○ 未运行${RESET} (无 systemd 服务)" ;;
        *)          ui_kv "服务状态" "${RED}⚠ ${ST_SERVICE}${RESET}" ;;
    esac
    case "$ST_CONF" in
        正常) ui_kv "配置状态" "${GREEN}✓ 正常${RESET}" ;;
        异常) ui_kv "配置状态" "${RED}✗ 检查失败${RESET}" ;;
        *)    ui_kv "配置状态" "${YELLOW}⚠ $ST_CONF${RESET}" ;;
    esac
    ui_kv "内核版本" "${ver:-未安装}"
    ui_kv "节点数量" "$n"
    echo
    printf "  ${CYAN}本地代理${RESET}\n"
    ui_kv_ascii "HTTP/SOCKS" "$EF_MIXED_PORT   $(port_state_mark "$EF_MIXED_PORT")"
    ui_kv_ascii "Clash API" "$EF_CLASH_PORT   $(port_state_mark "$EF_CLASH_PORT")"
    if [[ "$ST_SERVICE" != "运行中" && -n "$ST_REASON" ]]; then
        echo; printf "  ${YELLOW}提示${RESET}: %s\n" "$ST_REASON"
        [[ "$ST_SERVICE" == "未运行" ]] && printf "         可选择 “7. 启动服务” 开始使用。\n"
        [[ "$ST_SERVICE" == "启动失败" ]] && printf "         建议先执行 “12. 配置检查”。\n"
        [[ "$ST_SERVICE" == "未初始化" ]] && printf "         请先执行 “2. 初始化基础配置”。\n"
    fi
    echo
    ui_rule
    ui_menu  1 "安装内核"
    ui_menu  2 "初始化基础配置"
    ui_menu  3 "添加节点 (share-url)"
    ui_menu  4 "删除节点"
    ui_menu  5 "列出节点"
    ui_menu  6 "更新节点 (重拉 share)"
    ui_menu  7 "启动服务"
    ui_menu  8 "停止服务"
    ui_menu  9 "重启服务"
    ui_menu 10 "查看运行状态"
    ui_menu 11 "Web UI / Clash API"
    ui_menu 12 "配置检查"
    ui_menu 13 "客户端设置 (端口 / Web UI / 占用检测)"
    ui_menu 14 "软重载配置 (零断流)"
    ui_menu 15 "卸载客户端 (停服务/删目录/删入口)"
    ui_menu  0 "退出"
    ui_rule
    read -r -p "请输入选项: " c || { ui_clear; exit 0; }
    case "$c" in
        1) do_install ;;
        2) do_init; do_status ;;
        3) read -r -p "  分享链接/URL: " u; add_node "$u" && apply_change "节点导入" ;;
        4) read -r -p "  要删除的节点名: " t; del_node "$t" && apply_change "节点删除" ;;
        5) regen_selector; local f; for f in "$CLIENT_NODE_DIR"/node-*.json; do
                [[ -f "$f" ]] || continue
                printf "  %-22s %s\n" "$(basename "$f" .json | sed 's/^node-//')" "$(jq -r '.outbounds[0].type // "?"' "$f" 2>/dev/null)"
           done; echo; print_msg "共 $(node_count) 个可用节点" ;;
        6) update_node && apply_change "节点更新" ;;
        7) do_start && sleep 1 ;;
        8) do_stop ;;
        9) do_restart && sleep 1 ;;
        10) do_status ;;
        11) do_info ;;
        12) check_menu ;;
        13) settings_menu ;;
        14) do_reload ;;
        15) do_uninstall ;;
        0) ui_clear; exit 0 ;;
        *) print_err "无效选项 $c" ;;
    esac
    echo; read -r -p "按回车键返回主菜单..." _ || true
}

# 无参数运行 → 面板; CLI 子命令照旧
if [[ $# -eq 0 ]]; then
    while true; do show_panel; done
fi

case "${1:-}" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    init) do_init ;;
    add) shift; add_node "$@" ;;
    list) regen_selector; for f in "$CLIENT_NODE_DIR"/node-*.json; do [[ -f "$f" ]] && echo "$(basename "$f" .json | sed 's/^node-//')"; done ;;
    del) shift; del_node "$@" ;;
    update) shift; update_node ;;
    check) client_check_cli ;;
    start) do_start ;;
    stop) do_stop ;;
    restart) do_restart ;;
    reload) do_reload ;;
    status) do_status ;;
    service) do_service_install ;;
    settings) settings_menu ;;
    install-ui) download_ui ;;
    info) do_info ;;
    *) echo "用法: client.sh {install|init|add <url>|list|del <tag>|update|start|stop|restart|reload|status|check|service|install-ui|info}"; exit 1 ;;
esac
