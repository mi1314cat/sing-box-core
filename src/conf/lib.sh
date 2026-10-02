#!/bin/bash
# ==============================================================
# lib.sh — SB-Panel 公共库
# 设计给 sing-box.sh 主入口与 conf/*.sh 模块 source 复用：
#   source "$(dirname "$0")/lib.sh"
# 与 xray-core 面板 (xary-core/conf/verify.sh) 的习惯一致：
#   - UI 打印全部输出到 stderr
#   - 路径可被上层环境变量覆盖
# ==============================================================

# ---- 路径（可覆盖）----
SB_ROOT="${SB_ROOT:-/root/catmi/sing-box}"
SB_CONFIG_DIR="${SB_CONFIG_DIR:-$SB_ROOT/config}"
SB_OUT_DIR="${SB_OUT_DIR:-$SB_ROOT/out}"
SB_BACKUP_DIR="${SB_BACKUP_DIR:-$SB_ROOT/backup}"
SB_BIN="${SB_BIN:-$SB_ROOT/sing-box}"
SB_SERVICE="${SB_SERVICE:-sing-box}"
SB_REPO_API="https://api.github.com/repos/SagerNet/sing-box"

export SB_ROOT SB_CONFIG_DIR SB_OUT_DIR SB_BACKUP_DIR SB_BIN SB_SERVICE

# ---- 颜色 ----
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
MAGENTA="\e[95m"
CYAN="\e[96m"
BOLD="\e[1m"
RESET="\e[0m"

print_info()  { printf "${CYAN}[Info]${RESET} %s\n" "$1" >&2; }
print_ok()    { printf "${GREEN}[OK]${RESET} %s\n" "$1" >&2; }
print_warn()  { printf "${YELLOW}[Warn]${RESET} %s\n" "$1" >&2; }
print_error() { printf "${RED}[Error]${RESET} %s\n" "$1" >&2; }

print_title() {
    printf "${MAGENTA}${BOLD}" >&2
    printf "╔══════════════════════════════════════════════╗\n" >&2
    printf "║ %-44s ║\n" "$1" >&2
    printf "╚══════════════════════════════════════════════╝\n" >&2
    printf "${RESET}" >&2
}

# ---- 输入工具 ----
clean_input() { echo "$1" | tr -d '\000-\037' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

safe_read() { # safe_read <prompt> <default> -> stdout
    local input
    if [[ -n "${SB_BATCH:-}" ]]; then
        printf '%s (batch→默认: %s)\n' "$1" "$2" >&2
        echo "$2"; return
    fi
    printf '%s (默认: %s): ' "$1" "$2" >&2
    read -r input
    input=$(clean_input "$input")
    echo "${input:-$2}"
}

# ---- 端口工具 ----
port_in_use() {
    ss -tuln 2>/dev/null | awk '{print $5}' | grep -E -q "(:|])${1}$"
}

random_free_port() {
    local port
    while true; do
        port=$(shuf -i 10000-60000 -n 1)
        if ! port_in_use "$port"; then
            echo "$port"
            return
        fi
    done
}

# ---- 批量端口分配器 (全协议一键生成用) ----
batch_ports_used() { # 输出本机监听端口 + 已有 config 内 listen_port
    ss -tuln 2>/dev/null | awk '{print $5}' | sed 's/.*[:]]*//' | grep -E '^[0-9]+$'
    shopt -s nullglob
    local f
    for f in "$SB_CONFIG_DIR"/*.json; do
        jq -r '.inbounds[]?.listen_port // empty' "$f" 2>/dev/null
    done
    shopt -u nullglob
}

batch_next_port() { # 从 SB_BATCH_PORT_START-END 内顺序取未占用端口(跳过已领的), 领完区间回落随机
    local s="${SB_BATCH_PORT_START:-20000}" e="${SB_BATCH_PORT_END:-50000}"
    local used="$SB_OUT_DIR/.batch-used"
    local prev="$SB_OUT_DIR/.batch-port"
    local n p
    n=$s; [[ -s "$prev" ]] && n=$(( $(cat "$prev") + 1 ))
    while (( n <= e )); do
        if ! port_in_use "$n" && ! grep -qx "$n" <(batch_ports_used) && ! grep -qx "$n" "$used" 2>/dev/null; then
            echo "$n" > "$prev"; echo "$n" >> "$used"
            echo "$n"; return
        fi
        ((n++))
    done
    echo "range exhausted" >&2
    random_free_port
}

safe_read_port() { # 默认值 = 随机空闲端口
    local default="${1:-}" input port
    if [[ -n "${SB_BATCH:-}" ]]; then
        batch_next_port; return
    fi
    [[ -z "$default" ]] && default=$(random_free_port)
    while true; do
        printf '请输入监听端口 (默认: %s): ' "$default" >&2
        read -r input
        input=$(clean_input "$input")
        port="${input:-$default}"
        if ! [[ "$port" =~ ^[0-9]+$ ]]; then print_error "端口必须是数字"; continue; fi
        if (( 10#$port < 1 || 10#$port > 65535 )); then print_error "端口范围 1-65535"; continue; fi
        # 1-1023 是特权端口, 代理服务没有正当理由占用。
        # 只查 1-65535 会放过明显是手滑的值 (比如把"传输选 1"误填进端口框
        # 得到端口 1), 而 root 确实能绑上去 —— 于是生成出一份
        # "proxy_pass https://127.0.0.1:1" 的 nginx 配置, 全程一路 [OK],
        # 直到客户端连不上才暴露。端口 22 更危险: 会直接顶掉 sshd。
        if (( 10#$port < 1024 )); then
            print_error "端口 $port 是特权端口 (1-1023 保留给系统服务), 请用 1024 以上"
            continue
        fi
        if port_in_use "$port"; then print_error "端口 $port 已被占用"; continue; fi
        echo "$port"
        return
    done
}

# ---- 监听 IP 检测 ----
detect_listen_ip() {
    local has_v4=false has_v6=false
    ip -4 addr show scope global 2>/dev/null | grep -q "inet " && has_v4=true
    ip -6 addr show scope global 2>/dev/null | grep -q "inet6 [2-9a-fA-F]" && has_v6=true
    if $has_v4 && ! $has_v6; then echo "ipv4"
    elif ! $has_v4 && $has_v6; then echo "ipv6"
    elif $has_v4 && $has_v6; then echo "dual"
    else echo "none"; fi
}

# 隧道/虚拟接口名 —— 这些接口上的 IP 是代理出口地址, 不能直接给客户端连
SB_TUNNEL_IFACE_RE='^(warp|wg[0-9]*|tun[0-9]*|tap[0-9]*|utun[0-9]*|tailscale|ts[0-9]*|ppp[0-9]*|zt|meta|he-ipv6-tun)'

# 机器真实 IPv6 (排除 WARP 等隧道接口)
#
# 为什么不能用 "问外部 API 拿出口 IP": 套了 WARP 时, 那条查询本身就走 WARP,
# 返回的是 WARP 地址 (2606:4700:...) —— 客户端拿去直连必然失败。
# 外部 API 只在没有隧道、且用户明确要"出口 IP"时才作为最后的兜底。
sb_real_ipv6() {
    local dev
    # -6 -o addr show scope global: 全局单播地址
    # 第二列是接口名, 第四列是 地址/前缀
    while read -r dev _ _ cidr _; do
        [[ -z "$dev" || -z "$cidr" ]] && continue
        [[ "$dev" =~ $SB_TUNNEL_IFACE_RE ]] && continue
        case "$cidr" in
            *:*/*) echo "${cidr%%/*}"; return 0 ;;
        esac
    done < <(ip -6 -o addr show scope global 2>/dev/null)
    return 1
}

# 是否套了 WARP
sb_warp_active() {
    ip -6 -o addr show scope global 2>/dev/null | awk '{print $2}' | grep -qE "$SB_TUNNEL_IFACE_RE"
}

# 对外使用的服务器地址: 优先真实 IPv4; 没有 v4 再用真实 IPv6
#
# 注意与 default_server_ip 的区别: 这里刻意不查外部 API —— 那会经 WARP
# 拿到 WARP 地址。宁可返回空, 也不要给用户一个连不通的地址。
default_server_ip_real() {
    local v4
    v4=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 |
         grep -vE '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -1)
    if [[ -n "$v4" ]]; then echo "$v4"; return 0; fi
    sb_real_ipv6 && return 0
    return 1
}

# ==================== 地址族: IPv4 / IPv6 ====================
#
# 为什么需要: 同一个节点端口, 想让 IPv4 和 IPv6 的客户端都能连, 服务端就得
# 监听在双栈地址上。实测踩过的坑:
#   监听 0.0.0.0  -> 只收 IPv4。客户端拿 IPv6 来连, 服务器直接
#                     "Connection refused" (注意是**拒绝**不是超时 —— 说明包到了,
#                     那个端口在 IPv6 上压根没人监听)。
#   监听 ::       -> Linux 上默认双栈 (net.ipv6.bindv6only=0), 一个端口同时收
#                     IPv4 和 IPv6, 不会因为开了 IPv6 就丢掉 IPv4。
# 所以监听地址这一项要让人能选, 而不是只能填 0.0.0.0。
#
# 另外客户端产物 (sb_client-*.json / .yaml / 分享链接) 里写的是"连哪个地址",
# 这跟服务端监听地址是两件事 —— 监听双栈但产物里写死 IPv4, 客户端还是只会走
# IPv4。所以两边都要能选, 这里负责探测地址和切换产物里的地址。

SB_ADDR_FAMILY_FILE=""

sb_addr_state_file() {
    SB_ADDR_FAMILY_FILE="$SB_ROOT/.addr-family"
    printf '%s' "$SB_ADDR_FAMILY_FILE"
}

sb_addr4() {
    local ip
    ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 |
         grep -vE '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -1)
    [[ -z "$ip" ]] && ip=$(curl -4 -s --max-time 6 ip.sb 2>/dev/null | tr -d '[:space:]')
    printf '%s' "$ip"
}

# 服务器真实 IPv6 —— 排除 WARP/wg/tun 等隧道接口上的地址。
# 隧道地址对外不可达, 写进客户端产物等于给一个连不上的地址。
sb_addr6() { sb_real_ipv6 2>/dev/null || true; }

sb_addr_family_get() {
    local f; f=$(sb_addr_state_file)
    local v=""
    [[ -f "$f" ]] && v=$(head -1 "$f" 2>/dev/null | tr -d '[:space:]')
    [[ "$v" == "v6" ]] && { printf 'v6'; return 0; }
    printf 'v4'
}

# 地址族的显示名 —— 不要用 "IPv$(( 6 - cur + 1 ))" 这种算术。
# 写着省事, 实际算反了: cur=1 表示 v4, 6-1+1=6 会显示成 "IPv6"。
# 排查时菜单写着 IPv6、日志却是 IPv4, 就是这行干的。
sb_family_num()   { [[ "$(sb_addr_family_get)" == "v6" ]] && echo 6 || echo 4; }
sb_family_label() { echo "IPv$(sb_family_num)"; }

sb_addr_family_set() {
    local f; f=$(sb_addr_state_file)
    mkdir -p "$SB_ROOT" 2>/dev/null
    printf '%s\n' "$1" > "$f"
}

# 当前地址族对应的地址 (产物里该写什么)
sb_addr_current() {
    if [[ "$(sb_addr_family_get)" == "v6" ]]; then
        local a; a=$(sb_addr6)
        if [[ -n "$a" ]]; then printf '%s' "$a"; return 0; fi
        print_warn "本机没有可用的真实 IPv6, 回退 IPv4" >&2
    fi
    sb_addr4
}

# ---------- 监听地址选择 ----------
# 默认双栈 (::)。Linux 上 :: 在 bindv6only=0 时同时收 IPv4 和 IPv6, 不会因为
# 开了 IPv6 就丢掉 IPv4 —— 所以它比 0.0.0.0 更通用, 没有理由不默认。
# 唯一要退让的情况: 内核完全没启用 IPv6 (压根没有 :: 可绑), 这时才回 0.0.0.0。
SB_LISTEN_DEFAULT="::"
# 判定方式踩过一次坑: 一开始写的是 grep -q "^::" /proc/net/if_inet6, 永远不匹配 ——
# 那个文件里地址是 32 个十六进制字符 (2001:470::1 存成 2001047000...0001),
# 压根没有 "::" 这种写法。于是每次都误判成"没 IPv6", 默认值退回 0.0.0.0,
# 看起来像是功能没生效, 其实是我判断写错了。
# 改成真的去绑一次: 能绑上就是能用, 绑不上才退回 IPv4。
if ! python3 -c "
import socket,sys
try:
    s=socket.socket(socket.AF_INET6); s.bind(('::',0)); s.close()
except Exception:
    sys.exit(1)
" 2>/dev/null; then
    SB_LISTEN_DEFAULT="0.0.0.0"
