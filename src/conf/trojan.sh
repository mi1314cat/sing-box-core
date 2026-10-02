#!/bin/bash
# ==============================================================
# trojan.sh — Trojan + TLS 节点模块
# 证书: 真证书 / 自签(pin 分享)；不支持 Reality(无先例, 参考脚本均未做)
# CLI: bash trojan.sh [add|list|del]
# ==============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib.sh"

PROTO="trojan"
CERT_DIR="$SB_ROOT/cert"
random_domain() { reality_random_domain; }

extract_cert_domain() {
    local crt="$1" dom=""
    command -v openssl >/dev/null && [[ -f "$crt" ]] && dom=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -oE "DNS:[^,]+" | head -1 | cut -d: -f2)
    [[ -z "$dom" ]] && dom=$(basename "$crt" | sed -E 's/\.(crt|pem)$//; s/_cert$//; s/^cert-//')
    echo "$dom"
}

ask_cert() {  # 输出三种: CERT_FILE+KEY_FILE (TLS) / REALITY_ENV (Reality = TLS enabled false)
    echo "TLS 证书: 1) 真证书 2) 自签(pin) 3) Reality (AnyReality 同款) [默认 2]" >&2
    # 批量生成 Reality 变体时由 batch 显式指定 (见 batch.sh 注释);
    # 只替换交互输入, 复用下方原有 Reality 分支
    local c
    if [[ "${SB_FORCE_TLS_REALTY:-}" == "1" ]]; then c=3
    else
        read -r -p "选择: " c; c=$(clean_input "$c"); [[ -z "$c" ]] && c=2
        sb_batch_tls_override 1 c
    fi
    if [[ "$c" == "3" ]]; then
        local dom sni
        dom=$(safe_read "Reality 握手目标 (统一 domains.sh)" "$(random_domain)")
        mkdir -p "$CERT_DIR"
        if [[ ! -f "$SB_OUT_DIR/reality-keys.json" ]]; then
            local kp=("$("$SB_BIN" generate reality-keypair 2>/dev/null | awk -F': ' "/PrivateKey|PublicKey/{print \$NF}")")
            [[ ${#kp} -lt 0 ]] || :           # awk not needed here, direct friendlier below
        fi
        if [[ ! -s "$SB_OUT_DIR/reality-keys.json" ]]; then
            local priv pub
            mapfile -t kp < <("$SB_BIN" generate reality-keypair 2>/dev/null | awk -F': ' 'NF>1 {print $NF}')
            priv="${kp[0]:-}"; pub="${kp[1]:-}"
            [[ -z "$priv" || -z "$pub" ]] && { print_error "REALITY 密钥生成失败"; return 1; }
            jq -n --arg p "$priv" --arg u "$pub" '{private_key:$p,public_key:$u}' > "$SB_OUT_DIR/reality-keys.json"
        fi
        priv=$(jq -r .private_key "$SB_OUT_DIR/reality-keys.json")
        pub=$(jq -r .public_key "$SB_OUT_DIR/reality-keys.json")
        sid=$(openssl rand -hex 8)
        CERT_DOMAIN="$dom"; TLS_TYPE="reality"
        export T_RE_PRIV="$priv" T_RE_PUB="$pub" T_RE_SID="$sid"
        return 0
    fi
    if [[ "$c" == "2" ]]; then
        local d; d=$(safe_read "自签伪装域名 (统一 domains.sh)" "$(random_domain)")
        mkdir -p "$CERT_DIR"
        CERT_FILE="$CERT_DIR/cert-$d.crt"; KEY_FILE="$CERT_DIR/key-$d.key"
        [[ -f "$CERT_FILE" ]] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
            -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 -subj "/CN=$d" -addext "subjectAltName=DNS:$d" >/dev/null 2>&1
        CERT_DOMAIN="$d"; CERT_TRUSTED=false; return 0
    fi
    # 真证书: 批量模式用 batch 入口选好的那张; 交互模式列出本机证书让你选,
    # 而不是要你手打 crt/key 路径 —— 手打几乎没人填对, 填错了报错还很难看出来。
    [[ -n "${SB_BATCH:-}" ]] && { sb_apply_batch_cert; return $?; }
    pick_trusted_cert_verbose
}

add_config() {
    print_title "新增 Trojan 节点 ($PROTO-NN.json)"
    local listen_ip listen_port password file tag idx
    listen_port=$(safe_read_port)
    password=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
    # Trojan 与 VLESS/VMess 一样带 transport 字段 (只有这两个协议和三者的
    # 兄弟 VMess 有), 之前完全没做传输选项, 等于把这一个维度整个漏掉了。
    sb_ask_transport
    ask_cert || return 1
    [[ -z "$TR_HOST" ]] && TR_HOST="$CERT_DOMAIN"

    # REALITY 与 CDN 互斥: REALITY 走的是端到端握手, Cloudflare 在边缘就终止
    # 了 TLS, 中间插一层代理必然失败。所以 Reality 变体强制直连。
    local trusted="no" ACCESS_MODE="direct"
    if [[ "${TLS_TYPE:-}" != "reality" ]]; then
        sb_key_for "$CERT_FILE" >/dev/null 2>&1 && \
            cert_not_expired "$CERT_FILE" && \
            sb_cert_is_real_issuer "$CERT_FILE" && trusted="yes"
        ask_access_mode "$TR_TYPE" "$trusted"
        case "$ACCESS_MODE" in
            cdn)        listen_ip="0.0.0.0" ;;
            cdn-nginx)  listen_ip="127.0.0.1" ;;
            *)          listen_ip=$(ask_listen_addr) ;;
        esac
    fi
    # REALITY 变体没被上面覆盖到 —— 它强制直连, 监听地址仍需询问
    [[ -n "$listen_ip" ]] || listen_ip=$(ask_listen_addr)

    idx=$(get_next_index "$PROTO"); file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"
    # ask_cert 已决定: TLS_TYPE=reality 还是 selfsign/real —— 名字体现传输方式
    [[ "${TLS_TYPE:-}" == "reality" ]] && tag="$tag$(tag_form_suffix reality)" || tag="$tag$(tag_form_suffix tls)"
    local json tr_json tr_line=""
    sb_ask_multiplex trojan server; local _mux=$(sb_mux_json_server)
    # ECH 只在 CDN 模式问; 两个模板的 tls 行都要插
    sb_ask_ech "$CERT_DOMAIN" "${ACCESS_MODE:-direct}"
    local ech_srv=$(sb_ech_json_server)
    # 这里刻意不把 mux/ech 塞进 heredoc 模板 —— 模板里已经有一个跨行的
    # tr_line 赋值 (为了给 transport 留尾逗号), 再叠一层跨行变量会让 bash
    # 在运行时把它们的参数当命令执行, 而且报错位置还会被归到别处, 极难查。
    # 统一改成 heredoc 出基础结构, 之后用 jq 合并 (和 vmess 同一套路)。
    if [[ "${TLS_TYPE:-}" == "reality" ]]; then
        json=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "trojan",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "users": [ { "password": "$password" } ],
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
    # 裸 TCP: sing-box 里没有 "type":"tcp", 必须整个省略 transport 字段
    tr_json=$(sb_transport_json_server "$TR_TYPE" "$TR_PATH" "$TR_SVC" "$TR_HOST")
    # 注意 sb_transport_json_server 返回的是**值**, "transport" 这个键要在这里补上
    [[ -n "$tr_json" ]] && tr_line="      \"transport\": $tr_json,
"
    json=$(cat <<EOF
{
  "inbounds": [
    {
      "type": "trojan",
      "tag": "$tag",
      "listen": "$listen_ip",
      "listen_port": $listen_port,
      "users": [ { "name": "user", "password": "$password" } ],
$tr_line      "tls": { "enabled": true, "alpn": $(sb_transport_alpn "$TR_TYPE"), "certificate_path": "$CERT_FILE", "key_path": "$KEY_FILE" }
    }
  ]
}
EOF
)
    fi
    # multiplex / ech 统一在这里用 jq 并进去 (片段要补 {} 才是完整 JSON 值)
    [[ -n "$_mux" ]] && json=$(echo "$json" | jq --argjson mx "{$_mux}" '.inbounds[0] += $mx')
    [[ -n "$ech_srv" ]] && json=$(echo "$json" | jq --argjson ec "{$ech_srv}" '.inbounds[0].tls += $ec')

    backup_config config
    write_config "$file" "$json" || return 1
    if ! sb_check; then rm -f "$file"; print_error "已删除非法配置（现网未受影响）"; return 1; fi
    cleanup_node_shares "$tag"
    sb_reload || true

    local server_ip pin="" mode_tls="tls"
    [[ "${TLS_TYPE:-}" == "reality" ]] && mode_tls="reality"
    server_ip=$(ask_server_addr)
    if [[ "$CERT_TRUSTED" == "false" ]]; then pin=$(cert_spki_pin_base64 "$CERT_FILE"); fi
    # 命令替换提前算好: 放在双引号字符串里出错时归因困难, 串联多个替换时行为也不确定
    local mux_link ech_link
    mux_link=$(sb_mux_link_params); ech_link=$(sb_ech_link_params)
    local link
    # CDN 节点只监听 127.0.0.1, 客户端连证书域名而非服务器 IP
    server_ip=$(sb_cdn_finalize "$file" "$server_ip")
    # CDN 只在 443 上提供服务; 沿用源站端口会得到连不通的 域名:源站端口
    sb_node_is_cdn "$file" && listen_port=443
    if [[ "$mode_tls" == "reality" ]]; then
        link="trojan://$password@$server_ip:$listen_port?sni=$CERT_DOMAIN&security=reality&pbk=$T_RE_PUB&sid=$T_RE_SID&type=tcp$mux_link$ech_link$fr_link#$tag"
    else
        # alpn 必须跟着传输走: grpc / http(H2) 要 h2, 写死 http/1.1 会
        # 让客户端在 TLS 握手时与需要 h2 的服务端协商失败。
        local link_alpn; link_alpn=$(sb_transport_alpn "$TR_TYPE" | tr -d '[]"')
        link="trojan://$password@$server_ip:$listen_port?sni=$CERT_DOMAIN&alpn=$link_alpn${pin:+&pinSHA256=$pin}$(sb_transport_link_params "$TR_TYPE" "$TR_PATH" "$TR_SVC" "$TR_HOST")$mux_link$ech_link$fr_link#$tag"
    fi
    local utls_fp; utls_fp=$(ask_utls_fingerprint)
    local ctr_json ctr_sep="" alpn_json
    ctr_json=$(sb_transport_json_client "$TR_TYPE" "$TR_PATH" "$TR_SVC" "$TR_HOST")
    [[ -n "$ctr_json" ]] && ctr_sep=","
    alpn_json=$(sb_transport_alpn "$TR_TYPE")
    sb_ask_multiplex trojan client; local mux_json=$(sb_mux_json_client)
    sb_ask_ech "$CERT_DOMAIN" "${ACCESS_MODE:-direct}"; local ech_cli=$(sb_ech_json_client)
    sb_ask_fragment "$mode_tls"; local frag_cli=$(sb_fragment_json_client)
    local fr_link; fr_link=$(sb_fragment_link_params)
    python3 - "$utls_fp" "$SB_OUT_DIR/sb_client-$tag.json" "$tag" "$server_ip" "$listen_port" "$password" "$CERT_DOMAIN" "$pin" "$mode_tls" "${T_RE_PUB-}" "${T_RE_SID-}" "$ctr_json" "$alpn_json" "$mux_json" "$ech_cli" "$frag_cli" <<'PYGEN'
import json,sys
_,fp,ofile,tag,srv,port,pw,sni,pin,mtype,pub,sid,tr_json,alpn,mux,ech,frag=sys.argv
tls={"enabled":True,"server_name":sni,"alpn":json.loads(alpn),
     "utls":{"enabled":True,"fingerprint":fp}}
# ECH 片段补 {} 才是完整 JSON 值
if ech: tls.update(json.loads("{"+ech+"}"))
if pin: tls["certificate_public_key_sha256"]=pin
out={"type":"trojan","tag":tag,"server":srv,"server_port":int(port),"password":pw,"tls":tls}
if pub and sid:
    # reality: 不需要 certificate, 信任来自 REALITY 密钥对 (sing-box 1.14 OutboundRealityOptions)
    out["tls"]["reality"]={"enabled":True,"public_key":pub,"short_id":sid}
elif tr_json:
    # 裸 TCP 不加 transport 字段 —— sing-box 里没有 "tcp" 这个类型
    out["transport"]=json.loads(tr_json)
# multiplex: 出站才有 protocol / 连接数 / 流数
# mux 是片段 "multiplex": {...}, 补 {} 才是完整 JSON 值
if mux: out.update(json.loads("{"+mux+"}"))
# fragment 同样是片段, 补 {}
if frag: tls.update(json.loads("{"+frag+"}"))
json.dump({"outbounds":[out]},open(ofile,"w"),indent=2)
PYGEN
        gen_mihomo_yaml "$tag"

    # CDN 节点额外产出 .cdn 版产物 (连域名走 Cloudflare), 与直连版并存
    if sb_cdn_enabled "$file"; then
        cdn_node_gen_all "$tag" >/dev/null 2>&1 || true
    fi
    [[ -n "$pin" ]] && echo "  # 自签: mihomo 需 skip-cert-verify: true" >> "$SB_OUT_DIR/sb_client-$tag.yaml"
    echo "$link" | tee "$SB_OUT_DIR/sb_share-$tag.txt" | tail -1 >&2
    grep -vF "$link" "$SB_OUT_DIR/sb_links-all.txt" 2>/dev/null > /tmp/l.$$ && mv /tmp/l.$$ "$SB_OUT_DIR/sb_links-all.txt"
    echo "$link" >> "$SB_OUT_DIR/sb_links-all.txt"
    echo "{\"tag\":\"$tag\",\"port\":$listen_port,\"pin\":\"$pin\",\"password\":\"$password\"}" | jq . > "$SB_OUT_DIR/sb_meta-$tag.json"
    open_port "$listen_port"
    print_ok "Trojan 节点添加完成: $file"
    # 重建聚合: 新节点不在 sb_client-all.json 里的话, 分享链接
    # (菜单3 / all-share URL) 下发的还是旧节点列表。
    declare -F sb_regen_aggregate >/dev/null 2>&1 && sb_regen_aggregate
}

