#!/bin/bash
# ==============================================================
# ruleset.sh — 规则集管理模块
# 管理 config/02-rule-set.json（rule_set 定义）与 03-route.json（路由规则）
# 预设源: SagerNet/sing-geosite rule-set 分支（官方 .srs），可手填 MetaCubeX 镜像
# CLI: bash ruleset.sh [list|add|del|route|check]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

RS_FILE="$SB_CONFIG_DIR/02-rule-set.json"
ROUTE_FILE="$SB_CONFIG_DIR/03-route.json"

preset_url() {
    case "$1" in
        ads)      echo "geosite-category-ads-all" ;;
        cn)       echo "geosite-cn" ;;
        telegram) echo "geosite-telegram" ;;
        twitter)  echo "geosite-twitter" ;;
        netflix)  echo "geosite-netflix" ;;
        disney)   echo "geosite-disney" ;;
        openai)   echo "geosite-openai" ;;
        google)   echo "geosite-google" ;;
        *)        echo "" ;;
    esac
}

preset_full_url() {
    local name; name=$(preset_url "$1")
    [[ -z "$name" ]] && return 1
    echo "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/${name}.srs"
}

ensure_files() {
    # 关键: 不要只建一个空的 {"rule_set":[]}。那样 dns.sh 的去广告模板引用
    # geosite-category-ads-all 时必然 check 失败, 且面板写操作全被挡住。
    # 这里直接播种官方预设 (与 dns.sh 共用 lib.sh 的幂等函数)。
    [[ -f "$RS_FILE" ]] || write_config "$RS_FILE" '{"route":{"rule_set":[]}}' || return 1
    sb_ensure_ruleset "$(preset_url ads)" "$(sb_geosite_url "$(preset_url ads)")" binary 1d || return 1
    sb_ensure_ruleset "$(preset_url cn)"  "$(sb_geosite_url "$(preset_url cn)")"  binary 3d || return 1
}

# 通用编辑: rs_edit <file> <filter-file>
apply_edit() {
    # 调用处形如 apply_edit <file> --arg t <tag> '<filter>', 因此参数要整体转发给 jq。
    # 旧实现只接 ($1,$2), --arg 占据了 filter 槽位, 真过滤器被丢弃,
    # jq 报 "--arg takes two parameters", 路由规则 2/3/4 三个功能全部失效。
    local file="$1"; shift
    # 文件不存在时直接报 jq "Could not open file", 用户完全看不懂;
    # 实际是还没生成骨架, 让他去用「初始化骨架」
    if [[ ! -f "$file" ]]; then
        print_error "文件不存在: $file"
        print_error "请先在本菜单执行「1) 初始化骨架」"
        return 1
    fi
    local old; old=$(jq . "$file")
    if ! write_config "$file" "$(jq "$@" "$file")"; then print_error "jq 过滤器错误"; return 1; fi
    if ! sb_check; then
        echo "$old" | jq . > "$file"
        print_error "已回滚（check 未通过）"
        return 1
    fi
    # 关键: 必须把 reload 的成败如实往上带。
    # 旧实现 `sb_reload; return 0` 无视结果, 于是 reload 失败时调用方照样打印
    # "[OK] 规则已添加" —— 同一屏上 "[Error] 服务异常" 与 "[OK]" 自相矛盾,
    # 而配置其实已经写盘、服务正在崩溃重启循环里。
    if ! sb_reload; then
        echo "$old" | jq . > "$file"
        print_error "服务未能加载新配置, 已回滚 (文件已还原)"
        return 1
    fi
    return 0
}

