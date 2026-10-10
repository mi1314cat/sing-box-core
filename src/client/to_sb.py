#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把各种"别人家的订阅格式"转成 sing-box outbound 配置。

客户端面板的 `add` 现在只认自家 share 服务返回的 sing-box JSON, 但用户
手上��订阅五花八门。这个脚本负责先认出来, 再转:

  1. base64 订阅      整份 base64, 解开是一堆 vmess:// vless:// ...
  2. 明文 share URI   一行一个 vmess:// vless:// trojan:// ss:// ...
  3. mihomo YAML 片段 形如
                          - name: "Browser-Dialer"
                            type: socks5
                            server: 10.0.0.5
                            port: 1080
                            udp: true
  4. sing-box JSON     自家 share, 原样透传
  5. mihomo 整份 YAML   proxies: 段 (取 proxies, 忽略 rules 等其他段)

识别顺序即上面的顺序: 从最结构化的往回退, 因为 YAML 和 JSON 都有可靠的
解析器, 而 base64/URI 只能靠特征猜。

用法:
    to_sb.py <输入文件>  --prefix <前缀>
    to_sb.py <输入文件>  --prefix <前缀> --format json|text
输出是 sing-box 的 {"outbounds":[...]}。

设计约束:
  - 只用标准库 + PyYAML (可选)。PyYAML 缺失时降级成一个只认
    "key: value" 的极简 YAML 解析器 —— 用户贴的片段本来就是平铺的,
    足够用。
  - 不联网, 不写文件。识别不了的直接跳过并计数, 绝不猜。
  - **不静默降级**（2026-10 修）: 传输写不出来（xhttp / mkcp / httpupgrade / 未知名）
    就明确拒绝并说明, 绝不"不认识就当成 tcp"; 只要写出 tls 段就一定带
    enabled: true; ECH 写不成内核要的 PEM 就**声明不可用**, 绝不塞个内核会 FATAL
    的值。能力判定仍然只由 compat 出（见 _keep 的两道闸门）。
