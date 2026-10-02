#!/usr/bin/env bash
# cdn_menu.sh — CDN 模块的菜单入口

cdn_menu() {
    while true; do
        print_title "CDN / Nginx 前置"
        echo -e "${CYAN}1)${RESET} 自动插入 CDN location 到站点配置 (推荐)"
        echo -e "${CYAN}2)${RESET} 生成完整配置, 整段复制到 Nginx"
        echo -e "${CYAN}3)${RESET} 检测证书 (看有哪些可用)"
        echo -e "${CYAN}4)${RESET} 列出站点 (看域名对应哪个配置文件)"
        echo -e "${CYAN}5)${RESET} 列出节点 (哪些能走 CDN)"
        echo -e "${CYAN}6)${RESET} 生成全部节点的 CDN 版产物 (.cdn.json/.yaml/链接)"
        echo -e "${CYAN}7)${RESET} 移除已插入的 CDN 配置"
        echo -e "${CYAN}8)${RESET} 检查残留 (节点删了配置还在?)"
        echo -e "${CYAN}9)${RESET} CDN 接入说明"
        echo -e "${CYAN}0)${RESET} 返回"
        echo
        # 必须是普通 read, 不能写成 c=$(read ...)。
        # 命令替换会开子 shell, read 把值赋给**子 shell 的** c, 父 shell 拿到的
        # 永远是空 —— 于是 case 全部落空, 菜单 10 的 9 个选项都是空操作,
        # 表现为"选任何一项都直接退回主菜单、什么也没发生"。
        # 这正是用户最早报的"批量生成后去菜单 10 → 1 配 Nginx 却没反应"的根源。
        # lib.sh 的 ask_access_mode 里已经踩过同一个坑并留了注释, 这里又踩了一次。
        # 不能写 2>/dev/null: read -p 的提示语是输出到 **stderr** 的, 那个重定向
        # 会把提示语一起吞掉 —— 菜单画完 10 个选项, 底下却光秃秃什么都没有,
        # 看着就像"菜单坏了"。其他所有菜单(core_menu / net_menu / ...)都没加这个
        # 重定向, 所以只有菜单 10 有这个怪样子。
        # 顺带: 菜单有 1-10 共 10 项, [0-9] 是错的 (同主菜单的老毛病)。
        local c=""
        read -r -p "请选择 [0-10]: " c || return 0
        case "${c// /}" in
            1) cdn_auto_insert ;;
            2) cdn_gen_nginx_conf ;;
            3) cdn_show_certs ;;
            4) cdn_show_sites ;;
            5) cdn_list_nodes ;;
            6) cdn_gen_all_nodes ;;
            7) cdn_auto_remove ;;
            8) cdn_check_orphans ;;
            9) cdn_show_help ;;
            0|"") return 0 ;;
            *) print_warn "无效选项" ;;
        esac
        echo; read -r -p "按回车继续..." _ 2>/dev/null || true
    done
}

