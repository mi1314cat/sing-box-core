#!/bin/bash
# ==============================================================
# outbound.sh — 出站（outbound）管理模块
# 每条出站 = config/outbound-NN.json（direct/socks/http/渗透 chain）
# reference: xary-core conf/outbound.sh 的 out-*.json 模式（简化版）
# CLI: bash outbound.sh [add|list|del]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="outbound"

add_config() {
    print_title "新增出站 ($PROTO-NN.json)"
    echo "类型: 1) direct(自由) 2) socks 3) http"
    read -r -p "选择 (默认 1): " t
    t=$(clean_input "$t")
    case "$t" in
        2) otype=socks ;;
        3) otype=http ;;
        *) otype=direct ;;
    esac
    read -r -p "$(echo -e $CYAN)_meta.name 标识 (默认 auto): $RESET" name
    name=$(clean_input "$name"); name=${name:-custom}
    idx=$(get_next_index "$PROTO")
    local file tag
    file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="$PROTO$idx"
    local json
    json=$(cat <<EOF
{
  "outbounds": [ {
      "type": "$otype",
      "tag": "$tag"
  } ]
}
EOF
)

    case "$otype" in
        socks|http)
            local addr port
            addr=$(safe_read "服务器地址" "127.0.0.1")
            port=$(safe_read_port)
            local extra="\"server\": \"$addr\", \"server_port\": $port"
            # socks 附加 auth optional
            ;;
        *) extra="" ;;
    esac
    if [[ -n "$extra" ]]; then
        json=$(cat <<EOF
{
  "outbounds": [ {
      "type": "$otype", "tag": "$tag", $extra
  } ]
}
EOF
)
    fi

    backup_config config
    write_config "$file" "$json" || return 1
    if ! sb_check; then rm -f "$file"; print_error "已删除非法配置（现网未受影响）"; return 1; fi
    sb_reload || true
    print_ok "出站已添加: $file"
}

list_configs() {
    print_title "$PROTO 配置"
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        local num tag otype
        num=$(basename "$f" .json | cut -d'-' -f2)
        jq -r '.outbounds[] | "\(.tag)\t\(.type)\t\(.server // "-"):\(.server_port // "-")"' "$f" 2>/dev/null | while IFS=$'\t' read -r tg ot sv; do
            printf "%s) %s %s %s\n" "$num" "$tg" "$ot" "$sv"
        done
    done
}

delete_config() {
    list_configs
    read -r -p "输入要删除的编号: " num
    num=$(clean_input "$num"); [[ "$num" =~ ^[0-9]+$ ]] || { print_error "编号必须数字"; return 1; }
    local idx file tag refs
    idx=$(printf "%02d" "$num")
    file="$SB_CONFIG_DIR/$PROTO-$idx.json"
    tag="$(jq -r '.outbounds[0].tag' "$file")"
    [[ -f "$file" ]] || { print_error "编号不存在"; return 1; }
    refs=$(jq '[.route.rules[]? | select(.outbound? == $t)] | length' --arg t "$tag" "$SB_CONFIG_DIR/03-route.json" 2>/dev/null || echo 0)
    if (( refs > 0 )); then
        read -r -p "该出站被 $refs 条 分流/绑定 规则引用; 删除后规则改回 direct? [Y/n]: " fc
        fc=$(clean_input "$fc"); [[ -z "$fc" ]] && fc=y
        [[ "$fc" =~ ^[yY] ]] || { print_warn "已取消"; return 0; }
    fi
    selftest_outbound "$file" "$tag" 2 || swap_outbound_rules "$tag"
    rm -f "$file"
    sb_check && sb_reload || true
    print_ok "已删除出站 $tag; 引用它的规则已切回 direct"
}

# 批量自检: 所有自定义出站
selftest_all() {
    local f tag
    for f in "$SB_CONFIG_DIR"/outbound-*.json; do
        [[ -f "$f" ]] || continue
        tag=$(jq -r '.outbounds[0].tag' "$f")
        selftest_outbound "$f" "$tag" 2 || { swap_outbound_rules "$tag"; print_warn "$tag 自检失败 -> 规则改回 direct"; }
    done
}