"""
import base64
import json
import os
import re
import sys
import urllib.parse as up

# --------------------------------------------------------------------------
# PyYAML 可选
# --------------------------------------------------------------------------
try:
    import yaml  # noqa
    HAVE_YAML = True
except Exception:
    HAVE_YAML = False


def parse_yaml_min(text):
    """没有 PyYAML 时的极简兜底: 只支持平铺的 "key: value" 和 "- key: value"。

    用户手贴的 mihomo 片段就是这个形状:
        - name: "Browser-Dialer"
          type: socks5
          server: 10.0.0.5
          port: 1080
          udp: true
    不支持嵌套/多行/锚点 —— 遇到就当没这条, 让上层报告"识别失败",
    总比解析出半吊子数据生成一份坏配置要强。
    """
    out, cur = [], None
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].rstrip() if not raw.strip().startswith("#") else ""
        if not line.strip():
            continue
        m = re.match(r"^\s*-\s*(\w[\w-]*)\s*:\s*(.*)$", line)
        if m:
            cur = {}
            out.append(cur)
            _kv(cur, m.group(1), m.group(2))
            continue
        m = re.match(r"^\s+(\w[\w-]*)\s*:\s*(.*)$", line)
        if m and cur is not None:
            _kv(cur, m.group(1), m.group(2))
    return out


def _kv(d, k, v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    d[k] = v


def load_yaml(text):
    if HAVE_YAML:
        return yaml.safe_load(text)
    return parse_yaml_min(text)


# --------------------------------------------------------------------------
# 字段映射
# --------------------------------------------------------------------------
# mihomo/clash 的 type -> sing-box 的 outbound type。值是 (singbox_type, 需要哪些字段)
CLASH_TYPE = {
    "socks5": "socks",
    "socks": "socks",
    "http": "http",
    "ss": "shadowsocks",
    "ssr": "shadowsocksr",
    "vmess": "vmess",
    "vless": "vless",
    "trojan": "trojan",
    "hysteria2": "hysteria2",
    "hy2": "hysteria2",
    "tuic": "tuic",
    "anytls": "anytls",
    "snell": "snell",
    "wireguard": "wireguard",
}

# mihomo 字段名和 sing-box 不一致的, 在这里翻。
# 左边是 mihomo/clash 的键, 右边是 (目标键, 取值函数)
CLASH_RENAME = {
    "servername": "server_name",
    "sni": "server_name",
    "skip-cert-verify": "insecure",
    "allowInsecure": "insecure",
    "alpn": "alpn",
    "client-fingerprint": "utls",
    "fingerprint": "utls",
    "reality-opts": "reality",
    "public-key": "public_key",
    "short-id": "short_id",
}


def _to_bool(v):
    if isinstance(v, bool):
        return v
    return str(v).strip().lower() in ("1", "true", "yes", "on")


def _as_list(v):
    if v is None:
        return []
    if isinstance(v, list):
        return v
    return [x.strip() for x in str(v).split(",") if x.strip()]


# --------------------------------------------------------------------------
# 转换器的"表达能力"（**不是**内核能力 —— 内核能力只由 compat 出结论）
# --------------------------------------------------------------------------
# 显式 tcp/raw/空: 不写 transport 段就是内核默认 tcp, 语义完全一致。
_TCP_NET = ("", "tcp", "raw", "none")
# to_sb 只会**忠实写出**这几个传输（ws / grpc / h2-http, 字段映射在本文件里写全、
# 且实测内核接受这种写法）。别的传输一律进闸门: 要么 compat 判内核不可用（xhttp /
# mkcp）, 要么明确拒绝 —— 绝不再"不认识就当成 tcp"（内核不报错, 节点却永远连不上;
# 本仓库的老毛病, 见 _keep 的两道闸门）。
# 内部标记: 只在本文件里流转, 进配置前一定被 _keep 取走（main() 另有一道兜底剥离）。
_TR_KEY = "_sb_unwritable_transport"     # 链接里的传输 to_sb 写不出 -> 传输名
_ECH_KEY = "_sb_ech_not_carried"         # 链接里有 ECH, 但写不成 sing-box 的 PEM 形态

_ECH_PEM_BEGIN = "-----BEGIN ECH CONFIGS-----"


def _is_ech_pem(v):
    """sing-box 的 tls.ech.config 只认 PEM（-----BEGIN ECH CONFIGS-----）。

    实测（sing-box 1.14.2 linux/amd64）: 喂 base64 →
    `FATAL initialize outbound[0]: invalid ECH configs pem`, **整份配置作废**。
    所以这里只放行 PEM 原文; 别的形态一律"不写 + 标不可用", 绝不猜。
    """
    return isinstance(v, str) and _ECH_PEM_BEGIN in v


def _raw_query_param(q, key):
    """从**原始** query 串里取参数值。

    不能用 parse_qs/parse_qsl: 它们按 form-encoding 把 '+' 解成空格, 而
    `ech=` / base64 这类取值里 '+' 是字面量（compat 的 uri.py 出于同一原因自己
    写了解析器）。这里只为 ECH 取值服务, 语义与 compat 对齐。
    """
    for chunk in (q or "").split("&"):
        if not chunk:
            continue
        k, _, v = chunk.partition("=")
        if up.unquote(k) == key:
            return up.unquote(v)
    return ""


def _ech_ref(kind, query=None, raw=None):
    """给报告与判定用的"这条链接的 ECH 长什么样"。"""
    return {"kind": kind, "query": query or "", "raw": (raw or "")[:80]}


def _ech_loss_note(ref):
    """ECH 没写进配置时的**显式**声明（绝不静默丢能力）。"""
    ref = ref or {}
    q = ref.get("query") or ""
    raw = ref.get("raw") or ""
    what = ("分享里的 ECH（%s%s）写不成 sing-box 的 tls.ech.config —— 内核只认 PEM"
            "（-----BEGIN ECH CONFIGS-----）, 给的是 %s; 转换器不联网、不能现场取 "
            "ECHConfig, 也绝不写 base64（实测喂 base64 = FATAL invalid ECH configs "
            "pem, 整份配置作废）。**这条节点的 ECH 没有启用**; 若它必须靠 ECH 才能"
            "连通, 表现就是连不上。"
            % (ref.get("kind") or "ECH", ("/" + q) if q else "",
               raw if raw else "运行时查 DNS(HTTPS/SVCB) 的形态"))
    return {"feature": "standard:ech", "source": "to_sb", "what": what}


def _unwritable_reason(name, r):
    """转换器写不出这个传输 → 明确拒绝（并说清这不是"内核不支持"的判定）。"""
    v = (r or {}).get("verdict") or "（compat 未接入）"
    msgs = (r or {}).get("message") or []
    extra = ("; compat: " + msgs[0][:160]) if msgs else ""
    return ("本转换器不会写 transport '%s'（compat 判定=%s%s）—— 明确拒绝, 不静默"
            "降级成 tcp（内核侧不会报错, 只会永远连不上）" % (name, v, extra))


# --------------------------------------------------------------------------
# 传输层
# --------------------------------------------------------------------------
def transport_from_clash(d):
    """mihomo 的 network/ws-opts/grpc-opts/h2-opts -> (transport, 写不出的传输名)。

    ★ 三种返回, 语义必须分清（历史缺陷就是在这里"不认识 → 当成 tcp"）:
        (dict, None)  能忠实写出
        (None, None)  显式 tcp/raw/空 —— 内核默认就是 tcp, 语义一致, 不写 transport 段
        (None, name)  写不出（xhttp / mkcp / httpupgrade / 任何没见过的名字）
    """
    net = (d.get("network") or "").strip().lower()
    if net in _TCP_NET:
        return None, None
    t = {}
    if net in ("ws", "websocket"):
        ws = d.get("ws-opts") or {}
        # mihomo **没有** network: httpupgrade —— 它把 httpupgrade 写成
        # `network: ws` + `ws-opts.v2ray-http-upgrade: true`（本仓库 to_mihomo.py 也这么发）。
        # 只按 ws 读 = 把 httpupgrade 静默换成 ws, 同样是"看着对、连不上"。
        if _to_bool(ws.get("v2ray-http-upgrade")) or _to_bool(d.get("v2ray-http-upgrade")) \
                or _to_bool(d.get("http-upgrade")):
            return None, "httpupgrade"
        path = ws.get("path") or d.get("ws-path") or "/"
        hdrs = (ws.get("headers") or {})
        host = hdrs.get("Host") or d.get("ws-headers", {}).get("Host")
        t["type"] = "ws"
        t["path"] = path or "/"
        if host:
            t["headers"] = {"Host": host}
    elif net == "grpc":
        g = d.get("grpc-opts") or {}
        t["type"] = "grpc"
        t["service_name"] = g.get("grpc-service-name") or d.get("serviceName") or ""
    elif net == "h2":
        h2 = d.get("h2-opts") or {}
        t["type"] = "http"
        paths = h2.get("path")
        t["path"] = paths if isinstance(paths, str) else (paths or "/")
        host = h2.get("host")
        if isinstance(host, list):
            host = host[0] if host else None
        if host:
            t["host"] = [host]
    else:
        return None, net
    return t, None


# --------------------------------------------------------------------------
# 单个 mihomo proxy -> sing-box outbound
# --------------------------------------------------------------------------
def clash_to_outbound(d, prefix=""):
    if not isinstance(d, dict):
        return None
    ctype = (d.get("type") or "").strip().lower()
    sbtype = CLASH_TYPE.get(ctype)
    if not sbtype:
        return None
    name = str(d.get("name") or d.get("server") or sbtype)
    ob = {"type": sbtype, "tag": (prefix + name) if prefix else name,
          "server": d.get("server"), "server_port": int(d.get("port") or 0)}
    if not ob["server"] or not ob["server_port"]:
        return None

    # 认证 (socks / http 支持)
    if d.get("username"):
        ob["username"] = str(d["username"])
    if d.get("password"):
        ob["password"] = str(d["password"])

    # TLS
    tls_on = _to_bool(d.get("tls")) or ctype in ("trojan", "hysteria2", "hy2", "tuic", "anytls")
    tls = {}
    if tls_on:
        # ★ 只要写出 tls 段, 就必须显式带 enabled: true。
        #   sing-box 的 TLS 选项默认关; 缺了它:
        #     * anytls / tuic / hy2 → 整份配置 FATAL `initialize outbound[0]: TLS required`
        #       （内核连 check 都过不去, 一条就废掉整批节点）
        #     * vless / trojan     → tls 段被**无声忽略**, 明文去连, 永远 502/超时
        #   实测 M 分享 18 个节点真连 0/18, 精确归因就是这一行。
        tls["enabled"] = True
        if d.get("sni") or d.get("servername"):
            tls["server_name"] = d["servername"] if d.get("servername") else d["sni"]
        elif d.get("server"):
            tls["server_name"] = d["server"]
        if _to_bool(d.get("skip-cert-verify")):
            tls["insecure"] = True
        if d.get("alpn"):
            tls["alpn"] = _as_list(d["alpn"])
        fp = d.get("client-fingerprint") or d.get("fingerprint")
        if fp and fp not in ("random", ""):
            tls["utls"] = {"enabled": True, "fingerprint": fp}
        ro = d.get("reality-opts") or {}
        if ro:
            r = {"enabled": True}
            if ro.get("public-key"):
                r["public_key"] = ro["public-key"]
            if ro.get("short-id"):
                r["short_id"] = ro["short-id"]
            tls["reality"] = r

    # ECH（mihomo 的 ech-opts）: 语义是"运行时按域名去查 DNS(HTTPS/SVCB 记录)拿
    # ECHConfig"。sing-box 的 tls.ech.config 只吃**静态 PEM** —— 转换器不联网, 取不到;
    # 也绝不把域名/base64 塞进去（内核 FATAL, 整份配置作废）。
    eo = d.get("ech-opts")
    if isinstance(eo, dict) and _to_bool(eo.get("enable")):
        ecfg = eo.get("config") or eo.get("config-path")
        if tls_on and _is_ech_pem(ecfg):
            tls["ech"] = {"enabled": True, "config": str(ecfg)}
        else:
            ob[_ECH_KEY] = _ech_ref("mihomo ech-opts",
                                    query=eo.get("query-server-name"))

    if tls:
        ob["tls"] = tls

    tr, refused_net = transport_from_clash(d)
    if tr:
        ob["transport"] = tr
    if refused_net:
        # 写不出的传输: 绝不静默当 tcp, 交给 _keep 的转换闸门明确处理。
        ob[_TR_KEY] = refused_net

    # 各协议自己的必填字段
    if sbtype in ("shadowsocks", "shadowsocksr"):
        ob["method"] = d.get("cipher") or d.get("method") or "aes-128-gcm"
        ob["password"] = str(d.get("password") or "")
    elif sbtype == "vmess":
        ob["uuid"] = str(d.get("uuid") or "")
        ob["security"] = d.get("cipher") or "auto"
        ob["alter_id"] = int(d.get("alterId") or 0)
    elif sbtype == "vless":
        ob["uuid"] = str(d.get("uuid") or "")
        fl = (d.get("flow") or "").strip()
        if fl:
            ob["flow"] = fl
    elif sbtype == "hysteria2":
        ob["password"] = str(d.get("password") or "")
        up_mb = d.get("up") or d.get("upmbps")
        if up_mb:
            ob["up_mbps"] = int(up_mb)
        ob["obfs"] = {"type": "salamander", "password": d.get("obfs-password") or ""} \
            if d.get("obfs-password") else None
        if ob.get("obfs") is None:
            ob.pop("obfs", None)
    elif sbtype == "tuic":
        ob["uuid"] = str(d.get("uuid") or "")
        ob["password"] = str(d.get("password") or "")
        ob["congestion_control"] = d.get("congestion-controller") or "bbr"
    elif sbtype == "snell":
        ob["password"] = str(d.get("password") or "")
        ob["version"] = str(d.get("version") or "4")
    elif sbtype == "wireguard":
        ob["private_key"] = d.get("private-key") or d.get("privateKey") or ""
        ob["peer_public_key"] = d.get("public-key") or d.get("publicKey") or ""
        ob["local_address"] = _as_list(d.get("ip") or d.get("local-address"))
        ob["mtu"] = int(d.get("mtu") or 1408)

    if sbtype == "anytls":
        ob["password"] = str(d.get("password") or "")

    return ob


# --------------------------------------------------------------------------
# share URI
# --------------------------------------------------------------------------
def uri_to_outbound(line, prefix=""):
    s = line.strip()
    if "://" not in s:
        return None
    scheme = s.split("://", 1)[0].lower()
    rest = s.split("://", 1)[1]

    frag = ""
    if "#" in rest:
        rest, frag = rest.rsplit("#", 1)
    frag = up.unquote(frag)

    if scheme == "vmess":
        return _vmess_uri(rest, frag, prefix)
    if scheme in ("vless", "trojan", "ss", "socks", "http", "hysteria2", "hy2", "tuic"):
        return _std_uri(scheme, rest, frag, prefix)
    return None


def _decode_vmess_payload(rest):
    """vmess:// 是 base64 的整段 JSON (老格式)。"""
    try:
        raw = base64.b64decode(rest + "=" * (-len(rest) % 4))
        return json.loads(raw.decode("utf-8", "replace"))
    except Exception:
        return None