# ---------- add ----------
add_ruleset() {
    ensure_files
    echo -e "预设: ${CYAN}ads cn telegram twitter netflix disney openai google${RESET} 或 ${CYAN}custom${RESET}(手填URL)"
    sb_ask "选择: "; local p="$REPLY"
    local tag url interval update
    if [[ "$p" == "custom" ]]; then
        sb_ask "tag (如 geosite-xxx): "; tag="$REPLY"
        sb_ask "URL (.srs 或 .json): "; url="$REPLY"
    else
        tag=$(preset_url "$p")
        url=$(preset_full_url "$p") || { print_error "未知预设: $p"; return 1; }
        jq -e --arg t "$tag" 'any(.route.rule_set[]?; .tag==$t)' "$RS_FILE" >/dev/null && { print_warn "已存在: $tag"; return 0; }
    fi
    [[ -z "$tag" || -z "$url" ]] && { print_error "tag 与 URL 都不能为空"; return 1; }
    [[ "$url" =~ ^https?:// ]] || { print_error "URL 必须以 http:// 或 https:// 开头: $url"; return 1; }
    case "$url" in
        *.srs)   fmt=binary ;;
        *.json)  fmt=source  ;;
        *)       fmt=binary ;; # remote 默认
    esac
    sb_ask "update_interval (默认 1d): "; interval="$REPLY"; interval=${interval:-1d}

    # update_interval 必须是最小单位形式; "0" 会被 sing-box 当成"不再更新"且 check 不报错
    if [[ ! "$interval" =~ ^[0-9]+(s|m|h|d)$ ]]; then
        print_error "update_interval 格式应为 30s / 5m / 1h / 1d (收到: $interval)"
        print_error "填 0 会让该规则集永久不再更新, 因此已拒绝"
        return 1
    fi

    # 可达性预检: sing-box check 不联网, 坏 URL 只能在运行期暴露, 这里提前告知
    if [[ "$fmt" != "source" || "$url" == *.srs ]]; then
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 -L "$url" 2>/dev/null)
        if [[ "$code" != "200" && "$code" != "206" ]]; then
            print_warn "预检: 该 URL 当前取不到内容 (HTTP ${code:-000})"
            print_warn "      sing-box check 不联网, 无法发现这类问题; 真正报错会出现在服务启动/更新规则集时"
            sb_ask "  仍然添加? [y/N]: "
            [[ "$REPLY" =~ ^[yY] ]] || { print_warn "已取消, 未写入"; return 0; }
        else
            print_ok "预检通过: URL 可下载 (HTTP $code)"
        fi
    fi

    local json entry
    entry=$(cat <<EOF
{ "type": "remote", "tag": "$tag", "format": "$fmt", "url": "$url",
  "http_client": "http-direct", "update_interval": "$interval" }
EOF
)
    if ! write_config "$RS_FILE" "$(jq --argjson e "$entry" '.route.rule_set += [$e]' "$RS_FILE")"; then return 1; fi
    if ! sb_check; then
        write_config "$RS_FILE" "$(jq --arg t "$tag" '.route.rule_set |= map(select(.tag != $t))' "$RS_FILE")" || true
        print_error "添加失败已回滚。请以上面 sing-box check 的真实报错为准"
        print_warn  "提示: sing-box check 不联网, 无法验证 URL 是否真的可下载"
        return 1
    fi
    sb_reload && print_ok "规则集已添加: $tag"
    return 0
}

# ---------- del ----------
del_ruleset() {
    [[ -f "$RS_FILE" ]] || { print_warn "无规则集文件"; return 1; }
    list_ruleset
    sb_ask "删除哪个 tag: "; local t="$REPLY"
    [[ -z "$t" ]] && { print_error "未输入 tag"; return 1; }
    sb_ruleset_defined "$t" || { print_error "该 tag 未定义: $t"; return 1; }
    local refs; refs=$(sb_ruleset_refs "$t")
    if [[ -n "$refs" ]]; then
        print_warn "该规则集仍被以下位置引用, 直接删除会让 sing-box check 失败:"
        printf '%s\n' "$refs" >&2
        echo "    1) 同时清除这些引用后删除 (推荐)" >&2
        echo "    2) 取消" >&2
        # 关键: 这里的"默认 1"是破坏性选项(清除引用并删除)。
        # EOF/空回车时若一律取 1, 就等于"没人确认也照删"。
        # 所以 EOF 一律按取消处理, 只有显式输入 1/y 才继续。
        if ! sb_ask "    选择 (直接回车=取消): "; then
            print_warn "输入已结束, 已取消"; return 0
        fi
        case "$REPLY" in
            1|y|Y|yes) : ;;
            *) print_warn "已取消"; return 0 ;;
        esac
    else
        # 无人引用也要确认 —— 规则集删掉后只能重新下载恢复
        sb_ask "  确认删除规则集 $t? [y/N]: "
        case "$REPLY" in
            y|Y|yes|YES) : ;;
            *) print_warn "已取消"; return 0 ;;
        esac
    fi
    backup_config config
    # 先从 02-rule-set.json 真正移除该定义 (上面的引用扫描只看得到"谁在用", 不含定义本身)
    if ! write_config "$RS_FILE" "$(jq --arg t "$t" '.route.rule_set |= map(select(.tag != $t))' "$RS_FILE")"; then
        print_error "无法从 $RS_FILE 移除定义, 已中止"; return 1
    fi
    # 再清理其它文件里依赖它的规则: 整条规则丢弃, 不能只删 rule_set 键
    # (否则 {"rule_set":[t],"server":"dns-local"} 会变成 {"server":"dns-local"} 这种半残规则)
    if ! python3 - "$SB_CONFIG_DIR" "$t" <<'PYS'
import json,os,sys
cfgdir,tag=sys.argv[1],sys.argv[2]
def clean(node):
    if isinstance(node,dict):
        rs=node.get("rule_set")
        if isinstance(rs,list) and tag in rs:
            return None            # 整条规则失效 -> 丢弃
        return {k:clean(v) for k,v in node.items() if clean(v) is not None or True}
    if isinstance(node,list):
        out=[]
        for x in node:
            y=clean(x)
            if y is not None:
                out.append(y)
        return out
    return node
changed=[]
for f in sorted(os.listdir(cfgdir)):
    if not f.endswith(".json") or f=="02-rule-set.json": continue
    p=os.path.join(cfgdir,f)
    try: d=json.load(open(p))
    except Exception: continue
    n=clean(d)
    # 过滤后数组可能变空; 空数组虽能过 check, 但属于可疑形态, 直接把键删掉更干净
    if isinstance(n.get("dns"),dict) and n["dns"].get("rules")==[]:
        n["dns"].pop("rules",None)
    if isinstance(n.get("route"),dict) and n["route"].get("rules")==[]:
        n["route"].pop("rules",None)
    if n!=d:
        json.dump(n,open(p,"w"),indent=2); changed.append(f)