# ---------- 查看可走 CDN 的节点 ----------
cdn_list_nodes() {
    local f n=0
    shopt -s nullglob
    printf "${CYAN}%-22s %-8s %-6s %s${RESET}\n" "节点" "传输" "端口" "CDN" >&2
    for f in "$SB_CONFIG_DIR"/*.json; do
        [[ "$(basename "$f")" =~ ^(00-|01-|02-|03-) ]] && continue
        local tag t port ok="✗" why=""
        tag=$(jq -r '.inbounds[0].tag' "$f" 2>/dev/null)
        t=$(jq -r '.inbounds[0].transport.type // "tcp"' "$f" 2>/dev/null)
        port=$(jq -r '.inbounds[0].listen_port' "$f" 2>/dev/null)
        if cdn_config_supported "$f"; then
            ok="✓ 可走"
        else
            cdn_transport_supported "$t" || why="$t 不支持"
            if [[ -z "$why" ]]; then
                local crt; crt=$(jq -r '.inbounds[0].tls.certificate_path // ""' "$f")
                [[ -n "$crt" ]] && why="自签证书" || why="无 TLS"
            fi
        fi
        printf "  %-22s %-8s %-6s %-8s %s\n" "$tag" "$t" "$port" "$ok" "$why" >&2
    done
    shopt -u nullglob
    echo >&2
    print_info "可走 CDN: $n 个" 2>/dev/null
    print_info "只有 ws/grpc/http(2) + 真证书才能走 CDN" 2>/dev/null
}

# ---------- 证书检测 ----------
cdn_show_certs() {
    if ! sb_scan_certs; then
        print_error "未检测到可用证书"
        print_warn "CDN 回源需要真证书 (Cloudflare Origin 证书 或 Let's Encrypt)"
        print_warn "请放到以下任一目录后重新检测:"
        for d in "$SB_ROOT/cert" /etc/letsencrypt/live /root/.acme.sh /etc/nginx/certs /root/catmi/cloudflare/certs; do
            print_warn "  $d/"
        done
        return 1
    fi
    print_ok "检测到 ${#sb_FOUND_CERTS[@]} 张可用证书:"
    local e crt key dom
    for e in "${sb_FOUND_CERTS[@]}"; do
        crt="${e%%|*}"; key="${e#*|}"; key="${key%%|*}"
        dom=$(cdn_cert_domain "$crt")
        printf "  %-52s\n" "$crt" >&2
        printf "    私钥: %s\n" "$key" >&2
        printf "    域名: %s%s\n" "${dom:-未知}" "$(cert_not_expired "$crt" && echo '  (未过期)' || echo '  (已过期!)')" >&2
    done
}

# ---------- 列出你的站点 ----------
cdn_show_sites() {
    local probe out
    probe=$(cdn_probe_nginx)
    local kind=${probe%%$'\t'*} rest=${probe#*$'\t'}
    local container=${rest%%$'\t'*} dir=${rest##*$'\t'}

    case "$kind" in
        docker) print_info "检测到 Nginx 运行在 Docker 容器: $container"
                print_info "配置来源: $dir" ;;
        host)   print_info "检测到 Nginx 运行在宿主 (systemd)" ;;
        *)      print_warn "未自动检测到 Nginx —— 可在下方手工指定站点配置文件" ;;
    esac
    echo
    local n=0 dn file
    while IFS='|' read -r dn file; do
        [[ -z "$dn" ]] && continue
        local tls="无 TLS(不能回源)"
        cdn_site_has_tls "$file" && tls="有 TLS ✓"
        printf "  %-40s %-12s %s\n" "$dn" "$tls" "$file" >&2
        n=$((n+1))
    done < <(cdn_list_sites)
    echo
    (( n == 0 )) && print_warn "没找到已配置的站点 server_name"
    return 0
}

# ---------- 孤儿检测 ----------
# 节点被删除后, nginx 里对应的 location 不会自动消失 —— 因为插入是
# "整块替换", 只在下次生成时才同步。若长期不重新生成, 就会出现:
#   - location 指向一个已经不存在的端口, 请求打过来 502
#   - 更糟: 端口被系统里别的服务复用, 代理指向了错误的目标
# 所以提供显式检测, 让人能随时核对"配置与实际节点是否还对得上"。
cdn_check_orphans() {
    local dn file f port line
    local -A live_ports=()
    shopt -s nullglob
    for f in "$SB_CONFIG_DIR"/*.json; do
        [[ "$(basename "$f")" =~ ^(00-|01-|02-|03-) ]] && continue
        port=$(jq -r '.inbounds[0].listen_port // empty' "$f" 2>/dev/null)
        [[ -n "$port" ]] && live_ports["$port"]=1
    done
    shopt -u nullglob

    local n=0
    while IFS='|' read -r dn file; do
        [[ -z "$dn" || -z "$file" ]] && continue
        [[ -f "$file" ]] || continue
        # 只看 SB-Panel 自己生成的块, 别人手写的不管
        grep -q "SB-Panel CDN" "$file" 2>/dev/null || continue
        while read -r line; do
            port=$(printf '%s' "$line" | grep -oE '127\.0\.0\.1:[0-9]+' | head -1 | cut -d: -f2)
            [[ -z "$port" ]] && continue
            if [[ -z "${live_ports[$port]:-}" ]]; then
                print_warn "  $dn 站点里有指向已不存在端口 $port 的 location"
                n=$((n+1))
            fi
        done < <(sed -n '/SB-Panel CDN 开始/,/SB-Panel CDN 结束/p' "$file" | grep -oE 'proxy_pass[^;]*;' | tr ';' '\n')
    done < <(cdn_list_sites)

    if (( n == 0 )); then
        print_ok "配置与实际节点一致, 没有指向已删除节点的残留"
    else
        print_info ""
        print_info "用菜单 1 重新生成即可同步 (会整块替换已插入的内容)"
    fi
}

# ---------- 自动插入 ----------
# 生成完 CDN 节点后自动把 nginx 配好 —— 批量和单协议共用这一个入口。
# 之前两条路径都只打印一句"请到菜单 10 → 1", 有的甚至什么都不说, 节点
# 的 server 已经是 CDN 域名而 nginx 里没有对应 location, 连不上也无从查起。
cdn_autosetup() {
      # 没有任何走 CDN 的节点就别刷屏
      local f n=0
      shopt -s nullglob
      for f in "$SB_CONFIG_DIR"/*.json; do
          [[ "$(basename "$f")" =~ ^(00-|01-|02-|03-) ]] && continue
          sb_cdn_enabled "$f" && n=$((n+1))
      done
      shopt -u nullglob
      if (( n == 0 )); then return 0; fi
      print_title "自动配置 Nginx (CDN)"
      cdn_auto_insert
  }
  

cdn_auto_insert() {
    local tmp; tmp=$(mktemp)
    local frag; frag="$SB_OUT_DIR/sb_cdn-nginx-location.conf"

    print_info "生成 CDN location 片段..."
    cdn_gen_nginx_conf "$frag" >/dev/null || { print_error "没有可走 CDN 的节点"; rm -f "$tmp"; return 1; }

    # 从片段里读回要处理哪些域名
    local domains
    # 域名从 BEGIN 标记里取。
    # 原来匹配的是 "# 粘贴到 server_name X;" 那行注释, 配置头部改版后那行已经
    # 没了 —— 自动插入会因此认为"片段里没有域名信息"直接报错退出。
    # BEGIN 标记是配置本身的组成部分, 不会因为排版调整消失, 比注释可靠。
    domains=$(grep -oE '^# >>> SB-Panel CDN BEGIN [^>]+ >>>' "$frag" 2>/dev/null \
              | sed 's/^# >>> SB-Panel CDN BEGIN //; s/ >>>$//' | sort -u)
    if [[ -z "$domains" ]]; then
        print_error "片段里没有域名信息"; rm -f "$tmp"; return 1
    fi

    echo
    print_info "将处理以下域名:"
    echo "$domains" | sed 's/^/    /' >&2
    echo

    local dn target nfile=0 ok=0
    for dn in $domains; do
        target=$(cdn_find_site_file "$dn")
        if [[ -z "$target" ]]; then
            print_warn "找不到 $dn 的站点配置文件 —— 已跳过 (绝不猜路径)"
            print_warn "  可用菜单 2 手工复制片段"
            continue
        fi
        if ! cdn_site_has_tls "$target"; then
            print_error "$dn 的站点没有 ssl_certificate, Cloudflare 无法回源"
            print_warn "  请先在 $target 里配置证书"
            continue
        fi
        nfile=$((nfile+1))
        print_info "→ $dn : $target"
        # 先把将要写入的内容摘要打出来再改文件 —— 出问题时能立刻看出
        # 是哪几条 location 被写进了哪个文件。
        print_info "  将写入的 location:"
        grep -E "^[[:space:]]*location /|proxy_pass" "$frag" 2>/dev/null \
            | sed 's/^[[:space:]]*/    /'
        echo >&2
        # 不能写成 `if python3 ... | sed ...; then` —— 管道的退出码取自最后一个
        # 命令(sed), python3 失败也被判成成功, 于是明明没插入却报 [OK]。
        # 实测踩过: $SELF_DIR 为空导致 cdn_apply.py 找不到文件, 照样显示"已成功插入"。
        # 这里先跑 python3 拿退出码, 再单独把输出过滤一遍。
        local rc=0 outf
        outf=$(mktemp)
        python3 "$SELF_DIR/conf/cdn_apply.py" --domain "$dn" --file "$target" \
             --block "$frag" --nginx "$(cdn_nginx_mode)" >"$outf" 2>&1 || rc=$?
        sed 's/^/    /' < "$outf"
        rm -f "$outf"
        if (( rc == 0 )); then
            ok=$((ok+1))
        else
            print_error "  ↑ 该站点插入失败 (退出码 $rc), 未做任何修改"
        fi
    done

    echo
    rm -f "$tmp"

      if (( ok > 0 )); then
          print_ok "已成功插入 $ok 个站点的 CDN 配置"
          # 插入成功但没重载 = 配置没生效, 节点照样连不上。
          # reload 是平滑的(不断现有连接), 交给用户自己跑等于让功能半残。
          cdn_nginx_reload
      else
          print_error "没有任何站点被自动修改"
      fi

    # 关键: 自动没做成的, 一律给出片段让用户手工粘贴。
    # 自动化只是省事, 不是唯一路径 —— nginx 配置出错代价高, 必须留手工兜底。
    local need=0
    for dn in $domains; do
        target=$(cdn_find_site_file "$dn")
        if [[ -z "$target" ]] || ! grep -q "SB-Panel CDN" "$target" 2>/dev/null; then
            need=1
        fi
    done

    if (( need == 1 )); then
        echo
        print_info "════════ 以下配置需要你手工粘贴 ════════"
        print_info "自动插入没能覆盖的站点, 请把对应片段粘进该站点 server{} 内 (location / 之前)"
        echo
        cat "$frag"
        echo
        print_info "════════════════════════════════════════"
    fi

    print_info ""
    print_info "重载命令 (请自己执行, 自动化不碰你的服务):"
    print_info "  docker exec nginx nginx -s reload    (Docker 部署)"
    print_info "  systemctl reload nginx               (宿主部署)"
    return 0
}

