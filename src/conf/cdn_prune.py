#!/usr/bin/env python3
"""cdn_apply.py --prune-orphans: 清除 proxy_pass 指向已不存在节点的孤立 location

只删**同时满足**两条的 location 块:
  1. 处于 server{} 之外 (顶层, 列 0 开始), 且 proxy_pass 是
     http://127.0.0.1:<端口> 形式 —— 这是本项目插入的节点反代的特征;
  2. 该端口不在 --live-ports 给出的存活端口集合里。

站点自有的 location (upstream backend_xxx、静态文件缓存、acme-challenge、
非 127.0.0.1 的 proxy_pass) 一律不碰。
"""
import argparse
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cdn_apply as CA  # noqa: E402


def find_top_level_orphan_blocks(lines, live):
    """返回 [(start, end_exclusive, port, preview)] —— 只匹配顶层 127.0.0.1 反代块"""
    out = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        m = re.match(r'^location\s+(\S+)\s*\{', line)
        if not m:
            i += 1
            continue
        start = i
        depth = line.count("{") - line.count("}")
        j = i + 1
        while j < n and depth > 0:
            depth += lines[j].count("{") - lines[j].count("}")
            j += 1
        body = "".join(lines[start:j])
        pm = re.search(r'proxy_pass\s+http://127\.0\.0\.1:(\d+)', body)
        if pm and int(pm.group(1)) not in live:
            out.append((start, j, int(pm.group(1)),
                        lines[start].strip()[:50]))
            i = j
            continue
        i = j
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    ap.add_argument("--live-ports", default="",
                    help="逗号分隔的存活节点端口; 其余 127.0.0.1 反代块视为孤立")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--nginx", default="auto")
    args = ap.parse_args()

    path = args.file
    if not os.path.isfile(path):
        print("找不到站点文件 %s" % path, file=sys.stderr)
        return 1

    live = set()
    for p in args.live_ports.split(","):
        p = p.strip()
        if p.isdigit():
            live.add(int(p))

    with open(path, "rb") as f:
        data = f.read()
    text = CA.decode(data)
    eol = CA.detect_eol(data)
    lines = text.splitlines(keepends=True)

    nginx_mode = args.nginx
    orphans = find_top_level_orphan_blocks(lines, live)
    if not orphans:
        print("[OK] 无孤立 location (%s)" % os.path.basename(path))
        return 0

    for s, e, port, preview in orphans:
        print("将删除孤立 location %s  → 127.0.0.1:%d" % (preview, port))
    if args.dry_run:
        return 0

    for s, e, port, preview in reversed(orphans):
        del lines[s:e]

    new_text = "".join(lines)
    backup = path + ".sbpanel-prune.bak"
    with open(backup, "wb") as f:
        f.write(data)
    with open(path, "wb") as f:
        f.write(CA.encode(new_text, eol))
    print("[OK] 已清除 %d 个孤立 location: %s (备份 %s)"
          % (len(orphans), path, backup))

    ok, _ = CA.nginx_test(nginx_mode)
    if not ok:
        with open(path, "wb") as f:
            f.write(data)
        print("[Error] nginx -t 失败, 已回滚", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())