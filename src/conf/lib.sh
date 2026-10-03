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
# 只收 IPv4 的节点。后来改成显式菜单 —— 但那是**多余的**。
#
# 服务端监听地址没有需要用户做选择的空间: :: 在 bindv6only=0 时同时收 IPv4
# 和 IPv6, 严格优于 0.0.0.0 (只多一个选项而已), 没有任何理由退让。
# 唯一不能双栈的场合是 CDN 模式, 而那个地址是由**接入方式**决定的
# (cdn=0.0.0.0 供 Cloudflare 回源, cdn-nginx=127.0.0.1 隐藏源站),
# 不是用户该选的东西 —— 那种情况下协议脚本直接写死, 根本不走这个函数。
#
# 所以: 不问、不提示, 统一双栈。真正需要区分 IPv4/IPv6 的是**客户端产物**
# 里写哪个地址 (ask_server_addr), 那边保留菜单。
ask_listen_addr() {
    local d
    # 批量入口 (batch.sh) 仍然可以整体指定, 方便一行生成全套
    if [[ -n "${SB_BATCH:-}" ]]; then
        d="${SB_LISTEN_ADDR:-$SB_LISTEN_DEFAULT}"
    else
        d="$SB_LISTEN_DEFAULT"
    fi
    printf '%s' "$d"
}

# 保留旧的提示文本, 供不需要交互的场景复用 (如菜单说明)。
sb_listen_addr_hint() {
    local a6; a6=$(sb_addr6)
    echo -e "${CYAN}  监听地址${RESET} ${GREEN}::${RESET} ${CYAN}IPv4+IPv6 双栈 (固定)${RESET}" >&2
    [[ -n "$a6" ]] && echo -e "     ${MAGENTA}(检测到 $a6)${RESET}" >&2
    if [[ -z "$a6" ]]; then
        print_warn "本机没有可用的 IPv6 地址 —— 双栈仍能收 IPv4, 但 IPv6 客户端连不上"
    elif [[ "$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo 0)" == "1" ]]; then
        print_warn "net.ipv6.bindv6only=1, 监听 :: 只收 IPv6, IPv4 会连不上"
    fi
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
# 证书列表按域名去重 —— 供所有证书选择入口共用。
#
# 同一张证书在磁盘上通常有两份 (acme.sh 的 certs/x.pem 与 certbot 的
# live/x/fullchain.pem)。按路径去重没用 (路径确实不同), 用户看到的是同一
# 个域名出现两次, 编号还和预期对不上, 很容易选错。
#
# 之前只有 pick_trusted_cert_verbose 做了这件事, pick_trusted_cert (非
# verbose 版) 没做 —— 结果同一个服务器上, 走 A 入口看到 2 张、走 B 入口
# 看到 4 张。抽成函数后才能保证两处行为一致。
#
# 保留第一份: sb_scan_certs 的扫描顺序是 /home/web/certs -> /etc/letsencrypt,
# 先扫到的通常正是现有 nginx 站点正在用的那张。
sb_dedup_certs_by_domain() {
    local uniq=() seen=" " e dom
    for e in "${sb_FOUND_CERTS[@]}"; do
        dom=$(extract_cert_domain "${e%%|*}")
        [[ "$seen" == *" ${dom:-?} "* ]] && continue
        seen+="${dom:-?} "; uniq+=("$e")
    done
    SB_UNIQ_CERTS=("${uniq[@]}")
    return 0
}

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
    local uniq=() e crt key dom mark
    sb_dedup_certs_by_domain; uniq=("${SB_UNIQ_CERTS[@]}")
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
            CERT_FILE="$f"; CERT_KEY_FILE_DONE="$k"
            KEY_FILE="$k"; CERT_DOMAIN=$(extract_cert_domain "$f"); CERT_TRUSTED=true
            return 0
        fi
        print_error "路径无效"; return 1
    fi

    local uniq=() e crt key dom i=1 c
    sb_dedup_certs_by_domain; uniq=("${SB_UNIQ_CERTS[@]}")
    echo "  检测到 ${#uniq[@]} 张证书:" >&2
    for e in "${uniq[@]}"; do
        crt="${e%%|*}"; key="${e#*|}"; key="${key%%|*}"
        dom=$(extract_cert_domain "$crt")
        printf "  %d) %s  (%s)\n" "$i" "${dom:-未知域名}" "$crt" >&2
        i=$((i+1))
    done
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

# ---------- 传输方式 (Transport) ----------
# sing-box 1.14 的 HTTP 类传输恰好 4 种: ws / grpc / http / httpupgrade。
#
# **裸 TCP 在 sing-box 里没有对应的 transport 类型** —— 不存在 "tcp"/"raw"
# 这两个值 (那是 Xray 的别名)。transport/v2ray/transport.go 在 Type 为空时
# 直接返回 nil, 所以裸 TCP 的唯一正确写法是**整个省略 transport 字段**。
# 写成 "type":"tcp" 会报 unknown transport type。
#
# 默认 ws: 客户端覆盖最广 (sing-box/mihomo/Xray/v2rayN 全支持)、Cloudflare
# 支持最完整、性能最好。
SB_TRANSPORT_HTTP=(ws grpc http httpupgrade)

sb_transport_is_http() {
    case "${1:-}" in ws|grpc|http|httpupgrade) return 0 ;; *) return 1 ;; esac
}

# 询问传输方式。
# 结果写进全局 (不靠 stdout —— 理由同 ask_access_mode 的注释: 命令替换会让
# read 跑在子 shell 上, stdin 可能已耗尽, 表现为"明明选了却还在问下一个")。
#   TR_TYPE  ws|grpc|http|httpupgrade; 裸 TCP 时为空字符串
#   TR_PATH  ws / http / httpupgrade 的 path
#   TR_SVC   grpc 的 service_name
#   TR_HOST  http 的 host —— sing-box 用它做 Host 校验, 不设会退化成
#           Host: www.example.com 而被自己的服务端拒掉
sb_ask_transport() {
    local t
    TR_TYPE=""; TR_PATH=""; TR_SVC=""; TR_HOST=""
    # 批量模式必须走显式环境变量而不是应答串: safe_read 在 SB_BATCH 下
    # 返回默认值且**不消费答案队列**, 用应答串定位会让后面所有提问整体错位
    # (历史上 4 被当成"传输方式", Reality 变体退化成 plain)。
    if [[ -n "${SB_BATCH:-}" ]]; then
        t="${SB_BATCH_TRANSPORT:-ws}"
    else
        echo "  传输方式:" >&2
        echo "    ${CYAN}1)${RESET} ws             ${DIM:-}(默认, 兼容性最好, Cloudflare 全功能)${RESET}" >&2
        echo "    ${CYAN}2)${RESET} grpc           ${DIM:-}(Cloudflare 面板需开 gRPC 开关)${RESET}" >&2
        echo "    ${CYAN}3)${RESET} http (HTTP/2)   ${DIM:-}(低优先级: Xray 已移除此传输)${RESET}" >&2
        echo "    ${CYAN}4)${RESET} httpupgrade    ${DIM:-}(主动探测最难识别, CPU 开销最低)${RESET}" >&2
        echo "    ${CYAN}5)${RESET} 裸 TCP          ${DIM:-}(不写 transport 字段)${RESET}" >&2
        # 预置方案指定的传输: 菜单照常打出来 (用户仍能改), 但回车直接落在
        # 它身上。用独立变量而不是复用 SB_BATCH_TRANSPORT —— 后者会把整个
        # sb_ask_transport 切到不提问的批量分支, 等于剥夺用户改动的机会。
        local preset_tr="${SB_PRESET_TR_HINT:-}" preset_tr_idx=""
        if [[ -n "$preset_tr" ]]; then
            case "$preset_tr" in
                ws)          preset_tr_idx=1 ;;
                grpc)        preset_tr_idx=2 ;;
                http)        preset_tr_idx=3 ;;
                httpupgrade) preset_tr_idx=4 ;;
                tcp)         preset_tr_idx=5 ;;
            esac
            # 提示里打传输**名字**而不是菜单序号: "预置方案指定 1" 对用户毫无意义
            # (1 是 ws 还是 http 要翻上面的菜单才知道)。名字在下面 case 里取。
            [[ -n "$preset_tr_idx" ]] && {
                local preset_tr_name="$preset_tr"
                case "$preset_tr" in
                    ws) preset_tr_name="WebSocket" ;;   grpc) preset_tr_name="gRPC" ;;
                    http) preset_tr_name="HTTP/2" ;;     httpupgrade) preset_tr_name="HTTPUpgrade" ;;
                    tcp) preset_tr_name="裸TCP" ;;
                esac
                echo -e "    ${MAGENTA}(预置方案指定 ${preset_tr_name} —— 回车即用, 输别的序号可改)${RESET}" >&2
            }
        fi
        local def_tr_idx="${preset_tr_idx:-1}"
        t=$(safe_read "选择 [1-5, 回车=${def_tr_idx}]" "$def_tr_idx")
    fi
    # 同时接受菜单序号和传输名 —— 批量走的是 SB_BATCH_TRANSPORT=grpc 这种
    # **名字**, 只认序号的话它会落到 *) 兜底变成 ws, 表现为"传了也没用"。
    case "$t" in
        2|grpc)       t="grpc" ;;
        3|http|h2)    t="http" ;;
        4|httpupgrade) t="httpupgrade" ;;
        5|tcp|raw)    t="tcp" ;;
        *)            t="ws" ;;
    esac
    case "$t" in
        tcp)
            TR_TYPE=""
            ;;
        grpc)
            TR_TYPE="grpc"
            # service_name 默认必须**每个节点不同**。所有节点都叫 grpcSvc 时,
            # cdn.sh 生成的片段会出现多个同路径 location, nginx 直接
            # "duplicate location" 起不来 —— 一个节点的默认值能连带搞垮
            # 整份站点配置。
            TR_SVC=$(safe_read "gRPC service_name" "grpc$(openssl rand -hex 3)")
            ;;
        http)
            TR_TYPE="http"
            TR_PATH=$(safe_read "HTTP 路径 (以 / 开头)" "/$(openssl rand -hex 4)")
            ;;
        httpupgrade)
            TR_TYPE="httpupgrade"
            # sing-box 的 httpupgrade **不支持 early data**, 带 ?ed= 会 404
            TR_PATH=$(safe_read "HTTPUpgrade 路径 (以 / 开头)" "/$(openssl rand -hex 4)")
            ;;
        *)
            TR_TYPE="ws"
            TR_PATH=$(safe_read "WS 路径 (以 / 开头)" "/$(openssl rand -hex 4)")
            ;;
    esac
    return 0
}

# 服务端 transport JSON 片段。裸 TCP 返回空串 (调用方不要输出该字段)。
sb_transport_json_server() { # <type> <path> <svc> <host>
    case "${1:-}" in
        "")            printf '' ;;
        ws)            printf '{"type":"ws","path":"%s","max_early_data":2560,"early_data_header_name":"Sec-WebSocket-Protocol"}' "$2" ;;
        httpupgrade)   printf '{"type":"httpupgrade","path":"%s"}' "$2" ;;
        grpc)          printf '{"type":"grpc","service_name":"%s"}' "$3" ;;
        http)          printf '{"type":"http","path":"%s","host":["%s"]}' "$2" "$4" ;;
        *)             print_error "未知传输类型: ${1:-<空>}"; return 1 ;;
    esac
}

# 客户端 transport JSON 片段。裸 TCP 返回空串。
# ws 显式带 User-Agent: sing-box 的 ws 默认发 "Go-http-client/1.1", 而这正是
# Cloudflare 滥用公告里点名的特征 ("WebSocket tunneling abuse - Xray/V2Ray
# x_padding pattern with Go-http client")。
sb_transport_json_client() { # <type> <path> <svc> <host> <ua>
    local ua="${5:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36}"
    case "${1:-}" in
        "")            printf '' ;;
        ws)            printf '{"type":"ws","path":"%s","headers":{"Host":"%s","User-Agent":"%s"}}' "$2" "$4" "$ua" ;;
        httpupgrade)   printf '{"type":"httpupgrade","path":"%s","host":"%s"}' "$2" "$4" ;;
        grpc)          printf '{"type":"grpc","service_name":"%s"}' "$3" ;;
        http)          printf '{"type":"http","path":"%s","host":["%s"]}' "$2" "$4" ;;
        *)             print_error "未知传输类型: ${1:-<空>}"; return 1 ;;
    esac
}

