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

sb_proxy_show() {
    local f="$SB_PROXY_MODE_FILE" cur="auto"
    [[ -s "$f" ]] && cur=$(head -1 "$f" 2>/dev/null)
    printf '%s' "$cur"
}
sb_proxy_set_mode() { # $1 = auto|off|<url>
    mkdir -p "$(dirname "$SB_PROXY_MODE_FILE")" 2>/dev/null
    printf '%s' "$1" > "$SB_PROXY_MODE_FILE" 2>/dev/null || true
}

proxy_settings_menu() {
    while true; do
        local cur; cur=$(sb_proxy_show)
        local desc
        case "$cur" in
            off) desc="强制直连 (不使用任何代理)" ;;
            auto) desc="自动 (有环境变量就用, 否则探测本机端口)" ;;
            http*|socks5*) desc="固定使用 $cur" ;;
            *) desc="未知 ($cur)" ;;
        esac
        ui_title "下载通道"
        ui_kv_ascii "当前" "$desc"
        echo
        ui_menu 1 "自动 (环境变量 / 探测本机代理)"
        ui_menu 2 "强制直连 (不走任何代理)"
        ui_menu 3 "固定使用某个代理地址"
        ui_menu 4 "扫描本机可用代理端口"
        ui_menu 0 "返回"
        ui_rule
        read -r -p "请输入选项 [0-4]: " c || return 0
        case "$c" in
            1) sb_proxy_set_mode auto;   print_ok "已设为: 自动" ;;
            2) sb_proxy_set_mode off;    print_ok "已设为: 强制直连" ;;
            3)
                read -r -p "  代理地址 (如 http://127.0.0.1:7890, 留空=取消): " a || return 0
                a="${a// /}"
                if [[ -z "$a" ]]; then print_msg "已取消"; continue; fi
                if [[ "$a" != http://* && "$a" != https://* && "$a" != socks5://* && "$a" != socks5h://* ]]; then
                    print_err "需要以 http:// / https:// / socks5:// 开头"; continue
                fi
                sb_proxy_set_mode "$a"; print_ok "已设为: $a" ;;
            4)
                sb_proxy_scan
                if (( ${#SB_PROXY_CANDS[@]} == 0 )); then
                    print_warn "本机未发现可用代理端口"
                else
                    print_msg "发现 ${#SB_PROXY_CANDS[@]} 个:"
                    local i
                    for i in "${!SB_PROXY_CANDS[@]}"; do
                        printf "  %d) %s\n" "$((i+1))" "${SB_PROXY_CANDS[$i]}" >&2
                    done
                fi ;;
            0) return ;;
            *) print_err "无效选项 $c" ;;
        esac
    done
}

sb_pick_proxy() { # 让用户选下载通道; 默认直连。$1 = 用途说明(给提示文案用)
    # 已显式配置: 不打扰
    # 用户在「客户端设置 → 下载通道」里选过的模式优先于一切。
    # 之前只看环境变量, 结果机器上一个历史遗留的 http_proxy 就把整个面板
    # 的下载都带上了代理, 用户既不知道也没地方关 —— 现在有地方改了。
    local pmode; pmode=$(sb_proxy_show)
    case "$pmode" in
        off)
            unset http_proxy https_proxy all_proxy 2>/dev/null || true
            print_msg "下载通道: 强制直连 (按设置)"
            return 0 ;;
        http://*|https://*|socks5://*|socks5h://*)
            sb_proxy_apply "$pmode"
            print_msg "下载通道: $pmode (按设置)"
            return 0 ;;
    esac
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
# 订阅注册表: 记录每个订阅的 来源URL / 前缀 / 节点数, 供"订阅管理"页用。
# 以前只有节点级的 node-<tag>.txt 记着来源 URL, 没有"这是一条订阅"的概念,
# 所以既列不出订阅、也没法只更新某一条 —— update_node 只能把所有来源挨个
# 重拉一遍, 用户根本不知道自己在更新什么。
SUBS_FILE="${SUBS_FILE:-$CLIENT_ROOT/subscriptions.json}"
# 订阅格式转换器 (install.sh 随 client.sh 一起复制过来)
SB_TO_SB="${SB_TO_SB:-$CLIENT_ROOT/share-state/to_sb.py}"

# 下载通道选择 (auto / off / 代理地址)。
# 必须放在 CLIENT_ROOT 之后 —— 之前它写在前面, set -u 下引用未定义的
# CLIENT_ROOT 直接让整个面板起不来 (line 121: unbound variable)。
SB_PROXY_MODE_FILE="${SB_PROXY_MODE_FILE:-$CLIENT_ROOT/share-state/proxy-mode}"

# ---------- DNS (防泄露) ----------
# 目标: 客户端所有域名解析都走代理, 不给"明文 53 走直连"留口子。
# sing-box 侧的防泄露由三层构成, 缺一层就有泄露面:
#   1. dns.servers 全部是 DoH (HTTPS, 本身走代理) —— 没有明文 53
#   2. route 规则 hijack 掉所有 protocol=dns 与 port=53 的流量,
#      强制它们进 sing-box 内置 DNS, 应用自己发的 53 也拦得住
#   3. 拒绝 QUIC (udp/443), 避免应用用 DoQ/QUIC 绕开我们指定的解析器
# 默认两条 DoH: 国内阿里 (走代理快) + Cloudflare (兜底, 走代理)。
DNS_ENABLED="${DNS_ENABLED:-1}"
DNS_MAIN="${DNS_MAIN:-223.5.5.5}"          # 阿里 DoH, IP 直连避免引导解析
DNS_MAIN_HOST="${DNS_MAIN_HOST:-dns.alidns.com}"
DNS_FALLBACK="${DNS_FALLBACK:-1.1.1.1}"   # Cloudflare DoH
DNS_FALLBACK_HOST="${DNS_FALLBACK_HOST:-cloudflare-dns.com}"
DNS_STRATEGY="${DNS_STRATEGY:-ipv4_only}" # 防 IPv6 泄露: 只解析 A 记录
UI_ZIP_URL="${UI_ZIP_URL:-https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip}"
SB_UNIT_NAME="sb-client"        # 常驻 unit
SB_UNIT_ADHOC="sb-client-adhoc" # 临时 unit (仅当未安装常驻 unit 时)

# ---------- 颜色 / 输出 ----------
# 颜色变量允许被环境覆盖, 但覆盖值可能写成 '\e[31m' 这种字面量,
# 这里统一用 printf %b 归一化成真正的 ESC 字节, 否则作为 printf 参数传入时会原样打印
_c(){ printf '%b' "$1"; }
RED="$(_c "${RED:-\e[31m}")"; GREEN="$(_c "${GREEN:-\e[32m}")"; YELLOW="$(_c "${YELLOW:-\e[33m}")"
CYAN="$(_c "${CYAN:-\e[96m}")"; RESET="$(_c "${RESET:-\e[0m]}")"
# 暗色 (分组小标题用)。服务端 lib.sh 有 DIM, 客户端此前没有, 菜单分组一加
# 分组一加就撞上 DIM: unbound variable —— set -u 下菜单直接不显示。
# 用单引号把转义序列原样交给 _c 去 printf %b 还原; 写成双引号时 ${...:-...}
# 的默认值会在参数展开阶段被当成 glob, 把这一行截断。
DIM="$(_c "${DIM:-\e[2m}")"; BOLD="$(_c "${BOLD:-\e[1m]}")"
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
        # 必须排除被别的 outbound 用 detour 引用的辅助层 (如 shadowtls 的
        # "<tag>-out"): 那不是独立节点, 用户在界面里也选不到它。
        # 以前只排除了 selector/urltest/direct, 辅助层被算进去了 ——
        # 实测 43 个节点的文件, 面板报 44 个可用节点, 一直差这一个。
        n=$(jq '(.outbounds | map(select(.detour != null) | .detour)) as $dep
               | [.outbounds[]?
                  | select(.type!="selector" and .type!="urltest" and .type!="direct")
                  | select((.tag as $t | $dep | index($t)) == null)] | length'\
             "$f" 2>/dev/null) || n=0
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
# ---------- DNS 配置 (防泄露) ----------
# 单独一个片段 02-dns.json, 便于单独改/删; 服务端用 -C 目录合并加载。
write_dns_conf() {
    if [[ "$DNS_ENABLED" != "1" ]]; then
        rm -f "$CLIENT_CONF/02-dns.json"
        print_warn "DNS 防泄露已关闭 (DNS_ENABLED=0), 域名会走直连解析"
        return 0
    fi
    # DoH 一律用 **IP + tls.server_name** 而不是域名:
    #   用域名的话, 为了拿到 dns.alidns.com 的 IP, 内核还得先做一次解析 ——
    #   那一次就是泄露点 (走直连 UDP/53 或系统解析器)。
    #   写 IP + server_name 则 TLS 校验照常 (SNI 对), 但不需要引导解析。
    cat > "$CLIENT_CONF/02-dns.json" <<EOF
{
  "dns": {
    "servers": [
      {
        "type": "https",
        "tag": "doh-main",
        "server": "$DNS_MAIN",
        "server_port": 443,
        "path": "/dns-query",
        "tls": { "enabled": true, "server_name": "$DNS_MAIN_HOST" }
      },
      {
        "type": "https",
        "tag": "doh-fallback",
        "server": "$DNS_FALLBACK",
        "server_port": 443,
        "path": "/dns-query",
        "tls": { "enabled": true, "server_name": "$DNS_FALLBACK_HOST" }
      }
    ],
    "final": "doh-fallback",
    "strategy": "$DNS_STRATEGY"
  },
  "experimental": {
    "cache_file": { "enabled": true, "store_fakeip": false }
  }
}
EOF
    print_ok "DNS 防泄露已写入: DoH $DNS_MAIN (主) / $DNS_FALLBACK (兜底), 劫持 53 与 DoQ"
}

do_init() {
    mkdir -p "$CLIENT_CONF" "$CLIENT_NODE_DIR" "$CLIENT_ROOT/share-state" "$CLIENT_UI"
    gen_clash_secret "$CLASH_LISTEN"
    local secret=""; [[ -s "$CLASH_SECRET_FILE" ]] && secret=$(cat "$CLASH_SECRET_FILE")
    write_mixed_conf "$BIND_LAN" "$PORT_MIXED"
    write_clash_conf "$CLASH_LISTEN:$PORT_CLASH" "$CLIENT_UI" "$secret"
    write_dns_conf
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
    python3 - "$CLIENT_ROOT/nodes" "$CLIENT_CONF/90-outbounds.json" "$SUBS_FILE" <<'PYGEN'
import json,sys,glob,os
ndir,ofile=sys.argv[1],sys.argv[2]
subfile=sys.argv[3] if len(sys.argv)>3 else ""
obs=[]
# 按 tag 去重: 同名 outbound 出现两次, 内核会直接拒绝启动
# ("duplicate outbound/endpoint tag"), 表现为配置检查 FATAL 而查不出原因。
seen=set()
for f in sorted(glob.glob(os.path.join(ndir,"node-*.json"))):
    j=json.load(open(f))
    for o in j.get("outbounds",[]):
        if o.get("tag") in seen: continue
        seen.add(o.get("tag")); obs.append(o)
htags=set(o["detour"] for o in obs if o.get("detour"))
tags=[o["tag"] for o in obs if o.get("type")!="direct" and o["tag"] not in htags]
tags=tags or [o["tag"] for o in obs]

# ---- 按订阅分组 ----
# 节点一多 (自家 + 好几条外部订阅, 轻松 60+), PROXY 里平铺着选起来很痛苦。
# 现在一条订阅一个组: PROXY 只放组, 组里才是那条订阅的节点。
# sing-box 的 selector 允许嵌套 (PROXY -> 组 -> 节点), 实测内核 check 通过。
subs=[]
if subfile:
    try: subs=json.load(open(subfile)).get("subs",[])
    except Exception: subs=[]
groups=[]; matched=set()
for sb in subs:
    pre=(sb.get("prefix") or "").strip()
    if not pre: continue
    gt=[t for t in tags if t.startswith(pre+"-")]
    if not gt: continue
    groups.append([sb.get("name") or pre, gt, False]); matched.update(gt)
rest=[t for t in tags if t not in matched]
if rest: groups.append(["其它", rest, True])  # 末尾 True = 不是订阅组, 只是收容

def gtag(name):
    # 组 tag 必须是唯一且不与节点 tag 撞; 去掉非 ASCII 字符 (国旗等)
    t="".join(c for c in name if c.isalnum() or c in "-_.") or "grp"
    if t in seen or t in tags: t="G-"+t
    seen.add(t); return t

# 只要**有**订阅记录就建组, 跟订阅是一条还是多条无关。
# 之前写的是 len(groups)>1 才分组, 理由是"只有一组时 PROXY 里就剩一项, 纯属
# 多绕一层"。这个判断是错的: 用户删光订阅再重加一条, 就掉进平铺分支, 界面上
# 看不到任何组 —— 报的原话是"我没有看见我这个新订阅的组"。
# 多绕一层的代价是点一下才能进组; 少一层的代价是整条需求消失。取舍很清楚。
#
# 真正该平铺的只有一种情况: **一条订阅都没登记** —— 此时所有节点都是手动加的
# (简易 HTTP/SOCKS 之类), 本来就没有"订阅"这个概念可分组。
# 有**真正的订阅**才建组。「其它」是收容组, 不算订阅。
use_groups = any(not g[2] for g in groups)
if use_groups:
    gsel=[]
    for name,gt,_isother in groups:
        g=gtag(name)
        gsel.append({"type":"selector","tag":g,"outbounds":gt,"default":gt[0]})
    proxy_items=[g["tag"] for g in gsel]
    auto_items=tags
else:
    gsel=[]; proxy_items=tags; auto_items=tags

if not tags:
    cfg={"outbounds":[]}
else:
    cfg={"outbounds":obs+gsel+[
       {"type":"selector","tag":"PROXY","outbounds":proxy_items,"default":proxy_items[0]},
       {"type":"urltest","tag":"AUTO","outbounds":auto_items,"url":"https://www.gstatic.com/generate_204","interval":"3m"}],
       # route 只写 final —— rules 全部由 02-dns.json 提供。
       # sing-box -C 合并时同名字段后者覆盖前者, 这里若也写 rules,
       # 加载顺序一变就会把防泄露规则冲掉。
       # route 里除了 final 还要给 default_domain_resolver, 指向 02-dns.json
       # 里定义的 "doh-main"。两个坑都踩过:
       #   1. 位置是 route.default_domain_resolver —— 放顶层或 dns 里都报
       #      unknown field;
       #   2. 它只接受**引用 dns.servers 里的 tag**, 不能内联一份完整解析器 ——
       #      内联会报 "default domain resolver not found: 223.5.5.5"。
       # 防泄露规则与 final/resolver 必须写在**同一个** route 对象里:
       # sing-box -C 合并是按顶层键覆盖的, 分两个片段各写 route, 后加载的
       # 会把前一个的 rules 整个冲掉 (实测: rules 变成 0 条, 劫持全失效)。
       # 加载顺序还会随文件名变动, 所以不能靠"放前面"解决。
       "route":{"final":"PROXY",
                "default_domain_resolver":{"server":"doh-main"},
                "auto_detect_interface":True,
                "rules":[
                  {"ip_is_private":True,"outbound":"direct"},
                  {"protocol":"dns","action":"hijack-dns"},
                  {"port":53,"action":"hijack-dns"},
                  {"port":[135,137,138,139,5353],"action":"reject"},
                  {"network":"udp","port":443,"action":"reject"}
                ]}}
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
        do_reload && { print_ok "$what 已生效 (已重启)"; return 0; }
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
        # 自家 share 也要登记进订阅表。
        # 以前只有走"格式转换"那条路的外部订阅才登记, 而自家 share 返回的
        # 本来就是 sing-box JSON, 内核直接认 -> 压根不进那个分支 -> 永远
        # 没被登记。后果是「一个订阅一个组」做出来, 自家那 16 个节点会跟
        # 手动加的一起掉进「其它」组里, 分组等于没分。
        PENDING_SUB_URL="$src"
    else
        cp "$src" "$tmp" || { rm -f "$tmp"; print_err "无法读取 $src"; return 1; }
        export IF_SOURCE="$src"
    fi
    # ---- 格式识别 ----
    # 自家 share 返回的就是 sing-box JSON, 内核直接认; 别人的订阅五花八门
    # (base64 包着的 vless://、mihomo YAML ...), 得先转一道。
    # 不转直接喂内核必然失败, 而报的是 "decode config" —— 用户完全看不出
    # 自己拉到的其实是另一种格式。
    if ! "$CLIENT_BIN" check -c "$tmp" >/dev/null 2>&1 && ! "$CLIENT_BIN" check "$tmp" >/dev/null 2>&1; then
        if [[ ! -s "$SB_TO_SB" ]]; then
            rm -f "$tmp"
            print_err "缺少格式转换器 $SB_TO_SB (重新执行安装脚本即可补上)"
            return 1
        fi
        command -v python3 >/dev/null 2>&1 || {
            rm -f "$tmp"; print_err "导入外部订阅需要 python3"; return 1; }

        # 外部订阅一律加前缀。它内部的节点名多半是裸的 (anytls01-TLS 这种),
        # 不加前缀就会和我们自己的节点重名 —— 而重名的后果是静默覆盖旧的、
        # 面板还报 [OK] 已导入。用户可以自己指定, 回车用猜出来的。
        local prefix="" sp
        if [[ "$src" =~ ^https?:// ]]; then
            local guess; guess=$(subs_guess_prefix "$src")
            if [[ -n "${SB_SUBS_PREFIX:-}" ]]; then
                sp="$SB_SUBS_PREFIX"
            else
                read -r -p "  这条订阅的节点名前缀 (默认 $guess): " sp || { echo; rm -f "$tmp"; return 1; }
                sp="${sp// /}"
                [[ -z "$sp" ]] && sp="$guess"
            fi
            sp=$(printf '%s' "$sp" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^-*//;s/-*$//' | cut -c1-24)
            [[ -n "$sp" ]] || sp="$guess"
            prefix="$sp"
        fi

        local conv="$CLIENT_ROOT/share-state/.conv.json" cerr="$CLIENT_ROOT/share-state/.conv.err"
        # 用数组传参, 别用 ${prefix:+--prefix "$prefix"} —— 那种写法不加引号,
        # 会被分词成多个参数, 前缀里有空格就彻底错位。
        local cargs=("$tmp")
        [[ -n "$prefix" ]] && cargs+=(--prefix "$prefix")
        python3 "$SB_TO_SB" "${cargs[@]}" > "$conv" 2>"$cerr"
        local rep; rep=$(cat "$cerr" 2>/dev/null)
        if [[ ! -s "$conv" ]] || [[ "$(jq '.outbounds|length' "$conv" 2>/dev/null || echo 0)" == "0" ]]; then
            rm -f "$tmp"; print_err "无法识别的订阅格式"
            [[ -n "$rep" ]] && print_msg "${rep}"
            return 1
        fi
        local fmt cnt
        fmt=$(printf '%s' "$rep" | sed -n 's/.*格式=\([^ ]*\).*/\1/p')
        cnt=$(jq '.outbounds|length' "$conv" 2>/dev/null || echo 0)
        print_ok "识别为 ${fmt:-未知} 格式, 转换出 $cnt 个节点"
        mv -f "$conv" "$tmp"

        # 登记订阅, 供「订阅管理」页列出/更新
        if [[ -n "$prefix" && "$src" =~ ^https?:// ]]; then
            local sid; sid=$(subs_id "$src")
            subs_put "$(jq -n --arg id "$sid" --arg url "$src" --arg pre "$prefix" \
                --arg nm "$prefix" --argjson n "$cnt" --arg ts "$(date -Is)" \
                '{id:$id,name:$nm,prefix:$pre,url:$url,kind:"external",nodes:$n,added_at:$ts}')"
            print_msg "已登记订阅「$prefix」($cnt 个节点), 可在「订阅管理」里更新"
        fi
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

    # 自家 share 的登记补在这里 (外部订阅在转换分支里已经登记过了)。
    # 前缀从**刚落盘的节点名**里取 —— 单节点/多节点两条路径落盘后
    # 第一个 tag 都带同一个服务端前缀, 这里用它反过来建订阅记录。
    if [[ -n "${PENDING_SUB_URL:-}" ]]; then
        local _sid _pre
        _pre=$(list_nodes 2>/dev/null | awk -F'\t' '{print $1}' | sort | head -1)
        _pre="${_pre%%-[^-]*}"
        if [[ -n "$_pre" ]]; then
            _sid=$(subs_id "$PENDING_SUB_URL")
            [[ -n "$(subs_get "$_sid")" ]] || \
                subs_register "$PENDING_SUB_URL" self "$_pre"
        fi
        unset PENDING_SUB_URL
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

# ---------- 订阅管理 ----------
# 列出所有登记过的订阅, 支持 更新 / 删除。
# 节点是"订阅"的产物: 更新订阅 = 重拉 + 重建该订阅名下的节点;
# 删除订阅 = 同样删掉它带的节点 (否则会留下指向已删订阅的孤儿节点)。
subs_menu() {
    while true; do
        local n; n=$(subs_count)
        if [[ "$n" == "0" ]]; then
            print_warn "还没有登记任何订阅"
            print_msg "用菜单「添加节点」导入一个订阅 URL 就会出现在这里"
            return 0
        fi
        echo
        printf "  ${CYAN}%4s  %-22s %-10s %-8s %s${RESET}\n" "序号" "名称(前缀)" "节点数" "分组" "来源"
        printf "  %s\n" "──────────────────────────────────────────────────────────────────"
        local i=1 id nm pre cnt url
        while IFS=$'\t' read -r id nm pre cnt url; do
            printf "  %4d  %-22s %-10s %-8s %s\n" "$i" "$nm" "$cnt" "已登记" \
                "$(printf '%s' "$url" | cut -c1-30)"
            i=$((i+1))
        done < <(jq -r '.subs[]?|[.id,.name,.prefix,(.nodes|tostring),.url]|@tsv' "$SUBS_FILE" 2>/dev/null)
        echo
        echo
        # 两段式, **两套互不影响的数字编号**:
        #
        #   第一步  订阅编号 1..N  —— 选哪一条订阅
        #   第二步  操作编号 1..5  —— 对它做什么 (编号固定)
        #
        # 以前是把操作项接在订阅数后面 (N+1/N+2/...), 删掉一个订阅就整体
        # 往前挪一位: 记熟的"6 = 只删节点"变成 5, 按记忆操作会删错东西。
        # 用户报的原话是"上面的列表和下面的菜单共用一个序列"。
        # 拆成两段后, 订阅增减完全不影响操作编号。
        #
        # 第二步支持直接回车 = 1 (更新), 这是最常用的操作, 不用多按一次。
        local nsub="$n" sel sid act nm
        read -r -p "  请输入订阅编号 [1-$nsub], 0 返回: " sel || { echo; return 0; }
        sel="${sel// /}"
        [[ -z "$sel" || "$sel" == "0" ]] && return 0
        if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > nsub )); then
            print_err "请输入 1-$nsub 之间的编号"; continue
        fi
        sid=$(jq -r --argjson i "$sel" '(.subs//[])[$i-1].id // empty' "$SUBS_FILE" 2>/dev/null)
        [[ -n "$sid" ]] || { print_err "没有编号 $sel"; continue; }
        nm=$(jq -r --argjson i "$sel" '(.subs//[])[$i-1].name // empty' "$SUBS_FILE" 2>/dev/null)

        echo
        printf "  ${CYAN}已选订阅 %d: %s${RESET}\n" "$sel" "$nm"
        printf "   ${CYAN}1)${RESET} 更新这条订阅\n"
        printf "   ${CYAN}2)${RESET} ${CYAN}只删这条的节点${RESET} ${DIM}(保留订阅, 之后可更新拉回)${RESET}\n"
        printf "   ${YELLOW}3)${RESET} ${YELLOW}删除这条订阅${RESET} ${DIM}(连记录和 URL 一起删)${RESET}\n"
        printf "   ${CYAN}4)${RESET} 更新全部订阅\n"
        printf "   ${CYAN}5)${RESET} 补登记未登记的节点组\n"
        printf "   ${RED}0)${RESET} 返回\n"
        local act; read -r -p "  请选择 [1-5, 直接回车=更新, 0 返回]: " act || { echo; continue; }
        act="${act// /}"
        [[ -z "$act" ]] && act=1
        [[ "$act" == "0" ]] && continue
        case "$act" in
            1) sub_update_one "$sid" && regen_selector && apply_change "订阅已更新" ;;
            2)
                # 只删节点, 订阅记录留着 —— 服务器重置 / 订阅过期时用,
                # 之后还能"更新"重新拉回来。
                sub_delete_nodes "$sid" && apply_change "节点已删除" ;;
            3) sub_delete_one "$sid" && apply_change "订阅已删除" ;;
            4) sub_update_all ;;
            5) sub_backfill ;;
            *) print_err "请输入 0-5" ;;
        esac
    done
}

sub_update_one() {
    local sid="$1" url pre nm
    url=$(subs_get "$sid" | jq -r '.url // empty')
    [[ -n "$url" ]] || { print_err "订阅记录异常 (无 URL)"; return 1; }
    pre=$(subs_get "$sid" | jq -r '.prefix // empty')
    nm=$(subs_get "$sid" | jq -r '.name // empty')
    print_msg "更新订阅「$nm」..."
    # 该订阅带的节点先删掉, 否则改名后的节点会变成孤儿。
    local t
    for t in $(grep -lF "${pre}-" "$CLIENT_NODE_DIR"/node-*.json 2>/dev/null); do
        rm -f "${t%.json}".*
    done
    # 必须用 export 而不是 `VAR=x func` 前置赋值: bash 里那种写法只在函数
    # 执行期间让该变量临时可见, 但 add_node 内部再调的其它函数看不到它,
    # 会退回"询问前缀"分支 —— 更新订阅时又弹一次前缀输入, 前缀就丢了。
    export SB_SUBS_PREFIX="$pre"
    add_node "$url"
}

sub_update_all() {
    local id n=0 bad=0
    while read -r id; do
        [[ -n "$id" ]] || continue
        sub_update_one "$id" && n=$((n+1)) || bad=$((bad+1))
    done < <(jq -r '.subs[]?.id' "$SUBS_FILE" 2>/dev/null)
    if (( n > 0 )); then print_ok "已更新 $n 条订阅"; fi
    if (( bad > 0 )); then print_warn "$bad 条订阅更新失败 (链接可能已过期/用尽)"; fi
    (( n > 0 )) && { regen_selector; apply_change "订阅已更新"; }
}

# 补登记: 把**已经存在但没登记**的节点按前缀分组建成订阅条目。
# 为什么需要: 自家 share 早于"订阅登记"这个功能导入, 那批节点从来没进过
# subscriptions.json。分组靠前缀匹配, 它们匹配不到任何订阅 -> 全掉进「其它」,
# "一个订阅一个组"就等于没分。这个动作把存量补齐, 不用重装。
# URL 留空 —— 补出来的条目只知道节点从哪来, 不知道订阅地址, 所以不能"更新",
# 但"只删节点"可用。要能更新的话重新导入一次那个分享链接即可。
sub_backfill() {
    local -a names=() pres=()
    # 用 mapfile 直接读整个输出, 不要 while read 配多个字段 ——
    # list_nodes 只取第 1 列时 read 的占位字段行为不可靠, 实测整轮读成空,
    # 结果明明有 59 个节点却报"还没有节点"。
    mapfile -t names < <(list_nodes 2>/dev/null | cut -f1)
    # 去掉可能的空行
    local -a clean=()
    local x
    for x in "${names[@]}"; do [[ -n "$x" ]] && clean+=("$x"); done
    names=("${clean[@]}")
    (( ${#names[@]} == 0 )) && { print_warn "还没有节点"; return 0; }
    # 前缀树聚类。
    # 简单砍尾不行: rn-anytls01-TLS -> rn-anytls01, 而 rn-anytls02-REALITY
    # -> rn-anytls02, 同一个订阅的节点被切得七零八落 (踩过)。
    # 正确做法: 按 '-' 分段, 逐层往下, 只有当"整组节点都在这一层之下"时才
    # 继续细分; 某个节点名在这里到头或与同组不一致, 就停在上一层。
    local -a pres=()
    mapfile -t pres < <(printf '%s\n' "${names[@]}" | python3 -c '
import sys
from collections import defaultdict
names=[l.rstrip("\n") for l in sys.stdin if l.strip()]
groups=defaultdict(list)
for n in names:
    parts=n.split("-")
    # 先按第 0 段粗分 (没有 - 的单独成组)
    groups["-".join(parts[:1])].append(n)
out=[]
for head, mem in groups.items():
    if len(mem)<2: continue
    depth=1                      # 已确认的段数 (含第 0 段)
    segs=len(head.split("-"))
    while True:
        if all(len(m.split("-"))>segs for m in mem):
            nxt=set(m.split("-")[segs] for m in mem)
            if len(nxt)<2: break # 这一层开始就分叉了, 停在这
            segs+=1
        else:
            break
    out.append("-".join(head.split("-")[:segs]))
print("\n".join(out))
')
    local added=0 p cnt grp
    for p in "${pres[@]}"; do
        [[ -n "$p" ]] || continue
        # 已有同名订阅就跳过
        jq -e --arg p "$p" '(.subs//[])|any(.prefix==$p)' "$SUBS_FILE" >/dev/null 2>&1 && continue
        cnt=0
        for t in "${names[@]}"; do [[ "$t" == "$p"-* ]] && cnt=$((cnt+1)); done
        (( cnt == 0 )) && continue
        grp="$p"
        jq -e --arg g "$grp" '(.subs//[])|any(.name==$g)' "$SUBS_FILE" >/dev/null 2>&1 && grp="${grp}-2"
        subs_put "$(jq -n --arg id "local-$(printf '%s' "$p" | md5sum | cut -c1-10)" \
            --arg url "" --arg pre "$p" --arg nm "$grp" --argjson n "$cnt" \
            --arg ts "$(date -Is)" \
            '{id:$id,name:$nm,prefix:$pre,url:"",kind:"local",nodes:$n,added_at:$ts}')"
        print_ok "已登记「$grp」($cnt 个节点)"
        added=$((added+1))
    done
    (( added > 0 )) || { print_msg "没有需要补登记的 (都已有订阅记录)"; return 0; }
    # 必须 apply_change (重启), 不能只 regen_selector。
    # regen_selector 只重写 90-outbounds.json, 运行中的内核还拿着旧配置 ——
    # 配置文件里 PROXY 已经是 3 个组了, 但 Clash API (Web UI 读的就是它)
    # 仍然返回旧的 ["mysub","其它"], 自家那 29 个节点在界面里全落在「其它」。
    # 这个坑踩过: 提示写着"已重建 PROXY", 实际界面没变。
    regen_selector && apply_change "分组已重建"
}

# 只删节点, **保留订阅记录**。
# 和 sub_delete_one 的区别: 那���个连 URL 一起删, 用户想再拉回来就得重新
# 把订阅地址输一遍。这个保留 subscriptions.json 里那条, 之后在同一个菜单
# 点"更新"就能重拉 —— 服务器重置、订阅过期两种场景都是这个需求。
sub_delete_nodes() {
    local sid="$1" pre t n=0
    pre=$(subs_get "$sid" | jq -r '.prefix // empty')
    [[ -n "$pre" ]] || { print_err "订阅记录异常 (无前缀)"; return 1; }
    for t in "$CLIENT_NODE_DIR"/node-"$pre"-*; do
        [[ -f "$t" ]] && { rm -f "${t%.json}".*; n=$((n+1)); }
    done
    if (( n == 0 )); then
        print_warn "订阅「$pre」当前没有节点 (可能已被删除)"
        return 0
    fi
    print_warn "已删除订阅「$pre」的 $n 个节点; 订阅记录保留, 可随时「更新」重新拉取"
    regen_selector
    print_ok "现 $(node_count) 个可用节点"
}

sub_delete_one() {
    local sid="$1" pre t
    pre=$(subs_get "$sid" | jq -r '.prefix // empty')
    print_warn "删除订阅「$pre」并同时删除它带的节点 (订阅记录和 URL 也会消失)"
    local w
    read -r -p "  确认? 输入 yes, 其它任何输入=取消: " w
    [[ "$w" == "yes" ]] || { print_msg "已取消"; return 0; }
    for t in "$CLIENT_NODE_DIR"/node-"$pre"-*; do
        [[ -f "$t" ]] && rm -f "${t%.json}".*
    done
    subs_del "$sid"
    regen_selector
    print_ok "已删除订阅「$pre」, 现 $(node_count) 个可用节点"
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

# ---------- 简易 HTTP / SOCKS 节点 ----------
# 用途: 这台客户端机器上可能还跑着别的内核 (mihomo / sing-box / v2ray ...),
# 想让本客户端把它们当成**出站**用 —— 在 PROXY 选择器里多一个选项, 选它就走
# 那个 socks/http 端口出去。
# 注意这是 outbound (客户端主动连出去), 不是在本机开一个 socks 端口给别人连
# (那是 mixed-port 的事, 见 write_mixed_conf)。两者方向相反, 别混。
add_local_proxy() {
    local t addr port user pass tag defport
    echo
    printf "  ${CYAN}1)${RESET} socks5   ${DIM}(另一个内核的本地 SOCKS 端口)${RESET}\n"
    printf "  ${CYAN}2)${RESET} http     ${DIM}(另一个内核的本地 HTTP 端口)${RESET}\n"
    printf "  ${CYAN}0)${RESET} 取消\n"
    local c
    read -r -p "  节点类型 [1-2, 回车=1]: " c || { echo; return 0; }
    c="${c// /}"
    case "$c" in
        2) t="http";     defport=7890 ;;
        0) return 0 ;;
        *) t="socks";    defport=1080 ;;
    esac

    # 默认 127.0.0.1: 这个面板跑在客户端机器上, 最常见的用法就是链本机上另一个
    # 内核, 回环地址省一次输入; 要接别的机器直接输入 IP/域名即可。
    read -r -p "  目标地址 (默认 127.0.0.1): " addr || { echo; return 0; }
    addr="${addr// /}"
    [[ -z "$addr" ]] && addr="127.0.0.1"

    read -r -p "  目标端口 (默认 $defport): " port || { echo; return 0; }
    port="${port// /}"
    [[ -z "$port" ]] && port="$defport"
    # 实测 sing-box check 放行 server_port:0 —— 语法合法但运行时才炸,
    # 这种错留到内核才报最难查, 这里直接拦。
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        print_err "端口必须是 1-65535 的整数"; return 1
    fi

    # 用户名/密码: 很多本地代理开着认证, 这两项必须能填。
    # 留空 = 不认证, 就不写进配置 (username/password 是 sing-box 的可选字段)。
    read -r -p "  用户名 (留空=不认证): " user || { echo; return 0; }
    user="${user// /}"
    read -r -p "  密码 (留空=不认证): " pass || { echo; return 0; }
    pass="${pass// /}"
    if [[ -n "$pass" && -z "$user" ]]; then
        print_warn "只填了密码没填用户名, 按不认证处理"
        pass=""
    fi

    local defname="SOCKS5"; [[ "$t" == "http" ]] && defname="HTTP"
    read -r -p "  节点名 (默认 ${defname}-${addr}-${port}): " tag || { echo; return 0; }
    tag="${tag// /}"
    [[ -z "$tag" ]] && tag="${defname}-${addr}-${port}"
    # tag 会进文件名 node-<tag>.json, 去掉路径分隔符等不安全字符
    tag=$(printf '%s' "$tag" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^-*//;s/-*$//' | cut -c1-48)
    [[ -n "$tag" ]] || { print_err "节点名无效"; return 1; }
    [[ -f "$CLIENT_NODE_DIR/node-$tag.json" ]] && { print_err "同名节点已存在: $tag"; return 1; }

    if [[ -n "$user" ]]; then
        jq -n --arg tag "$tag" --arg t "$t" --arg addr "$addr" --argjson port "$port" \
           --arg user "$user" --arg pass "$pass" '
          {outbounds:[{type:$t, tag:$tag, server:$addr, server_port:$port,
                       username:$user, password:$pass}]}'
    else
        jq -n --arg tag "$tag" --arg t "$t" --arg addr "$addr" --argjson port "$port" '
          {outbounds:[{type:$t, tag:$tag, server:$addr, server_port:$port}]}'
    fi > "$CLIENT_NODE_DIR/node-$tag.json" || { print_err "生成节点文件失败"; return 1; }

    echo "$t://$addr:$port" > "$CLIENT_NODE_DIR/node-$tag.txt"
    printf '{"tag":"%s","source":"local","imported_at":"%s"}\n' "$tag" "$(date -Is)" \
        > "$CLIENT_NODE_DIR/node-$tag.meta.json"
    regen_selector
    print_ok "已添加 $tag  ($t://$addr:$port${user:+ 用户 $user}); 现 $(node_count) 个可用节点"
}

# ---------- 订阅注册表 ----------
# subscriptions.json:
#   {"subs":[{"id","name","prefix","url","kind","nodes","added_at","last_ok"}]}
# kind: external=外部订阅  self=自家 share  local=本地文件
subs_file_init() { [[ -s "$SUBS_FILE" ]] || echo '{"subs":[]}' > "$SUBS_FILE" 2>/dev/null || true; }
subs_count() { subs_file_init; jq '.subs|length' "$SUBS_FILE" 2>/dev/null || echo 0; }
subs_id() { printf '%s' "$1" | md5sum | cut -c1-12; }
subs_get() { subs_file_init; jq -c --arg i "$1" '.subs[]?|select(.id==$i)' "$SUBS_FILE" 2>/dev/null; }
subs_put() { # $1=json 对象; 同 id 覆盖, 否则追加
    subs_file_init
    local id; id=$(printf '%s' "$1" | jq -r '.id')
    jq --argjson o "$1" --arg i "$id" \
        '.subs = (((.subs // []) | map(select(.id != $i))) + [$o])' \
        "$SUBS_FILE" > "$SUBS_FILE.tmp" 2>/dev/null && mv -f "$SUBS_FILE.tmp" "$SUBS_FILE"
}
subs_del() {
    subs_file_init
    jq --arg i "$1" '.subs = ((.subs // []) | map(select(.id != $i)))' \
        "$SUBS_FILE" > "$SUBS_FILE.tmp" 2>/dev/null && mv -f "$SUBS_FILE.tmp" "$SUBS_FILE"
}
# 登记一个订阅。
# 前缀必须和节点名里的一模一样 —— 「一个订阅一个组」就是靠 tag 前缀匹配的,
# 猜错一点整组就空了。所以这里只接受**调用方明确传进来的**前缀, 不去反推:
# 外部订阅的前缀是用户导入时自己填的, 天然已知; 自家 share 的前缀来自服务端
# 的"服务器标识", 客户端只能从**配置里已经带前缀的节点名**取 —— 那是 sing-box
# 聚合时写好的, 比从 URL 猜靠谱得多。
subs_register() { # <url> <kind> <prefix> [显示名]
    local url="$1" kind="$2" pre="$3" name="${4:-$3}" cnt sid
    [[ "$url" =~ ^https?:// ]] || return 1
    [[ -n "$pre" ]] || return 1
    cnt=$(node_file_count)
    sid=$(subs_id "$url")
    subs_put "$(jq -n --arg id "$sid" --arg url "$url" --arg pre "$pre" \
        --arg nm "$name" --argjson n "$cnt" --arg ts "$(date -Is)" --arg kind "$kind" \
        '{id:$id,name:$nm,prefix:$pre,url:$url,kind:$kind,nodes:$n,added_at:$ts}')"
    print_msg "已登记订阅「$name」($cnt 个节点)"
    return 0
}

# 从 URL 猜默认前缀: sub.example.com -> sub。猜不出用 sub,
# 用户回车就有合理默认, 想改再手打。
subs_guess_prefix() {
    local h p
    h=$(printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://##; s#[/?].*$##')
    case "$h" in
        *.*.*) p=$(printf '%s' "$h" | cut -d. -f2) ;;
        *.*)   p=$(printf '%s' "$h" | cut -d. -f1) ;;
        *)     p="sub" ;;
    esac
    p=$(printf '%s' "$p" | tr -cd 'A-Za-z0-9_-' | cut -c1-24)
    [[ -n "$p" ]] || p="sub"
    printf '%s' "$p"
}

# ---------- 节点列表 (带编号) ----------
# 菜单 4 以前直接 read 一个节点名, 要手打 `🇺🇸 myserver-anytls01-TLS`
# 这种长串, 打错一个字就"无此节点"。列出来给编号, 敲个数字就行。
NODE_LIST=""
list_nodes() {
    NODE_LIST=""
    local f tag typ srv
    for f in "$CLIENT_NODE_DIR"/node-*.json; do
        [[ -f "$f" ]] || continue
        # 一个节点文件里可能有多个 outbound, 比如 shadowtls 的外层 vless
        # 和被它 detour 引用的内层 "<tag>-out"。内层不是独立节点, 界面上
        # 也选不到, 以前这里取 .outbounds[0] 恰好会读到内层 —— 表现为
        # 文件叫 rn-shadowtls01-TLS.json, 列表里却显示 rn-shadowtls01-TLS-out,
        # 而且"共 N 个可用节点"凭空多一个。改成: 有 detour 依赖的取剩下的那个。
        local -a tgs
        mapfile -t tgs < <(jq -r '
            (.outbounds // []) as $o
            | ($o | map(select(.detour != null) | .detour)) as $dep
            | ($o | map(select((.tag as $t | $dep | index($t)) != null) | .tag)) as $inner
            | $o[0].tag as $first
            | if (($o | length) > 1 and ($inner | index($first)) != null)
              then ($o | map(select((.tag as $t | $dep | index($t)) == null))[0].tag)
              else $first end' "$f" 2>/dev/null)
        tag="${tgs[0]:-}"
        [[ -n "$tag" ]] || continue
        typ=$(jq -r --arg t "$tag" '.outbounds[]?|select(.tag==$t)|.type // "?"' "$f" 2>/dev/null | head -1)
        srv=$(jq -r --arg t "$tag" '.outbounds[]?|select(.tag==$t)
                |((.server//"-")+":"+((.server_port//"-")|tostring))' "$f" 2>/dev/null | head -1)
        NODE_LIST+="$tag"$'\t'"$typ"$'\t'"$srv"$'\n'
    done
    [[ -n "$NODE_LIST" ]]
    # 同时吐到 stdout。sub_backfill 这类调用方是 `list_nodes | cut -f1` 直接
    # 接管道的, 之前只填全局变量不出声, 那边的 mapfile 拿到的是空的 ——
    # 明明有 59 个节点却报"还没有节点"。
    printf '%s' "$NODE_LIST"
}
print_nodes() {
    list_nodes || { print_warn "还没有任何节点"; return 1; }
    local i=1 tag typ srv
    echo
    printf "  ${CYAN}%4s  %-44s %-13s %s${RESET}\n" "序号" "节点名" "类型" "地址"
    printf "  %s\n" "────────────────────────────────────────────────────────"
    while IFS=$'\t' read -r tag typ srv; do
        [[ -n "$tag" ]] || continue
        printf "  %4d  %-44s %-13s %s\n" "$i" "$tag" "$typ" "$srv"
        i=$((i+1))
    done <<< "$NODE_LIST"
    echo
    print_msg "共 $((i-1)) 个可用节点"
}
node_by_index() { # <序号> -> stdout: tag
    local n="$1" i=1 tag rest
    list_nodes || return 1
    while IFS=$'\t' read -r tag rest; do
        if [[ "$i" == "$n" ]]; then printf '%s' "$tag"; return 0; fi
        i=$((i+1))
    done <<< "$NODE_LIST"
    return 1
}
# 交互式删除: 列出来选编号
del_node_menu() {
    print_nodes || return 1
    local n t
    read -r -p "  要删除的编号 (回车取消): " n || { echo; return 0; }
    n="${n// /}"
    [[ -z "$n" ]] && return 0
    t=$(node_by_index "$n") || { print_err "没有编号 $n"; return 1; }
    del_node "$t"
}
# 全部删除 (节点 + 订阅记录)。以前只能一个个删, 清空要十几轮交互。
# 删了只能重新订阅拉回来, 所以默认 no。
del_all_nodes() {
    local n; n=$(node_file_count)
    (( n == 0 )) && { print_warn "没有可删除的节点"; return 0; }
    print_warn "即将删除全部 $n 个节点 (含订阅记录), 不可撤销"
    local w
    read -r -p "  确认删除全部? 输入 yes, 其它任何输入=取消: " w
    [[ "$w" == "yes" ]] || { print_msg "已取消"; return 0; }
    rm -f "$CLIENT_NODE_DIR"/node-* 2>/dev/null
    printf '{"subs":[]}' > "$SUBS_FILE" 2>/dev/null || true
    regen_selector
    print_ok "已删除全部节点, 现 $(node_count) 个可用节点"
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
    # 服务已在跑时, `systemctl start` 是空操作(返回 0 但什么都不做), 调用方
    # 会以为"新配置已生效"。实测: 导入 12 个新节点后显示"已生效 (已启动服务)",
    # 实际运行实例仍在用旧端口拨不出去。已在跑就 restart, 让新配置真正加载。
    if systemctl is-active --quiet "$SB_UNIT_NAME" 2>/dev/null; then
        systemctl restart "$SB_UNIT_NAME" && return 0
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
      # 必须 restart。unit 里是 ExecReload=/bin/kill -HUP $MAINPID, 但 sing-box
      # **不支持 SIGHUP 热重载** —— 没有 reload 子命令, 收到 SIGHUP 也不重读配置。
      # 而 kill 返回 0, 所以 `systemctl reload` 永远"成功", PID 也不变, 旧代码
      # 一路返回 0 并打印"软重载, 零断流", 而新配置根本没生效。
      #
      # 实测: 配置文件里 anytls 端口已是 25959, 运行实例仍在拨 20478;
      # systemctl reload 返回 0, 行为毫无变化。导入新节点后旧节点继续被使用,
      # 面板却一路 [OK] —— 又是静默假成功。
      local p; p="$(find_sb_pid || true)"
      [[ -n "$p" ]] || { print_err "sing-box 未运行, 无需重载 (请先启动)"; return 1; }
      if have_systemd && unit_installed && systemctl is-active --quiet "$SB_UNIT_NAME" 2>/dev/null; then
          systemctl restart "$SB_UNIT_NAME" 2>/dev/null || return 1
      else
          kill "$p" 2>/dev/null || return 1
          sleep 1
          "$CLIENT_BIN" run -D "$CLIENT_CONF" -C "$CLIENT_CONF" >/dev/null 2>&1 &
      fi
      sleep 1
      p="$(find_sb_pid || true)"
      [[ -n "$p" ]] || { print_err "重载后进程未起来"; return 1; }
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
        ui_menu 8 "下载通道 (拉订阅/内核/UI 走不走代理)"
        ui_menu 0 "返回主菜单"
        ui_rule
        read -r -p "请输入选项 [0-8]: " c || return 0
        case "$c" in
            1) set_mixed_port ;;
            2) set_clash_port ;;
            3) set_bind ;;
            4) webui_menu ;;
            5) show_conf ;;
            6) port_check_menu ;;
            7) show_secret ;;
            8) proxy_settings_menu ;;
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
        [[ "$ST_SERVICE" == "未运行" ]] && printf "         可选择 “10. 启动服务” 开始使用。\n"
        [[ "$ST_SERVICE" == "启动失败" ]] && printf "         建议先执行 “15. 配置检查”。\n"
        [[ "$ST_SERVICE" == "未初始化" ]] && printf "         请先执行 “2. 初始化基础配置”。\n"
    fi
    echo
    ui_rule
    echo
    printf "  %s节点%s\n" "$DIM" "$RESET"
    ui_menu  1 "安装内核"
    ui_menu  2 "初始化基础配置"
    ui_menu  3 "添加节点 (分享链接 / 订阅 URL / YAML 片段)"
    ui_menu  4 "添加简易 HTTP/SOCKS 节点 (接本机或局域网的其它内核)"
    ui_menu  5 "订阅管理 (列出 / 更新 / 删除)"
    ui_menu  6 "删除节点 (列表选编号)"
    ui_menu  7 "全部删除节点"
    ui_menu  8 "列出节点"
    ui_menu  9 "更新节点 (重拉全部订阅)"
    echo
    printf "  %s服务%s\n" "$DIM" "$RESET"
    ui_menu 10 "启动服务"
    ui_menu 11 "停止服务"
    ui_menu 12 "重启服务"
    ui_menu 13 "查看运行状态"
    echo
    printf "  %s配置%s\n" "$DIM" "$RESET"
    ui_menu 14 "Web UI / Clash API"
    ui_menu 15 "配置检查"
    ui_menu 16 "客户端设置 (端口 / Web UI / 占用检测)"
    ui_menu 17 "应用配置 (重启, sing-box 无热重载)"
    ui_menu 18 "卸载客户端 (停服务/删目录/删入口)"
    ui_menu  0 "退出"
    ui_rule
    read -r -p "请输入选项: " c || { ui_clear; exit 0; }
    case "$c" in
        1) do_install ;;
        2) do_init; do_status ;;
        3) read -r -p "  分享链接/订阅 URL/本地文件: " u; add_node "$u" && apply_change "节点导入" ;;
        4) add_local_proxy && apply_change "简易节点已添加" ;;
        5) subs_menu ;;
        6) del_node_menu && apply_change "节点已删除" ;;
        7) del_all_nodes && apply_change "节点已全部删除" ;;
        # 纯查看, 不要在这里 regen_selector: 它只重写 90-outbounds.json 而不重启,
        # 会造出"配置文件里已有分组、运行实例里还是旧的"这种状态 ——
        # 用户看界面没组, 打开配置文件却有。列出节点不该有副作用。
        8) print_nodes ;;
        9) update_node && apply_change "节点更新" ;;
        10) do_start && sleep 1 ;;
        11) do_stop ;;
        12) do_restart && sleep 1 ;;
        13) do_status ;;
        14) do_info ;;
        15) check_menu ;;
        16) settings_menu ;;
        17) do_reload ;;
        18) do_uninstall ;;
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
