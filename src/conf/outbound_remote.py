#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
outbound_remote.py — 服务端出站: 从「远程配置(分享链接)」拉取节点

复用的是项目已有的分享机制本身, 不另造一套订阅系统:
  分享端 (share.sh → 公共分享服务) 下发的就是一份 sing-box 配置 JSON,
  其中 .outbounds[] 的每一项本身就是完整可用的 outbound 对象。
  所以这里不需要"协议解析/字段转换", 只需:
    1. 按 client.sh add_node 的同一套 HTTP 语义取回 (200/404/410/503)
    2. 用 sing-box check 验证载荷确实是合法配置
    3. 挑出真正的节点 (排除 selector/urltest/direct/block/dns)
    4. 计算 detour 依赖闭包 —— ShadowTLS 这类节点是两条 outbound 组成的,
       少导入一条必然 check 失败

子命令:
  fetch   <url> <cache>            下载 + 校验, cache 存原始载荷; stdout = 节点清单
  node    <cache> <tag>            输出该 tag 的 outbound JSON
  preview <cache> <tag>            输出脱敏预览行
"""
import json, os, subprocess, sys, tempfile, urllib.error, urllib.request

# 与 client.sh add_node 保持一致: 这些类型不是"节点", 是聚合/控制用的
CONTROL_TYPES = {"selector", "urltest", "direct", "block", "dns"}
# 缺失就无法工作 —— 服务端 inbound 侧同理
REQUIRED_FIELDS = {
    "shadowsocks": ["method", "password"],
    "vmess": ["uuid"],
    "vless": ["uuid"],
    "trojan": ["password"],
    "hysteria2": ["password"],
    "tuic": ["uuid", "password"],
    "anytls": ["password"],
    "shadowtls": ["password"],
    "naive": ["username", "password"],
    "http": ["username", "password"],
    "socks": [],
    "ssh": [],
}


def fail(msg):
    print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False))
    sys.exit(2)


def singbox_check(path):
    """复用本机内核做校验; 找不到内核时不谎报通过"""
    for cand in ("sing-box",
                 "/root/catmi/sing-box/sing-box",
                 os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sing-box")):
        exe = cand if os.path.isabs(cand) or os.path.sep in cand else None
        if exe is None:
            exe = shutil_which("sing-box")
        if not exe or not (os.path.isfile(exe) and os.access(exe, os.X_OK)):
            continue
        r = subprocess.run([exe, "check", "-c", path],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if r.returncode == 0:
            return True, ""
        return False, r.stdout.decode("utf-8", "replace").strip().splitlines()[-1:] or [""]
    return None, ""


def shutil_which(name):
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def http_get(url, dest):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "sb-panel-outbound"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            code = resp.getcode()
            body = resp.read()
    except urllib.error.HTTPError as e:
        code, body = e.code, b""
    except Exception as e:
        fail("网络错误, 下载失败 (%s)" % type(e).__name__)
    # 与 client.sh add_node 相同的语义, 用户看到的提示也保持一致
    if code == 404:
        fail("链接不存在 (HTTP 404)")
    if code == 410:
        fail("分享链接已失效 (用尽/过期/禁用)")
    if code == 503:
        fail("服务端配置暂不可用, 未消耗次数 (HTTP 503)")
    if code != 200:
        fail("HTTP %s" % code)
    if not body.strip():
        fail("远程配置为空 (0 字节)")
    with open(dest, "wb") as f:
        f.write(body)
    return body


def load_manifest(cache):
    try:
        with open(cache, encoding="utf-8") as f:
            doc = json.load(f)
    except Exception as e:
        fail("远程配置不是合法 JSON: %s" % e)
    obs = doc.get("outbounds")
    if not isinstance(obs, list) or not obs:
        fail("远程配置里没有 outbounds 数组 —— 这不是本项目分享的节点配置")
    return obs


def find_by_tag(obs, tag):
    for o in obs:
        if o.get("tag") == tag:
            return o
    return None


def build_closure(obs, tags):
    """选中项 + 它们的 detour 依赖 (ShadowTLS 这类节点是两条一组)"""
    by = {o.get("tag"): o for o in obs if isinstance(o, dict)}
    out, stack = [], list(tags)
    while stack:
        t = stack.pop(0)
        if t in out or t not in by:
            continue
        out.append(t)
        d = by[t].get("detour")
        if isinstance(d, str) and d and d not in out:
            stack.append(d)
    return out


def check_nodes(obs, tags):
    """逐节点 (含其 detour 依赖) 单独校验。

    刻意不对整份载荷做 check: 载荷里只要有一个本机不支持的出站
    (例如内核缺 cronet 的 naive), 整份 check 就失败, 会把其余可用节点
    一起挡掉。服务端是"挑一个节点来用", 粒度必须是单个节点。
    """
    by = {o.get("tag"): o for o in obs if isinstance(o, dict)}
    results = {}
    for t in tags:
        group = build_closure(obs, [t])
        doc = {"outbounds": [by[g] for g in group if g in by], "route": {"final": t}}
        fd, tmp = tempfile.mkstemp(suffix=".json")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(doc, f)
            ok, err = singbox_check(tmp)
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        if ok is None:
            results[t] = (False, "找不到 sing-box 内核, 无法校验")
        elif ok:
            results[t] = (True, "")
        else:
            results[t] = (False, err[0])
    return results


def cmd_fetch(url, cache):
    http_get(url, cache)
    obs = load_manifest(cache)          # 这里只保证是合法 JSON

    # 真正的节点 = 非控制类型
    nodes = [o for o in obs
             if isinstance(o, dict) and o.get("type") and o.get("type") not in CONTROL_TYPES]
    if not nodes:
        fail("远程配置里没有可导入的节点 (只有 selector/urltest/direct 等控制型出站)")

    # detour 依赖闭包: 被别人 detour 的 outbound 不能单独用
    detour_target = set()
    for o in obs:
        d = o.get("detour")
        if isinstance(d, str) and d:
            detour_target.add(d)

    manifest, problems = [], []
    seen = set()
    for o in nodes:
        tag = o.get("tag")
        if not tag or tag in seen:
            continue
        seen.add(tag)
        entry = {"tag": tag, "type": o.get("type"),
                 "role": "dep" if tag in detour_target else "main",
                 "server": o.get("server"), "port": o.get("server_port"),
                 "needs": [], "missing": []}
        d = o.get("detour")
        if isinstance(d, str) and d:
            entry["needs"].append(d)
            if find_by_tag(obs, d) is None:
                entry["missing"].append(d)
        for f in REQUIRED_FIELDS.get(o.get("type"), []):
            val = o.get(f)
            if val is None or (isinstance(val, str) and not val.strip()):
                entry["missing"].append(f)
        if entry["missing"]:
            problems.append("%s (%s) 缺少: %s" % (tag, o.get("type"), ", ".join(entry["missing"])))
        manifest.append(entry)

    # 逐节点内核校验 —— 这是"在本机到底能不能用"的真实判据
    checks = check_nodes(obs, [e["tag"] for e in manifest])
    usable = 0
    for e in manifest:
        ok, err = checks.get(e["tag"], (False, "未校验"))
        e["valid"] = bool(ok)
        if not ok:
            e["err"] = err
        elif e["role"] == "main":
            usable += 1
    if usable == 0:
        fail("远程配置里的节点在本机内核上没有一个可用:\n      " +
             "\n      ".join("%s (%s): %s" % (e["tag"], e["type"], e.get("err", "?"))
                            for e in manifest if e["role"] == "main"))
    print(json.dumps({"ok": True, "source": url, "nodes": manifest,
                      "usable": usable, "problems": problems}, ensure_ascii=False))


def cmd_node(cache, tag):
    obs = load_manifest(cache)
    o = find_by_tag(obs, tag)
    if o is None:
        fail("远程配置里没有 tag=%s" % tag)
    print(json.dumps(o, ensure_ascii=False))


def mask(v):
    s = str(v)
    if not s:
        return "(空)"
    # 不回显长度: 长度会缩小暴力破解空间, 统一固定掩码
    return "******** (已配置)"


def cmd_preview(cache, tag):
    obs = load_manifest(cache)
    o = find_by_tag(obs, tag)
    if o is None:
        fail("远程配置里没有 tag=%s" % tag)
    out = []

    def walk(prefix, d):
        for k in sorted(d.keys()):
            v = d[k]
            if isinstance(v, dict):
                walk(prefix + k + ".", v)
                continue
            if isinstance(v, list):
                out.append((prefix + k, "(%d 项)" % len(v)))
                continue
            if k in ("password", "uuid", "username"):
                out.append((prefix + k, mask(v)))
            elif k == "certificate":
                out.append((prefix + k, "(内嵌证书, %d 字节)" % len(str(v).encode())))
            elif k in ("public_key", "short_id", "certificate_public_key_sha256"):
                out.append((prefix + k, "(已配置)"))
            else:
                out.append((prefix + k, "是" if v is True else ("否" if v is False else str(v))))
    walk("", o)
    for k, v in out:
        print("%s: %s" % (k, v))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        fail("用法: outbound_remote.py {fetch|node|preview} ...")
    cmd = sys.argv[1]
    if cmd == "fetch" and len(sys.argv) == 4:
        cmd_fetch(sys.argv[2], sys.argv[3])
    elif cmd == "node" and len(sys.argv) == 4:
        cmd_node(sys.argv[2], sys.argv[3])
    elif cmd == "preview" and len(sys.argv) == 4:
        cmd_preview(sys.argv[2], sys.argv[3])
    else:
        fail("用法: outbound_remote.py fetch <url> <cache> | node <cache> <tag> | preview <cache> <tag>")