if changed: print("已清理引用: "+", ".join(changed), file=sys.stderr)
PYS
    then
        print_error "清理引用失败, 已中止 (规则集定义已移除, 建议从备份恢复)"
        return 1
    fi
    if ! sb_check; then
        print_error "删除后 sing-box check 未通过; 请用备份目录 $SB_BACKUP_DIR 恢复"
        return 1
    fi
    sb_reload || true
    print_ok "已删除规则集 $t (定义已移除, 相关引用已清理)"
}

# ---------- route 规则 ----------
init_route() {
    if [[ ! -f "$ROUTE_FILE" ]]; then
        write_config "$ROUTE_FILE" '{
  "route": {
    "rules": [
      { "rule_set": ["'"$(preset_url ads)"'"], "action": "reject" },
      { "rule_set": ["'"$(preset_url cn)"'"], "action": "sniff" }
    ]
  }
}' || return 1
        print_ok "03-route.json 骨架已生成"
    fi
}

route_menu() {
    print_title "路由规则 (03-route.json)"
    [[ -f "$ROUTE_FILE" ]] && cat "$ROUTE_FILE" >&2 || print_warn "无 03-route.json（可 init）"
    echo -e "${CYAN}1)${RESET} 初始化骨架"
    echo -e "${CYAN}2)${RESET} 添加规则 (rule_set 出站 direct)"
    echo -e "${CYAN}3)${RESET} 添加 reject 规则"
    echo -e "${CYAN}4)${RESET} 删除规则 (按 rule_set tag)"
    echo -e "${CYAN}0)${RESET} 返回"
    read -r -p "选择: " c; c=$(clean_input "$c")
    case "$c" in
        1) init_route ;;
        2|3)
            [[ "$c" == 2 ]] && L="添加规则 (rule_set 出站 direct)" || L="添加 reject 规则"
            read -r -p "rule_set tag: " tag; tag=$(clean_input "$tag")
            # 关键: sing-box check 查不出 route.rules[].rule_set 引用的 tag 是否存在
            # (实测 exit=0), 但运行期会 FATAL "rule-set not found" 让服务永久崩溃重启。
            # 所以必须在写盘前自己拦。
            if [[ -z "$tag" ]]; then print_error "tag 不能为空"; return 0; fi
            if ! sb_ruleset_defined "$tag"; then
                print_error "规则集未定义: $tag"
                print_error "sing-box check 查不出这类错误, 但服务会崩溃重启, 因此已阻止"
                print_info "已定义的规则集: $(jq -r '.route.rule_set[]?.tag' "$SB_RS_FILE" 2>/dev/null | tr "\n" " ")"
                print_info "可先用本菜单「4) 添加规则集」创建它"
                return 0
            fi
            if [[ "$c" == 2 ]]; then
                apply_edit "$ROUTE_FILE" --arg t "$tag" '.route.rules += [{ "rule_set": [$t], "outbound": "direct" }]' \
                    && print_ok "规则已添加"
            else
                apply_edit "$ROUTE_FILE" --arg t "$tag" '.route.rules += [{ "rule_set": [$t], "action": "reject" }]' \
                    && print_ok "规则已添加"
            fi
            ;;
        4)
            read -r -p "rule_set tag: " tag
            apply_edit "$ROUTE_FILE" --arg t "$tag" '.route.rules |= map(select((.rule_set? // ["-x-"] | tostring) != ([$t] | tostring)))' \
                && print_ok "规则已删除"
            ;;
    esac
}

# ---------- list ----------
list_ruleset() {
    print_title "rule-set 定义 (02-rule-set.json) — 文件存在 ≠ tag 已定义"
    if ! sb_rs_healthy; then
        print_error "规则集定义文件异常: $RS_FILE (不存在或 JSON 损坏)"
        return 1
    fi
    [[ -f "$RS_FILE" ]] || { print_warn "无"; return 1; }
    jq -r '.route.rule_set[]? | "\(.tag)\t\(.type)\t\(.format)\t\(.update_interval)\t\(.url // .path)"' "$RS_FILE" >&2
}

# ---------- 菜单 ----------
menu() {
    while true; do
        print_title "规则集管理"
        sb_guard_rs || true
        list_ruleset
        echo -e "${CYAN}1)${RESET} 添加规则集 (预设/custom)"
        echo -e "${CYAN}2)${RESET} 删除规则集"
        echo -e "${CYAN}3)${RESET} 路由规则 (route.rules)"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请选择: " c
        case "$(clean_input "$c")" in
            1) add_ruleset ;;
            2) del_ruleset ;;
            3) route_menu ;;
            0) break ;;
            *) print_error "无效选项" ;;
        esac
        read -r -p "按回车继续..." _ || { echo; exit 0; }
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        list)  list_ruleset ;; add) add_ruleset ;; del) del_ruleset ;; route) route_menu ;; check) sb_check ;;
        *)     menu ;;
    esac
fi