# 分享链接的传输参数。裸 TCP 返回空串。
# httpupgrade **绝不能带 &ed=**: sing-box 不支持 httpupgrade 的 early data,
# 且路径是精确匹配, 多余参数直接 404。
sb_transport_link_params() { # <type> <path> <svc> <host>
    case "${1:-}" in
        "")            printf '' ;;
        ws)            printf '&type=ws&path=%s&host=%s' "$2" "$4" ;;
        grpc)          printf '&type=grpc&serviceName=%s&host=%s' "$3" "$4" ;;
        http)          printf '&type=http&path=%s&host=%s' "$2" "$4" ;;
        httpupgrade)   printf '&type=httpupgrade&path=%s&host=%s' "$2" "$4" ;;
        *)             print_error "未知传输类型: ${1:-<空>}"; return 1 ;;
    esac
}

# ---------- TLS Fragment (客户端侧) ----------
#
# 把 ClientHello 切成多段、每段之间插随机延时再发出去, 让按"首包大小"分类的
# DPI 探针看不出这是个 TLS 握手 (裸 ClientHello 的特征太明显)。
#
# 与 record_fragment 的区别 (两者别混):
#   fragment         —— 切的是 **ClientHello 这条 TLS 记录**本身
#   record_fragment  —— 切的是之后的**每一条 TLS record**
# 前者防的是"看到第一个包就是标准 ClientHello", 后者防的是握手之后的流量特征。
# 本项目的 vless/vmess/trojan 默认只暴露 fragment, 因为它更通用、对服务端
# 零要求 (record_fragment 对服务端实现有要求)。
#
# 为什么默认关闭:
#   - 每个 ClientHello 多花 10~20ms, 高频新建连接的场景反而更慢
#   - 部分中间设备对分片 TLS 的处理有 bug, 可能直接断连
#   - 已经走 REALITY / ECH 的节点不需要它 (那些是更强的手段)
# 所以做成显式 opt-in, 不塞进默认路径。
SB_FRAG_DELAY_DEFAULT=10

sb_ask_fragment() { # <tls_mode> -> SB_FRAGMENT / SB_FRAG_DELAY
    SB_FRAGMENT=""; SB_FRAG_DELAY=0
    [[ -n "${SB_BATCH:-}" ]] && return 0
    # reality 节点自己就是"伪装", 再套 fragment 没必要
    [[ "${1:-}" == "reality" ]] && return 0
    echo >&2
    echo -e "${CYAN}  TLS 分片 (fragment)${RESET} ${CYAN}— 切开 ClientHello 并插入随机延时, 抗按首包特征的 DPI${RESET}" >&2
    echo -e "    ${MAGENTA}代价: 每个 ClientHello 多 10~20ms; 少数中间设备对分片 TLS 处理有 bug。${RESET}" >&2
    echo -e "    ${MAGENTA}REALITY / ECH 节点不需要它 (那已经是更强的手段)。${RESET}" >&2
    echo -e "    ${GREEN}1)${RESET} 关闭 (推荐)" >&2
    echo -e "    ${GREEN}2)${RESET} 开启" >&2
    local c
    read -r -p "    请选择 [1-2, 回车=1]: " c || { echo; return 0; }
    c=$(clean_input "$c"); [[ -z "$c" ]] && c=1
    [[ "$c" == "2" ]] || return 0
    SB_FRAGMENT="true"
    SB_FRAG_DELAY=$(safe_read "首片延时 (毫秒)" "$SB_FRAG_DELAY_DEFAULT")
    [[ "$SB_FRAG_DELAY" =~ ^[0-9]+$ ]] || SB_FRAG_DELAY=$SB_FRAG_DELAY_DEFAULT
    print_ok "TLS 分片已开启 (首片延时 ${SB_FRAG_DELAY}ms)"
    return 0
}

# 客户端 TLS 片段 (与 ech 一样用 jq 并进去)
sb_fragment_json_client() {
    [[ "${SB_FRAGMENT:-}" == "true" ]] || return 0
    printf '"fragment": true, "fragment_fallback_delay": "%sms"' "${SB_FRAG_DELAY:-$SB_FRAG_DELAY_DEFAULT}"
}

# 分享链接参数 (mihomo 叫 tls-fragment, sing-box 客户端认 fragment/fallback)
sb_fragment_link_params() {
    [[ "${SB_FRAGMENT:-}" == "true" ]] || return 0
    printf '&fragment=1&fragmentFallbackDelay=%sms' "${SB_FRAG_DELAY:-$SB_FRAG_DELAY_DEFAULT}"
}

# ---------- 多行输入工具 ----------
# 多行读取 padding_scheme 规则。
# 用法: sb_read_lines <提示文字> <全局变量名>
# 每行一条, 空行结束; 管道/重定向喂进来的内容一律当作只有一行处理, 避免
# 在批处理里把后面的 stdin 全部吞掉。
sb_read_lines() { # <提示> <变量名> -> stdout
    local prompt="$1" __v="$2" line out=""
    printf '%s' "$prompt" >&2
    printf '    每行一条规则, 空行结束。\n' >&2
    while IFS= read -r line; do
        line=$(clean_input "$line")
        [[ -z "$line" ]] && break
        [[ "$line" == "stop="* || "$line" == [0-7]* ]] || {
            print_warn "看不懂的规则, 已忽略: $line"; continue; }
        # 用**换行**拼接, 不用逗号: padding 规则本身就含逗号
        # (如 "2=400-500,c,500-1000"), 逗号拼接后再按逗号还原会把一条规则
        # 拆成三条。下游 jq -R . 本来就按行切, 换行拼接正好对上。
        out="${out}${out:+$'\n'}$line"
    done
    # 循环退出条件: 空行, 或 stdin 读完 (EOF)。
    # EOF 也退出是必须的 —— 否则用户没敲空行时, 这里会把后面所有提问的
    # 输入全部吞掉, 症状和"只支持单行"一模一样。
    printf '%s' "$out"
}

# 读取多行并渲染成 JSON 数组 (每行一个元素)。
sb_read_lines_json() { # <提示> -> stdout
    local raw; raw=$(sb_read_lines "$1" _unused)
    [[ -n "$raw" ]] || return 0
    printf '%s' "$raw" | jq -R . | jq -sc .
}

# ---------- ECH (Encrypted Client Hello) ----------
#
# ECH 把 ClientHello 里的真实 SNI 加密, 外面套一个"公开名"(public_name)。
# 中间盒于是只看到公开名, 看不到你实际连的是哪个域名。
#
# ★ 关键: **两种场景的密钥来源完全不同, 不能共用一套逻辑**
#
#   CDN ECH (Client → Cloudflare → Nginx/SB)
#     TLS 在 Cloudflare 边缘终止, ECH 私钥握在 **Cloudflare** 手里。
#     客户端必须用 **Cloudflare 自己发布的 ECHConfigList** (来自域名的
#     HTTPS/SVCB DNS 记录的 ech= 参数), public_name 是 cloudflare-ech.com。
#     → 客户端填 ech.query_server_name, 让 sing-box 自己去 DNS 取。
#     → **源站 sing-box 完全不需要 ECH 配置** (它根本看不到 ClientHello)。
#     ✗ 绝不能在这里跑 `sing-box generate ech-keypair` —— 那是给"自己就是
#       TLS 终点"的场景用的, 生成的密钥 Cloudflare 解不开, 只会得到
#       "tls: server rejected ECH"; 而且 public_name 会等于你自己的域名,
#       等于什么都没藏。
#
#   直连 SB ECH (Client → SB) —— 重新开放, 但仅限 sing-box 客户端
#     TLS 就在源站 sing-box 上终结, ECH 密钥对由我们自己生成:
#       服务端 ech.key_path  = 私钥 (ECH KEYS PEM)
#       客户端 ech.config    = 内联整份 ECHCONFIGS PEM (公钥侧)
#     已实测 anytls / hysteria2 / tuic 三个协议端到端 3/3 (2026-10):
#     服务端与客户端配置 check 全过, 关/开 ECH 对照均连通, 且服务端日志里
#     没有 server rejected ECH —— 说明加密的 inner ClientHello 被成功解密。
#     **限制**: 客户端必须内联整份 PEM, mihomo / Clash 系内核不认这种形式,
#     所以它只能作为**显式选配**, 不能默认开, 也不能进 CDN 那三个协议的
#     常规路径 (那几个要兼容 mihomo)。对 anytls/hysteria2/tuic 意义不同:
#     它们本来就没有 Reality 可选, 内核 ECH 是它们唯一的 SNI 隐藏手段。
#
# 下面两个函数分别实现这两条路, 由 sb_ask_ech 按 ACCESS_MODE 分流。
# URL 编码 (分享链接的 ech= 参数要用)
sb_urlencode() {
    local s="$1" i c out=""
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9_.~-]) out+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
        esac
    done
    printf '%s' "$out"
}

# CDN 模式 ECH 的分享链接参数 —— DNS 查询形式。
#
# 格式: <public_name>+<ECHConfigList 的 DNS 上游>
# v2rayN / v2rayNG / edgetunnel 通用: 客户端看到这个参数就知道该去哪个 DNS
# 查 HTTPS(65) 记录里的 ech= 字段, 用哪个 public_name 去伪装外层 SNI。
# 之所以要带 public_name 显式声明: 客户端不能假设一定是 cloudflare-ech.com,
# 换 CDN 厂商就是另一个名字。
#
# 注意这**不是**往链接里塞 base64 的 ECHCONFIGS —— 那种形式只有拿到我们
# 自签密钥的场景才成立, CDN 模式下 Cloudflare 解不开, 塞进去反而会让
# 支持该字段的客户端优先用它而失败。
SB_ECH_PUBLIC_NAME="cloudflare-ech.com"
SB_ECH_DNS_UPSTREAM="https://dns.alidns.com/dns-query"
SB_ECH_QUERY_PARAM="${SB_ECH_PUBLIC_NAME}+${SB_ECH_DNS_UPSTREAM}"

# ECH 只在 CDN 接入下有意义。
#   CDN 模式: ECHConfigList 由 Cloudflare 发布, 私钥在 Cloudflare 手里,
#             客户端从 DNS 自动取 —— 这也是浏览器和主流客户端唯一认的形式。
#   直连模式: 要自己持一份 ECH 密钥对, 且客户端必须内联整份 PEM
#             (sing-box 的 ech.config 只认内联 PEM, 见 sb_ech_json_client),
#             mihomo/Clash 这类内核完全不支持, 实际没人用。
# 所以直连一律不问 ECH, 避免给出一个"看着能用、换个内核就废"的选项。
#   cdn / cdn-nginx → Cloudflare ECH (通用, mihomo 也能用)
#   direct           → 内核 ECH    (仅 sing-box 客户端, 见上方实测记录)
# 第二个参数可传 "kernel-only" —— 只对没有 CDN 能力的协议用内核 ECH。
sb_ech_supported() {
    case "${1:-}" in
        cdn|cdn-nginx|direct) return 0 ;;
        *) return 1 ;;
    esac
}

# 该域名是否发布了可用于 ECH 的 HTTPS 记录 —— 只对 CDN 模式有意义。
sb_ech_dns_published() { # <域名>
    local domain="$1" out=""
    command -v curl >/dev/null 2>&1 || return 1
    # Cloudflare 的 ech= 参数在 HTTPS(65) 记录里; 不同 DoH 后端返回的
    # JSON 结构略有差异, 这里只取 Answer[].data 并找 ech= 字段。
    out=$(curl -s -m 8 -H 'accept: application/dns-json' \
        "https://dns.alidns.com/resolve?name=$domain&type=HTTPS" 2>/dev/null) || return 1
    [[ -n "$out" ]] || return 1
    # 没有 jq 时退回纯文本匹配
    if command -v jq >/dev/null 2>&1; then
        out=$(printf '%s' "$out" | jq -r '.Answer[]?.data' 2>/dev/null)
    fi
    printf '%s' "$out" | grep -q 'ech="'
}

