#!/bin/bash
# ==============================================================
# artifacts.sh — 客户端产物查看器 (JSON / YAML / 分享链接 / 聚合 / 合并 yaml)
# 只读 (合并 yaml 仅生成 out/sb_client-all.yaml, 不动 server 配置).
# CLI:
#   bash artifacts.sh json [编号]   # 单节点 JSON
#   bash artifacts.sh yaml  [编号]  # 单节点 YAML
#   bash artifacts.sh merged        # 全部合并成一份 mihomo YAML
#   bash artifacts.sh links         # 全部分享链接
#   bash artifacts.sh path          # 全部文件路径
# ==============================================================
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SB_LIB="${SB_LIB:-$SELF_DIR/conf/lib.sh}"
[[ -f "$SB_LIB" ]] && source "$SB_LIB"

json_files()  { ls "$SB_OUT_DIR"/sb_client-*.json 2>/dev/null | grep -v "sb_client-all.json" | sort; }
yaml_files()  { ls "$SB_OUT_DIR"/sb_client-*.yaml 2>/dev/null | sort; }
share_files() { ls "$SB_OUT_DIR"/sb_share-*.txt 2>/dev/null | sort; }
tag_of() { basename "$1" | sed -E "s/sb_client-//; s/.json$//; s/.yaml$//"; }

