#!/bin/bash
# ==============================================================
# batch.sh — 全协议一键生成 (Batch Generator)
#   * 无重复询问公共参数: 一开始只要一次端口范围, 其余全用各协议自带默认生成逻辑
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

# 协议 + Reality 变体说明: reality/anyreality 本身就是 Reality; vmess/trojan 追加 Reality 第二形态
PROTOS=(reality hysteria2 anyreality vless shadowsocks tuic vmess trojan naive shadowtls)
BATCH_ANSWERS_OVERRIDE=""

latest_file() { ls "$SB_CONFIG_DIR"/${1}-*.json 2>/dev/null | sort | tail -1; }
tag_of() { basename "$(latest_file "$1")" .json | tr -d '-'; }

########## 主流程 ##########
batch_main() {
    mkdir -p "$SB_CONFIG_DIR" "$SB_OUT_DIR"
    init_base >/dev/null 2>&1 || true

    echo >&2
    print_title "全协议一键生成"
    echo -e "${CYAN}唯一交互: 监听端口分配范围. 其余全部沿用各协议默认值.${RESET}" >&2
    echo -e "${CYAN}如端口被占用或配置失败, 会自动清理; 收尾统一 check + reload.${RESET}" >&2

    # --- 唯一一次交互 ---
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
    rm -f "$SB_OUT_DIR/.batch-used" "$SB_OUT_DIR/.batch-port"

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
        SB_BATCH_PORT_START="$SB_BATCH_PORT_START" SB_BATCH_PORT_END="$SB_BATCH_PORT_END" \
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
    local -a variant_list=(vmess trojan)
    local -a variant_answers=(";4" "2")
    for i in "${!variant_list[@]}"; do
        local vp="${variant_list[$i]}"
        printf "%b• %s 变体%b ... " "$CYAN" "$vp" "$RESET" >&2
        local second=""; 
        ls "$SB_CONFIG_DIR"/${vp}-02.json >/dev/null 2>&1 && {
            printf "%b[已存在]%b Reality 变体已生成\n" "$YELLOW" "$RESET" >&2
            continue
        }
        SB_BATCH=1 SB_NO_RELOAD=1 SB_BATCH_ANSWERS="${variant_answers[$i]}" \
        SB_BATCH_PORT_START="$SB_BATCH_PORT_START" SB_BATCH_PORT_END="$SB_BATCH_PORT_END" \
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

    # --- 分享链接统一输出 (复用 share.sh) ---
    echo >&2
    printf "${CYAN}════ 分享链接 ════${RESET}\n" >&2
    bash "$SELF_DIR/conf/share.sh" create-all </dev/null 2>&1 | grep -E "http://|已创建" | tail -2 >&2 || true

    show_service
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
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请输入选项 [0-2]: " c || { echo; exit 0; }
        case "$(clean_input "$c")" in
            1) batch_main ;;
            2) SB_BATCH_AUTO=1 batch_main ;;
            0) return ;;
            *) print_error "无效选项" ;;
        esac
        read -r -p "按回车键返回主菜单..." _ || { echo; exit 0; }
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