# 直连 (内核) ECH 的密钥生成 —— 只在 direct 模式用。
#
# `sing-box generate ech-keypair <域名>` 一次输出两份 PEM:
#   ECH CONFIGS = 公钥侧 (给客户端内联进 ech.config)
#   ECH KEYS    = 私钥侧 (留在服务端 ech.key_path, 用来解密 inner ClientHello)
# 两份必须成对: 客户端拿 CONFIGS 加密, 服务端拿 KEYS 解密。
# 同域名复用同一份文件, 重复建节点不会把已有节点的密钥换掉。
#
# 注意与 CDN 模式的区别: CDN 下这把私钥在 Cloudflare 手里, 源站不需要;
# 直连下我们自己终结 TLS, 所以私钥必须留在源站, 客户端只拿公钥。
sb_ech_generate() { # <域名>
    local domain="$1" dir="$SB_ROOT/ech"
    SB_ECH_KEY_FILE="" SB_ECH_CONFIG_FILE=""
    [[ -n "$domain" ]] || return 1
    command -v "$SB_BIN" >/dev/null 2>&1 || return 1
    mkdir -p "$dir" || return 1
    local safe; safe=$(printf '%s' "$domain" | tr -c 'A-Za-z0-9._-' '_')
    local kf="$dir/${safe}_ech.key.pem" cf="$dir/${safe}_ech.config.pem"
    # 已存在就复用 —— 换一份密钥会让此前所有客户端产物失效
    if [[ -s "$kf" && -s "$cf" ]]; then
        SB_ECH_KEY_FILE="$kf"; SB_ECH_CONFIG_FILE="$cf"; return 0
    fi
    local out
    out=$("$SB_BIN" generate ech-keypair "$domain" 2>/dev/null) || return 1
    printf '%s\n' "$out" | python3 -c '
import sys, os
kf, cf = sys.argv[1], sys.argv[2]
buf, cur = {}, None
for line in sys.stdin:
    line = line.rstrip("\n")
    if "BEGIN ECH CONFIGS" in line: cur = "c"; buf[cur] = [line]; continue
    if "BEGIN ECH KEYS" in line:    cur = "k"; buf[cur] = [line]; continue
    if "END ECH" in line:
        if cur: buf[cur].append(line); cur = None
        continue
    if cur: buf[cur].append(line)
# 头尾行必须完整保留 —— sing-box 只认完整 PEM, 缺 BEGIN/END 会报
# "invalid ECH configs pem" (实测踩过: 只给 base64 正文是不行的)
for key, path in (("k", kf), ("c", cf)):
    if key in buf and buf[key]:
        open(path, "w").write("\n".join(buf[key]) + "\n")
' "$kf" "$cf" 2>/dev/null || return 1
    [[ -s "$kf" && -s "$cf" ]] || return 1
    chmod 600 "$kf"
    SB_ECH_KEY_FILE="$kf"; SB_ECH_CONFIG_FILE="$cf"; return 0
}
# 只问一次, 且**只在 CDN 接入下才问** (sb_ech_supported 决定)。
# ECHConfigList 由 Cloudflare 发布、私钥在 Cloudflare 手里, 客户端从 DNS 自取;
# 源站不需要任何证书材料, 也不需要改配置。
# 结果写进 SB_ECH_ON / SB_ECH_MODE, 调用点: 服务端建节点时问一次,
# 客户端渲染时读全局, 不再问第二次。
sb_ask_ech() { # <域名> <ACCESS_MODE>
    local domain="$1" mode="$2"
    SB_ECH_ON=0; SB_ECH_KEY_FILE=""; SB_ECH_CONFIG_FILE=""; SB_ECH_MODE=""
    # 客户端渲染要用 (CDN 模式的 query_server_name), 所以即便后面判定为
    # 不开启也要留下域名, 否则客户端片段会拼出一个空的 query_server_name
    SB_ECH_DOMAIN="$domain"
    sb_ech_supported "$mode" || return 0
    if [[ -n "${SB_BATCH:-}" ]]; then
        [[ "${SB_BATCH_ECH:-0}" == "1" ]] || return 0
        if [[ "$mode" == "direct" ]]; then
            sb_ech_generate "$domain" && { SB_ECH_ON=1; SB_ECH_MODE="direct"; } || SB_ECH_ON=0
        else
            SB_ECH_ON=1; SB_ECH_MODE="cdn"
        fi
        return 0
    fi

    # 预置方案点名要 ECH 时把默认值落到"开启", 菜单照样打印, 用户想改仍能改
    local pdef=1
    [[ "${SB_PRESET_ECH:-0}" == "1" ]] && pdef=2
    echo >&2
    if [[ "$mode" == "direct" ]]; then
        echo -e "${CYAN}  ECH (加密 ClientHello)${RESET} ${CYAN}— 隐藏真实 SNI${RESET}" >&2
        echo -e "    ${GREEN}1)${RESET} 关闭 (推荐)" >&2
        echo -e "    ${GREEN}2)${RESET} 开启  (内核 ECH, 由本机 sing-box 终结 TLS)" >&2
        echo -e "    ${MAGENTA}注意: 仅 sing-box 客户端可用 —— 需内联 ECHConfigList, mihomo/Clash 不支持${RESET}" >&2
    else
        echo -e "${CYAN}  ECH (加密 ClientHello)${RESET} ${CYAN}— 隐藏真实 SNI, 只对 CDN 有效${RESET}" >&2
        echo -e "    ${GREEN}1)${RESET} 关闭 (推荐)" >&2
        echo -e "    ${GREEN}2)${RESET} 开启  (用 Cloudflare 发布的 ECHConfigList)" >&2
        echo -e "    ${MAGENTA}密钥在 Cloudflare 手里, 客户端从 DNS 自动取; 源站不需要任何证书${RESET}" >&2
    fi
    local c
    read -r -p "    请选择 [1-2, 回车=${pdef}]: " c || { echo; return 0; }
    c=$(clean_input "$c"); [[ -z "$c" ]] && c=$pdef
    [[ "$c" == "2" ]] || return 0

    if [[ "$mode" == "direct" ]]; then
        if sb_ech_generate "$domain"; then
            SB_ECH_ON=1; SB_ECH_MODE="direct"
            print_ok "ECH 已启用 (内核模式, 密钥: $(basename "$SB_ECH_KEY_FILE"), 仅 sing-box 客户端)"
        else
            print_warn "ECH 密钥生成失败, 继续用未加密 SNI (节点不受影响)"
        fi
        return 0
    fi

    # CDN 模式: 先确认域名确实发布了 ech= 参数, 否则开了也是白开
    if sb_ech_dns_published "$domain"; then
        SB_ECH_ON=1; SB_ECH_MODE="cdn"
        print_ok "ECH 已启用 (CDN 模式, 客户端将从 DNS 获取 Cloudflare 的 ECHConfigList)"
    else
        print_warn "该域名的 HTTPS 记录里没有 ech= 参数, Cloudflare 未发布 ECHConfigList"
        print_warn "保持关闭 —— 开启只会得到 \"server rejected ECH\", 不会更好"
    fi
    return 0
}

# 服务端 TLS 里的 ech 片段。
# CDN 模式返回空: TLS 在 Cloudflare 终止, 源站根本看不到 ClientHello,
# 写 key_path 只会误导排障。
sb_ech_json_server() {
    # CDN 模式恒空: TLS 在 Cloudflare 终结, 源站根本看不到 ClientHello,
    # 写 key_path 只会误导排障。
    # 内核模式要写: 我们自己终结 TLS, 解密 inner ClientHello 靠的就是这把私钥。
    [[ "${SB_ECH_ON:-0}" == "1" && "${SB_ECH_MODE:-}" == "direct" ]] || return 0
    [[ -s "${SB_ECH_KEY_FILE:-}" ]] || return 0
    printf '"ech": { "enabled": true, "key_path": "%s" }' "$SB_ECH_KEY_FILE"
}

# 客户端 TLS 里的 ech 片段 (供各协议并进 outbound.tls)
# CDN 模式: 只写 query_server_name, sing-box 自己去 DNS 取 Cloudflare 的
# ECHConfigList。**不写 config/config_path** —— 那是本机文件路径, 客户端
# 那边不存在, 曾导致所有 ECH 节点实测 0/3。
sb_ech_json_client() {
    [[ "${SB_ECH_ON:-0}" == "1" ]] || return 0
    case "${SB_ECH_MODE:-}" in
        cdn)
            [[ -n "${SB_ECH_DOMAIN:-}" ]] || return 0
            printf '"ech": { "enabled": true, "query_server_name": "%s" }' "$SB_ECH_DOMAIN"
            ;;
        direct)
            # 必须内联**完整 PEM** (含 BEGIN/END ECH CONFIGS 头尾行):
            #   ech.config      = 内联 PEM  ← 用这个
            #   ech.config_path = 本地文件路径, 那是**服务端**机器上的绝对
            #                     路径, 写进客户端产物客户端必然打不开
            #                     (实测所有 ECH 节点 0/3)
            #   ech.configs     = 内核 1.14 不认 (unknown field)
            [[ -s "${SB_ECH_CONFIG_FILE:-}" ]] || return 0
            local cf; cf=$(jq -Rs . < "$SB_ECH_CONFIG_FILE")
            [[ "$cf" != '""' ]] || return 0
            printf '"ech": { "enabled": true, "config": %s }' "$cf"
            ;;
    esac
}

# 分享链接参数: 同样只有 CDN 形式 (客户端从 DNS 自取 ECHConfigList)
sb_ech_link_params() {
    [[ "${SB_ECH_ON:-0}" == "1" ]] || return 0
    case "${SB_ECH_MODE:-}" in
        cdn)
            [[ -n "${SB_ECH_DOMAIN:-}" ]] || return 0
            printf '&ech=%s' "$(sb_urlencode "$SB_ECH_QUERY_PARAM")"
            ;;
        direct)
            # 内核 ECH: 链接里带 ECHCONFIGS 正文 (去掉 PEM 头尾行)。
            # 只有认这个形式的客户端能用, 也就是 sing-box。
            [[ -s "${SB_ECH_CONFIG_FILE:-}" ]] || return 0
            printf '&ech=%s' "$(sb_urlencode "$(sed '1d;$d' "$SB_ECH_CONFIG_FILE" | tr -d '\n\r')")"
            ;;
    esac
}

# 节点名的**最终裁决**。必须在 ECH / 接入方式都确定之后调用。
#
# 为什么需要: 预置表的标签是在"选方案"那一刻定下的, 但里面最关键的两个
# 特征 —— CDN 与 ECH —— 要到后面才确定:
#   - 预置说是 CDN, 用户在"接入方式"那一步改成直连了
#   - ECH 菜单默认开, 但 sb_ech_dns_published 查到这个域名的 HTTPS 记录里
#     没有 ech= 参数, 于是没开成
# 这两种情况下, 早先拼进名字的 "CDN" / "ECH" 就是**假话** —— 而用户在
# 客户端列表里唯一的线索就是名字, 看到 "…-ECH" 却发现没加密, 比不给提示更糟。
# 所以这里按实际生效的开关重算标签, 而不是相信预置表。
sb_resolve_tag() { # <基础形态: reality|tls|plain> -> 追加到 SB_TAG_EXTRA
    local form="${1:-plain}"
    local extra="$SB_PRESET_TAG"
    # 批量模式下 sb_ask_preset 直接 return (不消费答案, 也不读预置行), 于是
    # SB_PRESET_TAG 恒为空 —— 批量建出来的 CDN 节点名字就少一个 "-CDN",
    # 用户在客户端列表里分不出哪个走 CDN。这里按批量自己选的接入方式补回。
    if [[ -z "$extra" && -n "${SB_BATCH:-}" ]]; then
        case "${ACCESS_MODE:-direct}" in
            cdn|cdn-nginx) extra="CDN" ;;
        esac
    fi
    # CDN: 以实际接入方式为准
    case "${ACCESS_MODE:-direct}" in
        cdn|cdn-nginx) ;;
        *) extra="${extra//CDN/}" ;;
    esac
    # ECH: 以实际是否开启为准 (可能是预置要求开但 DNS 里没有 ech= 参数)
    [[ "${SB_ECH_ON:-0}" == "1" ]] || extra="${extra//ECH/}"
    # 把 "CDN+ECH" 这样的连接写法换成 "-", 而不是直接删 "+"。
    # 直接删会把两段贴成一个词 (CDN+ECH → CDNECH), 名字里就看不出是两项了。
    extra="${extra//+/-}"
    # 收拾首尾多余的 "-"
    while [[ "$extra" == -* ]]; do extra="${extra#-}"; done
    while [[ "$extra" == *- ]]; do extra="${extra%-}"; done
    SB_TAG_EXTRA="$extra"
}

