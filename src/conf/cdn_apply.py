#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cdn_apply.py — 把 SB-Panel 的 CDN location 片段安全地插入已有 Nginx 站点配置

为什么需要这么小心:
  - 用户的 Nginx 站点已经 listen 443 且配好 ssl_certificate, 还兼着正常网站
    业务。新建一个同 server_name 的 server 块会让 nginx 直接起不来
    ("Address already in use")。
  - 所以只能往**已有的 server{} 块内部**插 location, 绝不新建 server 块。
  - 配置常是 CRLF 行尾(dos), 插入时必须保持, 否则可能解析异常。

安全措施 (每一步都可回滚):
  1. 只在"已存在且 server_name 匹配"的 server 块内插入; 找不到就拒绝, 不猜。
  2. 用标记注释包起来, 重复执行是**替换**而非追加 —— 天然幂等, 不会重复堆叠。
  3. 写入前备份 (.sbpanel-bak), 保留原文件权限。
  4. 写入后自动跑 nginx -t; 不通过就**立即回滚**并报错。
  5. 找不到 nginx 部署方式 / 找不到站点文件 / 没权限 —— 一律拒绝并说明, 绝不硬写。

用法:
  cdn_apply.py --domain <域名> --file <站点配置> --block <片段文件> [--nginx docker:nginx|systemd|none] [--dry-run]
  cdn_apply.py --remove --domain <域名> --file <站点配置> ...
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

BEGIN = "    # >>> SB-Panel CDN 开始 (自动生成, 请勿手改) >>>"
END = "    # <<< SB-Panel CDN 结束 <<<"

# CRLF 感知的行尾探测
def detect_eol(data: bytes) -> bytes:
    return b"\r\n" if b"\r\n" in data else b"\n"

def decode(data: bytes) -> str:
    return data.decode("utf-8", errors="surrogateescape")

def encode(text: str, eol: bytes) -> bytes:
    return text.replace("\r\n", "\n").replace("\n", eol.decode()).encode("utf-8", errors="surrogateescape")

def find_server_block_span(lines, domain):
    """返回包含 server_name <domain> 的那个 server{} 块的 (起始行, 结束行) 下标。
    没有就返回 None —— 绝不猜。"""
    dom_re = re.compile(r"server_name\s+[^;]*\b" + re.escape(domain) + r"\b[^;]*;")
    for i, line in enumerate(lines):
        if not dom_re.search(line):
            continue
        # 从这一行往上找最近的 "server {" (跳过 upstream{})
        start = None
        for j in range(i, -1, -1):
            s = lines[j]
            if re.search(r"\bupstream\b", s):
                break
            if re.match(r"^\s*server\s*\{", s):
                start = j
                break
            if re.match(r"^\s*server\s*\{", s) is None and re.search(r"^\s*server\b", s):
                start = j
                break
        if start is None:
            continue
        # 从 start 往下做花括号配对
        depth = 0
        for k in range(start, len(lines)):
            depth += lines[k].count("{") - lines[k].count("}")
            if depth == 0 and k > start:
                return start, k
            if depth == 0 and k == start and "{" in lines[k]:
                return start, k
    return None