def _vmess_uri(rest, frag, prefix):
    d = _decode_vmess_payload(rest)
    if not isinstance(d, dict):
        return None
    # 名字: vmess:// 的 v2rayN 约定是放在 JSON 的 "ps" 里, base64 串后面
    # **不带** #片段 —— mihomo 会把 #片段一起塞进 base64 解码, 解不开就
    # 把整条订阅判成 0 节点。老链接 (含本面板 2026-10 以前发的) 把名字放在
    # #片段, 两种都认。
    name = str(d.get("ps") or "").strip() or frag
    ob = {"type": "vmess", "tag": (prefix + name) if prefix else name,
          "server": d.get("add"), "server_port": int(d.get("port") or 0),
          # 标准字段名是 "id"; 本面板 2026-10 之前发出去的链接写的是 "uuid"
          "uuid": d.get("id") or d.get("uuid") or "",
          "security": d.get("scy") or d.get("security") or "auto",
          "alter_id": int(d.get("aid") or 0)}
    if not ob["server"] or not ob["server_port"]:
        return None
    tls = {}
    tlsmode = str(d.get("tls", "")).lower()
    if tlsmode in ("tls", "true", "1", "reality"):
        # ★ tls 段写出来就必须带 enabled（理由同 clash 侧: 缺了它, vless/trojan 会被
        #   内核无声当明文连, 永远连不上）。
        tls["enabled"] = True
        tls["server_name"] = d.get("sni") or d.get("host") or ob["server"]
        if tlsmode == "reality":
            # vmess/trojan + REALITY 的链接: tls 段只"借"目标站点的握手, 真正的
            # 身份校验在 pbk/sid 上。原来这里只认 tls/true/1, 于是 REALITY 链接
            # 被当**明文** vmess 导入 —— 内核不报错, 节点却永远连不通。
            r = {"enabled": True}
            if d.get("pbk"):
                r["public_key"] = d["pbk"]
            if d.get("sid"):
                r["short_id"] = d["sid"]
            tls["reality"] = r
        if d.get("alpn"):
            tls["alpn"] = str(d["alpn"]).split(",")
        fp = d.get("fp")
        if fp and fp not in ("", "random"):
            tls["utls"] = {"enabled": True, "fingerprint": fp}
    ech = d.get("ech")
    if ech:
        if tls and _is_ech_pem(ech):
            tls["ech"] = {"enabled": True, "config": str(ech)}
        else:
            ob[_ECH_KEY] = _ech_ref("vmess JSON ech", raw=str(ech))
    if tls:
        ob["tls"] = tls
    net = (d.get("net") or "tcp").lower()
    if net in ("ws", "websocket"):
        ob["transport"] = {"type": "ws", "path": d.get("path") or "/",
                           "headers": {"Host": d.get("host") or ob["server"]}}
    elif net == "grpc":
        ob["transport"] = {"type": "grpc", "service_name": d.get("path") or ""}
    elif net == "h2":
        ob["transport"] = {"type": "http", "path": d.get("path") or "/",
                           "host": [d.get("host") or ob["server"]]}
    elif net not in _TCP_NET:
        ob[_TR_KEY] = net
    return ob


