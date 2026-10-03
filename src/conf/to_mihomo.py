#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sing-box 客户端产物 -> mihomo YAML 转换器 (SB-Panel 唯一转换真源)

两种模式:
  --merged <out.yaml> <certdir> <sb_client-*.json>...
      输出一份含全部节点的合并配置 (mihomo/clash 可直接导入)

  --single <outdir>  <certdir> <sb_client-*.json>...
      逐个节点输出 sb_client-<tag>.yaml 单节点文件

两者共用 conv() —— 指纹 (client-fingerprint)、证书钉扎 (fingerprint)、
Reality 参数、自签回退 (skip-cert-verify) 的处理逻辑完全一致。
"""
import sys, os, json

MISSING_FP = []
SKIPPED_OPTS = []

HDR = ["# 由 SB-Panel 生成 (conf/to_mihomo.py)",
       "# 源: sb_client-<tag>.json (sing-box outbound) -> mihomo (Clash.Meta)",
       "# 导入: mihomo / Clash.Meta 客户端可直接使用", ""]


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
        if sni:
            if reality.get("enabled"):
                # Reality 节点两个字段都要写, 各协议认的不一样 (实测矩阵,
                # 同一批 sing-box 服务端节点, 同一套凭据, 只换字段名):
                #            sni   servername   sni+servername
                #   vless    ✗        ✓ 3/3         ✓ 3/3
                #   vmess    ✗        ✓ 3/3         ✓ 3/3
                #   trojan   ✓ 3/3    ✗            ✓ 3/3
                # mihomo 的 vless/vmess Reality 只读 servername: 只给 sni 时它
                # 当普通 TLS 直连, Reality 握手压根不发, 服务端收到一个不带
                # SNI 的 ClientHello, 回 TLS alert unrecognized_name。
                # trojan 那边反过来, 只认 sni。写全最省事, 副作用为零。
                d["sni"] = sni
                d["servername"] = sni
            else:
                d["sni"] = sni
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
            fp2 = cert_fingerprint(certdir, sni)
            if fp2:
                d["fingerprint"] = fp2
            else:
                d["skip-cert-verify"] = True
                MISSING_FP.append(tag)

        # ---- ECH ----
        # mihomo 的 ech-opts 与 sing-box 的 ech 同义: 都是让客户端去 DNS 取
        # 域名的 ECHConfigList (HTTPS/SVCB 的 ech= 参数), 用 Cloudflare 发布的
        # 密钥加密 ClientHello, 外层 SNI 换成 cloudflare-ech.com。
        #   mihomo: ech-opts: { enable: true, query-server-name: <真实域名> }
        #   sing-box: ech: { enabled: true, query_server_name: <真实域名> }
        ech = tls.get("ech") or {}
        if ech.get("enabled"):
            q = ech.get("query_server_name")
            if q:
                d["ech-opts"] = {"enable": True, "query-server-name": q}
            elif ech.get("config") or ech.get("config_path"):
                # 直连模式: sing-box 用本地 ECHCONFIGS 文件, mihomo 没有对应字段
                # (ech-opts 只支持 DNS 查询形式), 转过去必然连不上。
                SKIPPED_OPTS.append("%s: ech 用本地 config 文件, mihomo 无法表达" % tag)
            else:
                SKIPPED_OPTS.append("%s: ech 开了但没有 query_server_name" % tag)

    # ---- 多路复用 ----
    # mihomo 的 smux 是**通用字段**, 任何 proxy 类型都能挂; 它的 brutal 直接内建
    # 在 smux.brutal-opts 下 (up/down 单位 Mbps), 正好对上 sing-box 的 brutal。
    # 官方文档: smux.protocol 默认就是 h2mux。
    mx = ob.get("multiplex") or {}
    if mx.get("enabled"):
        sm = {"enabled": True}
        if mx.get("protocol"): sm["protocol"] = mx["protocol"]
        if mx.get("max_connections"): sm["max-connections"] = mx["max_connections"]
        if mx.get("min_streams"):   sm["min-streams"] = mx["min_streams"]
        if mx.get("max_streams"):   sm["max-streams"] = mx["max_streams"]
        b = mx.get("brutal") or {}
        if b.get("enabled"):
            sm["brutal-opts"] = {
                "enabled": True,
                "up": b.get("up_mbps", 0),
                "down": b.get("down_mbps", 0),
            }
        d["smux"] = sm

    # ---- 传输层 ----
    # sing-box 的 type -> mihomo 的 network, 两个反直觉的映射:
    #   sing-box "httpupgrade" -> mihomo **没有** network: httpupgrade 这个键,
    #     写错会落到 default 分支变成**裸 TCP 静默降级**。正确写法是
    #     network: ws + ws-opts.v2ray-http-upgrade: true。
    #   sing-box "http" (HTTP/2) -> mihomo 的键叫 **h2**; mihomo 自己的
    #     network: http 是另一个 HTTP/1.1 传输, 两者不是一回事。
    if net in ("ws", "websocket"):
        d["network"] = "ws"
        opts = {"path": tr.get("path") or "/"}
        hdr = (tr.get("headers") or {}).get("Host")
        if hdr: opts["headers"] = {"Host": hdr}
        d["ws-opts"] = opts
    elif net == "httpupgrade":
        d["network"] = "ws"
        opts = {"path": tr.get("path") or "/", "v2ray-http-upgrade": True}
        if tr.get("host"): opts["headers"] = {"Host": tr["host"]}
        d["ws-opts"] = opts
    elif net == "grpc":
        d["network"] = "grpc"
        d["grpc-opts"] = {"grpc-service-name": tr.get("service_name") or ""}
    elif net == "http":
        d["network"] = "h2"
        d["h2-opts"] = {"host": ([tr["host"]] if isinstance(tr.get("host"), str)
                                 else (tr.get("host") or [])), "path": tr.get("path") or "/"}
    return d, ""


def dump_scalar(v):
    if isinstance(v, bool):  return "true" if v else "false"
    if v is None:           return "null"
    if isinstance(v, (int, float)): return str(v)
    s = str(v)
    # 需要加引号的场景: 空串 / 含 YAML 特殊字符 / 会被误读成别的类型
    if (s == "" or s[0] in "-?:,[]{}#&*!|>'\"%@` " or ": " in s or " #" in s
            or s in ("true", "false", "null", "yes", "no", "on", "off", "~")):
        return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')
    if s.endswith(":") or s.endswith(" "):
        return '"%s"' % s
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


def write_single(outdir, certdir, paths):
    """逐节点输出 sb_client-<tag>.yaml"""
    ok, skipped = 0, []
    for f in paths:
        tag = os.path.basename(f)[len("sb_client-"):-len(".json")]
        out = os.path.join(outdir, "sb_client-%s.yaml" % tag)
        d = json.load(open(f))
        obs = [o for o in (d.get("outbounds") or [])
               if o.get("type") not in ("selector", "urltest", "direct", "block", "dns")]
        if not obs:
            skipped.append((tag, "文件里没有出站对象")); continue
        p, why = conv(obs[0], certdir)
        if p is None:
            skipped.append((tag, why))
            try: os.remove(out)
            except OSError: pass
            continue
        buf = list(HDR)
        emit({"proxies": [p]}, 0, buf)
        open(out, "w").write("\n".join(buf) + "\n")
        ok += 1
    sys.stderr.write("已生成单节点 YAML: %d 个 -> %s\n" % (ok, outdir))
    for tag, why in skipped:
        sys.stderr.write("  [跳过] %-16s %s\n" % (tag, why))
    for tag in MISSING_FP:
        sys.stderr.write("  [注意] %-16s 自签证书钉扎改用 skip-cert-verify "
                         "(未找到 cert-<sni>.crt 可算 fingerprint)\n" % tag)
    for msg in SKIPPED_OPTS:
        sys.stderr.write("  [注意] %s\n" % msg)
    return 0


def main():
    if len(sys.argv) < 4:
        sys.stderr.write(__doc__); return 2
    mode, out, certdir = sys.argv[1], sys.argv[2], sys.argv[3]
    paths = sys.argv[4:]
    if mode == "--merged":
        proxies, names, skipped = load(paths, certdir)
        if not proxies:
            sys.stderr.write("没有任何可转换的节点\n"); return 1
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
        buf = list(HDR)
        emit(doc, 0, buf)
        open(out, "w").write("\n".join(buf) + "\n")
        sys.stderr.write("已生成 %s: %d 个节点\n" % (out, len(proxies)))
        for tag, why in skipped:
            sys.stderr.write("  [跳过] %-16s %s\n" % (tag, why))
        for msg in SKIPPED_OPTS:
            sys.stderr.write("  [注意] %s\n" % msg)
        for tag in MISSING_FP:
            sys.stderr.write("  [注意] %-16s 自签证书钉扎改用 skip-cert-verify "
                             "(未找到 cert-<sni>.crt 可算 fingerprint)\n" % tag)
        return 0
    if mode == "--single":
        return write_single(out, certdir, paths)
    sys.stderr.write("未知模式: %s\n" % mode); return 2


if __name__ == "__main__":
    sys.exit(main())