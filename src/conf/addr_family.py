#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
addr_family.py — 客户端产物地址族切换: 只改"确实指向本机的 IP"

背景 (为什么不能再用 sed / jq 无条件改写):
  旧实现把产物里**每一个 server 字段**都改成目标地址, 于是:
    * CDN 节点被改坏 —— sb_cdn_finalize 故意把客户端写成"证书域名:443"
      (源站只监听 127.0.0.1, 靠 nginx 回源), 改成源站 IP:443 之后
      既连不通, 也把"隐藏源站"这件事一起抹掉了;
    * 手工填域名的节点、从他处导入的节点同理;
    * 别的服务器/中转节点的 IP 也被顺手改成本机地址。
  另外还有两处**静默失效**:
    * 分享链接里 IPv6 是 @[2001:db8::1]:port (带方括号), 旧正则用
      @2001:db8::1 去匹配永远不中 —— 切 v6->v4 时什么都没改, 却报"已更新";
    * vmess 链接的地址在 base64 里, 文本替换根本碰不到。

所以这里只做一件事, 并且做准:
  server / 链接主机 / 订阅 URL 主机 —— **等于 --ours 里给出的地址**才替换,
  其余 (域名 / 他机 IP / 私网 / WARP 等隧道地址) 一律原样保留并在报告里说明。

用法:
  addr_family.py --out-dir <out> --from <旧地址> --to <新地址> [--ours IP]...