list_configs() {
    print_title "$PROTO 配置"
    for f in "$SB_CONFIG_DIR"/$PROTO-*.json; do
        [[ -f "$f" ]] || continue
        local idx tag port pw ttype detail
        idx=$(basename "$f" .json | cut -d'-' -f2); tag="${PROTO}${idx}"
        port=$(jq -r '.inbounds[0].listen_port' "$f")
        pw=$(jq -r '.inbounds[0].users[0].password' "$f")
        # 裸 TCP 没有 transport 字段, .transport.path 取到 null —— 显示 "tcp"
        ttype=$(jq -r '.inbounds[0].transport.type // "tcp"' "$f")
        detail=$(jq -r '.inbounds[0].transport.path // .inbounds[0].transport.service_name // "-"' "$f")
        printf "%s) 端口:%s  传输:%s  %s\n" "$idx" "$port" "$ttype" "$detail" >&2
    done
}

delete_config() {
    list_configs
    read -r -p "输入要删除的编号: " num; num=$(clean_input "$num")
    [[ "$num" =~ ^[0-9]+$ ]] || { print_error "编号必须数字"; return 1; }
    read -r -p "确认删除编号 $num ($PROTO) 的节点? [y/N]: " dconfirm
    [[ "$(clean_input "$dconfirm")" =~ ^[yY] ]] || { print_warn "已取消"; return 0; }
    local idx file tag
    idx=$(printf "%02d" "$num"); file="$SB_CONFIG_DIR/$PROTO-$idx.json"; tag="${PROTO}${idx}"
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
        add) add_config ;; list) list_configs ;; del) delete_config ;; check) sb_check ;;
        *) while true; do
            print_title "Trojan 节点管理"
            echo -e "${CYAN}1)${RESET} 添加\n${CYAN}2)${RESET} 列出\n${CYAN}3)${RESET} 删除\n${CYAN}0)${RESET} 返回"
            read -r -p "请选择: " c
            case "$(clean_input "$c")" in 1) add_config ;; 2) list_configs ;; 3) delete_config ;; 0) break ;; esac
            read -r -p "按回车继续..." _ || { echo; exit 0; }
        done ;;
    esac
fi