fi
export SB_LISTEN_DEFAULT
# 原来是 safe_read "监听地址 (0.0.0.0/::)" "0.0.0.0" —— 纯自由输入,
# 默认值又是 0.0.0.0, 于是"想同时支持 IPv6"这件事没有任何提示, 很容易就建成
# 只收 IPv4 的节点。改成显式菜单, 并把每一项的后果说清楚。
ask_listen_addr() {
    local dual="::" v6ok="无"
    local a6; a6=$(sb_addr6)
    [[ -n "$a6" ]] && v6ok="检测到 $a6"
    echo >&2
    echo -e "${CYAN}  监听地址 —— 决定这个节点收 IPv4、收 IPv6、还是只收本机${RESET}" >&2
    echo -e "    ${GREEN}1)${RESET} ${CYAN}::${RESET}       IPv4+IPv6 双栈${RESET} (默认 — 两种协议都能连, 不丢 IPv4)" >&2
    echo -e "       ${MAGENTA}(${v6ok})${RESET}" >&2
    echo -e "    ${GREEN}2)${RESET} ${YELLOW}0.0.0.0${RESET}  仅 IPv4${RESET} (只给不支持 IPv6 的场景)" >&2
    echo -e "    ${GREEN}3)${RESET} 127.0.0.1 仅本机${RESET} (给 CDN/Nginx 前置用, 外部连不上)" >&2
    local c="" d
    # 批量模式下绝不能 read: 批量生成靠一条应答队列按顺序喂各协议的提问,
    # 这里多读一次就把后面某个协议的答案吃掉了 (顺序错位, 而且极难查)。
    # 批量入口 (batch.sh) 会先问一次用户, 再把结果放进 SB_LISTEN_ADDR。
    if [[ -n "${SB_BATCH:-}" ]]; then
        d="${SB_LISTEN_ADDR:-$SB_LISTEN_DEFAULT}"
        [[ "$d" == "::" ]] && print_ok "批量: 双栈监听 (IPv4+IPv6)"
        [[ "$d" == "::" ]] || print_info "批量: 监听 $d"
        printf '%s' "$d"; return 0
    fi
    read -r -p "    请选择 [1-3, 回车=1]: " c || { echo; return 0; }
    case "${c// /}" in
        2) d="0.0.0.0" ;;
        3) d="127.0.0.1" ;;
        "") d="$SB_LISTEN_DEFAULT" ;;
        *) d="$c" ;;
    esac
    if [[ "$d" == "0.0.0.0" ]]; then
        print_info "仅 IPv4: IPv6 客户端连这个端口会被拒绝 (Connection refused)"
    fi
    if [[ "$d" == "::" ]]; then
        if [[ -z "$a6" ]]; then
            print_warn "本机没有可用的 IPv6 地址 —— 双栈仍然能收 IPv4, 但 IPv6 客户端连不上"
        else
            print_ok "双栈监听: IPv4 与 IPv6 客户端都能连这个端口"
        fi
        if [[ "$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo 0)" == "1" ]]; then
            print_warn "net.ipv6.bindv6only=1, 监听 :: 只收 IPv6, IPv4 会连不上"
        fi
    fi
    printf '%s' "$d"
}

# ---------- 对外地址选择 (写进客户端产物) ----------
# 同样从自由输入改成显式选择, 并把"这次产物用 IPv4 还是 IPv6"落到状态文件,
# 后续生成聚合/分享链接时保持一致, 不会出现单节点写 IPv4、聚合写 IPv6 的情况。
ask_server_addr() {
    local a4 a6
    a4=$(sb_addr4); a6=$(sb_addr6)
    echo >&2
    echo -e "${CYAN}  服务器对外地址 —— 客户端配置里写哪个地址${RESET}" >&2
    [[ -n "$a4" ]] && echo -e "    ${GREEN}1)${RESET} IPv4   ${CYAN}$a4${RESET}" >&2 || echo -e "    ${MAGENTA}(未检测到 IPv4)${RESET}" >&2
    [[ -n "$a6" ]] && echo -e "    ${GREEN}2)${RESET} IPv6   ${CYAN}$a6${RESET}" >&2 || echo -e "    ${MAGENTA}(未检测到 IPv6)${RESET}" >&2
    echo -e "    ${GREEN}3)${RESET} 手工输入${RESET}" >&2
    # 同 ask_listen_addr: 批量模式不 read, 由 batch.sh 事先问好放进 SB_SERVER_ADDR
    if [[ -n "${SB_BATCH:-}" ]]; then
        local bd="${SB_SERVER_ADDR:-}"
        [[ -z "$bd" ]] && bd=$(sb_addr_current)
        [[ -z "$bd" ]] && bd="$a4"
        [[ "$bd" == *:* ]] && sb_addr_family_set v6 || sb_addr_family_set v4
        print_info "批量: 客户端配置写入 $([[ "$bd" == *:* ]] && echo IPv6 || echo IPv4) $bd"
        printf '%s' "$bd"; return 0
    fi
    local c="" cur
    cur=$(sb_addr_family_get); [[ "$cur" == "v6" ]] && cur=2 || cur=1
    read -r -p "    请选择 [1-3, 回车=$([[ "$cur" == 2 ]] && echo IPv6 || echo IPv4)]: " c || { echo; return 0; }
    case "${c// /}" in
        2) [[ -n "$a6" ]] || { print_warn "没有可用 IPv6, 仍按 IPv6 处理"; }; sb_addr_family_set v6; printf '%s' "$a6" ;;
        3) local m=""; read -r -p "    请输入地址: " m || { echo; return 0; }
           [[ -z "$m" ]] && m="$a4"
           [[ "$m" == *:* ]] && sb_addr_family_set v6 || sb_addr_family_set v4
           printf '%s' "$m" ;;
        *) sb_addr_family_set v4; [[ -n "$a4" ]] && printf '%s' "$a4" || printf '%s' "$(default_server_ip)" ;;
    esac
}

default_server_ip() { # 优先公网网卡 IPv4; 无 v4 则回退 IPv6
    local local_ip public_ip
    local_ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 |
        grep -vE '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -1)
    [[ -n "$local_ip" ]] && { echo "$local_ip"; return; }
    public_ip=$(curl -4 -s --max-time 8 ip.sb 2>/dev/null | tr -d '[:space:]')
    [[ -n "$public_ip" ]] && { echo "$public_ip"; return; }
    # 无 IPv4 时用真实 IPv6 (排除 WARP 等隧道接口)
    sb_real_ipv6 && return 0
    echo ""
}


  # URL 里的主机: IPv6 必须用方括号包起来, 否则端口会被当成地址的一部分。
  #   错误: http://2001:db8::1:9292/share/xxx
  #   正确: http://[2001:db8::1]:9292/share/xxx
  # 客户端(浏览器/curl/sing-box)把前者解析成非法 host, 直接失败。
  # IPv4 不加括号 (加了多数实现也认, 但没必要, 且日志难读)。
  sb_url_host() {
      local h="$1"
      [[ -z "$h" ]] && { echo ""; return; }
      case "$h" in
          *:*) printf '[%s]' "$h" ;;   # 含冒号 = IPv6
          *)   printf '%s' "$h" ;;
      esac
  }
