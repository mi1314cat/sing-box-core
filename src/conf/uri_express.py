#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""uri_express.py — "URI 这条产品装不下什么" 的显式标注（服务端, 发布前跑）。

为什么必须有这个文件
--------------------
SB 的服务端从"只发原生 sing-box JSON"变成"两条产品": 主产品 = **URI 列表**
(普通话, 谁都能读), 附带产品 = **原生 sing-box JSON**。URI 是唯一能跨生态的
格式, 但它**装不下**一些能力 —— 例如 `ss://` 物理上无法表达 reality、分享链接
规范里没有 mux 参数、ECH 在链接里只能带 ConfigList 而带不了查询域名。

本项目的历史毛病是"静默降级": 一条连不上的节点被当成功发出去。所以发布 URI
产品之前必须把损失**显式打出来**, 而不是假装没有。

真源不是本文件, 是 vendored 的 **URI 表达力注册表**
(`src/client/lib/proxy_node_compat/data/rules.json` 的 `uri_rules`, 文档
`proxy-node-compat/docs/uri-representation.md`)。本文件只做三件事:

  1. 把原生 outbound 映射成 compat 的 NodeProfile（`compat2.profile_from_sb_outbound`,
     与客户端 compat 判定**同一个映射**, 不另写一套）;
  2. 把 URI 行解析成 NodeProfile（`proxy_node_compat.uri.parse_uri`, 同上）;
  3. 逐节点查注册表:
       · 原生有、URI 没有的 feature  → 有 rule 的报损失; **没入册的报 UNKNOWN**
       · URI 有、但 rule 的 representation != FULL → 报"只能表达一部分"的损失
       · 带 `target_kernel` 的行（某内核的链接解析实现读不读）单独分叉报出
  一条也不许猜: 注册表里查不到的一律进 `unregistered` / `unknown_scheme`,
  报告里照原样写"UNKNOWN", 不折算成"没有损失"。

用法:
  uri_express.py report <原生 sb_client-<tag>.json> [--link TAG=链接文件]... [--json]
  uri_express.py report <原生.json> --links-dir <目录>        # 由 <tag> 推 sb_share-<tag>.txt
退出码: 0 = 打完了（**有损失也返回 0** —— 损失是标注不是错误）;
        2 = 用法/输入错误（调用方据此决定不发）。