def _std_uri(scheme, rest, frag, prefix):
    # 拆 user@host:port
    if "@" in rest:
        userinfo, hostpart = rest.rsplit("@", 1)
    else:
        userinfo, hostpart = "", rest
    q = ""
    if "?" in hostpart:
        hostpart, q = hostpart.split("?", 1)
    qd = {k: v[0] for k, v in up.parse_qs(q, keep_blank_values=True).items()}

    # host:port
    if hostpart.startswith("["):           # [v6]:port
        h, _, p = hostpart.rpartition("]:")
        host = h.lstrip("["); port = p
    elif ":" in hostpart:
        host, _, port = hostpart.rpartition(":")
    else:
        host, port = hostpart, ""
    try:
        port = int(port)
    except ValueError:
        port = 0
    if not host or not port:
        return None
    userinfo = up.unquote(userinfo)
    if ":" in userinfo:
        user, pwd = userinfo.split(":", 1)
    else:
        user, pwd = userinfo, ""

    sbtype = CLASH_TYPE.get(scheme, scheme)
    ob = {"type": sbtype, "tag": (prefix + frag) if prefix else frag,
          "server": host, "server_port": port}

    sec = (qd.get("security") or "").lower()
    net = (qd.get("type") or qd.get("network") or "").lower()

    if scheme in ("socks", "http"):
        if user:
            ob["username"] = user
        if pwd:
            ob["password"] = pwd
        return ob

    if scheme == "ss":
        # ss://base64(method:pass)@host:port  或  ss://method:pass@host:port
        if ":" not in user:
            try:
                user = base64.b64decode(user + "=" * (-len(user) % 4)).decode("utf-8", "replace")
            except Exception:
                pass
        if ":" in user:
            m, _, pw = user.partition(":")
            ob["method"], ob["password"] = m, pw
        else:
            ob["method"], ob["password"] = "aes-128-gcm", user
        return ob

    if scheme == "vless":
        ob["uuid"] = user
        if qd.get("flow"):
            ob["flow"] = qd["flow"]
    elif scheme == "trojan":
        ob["password"] = user
    elif scheme in ("hysteria2", "hy2"):
        ob["password"] = user
        # 只在**真有密码**时才写 obfs。别人家的链接可能带
        # `obfs=none&obfs-password=` (M / 老版 X 都这么发过):
        #   * 写进 obfs 会得到一个内核 check 不过的 outbound -> 整份客户端配置
        #     失效, 一条坏链接拖掉全部节点;
        #   * mihomo 更直接: "missing obfs password" -> 整条订阅 0 节点。
        # 不写 obfs 就是"无混淆", 语义与 obfs=none 完全一致。
        if qd.get("obfs") == "salamander" and qd.get("obfs-password"):
            ob["obfs"] = {"type": "salamander", "password": qd["obfs-password"]}
        if qd.get("mport"):
            ob["server_ports"] = [int(x) for x in qd["mport"].split(",") if x.strip().isdigit()]
            ob.pop("server_port", None)
        if qd.get("upmbps"):
            ob["up_mbps"] = int(qd["upmbps"])
    elif scheme == "tuic":
        ob["uuid"], ob["password"] = user, pwd
        ob["congestion_control"] = "bbr"
    elif scheme == "anytls":
        ob["password"] = user

    # TLS / Reality
    tls = {}
    if sec in ("tls", "reality", "xtls"):
        tls["enabled"] = True
        sni = qd.get("sni") or qd.get("host") or qd.get("peer") or host
        tls["server_name"] = sni
        if sec == "reality":
            r = {"enabled": True}
            if qd.get("pbk"):
                r["public_key"] = qd["pbk"]
            if qd.get("sid"):
                r["short_id"] = qd["sid"]
            tls["reality"] = r
        if qd.get("allowInsecure", "").lower() in ("1", "true") or qd.get("insecure", "").lower() in ("1", "true"):
            tls["insecure"] = True
        if qd.get("alpn"):
            tls["alpn"] = qd["alpn"].split(",")
        if qd.get("fp") and qd["fp"] not in ("", "random"):
            tls["utls"] = {"enabled": True, "fingerprint": qd["fp"]}
    elif scheme in ("hysteria2", "hy2", "tuic", "anytls"):
        tls = {"enabled": True, "server_name": qd.get("sni") or qd.get("peer") or host}
        if qd.get("insecure", "").lower() in ("1", "true"):
            tls["insecure"] = True
    # ECH: sing-box 只认 PEM。X 侧链接写的是 "域名+DoH"（运行时去查该域名的
    # HTTPS/SVCB 记录拿 ECHConfig）, mihomo 是 ech-opts（同一种 DNS 形态）。
    # 转换器不联网 → 取不到; 也绝不把域名/base64 写进 tls.ech.config
    # （内核 FATAL: invalid ECH configs pem, 整份配置作废）。
    ech_raw = _raw_query_param(q, "ech") or _raw_query_param(q, "pcs") \
        or _raw_query_param(q, "vcn")
    if ech_raw:
        if tls and _is_ech_pem(ech_raw):
            tls["ech"] = {"enabled": True, "config": ech_raw}
        else:
            ob[_ECH_KEY] = _ech_ref("链接 ech 参数", raw=ech_raw)
    if tls:
        ob["tls"] = tls

    # 传输
    if net in ("ws", "websocket"):
        tr = {"type": "ws", "path": up.unquote(qd.get("path", "/")) or "/"}
        if qd.get("host"):
            tr["headers"] = {"Host": qd["host"]}
        elif qd.get("sni"):
            tr["headers"] = {"Host": qd["sni"]}
        ob["transport"] = tr
    elif net == "grpc":
        ob["transport"] = {"type": "grpc",
                           "service_name": up.unquote(qd.get("serviceName") or qd.get("path") or "")}
    elif net in ("h2", "http"):
        ob["transport"] = {"type": "http",
                           "path": up.unquote(qd.get("path") or "/"),
                           "host": [qd.get("host") or qd.get("sni") or host]}
    elif net not in _TCP_NET:
        # xhttp / mkcp / httpupgrade / 任何没见过的传输: 绝不静默当 tcp。
        ob[_TR_KEY] = net
    return ob


