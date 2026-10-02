#!/bin/bash
# ==============================================================
# anytls.sh — AnyTLS 节点模块 (含 REALITY 选配)
#
# 历史: 本模块原为"纯 AnyTLS"(不含 REALITY), anyreality.sh 单独管
# AnyTLS+REALITY。现在两者合并 —— 同一个协议, 只是 TLS 模式不同,
# 拆两个模块/两套编号让用户每次都要先想"我该用哪个"。
# 现在统一为一个入口, 证书选配方式与 trojan.sh 完全一致:
#     1) 真证书    2) 自签(pin)    3) Reality
#
# 关键约束 (决定了为什么要拆出纯 AnyTLS 这一支):
#   mihomo/Clash **明确不支持 AnyTLS+REALITY**
#   (官方原文: "Mihomo does not support AnyTLS+Reality, and will not
#   support this combination in the future")。
#   所以选 1)/2) 出来的节点两端都能用; 选 3) 只能给 sing-box 客户端,
#   不会产出 mihomo YAML。
#
# 迁移: 旧的 anyreality-NN.json 会在进入菜单时自动改名为 anytls-NN.json
#       (编号取空位, 端口/证书/密钥全保留, 旧分享链接继续可用)。
# CLI: bash anytls.sh [add|list|del]
# 指纹: uTLS 指纹走 lib.sh 的 ask_utls_fingerprint 选配 (默认 chrome)
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="anytls"
CERT_DIR="$SB_ROOT/cert"
REALITY_KEYS_FILE="$SB_OUT_DIR/reality-keys.json"

# REALITY 长期密钥对与 reality.sh 共享 (不重复生成)
ensure_reality_keys() {
    if [[ -f "$REALITY_KEYS_FILE" ]]; then
        local p u
        p=$(jq -r '.private_key // empty' "$REALITY_KEYS_FILE")
        u=$(jq -r '.public_key  // empty' "$REALITY_KEYS_FILE")
        [[ -n "$p" && -n "$u" ]] && { REAL_PRIV="$p"; REAL_PUB="$u"; return 0; }
    fi
    local kp
    kp=$("$SB_BIN" generate reality-keypair 2>/dev/null)
    REAL_PRIV=$(echo "$kp" | grep -oP '^PrivateKey: \K.*')
    REAL_PUB=$(echo  "$kp" | grep -oP '^PublicKey: \K.*')
    [[ -n "$REAL_PRIV" && -n "$REAL_PUB" ]] || { print_error "REALITY 密钥生成失败"; return 1; }
    echo "{\"private_key\":\"$REAL_PRIV\",\"public_key\":\"$REAL_PUB\"}" | jq . > "$REALITY_KEYS_FILE"
    print_ok "REALITY 密钥已生成: $REALITY_KEYS_FILE"
}

extract_cert_domain() {
    local crt="$1" dom=""
    command -v openssl >/dev/null && [[ -f "$crt" ]] && dom=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -oE "DNS:[^,]+" | head -1 | cut -d: -f2)
    [[ -z "$dom" ]] && dom=$(basename "$crt" | sed -E 's/\.(crt|pem)$//; s/^cert-//')
    echo "$dom"
}

