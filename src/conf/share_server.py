#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
share_server.py — SB-Panel Share URL 服务端
GET  /share/<token>            -> 200: client config JSON (原子消费一次额度)
                                  410: DENIED(用尽/禁用/过期)
                                  404: 未知 token
GET  /status                   -> 文本健康
并发安全: flock(SHARE_DIR/.share.lock) 串行化 read-modify-write
*/
"""
import json, os, sys, time, fcntl, struct, http.server, socketserver, threading
from urllib.parse import urlsplit

SHARE_DIR = os.environ.get("SHARE_DIR", "/root/catmi/sing-box/share")
LOCK = os.path.join(SHARE_DIR, ".share.lock")
PORT = int(os.environ.get("SHARE_PORT", "9292"))

class Store:
    @staticmethod
    def _lock():
        f = open(LOCK, "a+")
        fcntl.flock(f, fcntl.LOCK_EX)
        return f
    @staticmethod
    def path(token):
        return os.path.join(SHARE_DIR, "shares", f"{token}.json")
    @staticmethod
    def load(token):
        try:
            with open(Store.path(token)) as fh:
                return json.load(fh)
        except FileNotFoundError:
            return None
    @staticmethod
    def save(meta):
        p = Store.path(meta["share_token"])
        tmp = p + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(meta, fh, indent=1)
        os.replace(tmp, p)

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):
        pass
    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path == "/status":
            self._send(200, b"SB-Panel Share Server OK\n")
            return
        token = path[len("/share/"):] if path.startswith("/share/") else None
        if not token or not token.isalnum() or len(token) < 16:
            self._send(404, "not found\n")
            return
        lock = Store._lock()
        try:
            meta = Store.load(token)
            if meta is None:
                return self._send(404, b"not found\n")
            now = int(time.time())
            if not meta.get("enabled", False):
                return self._send(410, "disabled\n")
            if meta.get("expires_at", 0) and now > int(meta["expires_at"]):
                return self._send(410, "expired\n")
            maxu = int(meta.get("max_uses", 0))
            used = int(meta.get("used_count", 0))
            if maxu and used >= maxu:
                return self._send(410, "used up\n")
            cpath = meta.get("client_file")
            if not cpath or not os.path.isfile(cpath):
                return self._send(503, "config unavailable\n")   # 未成功提供则不消耗
            # 提交消费(在提供网络响应前原子预留; 客户端收到 200 必然有完整 body)
            meta["used_count"] = used + 1
            meta["last_used_at"] = now
            Store.save(meta)
            with open(cpath, "rb") as fh:
                body = fh.read()
            return self._send(200, body, "application/json")
        finally:
            try:
                import fcntl as f2; f2.flock(lock, fcntl.LOCK_UN); lock.close()
            except Exception:
                pass

class Srv(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

if __name__ == "__main__":
    os.makedirs(os.path.join(SHARE_DIR, "shares"), exist_ok=True)
    Store._lock()  # 触发 lock 文件创建
    with Srv(("0.0.0.0", PORT), Handler) as httpd:
        print(f"share server on :{PORT}", flush=True)
        httpd.serve_forever()
