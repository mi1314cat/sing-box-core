#!/usr/bin/env python3
"""SB-Panel 配置分发服务。

把客户端当前的完整配置 (出站 + DNS + 路由) 以 URL 形式提供给局域网里的
其他设备, 让它们导入后直接可用。别人拿到配置后自己连服务器、自己解析
DNS —— 这里只负责把配置发出去, 不做任何转发。

安全:
  - URL 必须带 token, 没有 token 一律 404 (不告诉攻击者路径是否存在)
  - 只监听一个地址, 只发一个文件, 不提供目录浏览, 不读任何其它路径
  - 每次请求都重新合并 conf/ 下的配置片段, 不读预生成的快照 ——
    这样面板里的任何改动下次拉取立刻生效, 不依赖谁记得去刷新快照。
"""

import argparse
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# 允许导入的客户端
ADDR = "0.0.0.0"
SUB_PATH = "/sub/"


def load_token(path):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return ""


def load_config(confdir):
    """实时合并 conf/ 下的所有片段。

    早先的��现是读一份预生成的快照 (sub.json), 靠 apply_change 钩子刷新。
    问题是 regen_selector (重建 90-outbounds.json) 只在部分操作里跑 ——
    比如菜单 17「应用配置」只重启不重建。于是节点文件已经删了、面板里也
    显示删了, 但聚合配置还是旧的, 快照也跟着是旧的, 别人拉到的还是那个
    已经不存在的节点。

    改成每次请求现场合并: 面板里的操作只要落到了 conf/ 或 nodes/ 里, 下一次
    拉取立刻就是最新的。代价是每个请求读几个 JSON 文件, 局域网这个量级
    完全无所谓。
    """
    merged = {}
    for fn in sorted(os.listdir(confdir)):
        if not fn.endswith(".json"):
            continue
        fp = os.path.join(confdir, fn)
        if not os.path.isfile(fp):
            continue
        try:
            with open(fp) as fh:
                merged.update(json.load(fh))
        except (OSError, ValueError):
            continue
    # 去掉入站: 别的设备用 TUN 还是 SOCKS、监听哪个端口是它自己的事
    merged.pop("inbounds", None)
    # clash_api 的 external_ui 是本机绝对路径, 在别的设备上不存在
    merged.pop("experimental", None)
    if not merged.get("outbounds"):
        raise ValueError("no outbounds")
    return json.dumps(merged, ensure_ascii=False, indent=2).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = "sb-panel-sub"
    sys_version = ""
    token_path = ""
    conf_dir = ""

    def log_message(self, fmt, *args):
        # 静默: 这个服务的访问日志没有价值, 反而会刷屏
        pass

    def _deny(self):
        # 用 404 而不是 403: 不泄露"路径存在但没权限"这一信息
        body = b"not found\n"
        self.send_response(404)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve(self, write_body):
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Disposition",
                         'attachment; filename="sb-client.json"')
        self.send_header("Content-Length", str(len(write_body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(write_body)

    def _expected(self):
        """/sub/<token> —— token 每次重读, 重置后立刻生效, 不用重启服务"""
        return SUB_PATH + load_token(self.token_path)

    def _authorized(self, path):
        exp = self._expected()
        # token 为空 (还没生成) 时一律拒绝, 不能让 /sub/ 裸奔
        return bool(load_token(self.token_path)) and path == exp

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if not self._authorized(path):
            self._deny()
            return
        try:
            body = load_config(self.conf_dir)
        except (OSError, ValueError) as e:
            body = ('{"error":"配置尚未生成, 请先在面板里启动该服务"}'
                    .encode("utf-8"))
            self.send_response(503)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._serve(body)

    def do_HEAD(self):
        path = self.path.split("?", 1)[0]
        if not self._authorized(path):
            self._deny()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(load_config(self.conf_dir))))
        self.end_headers()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9293)
    ap.add_argument("--token-file", required=True)
    ap.add_argument("--config-dir", required=True)
    args = ap.parse_args()

    Handler.token_path = args.token_file
    Handler.conf_dir = args.config_dir

    # 每次请求都重读 token, 不缓存 —— 面板里重置 token 后立刻生效,
    # 不需要重启这个服务。
    if not load_token(args.token_file):
        sys.stderr.write("token 文件为空: %s\n" % args.token_file)
        return 1
    if not os.path.isdir(args.config_dir):
        sys.stderr.write("配置目录不存在: %s\n" % args.config_dir)
        return 1

    srv = ThreadingHTTPServer((ADDR, args.port), Handler)
    srv.daemon_threads = True
    sys.stderr.write("配置分发服务已监听 %s:%d\n" % (ADDR, args.port))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())