输出 (stdout): 一行 JSON 报告, 由 lib.sh 渲染成中文提示; 退出码 0=成功。
"""

import argparse
import base64
import binascii
import ipaddress
import json
import os
import re
import sys
import urllib.parse as up

# URI 链接里带主机的那几个文件 (协议脚本产出) 与订阅 URL 文件 (公共分享服务)
LINK_GLOBS = ("sb_share-*.txt", "sb_links-all.txt")
SUB_GLOBS = ("share_tag-*.txt",)
JSON_GLOB = "sb_client-*.json"
YAML_GLOB = "sb_client-*.yaml"

SCHEME_RE = re.compile(r"^([A-Za-z][A-Za-z0-9+.\-]*)://(.*)$", re.S)
# YAML 里只认**键名正好是 server** 的那一行:
#   server: 1.2.3.4        <- 要改
#   servername: a.com      <- 不能碰 (TLS SNI)
#   query-server-name: a.com  <- 不能碰 (ECH)
#   handshake: { server: .. } <- mihomo 里没有, 但也不该误伤
YAML_SERVER_RE = re.compile(r"^(\s*server:\s*)(\S+)(\s*)$")


def norm_ip(s):
    """返回规范化后的 IP 文本; 不是 IP 字面量则返回 None。

    必须规范化再比: 2001:DB8::1 与 2001:db8::1 是同一个地址,
    字符串直接比会漏掉 (客户端产物里的写法不由我们控制)。
    """
    if not isinstance(s, str) or not s:
        return None
    try:
        return str(ipaddress.ip_address(s.strip()))
    except ValueError:
        return None


def b64_decode_tolerant(s):
    """容忍 URL-safe 字母表与缺失填充的 base64 解码。"""
    s = re.sub(r"\s+", "", s)
    s = s.replace("-", "+").replace("_", "/")
    s += "=" * (-len(s) % 4)
    return base64.b64decode(s)


class Rewriter:
    def __init__(self, out_dir, old, new, ours):
        self.out = out_dir
        self.new = new
        self.new_norm = norm_ip(new)
        # 规范化后的"本机地址"集合。old 也在里面 —— 调用方会把探测到的旧地址塞进来。
        self.ours = set()
        for a in list(ours) + [old]:
            n = norm_ip(a)
            if n:
                self.ours.add(n)
        self.report = {
            "ok": True,
            "json": {"files": 0, "hosts": 0},
            "yaml": {"files": 0, "hosts": 0},
            "links": {"files": 0, "hosts": 0},
            "subs": {"files": 0, "hosts": 0},
            # 保留下来的东西要能看见: 域名(CDN/手工) 与 非本机 IP(他机/中转)
            "kept_domains": set(),
            "kept_ips": set(),
            "errors": [],
        }

    # ---------- 判定 ----------
    def is_ours(self, host):
        n = norm_ip(host)
        return bool(n) and n in self.ours

    def keep(self, host):
        """记下"没动"的地址, 好让用户知道为什么 (域名 vs 非本机 IP)。

        已经是目标地址的不记 —— 那说明这条产物本来就对, 报出来只会让人以为
        "有个地址没切", 反而误导 (重复执行切换时必然出现这种条目)。
        """
        n = norm_ip(host)
        if not n:
            self.report["kept_domains"].add(host)
        elif n != self.new_norm:
            self.report["kept_ips"].add(host)

    # ---------- 写文件 ----------
    def _write_if_changed(self, path, text):
        with open(path, "r", encoding="utf-8") as fh:
            old = fh.read()
        if old == text:
            return False
        tmp = path + ".aftmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
        return True

    def _files(self, *globs):
        import glob as _glob
        out = []
        for g in globs:
            out.extend(sorted(_glob.glob(os.path.join(self.out, g))))
        return out

    # ---------- JSON: 只碰 outbounds[].server ----------
    def do_json(self):
        for path in self._files(JSON_GLOB):
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    raw = fh.read()
                data = json.loads(raw)
            except Exception as e:
                self.report["errors"].append("%s: 解析失败 (%s)" % (os.path.basename(path), e))
                continue
            hits = 0
            for ob in (data.get("outbounds") or []):
                if not isinstance(ob, dict):
                    continue
                srv = ob.get("server")
                if isinstance(srv, str) and self.is_ours(srv):
                    ob["server"] = self.new
                    hits += 1
                elif isinstance(srv, str) and srv:
                    self.keep(srv)
            if not hits:
                continue
            # 缩进沿用原文件 (协议脚本写 2 格, 聚合写 1 格), 免得整个文件被重排
            indent = 2
            for line in raw.splitlines()[1:]:
                m = re.match(r"^(\s+)\S", line)
                if m:
                    indent = len(m.group(1))
                    break
            text = json.dumps(data, indent=indent, ensure_ascii=False) + "\n"
            if self._write_if_changed(path, text):
                self.report["json"]["files"] += 1
                self.report["json"]["hosts"] += hits

    # ---------- YAML: 只碰键名正好是 server 的那一行 ----------
    def do_yaml(self):
        for path in self._files(YAML_GLOB):
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    lines = fh.read().splitlines(keepends=True)
            except Exception as e:
                self.report["errors"].append("%s: 读取失败 (%s)" % (os.path.basename(path), e))
                continue
            hits = 0
            for i, line in enumerate(lines):
                m = YAML_SERVER_RE.match(line.rstrip("\n"))
                if not m:
                    continue
                raw_val = m.group(2)
                val = raw_val
                quote = ""
                if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                    quote, val = val[0], val[1:-1]
                if self.is_ours(val):
                    nl = "\n" if line.endswith("\n") else ""
                    lines[i] = "%s%s%s%s%s" % (m.group(1), quote, self.new, quote, m.group(3) + nl)
                    hits += 1
                elif val:
                    self.keep(val)
            if not hits:
                continue
            if self._write_if_changed(path, "".join(lines)):
                self.report["yaml"]["files"] += 1
                self.report["yaml"]["hosts"] += hits

    # ---------- 分享链接 (URI) ----------
    def _link_line(self, line):
        """返回 (改写后的行, 是否命中)。解析不了就原样返回。"""
        s = line.rstrip("\n")
        if not s.strip():
            return line, False
        m = SCHEME_RE.match(s.strip())
        if not m:
            return line, False
        scheme, rest = m.group(1), m.group(2)
        if scheme.lower() == "vmess":
            return self._link_vmess(line, s, rest)
        # 先切掉 #片段 与 ?查询, 再在剩下的 "userinfo@host:port" 里找主机。
        # 这样即使查询串/备注里出现 @ 或 IP, 也不会改错地方。
        body = rest.split("#", 1)[0]
        head = body.split("?", 1)[0]
        at = head.rfind("@")
        if at < 0:
            return line, False
        userinfo, hostport = head[:at + 1], head[at + 1:]
        hostport = hostport.split("/", 1)[0]      # 理论上没有 path, 兜一下
        if hostport.startswith("["):              # [IPv6]:port
            j = hostport.find("]")
            if j < 0:
                return line, False
            host, portpart = hostport[1:j], hostport[j + 1:]
        elif hostport.count(":") > 1:             # 裸 IPv6, 无端口
            host, portpart = hostport, ""
        else:
            # rpartition 会把分隔的冒号吃掉, 端口要自己补回去:
            # 少了它就成了 vless://x@[2001:db8::1]8443 —— 端口与地址粘在一起, 客户端解析失败
            host, _, p = hostport.rpartition(":")
            portpart = (":" + p) if p.isdigit() else ""
            if not portpart:                      # 没有端口
                host = hostport
        if not self.is_ours(host):
            if host:
                self.keep(host)
            return line, False
        newhost = "[%s]" % self.new if ":" in self.new else self.new
        newline = "%s://%s%s%s%s" % (scheme, userinfo, newhost, portpart, rest[len(head):])
        return newline + "\n", True

    def _link_vmess(self, line, s, rest):
        """vmess://<base64(JSON)>#tag —— 地址在 base64 的 "add" 里, 文本替换碰不到。"""
        body, _, frag = rest.partition("#")
        try:
            obj = json.loads(b64_decode_tolerant(body))
        except (binascii.Error, ValueError, UnicodeDecodeError):
            self.report["errors"].append("vmess 链接 base64/JSON 解析失败, 已跳过")
            return line, False
        if not isinstance(obj, dict):
            return line, False
        add = obj.get("add")
        if not (isinstance(add, str) and self.is_ours(add)):
            if isinstance(add, str) and add:
                self.keep(add)
            return line, False
        obj["add"] = self.new
        enc = base64.b64encode(
            json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ).decode("ascii")
        out = "vmess://" + enc + (("#" + frag) if frag else "")
        return out + "\n", True

    def do_links(self):
        for path in self._files(*LINK_GLOBS):
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    lines = fh.readlines()
            except Exception as e:
                self.report["errors"].append("%s: 读取失败 (%s)" % (os.path.basename(path), e))
                continue
            hits = 0
            for i, line in enumerate(lines):
                new, ok = self._link_line(line)
                if ok:
                    lines[i] = new
                    hits += 1
            if hits:
                if self._write_if_changed(path, "".join(lines)):
                    self.report["links"]["files"] += 1
                    self.report["links"]["hosts"] += hits

    # ---------- 订阅 URL (公共分享服务下发的那种 http://host:port/share/<token>) ----------
    def do_subs(self):
        for path in self._files(*SUB_GLOBS):
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    lines = fh.readlines()
            except Exception as e:
                self.report["errors"].append("%s: 读取失败 (%s)" % (os.path.basename(path), e))
                continue
            hits = 0
            for i, line in enumerate(lines):
                s = line.strip()
                if not s or s.startswith("#"):
                    continue
                try:
                    u = up.urlsplit(s)
                except ValueError:
                    continue
                host = u.hostname or ""
                if not self.is_ours(host):
                    if host:
                        self.keep(host)
                    continue
                hostpart = "[%s]" % self.new if ":" in self.new else self.new
                netloc = hostpart + ((":%d" % u.port) if u.port else "")
                lines[i] = up.urlunsplit((u.scheme, netloc, u.path, u.query, u.fragment)) + "\n"
                hits += 1
            if hits:
                if self._write_if_changed(path, "".join(lines)):
                    self.report["subs"]["files"] += 1
                    self.report["subs"]["hosts"] += hits

    def run(self):
        for step in (self.do_json, self.do_yaml, self.do_links, self.do_subs):
            try:
                step()
            except Exception as e:
                self.report["ok"] = False
                self.report["errors"].append("%s 失败: %s" % (step.__name__, e))
        r = self.report
        r["kept_domains"] = sorted(r["kept_domains"])
        r["kept_ips"] = sorted(r["kept_ips"])
        return r


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--out-dir", required=True, help="客户端产物目录 (SB_OUT_DIR)")
    ap.add_argument("--from", dest="old", required=True, help="被替换的旧地址")
    ap.add_argument("--to", dest="new", required=True, help="目标地址")
    ap.add_argument("--ours", action="append", default=[],
                    help="本机地址 (可多次); 只有这些地址会被替换, 其余原样保留")
    args = ap.parse_args()

    if not os.path.isdir(args.out_dir):
        print(json.dumps({"ok": False, "errors": ["目录不存在: %s" % args.out_dir]}))
        return 1
    if not norm_ip(args.new):
        print(json.dumps({"ok": False, "errors": ["目标不是合法 IP: %s" % args.new]}))
        return 1
    rep = Rewriter(args.out_dir, args.old, args.new, args.ours).run()
    print(json.dumps(rep, ensure_ascii=False))
    return 0 if rep.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