# --------------------------------------------------------------------------
# compat 接入（proxy-node-compat 适配层 = compat2.py, 与本文件同目录）
#
# 分工: 这里**不判**任何能力, 只把"这个节点是什么"（原文链接 / 出站 dict）交给
# compat2, 由它调 check_node 判一次, 然后消费结论。判定只在 compat 发生一次。
#
# 三条纪律:
#   * compat 只能收紧: 它说 UNSUPPORTED 才丢节点; 其余一律保留（旧行为不变）
#   * 回滚: SB_COMPAT_ENGINE=legacy 或 SB_COMPAT_DISABLE=1 → 完全回到旧路径
#   * compat2 缺失/异常 → 自动落回旧路径, 绝不让导入失败
# --------------------------------------------------------------------------
_COMPAT = None


def _compat_mod():
    global _COMPAT
    if _COMPAT is None:
        try:
            here = os.path.dirname(os.path.abspath(__file__))
            if here not in sys.path:
                sys.path.insert(0, here)
            import compat2                                  # noqa: WPS433
            _COMPAT = compat2
        except Exception:                                   # noqa: BLE001
            _COMPAT = False
    return _COMPAT or None


def compat_enabled():
    return (_compat_mod() is not None
            and os.environ.get("SB_COMPAT_ENGINE", "").strip().lower() != "legacy"
            and os.environ.get("SB_COMPAT_DISABLE", "") != "1")