# ---------- CDN 站点片段清理 ----------
# 清理已经没有 CDN 节点的域名所遗留的 SB-Panel 标记块。
#
# 为什么需要: cdn_autosetup 在"一个 CDN 节点都不剩"时直接 return, 而且
# 只为**仍有节点**的域名生成新片段 —— 于是删掉某域名最后一个节点后,
# 它的 location 会永远留在站点配置里, Cloudflare 回源直接 502。
#
# 安全边界: 只用 BEGIN/END 成对标记定位并删除我们自己插入的那一段,
# 站点里其他 location / 手写配置一律不碰。
sb_cdn_cleanup_stale() {
    local d; d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    declare -F cdn_config_roots >/dev/null 2>&1 || return 0
    [[ -n "${SELF_DIR:-}" ]] || SELF_DIR="$(cd "$d/.." && pwd)"
    export SELF_DIR
    declare -F cdn_find_site_file >/dev/null 2>&1 || return 0

    local f domain dn still=0 removed=0
    local -a stale_files=() stale_domains=()
    shopt -s nullglob
    local r
    while read -r r; do
        [[ -d "$r" ]] || continue
        for f in "$r"/*.conf; do
            [[ -f "$f" ]] || continue
            # 只看含我们标记块的站点文件
            grep -q "SB-Panel CDN 开始" "$f" 2>/dev/null || continue
            # 这个文件对应的域名
            domain=$(grep -oE '^[[:space:]]*server_name[[:space:]]+[^;]+' "$f" 2>/dev/null \
                     | head -1 | awk '{print $2}' | tr ' ' '\n' | grep -v '^$' | head -1)
            [[ -n "$domain" ]] || continue
            # 该域名下是否还有走 CDN 的节点
            local cf; local cnt=0
            for cf in "$SB_CONFIG_DIR"/*.json; do
                [[ -f "$cf" ]] || continue
                sb_cdn_enabled "$cf" || continue
                # 节点的证书域名要跟站点域名一致
                grep -q "$domain" "$cf" 2>/dev/null && cnt=$((cnt+1))
            done
            if (( cnt == 0 )); then
                stale_files+=("$f"); stale_domains+=("$domain")
            else
                still=$((still+1))
            fi
        done
    done < <(cdn_config_roots)
    shopt -u nullglob

    (( ${#stale_files[@]} )) || return 0

    local i rc
    for i in "${!stale_files[@]}"; do
        f="${stale_files[$i]}"; dn="${stale_domains[$i]}"
        echo >&2
        print_warn "域名 $dn 已无 CDN 节点, 清除其遗留的 location 片段"
        rc=0
        python3 "$SELF_DIR/conf/cdn_apply.py" --domain "$dn" --file "$f" \
                 --remove --nginx "$(cdn_nginx_mode)" >/dev/null 2>&1 || rc=$?
        if (( rc == 0 )); then
            print_ok "已清除: $f"
            removed=$((removed+1))
        else
            print_error "清除失败 (rc=$rc): $f"
        fi
    done
    # 第二遍: 清理**没有 SB-Panel 标记**的遗留块。
    # 历史版本的插入路径没写标记, 于是 strip_existing(靠标记定位) 永远删不掉,
    # 站点文件里会一直躺着 `location /xxx { proxy_pass http://127.0.0.1:9999; }`。
    # 这些块的位置和写法是固定的: 顶层(列 0) + 只反代本机端口, 站点自有的
    # location(upstream、静态缓存、acme-challenge) 都不长这样。
    local live_ports="" cf
    shopt -s nullglob
    for cf in "$SB_CONFIG_DIR"/*.json; do
        [[ -f "$cf" ]] || continue
        local lp
        lp=$(jq -r '.inbounds[0].listen_port // empty' "$cf" 2>/dev/null)
        [[ -n "$lp" ]] && live_ports="${live_ports:+$live_ports,}$lp"
    done
    shopt -u nullglob
    local pruned=0
    while read -r r; do
        [[ -d "$r" ]] || continue
        for f in "$r"/*.conf; do
            [[ -f "$f" ]] || continue
            grep -qE 'proxy_pass[[:space:]]+http://127\.0\.0\.1:' "$f" 2>/dev/null || continue
            if python3 "$SELF_DIR/conf/cdn_prune.py" --file "$f" \
                    --live-ports "$live_ports" --nginx "$(cdn_nginx_mode)" 2>&1 | sed 's/^/    /' | grep -q "已清除"; then
                pruned=$((pruned+1))
            fi
        done
    done < <(cdn_config_roots)

    (( removed )) && declare -F cdn_nginx_reload >/dev/null 2>&1 && cdn_nginx_reload
    return 0
}

# ---------- Multiplex (多路复用) ----------
#
# sing-box 只在**四个协议**上支持 multiplex —— VLESS / VMess / Trojan / Shadowsocks
# (见 option/{vless,vmess,trojan,shadowsocks}.go 里的 Multiplex 字段)。
# AnyTLS / NaiveProxy / Hysteria2 / TUIC 的 options 结构体里根本没有这个字段,
# 给它们加就是生成一份 sing-box check 会直接拒绝的配置。所以这里用协议白名单卡死。
#
# 两个方向不对称, 容易踩:
#   出站 (客户端): enabled / protocol / max_connections / min_streams / max_streams
#                  / padding / brutal        —— **protocol 只在出站有**
#   入站 (服务端): enabled / padding / brutal —— 服务端**没有 protocol 字段**,
#                  由 sing-box 自动识别客户端用了哪种。所以"让用户选服务端协议"
#                  这个需求在 sing-box 上不存在, 别去造。
#
# brutal 是 TCP Brutal 拥塞控制: 用一个预估带宽硬压发送速率, 高带宽高延迟链路上
# 吞吐能明显好于 TCP 常规拥塞控制。代价是**填错就废** —— 填的比实际带宽高会丢包、
# 重传, 甚至比不开还慢。所以它必须由用户明确给出, 默认关闭。
SB_MUX_PROTOCOLS=(h2mux yamux smux)
# 默认按用户口味: 上行 100 Mbps / 下行 200 Mbps
SB_BRUTAL_UP_DEFAULT=100
SB_BRUTAL_DOWN_DEFAULT=200

# ---- TCP Brutal 可用性探测 ----
#
# brutal 不是纯用户态特性: sing-box 会 setsockopt(TCP_CONGESTION, "brutal"),
# 要求**内核**装有 tcp_brutal 模块。该模块是 out-of-tree 的 (rimcoding/tcp_brutal),
# 2023 年已停止维护, 从未合入 Linux 主线 —— Debian/Ubuntu 官方内核不带,
# apt 源里也没有。
#
# 后果很关键: sing-box check **照样通过**, 配置看起来完全正常,
# 直到第一个真实请求才在运行时炸:
#   brutal exchange: remote error: enable TCP Brutal: setsockopt IPPROTO_TCP
#   TCP_CONGESTION brutal: no such file or directory
# 所以这里必须探测之后再决定要不要给用户这个选项, 不能无条件暴露。
sb_brutal_available() {
    grep -qw brutal /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && return 0
    modinfo tcp_brutal >/dev/null 2>&1 && return 0
    return 1
}

# 该协议是否支持 multiplex
# 多路复用档位 (web / video / download)
#
# 三个参数是内核的决策输入, 直接让用户填等于把内核逻辑丢给用户, 所以按
# 使用场景给预设。数值语义 (引自内核 client.go 的 offer 逻辑):
#   max_connections : 物理连接数上限
#   min_streams     : 新建连接的流数门槛 (活跃流数 < 此值时复用, 不新建)
#   max_streams     : 单连接流数容量 (max_connections>0 时不参与连接决策)
#
# 每行格式: <id>|<显示名>|<连接数>|<流起>|<单连接流数>|<说明>
# id 用英文: 它同时是 SB_MUX_TIER_DEFAULT 和 SB_BATCH_MUX_PROFILE 的取值,
# 显示名是中文 —— 两边混用会导致按 id 查档位永远查不到。
SB_MUX_TIERS=(
    "web|网页党|1|1|32|复用最大化, 单条连接扛住所有并发, 最省内存"
    "video|视频党|2|2|16|多一条并行通道, 兼顾视频 + 网页"
    "download|下载党|4|4|64|多物理连接, 为高吞吐和大文件"
)

# 默认档位: video (2/2/16)。单用途节点够用, 又不像网页档那样一条连接
# 顶所有并发, 也不像下载档那样平白多占三条物理连接。
SB_MUX_TIER_DEFAULT="video"

# 复用协议: 三个档位统一用 h2mux。
# mihomo 的 smux 块只支持 protocol: smux (内核限制), 这里不存在该约束,
# h2mux 基于 HTTP/2 流, 在 sing-box 里延迟最低, 与 ws/grpc 这类 CDN 传输
# 也最合拍; 要换 yamux/smux 走「自定义」。
SB_MUX_TIER_PROTO="h2mux"

# 菜单展示顺序 (英文 id)
SB_MUX_TIER_ORDER=(web video download)

# ══════════════════════════════════════════════════════════════════════
# Reality 流控 (flow)
# ══════════════════════════════════════════════════════════════════════
# sing-box 的 vless users[].flow 目前只有 xtls-rprx-vision 一个取值。它
# 是 XTLS 层级的流控 —— 在 Reality 的类 TLS 握手之上再套一层"按数据形态
# 分流 + 零拷贝", 比 multiplex 更省 CPU 也更不容易被侧信道统计识别。
#
# 与 multiplex 的关系是**二选一**, 不是叠加。两者都在争同一层带宽预算:
#   vision  = 改写数据流, 适合"少而长"的大流量 (视频/下载/下载器)
#   multiplex = 多路复用 TCP, 适合"多而短"的小请求 (网页/爬虫/IM)
# 同时开等于两套机制互相拖慢, 收益为负。
#
# ⚠ 与 transport 的互斥是实测出来的, 不是猜的 —— 见下方 sb_flow_conflict。
# sing-box check 对 flow + ws/grpc/httpupgrade **一律放行**, 但运行时
# Reality 校验直接失败:
#   裸TCP + flow=vision              → 3/3 连通
#   WS   + flow=vision              → 0/3 reality verification failed
#   WS   + 无flow + multiplex        → 3/3 连通
# 所以必须由面板拦, 内核拦不住。
SB_FLOW_VALUES=(xtls-rprx-vision)
SB_FLOW_DEFAULT="xtls-rprx-vision"

# 有传输层就配不了 vision。返回 0 = 冲突。
sb_flow_conflict() { # <TR_TYPE> -> 冲突时 return 0
    local tr="${1:-}"
    [[ -z "$tr" ]] && return 1      # 裸 TCP: 没问题
    return 0                         # ws/grpc/http/httpupgrade: 冲突
}

# 该协议/传输是否支持 flow。只有 vless 的 Reality 形态有意义。
sb_flow_supported() { # <协议> <CERT_MODE> <TR_TYPE>
    [[ "$1" == "vless" ]] || return 1
    [[ "$2" == "reality" ]] || return 1
    sb_flow_conflict "$3" && return 1
    return 0
}

sb_ask_flow() { # <CERT_MODE> <TR_TYPE>  -> stdout: flow 取值 (空=不用)
    FLOW=""
    local mode="$1" tr="$2"
    [[ "$mode" == "reality" ]] || return 0
    # 有传输层直接跳过, 不给用户选一个注定连不上的组合
    sb_flow_conflict "$tr" && return 0
    if [[ -n "${SB_BATCH:-}" ]]; then
        FLOW="${SB_BATCH_FLOW:-$SB_FLOW_DEFAULT}"
        return 0
    fi
    print_title "XTLS Vision 流控 (Reality 专用)"
    echo "    ${CYAN}1)${RESET} 开启 vision  ${DIM:-}(Reality 的正解, 少而长的大流量)${RESET}" >&2
    echo "    ${CYAN}2)${RESET} 不开         ${DIM:-}(留给 multiplex 用, 多而短的小请求)${RESET}" >&2
    local c; c=$(safe_read "选择" "1")
    [[ "$c" == "2" ]] && return 0
    FLOW="$SB_FLOW_DEFAULT"
    print_ok "flow: $FLOW (与 multiplex 互斥, mux 将自动关闭)"
    return 0
}

sb_flow_json_user() { # 服务端 inbound users[] 需要 flow
    [[ -n "$FLOW" ]] || return 0
    printf ', "flow": "%s"' "$FLOW"
}

# ══════════════════════════════════════════════════════════════════════
# Reality 预置方案
# ══════════════════════════════════════════════════════════════════════
# 这些是实战里被反复用的组合, 不是随便凑的档位。格式与 SB_MUX_TIERS 一致:
#   <id>|<中文显示名>|<传输>|<multiplex档位>|<flow>|<说明>
#
# 依据是 fscarmen/sing-box.sh (社区最流行的一键脚本) 的节点表, 它的
# idx11 就是 "Reality + 裸TCP + xtls-rprx-vision, 明确把 multiplex 关掉",
# idx19/20 是 "Reality + 传输 + multiplex, 明确不设 flow" —— 与上面
# sb_flow_conflict 的实测结论完全吻合。
#
# 优先级: 隐蔽性 > 兼容性。默认项绝对不能是 CDN/ECH 相关的, 那些要在
# 完整菜单里自己选。
# ══════════════ 全协议预置方案 ══════════════
# 一条一行, 字段顺序固定:
#   <协议>|<id>|<显示名>|<传输>|<mux档位>|<flow>|<证书>|<说明>|<标签>|<额外>
#   - 传输 写 tcp 表示"裸TCP"; 空表示该协议没有传输层
#   - mux档位 写 off 表示不跑多路复用; 档位用**英文 id**, 因为
#     SB_MUX_TIER_ORDER / sb_mux_tier_get 都以英文 id 为键
#   - flow 只有 vless 有 (sing-box 的 trojan/vmess outbound 里没有 flow 字段)
#   - 证书 reality = 强制 Reality; selfsign = 强制自签 (ECH 前提)
#   - 标签 = 写进**节点名**的标识, 用户在客户端列表里一眼认出方案
#   - 额外 ech = 该方案开 ECH; pad = 该方案开 anytls padding; 空 = 都不开
#
# 传输的选型不是拍脑袋, 是按"两个内核都实测跑通"挑的。mihomo 跑
# sing-box 服务端的 Reality 时, 传输层兼容性实测 (同批节点, 同套凭据):
#   裸TCP ✓ 3/3    gRPC ✓ 3/3    HTTP/2 ✓ 3/3    WebSocket ✗ 0/3
# WebSocket 那条是 mihomo 侧的问题 —— sing-box 客户端连同一节点 3/3 全通,
# mihomo 稳定回 404/400。所以 Reality 预置里一律不排 ws。
# (fscarmen 脚本的 Reality 节点表也是 h2 和 grpc, 从来不用 ws。)
#
# ECH 与 Reality 是两套不同的藏 SNI 手段, 不叠加:
#   Reality = 借用真实站点的证书, 本来就没有"自己的 SNI" 可藏
#   ECH     = 把 ClientHello 里的真实 SNI 用公钥加密, 外层只留 public_name
# 所以 ECH 方案走自签证书 + insecure/pin, 与 Reality 方案互斥。
SB_PRESETS=(
    "vless|tcp-vision|① 隐匿优先 · REALITY|tcp|off|xtls-rprx-vision|reality|裸TCP + XTLS Vision; 抗 DPI 最强, 无任何 Web 特征|REALITY|"
    "vless|grpc-video|② gRPC 伪装 · REALITY|grpc|video||reality|gRPC 套一层正常 HTTP/2 流量; 两个内核都验证过|REALITY|"
    "vless|grpc-dl|③ gRPC 高并发 · REALITY|grpc|download||reality|多路复用扛并发, 适合爬虫/大量小请求|REALITY|"
    "vless|h2-video|④ HTTP/2 伪装 · REALITY|h2|video||reality|HTTP/2 传输, 对 CDN 面板最友好的形状|REALITY|"
    "vless|ws-cdn|⑤ CDN 网页党 · 真证书|ws|web||真证书|走 Cloudflare 回源; 网页浏览档, 最省资源|CDN|"
    "vless|ws-cdn-ech|⑥ CDN + ECH · 网页党|ws|web||真证书|ECH 加密真实 SNI, CDN 回源; 域名探测也挡得住|CDN+ECH|ech"
    "vless|h2-cdn-ech|⑦ CDN + ECH · 视频党|h2|video||真证书|HTTP/2 + ECH; 看视频档, ECH 全程生效|CDN+ECH|ech"
    "vless|grpc-cdn|⑧ CDN · gRPC 档|grpc|video||真证书|Cloudflare 回源; gRPC 走 HTTP/2, 与网页档的 WebSocket 形态不同, 便于分散流量特征|CDN|"
    "vless|grpc-cdn-ech|⑨ CDN + ECH · gRPC 档|grpc|video||真证书|gRPC + ECH; Cloudflare 回源; gRPC 走 HTTP/2, 与网页档的 WebSocket 形态不同, 便于分散流量特征|CDN+ECH|ech"
    "vmess|tcp-video|① 隐匿优先 · REALITY|tcp|video||reality|裸TCP, 不带任何 Web 特征|REALITY|"
    "vmess|grpc-video|② gRPC 伪装 · REALITY|grpc|video||reality|gRPC 套一层正常 HTTP/2 流量|REALITY|"
    "vmess|grpc-dl|③ gRPC 高并发 · REALITY|grpc|download||reality|多路复用扛并发|REALITY|"
    "vmess|h2-video|④ HTTP/2 伪装 · REALITY|h2|video||reality|HTTP/2 传输|REALITY|"
    "vmess|ws-cdn|⑤ CDN 网页党 · 真证书|ws|web||真证书|走 Cloudflare 回源; 网页浏览档, 最省事|CDN|"
    "vmess|ws-cdn-ech|⑥ CDN + ECH · 网页党|ws|web||真证书|ECH 加密真实 SNI, CDN 回源|CDN+ECH|ech"
    "vmess|grpc-cdn|⑦ CDN · gRPC 档|grpc|video||真证书|Cloudflare 回源; gRPC 走 HTTP/2, 与网页档的 WebSocket 形态不同, 便于分散流量特征|CDN|"
    "vmess|grpc-cdn-ech|⑧ CDN + ECH · gRPC 档|grpc|video||真证书|gRPC + ECH; Cloudflare 回源; gRPC 走 HTTP/2, 与网页档的 WebSocket 形态不同, 便于分散流量特征|CDN+ECH|ech"
    "trojan|tcp-video|① 隐匿优先 · REALITY|tcp|video||reality|裸TCP, 不带任何 Web 特征|REALITY|"
    "trojan|grpc-video|② gRPC 伪装 · REALITY|grpc|video||reality|gRPC 套一层正常 HTTP/2 流量|REALITY|"
    "trojan|grpc-dl|③ gRPC 高并发 · REALITY|grpc|download||reality|多路复用扛并发|REALITY|"
    "trojan|h2-video|④ HTTP/2 伪装 · REALITY|h2|video||reality|HTTP/2 传输|REALITY|"
    "trojan|ws-cdn-ech|⑤ CDN + ECH · 网页党|ws|web||真证书|ECH 加密真实 SNI, CDN 回源|CDN+ECH|ech"
    "trojan|grpc-cdn|⑥ CDN · gRPC 档|grpc|video||真证书|Cloudflare 回源; gRPC 走 HTTP/2, 与网页档的 WebSocket 形态不同, 便于分散流量特征|CDN|"
    "trojan|grpc-cdn-ech|⑦ CDN + ECH · gRPC 档|grpc|video||真证书|gRPC + ECH; Cloudflare 回源; gRPC 走 HTTP/2, 与网页档的 WebSocket 形态不同, 便于分散流量特征|CDN+ECH|ech"
    # anytls 的预置表 (2026-10 更正两次)。
    #
    # 第一次误判: 写着"anytls 只有 REALITY 一种可用形态", 撤掉了全部 TLS 预置。
    #   错因是当时���测试环境有问题: 临时起的端口没在防火墙放行, CC 连过去是
    #   i/o timeout, 我把这个现象当成了"服务端在 ClientHello 阶段 reset"。
    #   (中途还误以为是 ALPN 的问题, 同样被推翻 —— 见下。)
    #
    # 复核结论 (RN 起服务端, CC 上 sing-box 与 mihomo 双内核实测):
    #   anytls 原生 TLS + 自签/真证书          -> 两端都正常, 稳定 8/8
    #   anytls + REALITY                       -> 两端正常 (仅 sing-box 客户端)
    #   alpn 有无、服务端有无 alpn             -> 四种组合**全部 8/8**, 与 ALPN 无关
    #   把 ufw 放行规则删掉                    -> 立刻退回 0/6 i/o timeout
    #   交叉验证: fscarmen/sing-box 的 anytls 服务端与客户端也都不写 alpn, 照常工作
    #
    # 所以 anytls 的原生 TLS 形态完全可用, 与 ALPN 无关, 与防火墙有关。
    # 本项目的 anytls.sh 一直给两端写死 alpn=[h2, http/1.1] —— 那是可选项,
    # 留着无妨 (与服务端一致), 但**不要**把它当成"缺了就连不上"。
    "anytls|tls-self|① 自签 (pin) · 通用|无|无||selfsign|自签证书 + SPKI pin; mihomo/sing-box 都能用; 推荐|自签|"
    "anytls|tls-real|② 真证书|无|无||真证书|CA 可信证书, 客户端无需 insecure/pin; 需先备好 crt/key|真证书|"
    "anytls|reality|③ 隐匿优先 · REALITY|无|无||reality|Reality 免证书; 仅 sing-box 客户端 (mihomo 不支持 AnyTLS+Reality)|REALITY|"
    "anytls|reality-pad|④ REALITY + padding|无|无|pad|reality|在 REALITY 基础上开 padding 填充, 改变流量形状|REALITY+pad|pad"
    
        "shadowsocks|ss-web|① 网页党 (省资源)|无|web||无|网页浏览; 单连接流数压到 1, 内存占用最低|网页|"
    "shadowsocks|ss-video|② 视频党 (均衡)|无|video||无|默认档; 看视频 + 日常网页都够用|视频|"
    "shadowsocks|ss-dl|③ 下载党 (高吞吐)|无|download||无|大文件/长连接; 单连接多流并行|下载|"
    "hysteria2|h2-default|① 推荐默认|无|无||真证书|Hysteria2 参数已是最优默认 (BBR + Salamander)|默认|"
    "hysteria2|h2-ech|② TLS + 内核 ECH|无|无||真证书|内核 ECH 加密 ClientHello, 隐藏真实 SNI (仅 sing-box 客户端)|TLS+ECH|ech"
    "tuic|tuic-default|① 推荐默认|无|无||真证书|TUIC 参数已是最优默认 (BBR + Salamander)|默认|"
    "tuic|tuic-ech|② TLS + 内核 ECH|无|无||真证书|内核 ECH 加密 ClientHello, 隐藏真实 SNI (仅 sing-box 客户端)|TLS+ECH|ech"
    "naive|naive-self|① 自签 + 伪装域名 (推荐)|无|无||selfsign|默认走这条: 一路回车就能建出来, 不需要先备好 crt/key|自签|"
    "naive|naive-real|② 真证书|无|无||真证书|naiveproxy 走真证书, 客户端无需 insecure/pin; 需先备好 crt/key 路径|真证书|"
)

# <协议> 的预置行数
sb_preset_count() {
    local p="$1" n=0 row
    for row in "${SB_PRESETS[@]}"; do [[ "${row%%|*}" == "$p" ]] && ((n++)); done
    printf '%s' "$n"
}

# <协议> <第几行(1起)> -> stdout: "<传输> <mux档位> <flow> <证书> <标签> <额外>"
#   标签 = 节点名里显示的方案标识 (REALITY / ECH / padding …)
#   额外 = ech (开 ECH) / pad (开 padding) / 空
# 用 | 分隔输出, **不能转成空格** —— 表里空字段是 "| |" 这种连续分隔符,
# 而 read 按 IFS 折叠连续空白, 空列会被整个吞掉、后面所有字段左移一位。
# (曾因此让 vmess/trojan/anytls 把 "reality" 读成 flow, 证书菜单静默回落自签。)
sb_preset_get() {
    local want="$1" idx="$2" i=1 row cols
    for row in "${SB_PRESETS[@]}"; do
        [[ "${row%%|*}" == "$want" ]] || continue
        if (( i == idx )); then
            # 逐列剥: 协议|id|显示名|传输|mux|flow|证书|说明|标签|额外
            cols="${row#*|}"; cols="${cols#*|}"; cols="${cols#*|}"
            printf '%s' "$cols"
            return 0
        fi
        ((i++))
    done
    return 1
}

# 预置方案菜单。不绕过提问 —— 只是把答案预填成默认值, 用户在后续
# 每一步仍能改回去。设 SB_PRESET_TR / SB_PRESET_MUX / SB_PRESET_FLOW /
# SB_PRESET_CERT, 各协议脚本在正常流程里读取。
sb_ask_preset() { # <协议> [菜单标题]
    local proto="$1" title="${2:-预置方案}"
    SB_PRESET_TR=""; SB_PRESET_MUX=""; SB_PRESET_FLOW=""; SB_PRESET_CERT=""
    SB_PRESET_TAG=""; SB_PRESET_ECH=0; SB_PRESET_PAD=0; SB_PRESET_CDN=0
    # 每个节点都要从干净的状态起算, 否则批量或连开时会把上一个节点的选择
    # 带过来 (SB_ECH_ON / SB_TAG_FORM 都是全局变量)
    SB_ECH_ON=0; SB_ECH_MODE=""; SB_TAG_FORM=""; SB_TAG_EXTRA=""
    if [[ -n "${SB_BATCH:-}" ]]; then return 0; fi
    local n; n=$(sb_preset_count "$proto")
    (( n == 0 )) && return 0
    print_title "${title} (不想选就一路回车, 逐项自己配)"
    local i=1 row
    for row in "${SB_PRESETS[@]}"; do
        [[ "${row%%|*}" == "$proto" ]] || continue
        printf '    %s%s)%s %-26s %s\n' "$CYAN" "$i" "$RESET" \
            "$(echo "$row" | cut -d'|' -f3)" "$(echo "$row" | cut -d'|' -f8)" >&2
        ((i++))
    done
    printf '    %s%s)%s 不用预设, 我自己逐项配%s\n' "$CYAN" "$((i))" "$RESET" \
        "${DIM:-}(回答每一个问题)${RESET}" >&2
    local c; c=$(safe_read "选择" "1")
    if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= n )); then
        local tr mux flow cert tag extra row_get
        # 不能用 read 拆: 表里空字段是 "| |" 这种连续分隔符, 而 read 按 IFS
        # 折叠连续空白 —— 空列会被整个吞掉, 后面所有字段左移一位
        # (曾导致 vmess/trojan/anytls 把 "reality" 读成 flow, CERT 永远空,
        #  于是证书菜单回落到自签)。逐列按位置取最稳。
        row_get=$(sb_preset_get "$proto" "$c")
        tr=$(printf '%s' "$row_get"   | cut -d'|' -f1)
        mux=$(printf '%s' "$row_get"  | cut -d'|' -f2)
        flow=$(printf '%s' "$row_get" | cut -d'|' -f3)
        cert=$(printf '%s' "$row_get" | cut -d'|' -f4)
        tag=$(printf '%s' "$row_get"   | cut -d'|' -f6)
        extra=$(printf '%s' "$row_get" | cut -d'|' -f7)
        SB_PRESET_TR=""; SB_PRESET_MUX=""; SB_PRESET_FLOW=""; SB_PRESET_CERT=""
        # "无" 是占位符, 表示该协议没有这个维度
        [[ "$tr"  == "无" ]] && tr=""
        [[ "$flow" == "无" ]] && flow=""
        [[ "$cert" == "无" ]] && cert=""
        [[ "$mux"  == "无" ]] && mux=""
        # 裸 TCP 留成显式的 "tcp" 而不是清空 —— 清空后与"用户没选预设"
        # 无法区分, 于是传输菜单回落到默认 ws, 预置①的抗 DPI 定位就没了。
        SB_PRESET_TR="$tr"; SB_PRESET_MUX="$mux"; SB_PRESET_FLOW="$flow"; SB_PRESET_CERT="$cert"
        [[ "$mux" == "off" ]] && SB_PRESET_MUX=""
        # 方案标识写进节点名 —— 用户在客户端列表里只能看到名字, 这是唯一的区分线索
        SB_PRESET_TAG="$tag"
        SB_PRESET_ECH=0; SB_PRESET_PAD=0; SB_PRESET_CDN=0
        [[ "$extra" == *ech* ]] && SB_PRESET_ECH=1
        [[ "$extra" == *pad* ]] && SB_PRESET_PAD=1
        # 标签里带 CDN 的方案 (走 Cloudflare 回源)
        [[ "$tag" == *CDN* ]] && SB_PRESET_CDN=1
        # ECH 有两条路, 别用"必须 CDN"把其中一条堵死:
        #   CDN    : ECHConfigList 私钥在 Cloudflare, 客户端从 DNS 自取 (通用)
        #   内核   : 我们自己持密钥对 (服务端 ech.key_path + 客户端内联 PEM),
        #            只对没有 CDN 可用的 anytls / hysteria2 / tuic 提供 ——
        #            它们本来就没有 REALITY 可选, 内核 ECH 是唯一的 SNI 隐藏手段。
        # 具体哪条由调用 sb_ask_ech 时传的 ACCESS_MODE 决定, 这里只负责把
        # 预置标签里的 ECH 记下来 (清理标签留到 sb_resolve_tag, 那时才知道
        # 实际开没开)。
        # 防呆: ECH 与 Reality 是两套不同的藏 SNI 手段, 不能叠加 ——
        # Reality 借的是真实站点的证书, 本来就没有"自己的 SNI" 可加密。
        # 表里已经把它们分到不同行, 这里再兜一层底, 防止以后改表时踩进去。
        if [[ "$SB_PRESET_ECH" == "1" && "$SB_PRESET_CERT" == "reality" ]]; then
            SB_PRESET_ECH=0; SB_PRESET_CERT="selfsign"; SB_PRESET_FLOW=""
            print_warn "ECH 不能与 Reality 同开, 已改为自签证书 + ECH"
        fi
        # 防呆: ECH 必须有证书可终结 TLS, 没有证书身份就没有 ClientHello 可加密
        # 注意: 这里**不能**再加一条"证书必须能终结 TLS"的判断。真证书当然
        # 能终结 TLS, 而且 CDN + ECH 恰恰就是配真证书用的 —— 之前那条防呆
        # 只放行 selfsign/real, 把 CDN 预置的真证书判成"没有证书身份",
        # 直接把 ECH 关了。属于自己加的、且与实际语义相反的规则。
        print_ok "预置方案: $(echo "${SB_PRESETS[@]}" | grep "^${proto}|" | sed -n "${c}p" | cut -d'|' -f3)"
        print_info "下面仍会逐项确认, 想改直接选别的即可"
    fi
    return 0
}

# Reality + WebSocket 在 mihomo 上跑不通 (见 SB_PRESETS 上方实测表),
# 用户手工选到这个组合时提醒一句, 免得建完才发现 M 内核用不了。
# 传输提问排在证书提问**前面** (传输层的选项里有 ws/grpc/http/httpupgrade,
# 裸TCP 不走 CDN), 所以这里不能读 CERT_MODE, 只能按"预置或后续大概率会选
# Reality"来判断: 预置里出现了 reality 就提醒; 非预置场景留到 cert 之后
# 由调用方用 CERT_MODE 再确认一次。
sb_warn_reality_transport() { # <传输类型> [是否已确定走 Reality]
    local tr="$1" reality="${2:-}"
    if [[ -z "$reality" ]]; then
        [[ "${SB_PRESET_CERT:-}" == "reality" ]] || return 0
    else
        [[ "$reality" == "reality" ]] || return 0
    fi
    case "$tr" in
        ws|1) print_warn "Reality + WebSocket 在 mihomo 上连不通 (实测 0/3, sing-box 客户端 3/3 正常)"
              print_info "要用 M 内核请改选 gRPC 或 HTTP/2, 这两个实测都能通" ;;
    esac
}

# 预置方案 → sb_ask_transport 的答案。空表示用默认。
sb_preset_transport_hint() {
    case "${SB_PRESET_TR:-}" in
        ws)           echo "ws" ;;
        grpc)         echo "grpc" ;;
        httpupgrade)  echo "httpupgrade" ;;
        http)         echo "http" ;;
        tcp)          echo "tcp" ;;
        "")           echo "" ;;     # 没选预设: 不干预, 用菜单默认值
    esac
}

sb_mux_tier_get() { # <档位id> -> stdout: "maxconn minstreams maxstreams"
    local want="$1" row rest
    for row in "${SB_MUX_TIERS[@]}"; do
        [[ "${row%%|*}" == "$want" ]] || continue
        # 剥掉 id 和显示名, 只留 连接数|流起|单连接流数
        rest="${row#*|}"; rest="${rest#*|}"
        printf '%s' "$rest" | cut -d'|' -f1,2,3 | tr '|' ' '
        return 0
    done
    return 1
}

sb_mux_tier_name() { # <档位id> -> stdout: 中文显示名
    local want="$1" row
    for row in "${SB_MUX_TIERS[@]}"; do
        [[ "${row%%|*}" == "$want" ]] || continue
        printf '%s' "$row" | cut -d'|' -f2
        return 0
    done
    return 1
}

sb_mux_supported() {
    case "${1:-}" in vless|vmess|trojan|shadowsocks) return 0 ;; *) return 1 ;; esac
}

# 交互式询问 multiplex 设置, 结果放进 SB_MUX_* 全局变量。
# 服务端与客户端各调用一次 (字段不同), 但问的是同一组问题。
# 批量模式一律关闭: 批量是"一把梭生成全套", 不该替用户做带宽假设。
sb_ask_multiplex() { # <协议> <server|client>
    local proto="$1" side="${2:-server}"

    # ── 防呆: flow (XTLS Vision) 与 multiplex 互斥 ──────────────────
    # 两者争同一层带宽预算, 叠加收益为负。flow 由 sb_ask_flow 在此之前
    # 问过, 这里只做拦截不再询问 —— 用户已经明确选了 vision, 静默关掉
    # mux 比再弹一次菜单更不容易把人绕晕。
    if [[ -n "${FLOW:-}" && "${SB_MUX_FORCE_ON:-0}" != "1" ]]; then
        print_warn "已选 flow=xtls-rprx-vision, multiplex 自动关闭 (两者互斥)"
        SB_MUX_ON=0
        return 0
    fi

    SB_MUX_ON=0; SB_MUX_PROTO=""; SB_MUX_MAXCONN=0; SB_MUX_MINSTR=0; SB_MUX_MAXSTR=0
    SB_MUX_PAD=0; SB_MUX_BRUTAL=0; SB_MUX_UP=0; SB_MUX_DOWN=0

    if [[ -n "${SB_BATCH:-}" ]]; then
        # 批量可显式指定, 默认关闭
        if [[ "${SB_BATCH_MUX:-0}" == "1" ]]; then
            SB_MUX_ON=1
            # 批量也必须探测: 否则批量生成的节点 check 全过, 但一个都连不上
            SB_MUX_BRUTAL=0
            sb_brutal_available && [[ "${SB_BATCH_BRUTAL:-1}" == "1" ]] && SB_MUX_BRUTAL=1
            # brutal 必须给非零带宽: sing-box 客户端会校验 BrutalMinSpeedBPS,
            # 填 0 会被拒 (服务端侧同样如此)。不指定就用默认口味。
            SB_MUX_UP="${SB_BATCH_UP_MBPS:-$SB_BRUTAL_UP_DEFAULT}"
            SB_MUX_DOWN="${SB_BATCH_DOWN_MBPS:-$SB_BRUTAL_DOWN_DEFAULT}"
            [[ "$SB_MUX_UP"  =~ ^[0-9]+$ && "$SB_MUX_UP"  -gt 0 ]] || SB_MUX_UP=$SB_BRUTAL_UP_DEFAULT
            [[ "$SB_MUX_DOWN" =~ ^[0-9]+$ && "$SB_MUX_DOWN" -gt 0 ]] || SB_MUX_DOWN=$SB_BRUTAL_DOWN_DEFAULT
            # 批量同样走档位, 默认与交互一致 (video)
            local _mc _mn _ms
            read -r _mc _mn _ms <<< "$(sb_mux_tier_get "${SB_BATCH_MUX_PROFILE:-$SB_MUX_TIER_DEFAULT}")"
            SB_MUX_PROTO="${SB_BATCH_MUX_PROTO:-$SB_MUX_TIER_PROTO}"
            SB_MUX_MAXCONN="${SB_BATCH_MUX_MAXCONN:-$_mc}"
            SB_MUX_MINSTR="${SB_BATCH_MUX_MINSTR:-$_mn}"
            SB_MUX_MAXSTR="${SB_BATCH_MUX_MAXSTR:-$_ms}"
        fi
        return 0
    fi
    sb_mux_supported "$proto" || return 0

echo >&2
    echo -e "${CYAN}  多路复用 (multiplex)${RESET} ${CYAN}— 多个连接复用一条 TCP, 减少握手并改善高延迟链路${RESET}" >&2
    echo -e "    ${MAGENTA}(${proto} 支持; 开销: 多一次封装, CPU 略增, 单连接延迟会略升)${RESET}" >&2
    local row i=1 tid tname mc mn ms note
    for row in "${SB_MUX_TIERS[@]}"; do
        IFS='|' read -r tid tname mc mn ms note <<< "$row"
        printf "    ${GREEN}%d)${RESET} %s ${DIM}连接 %s / %s 流起 / 单连接 %s 流${RESET}  %s\n" \
            "$((i+1))" "$tname" "$mc" "$mn" "$ms" "$note" >&2
        i=$((i+1))
    done
    local custom_idx=$(( i + 1 ))
    echo -e "    ${GREEN}${custom_idx})${RESET} 自定义  (自己选复用协议和三个参数)" >&2
    # 默认档位跟随 SB_MUX_TIER_DEFAULT (video), 而不是"关闭" —— 用户明确要了
    # 这个默认。提示里直接把它标出来, 免得看不出回车会发生什么。
    local c default_idx default_pos default_name
    # 菜单里档位从 2 开始编号 (1 是"关闭"), 所以菜单序号 = ORDER 位置 + 1
    default_pos=$(printf '%s\n' "${SB_MUX_TIER_ORDER[@]}" | grep -n "^${SB_MUX_TIER_DEFAULT}$" | cut -d: -f1)
    [[ -n "$default_pos" ]] || default_pos=2
    default_idx=$(( default_pos + 1 ))
    # 预置方案指定了档位时, 回车直接落在那个档位上 (而不是全局默认)。
    local preset_mux="${SB_PRESET_MUX:-}" preset_idx=""
    if [[ -n "$preset_mux" ]]; then
        local pp ppos
        ppos=$(printf '%s\n' "${SB_MUX_TIER_ORDER[@]}" | grep -n "^${preset_mux}$" | cut -d: -f1)
        [[ -n "$ppos" ]] && { preset_idx=$(( ppos + 1 )); default_idx=$preset_idx; }
        [[ -n "$preset_idx" ]] && default_name="$(sb_mux_tier_name "$preset_mux") (预置)"
    fi
    default_name="${default_name:-$(sb_mux_tier_name "$SB_MUX_TIER_DEFAULT")}"
    read -r -p "    请选择 [1-${custom_idx}, 回车=${default_idx} (${default_name})]: " c || { echo; return 0; }
    c=$(clean_input "$c"); [[ -z "$c" ]] && c="$default_idx"
    [[ "$c" == "1" ]] && { print_info "multiplex: 关闭"; return 0; }
    SB_MUX_ON=1

    if [[ "$c" == "$custom_idx" ]]; then
        # 自定义: 沿用逐项询问
        #
        # InboundMultiplexOptions 只有 enabled/padding/brutal 三个字段 (已用
        # sing-box check 实测: inbound 侧 max_connections 报 unknown field),
        # protocol 和那三个数值参数都是出站独有的。所以服务端选"自定义"时
        # 一个参数都不问 —— 客户端侧才问。
        if [[ "$side" == "client" ]]; then
                echo -e "${CYAN}  复用协议${RESET}" >&2
                echo -e "    ${GREEN}1)${RESET} ${YELLOW}h2mux${RESET}   基于 HTTP/2, 延迟最低, 与传输无关" >&2
                echo -e "    ${GREEN}2)${RESET} ${GREEN}yamux${RESET}   通用双工流, 与 HTTP/2 不兼容" >&2
                echo -e "    ${GREEN}3)${RESET} ${CYAN}smux${RESET}    最省内存, 主要为 kcp-go 设计" >&2
                local p
                read -r -p "    请选择 [1-3, 回车=1]: " p || { print_warn "读取中断, 按 h2mux 继续"; p=1; }
                p=$(clean_input "$p"); [[ -z "$p" ]] && p=1
                case "$p" in
                    2) SB_MUX_PROTO="yamux" ;;
                    3) SB_MUX_PROTO="smux" ;;
                    *) SB_MUX_PROTO="h2mux" ;;
                esac
                SB_MUX_MAXCONN=$(safe_read "最大连接数 (1-256, 0=不限)" "4")
                SB_MUX_MINSTR=$(safe_read "最少复用流数 (过少会退化成独占)" "4")
                SB_MUX_MAXSTR=$(safe_read "单连接最大流数 (0=不限)" "0")
            fi
    else
        # 档位: 三个参数一次填好, 用户不需要理解内核的门槛语义
        local tid_sel tname
        IFS='|' read -r tid_sel tname _ _ _ <<< "${SB_MUX_TIERS[$((c-2))]}"
        read -r SB_MUX_MAXCONN SB_MUX_MINSTR SB_MUX_MAXSTR <<< "$(sb_mux_tier_get "$tid_sel")"
        [[ "$side" == "client" ]] && SB_MUX_PROTO="$SB_MUX_TIER_PROTO"
        print_ok "multiplex: ${tname} (${SB_MUX_PROTO:-$SB_MUX_TIER_PROTO} · ${SB_MUX_MAXCONN} 连接 / ${SB_MUX_MINSTR} 流起 / 单连接 ${SB_MUX_MAXSTR} 流)"
    fi

    if [[ "$side" == "server" ]]; then
        # padding: 只允许未填充的连接会被拒 —— 会打断手动用 curl/浏览器直连节点的场景
        SB_MUX_PAD=0
        print_info "服务端不启用 padding (它会拒绝未填充的连接, 只适合纯客户端对纯客户端)"
    fi

    echo >&2
    if ! sb_brutal_available; then
        # 明确告诉用户为什么没有这个选项, 而不是给一个运行时才炸的开关
        echo -e "${CYAN}  TCP Brutal 拥塞控制${RESET} ${YELLOW}— 当前内核不支持, 已跳过${RESET}" >&2
        echo -e "    ${MAGENTA}brutal 需要 tcp_brutal 内核模块 (out-of-tree, 2023 年已弃用, 未合入主线)。${RESET}" >&2
        echo -e "    ${MAGENTA}缺它时 sing-box check 仍会通过, 但第一个请求就会断。${RESET}" >&2
        echo -e "    ${MAGENTA}本机可用: $(tr '\\n' ' ' < /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null | sed 's/ $//')${RESET}" >&2
        echo -e "    ${MAGENTA}想要高带宽高延迟链路的收益, 可改用系统级 BBR (本机内核已支持)。${RESET}" >&2
        return 0
    fi
    echo -e "${CYAN}  TCP Brutal 拥塞控制${RESET} ${CYAN}— 按设定带宽硬压发送速率${RESET}" >&2
    echo -e "    ${MAGENTA}填比实际带宽高会丢包重传, 可能比不开更慢; 建议设为实测带宽的 80%%${RESET}" >&2
    echo -e "    ${GREEN}1)${RESET} 关闭" >&2
    echo -e "    ${GREEN}2)${RESET} 开启 (默认 上${SB_BRUTAL_UP_DEFAULT}Mbps / 下${SB_BRUTAL_DOWN_DEFAULT}Mbps)" >&2
    local b
    read -r -p "    请选择 [1-2, 回车=1]: " b || { echo; return 0; }
    b=$(clean_input "$b"); [[ -z "$b" ]] && b=1
    if [[ "$b" == "2" ]]; then
        SB_MUX_BRUTAL=1
        local up dn
        up=$(safe_read "上行带宽 (Mbps)" "$SB_BRUTAL_UP_DEFAULT")
        dn=$(safe_read "下行带宽 (Mbps)" "$SB_BRUTAL_DOWN_DEFAULT")
        [[ "$up" =~ ^[0-9]+$ && "$up" -gt 0 ]] || up=$SB_BRUTAL_UP_DEFAULT
        [[ "$dn" =~ ^[0-9]+$ && "$dn" -gt 0 ]] || dn=$SB_BRUTAL_DOWN_DEFAULT
        SB_MUX_UP=$up; SB_MUX_DOWN=$dn
        print_ok "Brutal: 上 ${up} Mbps / 下 ${dn} Mbps"
    fi
    return 0
}

# 入站 multiplex JSON。服务端没有 protocol 字段, 只有 enabled/padding/brutal。
sb_mux_json_server() {
    [[ "${SB_MUX_ON:-0}" == "1" ]] || return 0
    local b=""
    if [[ "${SB_MUX_BRUTAL:-0}" == "1" ]]; then
        # 服务端的 up/down 要与客户端**对调**: 客户端 up=100 是"我发 100",
        # 服务端视角那就是"我收 100", 落在 down_mbps 上。
        # router.go 里服务端同样按 SendBPS=up_mbps / ReceiveBPS=down_mbps 处理,
        # 所以两端写一样的数字, 方向恰好是反的。
        b=",
        \"brutal\": { \"enabled\": true, \"up_mbps\": ${SB_MUX_DOWN}, \"down_mbps\": ${SB_MUX_UP} }"
    fi
    printf '"multiplex": { "enabled": true%s }' "$b"
}

# 出站 multiplex JSON。protocol/连接数/流数都在这一侧。
sb_mux_json_client() {
    [[ "${SB_MUX_ON:-0}" == "1" ]] || return 0
    local b=""
    [[ "${SB_MUX_BRUTAL:-0}" == "1" ]] && b=",
      \"brutal\": { \"enabled\": true, \"up_mbps\": ${SB_MUX_UP}, \"down_mbps\": ${SB_MUX_DOWN} }"
    printf '"multiplex": { "enabled": true, "protocol": "%s", "max_connections": %s, "min_streams": %s, "max_streams": %s%s }' \
        "${SB_MUX_PROTO:-h2mux}" "${SB_MUX_MAXCONN:-4}" "${SB_MUX_MINSTR:-4}" "${SB_MUX_MAXSTR:-0}" "$b"
}

# mux 相关的分享链接参数。服务端没有 protocol 可选, 因此链接里带的是**客户端**那侧的选择。
sb_mux_link_params() {
    [[ "${SB_MUX_ON:-0}" == "1" ]] || return 0
    local p
    p="&multiplex=1&muxProtocol=${SB_MUX_PROTO:-h2mux}&muxMaxConnections=${SB_MUX_MAXCONN:-4}&muxMinStreams=${SB_MUX_MINSTR:-4}&muxMaxStreams=${SB_MUX_MAXSTR:-0}"
    [[ "${SB_MUX_BRUTAL:-0}" == "1" ]] && p="$p&brutal=1&brutalUpMbps=${SB_MUX_UP}&brutalDownMbps=${SB_MUX_DOWN}"
    printf '%s' "$p"
}
# ALPN: ws/httpupgrade 走 http/1.1, grpc/http 必须走 h2。
# sing-box 的 httpupgrade 在服务端会**禁用 HTTP/2**, 前置层必须用 1.1 回源。
sb_transport_alpn() {
    case "${1:-}" in
        grpc|http) printf '["h2"]' ;;
        *)         printf '["http/1.1"]' ;;
    esac
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
    # 内联判定传输是否支持 CDN, 不依赖 cdn.sh 是否被加载
    # (protocol 脚本不一定加载了 cdn.sh, 调不到就等于"不支持" -> CDN 选项被藏)
    sb_transport_is_http "$ttype" && [[ "$trusted" == "yes" ]] && can_cdn="yes"

    if [[ "$can_cdn" != "yes" ]]; then
        echo "  接入方式:" >&2
        echo "    1) 直连 (监听对外地址, 客户端连 服务器IP:端口)" >&2
        if [[ "$trusted" != "yes" ]]; then
            echo "    [走 CDN 需要真证书 —— Cloudflare 不接受自签证书]" >&2
        else
            echo "    [$ttype 传输不能走 CDN —— Cloudflare 只代理 ws/grpc/http/httpupgrade]" >&2
        fi
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
    # 批量但没开 CDN: 必须是**直连**。
    # 不能掉进下面那个交互菜单 —— 菜单默认是 3 (CDN+Nginx), 而批量下
    # safe_read 直接返回默认值且不读 stdin, 于是每个"真证书 + HTTP 类传输"
    # 的节点都会被静默改成只听 127.0.0.1、客户端连 CDN 域名, 可 nginx 里
    # 根本没有对应 location, 节点彻底连不上。实测批量生成 vless/vmess/
    # trojan 时全部中招。
    if [[ "${SB_BATCH:-}" == "1" ]]; then
        ACCESS_MODE="direct"
        return 0
    fi

    echo "  接入方式:" >&2
    echo "    1) 直连 (推荐, 最简单, 无需 Nginx)" >&2
    echo "    2) CDN 直连 (Cloudflare 回源到本节点端口, 不经 Nginx)" >&2
    echo "    3) CDN + Nginx (推荐: 源站端口不暴露, 隐藏源站 IP)" >&2
    # 预置方案指定了 CDN 就把默认值落到 CDN 接入 (3), 用户仍可改回直连
    local c def=3 ahint=""
    if [[ "${SB_PRESET_CDN:-0}" == "1" ]]; then
        ahint=" (预置方案指定 CDN 接入)"; def=3
    fi
    [[ -n "$ahint" ]] && echo -e "    ${MAGENTA}${ahint}${RESET}" >&2
    c=$(safe_read "选择 (回车=${def})" "$def")
    [[ -z "$c" ]] && c=$def
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
    # 用户明确选了"直连"就不是 CDN 节点。
    # 光看传输+证书会误判: 一个"直连 + 真证书 + ws"的节点完全够得上下面
    # 的 CDN 判据, 于是 sb_cdn_finalize 把它的 listen 改写成 127.0.0.1、
    # 客户端地址改写成证书域名, 而 nginx 里根本没有对应 location ——
    # 表现为"生成成功但永远连不上", 且界面上看不出任何异常。
    case "${ACCESS_MODE:-}" in direct) return 1 ;; esac
    t=$(jq -r '.inbounds[0].transport.type // "tcp"' "$f" 2>/dev/null)
    case "$t" in ws|grpc|http|httpupgrade) ;; *) return 1 ;; esac
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
# 节点名的后缀标识。用户在客户端列表里**只能看到名字**, 没有别的线索,
# 所以方案特征 (REALITY / ECH / padding / 档位) 必须写进名字里。
#   $1 = 传输方式 (reality/tls/plain)
#   $2 = 方案标签 (来自 sb_ask_preset 的 SB_PRESET_TAG, 可为空)
tag_form_suffix() {
    local base
    case "$1" in
        reality) base="-REALITY" ;;
        tls)     base="-TLS" ;;
        *)       base="-plain" ;;
    esac
    # base 已经表达的形态, 标签里就别再写一遍:
    #   reality 形态 + 标签含 REALITY → 否则 "-REALITY-TLS"
    #   tls 形态     + 标签含 TLS     → 否则 "-TLS-TLS"
    # 标签里的 "+" 是给人看的分隔 (ECH+pad), 拼进名字时要换成 "-",
    # 否则会拼出 "TLS-ECHpad" 这种看不出边界的名字。
    local tag="${2:-}"
    case "$1" in
        reality) tag="${tag//REALITY/}" ;;
        tls)     tag="${tag//TLS/}" ;;
    esac
    tag="${tag//+/-}"
    # 去掉首尾的 "-", 否则 base+"-"+空会拼出双横线 (REALITY+pad → -REALITY--pad)
    while [[ "$tag" == -* ]]; do tag="${tag#-}"; done
    while [[ "$tag" == *- ]]; do tag="${tag%-}"; done
    [[ -n "$tag" ]] && printf -- "%s-%s" "$base" "$tag" || printf -- "%s" "$base"
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
      # 必须放在 autosetup 之后: autosetup 只为"仍有节点"的域名重写片段,
      # 已经没有节点的那些域名它根本不会碰, 遗留的 location 就留在站点文件里,
      # Cloudflare 回源会一直 502。
      declare -F sb_cdn_cleanup_stale >/dev/null 2>&1 && sb_cdn_cleanup_stale
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
      sb_cdn_warn_no_http2
      cdn_autosetup
  }

# ---------- gRPC / http(H2) 走 CDN 的前置条件: 站点必须开 HTTP/2 ----------
# 这两种传输跑在 HTTP/2 上, 而 nginx 的 listen 必须真的提供 h2。站点写
# `listen 443 ssl;` 而没有 http2 时, 客户端在 TLS 握手里带 h2、nginx 只答
# http/1.1, 握手直接失败 (no application protocol), 且 **nginx 自己不报错**
# —— 节点看着配好了, 却永远连不上。这里如实检出并给出要加的那一行。
#
# 只做只读检查并提示, 不替用户改他站点的 server 块: 那等于替他决定
# 整站要不要开 h2, 属于会影响他正常网站业务的决定。
sb_cdn_warn_no_http2() {
    declare -F cdn_config_supported >/dev/null 2>&1 || return 0
    declare -F sb_cdn_domain >/dev/null 2>&1 || return 0
    local f t dom=""
    shopt -s nullglob
    for f in "$SB_CONFIG_DIR"/*.json; do
        [[ "$(basename "$f")" =~ ^(00-|01-|02-|03-) ]] && continue
        cdn_config_supported "$f" || continue
        t=$(jq -r '.inbounds[0].transport.type // ""' "$f" 2>/dev/null)
        case "$t" in grpc|http) dom=$(sb_cdn_domain "$f"); break ;; esac
    done
    shopt -u nullglob
    [[ -z "$dom" ]] && return 0
    # 站点配置在哪: 容器化 nginx 与宿主 nginx 路径不同, 两边都看一眼
    local -a cfgs=()
    local site
    for site in /home/web/conf.d /etc/nginx/conf.d /usr/local/nginx/conf /etc/nginx/sites-enabled; do
        [[ -d "$site" ]] || continue
        for f in "$site"/*.conf; do [[ -f "$f" ]] && cfgs+=("$f"); done
    done
    [[ ${#cfgs[@]} -eq 0 ]] && return 0
    local c res
    for c in "${cfgs[@]}"; do
        res=$(python3 "$SELF_DIR/conf/cdn_apply.py" --domain "$dom" \
                --file "$c" --check-http2 2>/dev/null | tr -d '[:space:]')
        [[ "$res" == "OFF" ]] || continue
        print_warn "检测到 gRPC / http(H2) 节点走 CDN, 但站点 $dom 没开 HTTP/2"
        print_warn "  文件: $c"
        print_warn "  这两种传输跑在 HTTP/2 上。nginx 不提供 h2 时, 客户端带 h2 进来而"
        print_warn "  nginx 只答 http/1.1, TLS 握手直接失败, 且 nginx 不会报错。"
        print_warn "  在该 server 块里加一行即可 (nginx >= 1.25.1):"
        print_warn "      http2 on;"
        print_warn "  老写法也可以: 把 listen 443 ssl; 改成 listen 443 ssl http2;"
        return 0
    done
    return 0
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

# Reality short_id: 16 位十六进制 = 8 字节。空串是合法且推荐的值
# (客户端和服务端都允许短到 0 字节), 但随机 8 字节能避免"只有一条连接
# 恰好 short_id 为空才通过"这种可被主动探测利用的特征。
sb_real_shortid() { openssl rand -hex 8 2>/dev/null || echo "$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }

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
# ---------- 全局切换 uTLS 指纹 ----------
# 背景: 指纹原本只能在建节点时逐个选, 想换一套指纹就得重建全部节点 (端口 /
# 凭据全变, 已发出的链接全失效)。而指纹是**纯客户端表现层**的字段, 改它
# 不影响服务端的任何行为 —— 所以单独做一个批量切换, 只重写产物。
#
# 影响范围:
#   JSON: outbounds[].tls.utls.fingerprint  (sing-box 字段名 fingerprint)
#   YAML: client-fingerprint                (由 to_mihomo.py 从 JSON 转换而来)
#   分享链接本身**不含**指纹 (URI 标准没有这个参数), 但改完要重生成, 否则
#   聚合产物和单节点会对不上。
# 不动的: 服务端 config/ 下的任何配置 —— 指纹只出现在客户端出站。
sb_switch_utls_fingerprint() { # <指纹名>
    local fp="${1:-}"
    [[ -n "$fp" ]] || { print_error "用法: sb_switch_utls_fingerprint <指纹名>"; return 1; }
    local ok=0 f
    for f in "${SB_UTLS_FINGERPRINTS[@]}"; do
        [[ "$f" == "$fp" ]] && { ok=1; break; }
    done
    if (( ! ok )); then
        print_error "内核不支持的指纹: $fp"
        print_info "可选: ${SB_UTLS_FINGERPRINTS[*]}"
        return 1
    fi

    local n=0 t
    shopt -s nullglob
    # 1) 单节点 JSON + 聚合 JSON: 改 tls.utls.fingerprint。
    #    没有 tls.utls 的节点 (shadowsocks / naive 这类无 TLS 层的, 或
    #    用户当初就关了 uTLS) 不动它们 —— 凭空给它们加上 utls 反而会写出
    #    连不上的配置。
    for f in "$SB_OUT_DIR"/sb_client-*.json; do
        t=$(basename "$f")
        if jq -e '(.outbounds // []) | any(.tls.utls.enabled == true)' "$f" >/dev/null 2>&1; then
            jq --arg fp "$fp" '(.outbounds[] | select(.tls.utls.enabled == true) | .tls.utls.fingerprint) = $fp' \
                "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" && n=$((n+1)) \
                || print_warn "跳过 $t (改写失败)"
        fi
    done
    shopt -u nullglob
    if (( n == 0 )); then
        print_warn "没有带 uTLS 的产物可改 (shadowsocks / naive 无 TLS 层; 其他节点需在建节点时开启 uTLS)"
        return 1
    fi

    # 2) 重新生成 mihomo YAML —— YAML 的 client-fingerprint 是从 JSON 转换
    #    出来的, 不重转就会与 JSON 不一致 (看着改了其实没改)。
    if declare -F gen_all_mihomo >/dev/null 2>&1; then
        gen_all_mihomo >/dev/null 2>&1
    fi
    if declare -F single_yaml_view >/dev/null 2>&1; then
        local -a jarr=()
        mapfile -t jarr < <(ls "$SB_OUT_DIR"/sb_client-*.json 2>/dev/null | grep -v 'sb_client-all\.json$' | sort)
        (( ${#jarr[@]} )) && python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/to_mihomo.py" \
            --single "$SB_OUT_DIR" "$SB_ROOT/cert" "${jarr[@]}" >/dev/null 2>&1
    fi
    # 3) 聚合 JSON / 分享链接同步重建
    declare -F sb_regen_aggregate >/dev/null 2>&1 && sb_regen_aggregate >/dev/null 2>&1

    # 4) 记下当前值, 让下次进这个菜单能看到
    mkdir -p "$SB_ROOT" 2>/dev/null
    printf '%s\n' "$fp" > "$SB_ROOT/.utls-fp" 2>/dev/null

    print_ok "客户端产物指纹已切换为: $fp"
    print_info "已更新 $n 个 JSON, 并重建了 YAML / 分享链接"
    print_info "服务端配置未改动 —— 指纹只影响客户端出站的 ClientHello 伪装"
    return 0
}

sb_menu_utls_fingerprint() {
    print_title "切换全部客户端产物的 uTLS 指纹"
    local cur="" f
    [[ -f "$SB_ROOT/.utls-fp" ]] && cur=$(head -1 "$SB_ROOT/.utls-fp" 2>/dev/null)
    [[ -z "$cur" ]] && cur="$SB_DEFAULT_UTLS_FP"
    echo
    echo -e "  当前产物指纹: ${YELLOW}${cur}${RESET}" >&2
    echo -e "  ${MAGENTA}这是 ClientHello 伪装 —— 改它不影响服务端, 也不需要重建节点${RESET}" >&2
    echo >&2
    local i=1
    for f in "${SB_UTLS_FINGERPRINTS[@]}"; do
        local mark=" "; [[ "$f" == "$cur" ]] && mark="*"
        echo -e "  ${GREEN}${i})${RESET} ${CYAN}${f}${RESET} ${YELLOW}${mark}${RESET}" >&2
        i=$((i+1))
    done
    echo -e "  ${MAGENTA}全部) 一次性切到同一个指纹${RESET}" >&2
    echo >&2
    local c=""
    read -r -p "  请选择 [1-${#SB_UTLS_FINGERPRINTS[@]}, 回车不变]: " c || { echo; return 0; }
    c=$(clean_input "${c:-}")
    if [[ -z "$c" ]]; then print_info "未选择, 未做修改"; return 0; fi
    if [[ "$c" == "全部" || "$c" == "all" ]]; then
        sb_switch_utls_fingerprint "$SB_DEFAULT_UTLS_FP"
        return $?
    fi
    if [[ ! "$c" =~ ^[0-9]+$ ]] || (( c < 1 || c > ${#SB_UTLS_FINGERPRINTS[@]} )); then
        print_error "无效选项"; return 1
    fi
    local pick="${SB_UTLS_FINGERPRINTS[$((c-1))]}"
    sb_switch_utls_fingerprint "$pick"
}

# REALITY 的 dest 站点必须实测 —— 2026-10 的教训。
#
# 同一份配置 (同密钥/同端口/同协议), 只改 .tls.reality.handshake.server:
#     openjdk.org                      -> 5/5 通
#     images-na.ssl-images-amazon.com  -> 0/5, 客户端 connection reset by peer
# 两个站点从服务端都可达、TLS1.3 正常、HTTP 200、时延 0.2s, short_id 与公钥
# 也完全匹配 —— 纯粹是 REALITY 与该 dest 的握手兼容性。
#
# 本项目的 REALITY dest 直接取证书域名 (见 trojan.sh / vless.sh), 没有独立
# 的候选池, 所以用户拿哪个证书做 REALITY, 就会踩哪个 dest。这里给出实测
# 可靠的名单供参考, 不做硬性限制 —— 站点可用性会随时间变化, 名单会过期。
SB_REALITY_DEST_KNOWN_GOOD="openjdk.org www.mysql.com www.apple.com www.cloudflare.com"
SB_REALITY_DEST_KNOWN_BAD="images-na.ssl-images-amazon.com"

sb_reality_dest_hint() { # 在选证书时提示 REALITY dest 的风险
    print_info "REALITY 提示: dest 取你的证书域名。站点可用性需实测 ——"
    print_info "  实测可用: openjdk.org / www.mysql.com / www.apple.com"
    print_info "  实测不通: images-na.ssl-images-amazon.com (配置全对也 0/N)"
    print_info "  若 REALITY 节点连不上, 先换证书域名再排查其他"
}

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