ask_cert() {  # 输出 CERT_FILE/KEY_FILE/CERT_DOMAIN/CERT_TRUSTED, 或 TLS_TYPE=reality + T_RE_*
    local c
    echo "TLS 模式: 1) 真证书  2) 自签(pin)  3) Reality [默认 2]" >&2
    echo "  (选 3 = AnyTLS+REALITY, 仅 sing-box 客户端可用; mihomo/Clash 不支持该组合)" >&2
    local c
    # 顺序很重要: SB_FORCE_TLS_REALTY 必须**先于** SB_BATCH 判断。
    # 原来是 "SB_BATCH 就 c=2" 在前, 于是 batch 补齐 Reality 变体时
    # (SB_BATCH=1 SB_FORCE_TLS_REALTY=1) 仍然取自签, Reality 变体永远产不出来。
    # 这也是 batch 的 variant_list 里一直只有 vmess/trojan 的原因。
    if [[ "${SB_FORCE_TLS_REALTY:-}" == "1" ]]; then c=3
    elif [[ -n "${SB_BATCH:-}" ]]; then c=2
    else
        # 批量生成 Reality 变体时由 batch 显式指定 (见 batch.sh 注释);
        # 只替换交互输入, 复用下方原有 Reality 分支
        read -r -p "选择: " c; c=$(clean_input "$c"); [[ -z "$c" ]] && c=2
    fi
    # 覆盖放在 if/else 外面: 之前写在 else 里, 批量路径压根不经过, 于是
    # ③ 选了真证书, anytls 出来的还是自签。
    sb_batch_tls_override 1 c
    if [[ "$c" == "3" ]]; then
        local d sid
        d=$(safe_read "Reality 握手目标 (统一 domains.sh)" "$(reality_random_domain)")
        ensure_reality_keys || return 1
        sid=$(openssl rand -hex 8)
        CERT_DOMAIN="$d"; CERT_TRUSTED=false; TLS_TYPE="reality"
        T_RE_PRIV="$REAL_PRIV"; T_RE_PUB="$REAL_PUB"; T_RE_SID="$sid"
        return 0
    fi
    TLS_TYPE="tls"
    if [[ "$c" == "2" ]]; then
        local d; d=$(safe_read "自签伪装域名 (统一 domains.sh)" "$(reality_random_domain)")
        mkdir -p "$CERT_DIR"
        CERT_FILE="$CERT_DIR/cert-$d.crt"; KEY_FILE="$CERT_DIR/key-$d.key"
        [[ -f "$CERT_FILE" ]] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
            -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 -subj "/CN=$d" -addext "subjectAltName=DNS:$d" >/dev/null 2>&1
        [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] || { print_error "证书生成失败"; return 1; }
        CERT_DOMAIN="$d"; CERT_TRUSTED=false; return 0
    fi
    # 真证书: 批量模式用 batch 入口选好的那张; 交互模式列出本机证书让你选,
    # 而不是要你手打 crt/key 路径 —— 手打几乎没人填对, 填错了报错还很难看出来。
    [[ -n "${SB_BATCH:-}" ]] && { sb_apply_batch_cert; return $?; }
    pick_trusted_cert_verbose
}

# ---- AnyTLS 专属: padding_scheme ----
#
# padding_scheme 决定每种包类型要填充多少字节, 是 AnyTLS 抗**主动探测**的核心:
# 真实流量带 padding, 探测方发来的畸形包走"短填充"分支, 两者的长度分布不同,
# 探测方据此就能区分真假客户端。
# sing-anytls 内置一套默认方案, 没配这个字段时自动使用 (inbound.go 直接取
# padding.DefaultPaddingScheme) —— 也就是说**不写不等于没防护**, 只是不能自定义。
AT_PADDING_DEFAULT='stop=8
0=30-30
1=100-400
2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000
3=9-9,500-1000
4=500-1000
5=500-1000
6=500-1000
7=500-1000'

ask_anytls_padding() {
    AT_PADDING=""
    if [[ -n "${SB_BATCH:-}" ]]; then
        # 批量: 仅在显式指定时才写。默认留空 = 交给内核默认, 这样以后内核
        # 调整了默认方案我们的产物会自动跟随, 不会锁死在旧值上。
        [[ -n "${SB_ANYTLS_PADDING:-}" ]] && AT_PADDING="$SB_ANYTLS_PADDING"
        return 0
    fi
    echo >&2
    echo -e "${CYAN}  流量填充 (padding_scheme)${RESET} ${CYAN}— 按包类型填充随机字节, 抗主动探测${RESET}" >&2
    echo -e "    ${GREEN}1)${RESET} ${CYAN}内核默认 (推荐)${RESET}  不写该字段, 由 sing-box 使用自带方案" >&2
    echo -e "    ${GREEN}2)${RESET} ${CYAN}显式写入默认方案${RESET}  行为与 1 相同, 但配置里看得见" >&2
    echo -e "    ${GREEN}3)${RESET} ${YELLOW}自定义${RESET}  每行一条规则, 格式见 stop=8 / 0=30-30" >&2
    local c
    read -r -p "    请选择 [1-3, 回车=1]: " c || { echo; return 0; }
    c=$(clean_input "$c"); [[ -z "$c" ]] && c=1
    case "$c" in
        2) AT_PADDING="$AT_PADDING_DEFAULT"; print_ok "padding_scheme: 内置默认 (显式写入)" ;;
        3)
            local raw
            raw=$(safe_read "padding_scheme (每行一条)" "$AT_PADDING_DEFAULT")
            raw="${raw//\"/}"          # 引号会破坏 JSON 字符串, 提前去掉
            [[ -z "$raw" ]] && { print_warn "内容为空, 改用内核默认"; return 0; }
            AT_PADDING="$raw"
            print_ok "padding_scheme: 自定义 ($(printf '%s' "$raw" | grep -c . ) 条规则)" ;;
        *) print_info "padding_scheme: 交给内核默认" ;;
    esac
}