# ---------- 通用: 编号选择 + cat ----------
pick_and_cat() { # pick_and_cat "<file list>\n" "<kind>"
    local list="$1" kind="$2" i f n
    [[ -z "$list" ]] && { print_warn "没有产物文件 (先添加节点)"; return 1; }
    printf "${CYAN}可用 %s 产物:%b\n" "$kind" "$RESET" >&2
    local -a arr=()
    while IFS= read -r f; do arr+=("$f"); done <<<"$list"
    for i in "${!arr[@]}"; do printf " %s) %-18s %s\n" $((i+1)) "$(tag_of "${arr[i]}")" "${arr[i]}" >&2; done
    read -r -p "查看第几项 (0=返回): " n || { echo >&2; return 1; }
    n=$(clean_input "$n")
    [[ -z "$n" || "$n" == "0" ]] && return 1
    if [[ ! "$n" =~ ^[0-9]+$ ]]; then print_error "编号必须数字"; return 1; fi
    if (( n < 1 || n > ${#arr[@]} )); then print_error "编号无效 (1-$(( ${#arr[@]} )))"; return 1; fi
    printf "${MAGENTA}════════ 分享链接 (%s · %s) ════════%b\n" "$(tag_of "${arr[n-1]}")" "$kind" "$RESET" >&2
    cat "${arr[n-1]}"
    echo >&2
    printf "${CYAN}复制路径: %s%b\n" "${arr[n-1]}" "$RESET" >&2
}

pick_share() {
    local list; list=$(share_files)
    [[ -z "$list" ]] && { print_warn "没有 sb_share-*.txt"; return 1; }
    local -a arr=(); local f i n
    while IFS= read -r f; do arr+=("$f"); done <<<"$list"
    echo >&2
    for i in "${!arr[@]}"; do printf " %s) %s\n" $((i+1)) "$(tag_of "${arr[i]}")" >&2; done
    read -r -p "查看第几项 (0=返回): " n || { echo >&2; return 1; }
    n=$(clean_input "$n"); [[ -z "$n" || "$n" == "0" ]] && return 1
    if (( n < 1 || n > ${#arr[@]} )); then print_error "编号无效"; return 1; fi
    printf "${MAGENTA}════════ 分享链接 (%s) ════════%b\n" "$(tag_of "${arr[n-1]}")" "$RESET" >&2
    cat "${arr[n-1]}"
}

view_aggregate() {
    local f="$SB_OUT_DIR/sb_client-all.json"
    [[ -f "$f" ]] || { print_warn "聚合文件不存在 (可运行: bash conf/share.sh regen-aggregate)"; return 1; }
    printf "${MAGENTA}════════ sb_client-all.json ════════%b\n" "$RESET" >&2
    cat "$f"
    echo >&2
    printf "${CYAN}复制路径: %s%b\n" "$f" "$RESET" >&2
}

links_all_view() {
    local f="$SB_OUT_DIR/sb_links-all.txt"
    [[ -f "$f" ]] || { print_warn "没有 sb_links-all.txt"; return 1; }
    printf "${MAGENTA}════════ 全部节点分享链接 ════════%b\n" "$RESET" >&2
    cat "$f"
}

path_view() {
    printf "${CYAN}客户端产物路径 (可 cp/scp/复制):%b\n" "$RESET" >&2
    for f in "$SB_OUT_DIR"/sb_client-*.json "$SB_OUT_DIR"/sb_client-*.yaml "$SB_OUT_DIR"/sb_share-*.txt "$SB_OUT_DIR/sb_links-all.txt"; do
        [[ -f "$f" ]] && printf "  %s\n" "$f"
    done
}

# ---------- 全部节点合并成单一 mihomo/clash 文件 ----------
#
# 修复记录 (三个用户报告的问题):
#   1) 只合并 sb_client-*.yaml, 而 yaml 只有 reality/ss/trojan/tuic/vless 五个协议产出
#      -> vmess / hysteria2 / anytls 全部丢失。改为以 sb_client-*.json (sing-box
#         outbound, 权威数据源) 为准全量转换, 不再依赖各协议脚本是否顺手产出 yaml。
#   2) yaml.safe_dump 把序列写在缩进 0 (proxies: 换行后 "- name: x" 顶格),
#      与各协议脚本自己生成的 2 空格风格不一致, 复制粘贴到编辑器里很别扭。
#      改为自写序列化, 统一 2 空格缩进。
#   3) mihomo 不支持的节点原先被静默丢弃。这里逐条列出原因, 不假装"全都导出了"。
#
# 字段名依据 mihomo 官方文档 (wiki.metacubex.one/en/config/proxies/*) 逐项核对,
# 不凭记忆书写; mihomo 明确不支持的组合 (AnyTLS+Reality) 一律跳过并说明。
merged_yaml() { # 生成 out/sb_client-all.yaml (proxies + PROXY/AUTO 组)
    local -a jarr=()
    mapfile -t jarr < <(ls "$SB_OUT_DIR"/sb_client-*.json 2>/dev/null | grep -v 'sb_client-all\.json$' | sort)
    if (( ${#jarr[@]} == 0 )); then
        print_warn "没有任何客户端产物 sb_client-<tag>.json (先在「节点管理」创建节点)"
        return 1
    fi
    python3 - "$SB_OUT_DIR/sb_client-all.yaml" "$SB_ROOT/cert" "${jarr[@]}" <<'SBYAML'
import sys, os, json

MISSING_FP = []

def load(paths, certdir):
    """sing-box outbound -> mihomo proxy dict。返回 (proxies, names, skipped)"""
    proxies, names, skipped = [], [], []
    for f in paths:
        tag = os.path.basename(f)[len("sb_client-"):-len(".json")]
        try:
            d = json.load(open(f))
        except Exception as e:
            skipped.append((tag, "JSON 解析失败: %s" % e)); continue
        obs = [o for o in (d.get("outbounds") or [])
               if o.get("type") not in ("selector", "urltest", "direct", "block", "dns")]
        if not obs:
            skipped.append((tag, "文件里没有出站对象")); continue
        ob = obs[0]
        p, why = conv(ob, certdir)
        if p is None:
            skipped.append((tag, why)); continue
        if p["name"] in names:
            p["name"] = p["name"] + "_dup"; skipped.append((tag, "重名, 已改名"))
        names.append(p["name"]); proxies.append(p)
    return proxies, names, skipped

def cert_fingerprint(certdir, sni):
    """取 <certdir>/cert-<sni>.crt 的证书 DER SHA256 (mihomo fingerprint 语义)"""
    if not certdir or not sni:
        return ""
    import ssl as _ssl, hashlib
    p = os.path.join(certdir, "cert-%s.crt" % sni)
    if not os.path.isfile(p):
        return ""
    try:
        pem = open(p).read()
        der = _ssl.PEM_cert_to_DER_cert(pem)
        return hashlib.sha256(der).hexdigest()
    except Exception:
        return ""

def conv(ob, certdir):
    """单个 sing-box outbound -> mihomo proxy dict; 不支持则返回 (None, 原因)"""
    t = ob.get("type"); tag = ob.get("tag")
    if ob.get("detour"):
        return None, "detour 外壳 (被别的出站经 detour 引用), 不能单独使用"
    srv, port = ob.get("server"), ob.get("server_port")
    if not srv or not port:
        return None, "缺少 server/server_port"
    tls = ob.get("tls") or {}
    reality = tls.get("reality") or {}
    sni = tls.get("server_name") or tls.get("servername")
    alpn = tls.get("alpn")
    fp = ((tls.get("utls") or {}).get("fingerprint")) or None
    tr = ob.get("transport") or {}
    net = tr.get("type")

    d = {"name": tag, "server": srv, "port": int(port)}

    if t == "vless":
        d["type"] = "vless"; d["uuid"] = ob["uuid"]
        if ob.get("flow"): d["flow"] = ob["flow"]
    elif t == "vmess":
        d["type"] = "vmess"; d["uuid"] = ob["uuid"]
        d["alterId"] = 0; d["cipher"] = "auto"
    elif t == "trojan":
        d["type"] = "trojan"; d["password"] = ob["password"]
    elif t == "anytls":
        if reality.get("enabled"):
            # mihomo 官方原文: "Mihomo does not support AnyTLS+Reality, and will not
            # support this combination in the future."
            return None, "AnyTLS+Reality —— mihomo 官方明确不支持 (且声明不会支持)"
        d["type"] = "anytls"; d["password"] = ob["password"]
    elif t == "hysteria2":
        d["type"] = "hysteria2"; d["password"] = ob["password"]
        if ob.get("up_mbps"):   d["up"] = "%d Mbps" % ob["up_mbps"]
        if ob.get("down_mbps"): d["down"] = "%d Mbps" % ob["down_mbps"]
        obfs = ob.get("obfs") or {}
        if obfs.get("type"):
            d["obfs"] = obfs["type"]; d["obfs-password"] = obfs.get("password", "")
    elif t == "tuic":
        d["type"] = "tuic"; d["uuid"] = ob["uuid"]; d["password"] = ob["password"]
        d["congestion-controller"] = ob.get("congestion_control", "bbr")
    elif t == "shadowsocks":
        d["type"] = "ss"; d["cipher"] = ob["method"]; d["password"] = ob["password"]
        if ob.get("udp_over_tcp"):
            d["udp-over-tcp"] = True
    elif t == "naive":
        return None, "mihomo 无 naive 类型 (官方文档无此页)"
    elif t == "shadowtls":
        return None, "mihomo 无 shadowtls 独立出站类型 (它只是 ss/vmess 的包装插件)"
    else:
        return None, "mihomo 无 %s 出站类型" % t

    # ---- TLS 段 (仅在真的开了 TLS 时写) ----
    need_tls = bool(tls.get("enabled"))
    if need_tls:
        d["tls"] = True
        if sni: d["servername"] = sni
        if alpn: d["alpn"] = list(alpn)
        if tls.get("insecure"): d["skip-cert-verify"] = True
        if fp: d["client-fingerprint"] = fp
        if reality.get("enabled"):
            # mihomo 文档: reality-opts: {public-key, short-id}
            ro = {"public-key": reality.get("public_key", "")}
            if reality.get("short_id"): ro["short-id"] = reality["short_id"]
            d["reality-opts"] = ro
        # 自签证书的钉扎:
        #   sing-box 侧存的是 SPKI 哈希 (tls.certificate_public_key_sha256),
        #   mihomo 侧字段叫 fingerprint, 但官方定义是 **X.509 证书 DER 的 SHA256**
        #   (openssl x509 -noout -fingerprint -sha256), 两者不是一回事,
        #   直接搬过去会让证书钉扎校验失败。这里按 sni 到 cert/ 找证书实算。
        pin = tls.get("certificate_public_key_sha256")
        if pin:
            fp = cert_fingerprint(certdir, sni)
            if fp:
                d["fingerprint"] = fp
            else:
                d["skip-cert-verify"] = True
                MISSING_FP.append(tag)

    # ---- 传输层 ----
    if net in ("ws", "websocket"):
        d["network"] = "ws"
        opts = {"path": tr.get("path") or "/"}
        hdr = (tr.get("headers") or {}).get("Host")
        if hdr: opts["headers"] = {"Host": hdr}
        d["ws-opts"] = opts
    elif net == "grpc":
        d["network"] = "grpc"
        d["grpc-opts"] = {"grpc-service-name": tr.get("service_name") or ""}
    elif net == "http":
        d["network"] = "http"
        d["http-opts"] = {"path": [tr.get("path") or "/"]}
    return d, ""

def dump_scalar(v):
    if isinstance(v, bool):  return "true" if v else "false"
    if v is None:           return "null"
    if isinstance(v, (int, float)): return str(v)
    s = str(v)
    # 需要加引号的场景: 空串 / 含 YAML 特殊字符 / 会被误读成别的类型
    special = set("#&*!|>%@" + chr(96) + chr(39) + chr(34) + "[]{},?-:")
    if s == "" or s[0] in special or ": " in s or " #" in s \
       or s in ("true","false","null","yes","no","on","off","~") or s != s.strip():
        esc = s.replace(chr(92), chr(92)*2).replace(chr(34), chr(92)+chr(34))
        return chr(34) + esc + chr(34)
    return s

def emit(node, ind, buf):
    pad = " " * ind
    if isinstance(node, dict):
        for k, v in node.items():
            if isinstance(v, dict):
                buf.append("%s%s:" % (pad, k))
                emit(v, ind + 2, buf)
            elif isinstance(v, list):
                buf.append("%s%s:" % (pad, k))
                emit_list(v, ind + 2, buf)
            else:
                buf.append("%s%s: %s" % (pad, k, dump_scalar(v)))
    elif isinstance(node, list):
        emit_list(node, ind, buf)

def emit_list(lst, ind, buf):
    # 关键: 序列项统一缩进 2 格 (proxies: 下是 "  - name: x", 不是顶格 "- name: x")
    pad = " " * ind
    for item in lst:
        if isinstance(item, dict):
            first = True
            for k, v in item.items():
                pre = pad + "- " if first else pad + "  "
                first = False
                if isinstance(v, dict):
                    buf.append("%s%s:" % (pre, k)); emit(v, ind + 4, buf)
                elif isinstance(v, list):
                    buf.append("%s%s:" % (pre, k)); emit_list(v, ind + 4, buf)
                else:
                    buf.append("%s%s: %s" % (pre, k, dump_scalar(v)))
        elif isinstance(item, list):
            buf.append(pad + "-")
            emit_list(item, ind + 2, buf)
        else:
            buf.append("%s- %s" % (pad, dump_scalar(item)))

out     = sys.argv[1]
certdir = sys.argv[2] if len(sys.argv) > 2 else ""
proxies, names, skipped = load(sys.argv[3:], certdir)
if not proxies:
    sys.stderr.write("没有任何可转换的节点\n"); sys.exit(1)

doc = {"mixed-port": 7890, "allow-lan": False, "mode": "rule", "log-level": "info",
       "external-controller": "127.0.0.1:9090",
       "proxies": proxies,
       "proxy-groups": [
           {"name": "PROXY", "type": "select", "proxies": names + ["AUTO"]},
           {"name": "AUTO", "type": "url-test",
            "url": "https://www.gstatic.com/generate_204", "interval": 300,
            "tolerance": 50, "proxies": names},
       ],
       "rules": ["MATCH,PROXY"]}

buf = ["# 由 SB-Panel 生成 (菜单 9 -> 7)", "# 源: sb_client-*.json (sing-box outbound) -> mihomo",
       "# 导入: mihomo/clash 客户端可直接使用本文件; 亦可只取 proxies 段并入自己的配置", ""]
emit(doc, 0, buf)
open(out, "w").write("\n".join(buf) + "\n")
sys.stderr.write("已生成 %s: %d 个节点\n" % (out, len(proxies)))
for tag, why in skipped:
    sys.stderr.write("  [跳过] %-16s %s\n" % (tag, why))
for tag in MISSING_FP:
    sys.stderr.write("  [注意] %-16s 自签证书钉扎改用 skip-cert-verify (未找到 cert-<sni>.crt 可算 fingerprint)\n" % tag)
SBYAML
    local rc=$?
    (( rc == 0 )) || { print_error "生成失败"; return 1; }
    return 0
}

merged_yaml_view() {
    merged_yaml || return 1
    echo >&2
    printf "${MAGENTA}════════ 全部节点合并 (sb_client-all.yaml) ════════%b\n" "$RESET" >&2
    cat "$SB_OUT_DIR/sb_client-all.yaml"
    echo >&2
    printf "${CYAN}用法: 整份可直接导入 mihomo/clash; 只换节点的话复制 proxies 段, 其余保留自己的${RESET}\n" >&2
    printf "${CYAN}文件路径: %s%b\n" "$SB_OUT_DIR/sb_client-all.yaml" "$RESET" >&2
}

# ---------- 菜单 ----------
show_menu() {
    while true; do
        print_title "客户端产物 / 配置文件 (JSON·YAML·链接)"
        echo -e "${CYAN}1)${RESET} 单节点 JSON (客户端配置, 复制用)"
        echo -e "${CYAN}2)${RESET} 单节点 YAML  (mihomo/clash 兼容)"
        echo -e "${CYAN}3)${RESET} 单节点分享链接 (trojan:// etc.)"
        echo -e "${CYAN}4)${RESET} 全量聚合 (sb_client-all.json + all-share URL)"
        echo -e "${CYAN}5)${RESET} sb_links-all.txt (一键复制所有节点链接)"
        echo -e "${CYAN}6)${RESET} 全部文件路径 (给 shell/cp/复制用)"
        echo -e "${CYAN}7)${RESET} 全部节点合并成一份 mihomo YAML (sb_client-all.yaml)"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请输入选项 [0-7]: " c || { echo; exit 0; }
        case "$(clean_input "$c")" in
            1) pick_and_cat "$(json_files)" "JSON" ;;
            2) pick_and_cat "$(yaml_files)" "YAML" ;;
            3) pick_share ;;
            4) view_aggregate ;;
            5) links_all_view ;;
            6) path_view ;;
            7) merged_yaml_view ;;
            0) return ;;
            *) print_error "无效选项" ;;
        esac
        read -r -p "按回车键返回主菜单..." _ || { echo; exit 0; }
    done
}

# ---------- CLI ----------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        json)   pick_and_cat "$(json_files)" "JSON" ;;
        yaml)   pick_and_cat "$(yaml_files)" "YAML" ;;
        share)  pick_share ;;
        all)    view_aggregate ;;
        links)  links_all_view ;;
        merged) merged_yaml_view ;;
        path)   path_view ;;
        *)      show_menu ;;
    esac
fi