"""

from __future__ import annotations

import argparse
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_CLIENT = os.path.join(os.path.dirname(_HERE), "client")
for _p in (_CLIENT, os.path.join(_CLIENT, "lib")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import compat2                                                       # noqa: E402
from proxy_node_compat.uri import parse_uri                          # noqa: E402

# 控制型出站不进客户端订阅（与 share.sh 的 gen_full_profile / client.sh 同一套判定）
CONTROL_TYPES = ("selector", "urltest", "direct", "block", "dns")

# 有据可依的**蕴含关系**（唯一一条）: REALITY 就是 TLS 的一种握手 —— 链接用
# `security=reality` 表达时, TLS 层由 reality 参数承载, 而注册表里
# uri.vless.reality / uri.trojan.reality 都是 representation=FULL（链接装得下）。
# 所以"原生有 standard:tls、URI 侧只有 standard:reality"不是损失。
# 这不是"别名表": 只此一条, 且指向注册表里已有的条目。
IMPLIED = {"standard:tls": ("standard:reality",)}


def uri_host_port(line: str):
    """URI 行 → (host, port)。解析不了返回 None（不猜）。

    vmess:// 的地址在 base64(JSON) 里 —— 文本替换/正则都碰不到, 必须解码。
    """
    s = (line or "").strip()
    if "://" not in s:
        return None
    scheme, rest = s.split("://", 1)
    rest = rest.split("#", 1)[0]
    if scheme.lower() == "vmess":
        body = rest.split("?", 1)[0]
        try:
            import base64
            obj = json.loads(base64.b64decode(body + "=" * (-len(body) % 4)))
        except Exception:                                            # noqa: BLE001
            return None
        if not isinstance(obj, dict):
            return None
        try:
            return (str(obj.get("add") or ""), int(obj.get("port") or 0))
        except (TypeError, ValueError):
            return None
    head = rest.split("?", 1)[0]
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


def scheme_of(uri_line: str) -> str:
    s = (uri_line or "").strip().split("://", 1)[0].strip().lower()
    return s


def loss_lines_for(scheme, feat, registry):
    """注册表 → [(rule_id, 字段, 说明)]; 带 target_kernel 的分叉单独标注。"""
    out = []
    for u in registry.uri_rules_for_scheme(scheme):
        if u.get("feature") != feat:
            continue
        if u.get("representation") == "FULL":
            continue
        rid = u.get("uri_rule_id", "")
        tk = u.get("target_kernel")
        for loss in (u.get("loss") or [{}]):
            what = loss.get("what") or "URI 无法表达"
            if tk:
                what = "（仅 %s 的链接解析实现）%s" % (tk, what)
            out.append((rid, loss.get("field", feat), what))
    return out


def report(native_path, pairs):
    """pairs: [(tag, 链接文件路径)] —— 顺序与原生 JSON 里的节点一致。"""
    with open(native_path, encoding="utf-8") as fh:
        doc = json.load(fh)
    obs = {}
    order = []
    for o in doc.get("outbounds") or []:
        if not isinstance(o, dict):
            continue
        if (o.get("type") or "") in CONTROL_TYPES:
            continue
        if o.get("tag") in obs:
            continue
        obs[o["tag"]] = o
        order.append(o["tag"])
    helpers = {o.get("detour") for o in (doc.get("outbounds") or [])
               if isinstance(o, dict) and o.get("detour")}

    reg = compat2.registry()
    res = {"native": os.path.basename(native_path), "nodes": 0,
           "checked": [], "losses": [], "implied": [], "unregistered": [],
           "unknown_scheme": [], "missing_uri": [], "extra_uri": [],
           "addr_mismatch": []}
    pair_map = dict(pairs)
    for tag in order:
        if tag in helpers:
            continue
        ob = obs[tag]
        path = pair_map.pop(tag, "")
        if not path or not os.path.isfile(path):
            res["missing_uri"].append(tag)
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            line = (fh.read().strip().splitlines() or [""])[0]
        if not line:
            res["missing_uri"].append(tag)
            continue
        res["nodes"] += 1
        scheme = scheme_of(line)
        up = None
        try:
            up = parse_uri(line)
            ufeat = set(up.feature_ids())
        except Exception as e:                                       # noqa: BLE001
            ufeat = set()
            res["unknown_scheme"].append(
                {"tag": tag, "scheme": scheme, "why": "URI 解析失败: %s" % e})
        if up is not None and any(
                d.get("code") == "UNKNOWN_SCHEME" for d in up.diagnostics):
            res["unknown_scheme"].append(
                {"tag": tag, "scheme": scheme,
                 "why": "注册表没有覆盖这个 scheme 的 URI 解析（表达力判不了）"})
        try:
            np = compat2.profile_from_sb_outbound(ob, raw_uri=line, tag=tag)
            nfeat = set(np.feature_ids())
        except Exception as e:                                       # noqa: BLE001
            res["unregistered"].append({"tag": tag, "feature": "?",
                                        "why": "原生出站映射失败: %s" % e})
            continue
        res["checked"].append({"tag": tag, "scheme": scheme,
                               "native_features": sorted(nfeat),
                               "uri_features": sorted(ufeat)})
        # 取件地址一致性: **同一个节点的两种表达必须指向同一个地方**。
        # 实证过的后果（RN 部署, 3 个 CDN 节点）: 原生 JSON 里是
        # `107.173.154.178:443`（连不通）, 链接里是 `hxicc.…:443`（Cloudflare,
        # 200）—— 两条产品把用户带到两个不同的地方, 而两边都不报错。
        # detour 型节点跳过: 它的 server/server_port 在被引用的那个出站里。
        if not ob.get("detour"):
            uhp = uri_host_port(line)
            nhp = (str(ob.get("server") or ""), int(ob.get("server_port") or 0))
            if uhp and uhp != nhp and uhp[0]:
                res["addr_mismatch"].append(
                    {"tag": tag, "scheme": scheme, "native": "%s:%s" % nhp,
                     "uri": "%s:%s" % uhp})
        # ① 原生有、URI 完全没有
        for f in sorted(nfeat - ufeat):
            imp = [g for g in IMPLIED.get(f, ()) if g in ufeat]
            if imp:
                res["implied"].append({"tag": tag, "feature": f, "by": imp[0]})
                continue
            lines = loss_lines_for(scheme, f, reg)
            if lines:
                for rid, field, what in lines:
                    res["losses"].append({"tag": tag, "scheme": scheme,
                                          "feature": f, "rule": rid,
                                          "field": field, "what": what,
                                          "kind": "URI 里根本没有"})
            else:
                res["unregistered"].append(
                    {"tag": tag, "feature": f,
                     "why": "URI(%s) 侧没有这个 feature, 但注册表里没有 "
                            "(scheme=%s × feature=%s) 这一行 → UNKNOWN, 不猜"
                            % (scheme, scheme, f)})
        # ② URI 有, 但注册表说只能表达一部分
        for f in sorted(nfeat & ufeat):
            for rid, field, what in loss_lines_for(scheme, f, reg):
                res["losses"].append({"tag": tag, "scheme": scheme,
                                      "feature": f, "rule": rid,
                                      "field": field, "what": what,
                                      "kind": "只能表达一部分"})
    res["extra_uri"] = sorted(pair_map)
    return res


def main():
    ap = argparse.ArgumentParser(prog="uri_express.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("report")
    p.add_argument("native")
    p.add_argument("--link", action="append", default=[],
                   help="TAG=链接文件（可多次）")
    p.add_argument("--links-dir", default="",
                   help="由 <tag> 推 <dir>/sb_share-<tag>.txt")
    p.add_argument("--json", action="store_true")
    a = ap.parse_args()

    pairs = []
    for kv in a.link:
        tag, _, path = kv.partition("=")
        pairs.append((tag, path))
    if a.links_dir:
        with open(a.native, encoding="utf-8") as fh:
            doc = json.load(fh)
        for o in doc.get("outbounds") or []:
            if isinstance(o, dict) and (o.get("type") or "") not in CONTROL_TYPES:
                t = o.get("tag") or ""
                f = os.path.join(a.links_dir, "sb_share-%s.txt" % t)
                if os.path.isfile(f):
                    pairs.append((t, f))
    if not os.path.isfile(a.native):
        sys.stderr.write("找不到原生 JSON: %s\n" % a.native)
        return 2
    r = report(a.native, pairs)
    if a.json:
        print(json.dumps(r, ensure_ascii=False, indent=1))
        return 0
    print("URI 表达力标注（注册表: proxy_node_compat/data/rules.json uri_rules）")
    print("  节点 %d 个; 逐节点查过 %d 个 scheme" % (r["nodes"], len(r["checked"])))
    if r["missing_uri"]:
        print("  [ERR] 这些节点没有 URI 行 → **不许发布**(URI 产品会少节点): %s"
              % ", ".join(r["missing_uri"]))
    if r["extra_uri"]:
        print("  [ERR] 这些 URI 行在原生产品里没有对应节点: %s"
              % ", ".join(r["extra_uri"]))
    if r["losses"]:
        print("  [注意] URI 路径表达力损失 %d 条（原生路径没有这些损失）:" % len(r["losses"]))
        for l in r["losses"]:
            print("    · %-24s %-14s %s  [%s] %s"
                  % (l["tag"], l["feature"], l["kind"], l["rule"], l["what"]))
    else:
        print("  [OK]   URI 路径按注册表**没有**表达力损失（≠ 没有未入册项, 见下）")
    if r["addr_mismatch"]:
        print("  [注意] 两条产品的取件地址不一致 %d 个节点（同一节点的两种表达指向不同地址）:"
              % len(r["addr_mismatch"]))
        for m in r["addr_mismatch"]:
            print("    · %-24s 原生=%s / URI=%s  [%s]"
                  % (m["tag"], m["native"], m["uri"], m["scheme"]))
    if r["implied"]:
        print("  [--]   由其它 feature 承载（有据: 注册表该条 representation=FULL）: %s"
              % ", ".join("%s:%s←%s" % (i["tag"], i["feature"], i["by"]) for i in r["implied"]))
    if r["unknown_scheme"]:
        print("  [UNKNOWN] scheme 没入册, 表达力判不了:")
        for u in r["unknown_scheme"]:
            print("    · %-24s scheme=%s —— %s" % (u["tag"], u["scheme"], u["why"]))
    if r["unregistered"]:
        print("  [UNKNOWN] 原生有、URI 侧查不到, 且注册表没有对应行（不折算成'没损失'）:")
        for u in r["unregistered"]:
            print("    · %-24s %s —— %s" % (u["tag"], u["feature"], u["why"]))
    if r["missing_uri"] or r["extra_uri"]:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
