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

# 本文件由 run_module 以独立 bash 进程执行, **不会**继承主脚本 source 的
# lib.sh —— 下面这些 print_* 是本文件自己定义的。同理 fw_detect_backend
# 也在 lib.sh 里, 不加载就是空命令, clean_fw 会静默走错分支。
# 这里主动加载一次 (重复 source 无害), 拿不到就退化为本文件自带的实现。
if [[ -f "$SELF_DIR/conf/lib.sh" && -z "${SB_UNINSTALL_LIB_LOADED:-}" ]]; then
    SB_UNINSTALL_LIB_LOADED=1
    # shellcheck disable=SC1091
    source "$SELF_DIR/conf/lib.sh" 2>/dev/null || true
fi
# 兜底: lib.sh 不可用时至少保证后端判定不会返回空
if ! declare -F fw_detect_backend >/dev/null 2>&1; then
    fw_detect_backend() {
        nft list table inet filter >/dev/null 2>&1 && { echo nft; return; }
        command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active" && { echo ufw; return; }
        command -v firewall-cmd >/dev/null && firewall-cmd --state 2>/dev/null | grep -q running && { echo firewalld; return; }
        command -v iptables >/dev/null && { echo iptables; return; }
        echo none
    }
fi

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

# 收集 sing-box 自身配置里的所有监听端口 —— 这是"该端口属于本面板"的权威证据。
# 只看配置, 不看防火墙: 防火墙全表混着系统与其他服务的规则, 无法据此判断归属。
# 必须在删除 $SB_ROOT 之前调用, 之后配置就没了。
collect_own_ports() {
    SB_OWN_PORTS=$(jq -r '.inbounds[]?.listen_port // empty' \
        "$SB_CONFIG_DIR"/*.json 2>/dev/null | grep -E '^[0-9]+$' | sort -un)
}

# 清理防火墙 —— 三重校验后才删
#
# 安全设计 (曾因扫全表按端口号猜而误删 SSH 规则导致服务器失联):
#   1. 绝不扫描防火墙全表, 只处理 .fw-ports 登记过的端口。
#   2. 必须能在 sing-box 配置里查到该端口 —— 查不到 = 无法证明属于本面板 = 不删。
#      (端口被释放后若被别的服务接管, 配置里就没有它了, 从而不会误删他人规则)
#   3. sshd 正在监听的端口一律不删; 系统常用端口硬性黑名单。
#   4. 逐条打印, 输入 yes 才执行。
# 防火墙清理被取消时, 由 clean_fw 填充: 这些端口的规则会留成孤儿。
# 删掉 $SB_ROOT 之后就再也认不出归属, 只能手工一条条删。
SB_FW_ORPHANS=()

clean_fw() {
    local list="$SB_ROOT/.fw-ports"
    if [[ ! -f "$list" ]]; then
        print_warn "未找到端口记录 ($list), 无需清理防火墙"
        return 0
    fi
    collect_own_ports
    local p
    local -a deletable=() unverified=()
    while read -r p; do
        [[ -n "$p" ]] || continue
        if ! printf '%s\n' "$SB_OWN_PORTS" | grep -qx "$p"; then
            unverified+=("$p"); continue
        fi
        case "$p" in
            22|2222|2200|80|443|8080|8443|9090|9900|3389|21|25|53|110|143|465|587|993|995|1433|1521|2049|3306|5432|6379|11211|27017)
                unverified+=("$p (系统常用端口)"); continue ;;
        esac
        local _sshd
        _sshd=$(ss -Hltnp 2>/dev/null | grep -i sshd | grep -oE ':[0-9]+[[:space:]]' | tr -d ' :')
        if printf '%s\n' "$_sshd" | grep -qx "$p"; then
            unverified+=("$p (sshd 正在监听)"); continue
        fi
        deletable+=("$p")
    done < <(tr -d ' \r' < "$list" | grep -E '^[0-9]+$' | sort -un)

    if (( ${#unverified[@]} )); then
        print_warn "以下端口无法确认属于本面板 (配置中查不到), 已保留不动:"
        printf "    %s\n" "${unverified[@]}" >&2
    fi
    if (( ${#deletable[@]} == 0 )); then
        print_warn "没有可安全清理的端口, 已跳过"
        return 0
    fi
    print_warn "以下 ${#deletable[@]} 个端口经 sing-box 配置确认属于本面板:"
    printf "    %s\n" "${deletable[@]}" >&2
    # 外层问的是 [y/N], 用户十有八九回 "y"; 这里原本却只认字面的 "yes",
    # 于是几乎每次都会被判成"已取消", 然后流程继续往下删 $SB_ROOT ——
    # 防火墙规则留成孤儿, 而判断归属要读的 config/*.json 已经被删光,
    # 之后再也无法清理。
    local a
    read -r -p "确认删除这些防火墙规则? [y/N]: " a
    case "$(echo "$a" | tr A-Z a-z)" in
        y*|yes*) ;;
        *) print_warn "已取消, 未修改防火墙"
           # 记下还有哪些端口会留成孤儿, 由调用方在删目录前严肃提醒
           SB_FW_ORPHANS=("${deletable[@]}")
           return 1 ;;
    esac
    # 后端判定必须与 open_port / close_node_port 用同一个 fw_detect_backend。
    # 之前这里写死只处理 ufw/firewalld, 而放行规则是 open_port 按
    # fw_detect_backend 的结果加的 —— 在没有 ufw (firewalld 也没装) 的机器上
    # fw_detect_backend 返回 iptables, 规则是用 iptables 加的, 卸载却因为
    # "未检测到 ufw/firewalld" 直接不做任何修改。实测卸载后残留 26 条规则。
    local n=0 p proto be h
    be=$(fw_detect_backend)
    case "$be" in
        nft)
            for p in "${deletable[@]}"; do
                while read -r h; do
                    [[ "$h" =~ ^[0-9]+$ ]] || continue
                    nft delete rule inet filter input handle "$h" >/dev/null 2>&1 && n=$((n+1))
                done < <(nft -a list chain inet filter input 2>/dev/null \
                          | grep -E "dport ${p}([[:space:]]|$)" \
                          | grep -v 'UFW_PANEL_SSH' \
                          | grep -oE "handle [0-9]+" | awk '{print $2}')
            done
            # 清掉本面板自己的持久化文件, 否则重启后规则又被写回来
            [[ -n "${SB_NFT_OWN_FILE:-}" ]] && : > "$SB_NFT_OWN_FILE" 2>/dev/null
            ;;
        ufw)
            for p in "${deletable[@]}"; do
                ufw delete allow "$p/tcp" >/dev/null 2>&1 && n=$((n+1))
                ufw delete allow "$p/udp" >/dev/null 2>&1 && n=$((n+1))
            done
            ;;
        firewalld)
            for p in "${deletable[@]}"; do
                firewall-cmd --zone=public --remove-port="$p/tcp" --permanent >/dev/null 2>&1 && n=$((n+1))
            done
            firewall-cmd --reload >/dev/null 2>&1
            ;;
        iptables)
            for p in "${deletable[@]}"; do
                for proto in tcp udp; do
                    if iptables -C INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null; then
                        iptables -D INPUT -p "$proto" --dport "$p" -j ACCEPT >/dev/null 2>&1 && n=$((n+1))
                    fi
                done
            done
            ;;
        *)
            print_warn "未检测到可用的防火墙后端, 未做修改"
            return 0
            ;;
    esac
    print_ok "防火墙规则已清理 ($n 条, 后端 $be)"
    print_warn "提示: 若卸载后无法 SSH, 请用云控制台放行本机 SSH 端口"
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
    # 防火墙清理必须在删除目录之前 —— 它要读 config/*.json 判断端口归属
    read -r -p "是否一并清理防火墙规则 (只删 sing-box 配置中确认属于本面板的端口)? [y/N]: " f
    case "$(echo "$f"|tr A-Z a-z)" in
        y*|yes*) clean_fw || true ;;
        *) print_warn "保留防火墙规则 (可手动: ufw status 查看)"
           SB_FW_ORPHANS=() ;;
    esac
    # 防火墙规则没清掉却要删目录 = 制造永久孤儿。
    # 规则认不出来源 (判断归属依赖的 config/*.json 就在这个目录里), 端口又被占着,
    # 只能手工一条条去 iptables 里挖。所以这里拦一下, 要求二次确认。
    if (( ${#SB_FW_ORPHANS[@]} )); then
        print_warn "警告: 以下 ${#SB_FW_ORPHANS[@]} 个端口的防火墙规则会被永久留下"
        printf "    %s\n" "${SB_FW_ORPHANS[@]}" >&2
        print_warn "删除 $SB_ROOT 后, 面板将无法再判断这些规则是否属于自己"
        local ow
        read -r -p "仍要继续卸载 (留下这些孤儿规则)? [y/N]: " ow
        case "$(echo "$ow" | tr A-Z a-z)" in
            y*|yes*) ;;
            *) print_warn "已中止卸载 (防火墙规则与 $SB_ROOT 均保持原样)"
               return 0 ;;
        esac
    fi
    # Nginx 里的 CDN 片段必须单独问。
    # 它写的是**用户自己的站点配置文件**(如 /etc/nginx/conf.d/xxx.conf), 不在
    # SB-Panel 目录内, 所以下面删 $SB_ROOT 不会带走它 —— 卸载完 nginx 里会留着
    # 一堆指向已删端口的 location, Cloudflare 回源直接 502。
    # 只删本面板带标记的那一段(BEGIN/END 之间), 其余配置一个字都不动。
    # 站点配置目录必须走 cdn_config_roots 探测, 不能写死 /etc/nginx/conf.d:
    # Docker 部署常把宿主机目录挂进容器 (如宿主 /home/web/conf.d -> 容器的
    # /etc/nginx/conf.d), 只扫宿主机这两个标准路径会一个都找不到,
    # 于是"要不要清 CDN 配置"这个问题**根本不会问**, 卸载完 nginx 里
    # 留着一堆指向已删端口的 location, Cloudflare 回源直接 502。
    local _has_cdn=0 _f _dir _d
    _d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$_d/cdn_nginx.sh" ]]; then
        source "$_d/cdn_nginx.sh" 2>/dev/null
    fi
    if declare -F cdn_config_roots >/dev/null 2>&1; then
        while read -r _dir; do
            [[ -d "$_dir" ]] || continue
            for _f in "$_dir"/*.conf; do
                [[ -f "$_f" ]] || continue
                grep -q "SB-Panel CDN" "$_f" 2>/dev/null && { _has_cdn=1; break 2; }
            done
        done < <(cdn_config_roots 2>/dev/null)
    fi
    if (( _has_cdn )); then
        read -r -p "是否一并移除 Nginx 里 SB-Panel 插入的 CDN 配置? [Y/n]: " n
        case "$(echo "$n" | tr A-Z a-z)" in
            n*) print_warn "保留 Nginx CDN 配置 (可稍后用菜单 10 → 7 移除)" ;;
            *)  bash "$SELF_DIR/conf/cdn.sh" remove >/dev/null 2>&1 \
                    && print_ok "Nginx CDN 配置已移除" \
                    || print_warn "自动移除失败, 请用菜单 10 → 7 手动移除" ;;
        esac
    fi
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
