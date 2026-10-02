#!/bin/bash
# ==============================================================
# batch.sh — 全协议一键生成 (Batch Generator)
#   * 公共参数只问一次: 对外地址 / 证书方案 / 端口范围 / CDN 策略,
#     其余全用各协议自带默认生成逻辑
#   * 证书: SB_BATCH_CERT=real|self 配 SB_BATCH_CERT_CRT/KEY/DOMAIN 下发;
#     选真证书时 CDN 自动沿用同一张, 选自签时 CDN 需另选一张可信证书
#   * 地址族: SB_LISTEN_ADDR (服务端 bind) 与 SB_SERVER_ADDR (写进客户端配置)
#     分开设置 —— 可以只让 IPv6 连进来, 但配置里仍然发 IPv4
#   * 不重新实现协议: 直接调用 conf/<proto>.sh 现有 add_config 流程
#   * 幂等: 协议已有节点 → 跳过不覆盖
#   * 原子性: 每协议 write_config + 全目录 sing-box check 失败自动清理自身
#   * 服务: 批量期间 SB_NO_RELOAD=1; 收尾统一 check + 一次 reload
#   * 分享: 完全复用 share.sh create-all / regen-aggregate
# 依赖: conf/lib.sh 里的 SB_BATCH (safe_read/safe_read_port/read 覆盖) + SB_NO_RELOAD
# ==============================================================
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SB_LIB="${SB_LIB:-$SELF_DIR/conf/lib.sh}"
[[ -f "$SB_LIB" ]] && source "$SB_LIB"

# 协议 + Reality 变体说明
#   reality = VLESS+REALITY; vmess/trojan 会追加 Reality 第二形态
#   anytls  = 同一模块内选配 (默认纯 AnyTLS; 若勾 Reality 则为 AnyTLS+REALITY)
#   批量里 anytls 走默认形态 (非 Reality), 这样"一键生成"产出的节点
#   在 mihomo 客户端里也能直接用。
PROTOS=(reality hysteria2 anytls vless shadowsocks tuic vmess trojan naive shadowtls)
BATCH_ANSWERS_OVERRIDE=""

# 节点的真实 tag 藏在配置的 outbounds 里, 不能拿文件名去推。
# 文件名是 vmess-01, 但 tag 是 vmess01-TLS / vmess02-REALITY —— 形态后缀不同,
# 于是 `rm sb_client-$tag.json` 删的是 sb_client-vmess01.json, 而实际产物叫
# sb_client-vmess01-TLS.json, 永远删不到。旧节点就这样一天天堆在 out/ 里,
# 最后全量聚合把它们一起打进了要发给客户端的那份配置。
node_tags_of() {
    # 读 inbounds 而不是 outbounds —— 服务器配置里根本没有 outbounds 字段,
    # 只有 inbounds; 一开始写错成 .outbounds, jq 静默返回空, 于是清理等于没做。
    jq -r '.inbounds[]?.tag' "$1" 2>/dev/null
}

# 清掉"已经没有任何节点"的产物文件。
# 按 tag 逐个删只能保证往后不再堆积, 之前删掉的节点留下的旧文件还在,
# 它们会被全量聚合一起打进要发给客户端的配置里 —— 客户端拿到一堆连不上的死节点。
prune_orphan_artifacts() {
    local live f base tag n=0
    live=$(mktemp)
    for f in "$SB_CONFIG_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        case "$(basename "$f" .json)" in 00-*) continue;; esac
        node_tags_of "$f" >> "$live"
    done
    sort -u -o "$live" "$live"
    for f in "$SB_OUT_DIR"/sb_client-*.json "$SB_OUT_DIR"/sb_client-*.yaml; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f")
        [[ "$base" == "sb_client-all."* ]] && continue
        tag="${base#sb_client-}"
        # shadowtls 内层 (xxxinner) 没有独立产物, 不参与孤儿判定
        [[ "$tag" == *.inner ]] && continue
        tag="${tag%.*}"
        grep -qxF "$tag" "$live" || { rm -f "$f"; n=$(( n + 1 )); }
    done
    rm -f "$live"
    (( n > 0 )) && print_ok "清理残留产物 $n 个 (节点已不存在, 此前一直混在聚合配置里)"
    return 0
}

