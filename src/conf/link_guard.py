#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""link_guard.py — 分享链接的**唯一**校验真源（发布前闸门 + 回归门禁共用）。

为什么要有这个文件
------------------
`tools/check_share_links.sh` 头部列出的 5 条规则，每一条的后果都是**整条订阅
归零**（不是单条节点失效）: mihomo / sing-box 遇到一条坏链接会把整个 provider
判成 0 节点, 好节点一起消失。这些规则原来只写在门禁脚本里 —— 也就是说
**只有跑门禁时才发现**, 而面板发布分享时并不检查。

三家互通的改造把 **URI 列表变成了主产品**（谁都能读的"普通话"）, 于是这些规则
从"回归断言"升级成"发布闸门": 一条坏链接不再只是"那个节点连不上", 而是
**整个订阅对所有非 SB 客户端归零**。所以规则抽到这里, 两边共用:

    conf/share.sh                 发布前: 有 problem 就**拒绝发布**
    tools/check_share_links.sh    回归:   有 problem 就 FAIL

规则（每条都有实测出处, 见 check_share_links.sh 头部）:
  1. hy2 不能带无效 obfs 参数; 真开 salamander 必须有非空密码
  2. hy2 / tuic 必须带 alpn
  3. vmess 必须是 vmess://base64(JSON), 有 ps 与 id, **不能带 #片段**
  4. sni 不能是 IP 字面量（真证书必然 x509 校验失败）
  5. vless 的 encryption 只能是 none —— 写成 aes-128-gcm 的 vless 链接是
     "vmess+REALITY 被误标成 vless://" 的指纹（mihomo: invaild vless encryption
     value → 整条订阅 0 节点）
  + product 模式额外查: 链接的 scheme 必须与该节点的 sing-box 出站类型一致
    （一条 vless:// 链接配一个 vmess 出站 = 客户端按错的协议拨号）

用法:
  link_guard.py check <链接文件|-> [--label 标签] [--json]
  link_guard.py product <原生 sb_client-<tag>.json> --link TAG=链接文件... [--json]
退出码: check/product 有 problem → 1（调用方据此拒绝发布 / 判 FAIL）;
        warnings 不影响退出码（它们是"要给用户看见"的既存差异, 不是新错误）。