# 证书 DER 的 SHA256 (mihomo 的 fingerprint 语义: 证书指纹, 不是 SPKI 哈希)
cert_fingerprint_hex() {
    command -v openssl >/dev/null || return 1
    openssl x509 -in "$1" -outform DER 2>/dev/null | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}'
}

add_config() {
    print_title "新增 AnyTLS 节点 ($PROTO-NN.json)"
    local listen_ip listen_port password file tag idx server_ip pin=""
    listen_ip=$(ask_listen_addr)
    listen_port=$(safe_read_port)
    password=$(openssl rand -base64 18 | tr -d '/+=\n' | head -c 24)
    ask_cert || return 1
    ask_anytls_padding || return 1

    idx=$(get_next_index "$PROTO"); file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"
    # 名字体现传输方式: ask_cert 决定 reality 还是 TLS
    [[ "${TLS_TYPE:-}" == "reality" ]] && tag="$tag$(tag_form_suffix reality)" || tag="$tag$(tag_form_suffix tls)"
    local json
    # padding_scheme 是字符串数组, sing-box 用 \n join -> 每行一个元素
    # padding_scheme: sing-box 用 "\n" join 数组元素 -> 每个元素必须正好是一行规则,
    # 所以这里逐行拆成 JSON 数组, 而不是把多行文本塞进一个字符串。
    local pad_line=""
    if [[ -n "$AT_PADDING" ]]; then
        pad_line=$(printf '%s' "$AT_PADDING" | jq -R . | jq -sc . | tr -d "\n")
        pad_line=",
      \"padding_scheme\": $pad_line"
    fi
    if [[ "${TLS_TYPE:-tls}" == "reality" ]]; then
        json=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "anytls",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "users": [ { "name": "user", "password": "$password" } ]${pad_line},
      "tls": {
        "enabled": true,
        "server_name": "$CERT_DOMAIN",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$CERT_DOMAIN", "server_port": 443 },
          "private_key": "$T_RE_PRIV",
          "short_id": [ "$T_RE_SID" ]
        }
      }
    }
  ]
}
EOF
)
    else
    json=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "anytls",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "users": [ { "name": "user", "password": "$password" } ]${pad_line},
      "tls": { "enabled": true, "alpn": ["h2", "http/1.1"], "certificate_path": "$CERT_FILE", "key_path": "$KEY_FILE" }
    }
  ]
}
EOF
)
    fi
    backup_config config
    write_config "$file" "$json" || return 1
    if ! sb_check; then
        rm -f "$file"
        print_error "已删除非法配置（现网未受影响）"
        return 1
    fi
    cleanup_node_shares "$tag"
    sb_reload || true

    server_ip=$(ask_server_addr)
    [[ "$CERT_TRUSTED" == "false" ]] && pin=$(cert_spki_pin_base64 "$CERT_FILE")
    local fp=""; [[ "$CERT_TRUSTED" == "false" ]] && fp=$(cert_fingerprint_hex "$CERT_FILE")

    # anytls:// 分享链接 (自签走 pinSHA256, 与 trojan 同一套语义)
    local link
    if [[ "${TLS_TYPE:-tls}" == "reality" ]]; then
        link="anytls://$password@$server_ip:$listen_port?sni=$CERT_DOMAIN&insecure=0&pbk=$T_RE_PUB&sid=$T_RE_SID#$tag"
    elif [[ "$CERT_TRUSTED" == "true" ]]; then
        link="anytls://$password@$server_ip:$listen_port?sni=$CERT_DOMAIN&insecure=0#$tag"
    else
        link="anytls://$password@$server_ip:$listen_port?sni=$CERT_DOMAIN&insecure=1${pin:+&pinSHA256=$pin}#$tag"
    fi

    local utls_fp; utls_fp=$(ask_utls_fingerprint)
    # AnyTLS 出站专属的空闲会话治理。服务端开 multiplex 之外还会定期清理
    # 长时间空闲的会话, 参数不对会让长连接被提前掐断, 或让空闲会话堆积。
    local isc ist mis
    isc=$(safe_read "空闲会话检查间隔 (秒, 0=用默认30)" "0")
    ist=$(safe_read "空闲会话超时 (秒, 0=用默认30)" "0")
    mis=$(safe_read "最少保留空闲会话数 (0=用默认0)" "0")
    python3 - "$utls_fp" "$SB_OUT_DIR/sb_client-$tag.json" "$tag" "$server_ip" "$listen_port" \
        "$password" "$CERT_DOMAIN" "$pin" "${TLS_TYPE:-tls}" "${T_RE_PUB-}" "${T_RE_SID-}" \
        "$isc" "$ist" "$mis" <<'PYGEN'