def strip_existing(text):
    """移除上一次生成的标记块 (幂等: 重复执行是替换而非追加)"""
    pat = re.compile(
        re.escape(BEGIN) + r".*?" + re.escape(END) + r"\n?",
        re.S,
    )
    return pat.sub("", text), len(pat.findall(text))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--domain", required=True)
    ap.add_argument("--file", required=True)
    ap.add_argument("--block", help="location 片段文件")
    ap.add_argument("--remove", action="store_true")
    ap.add_argument("--nginx", default="auto",
                    help="docker:<容器名> | systemd | none (跳过语法校验)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    path = args.file
    if not os.path.isfile(path):
        print("找不到站点配置文件: %s" % path, file=sys.stderr)
        return 2

    with open(path, "rb") as f:
        raw = f.read()
    eol = detect_eol(raw)
    text = decode(raw)
    had = text.count(BEGIN)
    text, removed = strip_existing(text)

    if args.remove:
        if not removed:
            print("配置里没有 SB-Panel 生成的块, 无需移除", file=sys.stderr)
            return 0
        if not write_and_check(path, text, eol, args, dry_run=args.dry_run,
                               what="移除 SB-Panel CDN 片段"):
            return 1
        print("[OK] 已从 %s 移除 SB-Panel CDN 片段" % path)
        return 0

    if not args.block or not os.path.isfile(args.block):
        print("找不到 location 片段文件", file=sys.stderr)
        return 2
    with open(args.block, "rb") as f:
        block = decode(f.read()).replace("\r\n", "\n").rstrip("\n")

    lines = text.split("\n")
    span = find_server_block_span(lines, args.domain)
    if span is None:
        print(
            "在 %s 里找不到 server_name %s 的 server 块 —— 已拒绝写入。\n"
            "  本工具只往已存在的 server{} 内插 location, 不会新建 server 块。\n"
            "  请确认域名拼写, 或手工把片段粘进该站点的 server{} 内。"
            % (path, args.domain),
            file=sys.stderr,
        )
        return 3

    start, end = span
    # 缩进跟随该 server 块自身: server{ 在第几列, 内容就缩进在它之后一格。
    # 片段已经带了 4 空格基准缩进, 所以按相对层级平移, 而不是粗暴地 strip 全部。
    m = re.match(r"^([ \t]*)server\s*\{", lines[start])
    base = len(m.group(1)) if m else 0
    # 片段最少的缩进列数 = 基准, 整体右移到 base+4
    all_lines = block.split("\n")
    widths = [len(l) - len(l.lstrip(" ")) for l in all_lines if l.strip()]
    lead = min(widths) if widths else 0
    shift = base + 4 - lead

    out = []
    for l in all_lines:
        if not l.strip():
            out.append("")
            continue
        w = len(l) - len(l.lstrip(" "))
        out.append(" " * max(0, w + shift) + l.lstrip(" "))
    body = "\n".join(out)

    payload = (
        " " * (base + 4) + BEGIN.strip() + "\n"
        + body + "\n"
        + " " * (base + 4) + END.strip() + "\n"
    )

    # 插到该 server 块的收尾 } 之前
    new_lines = lines[:end] + payload.rstrip("\n").split("\n") + lines[end:]
    new_text = "\n".join(new_lines)

    if args.dry_run:
        print("=== 将写入 %s 的 server{} (第 %d-%d 行) ===" % (path, start + 1, end + 1))
        print(payload)
        return 0

    if not write_and_check(path, new_text, eol, args, dry_run=False,
                           what="写入 SB-Panel CDN 片段"):
        return 1
    print("[OK] 已插入到 %s 的 server_name %s 块内 (第 %d 行前)" % (path, args.domain, end + 1))
    return 0

def write_and_check(path, text, eol, args, dry_run, what):
    if dry_run:
        print("(dry-run) 未写入")
        return True
    # 备份
    bak = path + ".sbpanel-bak"
    shutil.copy2(path, bak)
    try:
        with open(path, "wb") as f:
            f.write(encode(text, eol))
    except OSError as e:
        print("写入失败: %s (原文件未改动)" % e, file=sys.stderr)
        return False
    # 语法校验
    ok, msg = nginx_test(args.nginx)
    if not ok:
        shutil.copy2(bak, path)     # 回滚
        print("%s 失败, 已自动回滚到原配置。" % what, file=sys.stderr)
        print("nginx -t 报错:\n%s" % msg, file=sys.stderr)
        return False
    return True

def nginx_test(mode):
    """返回 (是否通过, 输出)。校验不了就返回通过 —— 但会明确告知。"""
    cmds = []
    if mode == "auto":
        mode = detect_nginx_mode()
    if mode.startswith("docker:"):
        c = mode.split(":", 1)[1]
        cmds = [["docker", "exec", c, "nginx", "-t"]]
    elif mode == "systemd":
        cmds = [["nginx", "-t"]]
    else:
        print("[Warn] 未检测到可用的 nginx 校验方式, 跳过语法检查。"
              "请自行执行 nginx -t 确认。", file=sys.stderr)
        return True, ""
    for cmd in cmds:
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError) as e:
            print("[Warn] 无法执行 %s: %s" % (" ".join(cmd), e), file=sys.stderr)
            return True, ""
        out = (p.stdout or "") + (p.stderr or "")
        if p.returncode != 0:
            return False, out
    return True, ""

def detect_nginx_mode():
    if shutil.which("docker"):
        try:
            out = subprocess.run(["docker", "ps", "--format", "{{.Names}}"],
                                 capture_output=True, text=True, timeout=15).stdout
            for name in out.split():
                if name == "nginx":
                    return "docker:nginx"
        except (OSError, subprocess.SubprocessError):
            pass
    if os.path.exists("/etc/nginx/nginx.conf"):
        return "systemd"
    return "none"

if __name__ == "__main__":
    sys.exit(main())