# ---------- 移除已插入的配置 ----------
cdn_auto_remove() {
    local dn target n=0
    local -a doms=()
    while IFS='|' read -r dn target; do
        [[ -n "$dn" ]] && doms+=("$dn")
    done < <(cdn_list_sites)

    if ((${#doms[@]} == 0)); then
        print_warn "没有找到站点, 无法移除"; return 1
    fi
    for dn in "${doms[@]}"; do
        target=$(cdn_find_site_file "$dn")
        [[ -z "$target" ]] && continue
        grep -q "SB-Panel CDN" "$target" 2>/dev/null || continue
        print_info "→ $dn : $target"
        # 同 cdn_auto_insert: 管道的退出码取自 sed, python3 失败也会 +1,
        # 于是"其实没删掉"被报成"已移除"。先取退出码再过滤输出。
        local rc=0 of
        of=$(mktemp)
        python3 "$SELF_DIR/conf/cdn_apply.py" --domain "$dn" --file "$target" \
            --remove --nginx "$(cdn_nginx_mode)" >"$of" 2>&1 || rc=$?
        sed 's/^/    /' < "$of"
        rm -f "$of"
        (( rc == 0 )) && n=$((n+1)) || print_error "  ↑ 移除失败 (退出码 $rc)"
    done
    (( n == 0 )) && { print_info "没有找到已插入的 CDN 配置"; return 0; }
    print_ok "已移除 $n 处"
    # 配置改了不重载 = 仍生效在旧规则上, 等于没删
    cdn_nginx_reload
}

# ---------- 接入说明 ----------
cdn_show_help() {
    cat >&2 <<'EOF'

  Cloudflare CDN 接入原理
  ────────────────────────
    客户端 ──► Cloudflare 边缘 ──(回源443)──► Nginx ──(按 path)──► sing-box

  好处: 隐藏源站 IP、免费换 IP、扛 DDoS、绕封锁。

  哪些能走 CDN
  ─────────────
    ✓ WebSocket (ws)      vless / vmess / trojan
    ✓ gRPC                 vless / vmess / trojan
    ✓ HTTP/2 (h2)          vless / vmess / trojan
    ✗ REALITY / AnyTLS / Hysteria2 / TUIC / Shadowsocks / naive / ShadowTLS
      这些是原生 TCP/UDP 或专用协议, Cloudflare 代理不了, 必须直连。

  三个必要条件
  ─────────────
    1. 节点用「真证书」而不是自签 —— Cloudflare 只认受信任 CA 签发的证书
    2. 节点监听 127.0.0.1 —— 端口不对外暴露, 这是 CDN 生效的前提
    3. Nginx 承接 443 并按 path 转发到各节点端口

  面板做什么 / 不做什么
  ──────────────────────
    ✓ 自动检测你的证书 (复用既有扫描逻辑, 不新生成)
    ✓ 自动检测 Nginx 部署方式 (Docker / 宿主), 定位域名对应的站点文件
    ✓ 自动把 location 插入**已有**的 server{} 块内 (不新建 server 块)
    ✓ 插入前备份, 插入后 nginx -t 校验, 不通过自动回滚
    ✗ 不自动重载 nginx —— 重载会影响你的其它服务, 留给你确认后自己执行
    ✗ 不碰站点里 location / 等已有规则 —— 只增加自己的 location 块

EOF
}