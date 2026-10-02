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

# 放行一个端口 (ufw / firewalld / iptables); install.sh 不依赖 lib.sh, 故自带一份
open_port() {
    local port="$1"
    # 登记到 .fw-ports, 供卸载时按清单清理 (不扫全表, 避免误删系统规则)
    if [[ -n "${SRV_ROOT:-}" ]]; then
        mkdir -p "$SRV_ROOT" 2>/dev/null
        grep -qxF "$port" "$SRV_ROOT/.fw-ports" 2>/dev/null || echo "$port" >> "$SRV_ROOT/.fw-ports" 2>/dev/null || true
    fi
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port/tcp" >/dev/null 2>&1 || return 1
    elif command -v firewall-cmd >/dev/null && firewall-cmd --state 2>/dev/null | grep -q running; then
        firewall-cmd --zone=public --add-port="$port/tcp" --permanent >/dev/null 2>&1 || return 1
        firewall-cmd --reload >/dev/null 2>&1
    elif command -v iptables >/dev/null; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
            || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
    else
        return 1   # 没有防火墙工具: 不算失败, 但也无法保证对外
    fi
    return 0
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
            (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null || continue
            exec 3<&- 2>/dev/null; exec 3>&- 2>/dev/null
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
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

sb_pick_proxy() { # 安装时让用户选下载通道; 默认直连
    # 已显式配置: 不打扰
    if [[ -n "${https_proxy:-}${http_proxy:-}" ]]; then
        info "下载通道: 环境变量 ${https_proxy:-$http_proxy}"
        return 0
    fi
    sb_proxy_scan
    (( ${#SB_PROXY_CANDS[@]} == 0 )) && return 0   # 没代理 -> 静默直连
    # 非交互: 静默直连
    [[ -t 0 ]] || return 0
    warn "检测到本机可用代理 (内核/UI 将从 GitHub 下载):"
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
        ok "下载通道: ${SB_PROXY_CANDS[$((c-1))]}"
    else
        ok "下载通道: 直连"
    fi
    return 0
}

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

# ==================== 进入面板前的自动更新 ====================
#
# 目标: 每次用 `bash <(curl -Ls .../install.sh)` 进面板时自动比对 GitHub,
#       有新版就静默更新, 不用再手动输 u。
#
# 铁律: **任何情况下都不能把人挡在面板外面**。
#   fetch() 网络失败会 die 直接退出整个脚本 —— 自动更新绝不能走那条路:
#   GitHub 连不上只是"这次没更新成", 用本地版本继续才是对的。所以这里用
#   fetch_soft, 它只返回状态码, 从不退出。
#   状态码: 0=已更新  10=已是最新  2=取不到(网络/仓库)  3=取到了但落地失败
#
fetch_soft() {
    local cur new
    if [[ -d "$SRC_DIR/.git" ]]; then
        git -C "$SRC_DIR" fetch -q --depth 1 origin main 2>/dev/null || return 2
        cur=$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null)
        new=$(git -C "$SRC_DIR" rev-parse FETCH_HEAD 2>/dev/null)
        [[ -z "$cur" || -z "$new" ]] && return 2
        [[ "$cur" == "$new" ]] && return 10
        git -C "$SRC_DIR" reset -q --hard "$new" 2>/dev/null || return 3
        return 0
    fi
    # 没有源码缓存 (tarball 装的老用户): 重新取一份
    git clone -q --depth 1 "$REPO" "$SRC_DIR" 2>/dev/null \
      || { curl -fsSL --max-time 90 "$REPO/archive/refs/heads/main.tar.gz" -o /tmp/sbcore.tar.gz 2>/dev/null \
           && mkdir -p "$SRC_DIR" \
           && tar -xzf /tmp/sbcore.tar.gz -C "$SRC_DIR" --strip-components=1 2>/dev/null; } \
      || return 2
    [[ -f "$SRC_DIR/src/conf/lib.sh" ]] || return 2
    return 0
}

# 备份当前脚本, 供更新失败时回滚。静默更新必须留退路 —— 自动改自己的代码,
# 万一新版有问题, 没有备份就只能靠用户手工抢救了。
backup_scripts() {
    local b="$SRV_ROOT/backup/scripts-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$b" 2>/dev/null || { printf ''; return 1; }
    cp -rf "$SRV_ROOT/conf" "$b/" 2>/dev/null
    cp -f  "$SRV_ROOT/sing-box.sh" "$b/" 2>/dev/null
    printf '%s' "$b"
}

restore_scripts() {
    local b="$1"
    [[ -d "$b" ]] || return 1
    cp -rf "$b/conf/." "$SRV_ROOT/conf/" 2>/dev/null
    cp -f  "$b/sing-box.sh" "$SRV_ROOT/" 2>/dev/null
    chmod +x "$SRV_ROOT/sing-box.sh" "$SRV_ROOT/conf/"*.sh 2>/dev/null
    return 0
}

# 更新后的脚本必须全部能通过语法检查, 否则立刻回滚。
# 语法错误的面板会直接起不来, 而用户此刻正要进面板 —— 那就等于把门锁死了。
scripts_sane() {
    local f
    for f in "$SRV_ROOT"/sing-box.sh "$SRV_ROOT"/conf/*.sh; do
        [[ -f "$f" ]] || continue
        bash -n "$f" 2>/dev/null || return 1
    done
    if [[ -f "$SRV_ROOT/conf/share_server.py" ]]; then
        python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" \
            "$SRV_ROOT/conf/share_server.py" 2>/dev/null || return 1
    fi
    return 0
}

# 自动更新。返回 0=更新了  10=已是最新  其它=没更新成(调用方照常进面板)
auto_update() {
    local rc=0 t0=$SECONDS
    fetch_soft || rc=$?
    case $rc in
        10) return 10 ;;
        2)  warn "暂时连不上 GitHub, 这次跳过更新 (不影响使用)"; return 2 ;;
        3)  warn "获取新版时出错, 已保留本地版本"; return 1 ;;
    esac

    local ver; ver=$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null)
    local bak; bak=$(backup_scripts)
    [[ -n "$bak" ]] || warn "备份目录创建失败, 继续更新 (出问题请手动回滚)"

    rsync_files >/dev/null 2>&1

    if ! scripts_sane; then
        warn "新版脚本没通过语法检查, 已自动回滚"
        restore_scripts "$bak" && ok "已回滚到更新前的版本"
        return 1
    fi

    # 配置检查失败只警告不阻断: 脚本本身没问题, 多半是用户自己的配置需要调整,
    # 进面板后按提示处理即可, 不该为此拦住更新。
    config_ok || warn "配置检查未通过, 脚本已更新; 进面板后按提示排查即可"
    ok "已自动更新到最新版本 (${ver:-未知})  [$((SECONDS - t0))s]"
    [[ -n "$bak" ]] && info "旧版本备份: $bak"
    return 0
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
            # 防火墙必须放行 9292, 否则服务只在 localhost 自检通过, 外部客户端连不上
            if open_port 9292 >/dev/null 2>&1; then
                ok "分享服务 (9292, 防火墙已放行)"
            else
                warn "分享服务 (9292) 已启动, 但防火墙放行失败"
                warn "  分享链接仅本机可用; 请手动放行: ufw allow 9292/tcp"
            fi
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
    # 已装机器: 只更新脚本, 绝不碰用户配置 (端口/监听/节点都是用户自己设的)
    local already=0
    [[ -f "$CLI_ROOT/conf/00-mixed.json" ]] && already=1
    if (( already )); then info "更新客户端脚本"; else info "正在初始化 Sing-box 客户端..."; fi
    mkdir -p "$CLI_ROOT"/{conf,core,nodes,share-state,ui} /usr/local/bin || die "目录创建失败"
    cp -f "$SRC_DIR/src/client/client.sh" /usr/local/bin/sb-client || die "复制失败"
    chmod +x /usr/local/bin/sb-client
    ok "项目文件"
    if [[ ! -x "$CLI_ROOT/core/sing-box" ]]; then
        info "正在安装 Sing-box 内核..."
        sb_pick_proxy
        CLIENT_ROOT="$CLI_ROOT" bash /usr/local/bin/sb-client install >/dev/null 2>&1 || die "Sing-box 内核下载失败"
        ok "Sing-box 核心 ($("$CLI_ROOT/core/sing-box" version 2>/dev/null | head -1))"
    fi
    if (( already )); then
        # 已有配置: 只做 systemd 服务补齐 + 配置校验, 不重新生成 00-mixed/01-clash
        CLIENT_ROOT="$CLI_ROOT" bash /usr/local/bin/sb-client service >/dev/null 2>&1 || true
        if CLIENT_ROOT="$CLI_ROOT" bash /usr/local/bin/sb-client check >/dev/null 2>&1; then
            ok "配置检查"
        else
            warn "配置检查未通过 (未做任何修改), 请运行客户端面板 12 查看详情"
        fi
    else
        CLIENT_ROOT="$CLI_ROOT" bash /usr/local/bin/sb-client init >/dev/null 2>&1 || die "客户端初始化失败"
        ok "基础配置 + 服务已就绪"
    fi
    if [[ -f "$CLI_ROOT/ui/index.html" ]]; then
        ok "Web UI 已存在 (如需更新请用面板: 客户端设置 → Web UI → 重新下载)"
    else
        CLIENT_ROOT="$CLI_ROOT" bash /usr/local/bin/sb-client install-ui >/dev/null 2>&1 && ok "Web UI (metacubexd)" || warn "UI 下载失败, 可稍后 bash sb-client install-ui"
    fi
    echo
    # 端口从实际配置读取, 不用硬编码 —— 用户可能已经改过端口/监听地址
    local mport mlisten cctrl cport chost mhost lanip
    mport=$(jq -r '.inbounds[]?|select(.type=="mixed")|.listen_port // 2080' "$CLI_ROOT/conf/00-mixed.json" 2>/dev/null); mport="${mport:-2080}"
    mlisten=$(jq -r '.inbounds[]?|select(.type=="mixed")|.listen // "0.0.0.0"' "$CLI_ROOT/conf/00-mixed.json" 2>/dev/null); mlisten="${mlisten:-0.0.0.0}"
    cctrl=$(jq -r '.experimental.clash_api.external_controller // "0.0.0.0:19090"' "$CLI_ROOT/conf/01-clash.json" 2>/dev/null); cctrl="${cctrl:-0.0.0.0:19090}"
    cport="${cctrl##*:}"; chost="${cctrl%:*}"
    lanip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    # 监听 0.0.0.0 时局域网可达, 显示真实 LAN IP; 监听 127.0.0.1 时只有本机可用
    case "$mlisten" in 0.0.0.0|"::"|"") mhost="${lanip:-127.0.0.1}" ;; *) mhost="127.0.0.1" ;; esac
    case "$chost"  in 0.0.0.0|"::"|"") chost="${lanip:-127.0.0.1}" ;; *) chost="127.0.0.1" ;; esac
    printf "  HTTP/SOCKS: http://%s:%s\n" "$mhost" "$mport"
    printf "  Clash API:  http://%s:%s\n" "$chost" "$cport"
    [[ -f "$CLI_ROOT/ui/index.html" ]] && printf "  Web UI:     http://%s:%s/ui/  (密钥见面板 11 项)\n" "$chost" "$cport"
    echo "--------------------------------"
    ok "客户端安装完成"
    read -r -p "按回车进入管理面板..." _
    CLIENT_ROOT="$CLI_ROOT" bash /usr/local/bin/sb-client
}

# 已装机器重复运行: 不覆盖配置, 交给面板
existing() {
    printf "${GREEN}Sing-box 管理脚本${PLAIN}\n"
    echo "----------------------"
    local srvSta=$(systemctl is-active sing-box 2>/dev/null || echo inactive)
    local col="$RED"; [[ $srvSta == active ]] && col="$GREEN"
    printf "服务状态: %b%s%b\n" "$col" "$srvSta" "$PLAIN"
    printf "版本:     %s\n" "$(server_ver)"
    printf "节点数:   %s\n" "$(ls "$SRV_ROOT"/config/*.json 2>/dev/null | grep -cv '^-')"
    echo "----------------------"
    # 自动比对 GitHub: 有新版就静默更新, 没新版直接进面板。
    # 原来是问 "输入 u 为更新脚本" —— 但更新这件事本来就不该要人记得去做,
    # 你往往就是忘了才连不上某个新功能, 还得专门进一次菜单补更新。
    # 这里不再询问; 失败也不阻断进面板 (见 auto_update 的注释)。
    local rc=0
    auto_update || rc=$?
    [[ $rc -eq 10 ]] && ok "当前已是最新版本"
    echo
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