import json,sys
_,fp,ofile,tag,srv,port,pw,sni,pin,mode,pub,sid,isc,ist,mis=sys.argv
if mode=="reality":
    tls={"enabled":True,"server_name":sni,
         "utls":{"enabled":True,"fingerprint":fp},
         "reality":{"enabled":True,"public_key":pub,"short_id":sid}}
else:
    tls={"enabled":True,"server_name":sni,"alpn":["h2","http/1.1"],
         "utls":{"enabled":True,"fingerprint":fp}}
    if pin: tls["certificate_public_key_sha256"]=pin
out={"type":"anytls","tag":tag,"server":srv,"server_port":int(port),"password":pw,"tls":tls}
# 0 = 不写, 交给 sing-box 用它自己的默认值 (30/30/0)
if isc and int(isc)!=0: out["idle_session_check_interval"]=str(int(isc))+"s"
if ist and int(ist)!=0: out["idle_session_timeout"]=str(int(ist))+"s"
if mis and int(mis)!=0: out["min_idle_session"]=int(mis)
json.dump({"outbounds":[out]},open(ofile,"w"),indent=2)
PYGEN

    # mihomo 单节点 YAML —— 仅非 Reality 形态产出。
    # mihomo/Clash 不支持 AnyTLS+Reality, 生成了也是一份用不了的配置。
    rm -f "$SB_OUT_DIR/sb_client-$tag.yaml"
    if [[ "${TLS_TYPE:-tls}" != "reality" ]]; then
    gen_mihomo_yaml "$tag"

    else
        print_warn "Reality 形态: 已跳过 mihomo YAML (mihomo/Clash 不支持 AnyTLS+Reality)"
    fi

    echo "$link" > "$SB_OUT_DIR/sb_share-$tag.txt"
    grep -vF "$link" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.$$ && mv /tmp/l.$$ "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >> "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >&2
    echo "{\"tag\":\"$tag\",\"port\":$listen_port,\"password\":\"$password\",\"pin\":\"$pin\",\"tls_mode\":\"${TLS_TYPE:-tls}\",\"utls_fingerprint\":\"$utls_fp\"}" | jq . > "$SB_OUT_DIR/sb_meta-$tag.json"
    open_port "$listen_port"
    print_ok "AnyTLS 节点添加完成: $file"
    # 重建聚合: 新节点不在 sb_client-all.json 里的话, 分享链接
    # (菜单3 / all-share URL) 下发的还是旧节点列表。
    declare -F sb_regen_aggregate >/dev/null 2>&1 && sb_regen_aggregate
    if [[ "${TLS_TYPE:-tls}" == "reality" ]]; then
        print_warn "提示: AnyTLS+REALITY 形态, 仅 sing-box 客户端可用 (mihomo/Clash 不支持)"
    else
        print_warn "提示: AnyTLS 形态, sing-box 与 mihomo/Clash 都能用 (uTLS 指纹: $utls_fp)"
    fi
}

