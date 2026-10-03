#!/bin/bash
# ==============================================================
# reality.sh — Reality (VLESS-REALITY/Vision) 节点模块
# 职责：添加/删除/列出 config/reality-NN.json + out/ 客户端产物
# 服务重启由统一 sing-box.service 处理（check + SIGHUP 软重载）
# CLI: bash reality.sh [add|list|del]   无参数=交互菜单
# 依赖: source lib.sh (SB_ROOT/SB_BIN/lib 函数)
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="reality"
REALITY_KEYS_FILE="$SB_OUT_DIR/reality-keys.json"

# ---------- REALITY 密钥（复用已有，避免同 key 多节点共存问题时丢失）----------
ensure_reality_keys() {
    mkdir -p "$SB_OUT_DIR"
    if [[ -f "$REALITY_KEYS_FILE" ]]; then
        REAL_PRIV=$(jq -r '.private_key' "$REALITY_KEYS_FILE")
        REAL_PUB=$(jq -r '.public_key' "$REALITY_KEYS_FILE")
        [[ -n "$REAL_PRIV" && -n "$REAL_PUB" && "$REAL_PUB" != "null" ]] && { print_ok "复用已有 REALITY 密钥"; return 0; }
    fi
    print_info "生成新的 REALITY 密钥对 (sing-box generate reality-keypair)"
    local kp
    kp=$("$SB_BIN" generate reality-keypair)
    REAL_PRIV=$(echo "$kp" | grep -oP '^PrivateKey: \K.*')
    REAL_PUB=$(echo "$kp" | grep -oP '^PublicKey: \K.*')
    echo "{\"private_key\":\"$REAL_PRIV\",\"public_key\":\"$REAL_PUB\"}" | jq . > "$REALITY_KEYS_FILE"
    print_ok "REALITY 密钥已保存: $REALITY_KEYS_FILE"
}

# ---------- 通用 short_id ----------
new_short_id() { openssl rand -hex 8; }

pick_dest() { # pick_dest -> stdout: "dest|sni|port"
    local dest port
    echo >&2
    local rnd; rnd=$(reality_random_domain)   # 统一来源: mi1314cat/One-click-script domains.sh
    echo >&2
    echo "Reality 握手目标 (统一 domains.sh 随机域名): $rnd" >&2
    read -r -p "手动输入自定义目标? [y/N, 默认直接采用随机]: " c
    if [[ "$(clean_input "$c")" =~ ^[yY] ]]; then
        local dest port
        dest=$(safe_read "目标域名 (dest)" "$rnd"); port=$(safe_read "目标端口" "443")
        echo "$dest|$dest|$port"
    else
        echo "$rnd|$rnd|443"
    fi
}

