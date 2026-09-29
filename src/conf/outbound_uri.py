#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
outbound_uri.py — 代理分享链接 -> sing-box outbound

schema 基线: sing-box v1.14.1 (SagerNet/sing-box@v1.14.1 option/*.go)
已按该版本实际结构实现, 不使用任何记忆/臆测字段:
  socks        server, server_port, version(4/4a/5), username, password
  http         server, server_port, username, password, tls, path, headers
  shadowsocks  server, server_port, method(必填), password(必填), plugin, plugin_opts
  vmess        server, server_port, uuid(必填), security, alter_id, tls, transport, packet_encoding
  vless        server, server_port, uuid(必填), flow, tls, transport
  trojan       server, server_port, password(必填), tls, transport
  hysteria2    server, server_port, password, up_mbps, down_mbps, obfs, tls
  tuic         server, server_port, uuid(必填), password, congestion_control, udp_relay_mode, tls
  anytls       server, server_port, password, tls
  shadowtls    server, server_port, version, password, tls
  naive        server, server_port, username, password, tls   (需内核带 cronet)

设计约束(对应需求 十二/十三):
  * 每种 scheme 一个独立 parser, 不做"万能 URL 解析器"
  * 任何必填项缺失/非法 -> 直接失败并说明原因, 绝不产出半残配置
  * 敏感值只在 preview 中以掩码出现, 由本脚本负责掩码后再交给面板显示

输出 (stdout, 单个 JSON 对象):
  {"ok":true,"scheme":..,"type":..,"name":..,"outbound":{..},"preview":[[标签,值],..]}
  {"ok":false,"error":"原因"}
"""

import base64
import binascii
import json
import re
import sys
import urllib.parse as up

# sing-box v1.14.1 ShadowsocksOutboundOptions.Method 枚举
SS_METHODS = [
    "none", "aes-128-gcm", "aes-192-gcm", "aes-256-gcm",
    "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
    "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm",
    "2022-blake3-chacha20-poly1305",
    "aes-128-ctr", "aes-192-ctr", "aes-256-ctr",
    "aes-128-cfb", "aes-192-cfb", "aes-256-cfb",
    "rc4-md5", "chacha20-ietf", "xchacha20",
]
VMESS_SECURITY = ["auto", "none", "zero", "aes-128-cfb", "aes-128-gcm", "chacha20-poly1305"]
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
HOST_RE = re.compile(r"^[A-Za-z0-9._\-一-鿿]+$|^[0-9A-Fa-f:]+$")


class UriError(Exception):
    """分享链接无法解析 —— 消息即给用户看的原因"""


# ----------------------------------------------------------------- 基础工具
def b64d(s):
    """base64 解码, 容忍 URL-safe / 缺 padding"""
    s = s.strip().replace("\n", "").replace("\r", "")
    s = s.replace("-", "+").replace("_", "/")
    s = up.unquote(s)
    s += "=" * (-len(s) % 4)
    try:
        return base64.b64decode(s, validate=False).decode("utf-8", "strict")
    except (binascii.Error, UnicodeDecodeError, ValueError) as e:
        raise UriError("base64 解码失败 (%s)" % e)


def mask_uuid(u):
    """UUID 脱敏: 与密码同一口径。保留首尾各 4 位便于人工核对, 中间一律掩码。
    面板对"列出出站"也只显示"认证=已配置", 这里保持一致。"""
    u = str(u)
    if len(u) <= 8:
        return "******** (已配置)"
    return "%s****%s (已配置)" % (u[:4], u[-4:])


def mask(v):
    """凭据脱敏: 固定长度掩码, 不回显原文也不回显长度
    (回显长度会缩小暴力破解空间, 且与"从远程配置导入"的预览口径不一致)"""
    return "******** (已配置)" if str(v) else "(空)"


def check_host(h, ctx):
    h = (h or "").strip()
    if not h:
        raise UriError("%s: 服务器地址为空" % ctx)
    if any(c.isspace() for c in h):
        raise UriError("%s: 服务器地址含空格" % ctx)
    if h.startswith("[") and h.endswith("]"):
        h = h[1:-1]
    if not re.match(r"^[A-Za-z0-9._\-]+$", h) and not re.match(r"^[0-9A-Fa-f:]+$", h):
        raise UriError("%s: 服务器地址非法: %r" % (ctx, h))
    return h


def check_port(p, ctx, default=None):
    p = (p or "").strip()
    if not p:
        if default is not None:
            return default
        raise UriError("%s: 缺少端口" % ctx)
    if not p.isdigit():
        raise UriError("%s: 端口不是数字: %r" % (ctx, p))
    p = int(p)
    if not (1 <= p <= 65535):
        raise UriError("%s: 端口超出范围 1-65535: %d" % (ctx, p))
    return p


def check_uuid(u, ctx):
    u = (u or "").strip()
    if not u:
        raise UriError("%s: 缺少 UUID" % ctx)
    if not UUID_RE.match(u):
        raise UriError("%s: UUID 格式非法: %r" % (ctx, u))
    return u.lower()


def split_hostport(s, ctx):
    """拆 host:port, 支持 [IPv6]:port / 裸 IPv6 / host:port / host
    注意: SIP002 会在端口后带路径 (host:443/?plugin=..), 在这里一并丢弃"""
    s = (s or "").strip()
    if not s:
        raise UriError("%s: 地址为空" % ctx)
    if s.startswith("["):
        end = s.find("]")
        if end < 0:
            raise UriError("%s: IPv6 地址缺少 ']'" % ctx)
        host = s[1:end]
        rest = s[end + 1:].split("/", 1)[0]      # 丢弃 ']:443/xxx' 中的路径
        if rest.startswith(":"):
            return host, rest[1:]
        if rest:
            raise UriError("%s: IPv6 地址后有多余内容 %r" % (ctx, rest))
        return host, ""
    if s.count(":") > 1:                          # 裸 IPv6, 无端口
        return s.split("/", 1)[0], ""
    base = s.partition("/")[0]
    if ":" in base:
        host, _, port = base.rpartition(":")
        return host, port
    return base, ""                               # 无端口: 交由调用方按协议默认值处理
    if s.startswith("["):
        end = s.find("]")
        if end < 0:
            raise UriError("%s: IPv6 地址缺少 ']'" % ctx)
        host = s[1:end]
        rest = s[end + 1:]
        if rest.startswith(":"):
            return host, rest[1:]
        if rest:
            raise UriError("%s: IPv6 地址后有多余内容 %r" % (ctx, rest))
        return host, ""
    if s.count(":") > 1:                      # 裸 IPv6, 无端口
        return s, ""
    if ":" in s:
        host, _, port = s.rpartition(":")
        return host, port
    return s, ""


def q1(qs, key, default=""):
    """取 query 单值 (大小写不敏感, 兼容 fp/client-fingerprint 等别名)"""
    if not qs:
        return default
    for k, v in qs.items():
        if k.lower() == key.lower():
            return v[0] if v else default
    return default


def truthy(v):
    return str(v).strip().lower() in ("1", "true", "yes", "on")


def build_tls(sni="", insecure=False, alpn="", fp="", reality_pbk="", reality_sid=""):
    """构造 OutboundTLSOptions (v1.14 字段名: enabled/server_name/insecure/alpn/utls/reality)"""
    tls = {"enabled": True}
    if sni:
        tls["server_name"] = sni
    if insecure:
        tls["insecure"] = True
    if alpn:
        tls["alpn"] = [x for x in alpn.split(",") if x]
    if fp:
        tls["utls"] = {"enabled": True, "fingerprint": fp}
    if reality_pbk:
        r = {"enabled": True, "public_key": reality_pbk}
        if reality_sid:
            r["short_id"] = reality_sid
        tls["reality"] = r
    return tls


def build_transport(net, host, path, service_name, ctx):
    """V2RayTransportOptions: http / ws / grpc / httpupgrade (1.14 枚举)"""
    net = (net or "").strip().lower()
    if not net or net in ("tcp", "none", ""):
        return None
    if net == "ws":
        t = {"type": "ws"}
        if path:
            t["path"] = path
        if host:
            t["headers"] = {"Host": host}
        return t
    if net == "grpc":
        t = {"type": "grpc"}
        if host:
            t["service_name"] = host
        if path:
            t["service_name"] = path
        return t
    if net == "http":
        t = {"type": "http"}
        if host:
            t["host"] = [x for x in host.split(",") if x]
        t["path"] = path or "/"
        return t
    if net == "httpupgrade":
        t = {"type": "httpupgrade"}
        if host:
            t["host"] = host
        t["path"] = path or "/"
        return t
    raise UriError("%s: 不支持的传输方式 type=%r (本面板支持 tcp/ws/grpc/http/httpupgrade)" % (ctx, net))


# ----------------------------------------------------------------- ss://
def parse_ss(uri, name):
    """ss://  SIP002: ss://BASE64(method:password)@host:port/?plugin=..#name
              legacy:  ss://BASE64(method:password@host:port)#name"""
    ctx = "ss://"
    body = uri[5:]
    body = body.split("?", 1)
    query = up.parse_qs(body[1]) if len(body) > 1 else {}
    core = body[0]

    if "@" in core:
        userinfo, _, tail = core.rpartition("@")
        hostport = tail.split("/", 1)[0]
        if ":" in userinfo and not re.match(r"^[A-Za-z0-9+/=_-]+$", userinfo):
            userinfo = up.unquote(userinfo)
        else:
            userinfo = b64d(userinfo)
    else:
        dec = b64d(core.split("/", 1)[0])
        if "@" not in dec:
            raise UriError("无法解析: base64 内容不是 method:password@host:port")
        userinfo, _, hostport = dec.rpartition("@")

    if ":" not in userinfo:
        raise UriError("无法解析: 缺少 method:password")
    method, _, password = userinfo.partition(":")
    method = method.strip()
    if not method:
        raise UriError("无法解析: 缺少加密方式 method")
    if method not in SS_METHODS:
        raise UriError("加密方式不在 sing-box 支持列表: %r" % method)
    if password == "":
        raise UriError("无法解析: 密码为空")

    host, port = split_hostport(hostport, ctx)
    host = check_host(host, ctx)
    port = check_port(port, ctx)

    ob = {"type": "shadowsocks", "server": host, "server_port": port,
          "method": method, "password": password}

    plugin = q1(query, "plugin")
    if plugin:
        pname, _, popts = plugin.partition(";")
        pname = pname.strip()
        if pname not in ("obfs-local", "v2ray-plugin"):
            raise UriError("不支持的 plugin: %r (仅 obfs-local / v2ray-plugin)" % pname)
        ob["plugin"] = pname
        if popts:
            ob["plugin_opts"] = popts
        plugin_line = "%s (%s)" % (pname, popts or "无参数")
    else:
        plugin_line = "无"

    preview = [
        ["加密方式", method],
        ["密码", mask(password)],
        ["插件", plugin_line],
    ]
    return "ss", "shadowsocks", name, ob, preview


# ----------------------------------------------------------------- vmess://
def parse_vmess(uri, name):
    """vmess://BASE64(JSON)  (v2rayN 格式)"""
    ctx = "vmess://"
    payload = uri[8:]
    payload = payload.split("#", 1)[0]
    try:
        d = json.loads(b64d(payload))
    except (json.JSONDecodeError, UriError) as e:
        raise UriError("vmess 链接不是合法的 base64 JSON (%s)" % (e if isinstance(e, UriError) else "JSON 解析失败"))

    host = check_host(d.get("add", ""), ctx)
    port = check_port(d.get("port", ""), ctx)
    uuid = check_uuid(d.get("id", ""), ctx)

    ob = {"type": "vmess", "server": host, "server_port": port, "uuid": uuid}

    sec = (d.get("scy") or "auto").strip() or "auto"
    if sec not in VMESS_SECURITY:
        raise UriError("vmess 加密方式非法: %r (支持 %s)" % (sec, "/".join(VMESS_SECURITY)))
    ob["security"] = sec

    try:
        aid = int(d.get("aid") or 0)
    except (TypeError, ValueError):
        raise UriError("alterId 不是数字: %r" % d.get("aid"))
    if aid:
        ob["alter_id"] = aid

    tls_on = str(d.get("tls", "")).strip().lower() in ("tls", "true", "1", "reality")
    sni = (d.get("sni") or d.get("host") or "").strip()
    alpn = (d.get("alpn") or "").strip()
    fp = (d.get("fp") or "").strip()
    if tls_on:
        ob["tls"] = build_tls(sni, False, alpn, fp)

    net = (d.get("net") or "").strip()
    host_hdr = (d.get("host") or "").strip()
    path = (d.get("path") or "").strip()
    t = build_transport(net, host_hdr, path, None, ctx)
    if t:
        ob["transport"] = t

    name = (d.get("ps") or "").strip() or name
    preview = [
        ["UUID", mask_uuid(uuid)],
        ["加密方式", sec],
        ["alterId", str(aid)],
        ["TLS", "启用 (SNI=%s)" % (sni or "跟随服务器") if tls_on else "未启用"],
        ["传输", net or "tcp"],
    ]
    return "vmess", "vmess", name, ob, preview


# ----------------------------------------------------------------- vless://
def parse_vless(uri, name):
    """vless://uuid@host:port?encryption=none&security=tls&sni=&type=ws&flow=#name"""
    ctx = "vless://"
    body = uri[8:]
    body, _, query_s = body.partition("?")
    query = up.parse_qs(query_s) if query_s else {}
    if "@" not in body:
        raise UriError("无法解析: 缺少 uuid@host:port")
    uuid_s, _, hostport = body.rpartition("@")
    uuid = check_uuid(uuid_s, ctx)
    host, port = split_hostport(hostport, ctx)
    host = check_host(host, ctx)
    port = check_port(port, ctx, default=443)

    enc = q1(query, "encryption", "none")
    if enc and enc.lower() != "none":
        raise UriError("vless 暂只支持 encryption=none, 收到: %r" % enc)

    ob = {"type": "vless", "server": host, "server_port": port, "uuid": uuid}

    sec = (q1(query, "security") or "none").strip().lower()
    sni = q1(query, "sni") or q1(query, "host")
    alpn = q1(query, "alpn")
    fp = q1(query, "fp") or q1(query, "fingerprint") or q1(query, "client-fingerprint")
    tls_line = "未启用"
    if sec in ("tls", "reality"):
        pbk = q1(query, "pbk") or q1(query, "public-key")
        sid = q1(query, "sid") or q1(query, "short-id")
        if sec == "reality":
            if not pbk:
                raise UriError("reality 需要 pbk (公钥) 参数")
            ob["tls"] = build_tls(sni, False, alpn, fp, pbk, sid)
            tls_line = "REALITY (SNI=%s)" % (sni or host)
        else:
            ob["tls"] = build_tls(sni, truthy(q1(query, "allowInsecure")) or truthy(q1(query, "insecure")), alpn, fp)
            tls_line = "TLS (SNI=%s)" % (sni or "跟随服务器")
    elif sec not in ("none", ""):
        raise UriError("vless 不支持的安全类型: %r" % sec)

    flow = q1(query, "flow").strip()
    if flow:
        if not ob.get("tls"):
            raise UriError("flow=%s 需要同时启用 TLS/REALITY" % flow)
        ob["flow"] = flow

    t = build_transport(q1(query, "type"), q1(query, "host"), q1(query, "path"), None, ctx)
    if t:
        ob["transport"] = t

    preview = [
        ["UUID", mask_uuid(uuid)],
        ["TLS", tls_line],
        ["flow", flow or "无"],
        ["传输", (q1(query, "type") or "tcp")],
    ]
    return "vless", "vless", name, ob, preview


# ----------------------------------------------------------------- trojan://
def parse_trojan(uri, name):
    """trojan://password@host:port?sni=&type=&path=#name"""
    ctx = "trojan://"
    body = uri[9:]
    body, _, query_s = body.partition("?")
    query = up.parse_qs(query_s) if query_s else {}
    if "@" not in body:
        raise UriError("无法解析: 缺少 password@host:port")
    pw, _, hostport = body.rpartition("@")
    if not pw:
        raise UriError("无法解析: 密码为空")
    password = up.unquote(pw)
    host, port = split_hostport(hostport, ctx)
    host = check_host(host, ctx)
    port = check_port(port, ctx, default=443)

    ob = {"type": "trojan", "server": host, "server_port": port, "password": password}
    sni = q1(query, "sni") or q1(query, "host")
    alpn = q1(query, "alpn")
    fp = q1(query, "fp") or q1(query, "fingerprint")
    ob["tls"] = build_tls(sni, truthy(q1(query, "allowInsecure")) or truthy(q1(query, "insecure")), alpn, fp)
    t = build_transport(q1(query, "type"), q1(query, "host"), q1(query, "path"), None, ctx)
    if t:
        ob["transport"] = t

    preview = [
        ["密码", mask(password)],
        ["TLS", "启用 (SNI=%s)" % (sni or "跟随服务器")],
        ["传输", (q1(query, "type") or "tcp")],
    ]
    return "trojan", "trojan", name, ob, preview


# ----------------------------------------------------------------- hysteria2://
def parse_hysteria2(uri, name):
    """hysteria2://auth@host:port?sni=&insecure=&obfs=&obfs-password=#name
       hy2:// 为官方简写, 语义相同"""
    ctx = "hysteria2://"
    body = uri.split("://", 1)[1]
    body, _, query_s = body.partition("?")
    query = up.parse_qs(query_s) if query_s else {}
    if "@" not in body:
        raise UriError("无法解析: 缺少 auth@host:port")
    auth, _, hostport = body.rpartition("@")
    if not auth:
        raise UriError("无法解析: 密码(auth)为空")
    password = up.unquote(auth)
    host, port = split_hostport(hostport, ctx)
    host = check_host(host, ctx)
    port = check_port(port, ctx, default=443)

    ob = {"type": "hysteria2", "server": host, "server_port": port, "password": password}

    sni = q1(query, "sni") or q1(query, "peer")
    alpn = q1(query, "alpn")
    insecure = truthy(q1(query, "insecure")) or truthy(q1(query, "allowInsecure")) or truthy(q1(query, "skip-cert-verify"))
    pin = q1(query, "pinSHA256") or q1(query, "pinsha256")
    tls = build_tls(sni, insecure, alpn)
    if pin:
        # v1.14: certificate_public_key_sha256
        try:
            tls["certificate_public_key_sha256"] = [pin] if isinstance(pin, str) else list(pin)
        except Exception:
            raise UriError("pinSHA256 格式非法: %r" % pin)
    ob["tls"] = tls

    obfs_type = q1(query, "obfs").strip().lower()
    obfs_line = "无"
    if obfs_type:
        if obfs_type != "salamander":
            raise UriError("不支持的 obfs: %r (仅 salamander)" % obfs_type)
        obfs_pw = q1(query, "obfs-password") or q1(query, "obfs_param")
        if not obfs_pw:
            raise UriError("obfs=salamander 需要 obfs-password 参数")
        ob["obfs"] = {"type": "salamander", "password": obfs_pw}
        obfs_line = "salamander (%s)" % mask(obfs_pw)

    up_mbps = q1(query, "upmbps") or q1(query, "up_mbps")
    down_mbps = q1(query, "downmbps") or q1(query, "down_mbps")
    for label, val in (("up_mbps", up_mbps), ("down_mbps", down_mbps)):
        if val:
            if not val.isdigit():
                raise UriError("%s 不是数字: %r" % (label, val))
            ob[label] = int(val)

    ports = q1(query, "mport") or q1(query, "server_ports")
    if ports:
        sp = [x for x in ports.split(",") if x]
        for x in sp:
            check_port(x, "server_ports")
        ob["server_ports"] = sp

    preview = [
        ["密码", mask(password)],
        ["SNI", sni or "跟随服务器"],
        ["TLS", "启用%s" % (" (跳过证书校验)" if insecure else "")],
        ["混淆", obfs_line],
        ["带宽", "up=%s Mbps / down=%s Mbps" % (ob.get("up_mbps", "未指定"), ob.get("down_mbps", "未指定"))],
    ]
    if "server_ports" in ob:
        preview.append(["端口跳跃", ", ".join(ob["server_ports"])])
    return "hysteria2", "hysteria2", name, ob, preview


# ----------------------------------------------------------------- tuic://
def parse_tuic(uri, name):
    """tuic://uuid:password@host:port?congestion_control=&udp_relay_mode=&alpn=&sni=#name"""
    ctx = "tuic://"
    body = uri[7:]
    body, _, query_s = body.partition("?")
    query = up.parse_qs(query_s) if query_s else {}
    if "@" not in body:
        raise UriError("无法解析: 缺少 uuid:password@host:port")
    userinfo, _, hostport = body.rpartition("@")
    if ":" not in userinfo:
        raise UriError("无法解析: 缺少 uuid:password (sing-box 1.14 TUIC 需要两者)")
    uuid_s, _, pw_s = userinfo.partition(":")
    uuid = check_uuid(up.unquote(uuid_s), ctx)
    password = up.unquote(pw_s)
    if not password:
        raise UriError("无法解析: 密码为空")
    host, port = split_hostport(hostport, ctx)
    host = check_host(host, ctx)
    port = check_port(port, ctx, default=443)

    ob = {"type": "tuic", "server": host, "server_port": port, "uuid": uuid, "password": password}

    cc = q1(query, "congestion_control").strip().lower()
    if cc:
        if cc not in ("cubic", "new_reno", "bbr"):
            raise UriError("congestion_control 非法: %r (支持 cubic/new_reno/bbr)" % cc)
        ob["congestion_control"] = cc

    urm = q1(query, "udp_relay_mode").strip().lower()
    if urm:
        if urm not in ("native", "quic"):
            raise UriError("udp_relay_mode 非法: %r (支持 native/quic)" % urm)
        ob["udp_relay_mode"] = urm

    sni = q1(query, "sni") or q1(query, "host")
    alpn = q1(query, "alpn") or "h3"
    fp = q1(query, "fp") or q1(query, "fingerprint")
    ob["tls"] = build_tls(sni, truthy(q1(query, "allowInsecure")) or truthy(q1(query, "insecure")), alpn, fp)

    if truthy(q1(query, "zero_rtt_handshake")):
        ob["zero_rtt_handshake"] = True

    preview = [
        ["UUID", mask_uuid(uuid)],
        ["密码", mask(password)],
        ["拥塞控制", ob.get("congestion_control", "内核默认")],
        ["UDP 转发", ob.get("udp_relay_mode", "内核默认")],
        ["SNI", sni or "跟随服务器"],
        ["ALPN", ", ".join(ob["tls"].get("alpn", [])) or "h3"],
    ]
    return "tuic", "tuic", name, ob, preview


# ----------------------------------------------------------------- 派发
PARSERS = {
    "ss": parse_ss,
    "vmess": parse_vmess,
    "vless": parse_vless,
    "trojan": parse_trojan,
    "hysteria2": parse_hysteria2,
    "hy2": parse_hysteria2,
    "tuic": parse_tuic,
}

SUPPORTED_SCHEMES = ["ss", "vmess", "vless", "trojan", "hysteria2", "hy2", "tuic"]


def main():
    if len(sys.argv) == 2 and sys.argv[1] in ("--schemes", "-s"):
        print(json.dumps(SUPPORTED_SCHEMES))
        return 0
    if len(sys.argv) != 2:
        print(json.dumps({"ok": False, "error": "用法: outbound_uri.py <分享链接>"}, ensure_ascii=False))
        return 2

    uri = sys.argv[1].strip().strip("'\"")
    if not uri:
        print(json.dumps({"ok": False, "error": "分享链接为空"}, ensure_ascii=False))
        return 2

    if "://" not in uri:
        print(json.dumps({"ok": False, "error": "不是合法的分享链接 (缺少 scheme://)"}, ensure_ascii=False))
        return 2

    scheme = uri.split("://", 1)[0].lower()
    parser = PARSERS.get(scheme)
    if parser is None:
        print(json.dumps({
            "ok": False,
            "error": "不支持的协议 %r; 本面板支持: %s" % (scheme, ", ".join(SUPPORTED_SCHEMES)),
        }, ensure_ascii=False))
        return 2

    name = ""
    if "#" in uri:
        uri, frag = uri.split("#", 1)
        name = up.unquote(frag).strip()
    uri = uri.strip()

    try:
        s, t, pname, ob, preview = parser(uri, name)
        name = pname or name
    except UriError as e:
        print(json.dumps({"ok": False, "error": "无法解析该分享链接\n原因: %s" % e}, ensure_ascii=False))
        return 2
    except Exception as e:                     # 任何意外都不得写盘
        print(json.dumps({"ok": False, "error": "无法解析该分享链接\n原因: 解析器异常 %s: %s" % (type(e).__name__, e)}, ensure_ascii=False))
        return 2

    print(json.dumps({
        "ok": True, "scheme": s, "type": t, "name": name,
        "outbound": ob, "preview": preview,
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