# ---- 协议文件编号: <proto>-NN.json ----
# ---------- 证书选择 (CDN 友好) ----------
# 从已检测到的证书里选, 而不是手打路径:
#   - 域名自动带出, 与 Nginx server_name 保证一致 (CDN 回源校验 SNI)
#   - 不新增交互维度, 只是把"手打路径"换成"从列表挑"
# 用法: pick_trusted_cert  -> 设 CERT_FILE / KEY_FILE / CERT_DOMAIN / CERT_TRUSTED
# ---------- nginx 站点检测 ----------
# 批量选证书时用得上: 光列出一堆 /etc/letsencrypt/live 下的证书路径,
# 用户很难判断"哪个域名是我对外真正在用的"。把 nginx 站点里的 server_name
# 也列出来, 选择就直观了 —— 你站点在用的那张, 通常就是该用的那张。
# 兼容两种部署: 宿主机 nginx (/etc/nginx) 与容器 nginx (/home/web/conf.d)。
SB_NGINX_SITES=()
sb_scan_nginx_sites() {
    SB_NGINX_SITES=()
    local roots=(/etc/nginx /home/web/conf.d /usr/local/nginx/conf /etc/nginx/conf.d)
    local d f n
    for d in "${roots[@]}"; do
        [[ -d "$d" ]] || continue
        while read -r n; do
            [[ -n "$n" ]] && SB_NGINX_SITES+=("$n")
        done < <(grep -rhoE '^[[:space:]]*server_name[[:space:]]+[^;]+;' "$d" 2>/dev/null \
                  | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/;[[:space:]]*$//' \
                  | tr ' ' '\n' | grep -v '^_$' | sort -u)
    done
    # 去重
    if (( ${#SB_NGINX_SITES[@]} > 0 )); then
        local uniq=() seen=" "
        for n in "${SB_NGINX_SITES[@]}"; do
            [[ "$seen" == *" $n "* ]] && continue
            seen+="$n "; uniq+=("$n")
        done
        SB_NGINX_SITES=("${uniq[@]}")
    fi
    return 0
}

# 列出"证书 + 站点域名"的对照, 让用户按域名选而不是按文件路径选。
# 传入 sb_FOUND_CERTS (来自 sb_scan_certs), 打印编号列表, 回车=1。
pick_trusted_cert_verbose() {
    if ! sb_scan_certs; then
        print_warn "未检测到任何证书, 回退到手动输入路径"
        local f k
        read -r -p "  crt 路径: " f; read -r -p "  key 路径: " k
        f=$(clean_input "$f"); k=$(clean_input "$k")
        if [[ -f "$f" && -f "$k" ]]; then
            CERT_FILE="$f"; CERT_KEY_FILE_DONE="$k"
            KEY_FILE="$k"; CERT_DOMAIN=$(extract_cert_domain "$f"); CERT_TRUSTED=true
            return 0
        fi
        print_error "路径无效"; return 1
    fi
    sb_scan_nginx_sites
    # 同一张证书在磁盘上常有两份 (acme.sh 的 certs/x.pem 与 letsencrypt 的
    # live/x/fullchain.pem), 按路径去重会把它们都列出来, 用户看着像两张证书,
    # 编号也对不上号。这里按域名去重, 保留第一份路径。
    local uniq=() seen=" " e crt key dom mark
    for e in "${sb_FOUND_CERTS[@]}"; do
        crt="${e%%|*}"; dom=$(extract_cert_domain "$crt")
        [[ "$seen" == *" ${dom:-?} "* ]] && continue
        seen+="${dom:-?} "; uniq+=("$e")
    done
    local i=1
    echo "  检测到 ${#uniq[@]} 张证书:" >&2
    for e in "${uniq[@]}"; do
        crt="${e%%|*}"; key="${e#*|}"; key="${key%%|*}"
        dom=$(extract_cert_domain "$crt")
        mark=""
        local n
        for n in "${SB_NGINX_SITES[@]}"; do
            [[ "$n" == "$dom" || "$n" == "*.$dom" || "$n" == *".$dom" ]] && { mark=" ← nginx 站点在用"; break; }
        done
        printf "  %d) %-34s%s\n" "$i" "${dom:-未知域名}" "$mark" >&2
        i=$((i+1))
    done
    if (( ${#SB_NGINX_SITES[@]} > 0 )); then
        echo -e "  ${MAGENTA}(检测到 ${#SB_NGINX_SITES[@]} 个 nginx 站点域名)${RESET}" >&2
    fi
    local c
    read -r -p "  选哪张 (数字, 回车=1): " c
    c=$(clean_input "$c"); [[ -z "$c" ]] && c=1
    [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#uniq[@]} )) || { print_error "无效选择"; return 1; }
    e="${uniq[$((c-1))]}"
    crt="${e%%|*}"; key="${e#*|}"; key="${key%%|*}"
    CERT_FILE="$crt"; KEY_FILE="$key"
    CERT_DOMAIN=$(extract_cert_domain "$crt")
    CERT_TRUSTED=true
    print_ok "已选证书: $CERT_DOMAIN"
    return 0
}

# 批量模式下统一用 batch 入口事先选好的证书。
# 批量下**绝不能** read: 那条应答队列是按顺序喂给各协议的, 协议里多读一次
# 就会把后面某个协议的答案吃掉。所以这里只读环境变量。
# 批量指定"使用本机真实证书"时, 把协议自己读到的 TLS 模式改判到真证书分支。
# 各协议的分菜单编号不统一 (trojan/anytls 是 1, hysteria2/vmess 是 2),
# 所以把真证书分支编号当参数传进来。
# 不改的话: 批量下 read 取默认值 -> 各协议默认走自签 -> ③ 选了真证书也没用,
# 表现就是菜单明明选了真证书, 生成出来还是自签。
sb_batch_tls_override() { # sb_batch_tls_override <真证书分支编号> <变量名>
    local n="$1" var="$2"
    [[ -n "${SB_BATCH:-}" ]] || return 0
    [[ "${SB_BATCH_CERT:-self}" == "real" ]] || return 0
    printf -v "$var" '%s' "$n"
    return 0
}

sb_apply_batch_cert() {
    local m="${SB_BATCH_CERT:-self}"
    if [[ "$m" == "real" ]]; then
        if [[ -n "${SB_BATCH_CERT_CRT:-}" && -f "${SB_BATCH_CERT_CRT}" ]]; then
            CERT_FILE="$SB_BATCH_CERT_CRT"
            KEY_FILE="${SB_BATCH_CERT_KEY:-}"
            CERT_DOMAIN="${SB_BATCH_CERT_DOMAIN:-$(extract_cert_domain "$CERT_FILE")}"
            CERT_TRUSTED=true
            print_info "批量: 真证书 $CERT_DOMAIN"
            return 0
        fi
        print_warn "批量指定的真证书不可用, 改用自签"
    fi
    sb_selfgen_cert
    return 0
}

pick_trusted_cert() {
    if ! sb_scan_certs; then
        print_warn "未检测到任何证书, 回退到手动输入路径"
        local f k
        read -r -p "  crt 路径: " f; read -r -p "  key 路径: " k
        f=$(clean_input "$f"); k=$(clean_input "$k")
        if [[ -f "$f" && -f "$k" ]]; then
            CERT_FILE="$f"; KEY_FILE="$k"
            CERT_DOMAIN=$(extract_cert_domain "$f"); CERT_TRUSTED=true
            return 0
        fi
        print_error "路径无效"; return 1
    fi

    echo "  检测到 ${#sb_FOUND_CERTS[@]} 张证书:" >&2
    local i=1 e crt key dom
    for e in "${sb_FOUND_CERTS[@]}"; do
        crt="${e%%|*}"; key="${e#*|}"; key="${key%%|*}"
        dom=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null \
              | grep -oE 'DNS:[^ ,]+' | head -1 | cut -d: -f2)
        [[ -z "$dom" ]] && dom=$(extract_cert_domain "$crt")
        printf "  %d) %s  (%s)\n" "$i" "${dom:-未知域名}" "$crt" >&2
        i=$((i+1))
    done
    local c
    read -r -p "  选哪张 (数字, 回车=1): " c
    c=$(clean_input "$c"); [[ -z "$c" ]] && c=1
    [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#sb_FOUND_CERTS[@]} )) || { print_error "无效选择"; return 1; }

    e="${sb_FOUND_CERTS[$((c-1))]}"
    crt="${e%%|*}"; key="${e#*|}"; key="${key%%|*}"
    CERT_FILE="$crt"; KEY_FILE="$key"
    CERT_DOMAIN=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null \
                  | grep -oE 'DNS:[^ ,]+' | head -1 | cut -d: -f2)
    [[ -z "$CERT_DOMAIN" ]] && CERT_DOMAIN=$(extract_cert_domain "$crt")
    CERT_TRUSTED=true
    print_ok "已选证书: $CERT_DOMAIN"
    return 0
}

# 按 tag 找服务端配置文件路径
# 约定: 配置文件名是 <proto>-NN.json (如 vless-03.json), tag 形如 vless03-TLS
# 两者不同名, 不能直接拼 $SB_CONFIG_DIR/$tag.json
sb_config_by_tag() {
    local tag="$1" f base num
    # tag 形如 vless03-TLS / hysteria201-TLS / shadowtls02-TLS
    # 协议名本身含数字(hysteria2), 所以末尾两位数字才是编号:
    #   去掉尾部 "-XXX" 后, 再截掉末尾两位数字即协议名
    base="${tag%-*}"                 # vless03 / hysteria201 / shadowtls02
    [[ -z "$base" ]] && { echo ""; return 1; }
    num="${base: -2}"                # 末尾两位 = 编号 (03 / 01 / 02)
    [[ "$num" =~ ^[0-9]{2}$ ]] || { echo ""; return 1; }
    f="$SB_CONFIG_DIR/${base:0:${#base}-2}-$num.json"
    [[ -f "$f" ]] || { echo ""; return 1; }
    echo "$f"
}

# 证书是否由受信任 CA 签发 (不是自签)
# 自签证书 subject == issuer, Cloudflare 一律拒绝回源, 必须能区分出来。
sb_cert_is_real_issuer() {
    local crt="$1" subj issuer
    [[ -f "$crt" ]] || return 1
    subj=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null | sed 's/^subject=//')
    issuer=$(openssl x509 -in "$crt" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
    [[ -z "$subj" || -z "$issuer" ]] && return 1
    [[ "$subj" == "$issuer" ]] && return 1
    return 0
}

# ---------- 批量模式下的 CDN 证书选择 ----------
# 批量生成时若启用 CDN (SB_BATCH_CDN=1), 从已检测到的证书里挑一张真证书。
# 若可用证书的域名与站点配置的 server_name 不一致, 客户端仍能连
# (CDN 只认域名本身), 但 Nginx 需要有对应 server{} —— 由 cdn_auto_insert
# 负责定位; 定位不到会提示手工粘贴, 不会静默写错地方。
sb_batch_cdn_pick_cert() {
    sb_scan_certs >/dev/null 2>&1 || return 1
    local want="${SB_BATCH_CDN_DOMAIN:-}" e crt key dom
    # 指定了域名就找匹配的, 否则第一张可用即可
    for e in "${sb_FOUND_CERTS[@]}"; do
        crt="${e%%|*}"; key="${e#*|}"; key="${key%%|*}"
        dom=$(extract_cert_domain "$crt")
        if [[ -n "$want" && "$dom" != "$want" ]]; then continue; fi
        CERT_FILE="$crt"; KEY_FILE="$key"; CERT_DOMAIN="$dom"
        CERT_TRUSTED=true
        print_info "批量 CDN: 使用证书 $dom"
        return 0
    done
    return 1
}

# ---------- 建节点时询问接入方式 ----------
# 参照参考脚本 vlessxhttpecn.sh 的 ACCESS_MODE:
#   1) 直连       监听对外地址, 客户端连 服务器IP:端口   (最简单, 无需 Nginx)
#   2) CDN 直连   监听 0.0.0.0, Cloudflare 回源到本节点端口 (不经过 Nginx)
#   3) CDN+Nginx  监听 127.0.0.1, 由 Nginx 按路径转发      (源站 IP 不暴露)
# 只有 ws/grpc/http(2) 才能走 CDN; 其余协议 (REALITY/AnyTLS/Hysteria2/
# TUIC/SS/naive/ShadowTLS) 是原生 TCP/UDP, Cloudflare 代理不了, 只给直连。
#
# 输出: direct | cdn | cdn-nginx
ask_access_mode() {
    # 结果写进全局 ACCESS_MODE, 而不是靠 stdout 返回值。
    # 原因: 用 $(ask_access_mode) 命令替换时, 函数里的 safe_read/read 会跑在
    # 子 shell 里, 子 shell 的 stdin 在某些调用方式下读到的是已耗尽的副本,
    # 于是 safe_read 拿到空值 -> 默认值也没生效 -> 后面 case 全落到兜底分支,
    # 表现为"明明选了 CDN+Nginx 却还在问监听地址"。
    # 写全局变量则始终在当前 shell 的 stdin 上读, 行为可预期。
    local ttype="${1:-tcp}" trusted="${2:-no}"
    local can_cdn="no"
    # 内联判定传输是否支持 CDN (ws/grpc/http(2)), 不依赖 cdn.sh 是否被加载
    case "$ttype" in ws|grpc|http) [[ "$trusted" == "yes" ]] && can_cdn="yes" ;; esac

    if [[ "$can_cdn" != "yes" ]]; then
        echo "  接入方式:" >&2
        echo "    1) 直连 (监听对外地址, 客户端连 服务器IP:端口)" >&2
        case "$ttype" in
            ws|grpc|http)
                echo "    [走 CDN 需要真证书 —— Cloudflare 不接受自签证书]" >&2 ;;
            *)
                echo "    [$ttype 传输不能走 CDN —— Cloudflare 只代理 ws/grpc/http(2)]" >&2 ;;
        esac
        local c; c=$(safe_read "选择" "1")
        [[ -z "$c" ]] && c=1
        ACCESS_MODE="direct"
        return 0
    fi

    # 批量模式: 直接定成 CDN+Nginx, 不再逐个询问
    if [[ "${SB_BATCH:-}" == "1" && "${SB_BATCH_CDN:-0}" == "1" ]]; then
        ACCESS_MODE="cdn-nginx"
        return 0
    fi

    echo "  接入方式:" >&2
    echo "    1) 直连 (推荐, 最简单, 无需 Nginx)" >&2
    echo "    2) CDN 直连 (Cloudflare 回源到本节点端口, 不经 Nginx)" >&2
    echo "    3) CDN + Nginx (推荐: 源站端口不暴露, 隐藏源站 IP)" >&2
    local c; c=$(safe_read "选择" "3")
    [[ -z "$c" ]] && c=3
    case "$c" in
        1) ACCESS_MODE="direct" ;;
        2) ACCESS_MODE="cdn" ;;
        *) ACCESS_MODE="cdn-nginx" ;;
    esac
    return 0
}

# ---------- CDN 模式 ----------
# 真证书 + ws/grpc/http 即可走 CDN。判定只依据已生成的配置, 不引入新交互:
#   - 监听 127.0.0.1 (端口不对外暴露, 由 Nginx 承接 443 后按 path 转发)
#   - 分享链接用证书域名而非服务器 IP
# 非 CDN 节点行为完全不变。
sb_cdn_enabled() { # <配置文件> -> 0 表示该节点走 CDN
    # 判定: 传输在 ws/grpc/http(2) 之内, 且用的是**真证书**。
    # 自签证书 Cloudflare 一定拒绝回源, 不能算 CDN 节点 —— 否则会生成
    # 一份"看着像 CDN 其实永远 502"的客户端配置, 比直接报错更难排查。
    #
    # 这里内联判定而不是调 cdn.sh 的 cdn_config_supported:
    # lib.sh 被各协议脚本 source, 而 cdn.sh 只有进 CDN 菜单时才加载;
    # 调不到函数会被当成"返回非 0" -> 真证书 ws 节点也被判成非 CDN ->
    # 产物里写服务器 IP 而不是域名, 客户端连了源站端口, CDN 等于没生效。
    local f="$1" t crt
    t=$(jq -r '.inbounds[0].transport.type // "tcp"' "$f" 2>/dev/null)
    case "$t" in ws|grpc|http) ;; *) return 1 ;; esac
    crt=$(jq -r '.inbounds[0].tls.certificate_path // ""' "$f" 2>/dev/null)
    [[ -n "$crt" && -f "$crt" ]] || return 1
    sb_key_for "$crt" >/dev/null 2>&1 || return 1
    cert_not_expired "$crt" || return 1
    sb_cert_is_real_issuer "$crt" || return 1
    return 0
}
# CDN 收尾: 把节点切到 CDN 模式并回显客户端该连的地址
# 用法: conn=$(sb_cdn_finalize <config> <tag>)
#   非 CDN 节点: 原样返回传入的 fallback (通常是服务器 IP)
#   CDN 节点:   改 listen 为 127.0.0.1, 返回证书域名
sb_cdn_finalize() {
    local f="$1" fb="${2:-}" dom listen
    if sb_cdn_enabled "$f"; then
        # 监听地址由接入方式决定 (对应参考脚本 vlessxhttpecn.sh 的 ACCESS_MODE):
        #   cdn       = Cloudflare 直连本节点端口 -> 必须对外监听, 否则 CF 连不上
        #   cdn-nginx = 经 Nginx 按路径转发     -> 只听 127.0.0.1, 源站端口不暴露
        case "${ACCESS_MODE:-cdn-nginx}" in
            cdn) listen="0.0.0.0" ;;
            *)   listen="127.0.0.1" ;;
        esac
        jq --arg l "$listen" '.inbounds[0].listen = $l' "$f" > "$f.tmp" 2>/dev/null \
            && mv -f "$f.tmp" "$f"
        dom=$(sb_cdn_domain "$f")
        if [[ -n "$dom" ]]; then
            # 注意: 调用方必须同时把端口换成 443 —— 只换域名不换端口会得到
            # 连不通的 域名:源站端口 组合 (CDN 只在 443 上提供服务)
            if [[ "${ACCESS_MODE:-cdn-nginx}" == "cdn" ]]; then
                print_ok "CDN 直连模式: 监听 $listen, 客户端连 $dom:443"
            else
                print_ok "CDN+Nginx 模式: 监听 127.0.0.1, 客户端连 $dom:443 (源站端口不暴露)"
            fi
            printf '%s' "$dom"; return 0
        fi
    fi
    printf '%s' "$fb"
}
      # 注意: 调用方必须同时把端口换成 443 —— 只换域名不换端口会得到
      # 连不通的 域名:源站端口 组合 (源站端口只监听本地, CDN 只在 443 服务)

  # 该节点是否为 CDN 模式 (客户端产物走域名:443)
  sb_node_is_cdn() { sb_cdn_enabled "$1"; }

sb_cdn_domain() { # <配置文件> -> 证书里的域名
    local crt; crt=$(jq -r '.inbounds[0].tls.certificate_path // ""' "$1" 2>/dev/null)
    [[ -f "$crt" ]] || return 1
    openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null \
        | grep -oE 'DNS:[^ ,]+' | head -1 | cut -d: -f2
}

# 节点名后缀 —— 让用户从名字就能看出传输方式, 不用打开配置去分辨
#   reality  -> -REALITY
#   tls      -> -TLS        (自签 / 真证书的 TLS)
#   其他      -> -plain      (无 TLS)
# 例: reality01-REALITY, vless01-TLS, vmess01-plain
tag_form_suffix() {
    case "$1" in
        reality) printf -- "-REALITY" ;;
        tls)     printf -- "-TLS" ;;
        *)       printf -- "-plain" ;;
    esac
}