# ---------- add ----------
add_config() {
    print_title "新增 Reality 节点 ($PROTO-NN.json)"
    command -v jq >/dev/null || { print_error "需要 jq"; return 1; }
    ensure_reality_keys

    local server_ip listen_ip listen_port idx
    server_ip=$(ask_server_addr)
    listen_ip=$(ask_listen_addr)
    listen_port=$(safe_read_port)
    echo -n "" >&2
    local pick dest sni dport
    pick=$(pick_dest)
    dest="${pick%%|*}"; sni="${pick#*|}"; sni="${sni%%|*}"; dport="${pick##*|}"
    # dest 必须实测: 同密钥同端口, 只换 dest 就能从 5/5 变 0/5。
    # 选完立刻把最终 dest 摆出来, 方便用户连不上时第一时间换。
    print_info "REALITY dest = $dest:$dport  (若连不上, 换 dest 再排查)"
    print_info "  实测可用: openjdk.org / www.mysql.com / www.apple.com"

    echo -n "Reality transport: 1) vision(TCP) 2) gRPC 3) HTTP/2 [默认1]: " >&2
    read -r tv
    case "$(clean_input "$tv")" in
        2) TRANSPORT="grpc" ;;
        3) TRANSPORT="http" ;;
        *) TRANSPORT="vision" ;;
    esac
    local svc_name=""
    [[ "$TRANSPORT" == "grpc" ]] && { svc_name=$(safe_read "grpc service_name" "grpcSvc"); print_info "service_name=$svc_name"; }

    local uuid sid
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
    sid=$(new_short_id)

    idx=$(get_next_index "$PROTO")
    local file="$SB_CONFIG_DIR/$PROTO-$idx.json" tag="${PROTO}${idx}"
    tag="$tag$(tag_form_suffix reality)"   # 名字体现传输方式

    # QA-F1: 服务端 users 必须带与客户端一致的 flow (vision 才有), 否则客户端 flow mismatch 全部不可连
    local FLOW_JSON=""
    [[ "$TRANSPORT" == "vision" || -z "$TRANSPORT" ]] && FLOW_JSON=', "flow": "xtls-rprx-vision"'
    local json
    json=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "users": [ { "name": "user", "uuid": "$uuid"$FLOW_JSON } ],
      "tls": {
        "enabled": true,
        "server_name": "$sni",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$sni", "server_port": $dport },
          "private_key": "$REAL_PRIV",
          "short_id": [ "$sid" ]
        }
      }
    }
  ]
}
EOF
)

    # transport 注入 (vision 无 transport; grpc/http 有)
    case "$TRANSPORT" in
        grpc) json=$(echo "$json" | jq --arg sn "$svc_name" '.inbounds[0].transport = {"type":"grpc","service_name":$sn}') ;;
        http) json=$(echo "$json" | jq '.inbounds[0].transport = {"type":"http"}') ;;
    esac
    out_tag="$tag"; out_transport="$TRANSPORT"; out_svc="$svc_name" out_uuid="$uuid" out_sid="$sid" out_sni="$sni" out_pbk="$REAL_PUB" out_port="$listen_port" out_server="$server_ip"

    # 通用落盘流程：jq 校验 → sing-box check 整目录 → HUP 软重载，失败撤文件
    backup_config config
    if ! write_config "$file" "$json"; then return 1; fi
    if ! sb_check; then
        rm -f "$file"
        print_error "已删除非法配置文件（当前运行实例未受影响）"
        return 1
    fi
    sb_reload || print_warn "服务当前状态：$(systemctl is-active "$SB_SERVICE")"

    # ---- 客户端产物 ----
    local link="vless://$uuid@$server_ip:$listen_port?encryption=none&security=reality&sni=$sni&fp=chrome&pbk=$REAL_PUB&sid=$sid&type=tcp&flow=xtls-rprx-vision#$PROTO-$idx"
    local flow_extra=""
    [[ "$TRANSPORT" == "vision" ]] && flow_extra="&flow=xtls-rprx-vision"
    local tparam=""
    case "$TRANSPORT" in
        grpc) tparam="&type=grpc&serviceName=$svc_name" ;;
        http) tparam="&type=h2" ;;
        *)    tparam="&type=tcp" ;;
    esac
    local link="vless://$uuid@$server_ip:$listen_port?encryption=none&security=reality&sni=$sni&fp=chrome&pbk=$REAL_PUB&sid=$sid$tparam$flow_extra#$tag"
    write_out "$idx" "$tag" "$link" "$uuid" "$listen_port" "$sni" "$REAL_PUB" "$sid" "$server_ip" "$TRANSPORT" "$svc_name"
    open_port "$listen_port"
    print_ok "Reality 节点添加完成: $file"
    # 重建聚合: 新节点不在 sb_client-all.json 里的话, 分享链接
    # (菜单3 / all-share URL) 下发的还是旧节点列表。
    declare -F sb_regen_aggregate >/dev/null 2>&1 && sb_regen_aggregate
}

# ---------- 客户端产物 ----------
write_out() {
    local idx="$1" tag="$2" link="$3" uuid="$4" port="$5" sni="$6" pbk="$7" sid="$8" SERVER_IP="${9:-}" trans="${10:-vision}" svc="${11:-}"
    local client_flow='      "flow": "xtls-rprx-vision",'
    [[ "$trans" == "vision" ]] || client_flow=""   # grpc/h2 无 flow
    local transport_block=""
    case "$trans" in
        grpc) transport_block=",\n      \"transport\": { \"type\": \"grpc\", \"service_name\": \"$svc\" }" ;;
        http) transport_block=",\n      \"transport\": { \"type\": \"http\" }" ;;
    esac
    local utls_fp; utls_fp=$(ask_utls_fingerprint)
    python3 - "$utls_fp" "$SB_OUT_DIR/sb_client-$tag.json" "$tag" "$SERVER_IP" "$port" "$uuid" "$sni" "$pbk" "$sid" "$trans" "$svc" <<PYGEN
import json,sys
_,fp,ofile,tag,srv,port,uuid,sni,pbk,sid,trans,svc=sys.argv
ob={"type":"vless","tag":tag,"server":srv,"server_port":int(port),"uuid":uuid,
    "tls":{"enabled":True,"server_name":sni,
           "utls":{"enabled":True,"fingerprint":fp},
           "reality":{"enabled":True,"public_key":pbk,"short_id":sid}}}