"""

from __future__ import annotations

import argparse
import base64
import ipaddress
import json
import os
import sys
import urllib.parse as up

# sing-box 出站类型 → 该节点在 URI 里的 scheme。
# naive / shadowtls 是我们生态的写法（v2rayN / mihomo 对它各有各的读法）,
# 但"类型与 scheme 必须对应"这条对它们同样成立: 一条 shadowtls:// 链接配一个
# vmess 出站, 客户端必然按错的协议拨号。
TYPE_SCHEME = {
    "vless": ("vless",),
    "vmess": ("vmess",),
    "trojan": ("trojan",),
    "hysteria2": ("hysteria2", "hy2"),
    "tuic": ("tuic",),
    "anytls": ("anytls",),
    "shadowsocks": ("ss",),
    "naive": ("naive+https", "naive+quic", "naive"),
    "shadowtls": ("shadowtls",),
    "socks": ("socks", "socks5"),
    "http": ("http", "https"),
}
CONTROL_TYPES = ("selector", "urltest", "direct", "block", "dns")


def is_ip(s: str) -> bool:
    try:
        ipaddress.ip_address((s or "").strip("[]"))
        return True
    except ValueError:
        return False


def _split(line: str):
    """链接 → (scheme, body(不含片段), frag, query dict)。"""
    scheme = line.split("://", 1)[0].lower()
    body = line.split("://", 1)[1]
    frag = ""
    if "#" in body:
        body, frag = body.split("#", 1)
    query = {}
    if "?" in body:
        query = {k: v[0] for k, v in
                 up.parse_qs(body.split("?", 1)[1], keep_blank_values=True).items()}
    return scheme, body, frag, query


def check_line(line: str, where: str):
    """一条链接 → (problems, warnings)。规则与门禁逐字相同。"""
    problems, warnings = [], []
    if "://" not in line:
        return ["%s: 不是链接: %.60s" % (where, line)], []
    scheme, body, frag, query = _split(line)

    # ---- 1/2: hy2 obfs / alpn ----
    if scheme in ("hysteria2", "hy2"):
        o = (query.get("obfs") or "").strip().lower()
        if "obfs" in query and (o in ("", "none", "null", "off", "false", "0")):
            problems.append("%s: 带无效 obfs 参数 (obfs=%r) —— 对方会 missing obfs "
                            "password, 整条订阅 0 节点" % (where, query.get("obfs")))
        if o == "salamander" and not (query.get("obfs-password") or "").strip():
            problems.append("%s: obfs=salamander 但 obfs-password 为空" % where)
        if not query.get("alpn"):
            problems.append("%s: 缺 alpn (hy2 应带 alpn=h3)" % where)
        if not query.get("sni"):
            problems.append("%s: 缺 sni" % where)

    # ---- 5: tuic 必须带 alpn ----
    if scheme == "tuic" and not query.get("alpn"):
        problems.append("%s: 缺 alpn" % where)

    # ---- vless 的 encryption 只能是 none ----
    if scheme == "vless":
        enc = (query.get("encryption") or "none").strip().lower()
        if enc not in ("", "none"):
            problems.append("%s: vless 链接的 encryption=%r 非法 (VLESS 只允许 none; "
                            "vmess+REALITY 曾被误写成 vless://)" % (where, enc))

    # ---- 3: vmess 链接格式 ----
    if scheme == "vmess":
        if frag:
            problems.append("%s: vmess 链接带了 #片段 (mihomo 会把片段一起塞进 "
                            "base64 解码 -> format invalid -> 整条订阅 0 节点)" % where)
        d = None
        try:
            raw = base64.b64decode(body + "=" * (-len(body) % 4)).decode("utf-8", "replace")
            d = json.loads(raw)
        except Exception as e:                                       # noqa: BLE001
            problems.append("%s: base64 payload 解不开 (%s)" % (where, e))
        if isinstance(d, dict):
            if not (d.get("ps") or "").strip():
                problems.append("%s: JSON 缺 ps 字段 (mihomo 认不出这是 vmess 链接)" % where)
            if not (d.get("id") or d.get("uuid")):
                problems.append("%s: JSON 缺 id (标准字段名; uuid 只作兼容)" % where)
            sni = (d.get("sni") or "").strip()
            if sni and is_ip(sni):
                problems.append("%s: sni 是 IP (%s) —— 真证书必然校验失败" % (where, sni))
            if not str(d.get("port") or "").strip():
                warnings.append("%s: vmess payload 里没有 port (客户端可能报 url.Port() "
                                "is empty 并跳过这一条)" % where)

    # ---- 4: query 里的 sni 不能是 IP ----
    sni = (query.get("sni") or "").strip()
    if sni and is_ip(sni):
        problems.append("%s: sni 是 IP (%s) —— 对方 x509 校验必然失败" % (where, sni))
    return problems, warnings


def check_file(path: str, label: str):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = [l.strip() for l in fh if l.strip()]
    except OSError as e:
        return {"label": label, "checked": 0, "problems": ["读不到 %s (%s)" % (path, e)],
                "warnings": []}
    problems, warnings = [], []
    for i, line in enumerate(lines, 1):
        p, w = check_line(line, "第 %d 行 (%s)" % (i, line.split("://", 1)[0].lower()))
        problems += p
        warnings += w
    return {"label": label, "checked": len(lines), "problems": problems,
            "warnings": warnings}


def _uri_host_port(line: str):
    if "://" not in line:
        return None
    scheme, body, _frag, _q = _split(line)
    if scheme == "vmess":
        try:
            d = json.loads(base64.b64decode(body + "=" * (-len(body) % 4)))
        except Exception:                                            # noqa: BLE001
            return None
        if not isinstance(d, dict):
            return None
        try:
            return (str(d.get("add") or ""), int(d.get("port") or 0))
        except (TypeError, ValueError):
            return None
    head = body.split("?", 1)[0]
    at = head.rfind("@")
    if at < 0:
        return None
    hp = head[at + 1:].split("/", 1)[0]
    if hp.startswith("["):
        h, _, pp = hp[1:].partition("]")
        pp = pp.lstrip(":")
    else:
        h, _, pp = hp.rpartition(":")
        if not pp.isdigit():
            h, pp = hp, ""
    try:
        return (h, int(pp or 0))
    except ValueError:
        return None


def check_product(native_path: str, pairs):
    """原生出站 ↔ 链接 逐节点对账。pairs: [(tag, 链接文件)]"""
    with open(native_path, encoding="utf-8") as fh:
        doc = json.load(fh)
    obs = {o["tag"]: o for o in (doc.get("outbounds") or [])
           if isinstance(o, dict) and o.get("tag")}
    helpers = {o.get("detour") for o in obs.values() if o.get("detour")}
    problems, warnings, checked = [], [], 0
    pair_map = dict(pairs)
    for tag, path in pairs:
        ob = obs.get(tag)
        if ob is None:
            problems.append("%s: 原生产品里没有这个 tag" % tag)
            continue
        if ob.get("type") in CONTROL_TYPES or tag in helpers:
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                line = (fh.read().strip().splitlines() or [""])[0]
        except OSError as e:
            problems.append("%s: 读不到链接文件 %s (%s)" % (tag, path, e))
            continue
        if not line:
            problems.append("%s: 链接文件是空的 (%s)" % (tag, path))
            continue
        checked += 1
        p, w = check_line(line, tag)
        problems += p
        warnings += w
        scheme = line.split("://", 1)[0].lower()
        # detour 型节点（shadowtls 的两层结构: shadowsocks(tag) → shadowtls(tag-out)）
        # 的类型看**被引用的那个出站** —— 链接写的是 shadowtls://, 而外层出站类型
        # 是 shadowsocks; 拿外层判会得到一条假的"类型不符"。
        tgt = ob
        dep = ob.get("detour")
        if dep and dep in obs:
            tgt = obs[dep]
        want = TYPE_SCHEME.get((tgt.get("type") or "").lower())
        if want is None:
            warnings.append("%s: 出站类型 %r 没有登记对应的 URI scheme —— UNKNOWN, 不猜"
                            % (tag, ob.get("type")))
        elif scheme not in want:
            problems.append("%s: 链接 scheme=%s 与节点类型 %s 不符 (客户端会按错的协议拨号)"
                            % (tag, scheme, tgt.get("type")))
        uhp = _uri_host_port(line)
        nhp = (str(ob.get("server") or ""), int(ob.get("server_port") or 0))
        if uhp and uhp[0] and uhp != nhp and not ob.get("detour"):
            warnings.append("%s: 取件地址不一致 —— 原生=%s:%s / 链接=%s:%s "
                            "(陈旧产物: 两条产品把用户带到两个地方, 两边都不报错)"
                            % (tag, nhp[0], nhp[1], uhp[0], uhp[1]))
    for tag in pair_map:
        if tag not in obs:
            pass
    return {"native": os.path.basename(native_path), "checked": checked,
            "problems": problems, "warnings": warnings}


def main():
    ap = argparse.ArgumentParser(prog="link_guard.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("check")
    p.add_argument("file")
    p.add_argument("--label", default="")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("product")
    p.add_argument("native")
    p.add_argument("--link", action="append", default=[])
    p.add_argument("--json", action="store_true")
    a = ap.parse_args()

    if a.cmd == "check":
        label = a.label or os.path.basename(a.file)
        if a.file == "-":
            data = sys.stdin.read()
            import tempfile
            with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as fh:
                fh.write(data)
                tmp = fh.name
            r = check_file(tmp, label)
            os.unlink(tmp)
        else:
            r = check_file(a.file, label)
    else:
        pairs = []
        for kv in a.link:
            tag, _, path = kv.partition("=")
            pairs.append((tag, path))
        r = check_product(a.native, pairs)

    if a.json:
        print(json.dumps(r, ensure_ascii=False))
    else:
        for w in r["warnings"]:
            print("  [注意] %s: %s" % (r.get("label", r.get("native", "")), w))
        if not r["checked"]:
            print("  [--]   %s: 没有链接可查" % r.get("label", r.get("native", "")))
        elif not r["problems"]:
            print("  [OK]   %s: %d 条链接全部通过" % (r.get("label", r.get("native", "")),
                                                     r["checked"]))
        for pr in r["problems"]:
            print("  [FAIL] %s: %s" % (r.get("label", r.get("native", "")), pr))
    return 1 if r["problems"] else 0


if __name__ == "__main__":
    sys.exit(main())