drop_node_artifacts() { # drop_node_artifacts <tag...>
    local t
    for t in "$@"; do
        [[ -n "$t" ]] || continue
        rm -f "$SB_OUT_DIR/sb_client-$t.json" "$SB_OUT_DIR/sb_client-$t.yaml" \
              "$SB_OUT_DIR/sb_client-$t.cdn.json" "$SB_OUT_DIR/sb_client-$t.1.json" \
              "$SB_OUT_DIR/sb_client-$t.2.json" \
              "$SB_OUT_DIR/sb_share-$t.txt" "$SB_OUT_DIR/sb_meta-$t.json"
        cleanup_node_shares "$t"
    done
}

latest_file() { ls "$SB_CONFIG_DIR"/${1}-*.json 2>/dev/null | sort | tail -1; }
tag_of() { basename "$(latest_file "$1")" .json | tr -d '-'; }

########## 清空全部节点 (wipe) ##########
# 用途: 分享链接已发出/疑似暴露时, 一次性删光所有节点并吊销全部分享令牌,
#       避免逐个协议菜单手工 del (shadowtls 还是两个出站, 尤其麻烦)。
# 安全: 二次确认必须显式输入 yes; 基础骨架 (00-base.json / cert / reality-keys) 保留;
#       删除后统一 check + reload, 失败则从备份恢复。
wipe_all_nodes() {
    mkdir -p "$SB_CONFIG_DIR" "$SB_OUT_DIR"
    # 按协议白名单收集, 而不是按文件名黑名单。
    # 基础设施 (00-log/00-route/01-dns/02-rule-set/03-route ...) 不是协议配置,
    # 早先用黑名单只挡了 00-*, 结果 01-dns.json 被当协议配置删掉,
    # 出站引用的 dns-local 随之消失, sing-box check 直接 FATAL
    # (default domain resolver not found: dns-local)。白名单不会误伤。
    # 除协议节点外, 端口转发 / 出站也一并清掉:
    # 它们同样是会对外监听并承载流量的 inbound (portforward 是 type:direct),
    # 用户"分享的东西暴露了要全部收回"的意图下, 留着它们等于敞着口子。
    local -a WIPE_EXTRA=(portforward outbound)
    local -a victims=()
    local proto f
    for proto in "${PROTOS[@]}" "${WIPE_EXTRA[@]}"; do
        for f in "$SB_CONFIG_DIR"/${proto}-*.json; do
            [[ -f "$f" ]] && victims+=("$f")
        done
    done

    print_title "清空全部节点"
    if (( ${#victims[@]} == 0 )); then
        print_warn "当前没有协议节点配置, 无需清空"
    else
        printf "将删除 %d 个协议配置文件:\n" "${#victims[@]}" >&2
        for f in "${victims[@]}"; do printf "  - %s\n" "$(basename "$f")" >&2; done
        printf "同时删除全部客户端产物 / 分享链接文件, 吊销所有分享令牌 (旧链接立即 404),\n" >&2
        printf "并一并删除端口转发 (portforward) 与出站 (outbound) 配置 —— 它们的端口也会关闭.\n" >&2
        printf "${RED}基础骨架与证书会保留; 之后可重新一键生成.%b\n" "$RESET" >&2
        echo >&2
        read -r -p "确认清空? 输入 yes (其它任何输入=取消): " w
        if [[ "$(clean_input "$w")" != "yes" ]]; then
            print_warn "已取消, 未做任何改动"
            return 0
        fi
    fi

    # 自己建备份目录, 不靠 "ls -t 取最新" —— 万一 backup_config 这次没建成,
    # 取最新会拿到一个**历史**备份, 回滚就会把服务器恢复到一个错误的时间点。
    local bdir; bdir=$(mktemp -d "$SB_BACKUP_DIR/$(date +%Y%m%d-%H%M%S)-wipe-XXXXXX" 2>/dev/null)
    if [[ -n "$bdir" && -d "$SB_CONFIG_DIR" ]]; then
        mkdir -p "$bdir/config"
        cp -a "$SB_CONFIG_DIR/." "$bdir/config/"
        print_ok "已备份到: $bdir"
    else
        bdir=""
        print_warn "未创建备份目录; 若清空后校验失败将无法自动回滚"
    fi
    backup_config config >/dev/null 2>&1
    local n=0 t tags=()
    for f in "${victims[@]}"; do
        tags=()
        while read -r t; do [[ -n "$t" ]] && tags+=("$t"); done < <(node_tags_of "$f")
        rm -f "$f"
        (( ${#tags[@]} )) && drop_node_artifacts "${tags[@]}"
        n=$(( n + 1 ))
    done
    # 兜底: 任何形态的残留产物
    rm -f "$SB_OUT_DIR"/sb_client-*.json "$SB_OUT_DIR"/sb_client-*.yaml \
          "$SB_OUT_DIR"/sb_share-*.txt "$SB_OUT_DIR"/sb_meta-*.json \
          "$SB_OUT_DIR/sb_client-all.json" "$SB_OUT_DIR/sb_client-all.yaml" \
          "$SB_OUT_DIR/sb_links-all.txt"
    # 吊销全部分享令牌 (含 all 聚合分享) —— 旧链接立刻失效
    local shares_dir="$SB_ROOT/share/shares"
    local revoked=0
    if [[ -d "$shares_dir" ]]; then
        for sf in "$shares_dir"/*.json; do
            [[ -f "$sf" ]] || continue
            rm -f "$sf"; revoked=$(( revoked + 1 ))
        done
    fi

    if ! sb_check; then
        print_error "清空后配置校验失败, 自动从备份回滚"
        if [[ -n "$bdir" && -d "$bdir/config" ]]; then
            rm -f "$SB_CONFIG_DIR"/*.json
            cp -a "$bdir/config/." "$SB_CONFIG_DIR/"
            print_ok "已回滚到: $bdir/config"
            # 节点配置回来了, 但客户端产物/分享令牌已被删除且无法自动重建
            # (产物是各协议 add_config 时按当时的密钥/密码写出的, 没有"从配置反推"的入口)
            rm -f "$SB_OUT_DIR"/sb_client-*.json "$SB_OUT_DIR"/sb_client-*.yaml \
                  "$SB_OUT_DIR"/sb_share-*.txt "$SB_OUT_DIR"/sb_meta-*.json \
                  "$SB_OUT_DIR/sb_client-all.json" "$SB_OUT_DIR/sb_client-all.yaml" \
                  "$SB_OUT_DIR/sb_links-all.txt"
            print_warn "注意: 客户端产物与分享链接已一并清除, 需重新「一键生成」或重新创建分享"
        else
            print_error "未找到可用备份, 请手工从 $SB_BACKUP_DIR 恢复"
        fi
        sb_check && sb_reload || print_error "回滚后仍异常, 请立即手工检查"
        return 1
    fi
    sb_reload || print_warn "请手动确认服务状态"
    print_ok "已清空: $n 个节点配置, 吊销 $revoked 个分享令牌 (旧链接已立即失效)"
}

########## 覆盖模式: 清掉本协议已有配置 ##########
wipe_proto() { # wipe_proto <proto> —— 覆盖模式下先删该协议全部配置
    local proto="$1" f n=0
    local tags=() t
    for f in "$SB_CONFIG_DIR"/${proto}-*.json; do
        [[ -f "$f" ]] || continue
        while read -r t; do [[ -n "$t" ]] && tags+=("$t"); done < <(node_tags_of "$f")
        rm -f "$f"
        n=$(( n + 1 ))
    done
    (( ${#tags[@]} )) && drop_node_artifacts "${tags[@]}"
    return 0
}

########## 主流程 ##########
batch_main() {
    mkdir -p "$SB_CONFIG_DIR" "$SB_OUT_DIR"
    init_base >/dev/null 2>&1 || true

    echo >&2
    print_title "全协议一键生成"
    echo -e "${CYAN}交互项: 对外地址 → 证书方案 → 端口范围 → CDN. 其余沿用各协议默认值.${RESET}" >&2
    echo -e "${CYAN}如端口被占用或配置失败, 会自动清理; 收尾统一 check + reload.${RESET}" >&2

    # --- 服务端监听: 不问, 统一双栈 ---
    # :: 在 bindv6only=0 时同时收 IPv4 和 IPv6, 严格优于 0.0.0.0, 没有理由
    # 让用户为一个更差的选项做选择。走 CDN 的节点要只听本机, 那是**接入
    # 方式**决定的, 由各协议脚本在 ACCESS_MODE 出来后自行写死。
    # 真正需要区分 IPv4/IPv6 的是下面第二问: 客户端配置里写哪个地址。
    local a4 a6
    a4=$(sb_addr4); a6=$(sb_addr6)
    SB_LISTEN_ADDR="$SB_LISTEN_DEFAULT"
    echo >&2
    if [[ "$SB_LISTEN_ADDR" == "::" ]]; then
        print_ok "服务端监听: :: (IPv4+IPv6 双栈, 无需选择)"
        [[ -z "$a6" ]] && print_warn "本机无可用 IPv6, 双栈监听下只有 IPv4 客户端能连"
        [[ "$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo 0)" == "1" ]] && \
            print_warn "net.ipv6.bindv6only=1: 监听 :: 只收 IPv6, IPv4 会连不上"
    else
        print_warn "本机内核未启用 IPv6, 已退回 0.0.0.0 (仅 IPv4)"
    fi

    echo >&2
    echo -e "${CYAN}① 客户端配置里写哪个地址 —— 别人拿到配置后连的是这个${RESET}" >&2
    [[ -n "$a4" ]] && echo -e "   ${GREEN}1)${RESET} IPv4  ${CYAN}$a4${RESET}" >&2 || echo -e "   ${MAGENTA}(无 IPv4)${RESET}" >&2
    [[ -n "$a6" ]] && echo -e "   ${GREEN}2)${RESET} IPv6  ${CYAN}$a6${RESET}" >&2 || echo -e "   ${MAGENTA}(无 IPv6)${RESET}" >&2
    echo -e "   ${MAGENTA}选 IPv6 前请确认客户端网络真能出 IPv6 —— 写进去连不上更麻烦${RESET}" >&2
    cur_fam=$(sb_addr_family_get); [[ "$cur_fam" == "v6" ]] && cur_fam=2 || cur_fam=1
    local sch=""
    read -r -p "   请选择 [1-2, 回车=$([[ "$cur_fam" == 2 ]] && echo IPv6 || echo IPv4)]: " sch
    case "$(clean_input "${sch:-}")" in
      2) [[ -n "$a6" ]] || print_warn "本机无 IPv6"
         SB_SERVER_ADDR="$a6"; sb_addr_family_set v6
         print_ok "客户端配置写入 IPv6 $a6" ;;
      *) SB_SERVER_ADDR="$a4"; [[ -z "$a4" ]] && SB_SERVER_ADDR="$(default_server_ip)"
         sb_addr_family_set v4
         print_ok "客户端配置写入 IPv4 $SB_SERVER_ADDR" ;;
    esac
    export SB_LISTEN_ADDR SB_SERVER_ADDR

    # --- 第三次交互: 证书方案 ---
    # 单协议创建时本来就能选"真证书 / 自签", 批量却一直是硬编码走自签 ——
    # 于是机器上明明有一堆 Let's Encrypt 真证书, 批量出来的节点全在用自签,
    # 发给不支持 SPKI pin 的客户端 (mihomo 等) 直接连不上。
    # 这里补上前置提问, 并把选中的证书通过环境变量传给所有协议。
    SB_BATCH_CERT=real; SB_BATCH_CERT_CRT=""; SB_BATCH_CERT_KEY=""; SB_BATCH_CERT_DOMAIN=""
    local ncert=0
    sb_scan_certs >/dev/null 2>&1 && ncert=${#sb_FOUND_CERTS[@]}
    sb_scan_nginx_sites
    echo >&2
    echo -e "${CYAN}② 证书方案 —— 节点用什么证书对外服务${RESET}" >&2
    if (( ncert > 0 )); then
        echo -e "   ${GREEN}1)${RESET} ${CYAN}使用本机真实证书${RESET} (检测到 ${ncert} 张 CA 可信证书)" >&2
    else
        echo -e "   ${MAGENTA}1) 使用本机真实证书 —— 本机没检测到任何证书${RESET}" >&2
    fi
    echo -e "   ${GREEN}2)${RESET} ${YELLOW}自签证书${RESET} (伪装成随机大站域名, 客户端用 SPKI pin 锁定)" >&2
    echo -e "   ${MAGENTA}真实证书=任何客户端都能连; 自签=仅支持 pin 的客户端能连${RESET}" >&2
    local cch=""
    read -r -p "   请选择 [1-2, 回车=$([[ $ncert -gt 0 ]] && echo 1 || echo 2)]: " cch
    case "$(clean_input "${cch:-}")" in
      2) SB_BATCH_CERT=self; print_ok "证书: 自签 (各节点用 domains.sh 随机域名)" ;;
      *) if (( ncert > 0 )); then
           SB_BATCH_CERT=real
           pick_trusted_cert_verbose || { print_error "证书选择失败"; return 1; }
           SB_BATCH_CERT_CRT="$CERT_FILE"; SB_BATCH_CERT_KEY="$KEY_FILE"; SB_BATCH_CERT_DOMAIN="$CERT_DOMAIN"
           print_ok "证书: 真证书 $CERT_DOMAIN"
         else
           SB_BATCH_CERT=self
           print_warn "本机没有真实证书, 改用自签"
         fi ;;
    esac
    export SB_BATCH_CERT SB_BATCH_CERT_CRT SB_BATCH_CERT_KEY SB_BATCH_CERT_DOMAIN

    # --- 第三次交互: 端口范围 ---
    local r
    if [[ -n "${SB_BATCH_AUTO:-}" ]]; then
        SB_BATCH_PORT_START=$(( 20000 + RANDOM % 10000 ))
        SB_BATCH_PORT_END=$(( SB_BATCH_PORT_START + 5000 ))
        print_ok "批量自动端口区间: $SB_BATCH_PORT_START-$SB_BATCH_PORT_END"
    else
        echo >&2
        read -r -p "端口范围 (如 20000-25000, 回车=自动): " r
        r=$(clean_input "$r")
        if [[ -z "$r" ]]; then
            SB_BATCH_PORT_START=$(( 20000 + RANDOM % 10000 ))
            SB_BATCH_PORT_END=$(( SB_BATCH_PORT_START + 5000 ))
            print_ok "批量自动端口区间: $SB_BATCH_PORT_START-$SB_BATCH_PORT_END"
        else
            SB_BATCH_PORT_START="${r%%-*}"; SB_BATCH_PORT_END="${r##*-}"
            [[ "$SB_BATCH_PORT_START" =~ ^[0-9]+$ && "$SB_BATCH_PORT_END" =~ ^[0-9]+$ ]] || { print_error "格式: 起始-结束"; return 1; }
            (( SB_BATCH_PORT_START < SB_BATCH_PORT_END && SB_BATCH_PORT_END <= 65535 )) || { print_error "范围无效 (beg<g_end<=65535)"; return 1; }
        fi
    fi
    export SB_BATCH_PORT_START SB_BATCH_PORT_END

      # --- 第四次交互: CDN 策略 ---
      # 能走 CDN 的协议: vless / vmess / trojan (传输 ws/grpc/http/httpupgrade + 真证书)。
      # 其余协议是原生 TCP/UDP 或专用协议, Cloudflare 代理不了, 只能直连。
      # 这里默认开启: 反正只有这两个协议受影响, 开不开都由协议本身决定,
      # 不需要为"不支持 CDN 的协议"单独做任何事。
      local SB_BATCH_CDN=0 SB_BATCH_CDN_DOMAIN=""
      if sb_scan_certs >/dev/null 2>&1; then
          local cdn_dom cdn_first
          cdn_first="${sb_FOUND_CERTS[0]%%|*}"
          cdn_dom=$(extract_cert_domain "$cdn_first")
          echo >&2
          print_info "检测到 ${#sb_FOUND_CERTS[@]} 张真证书 (可用于 CDN 回源)"
          printf "  CDN 模式: 1) vless/vmess 自动走 CDN (推荐)  2) 全部直连 [默认 1]: " >&2
          read -r -p "  " rc 2>/dev/null
          rc=$(clean_input "${rc:-}")
          [[ "$rc" == "2" ]] || { SB_BATCH_CDN=1; SB_BATCH_CDN_DOMAIN="$cdn_dom"; }
          if (( SB_BATCH_CDN )); then
              # ② 选了真证书 -> CDN 直接沿用同一张, 不必再问
              if [[ "$SB_BATCH_CERT" == "real" && -n "$SB_BATCH_CERT_DOMAIN" ]]; then
                  SB_BATCH_CDN_DOMAIN="$SB_BATCH_CERT_DOMAIN"
                  print_ok "已启用 CDN: 沿用②选的证书 $SB_BATCH_CDN_DOMAIN"
              else
                  # ② 选了自签 -> 自签证书 Cloudflare 一律拒绝回源,
                  # 必须单独挑一张 CA 可信证书, 这里列出来让用户选
                  echo >&2
                  print_info "③ 选了自签证书, Cloudflare 不接受自签回源 —— 请为 CDN 单独选一张真证书:"
                  if pick_trusted_cert_verbose; then
                      SB_BATCH_CDN_DOMAIN="$CERT_DOMAIN"
                      print_ok "CDN 使用证书: $SB_BATCH_CDN_DOMAIN"
                  else
                      print_warn "未选择 CDN 证书, 本次不启用 CDN"
                      SB_BATCH_CDN=0; SB_BATCH_CDN_DOMAIN=""
                  fi
              fi
              (( SB_BATCH_CDN )) && print_ok "vless / vmess 将用 $SB_BATCH_CDN_DOMAIN 回源, 并只监听 127.0.0.1"
          fi
      else
          print_warn "未检测到真证书 (Cloudflare 不接受自签回源) —— 本次全部只能直连"
      fi
      export SB_BATCH_CDN SB_BATCH_CDN_DOMAIN
    rm -f "$SB_OUT_DIR/.batch-used" "$SB_OUT_DIR/.batch-port"

    # --- 覆盖模式: 跳过已有 (幂等) / 覆盖全部 (先删后建) ---
    local -a existing=()
    local ep
    for ep in "${PROTOS[@]}"; do
        [[ -n "$(latest_file "$ep")" ]] && existing+=("$ep")
    done
    local SB_OVERWRITE=0
    if (( ${#existing[@]} > 0 )); then
        echo >&2
        print_title "检测到已存在的协议"
        printf "  %s\n" "${existing[@]}" >&2
        echo >&2
        printf "覆盖会先删除上述协议的现有节点再重新生成。\n" >&2
        printf "  ${YELLOW}会更换: 监听端口 / password / uuid / 证书 / Reality ShortID${RESET}\n" >&2
        printf "  ${YELLOW}不会更换: REALITY 长期密钥对 (与 reality.sh 共享, 保持不变)${RESET}\n" >&2
        printf "  ${YELLOW}结果: 已发出的分享链接会立即失效 (端口/凭据都变了)${RESET}\n" >&2
        # 已显式要求覆盖 (菜单 3 / SB_BATCH_OVERWRITE=1) 就不再问; 否则问一次
        if [[ "${SB_BATCH_OVERWRITE:-0}" == "1" ]]; then
            SB_OVERWRITE=1
        else
            echo >&2
            read -r -p "如何处理? 1) 跳过已有 (幂等)  2) 覆盖全部 [默认 1]: " oc
            oc=$(clean_input "$oc"); [[ -z "$oc" ]] && oc=1
            [[ "$oc" == "2" ]] && SB_OVERWRITE=1
        fi
        if (( SB_OVERWRITE )); then
            print_warn "覆盖模式: 将先删除 ${#existing[@]} 个协议的现有节点"
            for ep in "${existing[@]}"; do
                wipe_proto "$ep"
                printf "  %b✓ %s 已清空%b\n" "$GREEN" "$ep" "$RESET" >&2
            done
            # 覆盖后旧令牌已无意义, 全部吊销
            [[ -d "$SB_ROOT/share/shares" ]] && rm -f "$SB_ROOT/share/shares"/*.json
        else
            print_ok "跳过模式: 已存在的协议不会被改动"
        fi
    fi
    export SB_OVERWRITE

    backup_config config >/dev/null 2>&1

    echo >&2
    print_title "批量生成开始"
    local -a ok_list=(); local -a fail_list=(); local -a skip_list=()
    local proto r
    for proto in "${PROTOS[@]}"; do
        printf "%b• %s%b ... " "$CYAN" "$proto" "$RESET" >&2
        if [[ -n "$(latest_file "$proto")" ]]; then
            printf "%b[已存在]%b 跳过 (幂等)\n" "$YELLOW" "$RESET" >&2
            skip_list+=("$proto"); continue
        fi
        SB_BATCH=1 SB_NO_RELOAD=1 \
          SB_BATCH_CDN="${SB_BATCH_CDN:-0}" SB_BATCH_CDN_DOMAIN="${SB_BATCH_CDN_DOMAIN:-}" \
          SB_LISTEN_ADDR="$SB_LISTEN_ADDR" SB_SERVER_ADDR="$SB_SERVER_ADDR" \
          SB_BATCH_CERT="$SB_BATCH_CERT" SB_BATCH_CERT_CRT="$SB_BATCH_CERT_CRT" \
          SB_BATCH_CERT_KEY="$SB_BATCH_CERT_KEY" SB_BATCH_CERT_DOMAIN="$SB_BATCH_CERT_DOMAIN" \
        SB_BATCH_PORT_START="$SB_BATCH_PORT_START" SB_BATCH_PORT_END="$SB_BATCH_PORT_END" \
        SB_BATCH_TRANSPORT="${SB_BATCH_TRANSPORT:-ws}" \
        timeout 240 bash "$SELF_DIR/conf/${proto}.sh" add </dev/null >/tmp/batch-$proto.log 2>&1
        local mod_rc=$?
        if [[ $mod_rc -eq 0 ]]; then
            printf "%b[OK]%b 生成\n" "$GREEN" "$RESET" >&2
            ok_list+=("$proto")
        else
            printf "%b[失败]%b (详见 /tmp/batch-%s.log)\n" "$RED" "$RESET" "$proto" >&2
            fail_list+=("$proto")
        fi
    done

    # --- Reality 变体补齐 (vmess/trojan 双形态: run2 以 SB_BATCH_ANSWERS 选择 4/3 Reality) ---
    # anytls 也在列: 它本来就有 Reality 分支 (anytls.sh ask_cert 的 c=3),
    # 只是上面那两行的判断顺序让它在批量里永远走不到, 已一并修正。
    local -a variant_list=(vmess trojan anytls)
    for i in "${!variant_list[@]}"; do
        local vp="${variant_list[$i]}"
        printf "%b• %s 变体%b ... " "$CYAN" "$vp" "$RESET" >&2
        local second=""; 
        ls "$SB_CONFIG_DIR"/${vp}-02.json >/dev/null 2>&1 && {
            printf "%b[已存在]%b Reality 变体已生成\n" "$YELLOW" "$RESET" >&2
            continue
        }
        # 用显式环境变量指定形态, 不用 SB_BATCH_ANSWERS:
        # safe_read() 在 SB_BATCH 下直接返回默认值且不消费答案队列, 靠应答串
        # 定位提问会整体错位 (历史上 4 被当成"传输方式", Reality 变体退化成 plain)。
        # SB_FORCE_TLS_REALTY=1 让 ask_tls/ask_cert 直接选 Reality, 跳过交互。
          SB_BATCH_CDN=0 \
        SB_BATCH=1 SB_NO_RELOAD=1 SB_FORCE_TLS_REALTY=1 \
        SB_BATCH_PORT_START="$SB_BATCH_PORT_START" SB_BATCH_PORT_END="$SB_BATCH_PORT_END" \
        SB_BATCH_TRANSPORT="${SB_BATCH_TRANSPORT:-ws}" \
        timeout 240 bash "$SELF_DIR/conf/${vp}.sh" add </dev/null >/tmp/batch-$vp-v.log 2>&1
        if [[ $? -eq 0 ]]; then
            printf "%b[生成]%b Reality 变体\n" "$GREEN" "$RESET" >&2
        else
            printf "%b[失败]%b (详见 /tmp/batch-%s-v.log)\n" "$RED" "$RESET" "$vp" >&2
        fi
    done

    # --- 全目录统一 check ---
    echo >&2
    if ! sb_check; then
        print_error "全协议批量验证失败 (错误见上); 坏配置已在各模块内自动删除"
        unset SB_BATCH SB_NO_RELOAD
        return 1
    fi

    # --- 一次统一 reload ---
    unset SB_NO_RELOAD
    sb_reload
    unset SB_BATCH

    # --- CDN 汇总 ---
    # 批量生成时能走 CDN 的节点 (ws/grpc/http + 真证书) 已被切成 CDN 模式,
    # 这里一次性列出来并提示下一步, 免得再逐个进节点菜单去找。
    echo >&2
    print_title "CDN 汇总"
    local cdn_n=0 cdn_f
    shopt -s nullglob
    for cdn_f in "$SB_CONFIG_DIR"/*.json; do
        [[ "$(basename "$cdn_f")" =~ ^(00-|01-|02-|03-) ]] && continue
        sb_cdn_enabled "$cdn_f" && cdn_n=$((cdn_n + 1))
    done
    shopt -u nullglob
    if (( cdn_n > 0 )); then
        print_ok "$cdn_n 个节点已走 CDN 模式 (客户端连域名:443, 源站端口不对外暴露)"
    else
        print_info "本次没有节点走 CDN"
        print_info "  CDN 需同时满足: 传输为 ws/grpc/http(2)  且  使用真证书"
        print_info "  批量生成默认用自签证书, 而 Cloudflare 不接受自签回源, 只能直连"
    fi
    echo >&2

    # --- 汇总 (节点信息 + 服务状态) ---
    echo >&2
    print_title "SB 全协议生成完成"
    local f tag port reality_enabled form
    for proto in "${PROTOS[@]}"; do
        f=$(latest_file "$proto")
        if [[ -z "$f" ]]; then
            printf " ✗ %-14s (无节点)\n" "$proto" >&2; continue
        fi
        tag=$(basename "$f" .json | tr -d '-')
        port=$(jq -r '.inbounds[0].listen_port' "$f" 2>/dev/null)
        reality_enabled=$(jq -r '.inbounds[0].tls.reality.enabled // false' "$f" 2>/dev/null)
        if [[ "$reality_enabled" == "true" ]]; then form="REALITY"
        elif jq -e '.inbounds[0].tls' "$f" >/dev/null 2>&1; then form="TLS"
        else form="裸网(无TLS)"; fi
        printf " ✓ %-14s tag=%-14s 端口=%-6s 形态=%s\n" "$proto" "$tag" "$port" "$form" >&2
        if [[ "$reality_enabled" == "true" ]]; then
            printf "     Reality 公钥=%s  ShortID=%s\n" \
                "$(jq -r .public_key "$SB_OUT_DIR/reality-keys.json" 2>/dev/null)" \
                "$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$f" 2>/dev/null)" >&2
        fi
        local pw uuid user
        pw=$(jq -r '.inbounds[0].users[0].password // .password // empty' "$f" 2>/dev/null)
        uuid=$(jq -r '.inbounds[0].users[0].uuid // empty' "$f" 2>/dev/null)
        [[ -n "$pw" ]] && printf "     password=%.24s…\n" "$pw" >&2
        [[ -n "$uuid" ]] && printf "     uuid=%s\n" "$uuid" >&2
    done
    echo >&2
    [[ ${#ok_list[@]} -gt 0 ]] && printf "%b生成成功:%b %s\n" "$GREEN" "$RESET" "${ok_list[*]}" >&2
    [[ ${#skip_list[@]} -gt 0 ]] && printf "%b已存在(跳过):%b %s\n" "$YELLOW" "$RESET" "${skip_list[*]}" >&2
    [[ ${#fail_list[@]} -gt 0 ]] && printf "%b失败(需检查):%b %s\n" "$RED" "$RESET" "${fail_list[*]}" >&2 && \
        for p in "${fail_list[@]}"; do echo "  --- $p ---"; tail -3 "/tmp/batch-$p.log" 2>/dev/null; done >&2

    # 先清掉无主的旧产物, 再生成聚合 —— 顺序反了聚合就会把死节点带进去
    prune_orphan_artifacts

    # --- 分享链接统一输出 (复用 share.sh) ---
    echo >&2
    printf "${CYAN}════ 分享链接 ════${RESET}\n" >&2
    bash "$SELF_DIR/conf/share.sh" create-all </dev/null 2>&1 | grep -E "http://|已创建" | tail -2 >&2 || true

    show_service
      show_service
      
      # CDN 节点生成完就把 nginx 配好。之前这里只打印一句"请到菜单 10 → 1",
      # 节点的 server 已经是 CDN 域名, 而 nginx 里没有对应 location,
      # 节点连不上, 用户却只能自己再走一遍菜单才知道该做什么。
      sb_cdn_autosetup
      print_ok "全协议一键生成 流程结束"
}

show_service() {
    local st; st=$(systemctl is-active "${SB_SERVICE:-sing-box}" 2>/dev/null || echo unknown)
    if [[ "$st" == "active" ]]; then
        printf "${GREEN}服务状态: 运行中${RESET}\n" >&2
    else
        printf "${RED}服务状态: %s${RESET}\n" "$st" >&2
    fi
}

main() {
    while true; do
        print_title "全协议一键生成 (Batch Generator)"
        echo -e "${CYAN}1)${RESET} 全协议生成 (默认形态; 唯一交互: 端口范围)"
        echo -e "${CYAN}2)${RESET} 全协议生成 (自动端口, 完全无交互)"
        echo -e "${CYAN}3)${RESET} 全协议生成 (强制覆盖已有协议, 重新生成全部)"
        echo -e "${RED}4)${RESET} 清空全部节点 (批量删除 + 吊销所有分享链接)"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请输入选项 [0-4]: " c || { echo; exit 0; }
        case "$(clean_input "$c")" in
            1) batch_main ;;
            2) SB_BATCH_AUTO=1 batch_main ;;
            3) SB_BATCH_OVERWRITE=1 SB_BATCH_AUTO=1 batch_main ;;
            4) wipe_all_nodes ;;
            0) return ;;
            *) print_error "无效选项" ;;
        esac
        read -r -p "按回车键返回主菜单..." _ || { echo; exit 0; }
    done
}

# CLI 派发: batch.sh wipe  (供 sing-box.sh 菜单直接调用)
case "${1:-}" in
    wipe)  wipe_all_nodes ;;
    main)  main ;;
    *)     main ;;
esac