if trans=="vision": ob["flow"]="xtls-rprx-vision"
if trans=="grpc": ob["transport"]={"type":"grpc","service_name":svc}
if trans=="http": ob["transport"]={"type":"http"}
json.dump({"outbounds":[ob]}, open(ofile,"w"), indent=2)
PYGEN
        gen_mihomo_yaml "$tag"
    echo "$link" | tee "$SB_OUT_DIR/sb_share-$tag.txt" | tail -1
    grep -vF "$link" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.txt 2>/dev/null && mv /tmp/l.txt "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >> "$SB_OUT_DIR/sb_links-all.txt"
}

# ---------- list / del ----------
list_configs() {
    print_title "$PROTO 配置列表"
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        local idx tag port uuid sni
        idx=$(basename "$f" .json | cut -d'-' -f2)
        tag="${PROTO}${idx}"
        port=$(jq -r '.inbounds[0].listen_port' "$f")
        uuid=$(jq -r '.inbounds[0].users[0].uuid' "$f")
        sni=$(jq -r '.inbounds[0].tls.reality.handshake.server' "$f")
        printf "%s) 端口:%s  UUID:%s  SNI:%s\n" "$idx" "$port" "$uuid" "$sni" >&2
    done
}

delete_config() {
    list_configs
    read -r -p "输入要删除的编号: " num
    num=$(clean_input "$num")
    [[ "$num" =~ ^[0-9]+$ ]] || { print_error "编号必须数字"; return 1; }
    read -r -p "确认删除编号 $num ($PROTO) 的节点? [y/N]: " dconfirm
    [[ "$(clean_input "$dconfirm")" =~ ^[yY] ]] || { print_warn "已取消"; return 0; }
    local idx file tag
    idx=$(printf "%02d" "$num")
    file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"
    if [[ ! -f "$file" ]]; then print_error "编号不存在"; return 1; fi
    # 先取端口再删文件 —— 文件没了就再也证明不了这个端口属于本节点。
    # 交给 close_node_port 按"归属已确认"的口径关闭, 它只认 .fw-ports 登记过的
    # 端口, 且 sshd 在听的 / 系统常用端口一律不碰。
    local fw_port; fw_port=$(jq -r '.inbounds[0].listen_port // empty' "$file" 2>/dev/null)
    # 产物文件名带形态后缀(如 sb_client-trojan03-TLS.json), 而这里的 $tag
    # 不带后缀, 所以按字面删的是 sb_client-trojan03.json —— 永远删不到,
    # 于是已删节点的产物长期残留, 还会被 gen_full_profile 读进聚合配置,
    # 分享链接一直下发连不上的假节点。改按前缀通配删。
    # 两种后缀都要匹配: 形态后缀是 "-TLS"/"-REALITY"(sb_client-tuic02-TLS.json),
    # 而 "tuic02.*" 只匹配点号开头的后缀, 匹配不到带形态后缀的那个文件。
    rm -f "$file" "$SB_OUT_DIR/sb_share-$tag".* "$SB_OUT_DIR/sb_share-$tag"-* \
          "$SB_OUT_DIR/sb_client-$tag".* "$SB_OUT_DIR/sb_client-$tag"-* \
          "$SB_OUT_DIR/sb_meta-$tag".* "$SB_OUT_DIR/sb_meta-$tag"-* 2>/dev/null
    # 重建聚合产物: 少了这一步, sb_client-all.json 里会一直留着
    [[ -n "$fw_port" ]] && close_node_port "$fw_port" "$tag"
    sb_check && sb_reload || print_warn "请手动确认服务状态"
    # 重建聚合产物, 并同步 nginx ——
    # 少了前者, sb_client-all.json 里会一直留着已删节点的 outbound, 分享链接
    # 下发连不上的假节点; 少了后者, 站点配置里留着指向已删端口的 location,
    # Cloudflare 回源直接 502。
    declare -F sb_regen_aggregate >/dev/null 2>&1 && sb_regen_aggregate
    declare -F sb_resync_cdn >/dev/null 2>&1 && sb_resync_cdn
    print_ok "已删除 $tag"
}

# ---------- 菜单 / CLI ----------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        add)    add_config ;;
        list)   list_configs ;;
        del)    delete_config ;;
        check)  sb_check ;;
        *)
            while true; do
                print_title "Reality 节点管理"
                echo -e "${CYAN}1)${RESET} 添加节点"
                echo -e "${CYAN}2)${RESET} 列出节点"
                echo -e "${CYAN}3)${RESET} 删除节点"
                echo -e "${CYAN}0)${RESET} 返回"
                read -r -p "请选择: " c
                case "$c" in
                    1) add_config ;;
                    2) list_configs ;;
                    3) delete_config ;;
                    0) break ;;
                    *) ;;
                esac
                read -r -p "按回车继续..." _ || { echo; exit 0; }
            done
            ;;
    esac
fi