def _compat_gate(rep, uri, ob, tag, declare=None):
    """判一个节点 → 记录到 rep["compat"]; 返回 (结果 dict, 报告里那条记录)。

    未接入 compat / compat 异常 → (None, None)（自动落回旧路径）。

    declare: 转换器自己产生的"损失声明"（如 ECH 写不成 PEM）。它是**声明**, 不是
    判定 —— 判定仍然只由 compat 出; 这里只把它挂到同一个节点记录上, 让 client.sh
    的摘要和报告都能看见（绝不静默丢能力）。
    """
    mod = _compat_mod() if compat_enabled() else None
    if mod is None:
        return None, None
    try:
        r = mod.judge(uri=uri, outbound=ob, tag=tag or (ob or {}).get("tag"))
    except Exception as e:                                  # noqa: BLE001
        rep.setdefault("compat", {}).setdefault("errors", []).append(
            "%s: %s" % (type(e).__name__, e))
        return None, None
    declare = [d for d in (declare or [])
               if d.get("feature") not in
               {(c or {}).get("feature") for c in (r.get("client_losses") or [])}]
    for d in declare:
        r["client_losses"] = list(r.get("client_losses") or []) + [d]
        r["message"] = list(r.get("message") or []) + [d["what"]]
    slot = rep.setdefault("compat", {})
    slot.setdefault("target", r.get("target"))
    rec = {
        "tag": r.get("tag"), "type": (ob or {}).get("type"),
        "verdict": r["verdict"], "verdict_source": r["verdict_source"],
        "ok": r["ok"], "reason_codes": r["reason_codes"], "message": r["message"],
        "raw_uri": r.get("raw_uri"), "extensions": r.get("extensions"),
        "unknowns": r.get("unknowns"), "client_losses": r.get("client_losses"),
        "downgrades": r.get("downgrades"),
        "losses": (r.get("compat") or {}).get("losses"),
        "warnings": r.get("warnings"),
        "legacy": r.get("legacy"),
    }
    slot.setdefault("nodes", []).append(rec)
    return r, rec


def _compat_reason(r):
    """跳过原因: 用 compat 的第一条文案（由 reason_code 生成, 已经说了缺什么/支持什么）"""
    msgs = r.get("message") or []
    m = msgs[0] if msgs else "compat 判定不支持"
    rc = ",".join(r.get("reason_codes") or [])
    return "compat[%s] %s" % (rc or "?", m[:180])


# --------------------------------------------------------------------------
# 输入分类
# --------------------------------------------------------------------------
URI_RE = re.compile(r"^(vmess|vless|trojan|ss|socks5?|http|hysteria2|hy2|tuic|anytls)://", re.I)