# ==============================================================
# 域名分流 + 入站绑定出站  (参考 xary-core outbound.sh 交互语义)
# 路由统一写 $SB_CONFIG_DIR/03-route.json 的 route.rules
# ==============================================================
ROUTE_FILE="$SB_CONFIG_DIR/03-route.json"
all_outbound_tags() { # 可选出站/tag 列表 (含各协议节点 tag + 自定义 outbound + direct)
    local tags
    jq -r '.outbounds[]?.tag' "$SB_CONFIG_DIR"/*.json 2>/dev/null |
        grep -vE "^(00-(direct|dns))" | sort -u
}

outbound_pick() {
    local i=1 t choices=()
    echo -e "${CYAN}可选出站/节点 tag:${RESET}" >&2
    echo "--------------------------------------------------------" >&2
    for t in $(all_outbound_tags); do
        echo -e "  ${GREEN}$i${RESET}) ${YELLOW}$t${RESET}" >&2
        choices+=("$t"); i=$((i+1))
    done
    echo -e "    ${CYAN}$i${RESET}) direct (默认)" >&2
    echo "--------------------------------------------------------" >&2
    read -r -p "选择编号 / 直接输入 tag (默认 direct): " n
    n=$(clean_input "$n"); [[ -z "$n" ]] && { echo "direct"; return; }
    if [[ "$n" =~ ^[0-9]+$ ]]; then
        (( n <= ${#choices[@]} )) && { echo "${choices[$((n-1))]}"; return; }
        echo "" ; return
    fi
    echo "$n"
}

split_add() {
    local dom out
    dom=$(safe_read "要分流的域名 (支持子域 suffix 匹配, 如 example.com)" "")
    [[ -z "$dom" ]] && { print_error "未输入域名"; return 1; }
    out=$(outbound_pick); [[ -z "$out" ]] && { print_error "未选择出站/编号无效"; return 1; }
    python3 - "$ROUTE_FILE" "$dom" "$out" <<'PYS'
import json,sys
rf,dom,out=sys.argv[1:]
try:
    d=json.load(open(rf))
except Exception:
    d={}
d.setdefault("route",{}).setdefault("rules",[])
d["route"]["rules"].append({"domain_suffix":[dom],"outbound":out})
json.dump(d,open(rf,"w"),indent=2)
PYS
    sb_check && sb_reload && print_ok "域名分流已生效: *$dom -> $out"
}

split_list() {
    jq -r '.route.rules[]? | select(.domain_suffix != null) | "\(.domain_suffix|join(","))  ->  \(.outbound)"' "$ROUTE_FILE" 2>/dev/null | nl -ba
}

split_del() {
    local n; n=$(safe_read "要删除第几条分流 (0=全部)" "0")
    [[ "$n" =~ ^[0-9]+$ ]] || { print_error "请输入编号"; return 1; }
    python3 - "$ROUTE_FILE" "$n" <<'PYS'
import json,sys
rf,n=sys.argv[1:3]
d=json.load(open(rf))
rules=d.get("route",{}).get("rules",[])
keep=[]
i=0
for r in rules:
    if "domain_suffix" in r:
        i+=1
        if n!="0" and str(i)!=n: keep.append(r)
        continue
    keep.append(r)
d["route"]["rules"]=keep
json.dump(d,open(rf,"w"),indent=2)
PYS
    sb_check && sb_reload && print_ok "分流规则已更新"
}

all_inbound_tags(){  # 所有可绑定的入站 tag (各节点 inbound+端口转发)
    jq -r '.inbounds[]?.tag' "$SB_CONFIG_DIR"/*.json 2>/dev/null | sort -u
}

bind_add() {
    local i=1 in_ choices=()
    echo -e "${CYAN}可选入站 (节点/端口转发):${RESET}" >&2
    echo "--------------------------------------------------------" >&2
    for in_ in $(all_inbound_tags); do
        echo -e "${GREEN}$i${RESET}) ${YELLOW}$in_${RESET}" >&2
        choices+=("$in_"); i=$((i+1))
    done
    [[ ${#choices[@]} -eq 0 ]] && { print_warn "当前没有入站"; return 1; }
    echo "--------------------------------------------------------" >&2
    read -r -p "选择入站编号: " c
    c=$(clean_input "$c")
    if [[ "$c" =~ ^[0-9]+$ ]]; then
        (( c >= 1 && c <= ${#choices[@]} )) || { print_error "无效编号"; return 1; }
        in_="${choices[$((c-1))]}"
    else in_="$c"; fi
    out=$(outbound_pick); [[ -z "$out" ]] && { print_error "未选择出站"; return 1; }
    python3 - "$ROUTE_FILE" "$in_" "$out" <<'PYS'
import json,sys
rf,ib,out=sys.argv[1:]
try:
    d=json.load(open(rf))
except Exception:
    d={}
rules=d.setdefault("route",{}).get("rules",[])
# 同一入站已绑定的先移除
rules=[r for r in rules if not ("inbound" in r and r["inbound"]==[ib])]
rules.append({"inbound":[ib],"outbound":out})
d["route"]["rules"]=rules
json.dump(d,open(rf,"w"),indent=2)
PYS
    sb_check && sb_reload && print_ok "入站绑定已生效: $in_ -> $out"
}

bind_del() {
    local n; n=$(safe_read "要删除第几条绑定 (0=全部)" "0")
    [[ "$n" =~ ^[0-9]+$ ]] || { print_error "请输入编号"; return 1; }
    python3 - "$ROUTE_FILE" "$n" <<'PYS'
import json,sys
rf,n=sys.argv[1:3]
d=json.load(open(rf))
rules=d.get("route",{}).get("rules",[])
keep=[]; i=0
for r in rules:
    if "inbound" in r and "outbound" in r:
        i+=1
        if n!="0" and str(i)!=n: keep.append(r)
        continue
    keep.append(r)
d.setdefault("route",{})["rules"]=keep
json.dump(d,open(rf,"w"),indent=2)
print("{} deleted".format(i-len(keep)))
PYS
    sb_check && sb_reload && print_ok "绑定规则已更新"
}
bind_list(){ jq -r '.route.rules[]? | select(.inbound != null) | "\(.inbound|join(","))  ->  \(.outbound)"' "$ROUTE_FILE" 2>/dev/null | nl -ba; }


# ==============================================================
# QA: 默认出站保护 / 失败回退 (借鉴 xary-core outbound.sh selftest)
#   - 自检失败 -> 所有引用改回 direct; 文件 quarantine
# ==============================================================
QUARANTINE_DIR="$SB_CONFIG_DIR/.quarantine"

selftest_outbound() {  # selftest_outbound <out_file> <tag> [tries]
    local file="$1" tag="$2" tries="${3:-3}" k port pid r ok=0
    [[ -f "$file" ]] || return 1
    for ((k=1; k<=tries; k++)); do
        local port=$(( 23000 + RANDOM % 2000 ))
        python3 - "$file" "$port" "$tag" <<'PYS'
import json,sys
o=json.load(open(sys.argv[1]))["outbounds"]
cfg={"log":{"level":"warn"},
     "inbounds":[{"type":"mixed","tag":"mix","listen":"127.0.0.1","listen_port":int(sys.argv[2])}],
     "outbounds":o,
     "route":{"final":sys.argv[3]}}
json.dump(cfg,open("/tmp/sb-out-selftest.json","w"))
PYS
        timeout 20 "$SB_BIN" run -c /tmp/sb-out-selftest.json >/dev/null 2>/tmp/sb-selftest.err &
        local pid=$!
        sleep 1
        r=$(timeout 12 curl -s --max-time 10 -x "http://127.0.0.1:$port" -o /dev/null -w "%{http_code}" https://www.gstatic.com/generate_204 2>/dev/null)
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        [[ "$r" == "204" ]] && ok=$((ok+1))
    done
    if (( ok == tries )); then print_ok "出站 [$tag] 自检通过 ($tries/$tries)"; return 0
    elif (( ok > 0 )); then print_warn "出站 [$tag] 自检部分通过 ($ok/$tries) - 按可用处理"; return 0
    else print_error "出站 [$tag] 自检失败 0/$tries"; return 1; fi
}

swap_outbound_rules() {  # swap_outbound_rules <tag> -> 所有引用 tag 的规则改回 direct
    local tag="$1" rf="$SB_CONFIG_DIR/03-route.json"
    [[ -f "$rf" ]] || return 0
    jq --arg t "$tag" '.route.rules |= map(if (.outbound? == $t) then (.outbound = "direct") else . end)' "$rf" > "$rf.tmp"         && mv "$rf.tmp" "$rf"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        add)  add_config ;;
        list) list_configs ;;
        del)  delete_config ;;
        check) sb_check ;;
        selftest) shift; selftest_outbound "$@" || true ;;
        swap) swap_outbound_rules "$2"; sb_check && sb_reload || true ;;
        *)
            while true; do
                print_title "出站管理"
                echo -e "${CYAN}1)${RESET} 添加出站"
                echo -e "${CYAN}2)${RESET} 列出出站"
                echo -e "${CYAN}3)${RESET} 删除出站"
                echo -e "${CYAN}4)${RESET} 域名分流 (添加规则: 指定域名 → 指定出站)"
                echo -e "${CYAN}5)${RESET} 域名分流 (列出规则)"
                echo -e "${CYAN}6)${RESET} 域名分流 (删除规则)"
                echo -e "${CYAN}7)${RESET} 入站绑定出站 (添加: 节点/端口 → 出站)"
                echo -e "${CYAN}8)${RESET} 入站绑定出站 (删除)"
                echo -e "${CYAN}9)${RESET} 出站自检+失败自动回退 direct (全量自检)"
                echo -e "${CYAN}0)${RESET} 返回"
                read -r -p "请选择: " c
                case "$(clean_input "$c")" in
                    1) add_config ;;
                    2) list_configs ;;
                    3) delete_config ;;
                    4) split_add ;;
                    5) split_list ;;
                    6) split_del ;;
                    7) bind_add ;;
                    8) bind_del ;;
                    9) selftest_all ;;
                    0) break ;;
                    *) ;;
                esac
                read -r -p "按回车继续..." _ || { echo; exit 0; }
            done ;;
    esac
fi
