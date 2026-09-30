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

default_server_ip() { # 优先公网网卡 IPv4
    local local_ip public_ip
    local_ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 |
        grep -vE '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -1)
    [[ -n "$local_ip" ]] && { echo "$local_ip"; return; }
    public_ip=$(curl -4 -s --max-time 8 ip.sb 2>/dev/null | tr -d '[:space:]')
    [[ -n "$public_ip" ]] && { echo "$public_ip"; return; }
    echo ""
}

# ---- 协议文件编号: <proto>-NN.json ----
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
fw_log_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 0
    mkdir -p "$SB_ROOT" 2>/dev/null
    grep -qxF "$port" "$SB_ROOT/.fw-ports" 2>/dev/null || echo "$port" >> "$SB_ROOT/.fw-ports" 2>/dev/null || true
}

open_port() {
    local port="$1"
    fw_log_port "$port"
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port/tcp" >/dev/null 2>&1
        ufw allow "$port/udp" >/dev/null 2>&1
        print_ok "ufw 已放行 $port (tcp+udp)"
    elif command -v firewall-cmd >/dev/null && firewall-cmd --state 2>/dev/null | grep -q running; then
        firewall-cmd --zone=public --add-port="$port/tcp" --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port="$port/udp" --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        print_ok "firewalld 已放行 $port (tcp+udp)"
    elif command -v iptables >/dev/null; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
        iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$port" -j ACCEPT
        print_ok "iptables 已放行 $port (tcp+udp)"
    else
        print_warn "未检测到防火墙工具，请手动放行 $port"
    fi
}

# ---- 服务 ----
sb_service_active() { systemctl is-active "$SB_SERVICE" >/dev/null 2>&1; }

sb_reload() { # HUP 软重载：check 通过才发；SIGHUP 失败时 sing-box 自动保留旧实例
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
    if ! systemctl reload "$SB_SERVICE" 2>/dev/null; then
        print_warn "systemctl reload 失败，尝试 restart"
    elif sleep 1 && sb_service_active; then
        print_ok "已通过 SIGHUP 软重载（不重启进程，零断流）"
        return 0
    fi
    systemctl restart "$SB_SERVICE"
    sleep 1
    if sb_service_active; then
        print_ok "SIGHUP 软重载失败，已改用 restart 兜底恢复"
        return 0
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