def looks_base64_sub(text):
    """整份是 base64 且解开后有明显的 share URI。"""
    t = text.strip()
    if not t or "\n" in t:
        return False
    if URI_RE.match(t):
        return False
    if not re.fullmatch(r"[A-Za-z0-9+/=\s]+", t):
        return False
    try:
        dec = base64.b64decode(t + "=" * (-len(t) % 4)).decode("utf-8", "replace")
    except Exception:
        return False
    return bool(URI_RE.search(dec))


def convert(data, prefix=""):
    """返回 (outbounds, 报告 dict)。"""
    rep = {"total": 0, "ok": 0, "skip": 0, "reasons": {}}

    def _note(r):
        rep["skip"] += 1
        rep["reasons"][r] = rep["reasons"].get(r, 0) + 1

    def _keep(ob, uri=None, tag=None):
        """闸门。返回 True = 这条出站可以进配置。

        两道闸门, 顺序固定:

          ① **转换闸门**（本转换器写不写得出 —— 不是内核能力）
            链接里的传输 / ECH, to_sb 写不出就**明确拒绝**, 绝不静默降级成 tcp、
             也绝不静默丢 ECH。标记由 uri_to_outbound / clash_to_outbound 挂在
             出站 dict 上（_TR_KEY / _ECH_KEY）, 这里第一件事就是取走 ——
             保证内部键绝不会落进配置文件。
             为什么必须写不出就拒: 静默成 tcp 的出站内核不报错, 只是永远连不上
             （M 分享的 xhttp 节点就是这样被"导入成功"的）。
          ② **compat 闸门**（内核能不能用）—— 判定与文案全部出自 compat;
             它说 UNSUPPORTED 才丢节点。

        ①的判定也要 compat 的结论来兜底/说明: 把链接里**真实的**传输 / ECH
        写进一份"只为判定"的副本交给 compat（它绝不进配置）。
        """
        tr_ref = ob.pop(_TR_KEY, None)
        ech_ref = ob.pop(_ECH_KEY, None)
        judge_ob = ob
        declare = []
        if (tr_ref or ech_ref) and not uri:
            # 没有原文链接时（mihomo YAML 片段 / 手贴 JSON）, compat 只能看出站 ——
            # 那就把"链接里真实的传输 / ECH"写进一份**只为判定**的副本, 让它有的判。
            # 有原文链接时**不这么做**: 原文才是权威, 而且必须保住 compat 自己那条
            # "客户端转换环节丢了 X" 的对比（不能让它以为转换器把 X 写出来了）。
            judge_ob = dict(ob)
            if tr_ref:
                judge_ob["transport"] = {"type": tr_ref}
            if ech_ref:
                t = dict(judge_ob.get("tls") or {})
                t["enabled"] = True
                t["ech"] = {"enabled": True,
                            "query_server_name": ech_ref.get("query") or ""}
                judge_ob["tls"] = t
                declare.append(_ech_loss_note(ech_ref))
        r, rec = _compat_gate(rep, uri, judge_ob, tag, declare=declare)
        if r is not None and not r["ok"]:
            _note(_compat_reason(r))
            return False
        if tr_ref:
            why = _unwritable_reason(tr_ref, r)
            _note(why)
            if rec is not None:
                # 报告必须与最终结果一致: compat 没判死, 是**转换闸门**拒的 ——
                # 记录成"跳过 + 原因", 否则摘要里会显示成"留着但有损失"。
                rec["ok"] = False
                rec["dropped_by"] = "to_sb.transport"
                rec["message"] = list(rec.get("message") or []) + [why]
            return False
        if declare:
            rep.setdefault("conversion_losses", []).extend(declare)
        return True

    text = data.decode("utf-8", "replace") if isinstance(data, bytes) else data

    # 1) sing-box JSON
    try:
        j = json.loads(text)
        if isinstance(j, dict) and isinstance(j.get("outbounds"), list):
            obs = [o for o in j["outbounds"] if isinstance(o, dict)
                   and o.get("type") not in ("selector", "urltest", "direct", "block", "dns")]
            rep["format"] = "sing-box-json"
            rep["total"] = len(obs)
            keep = []
            for o in obs:
                if prefix and o.get("tag"):
                    o["tag"] = prefix + o["tag"]
                if _keep(o, tag=o.get("tag")):
                    keep.append(o)
            rep["ok"] = len(keep)
            return keep, rep
        if isinstance(j, list):
            rep["format"] = "mihomo-json"
            return _from_clash_list(j, prefix, rep, _keep)
    except Exception:
        pass

    # 2) YAML (mihomo 片段 / 整份)
    if re.search(r"^\s*(-\s+)?(name|proxies|proxy-groups)\s*:", text, re.M):
        try:
            y = load_yaml(text)
        except Exception:
            y = None
        if isinstance(y, dict):
            lst = y.get("proxies") or []
            rep["format"] = "mihomo-yaml"
            return _from_clash_list(lst, prefix, rep, _keep)
        if isinstance(y, list):
            rep["format"] = "mihomo-yaml-list"
            return _from_clash_list(y, prefix, rep, _keep)

    # 3) base64 订阅
    if looks_base64_sub(text):
        try:
            text = base64.b64decode(text.strip() + "=" * (-len(text.strip()) % 4)).decode("utf-8", "replace")
        except Exception:
            pass

    # 4) 明文 share URI, 一行一个
    lines = [l for l in text.splitlines() if l.strip()]
    if lines and sum(1 for l in lines if URI_RE.match(l.strip())) >= max(1, len(lines) // 2):
        rep["format"] = "share-uri"
        obs = []
        for l in lines:
            l = l.strip()
            if not l or not URI_RE.match(l):
                continue
            rep["total"] += 1
            try:
                o = uri_to_outbound(l, prefix)
            except Exception as e:
                o = None
                _note("解析异常: %s" % type(e).__name__)
            if not o:
                _note("不支持的 URI: %s" % l.split("://", 1)[0])
                continue
            # 原文链接一并交给 compat: 它是"节点是什么"的唯一可信来源
            # （to_sb 遇到没写的传输是静默降级, 只看出站看不出问题）
            if not _keep(o, uri=l, tag=o.get("tag")):
                continue
            obs.append(o)
            rep["ok"] += 1
        return obs, rep

    rep["format"] = "未知"
    return [], rep


def _skip_note(rep, msg):
    """记一条"跳过 + 原因"。

    ★ 必须是**模块级**函数: `_note` 是 convert() 内部的闭包, 模块级函数里根本
      调不到它。原来 `_from_clash_list` 直接调 `_note` —— 于是**任何一条**不能
      转换的代理 (不认识的 type / 值非法触发异常) 都会抛 NameError, 把整批
      转换炸掉: 实测 M 分享的 19 节点订阅喂进来 -> 0 导入; 把唯一那条脏值
      剔掉之后 18/18 通过。这就是"一条坏条目毁掉整批"。
    纪律: 单条异常只跳过那一条并记录原因, 绝不影响同批其它节点。
    """
    rep["skip"] = rep.get("skip", 0) + 1
    reasons = rep.setdefault("reasons", {})
    reasons[msg] = reasons.get(msg, 0) + 1


def _from_clash_list(lst, prefix, rep, _keep=None):
    rep["total"] = len(lst)
    obs = []
    for d in lst:
        try:
            o = clash_to_outbound(d, prefix)
        except Exception:
            o = None
        if not o:
            _skip_note(rep, "不支持的 clash type: %s" % (d.get("type") if isinstance(d, dict) else "?"))
            continue
        # mihomo 的 proxies 里没有分享原文（除了 yaml 片段本身）, 所以只能用出站判;
        # 原始片段由 compat 的 raw_fields 保真（不变式 I1）。
        if _keep is not None and not _keep(o, tag=o.get("tag")):
            continue
        obs.append(o)
        rep["ok"] += 1
    return obs, rep


def main():
    args = sys.argv[1:]
    if not args:
        print("用法: to_sb.py <输入文件> [--prefix P] [--compat-report R]", file=sys.stderr)
        return 2
    path = args[0]
    prefix = ""
    if "--prefix" in args:
        prefix = args[args.index("--prefix") + 1] + "-"
    elif "--prefix" in args[:-1]:
        prefix = ""
    report = ""
    if "--compat-report" in args:
        report = args[args.index("--compat-report") + 1]
    try:
        data = open(path, "rb").read()
    except OSError as e:
        print("读不到 %s: %s" % (path, e), file=sys.stderr)
        return 1
    obs, rep = convert(data, prefix)
    # 兜底: 内部标记（_sb_*）绝不会进配置 —— 内核 DisallowUnknownFields/解码是严格的,
    # 一个内部键就能让整份配置作废。_keep 已经取走过它们, 这里再兜一道。
    obs = [{k: v for k, v in o.items() if not str(k).startswith("_sb_")} for o in obs]
    json.dump({"outbounds": obs}, sys.stdout, ensure_ascii=False, indent=1)
    sys.stderr.write("[to_sb] 格式=%s 共=%d 成功=%d 跳过=%d %s\n" % (
        rep.get("format"), rep["total"], rep["ok"], rep["skip"],
        ("跳过原因=" + json.dumps(rep["reasons"], ensure_ascii=False)) if rep["reasons"] else ""))
    if rep.get("conversion_losses"):
        sys.stderr.write("[to_sb] 转换损失 %d 条（能力没搬过去, 已保留节点并显式声明）: %s\n"
                         % (len(rep["conversion_losses"]),
                            "；".join(d["what"][:90] for d in rep["conversion_losses"][:3])))
    # compat 全量结果（losses / unknowns / extensions / raw_uri 都在里面）落盘一份,
    # 给 client.sh 打印与事后核对用 —— 节点文件里**绝不能**塞这些键, 内核会拒绝。
    if report:
        try:
            with open(report, "w", encoding="utf-8") as fh:
                json.dump(rep, fh, ensure_ascii=False, indent=1)
        except OSError as e:
            sys.stderr.write("[to_sb] compat 报告写不进去: %s\n" % e)
    return 0 if obs else 1


if __name__ == "__main__":
    sys.exit(main())