get_next_index() {
    local proto="$1" used=() i=1 base
    shopt -s nullglob
    for f in "$SB_CONFIG_DIR"/${proto}-*.json; do
        base=$(basename "$f")
        [[ "$base" =~ ^${proto}-([0-9]+)\.json$ ]] && used+=("${BASH_REMATCH[1]}")
    done
    shopt -u nullglob
    if ((${#used[@]} == 0)); then printf "01\n"; return; fi
    IFS=$'\n' used=($(printf "%s\n" "${used[@]}" | sort -n))
    for n in "${used[@]}"; do
        # 必须 10# 转十进制: 文件名捕获到的 "08"/"09" 前导零会被 bash 当八进制,
        # 直接比较会报 "value too great for base" 并让比较结果不可信
        (( 10#$n != 10#$i )) && break
        ((i++))
    done
    printf "%02d\n" "$i"
}

# 静默版 sing-box check: 只返回状态, 不打印。
# 用于"我先 check 一次 -> 回滚 -> 再 check 确认剩余配置是否干净"这类场景,
# 否则会出现 [Error] check 失败 紧跟 [OK] check 通过 的自相矛盾输出。
sb_check_quiet() {
    "$SB_BIN" check -D "$SB_ROOT" -C "$SB_CONFIG_DIR" >/dev/null 2>&1
}

# 写 config JSON + jq 校验，失败不落盘
write_config() { # write_config <path> <json-string>
    local path="$1" json="$2"
    if ! echo "$json" | jq -e . >/dev/null 2>&1; then
        print_error "JSON 语法校验失败，未写入 $path"
        echo "$json" | head -20 >&2
        return 1
    fi
    echo "$json" | jq . > "$path"
    return 0
}

# ---- 校验工具 ----
sb_check() { # 整目录校验，exit 0/1；错误输出到 stderr
    local out
    if [[ ! -x "$SB_BIN" ]]; then print_error "未找到 sing-box 二进制: $SB_BIN (先安装内核)"; return 1; fi
    if ! ls "$SB_CONFIG_DIR"/*.json >/dev/null 2>&1; then print_warn "配置目录为空: $SB_CONFIG_DIR"; return 1; fi
    out=$("$SB_BIN" check -D "$SB_ROOT" -C "$SB_CONFIG_DIR" 2>&1) || {
        print_error "sing-box check 失败:"
        echo "$out" | tail -15 >&2
        return 1
    }
    print_ok "sing-box check 通过 (全部配置合并合法)"
    return 0
}

sb_check_newbin() { # 用候选二进制校验当前配置（更新前测试）
    local newbin="$1" out
    [[ -x "$newbin" ]] || return 1
    out=$("$newbin" check -D "$SB_ROOT" -C "$SB_CONFIG_DIR" 2>&1) || {
        print_error "新内核无法加载当前配置:"
        echo "$out" | tail -15 >&2
        return 1
    }
    return 0
}

# ---- 备份（保留最近 5 份）----
backup_config() { # backup_config config|kernel|all
    local dir="$SB_BACKUP_DIR/$(date +%Y%m%d-%H%M%S)"
    case "$1" in
        config|all)  [[ -d "$SB_CONFIG_DIR" ]] && { mkdir -p "$dir/config"; cp -a "$SB_CONFIG_DIR"/. "$dir/config/"; } ;;
    esac
    case "$1" in
        kernel|all)  [[ -f "$SB_BIN" ]] && cp -a "$SB_BIN" "$dir/" ;;
    esac
    [[ -d "$dir" && -n "$dir" ]] && print_ok "已备份到 $dir"
    ls -dt "$SB_BACKUP_DIR"/*/ 2>/dev/null | tail -n +6 | xargs -r rm -rf
    return 0
}

# ---- 防火墙放行（ufw/firewall-cmd/iptables 三级回退）----
# 登记本面板放行过的端口; 卸载时 clean_fw 只按这份清单删除,
# 绝不扫描防火墙全表 (扫描会误删 SSH 等系统规则, 导致失联)
  # 防火墙后端探测 —— 决定放行/关闭规则写到哪去。
  #
  # 为什么要分得这么细: 原生 nft 规则与 iptables 规则**互不可见**。
  # 实测: 在 inet 表加一条原生 nft 规则后, `iptables -C INPUT` 完全查不到 ——
  # 因为 iptables(nf_tables 后端) 管的是 `table ip filter / chain INPUT`,
  # 而原生 nft 是 `table inet filter / chain input`, 表族和链名都不同。
  # 只认 iptables 的话, 换用原生 nft 后本面板的关端口一条都删不掉,
  # 节点删了端口还开着。
  fw_detect_backend() {
      # 有 inet filter 表 = 有组件在用原生 nft 管理防火墙
      if command -v nft >/dev/null 2>&1 \
         && nft list table inet filter >/dev/null 2>&1; then
          echo nft; return 0
      fi
      if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
          echo ufw; return 0
      fi
      if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
          echo firewalld; return 0
      fi
      if command -v iptables >/dev/null 2>&1; then
          echo iptables; return 0
      fi
      echo none
  }

  # 本面板在 nft 里加的规则一律带这个 comment; 关端口时只认带它的,
  # 绝不碰别的组件 (用户自己的 nftables.sh、fail2ban 等) 落在同一链上的规则。
  SB_NFT_COMMENT="SB_PANEL"
  # iptables 后端同样要打标记。之前只有 nft 分支带 comment, iptables 分支加的
  # 规则是光秃秃的 "-p tcp --dport N -j ACCEPT", 和用户自己加的规则**完全无法
  # 区分** —— 这就是历史上一批规则再也认不出归属、只能留成孤儿的原因。
  # 有了 comment, 以后任何时候都能精确找出"本面板加的、且现在没在用的"规则。
  SB_IPT_COMMENT="SB-Panel"
  # 该内核是否支持 -m comment (需要 xt_comment 模块)
  sb_iptables_comment_ok() {
      [[ -n "${SB_IPT_CMT_OK:-}" ]] && { [[ "$SB_IPT_CMT_OK" == "1" ]]; return; }
      if iptables -C SB_PANEL_PROBE -p tcp -m comment --comment probe -j RETURN 2>/dev/null; then
          SB_IPT_CMT_OK=1; return 0
      fi
      iptables -N SB_PANEL_PROBE 2>/dev/null && {
          if iptables -A SB_PANEL_PROBE -p tcp -m comment --comment probe -j RETURN 2>/dev/null; then
              iptables -F SB_PANEL_PROBE 2>/dev/null
              iptables -X SB_PANEL_PROBE 2>/dev/null
              SB_IPT_CMT_OK=1; return 0
          fi
          iptables -F SB_PANEL_PROBE 2>/dev/null; iptables -X SB_PANEL_PROBE 2>/dev/null
      }
      modprobe xt_comment >/dev/null 2>&1
      iptables -N SB_PANEL_PROBE 2>/dev/null && {
          if iptables -A SB_PANEL_PROBE -p tcp -m comment --comment probe -j RETURN 2>/dev/null; then
              iptables -F SB_PANEL_PROBE 2>/dev/null
              iptables -X SB_PANEL_PROBE 2>/dev/null
              SB_IPT_CMT_OK=1; return 0
          fi
          iptables -F SB_PANEL_PROBE 2>/dev/null; iptables -X SB_PANEL_PROBE 2>/dev/null
      }
      SB_IPT_CMT_OK=0; return 1
  }
  # 生成 (或空) iptables 的 comment 参数
  sb_ipt_cmt_args() {
      if sb_iptables_comment_ok; then
          printf '%s\n' -m comment --comment "$SB_IPT_COMMENT"
      fi
  }

  # ---------- 清理历史遗留的孤儿防火墙规则 ----------
  #
  # 为什么需要: 早期版本的 iptables 分支不加 comment, 规则和用户自己加的
  # 完全无法区分; 卸载时若面板没跑过 / 配置文件先被删掉, 规则就会永久留成孤儿。
  #
  # 分两类处理, 安全等级完全不同:
  #   [A] 带 SB-Panel 标记 —— 100% 确属本面板, 直接删, 无需确认;
  #   [B] 无标记的疑似遗留 —— 判据是: 规则形态与本面板加的完全一致
  #       (INPUT 链 + ACCEPT), 且该端口**当前没有任何进程在监听**,
  #       且不在本面板现在的节点端口表里, 且不是系统常用端口, 也不是 sshd。
  #       仍然列出完整清单要用户逐条过目, 输入 yes 才删。
  #
  # 关键安全阀: 端口正在监听的一律跳过。"正在被别的服务用"意味着有人管着它,
  # 不是孤儿, 哪怕形态像也得让人自己决定。
  sb_fw_scan_orphans() {
      SB_ORPHAN_MARKED=()      # "端口/tcp" 形式, 带标记
      SB_ORPHAN_LEGACY=()      # "端口/tcp" 形式, 无标记疑似
      local be; be=$(fw_detect_backend)
      local in_use="" p proto rule
      # 当前有进程监听的端口 —— 这些一律不当孤儿
      in_use=$(ss -Hltn 2>/dev/null | grep -oE ':[0-9]+[[:space:]]' | tr -d ' :' | sort -un)
      # 提取现有节点正在用的端口。
      # 注意: 不能用 awk -F'"listen_port"' 再 split($2," ") 取 a[1] ——
      # 拆出来的是 `: 20176},`, a[1] 是冒号而不是端口号, 结果一个都识别不到,
      # 现有节点的端口会被当成孤儿。这里直接用正则抓冒号后面的数字。
      local live_ports
      live_ports=$(grep -hoE '"listen_port"[[:space:]]*:[[:space:]]*[0-9]+' "$SB_CONFIG_DIR"/*.json 2>/dev/null \
                   | grep -oE '[0-9]+$' | sort -un)
      local -A seen=()
      if [[ "$be" == "iptables" ]]; then
          # 先把规则全部收进数组再遍历。
          # 原来写成 `while read -r rule; ... done < <(iptables -S ...)` 时,
          # 循环体内的 fw_port_is_ssh 里有不带 </dev/null 的 grep -q, 会把循环
          # 自己的 stdin (也就是还没读的规则) 读干净 —— 结果 390 条规则只处理
          # 了第 1 条就"结束"了, 只报出 1 条孤儿。数组遍历不受调用方 stdin 影响。
          local -a rules=()
          mapfile -t rules < <(iptables -S INPUT 2>/dev/null | grep -- "-j ACCEPT" | grep -E -- "--dport [0-9]+")
          for rule in ${rules[@]+"${rules[@]}"}; do
              [[ -n "$rule" ]] || continue
              proto=$(sed -nE 's/.*-p ([a-z]+).*/\1/p' <<<"$rule")
              p=$(sed -nE 's/.*--dport ([0-9]+).*/\1/p' <<<"$rule")
              [[ -n "$proto" && -n "$p" ]] || continue
              grep -qx "$p" <<<"$live_ports" && continue          # 现有节点在用
              grep -qx "$p" <<<"$in_use" && continue               # 有进程在监听
              fw_port_is_ssh "$p" </dev/null && continue             # sshd 碰不得
              case "$p" in
                  22|25|53|80|110|143|443|465|587|993|995|1433|1521|2049|3306|5432|6379|11211|27017) continue ;;
              esac
              [[ -n "${seen[$p$proto]:-}" ]] && continue
              seen[$p$proto]=1
              if grep -q "SB-Panel" <<<"$rule"; then
                  SB_ORPHAN_MARKED+=("$p/$proto")
              else
                  SB_ORPHAN_LEGACY+=("$p/$proto")
              fi
          done
      elif [[ "$be" == "nft" ]]; then
          while read -r p; do
              [[ -n "$p" ]] || continue
              grep -qx "$p" <<<"$live_ports" && continue
              grep -qx "$p" <<<"$in_use" && continue
              fw_port_is_ssh "$p" </dev/null && continue
              SB_ORPHAN_MARKED+=("$p/tcp")
          done < <(nft -a list chain inet filter input 2>/dev/null \
                   | grep "$SB_NFT_COMMENT" | grep -oE "dport [0-9]+" | awk '{print $2}' | sort -un)
      else
          return 1
      fi
      return 0
  }

  sb_fw_purge_orphans() { # 由菜单调用: 扫描 → 展示 → 确认 → 删除
      print_title "清理历史遗留的防火墙规则"
      if ! sb_fw_scan_orphans; then
          print_warn "未检测到可扫描的防火墙后端"
          return 1
      fi
      if (( ${#SB_ORPHAN_MARKED[@]} == 0 && ${#SB_ORPHAN_LEGACY[@]} == 0 )); then
          print_ok "没有发现遗留规则, 防火墙是干净的"
          return 0
      fi
      local p x d
      if (( ${#SB_ORPHAN_MARKED[@]} )); then
          print_warn "以下 ${#SB_ORPHAN_MARKED[@]} 条带 SB-Panel 标记, 确属本面板:"
          printf "    %s\n" "${SB_ORPHAN_MARKED[@]}" >&2
      fi
      local need_confirm=0
      if (( ${#SB_ORPHAN_LEGACY[@]} )); then
          need_confirm=1
          print_warn "以下 ${#SB_ORPHAN_LEGACY[@]} 条无标记, 形态与本面板早期加的规则一致:"
          printf "    %s\n" "${SB_ORPHAN_LEGACY[@]}" >&2
          print_warn "它们来自加注释功能之前的版本。已跳过: 当前节点在用的端口、"
          print_warn "有进程正在监听的端口、sshd、系统常用端口。"
          print_warn "仍可能包含你手工加的规则 —— 请对照上面的清单确认后再继续。"
      fi
      (( need_confirm )) || { print_ok "无需确认"; }
      if (( need_confirm )); then
          read -r -p "确认删除上面列出的全部规则? 输入 yes 继续: " d
          if [[ "$(echo "$d" | tr A-Z a-z)" != "yes" ]]; then
              print_warn "已取消, 未修改防火墙"
              return 0
          fi
      fi
      local be n=0
      be=$(fw_detect_backend)
      if [[ "$be" == "iptables" ]]; then
          for x in ${SB_ORPHAN_MARKED[@]+"${SB_ORPHAN_MARKED[@]}"} ${SB_ORPHAN_LEGACY[@]+"${SB_ORPHAN_LEGACY[@]}"}; do
              p="${x%/*}"
              iptables -D INPUT -p "${x##*/}" --dport "$p" -j ACCEPT 2>/dev/null && n=$((n+1))
          done
      elif [[ "$be" == "nft" ]]; then
          local h
          for p in ${SB_ORPHAN_MARKED[@]+"${SB_ORPHAN_MARKED[@]}"}; do
              p="${p%/*}"
              while read -r h; do
                  [[ "$h" =~ ^[0-9]+$ ]] || continue
                  nft delete rule inet filter input handle "$h" >/dev/null 2>&1 && n=$((n+1))
              done < <(nft -a list chain inet filter input 2>/dev/null \
                        | grep -E "dport ${p}([[:space:]]|$)" \
                        | grep -v 'UFW_PANEL_SSH' \
                        | grep -oE "handle [0-9]+" | awk '{print $2}')
          done
          fw_persist_nft
      fi
      print_ok "已删除 $n 条遗留规则 (后端 $be)"
      # 登记表里已经没有这些端口了, 顺手对齐, 避免下次 open_port 误判
      if [[ -f "$SB_ROOT/.fw-ports" ]]; then
          grep -vxE "$(printf '%s\n' ${SB_ORPHAN_MARKED[@]+"${SB_ORPHAN_MARKED[@]}"} ${SB_ORPHAN_LEGACY[@]+"${SB_ORPHAN_LEGACY[@]}"} | tr '/' ' ' | awk '{print $1}' | sort -un | tr '\n' '|' | sed 's/|$//')" \
              "$SB_ROOT/.fw-ports" > "$SB_ROOT/.fw-ports.tmp" 2>/dev/null \
              && mv -f "$SB_ROOT/.fw-ports.tmp" "$SB_ROOT/.fw-ports"
      fi
      return 0
  }

  # 生成完走 CDN 的节点后, 自动把 nginx 配好。
  #
  # 协议脚本 (vless/vmess) 只 source 了 lib.sh, 拿不到定义在 cdn_menu.sh 里的
  # cdn_autosetup, 所以这里做懒加载: 缺哪个文件补哪个, 再调用。
  # 单独跑 conf/cdn.sh 时它会 source 本文件, 所以这里不会反过来套娃。
  # 删节点后重建聚合产物。
  #
  # 以前 delete_config 只删单节点产物, 不管 out/sb_client-all.json, 于是聚合
  # 里一直留着已删除节点的 outbound —— 分享链接(菜单3 / all-share URL)会一直
  # 下发已经不存在的节点, 客户端导入后多出连不上的假节点。
  # 实测: trojan03 删掉很久了, 聚合里仍有它的条目。
  sb_regen_aggregate() {
      # SELF_DIR 由 sing-box.sh 定义; 协议脚本单独执行时为空, 所以这里从
      # lib.sh 自身位置反推 —— 否则 [[ -f "/conf/share.sh" ]] 直接假, 静默跳过。
      local d; d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      [[ -f "$d/share.sh" ]] || return 0
      bash "$d/share.sh" regen-aggregate >/dev/null 2>&1 || return 0
  }
  
  # 删节点后同步 nginx —— 否则站点配置里留着指向已删端口的 location,
  # 表现为 Cloudflare 回源 502, 而且要等到真有人访问那条路径才会暴露。
  # cdn_autosetup 会重新生成片段并替换旧块, 是幂等的。
  sb_resync_cdn() {
      local d; d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      [[ -f "$d/cdn_node.sh" && -f "$d/cdn.sh" ]] || return 0
      sb_cdn_autosetup
  }
  

  sb_cdn_autosetup() {
      local d; d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      # SELF_DIR = $SB_ROOT, 由 sing-box.sh 定义。协议脚本单独跑时没有它,
      # 而 cdn_auto_insert 内部用它拼 cdn_apply.py 的路径 —— 为空就会
      # "can't open file '/conf/cdn_apply.py'" 然后静默失败。
      [[ -n "${SELF_DIR:-}" ]] || SELF_DIR="$(cd "$d/.." && pwd)"
      export SELF_DIR
      declare -F cdn_autosetup >/dev/null 2>&1 || {
          # cdn.sh 里除了 source 那两个, 还自己定义 cdn_gen_nginx_conf 等,
          # 漏掉它会直接 "command not found"。三个都要, 缺一个都不行。
          [[ -f "$d/cdn_node.sh"  ]] && source "$d/cdn_node.sh"
          [[ -f "$d/cdn_nginx.sh"  ]] && source "$d/cdn_nginx.sh"
          [[ -f "$d/cdn.sh"       ]] && source "$d/cdn.sh"
          [[ -f "$d/cdn_menu.sh"  ]] && source "$d/cdn_menu.sh"
      }
      declare -F cdn_autosetup >/dev/null 2>&1 || {
          print_info "如需自动配置 Nginx, 请用菜单 10 → 1"
          return 0
      }
      cdn_autosetup
  }
  

fw_log_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 0
    mkdir -p "$SB_ROOT" 2>/dev/null
    grep -qxF "$port" "$SB_ROOT/.fw-ports" 2>/dev/null || echo "$port" >> "$SB_ROOT/.fw-ports" 2>/dev/null || true
}

open_port() {
      local port="$1"
      fw_log_port "$port"
      fw_unlog_closed_port "$port"
      local be; be=$(fw_detect_backend)
      case "$be" in
          nft)
              # 表/链不存在就建出来(装了原生 nft 防火墙但还没建表的场景)
              nft list table inet filter >/dev/null 2>&1 || nft add table inet filter 2>/dev/null
              nft list chain inet filter input >/dev/null 2>&1 || {
                  nft add chain inet filter input '{ type filter hook input priority 0; policy accept; }' 2>/dev/null
              }
              local proto
              for proto in tcp udp; do
                  nft list chain inet filter input 2>/dev/null \
                      | grep -qE "${proto} dport ${port} accept.*${SB_NFT_COMMENT}" \
                      || nft add rule inet filter input "$proto" dport "$port" accept \
                           comment "$SB_NFT_COMMENT" 2>/dev/null
              done
              print_ok "nft 已放行 $port (tcp+udp)"
              fw_persist_nft
              ;;
          ufw)
              ufw allow "$port/tcp" >/dev/null 2>&1
              ufw allow "$port/udp" >/dev/null 2>&1
              print_ok "ufw 已放行 $port (tcp+udp)"
              ;;
          firewalld)
              firewall-cmd --zone=public --add-port="$port/tcp" --permanent >/dev/null 2>&1
              firewall-cmd --zone=public --add-port="$port/udp" --permanent >/dev/null 2>&1
              firewall-cmd --reload >/dev/null 2>&1
              print_ok "firewalld 已放行 $port (tcp+udp)"
              ;;
          iptables)
              # 带上 SB-Panel 标记, 规则才可归属 (见 SB_IPT_COMMENT 处说明)。
              # 检查时也带上标记, 免得把用户自己加的同名规则误当成已存在。
              local -a cmt=()
              mapfile -t cmt < <(sb_ipt_cmt_args)
              if (( ${#cmt[@]} )); then
                  iptables -C INPUT -p tcp --dport "$port" "${cmt[@]}" -j ACCEPT 2>/dev/null \
                      || iptables -I INPUT -p tcp --dport "$port" "${cmt[@]}" -j ACCEPT 2>/dev/null
                  iptables -C INPUT -p udp --dport "$port" "${cmt[@]}" -j ACCEPT 2>/dev/null \
                      || iptables -I INPUT -p udp --dport "$port" "${cmt[@]}" -j ACCEPT 2>/dev/null
              else
                  iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
                  iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$port" -j ACCEPT
              fi
              if (( ${#cmt[@]} )); then
                  print_ok "iptables 已放行 $port (tcp+udp, 已标记 SB-Panel)"
              else
                  print_ok "iptables 已放行 $port (tcp+udp)"
                  print_warn "本机 iptables 不支持 -m comment, 规则无法自动标记"
              fi
              ;;
          *)
              print_warn "未检测到防火墙工具，请手动放行 $port"
              ;;
      esac
  }

  # 该端口是否正被 sshd 监听 —— 碰它就等于自断连接
  # ---- nft 规则持久化 ----
  #
  # nft 规则是内存态的: 动态 add 的规则重启就没了。用户自己的 nftables.sh
  # 靠它自己的 systemd 单元加载 zz-ufw-panel-dynamic.nft 解决持久化, 但那份
  # 文件不包含本面板开的端口 —— 所以切到 nft 后端后, 重启会丢掉我们所有规则。
  #
  # 这里自建一份规则文件和单元, 排在对方单元**之后**执行, 按登记表 (.fw-ports)
  # 重新落一遍 —— 登记表是唯一的真实来源, 因此文件与实际状态不会漂移。
  SB_NFT_OWN_FILE="/etc/nftables.d/zz-sb-panel.nft"
  # 脚本目录取 lib.sh 自身所在位置 —— SB_CONFIG_DIR 是 <root>/config,
  # 与 <root>/conf 同级, 不能拿它拼出脚本路径。
  SB_FW_APPLY="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/fw_apply.sh"
  SB_NFT_UNIT="sb-panel-nft.service"
  
  # 记录"本面板主动关掉过"的端口。
  # 对方那套 nftables.sh 会把链上规则扫进它自己的文件, 注释被抹掉; 我们关掉
  # 端口后那份文件里仍留着条目, 重启会被重新打开。开机时靠这份名单认领那些
  # 残留并清掉 (见 conf/fw_apply.sh)。
  fw_log_closed_port() {
      local port="$1" list="$SB_ROOT/.fw-closed-ports"
      [[ "$port" =~ ^[0-9]+$ ]] || return 0
      mkdir -p "$SB_ROOT" 2>/dev/null
      grep -qxF "$port" "$list" 2>/dev/null || echo "$port" >> "$list" 2>/dev/null || true
  }
  fw_unlog_closed_port() { # 端口重新被打开时撤销记账
      local port="$1" list="$SB_ROOT/.fw-closed-ports"
      [[ "$port" =~ ^[0-9]+$ ]] || return 0
      [[ -f "$list" ]] || return 0
      grep -vxF "$port" "$list" > "$list.tmp" 2>/dev/null && mv -f "$list.tmp" "$list"
  }
  
  fw_persist_nft() {
      command -v nft >/dev/null 2>&1 || return 0
      [[ "$(fw_detect_backend)" == "nft" ]] || return 0
      local be; be=$(fw_detect_backend)
      [[ "$be" == "nft" ]] || return 0
      local port tmp; tmp=$(mktemp)
      {
          echo "# 由 SB-Panel 自动生成 —— 请勿手改, 改动会在下次开/关节点时丢失"
          echo "table inet filter {"
          echo "  chain input {"
          # 系统常用端口一律不放行: 443 是用户自己的 nginx, 80/22 等同理。
          # 这些端口由各自的服务负责, 不该由节点放行逻辑接管。
          while read -r port; do
              [[ "$port" =~ ^[0-9]+$ ]] || continue
              case "$port" in 22|80|443|8443|3306|5432|6379|27017) continue ;; esac
              echo "    tcp dport $port accept comment \"SB_PANEL\""
              echo "    udp dport $port accept comment \"SB_PANEL\""
          done < <(sort -n "$SB_ROOT/.fw-ports" 2>/dev/null)
          echo "  }"
          echo "}"
      } > "$tmp"
      mkdir -p "$(dirname "$SB_NFT_OWN_FILE")" 2>/dev/null
      if ! install -m 0644 "$tmp" "$SB_NFT_OWN_FILE" 2>/dev/null; then
          cp -f "$tmp" "$SB_NFT_OWN_FILE" 2>/dev/null
      fi
      rm -f "$tmp"
      # 这里**只重写文件, 不做 nft -f**。
      # open_port 已经把规则加到链上了, 再加载一次文件会把同样的规则再加一遍
      # (nft -f 是追加语义, 不去重), 每开关一个端口就多一倍重复规则。
      # 文件只在开机时由 fw_apply.sh 加载一次。
      fw_install_nft_unit
      return 0
  }
  
  fw_install_nft_unit() {
      local unit="/etc/systemd/system/$SB_NFT_UNIT"
      [[ -f "$unit" ]] && return 0
      command -v nft >/dev/null 2>&1 || return 0
      # 用 printf 而非 heredoc: 嵌在函数里的 heredoc 终止符容易和调用方
      # 的 heredoc 撞车, 单元内容又需要 $SB_NFT_OWN_FILE 在生成时就展开。
      printf '%s\n' \
        '[Unit]' \
        "Description=SB-Panel nftables rules (regenerated from .fw-ports)" \
        'After=network.target nftables.service ufw-panel-nftables.service nftables-panel.service' \
        'Wants=nftables.service' \
        '' \
        '[Service]' \
        'Type=oneshot' \
        "ExecStart=/bin/sh $SB_FW_APPLY" \
        'RemainAfterExit=yes' \
        '' \
        '[Install]' \
        'WantedBy=multi-user.target' > "$unit" 2>/dev/null || return 0
      chmod 0644 "$unit" 2>/dev/null
      systemctl daemon-reload >/dev/null 2>&1
      systemctl enable "$SB_NFT_UNIT" >/dev/null 2>&1
  }


  fw_unlog_port() { # 从登记表移除 (不做任何系统改动)
      local port="$1" list="$SB_ROOT/.fw-ports"
      [[ "$port" =~ ^[0-9]+$ ]] || return 0
      [[ -f "$list" ]] || return 0
      grep -vxF "$port" "$list" > "$list.tmp" 2>/dev/null && mv -f "$list.tmp" "$list"
  }


fw_port_is_ssh() {
      local port="$1"
      # ss 的一行形如: LISTEN 0 128 0.0.0.0:6541 0.0.0.0:* users:(("sshd",pid=837,fd=6))
      # 进程名在端口**后面**, 所以不能写成 "sshd.*:PORT" —— 那样永远匹配不到,
      # 安全网会形同虚设。必须同一行里既出现该监听端口, 又出现 sshd。
      if command -v ss >/dev/null 2>&1; then
          ss -Hltnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | grep -q "sshd" </dev/null && return 0
      fi
      # 兜底1: sshd 自己的配置
      if [[ -r /etc/ssh/sshd_config ]]; then
          grep -qiE "^[[:space:]]*Port[[:space:]]+${port}([[:space:]]|$)" /etc/ssh/sshd_config && return 0
      fi
      # 兜底2: 防火墙里被标成 SSH 的放行规则 (含原生 nft)
      if command -v nft >/dev/null 2>&1; then
          nft list ruleset 2>/dev/null | grep -iE "dport ${port} accept" | grep -qi "ssh" </dev/null && return 0
      fi
      if command -v iptables >/dev/null 2>&1; then
          iptables -S 2>/dev/null | grep -E -- "--dport ${port} " | grep -qi "ssh\|SSH" && return 0
      fi
      return 1
  }

close_node_port() { # <端口> <节点tag>  —— 只关"确认属于该节点"的端口
      local port="$1" tag="${2:-}"
      [[ "$port" =~ ^[0-9]+$ ]] || return 0
      # 不在登记名单里的, 说明本面板没为它开过规则, 不该由本面板去关
      if ! grep -qxF "$port" "$SB_ROOT/.fw-ports" 2>/dev/null; then
          fw_unlog_port "$port"
          return 0
      fi
      if fw_port_is_ssh "$port"; then
          print_warn "端口 $port 正被 sshd 使用, 跳过关闭 (防失联)"
          return 0
      fi
      case "$port" in
          22|80|443|8443|3306|5432|6379|27017) fw_unlog_port "$port"; return 0 ;;
      esac
      local acted=0
      local be; be=$(fw_detect_backend)
      case "$be" in
          nft)
              # 关掉这个端口 = 删掉链上**所有**针对它、且不是 SSH 的规则。
              #
              # 为什么不能只删带 SB_PANEL 标记的: 用户自己那套 nftables.sh 的
              # persist_dynamic_ports() 会把链上所有 "dport N accept" 的规则扫走,
              # 去掉注释写进它自己的文件, 于是我们的规则会多出一份无标记副本。
              # 只删带标记的那条, 无标记副本会留下来 —— 端口看着关了, 其实还开着。
              #
              # 安全性来自调用侧: 只有"本面板确实开过、且随节点一起删掉"的端口
              # 才会走到这里 (来自 .fw-ports 登记表), 所以按端口整体清理是正确的。
              # SSH 规则仍然逐条排除, 那是唯一不能碰的。
              local h
              while read -r h; do
                  [[ "$h" =~ ^[0-9]+$ ]] || continue
                  nft delete rule inet filter input handle "$h" >/dev/null 2>&1 && acted=1
              done < <(nft -a list chain inet filter input 2>/dev/null \
                        | grep -E "dport ${port}([[:space:]]|$)" \
                        | grep -v 'UFW_PANEL_SSH' \
                        | grep -oE "handle [0-9]+" | awk '{print $2}')
              # 注: nft -a 的行尾是 "# handle 2", # 后面跟的是空格而不是数字,
              # 所以不能写成 grep -oE "#[0-9]+" —— 那永远匹配不到, 会导致
              # 一条都删不掉却报"未找到规则"。
              ;;
          ufw)
              ufw delete allow "$port/tcp" >/dev/null 2>&1 && acted=1
              ufw delete allow "$port/udp" >/dev/null 2>&1 && acted=1
              ;;
          firewalld)
              firewall-cmd --zone=public --remove-port="$port/tcp" --permanent >/dev/null 2>&1 && acted=1
              firewall-cmd --zone=public --remove-port="$port/udp" --permanent >/dev/null 2>&1 && acted=1
              firewall-cmd --reload >/dev/null 2>&1
              ;;
          iptables)
              # 带标记的先删(本面板自己加的), 再退回到无标记的老规则。
              # 老版本加的规则没有 comment, 只能按端口删 —— 之所以敢这么删,
              # 是因为调用侧已确认该端口在 .fw-ports 登记表里 (确属本面板开的)。
              local proto
              local -a cmt=()
              mapfile -t cmt < <(sb_ipt_cmt_args)
              for proto in tcp udp; do
                  if (( ${#cmt[@]} )); then
                      iptables -C INPUT -p "$proto" --dport "$port" "${cmt[@]}" -j ACCEPT 2>/dev/null \
                          && { iptables -D INPUT -p "$proto" --dport "$port" "${cmt[@]}" -j ACCEPT 2>/dev/null && acted=1; continue; }
                  fi
                  if iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
                      iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null && acted=1
                  fi
              done
              ;;
      esac
      fw_unlog_port "$port"
      [[ "$be" == "nft" ]] && fw_log_closed_port "$port"
      [[ "$be" == "nft" ]] && fw_persist_nft
      if (( acted )); then
          print_ok "已关闭防火墙端口 $port${tag:+ (原属 $tag, 后端 $be)}"
      else
          print_info "后端 $be 未找到本面板对该端口的规则, 仅从登记表移除 $port${tag:+ (原属 $tag)}"
      fi
      return 0
  }

# ---- 服务 ----
sb_service_active() { systemctl is-active "$SB_SERVICE" >/dev/null 2>&1; }

sb_reload() { # 应用新配置: check 通过才重启
    if [[ -n "${SB_NO_RELOAD:-}" ]]; then
        print_ok "批量模式: 跳过本次 reload (由全协议生成收尾统一执行)"
        return 0
    fi
    if ! sb_check; then
        print_error "校验失败，已放弃重载（当前运行实例未受影响）"
        return 1
    fi
    if ! sb_service_active; then
        print_warn "服务未运行，改为启动"
        systemctl start "$SB_SERVICE" && sleep 1
        if sb_service_active; then print_ok "服务已启动"; return 0; fi
        print_error "服务启动失败"; return 1
    fi
    # 必须 restart, 不能靠 SIGHUP。
    #
    # unit 里写的是 ExecReload=/bin/kill -HUP $MAINPID, 而 sing-box **不支持**
    # SIGHUP 热重载 —— 它没有 reload 子命令, 收到 SIGHUP 不会重读配置。
    # 但 kill 本身返回 0, 所以 `systemctl reload` 永远"成功", 旧代码据此
    # 打印"已通过 SIGHUP 软重载(零断流)"就返回了, 新配置其实**根本没生效**。
    #
    # 实测: 配置文件里 anytls 端口已是 25959, 运行中的实例仍在拨 20478;
    # 执行 systemctl reload 返回 0、进程 PID 不变、行为完全不变。
    # 也就是说"加节点/删节点/改节点"在不重启的情况下全是空操作, 面板一路
    # 显示成功, 用户却看不到任何变化 —— 这是最坏的一类假成功。
    #
    # sing-box 没有热重载能力, 所以这里只能 restart。
    if systemctl restart "$SB_SERVICE" 2>/dev/null; then
        sleep 1
        if sb_service_active; then
            print_ok "已重启生效 (sing-box 不支持 SIGHUP 热重载, 只能重启)"
            return 0
        fi
    fi
    print_error "服务异常，请查看 journalctl -u $SB_SERVICE"
    journalctl -u "$SB_SERVICE" -n 10 --no-pager 2>/dev/null | tail -10 >&2
    return 1
}

sb_restart() {
    systemctl restart "$SB_SERVICE"
    sleep 1
    if sb_service_active; then print_ok "$SB_SERVICE 已重启 (active)"; return 0; fi
    print_error "$SB_SERVICE 重启失败"
    journalctl -u "$SB_SERVICE" -n 10 --no-pager 2>/dev/null | tail -10 >&2
    return 1
}

sb_journal() { journalctl -u "$SB_SERVICE" -n "${1:-50}" --no-pager; }

sb_current_version() { "$SB_BIN" version 2>/dev/null | head -1 | awk '{print $3}'; }

sb_latest_version() {
    curl -s --max-time 10 "$SB_REPO_API/releases/latest" | jq -r '.tag_name // empty' | sed 's/^v//'
}

# ---- 统一 Reality 域名来源（mi1314cat/One-click-script domains.sh）----
# 运行时拉取并抽取 domains 数组 + random_website()，不本地复制数据
SB_DOMAINS_SH_URL="${SB_DOMAINS_SH_URL:-https://raw.githubusercontent.com/mi1314cat/One-click-script/main/domains.sh}"

reality_random_domain() {
    local tmp
    tmp=$(curl -fsSL --max-time 15 "$SB_DOMAINS_SH_URL" 2>/dev/null) || true
    [[ -z "$tmp" ]] && { print_warn "拉取 domains.sh 失败，回退 oracle.com"; echo "www.oracle.com"; return; }
    # 在受控子 shell 中抽取 random_website()（跳过文件尾部的交互 read/update_env 尾巴）
    local fn
    fn=$(printf '%s\n' "$tmp" | awk '/^random_website\(\) \{/{f=1} f{print; if (/^\}/) exit}')
    bash -c "$fn; random_website" 2>/dev/null
}

# ---- 自签证书 SPKI pin (兼容 fscarmen 的 sha256(SPKI) 分享习惯) ----
cert_pin_sha256() { openssl x509 -in "$1" -outform der 2>/dev/null | sha256sum | awk '{print tolower($1)}'; }

# sing-box 客户端 tls.certificate_public_key_sha256 期望: base64(sha256(SPKI DER))
# ---- uTLS 指纹选配 ----
# 取值不是抄文档: 用 sing-box 1.14.2 内核逐个 `sing-box check` 实测出来的。
# 实测接受 10 个; randomized-noalpn / safari-ios / ios_simulator /
# firefox_mozilla / opera / chrome_v2 全部被内核拒绝 (check 退出码非 0)。
# mihomo 的 -t 不校验这个字段 (连乱写都放行), 所以以 sing-box 为准,
# 取两者都支持的子集, 保证 sing-box / mihomo 双端产物都合法。
SB_UTLS_FINGERPRINTS=(chrome firefox edge safari 360 qq ios android random randomized)
SB_DEFAULT_UTLS_FP="chrome"

ask_utls_fingerprint() { # 输出 uTLS 指纹; 默认 chrome, 非法输入回落 chrome
    local c
    if [[ -n "${SB_BATCH:-}" ]]; then
        echo "$SB_DEFAULT_UTLS_FP"; return
    fi
    {
        echo "uTLS 指纹 (ClientHello 伪装):" >&2
        local i=1 v
        for v in "${SB_UTLS_FINGERPRINTS[@]}"; do
            local mark=" "; [[ "$v" == "$SB_DEFAULT_UTLS_FP" ]] && mark="*"
            printf "  %s%d) %s\n" "$mark" "$i" "$v" >&2
            i=$(( i + 1 ))
        done
        echo "  * = 默认; 直接回车即选 chrome" >&2
    }
    read -r -p "请选择 [1-${#SB_UTLS_FINGERPRINTS[@]}], 回车=chrome]: " c
    c=$(clean_input "$c")
    [[ -z "$c" ]] && { echo "$SB_DEFAULT_UTLS_FP"; return; }
    if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#SB_UTLS_FINGERPRINTS[@]} )); then
        echo "${SB_UTLS_FINGERPRINTS[$(( c - 1 ))]}"
        return
    fi
    # 也允许直接输入英文名
    for v in "${SB_UTLS_FINGERPRINTS[@]}"; do
        if [[ "${c,,}" == "$v" ]]; then echo "$v"; return; fi
    done
    print_warn "无法识别的指纹 '$c', 回落默认: $SB_DEFAULT_UTLS_FP" >&2
    echo "$SB_DEFAULT_UTLS_FP"
}

cert_spki_pin_base64() {
    openssl x509 -in "$1" -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform der 2>/dev/null \
        | openssl dgst -sha256 -binary 2>/dev/null | base64 -w0
}


# ==============================================================
# 统一 TLS 证书设施 (对齐 xary-core hysteria2.sh ask_cert 的语义)
#   SB_ask_cert 输出: CERT_FILE, KEY_FILE, CERT_DOMAIN, CERT_TRUSTED
#   1) 扫描本机已有证书 (ACME/nginx/CF Origin/ca 可信) 2) 手动路径 3) 自签
# ==============================================================
SB_CERT_SCAN_PIDIR="/etc/letsencrypt/live"
cert_not_expired() { openssl x509 -in "$1" -noout -checkend 86400 >/dev/null 2>&1; }
sb_has_key_for() {
    local crt="$1" k
    for k in "${crt%_cert.pem}_key.pem" "${crt%.pem}_key.pem" "${crt%.crt}.key" "${crt%.pem}.key" "${crt%.pem}_privkey.pem"; do
        [[ -f "$k" ]] && { echo "$k"; return 0; }
    done
    return 1
}
sb_scan_certs() {
    local dirs=() lbls=() src cid f
    # 1) 统一 cert 目录 (catmi 主目录)
    [[ -d "$SB_ROOT/cert" ]] && { dirs+=("$SB_ROOT/cert"); lbls+=("sb-cert-dir"); }
    # 2) certbot/ACME 正式目录 (真实域 CA 可信, 特别适合 naive/vmess)
    if [[ -d /etc/letsencrypt/live ]]; then
        for f in /etc/letsencrypt/live/*/*_cert.pem; do [[ -f "$f" ]] && { dirs+=("$f" ""); lbls+=("certbot"); }; done 2>/dev/null
    fi
    # 3) acme.sh 默认目录
    [[ -d /root/.acme.sh ]] && dirs+=("/root/.acme.sh") && lbls+=("acme.sh")
    # 4) nginx / cloudflare / docker
    [[ -d /etc/nginx/certs ]] && dirs+=("/etc/nginx/certs") && lbls+=("nginx-certs")
    [[ -d /root/catmi/cloudflare/certs ]] && dirs+=("/root/catmi/cloudflare/certs") && lbls+=("catmi/cloudflare-certs")
    if command -v docker >/dev/null 2>&1; then
        for cid in $(docker ps -q 2>/dev/null); do
            src=$(docker inspect "$cid" --format '{{range .Mounts}}{{if eq .Destination "/etc/nginx/certs"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
            [[ -z "$src" && -d /etc/nginx/certs ]] && src="/etc/nginx/certs"
            [[ -n "$src" ]] && { dirs+=("$src"); lbls+=("docker-nginx($cid)"); }
        done
    fi
    sb_FOUND_CERTS=()
    local lbl idx
    for ((i=0; i<${#dirs[@]}; i++)); do
        lbl="${lbls[$i]}"
        for f in "${dirs[$i]}"/*.crt "${dirs[$i]}"/*.pem "${dirs[$i]}"/*/*_cert.pem; do
            [[ -f "$f" ]] || continue
            case "$f" in *CA*|*ca.crt) continue ;; esac
            # 排除 CA 证书
            openssl x509 -in "$f" -noout -text 2>/dev/null | grep -q "CA:TRUE" && continue
            local k
            k=$(sb_key_for "$f") || true
            [[ -n "$k" && -f "$k" ]] && cert_not_expired "$f" && sb_FOUND_CERTS+=("${f}|${k}|${lbl}")
        done 2>/dev/null
    done
    # certbot live 目录单独处理 (fullchain/privkey 命名 特殊)
    for f in /etc/letsencrypt/live/*/fullchain.pem; do
        [[ -f "$f" ]] || continue
        sb_FOUND_CERTS+=("$f|$(dirname "$f")/privkey.pem|certbot-live")
    done 2>/dev/null
    # 去重 (find key)
    if ((${#sb_FOUND_CERTS[@]} == 0)); then return 1; fi
    return 0
}
sb_key_for() {  # sb_scan_certs 的 key 匹配 (规则与 ask_cert 一致)
    local crt="$1"
    local k
    for k in "${crt%_cert.pem}_key.pem" "${crt%.pem}_key.pem" "${crt%.crt}.key" "${crt%.pem}.key" "${crt%.crt}_key.pem" "${crt%.pem}_key.pem"; do
        [[ -f "$k" ]] && { echo "$k"; return 0; }
    done
    return 1
}
extract_cert_domain() {
    local f dom
    if command -v openssl >/dev/null 2>&1 && [[ -f "$1" ]]; then
        dom=$(openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | grep -oE 'DNS:[^,]+' | head -1 | cut -d: -f2)
        [[ -z "$dom" ]] && dom=$(openssl x509 -in "$1" -noout -subject 2>/dev/null | grep -oE 'CN *= *[^,]+' | head -1 | sed 's/CN *= *//')
    fi
    [[ -z "$dom" ]] && dom=$(basename "$1" | sed -E 's/\.(crt|pem)$//; s/_cert$//; s/^cert-//')
    echo "$dom"
}
sb_ask_cert() {
    export CERT_FILE KEY_FILE CERT_DOMAIN CERT_TRUSTED
    local choice f k c pick have=0
    echo "  证书方案：
        1) 扫描本机已有证书 (certbot/acme/nginx; CA 可信)
        2) 手动输入路径
        3) 生成自签 (200天, 客户端经 SPKI pin)" >&2
    read -r -p "  选择 (默认1): " c; c=$(clean_input "$c"); [[ -z "$c" ]] && c=1
    case "$c" in
        2)
            read -r -p "  crt 路径: " f; read -r -p "  key 路径: " k
            f=$(clean_input "$f"); k=$(clean_input "$k")
            [[ -f "$f" && -f "$k" ]] || { print_error "路径无效, 改用自签"; sb_selfgen_cert; return $?; }
            CERT_FILE=$f; KEY_FILE=$k; CERT_DOMAIN=$(extract_cert_domain "$f")
            cert_not_expired "$f" || { print_warn "证书已过期! 退回自签"; sb_selfgen_cert; return $?; }
            CERT_TRUSTED=true; return 0 ;;
        3) sb_selfgen_cert; return $? ;;
    esac
    sb_scan_certs || { print_warn "未发现可用证书, 改用自签"; sb_selfgen_cert; return $?; }
    local i=1 pair usable
    for pair in "${sb_FOUND_CERTS[@]}"; do
        f="${pair%%|*}"; k="${pair#*|}"; k="${k%%|*}"
        echo -e "    ${GREEN}$i${RESET}) ${YELLOW}$(extract_cert_domain "$f")${RESET} (${CYAN}${pair##*|}${RESET})" >&2
        have=1; ((i++))
    done
    echo -e "    ${CYAN}$i${RESET}) 手动输入路径" >&2
    echo -e "    ${CYAN}$((i+1))${RESET}) 生成自签" >&2
    read -r -p "  选择 (默认1): " pick; pick=$(clean_input "$pick"); [[ -z "$pick" ]] && pick=1
    if [[ $pick == "$i" ]]; then
        read -r -p "  crt: " f; read -r -p "  key: " k
        f=$(clean_input "$f"); k=$(clean_input "$k")
        [[ -f "$f" && -f "$k" ]] || { print_error "路径无效"; sb_selfgen_cert; return $?; }
        CERT_FILE=$f; KEY_FILE=$k; CERT_DOMAIN=$(extract_cert_domain "$f"); CERT_TRUSTED=true; return 0
    elif [[ $pick == $((i+1)) ]]; then sb_selfgen_cert; return $?
    else
        pair="${sb_FOUND_CERTS[$((pick-1))]:-}"
        [[ -z "$pair" ]] && { sb_selfgen_cert; return $?; }
        CERT_FILE="${pair%%|*}"; CERT_FILE="${CERT_FILE%%|*}"
        KEY_FILE="${pair#*|}"; KEY_FILE="${KEY_FILE%%|*}"
        CERT_DOMAIN=$(extract_cert_domain "$CERT_FILE"); CERT_TRUSTED=true
        return 0
    fi
}
sb_selfgen_cert() {
    export CERT_FILE KEY_FILE CERT_DOMAIN CERT_TRUSTED
    mkdir -p "$CERT_DIR"
    # 统一伪装域名: 优先 domains.sh 拉取, 失败才本地随机
    local d
    command -v reality_random_domain >/dev/null 2>&1 && d=$(reality_random_domain) || d=$(tr -dc a-z0-9 </dev/urandom | head -c 8).example.com
    CERT_FILE="$CERT_DIR/cert-$d.crt"; KEY_FILE="$CERT_DIR/key-$d.key"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes         -keyout "$KEY_FILE" -out "$CERT_FILE" -days 200 -subj "/CN=$d" -addext "subjectAltName=DNS:$d" >/dev/null 2>&1
    [[ -f "$CERT_FILE" ]] || { print_error "自签证书生成失败"; return 1; }
    CERT_DOMAIN="$d"; CERT_TRUSTED=false
    print_ok "自签证书 (pin 认证): $d (crt/key 已生成)"
}

# ---- QA: 节点删除后清理其分享 token, 并刷新 all 聚合 ----
cleanup_node_shares() { # cleanup_node_shares <tag>
    local tag="$1" f
    [[ -n "$tag" && -d "$SB_OUT_DIR/../share/shares" ]] || return 0
    local SHARES_DIR="$SB_ROOT/share/shares"
    for f in "$SHARES_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        [[ "$(jq -r .tag "$f" 2>/dev/null)" == "$tag" ]] && rm -f "$f"
    done
    # 若存在 all 分享, 刷新聚合文件 (token 不变, 内容即时更新)
    for f in "$SHARES_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        if [[ "$(jq -r .tag "$f" 2>/dev/null)" == "all" ]]; then
            bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/share.sh" regen-aggregate >/dev/null 2>&1
            break
        fi
    done
    return 0
}


# ---- 批量模式: 覆盖 bash 内置 read ----
# add_config 内编号/选择 read 返回空串 → 各协议自身的 [[ -z ]]&&默认 逻辑接管
# 防空转 (事故复盘 2026-09-21 RN): 连续 N 次(默认 32)注入"空答案"仍未正常推进 → 认定是菜单循环误入, 强制 exit.
if [[ "${SB_BATCH:-}" == "1" ]]; then
    _SB_BARE_READ_SEQ=0
    read() {
        local p="" var
        while (( $# )); do
            case "$1" in
                -r) shift ;;
                -p) p="$2"; shift 2 ;;
                -*) shift ;;
                *) break ;;
            esac
        done
        var="$1"
        printf '%s (batch→默认)\n' "${p:-读取}" >&2
        if [[ -n "${SB_BATCH_ANSWERS:-}" ]]; then
            local first="${SB_BATCH_ANSWERS%%;*}"
            printf -v "$var" '%s' "$first"
            if [[ "$SB_BATCH_ANSWERS" == *";"* ]]; then
                SB_BATCH_ANSWERS="${SB_BATCH_ANSWERS#*;}"
            else
                unset SB_BATCH_ANSWERS
            fi
            export SB_BATCH_ANSWERS
            _SB_BARE_READ_SEQ=0
            return 0
        fi
        printf -v "$var" '%s' ""
        _SB_BARE_READ_SEQ=$(( _SB_BARE_READ_SEQ + 1 ))
        if (( _SB_BARE_READ_SEQ > ${SB_BATCH_READ_LIMIT:-32} )); then
            print_error "batch 模式连续 ${SB_BATCH_READ_LIMIT:-32} 次空读取 (疑似交互菜单循环). 防止 CPU/磁盘空转 > 事故复盘处置, 强制退出."
            exit 0
        fi
        return 0
    }
fi

# ==============================================================
# 提示输入 —— bash 的 `read -p` 只在 stdin 是终端时才显示提示,
# 一旦被管道/自动化驱动就完全不可见, 用户(或测试者)会"输入了却不知道在输什么"。
# 面板统一改为显式写 stderr, 保证任何环境下都有指引。
# ==============================================================
sb_ask() { # sb_ask <提示> -> 结果写入全局 REPLY; 返回 read 的状态
    local _rc
    printf "%s" "$1" >&2
    read -r REPLY
    _rc=$?
    REPLY=$(clean_input "$REPLY")
    # 必须透传 read 的退出状态: 否则 stdin 提前结束(EOF)与"用户回车用默认"无法区分,
    # 依赖默认值的确认框会在无人确认的情况下写盘 (fail-open)。
    return "$_rc"
}

sb_ask_loop() { # 在 while 循环里用: 读不到输入(EOF)立即放弃整个操作, 不再空转
    # sb_ask 在 EOF 时返回非 0, 但循环里若忽略返回值就会以 ~150 行/秒 无限刷屏
    # (外推 50 万行/小时), 只能靠外部 timeout 杀掉。
    if ! sb_ask "$1"; then
        print_warn "输入已结束, 已放弃当前操作"
        return 1
    fi
    return 0
}

# ==============================================================
# rule-set 公共设施 —— dns.sh 与 ruleset.sh 共用
#
# 根因: 02-rule-set.json 可能由任一模块先创建 (ruleset.sh 只建空数组),
#       dns.sh 却只判断"文件是否存在"就认为规则集已就绪。于是
#       01-dns.json 引用 geosite-category-ads-all / geosite-cn,
#       而 02-rule-set.json 里一个 tag 都没定义 ->
#       FATAL initialize dns router: rule-set not found: geosite-category-ads-all
#       而面板每次写盘都要先过 sing-box check, 于是所有写操作全部回滚,
#       一次只能加一个规则集也永远修不好 (鸡生蛋死锁)。
# 修法: 一律按 tag 幂等自愈, 且一次把缺失的 tag 全部补齐。
# ==============================================================
SB_RS_FILE="${SB_RS_FILE:-$SB_CONFIG_DIR/02-rule-set.json}"
SB_HTTP_FILE="${SB_HTTP_FILE:-$SB_CONFIG_DIR/00-http.json}"
SB_HTTP_CLIENT_TAG="${SB_HTTP_CLIENT_TAG:-http-direct}"
SB_GEOSITE_BASE="${SB_GEOSITE_BASE:-https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set}"

sb_geosite_url() { echo "$SB_GEOSITE_BASE/$1.srs"; }

sb_ruleset_defined() { # <tag> -> 0 已定义 / 1 未定义
    local t="$1"
    [[ -f "$SB_RS_FILE" ]] || return 1
    jq -e --arg t "$t" 'any(.route.rule_set[]?; .tag==$t)' "$SB_RS_FILE" >/dev/null 2>&1
}

sb_ensure_http_client() { # remote rule-set 在 1.14 走 http_client (download_detour 已废弃)
    if [[ ! -f "$SB_HTTP_FILE" ]]; then
        write_config "$SB_HTTP_FILE" '{"http_clients":[{"tag":"'"$SB_HTTP_CLIENT_TAG"'"}]}' || return 1
        print_ok "已创建 http_client 定义: $SB_HTTP_FILE"
        return 0
    fi
    if jq -e --arg t "$SB_HTTP_CLIENT_TAG" 'any(.http_clients[]?; .tag==$t)' "$SB_HTTP_FILE" >/dev/null 2>&1; then
        return 0
    fi
    if write_config "$SB_HTTP_FILE" "$(jq --arg t "$SB_HTTP_CLIENT_TAG" '.http_clients = ((.http_clients // []) + [{"tag":$t}])' "$SB_HTTP_FILE")"; then
        print_ok "已补齐 http_client: $SB_HTTP_CLIENT_TAG ($SB_HTTP_FILE)"
        return 0
    fi
    print_error "无法在 $SB_HTTP_FILE 中写入 http_client"
    return 1
}

# 把仍用 download_detour 的条目迁到 http_client (1.14 已废弃前者)
sb_migrate_ruleset_detour() { # <tag> -> 0 已迁移 / 1 无需迁移
    local tag="$1"
    jq -e --arg t "$tag" 'any(.route.rule_set[]?; .tag==$t and (.download_detour? != null) and (.http_client? == null))' \
        "$SB_RS_FILE" >/dev/null 2>&1 || return 1
    sb_ensure_http_client || return 1
    jq --arg t "$tag" --arg hc "$SB_HTTP_CLIENT_TAG" '
        .route.rule_set |= map(
            if (.tag==$t and (.download_detour? != null) and (.http_client? == null))
            then (. + {http_client:$hc} | del(.download_detour)) else . end)' \
        "$SB_RS_FILE" > "$SB_RS_FILE.tmp" && mv "$SB_RS_FILE.tmp" "$SB_RS_FILE" || return 1
    print_ok "规则集 $tag: download_detour -> http_client ($SB_HTTP_CLIENT_TAG)"
    return 0
}

sb_ensure_ruleset() { # <tag> <url> [format] [interval] —— 幂等, 已存在不动
    local tag="$1" url="$2" fmt="${3:-binary}" iv="${4:-1d}" entry
    sb_rs_healthy || sb_repair_rs_file || return 1
    if sb_ruleset_defined "$tag"; then
        sb_migrate_ruleset_detour "$tag" || true
        return 0
    fi
    sb_ensure_http_client || return 1
    entry=$(jq -n --arg tag "$tag" --arg url "$url" --arg fmt "$fmt" --arg iv "$iv" --arg hc "$SB_HTTP_CLIENT_TAG" \
        '{type:"remote",tag:$tag,format:$fmt,url:$url,http_client:$hc,update_interval:$iv}')
    if ! write_config "$SB_RS_FILE" "$(jq --argjson e "$entry" '.route.rule_set = ((.route.rule_set // []) + [$e])' "$SB_RS_FILE")"; then
        print_error "规则集定义写入失败: $tag"
        return 1
    fi
    print_ok "已补齐规则集定义: $tag -> $(basename "$url")"
    return 0
}

# 删除 rule-set 前, 报告它还被哪些文件引用 (避免删完留下必然 check 失败的配置)
# 注意: 02-rule-set.json 里 tag 自身的"定义"不是引用, 统计前先 del 掉 .route.rule_set,
#       否则每个规则集都会被误报成"被自己引用"。
sb_ruleset_refs() { # <tag> -> 逐行 "文件 引用 N 处"
    local tag="$1" f n
    shopt -s nullglob
    for f in "$SB_CONFIG_DIR"/*.json; do
        # 注意别写成 paths(..|select(...)): 那会让 .. 嵌套 .. , 每处引用按祖先层数被重复计数
        n=$(jq -r --arg t "$tag" 'del(.route.rule_set) | [.. | select(type=="string" and .==$t)] | length' "$f" 2>/dev/null) || n=0
        [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) && echo "  $(basename "$f")  引用 $n 处"
    done
    shopt -u nullglob
    return 0
}

# ---- rule-set 文件健康检查 / 自愈 ----
# 02-rule-set.json 一旦被手工改坏(jq 解析不了), 面板所有 jq 操作都会静默失败,
# 界面上只剩一句原始的 "jq: parse error"。这里提供统一检测与两条修复路径。
SB_RS_DEFAULT_TAGS="geosite-category-ads-all geosite-cn"

sb_rs_healthy() { # 0=可解析 / 1=缺失或损坏
    [[ -f "$SB_RS_FILE" ]] || return 1
    jq -e . "$SB_RS_FILE" >/dev/null 2>&1
}

sb_repair_rs_file() { # 尝试修复: 先从最近备份恢复, 失败则重建默认预设
    local b
    for b in $(ls -dt "$SB_BACKUP_DIR"/*/config/02-rule-set.json 2>/dev/null | head -5); do
        if jq -e . "$b" >/dev/null 2>&1; then
            cp -f "$b" "$SB_RS_FILE" || continue
            print_ok "已从备份恢复规则集定义: $b"
            return 0
        fi
    done
    write_config "$SB_RS_FILE" '{"route":{"rule_set":[]}}' || return 1
    local t
    for t in $SB_RS_DEFAULT_TAGS; do
        sb_ensure_ruleset "$t" "$(sb_geosite_url "$t")" binary 1d || return 1
    done
    print_ok "已重建规则集定义 (默认预设: $SB_RS_DEFAULT_TAGS)"
    return 0
}

sb_guard_rs() { # 菜单入口守门: 损坏时先修复再继续
    sb_rs_healthy && return 0
    print_error "规则集定义文件异常: $SB_RS_FILE (不存在或 JSON 损坏)"
    local a
    printf "  1) 从最近备份恢复 / 重建默认预设 (推荐)\n  2) 取消\n" >&2
    sb_ask "  选择 (默认 1): "
    [[ "$REPLY" =~ ^2 ]] && return 1
    sb_repair_rs_file || { print_error "自动修复失败, 请人工检查 $SB_RS_FILE"; return 1; }
    return 0
}

# rule-set 定义被删掉又重新加回时, 01-dns.json 里引用它的规则不会自动回来
# (例如删掉 geosite-cn 再加回来, 国内域名会悄悄改走 final 服务器)。
# 这里在 DNS 配置里缺该规则时补上, 并明确告知。
sb_ensure_dns_rule() { # <tag> <jq-rule-filter> [说明]
    local tag="$1" filter="$2" desc="${3:-}" f="$SB_CONFIG_DIR/01-dns.json"
    [[ -f "$f" ]] || return 0
    sb_ruleset_defined "$tag" || return 1
    jq -e --arg t "$tag" 'any(.dns.rules[]?; ((.rule_set? // []) | tostring) == ([$t]|tostring))' "$f" >/dev/null 2>&1 && return 0
    if write_config "$f" "$(jq --arg t "$tag" "$filter" "$f")"; then
        print_ok "已补回 DNS 分流规则: $tag${desc:+ ($desc)}"
        return 0
    fi
    return 1
}

# ---------- 客户端产物 (mihomo YAML) ----------
# 统一走 conf/to_mihomo.py, 与菜单 9 的合并 YAML 同一套转换逻辑。
# 各协议脚本不再手写 YAML —— 手写版本曾出现 trojan 漏指纹/漏证书钉扎、
# vless 漏证书钉扎等问题, 同一份字段写两处必然漂移。
gen_mihomo_yaml() { # 按 tag 生成/刷新单节点 YAML; mihomo 不支持的组合会删掉旧文件并说明原因
    local tag="$1"
    local here; here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
    [[ -f "$SB_OUT_DIR/sb_client-$tag.json" ]] || return 0
    python3 "$here/to_mihomo.py" --single "$SB_OUT_DIR" "$SB_ROOT/cert" \
        "$SB_OUT_DIR/sb_client-$tag.json" 2>&1 | grep -v '^已生成单节点' >&2 || true
}

# ---------- 切换产物里的地址族 ----------
# 节点建好之后想把产物从 IPv4 换成 IPv6 (或反过来), 不必重建节点:
# 把所有客户端产物里"连哪个地址"统一改掉即可。
# 覆盖: sb_client-*.json (单节点) / .yaml (mihomo) / sb_client-all.json (聚合)
#       / sb_share-*.txt 与 sb_links-all.txt (分享链接里的 @host)
sb_switch_addr_family() {
    local want="$1"
    [[ "$want" == "v4" || "$want" == "v6" ]] || { print_error "用法: sb_switch_addr_family v4|v6"; return 1; }
      # 目标地址和"被替换的地址"都必须按 want 明确取, 不能走 sb_addr_current ——
      # 状态文件此刻可能已经是 want 了 (建节点时就写过), 再用它判断就会取反:
      # 切到 IPv6 时把 IPv4 填进去, 却报"已切换为 IPv6"。
      local ip old
      if [[ "$want" == "v6" ]]; then ip=$(sb_addr6); old=$(sb_addr4)
      else                          ip=$(sb_addr4); old=$(sb_addr6); fi
      if [[ -z "$ip" ]]; then
          print_error "本机没有可用的 IPv$([[ "$want" == v6 ]] && echo 6 || echo 4), 无法生成产物"
          return 1
      fi
      [[ -z "$old" ]] && print_warn "旧地址不可用, 只更新能更新的部分"

    local n=0 f base
    shopt -s nullglob
    # 1) 单节点 JSON 与聚合 JSON: 直接改 outbounds[].server
    for f in "$SB_OUT_DIR"/sb_client-*.json; do
        base=$(basename "$f")
        [[ "$base" == "sb_client-all.json" ]] && continue
        local t="${base#sb_client-}"; t="${t%.json}"
        jq --arg s "$ip" '(.outbounds[] | select(.server != null) | .server) = $s' "$f" > "$f.tmp" 2>/dev/null \
            && mv -f "$f.tmp" "$f" && n=$((n+1)) || { print_warn "跳过 $base (改写失败)"; rm -f "$f.tmp"; }
    done
    # 2) mihomo YAML: 改 server: 字段
    for f in "$SB_OUT_DIR"/sb_client-*.yaml; do
        local t; t=$(grep -m1 '^ *server:' "$f" 2>/dev/null)
        if [[ -n "$t" ]]; then
            sed -i -E "s|^( *server:).*|\\1 $ip|" "$f" && n=$((n+1))
        fi
    done
    # 3) 分享链接: 主机在 URI 的 @host:port 里。IPv6 必须带方括号,
    #    否则客户端会把最后一段当成端口 —— 这是 IPv6 最常见的踩坑。
    local v4re v6re
    if [[ -n "$old" ]]; then
        v4re=${old//./\\.}
        for f in "$SB_OUT_DIR"/sb_share-*.txt "$SB_OUT_DIR"/sb_links-all.txt; do
            [[ -f "$f" ]] || continue
            sed -i -E "s|@${v4re}(:[0-9]+)|@$(sb_url_host "$ip")\\1|g" "$f"
        done
        n=$((n+1))
    fi
    shopt -u nullglob
    # 4) 聚合文件重新生成, 让 sb_client-all.json 和单节点保持一致
    if declare -F sb_regen_aggregate >/dev/null 2>&1; then
        sb_regen_aggregate
        n=$((n+1))
    fi
    if [[ -f "$SB_OUT_DIR/sb_client-all.yaml" ]] || [[ -d "$SB_OUT_DIR" ]]; then
        declare -F gen_all_mihomo >/dev/null 2>&1 && gen_all_mihomo >/dev/null 2>&1 && n=$((n+1))
    fi
    sb_addr_family_set "$want"
    print_ok "产物地址已切换为 $([[ "$want" == "v6" ]] && echo IPv6 || echo IPv4): $ip  (共更新 $n 处)"
    [[ -n "$old" ]] && print_info "已替换的旧地址: $old"
    return 0
}

# 菜单入口: 问用户要 IPv4 还是 IPv6, 然后切换
sb_menu_addr_family() {
    print_title "切换客户端产物的地址族 (IPv4 / IPv6)"
    local a4 a6 cur
    a4=$(sb_addr4); a6=$(sb_addr6)
    cur=$(sb_addr_family_get); [[ "$cur" == "v6" ]] && cur=2 || cur=1
    echo
    echo -e "  当前产物使用: ${YELLOW}$(sb_family_label)${RESET}" >&2
    echo -e "  ${GREEN}1)${RESET} IPv4   ${CYAN}${a4:-未检测到}${RESET}" >&2
    echo -e "  ${GREEN}2)${RESET} IPv6   ${CYAN}${a6:-未检测到}${RESET}" >&2
    echo >&2
    print_info "只改客户端产物里的地址, 不动服务器监听, 也不动已生成的分享 token"
    print_info "改完记得重新生成聚合/分享链接, 让它们用上新地址"
    echo >&2
    local c=""
    read -r -p "  请选择 [1-2, 回车不变]: " c || { echo; return 0; }
    case "${c// /}" in
        1) sb_switch_addr_family v4 ;;
        2) sb_switch_addr_family v6 ;;
        "") print_info "未选择, 未做修改" ;;
        *) print_error "无效选项" ;;
    esac
}