# 旧 anyreality-NN.json → anytls-NN.json 自动改名迁移。
# 只改名, 不动内容: 端口/证书/REALITY 密钥/分享链接全部保持有效。
migrate_legacy_anyreality() {
    local -a olds=( "$SB_CONFIG_DIR"/anyreality-*.json )
    local f target n
    for f in "${olds[@]}"; do
        [[ -f "$f" ]] || continue
        n=$(basename "$f" .json | cut -d'-' -f2)
        target="$SB_CONFIG_DIR/anytls-$n.json"
        if [[ -e "$target" ]]; then
            # 编号已占用: 往后找一个空位
            local k
            for k in $(seq -w 1 99); do
                [[ -e "$SB_CONFIG_DIR/anytls-$k.json" ]] || { target="$SB_CONFIG_DIR/anytls-$k.json"; break; }
            done
        fi
        if mv "$f" "$target"; then
            local ot nt
            ot=$(basename "$f" .json | tr -d '-'); nt=$(basename "$target" .json | tr -d '-')
            # 文件名改了, 配置内部的 inbound tag 也必须跟着改, 且必须按
            # **目标文件名**推导 —— 目标编号可能与源编号不同 (源 01 被占用时会挪到 02)。
            # 早先版本误用源编号 n, 结果两个文件的 tag 都变成 anytls01,
            # sing-box check 直接因 tag 重复失败。
            local newtag="$nt" tmpj
            if [[ -f "$target" ]]; then
                tmpj=$(mktemp)
                if jq --arg t "$newtag" '(.inbounds[]? | select(.tag != null) | .tag) = $t' \
                       "$target" > "$tmpj" 2>/dev/null && [[ -s "$tmpj" ]]; then
                    mv -f "$tmpj" "$target"
                else
                    rm -f "$tmpj"
                fi
            fi
            # 客户端产物跟着改名, 否则旧 tag 的产物会变成孤儿
            for ext in json yaml; do
                [[ -f "$SB_OUT_DIR/sb_client-$ot.$ext" ]] && mv -f "$SB_OUT_DIR/sb_client-$ot.$ext" "$SB_OUT_DIR/sb_client-$nt.$ext"
            done
            [[ -f "$SB_OUT_DIR/sb_share-$ot.txt" ]] && mv -f "$SB_OUT_DIR/sb_share-$ot.txt" "$SB_OUT_DIR/sb_share-$nt.txt"
            [[ -f "$SB_OUT_DIR/sb_meta-$ot.json" ]] && mv -f "$SB_OUT_DIR/sb_meta-$ot.json" "$SB_OUT_DIR/sb_meta-$nt.json"
            # share 元数据里的 tag 也要跟着改
            [[ -d "$SB_ROOT/share/shares" ]] && grep -l "\"tag\": \"*$ot\"" "$SB_ROOT/share/shares"/*.json 2>/dev/null | \
                xargs -r sed -i "s/\"tag\": \"$ot\"/\"tag\": \"$nt\"/"
            print_ok "已迁移: $(basename "$f") → $(basename "$target")  (端口/密钥/链接均不变)"
        fi
    done
    # 旧入口文件不再使用, 留个提示桩避免有人直接调用报错
    return 0
}

list_configs() {
    print_title "$PROTO 配置列表"
    local found=0
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        found=1
        local idx tag port
        idx=$(basename "$f" .json | cut -d'-' -f2); tag="${PROTO}${idx}"
        port=$(jq -r '.inbounds[0].listen_port' "$f")
        printf "  %s) %s 端口:%s\n" "$idx" "$tag" "$port" >&2
    done
    (( found )) || print_warn "暂无 $PROTO 节点"
    return 0
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
    [[ -f "$file" ]] || { print_error "编号不存在"; return 1; }
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
    print_ok "已删除 $tag"
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        add)   add_config ;;
        list)  list_configs ;;
        del)   delete_config ;;
        check) sb_check ;;
        *)
            while true; do
                migrate_legacy_anyreality
                print_title "AnyTLS 节点管理 (可选 REALITY)"
                echo -e "${CYAN}1)${RESET} 添加节点"
                echo -e "${CYAN}2)${RESET} 列出节点"
                echo -e "${CYAN}3)${RESET} 删除节点"
                echo -e "${CYAN}0)${RESET} 返回"
                read -r -p "请选择: " c
                case "$(clean_input "$c")" in
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
