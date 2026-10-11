#!/usr/bin/env python3
"""三家互通 · 内核声明与格式选择（格式层, 与 compat 的能力层分工明确）。

    · 服务端: 把"我是哪个内核的哪个发行版 + 我提供哪些格式 + 每种格式从哪取"
      写进**它自己生成的那个订阅地址**（查询串）。
    · 客户端: 读这一个地址就能决定"拉原生还是拉普通话" —— 不猜 User-Agent、
      不做往返协商、不改任何已发出的载荷格式。

本文件是 X 侧 `xray--core/conf/lib/interop.py` 的 sing-box 移植版: 字段名、决策
规则、reason code **逐条相同**（同一份规范只允许有一套语义）, 只把"本机内核事实
真探测"从 `xray version` 换成 `sing-box version`。

设计原文（字段定义 / 为什么不能放响应头 / 为什么不能放内容里 /
决策规则与回退链 / 与 compat 的分工）:
    proxy-node-compat/docs/three-way-interop.md

本文件是**同一份实现的两份拷贝之一**:
    src/conf/interop.py          ← 服务端（权威）
    src/client/lib/interop.py    ← 客户端（vendored 逐字节副本）
门禁断言两份 sha256 相同 —— 抄一遍必然漂移, 而"服务端声明的字段名和客户端读的
字段名不一致"这种错, 表现是**静默全部走普通话**: 没有报错, 只是原生格式永远
拿不到。

为什么声明放 URL 查询串（三条都是可验证的, 不是偏好）:
  1. 公共服务 proxy-share-service 的路由先剥查询串再分发
     (`share_service.py:768-769` `path = self.path.split("?", 1)[0]`),
     所以未知查询参数对返回内容**零影响** —— 第三方客户端即使原样拉走带声明的
     地址, 拿到的仍是原来那份 URI 列表。
  2. 公共服务发不出 provider 自定义响应头（`_send()` 只发 Content-Type /
     Content-Length / Cache-Control, `extra` 只有 Content-Disposition),
     唯一的 meta 端点是「回环 + Bearer」的管理 API, 远端客户端读不到。
  3. 改载荷内容（在 URI 列表里塞声明行）会动到已经发出去的订阅格式, 而第三方
     解析器对它的容忍度在本环境**无法证明** → 按项目纪律不允许当成前提。
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import urllib.parse

# ---------------------------------------------------------------- 常量
# 声明规范的版本。不认识的版本 = 不认识这份声明 → 走最通用的普通话。
INTEROP_SCHEMA = 1

# 声明存在标记。它必须显式存在, 否则"声明缺失"与"某些参数恰好同名的第三方
# 订阅地址"分不开 —— 而这两种情况的处置是**必须**区分开的（缺失要报出来）。
MARKER = "interop"
PARAM_KERNEL = "kernel"
PARAM_DIST = "distribution"
PARAM_VERSION = "version"
PARAM_FORMATS = "formats"
URL_PREFIX = "url-"

# 内核词表 —— 与公共分享服务的 provider 命名**同一套**
# (Share-Service/client/share_client.py: PROVIDER 默认 mihomo;
#  xray--core/conf/share_client.py 里是 xray; sing-box 这边是 sing-box)。
KERNELS = ("xray", "sing-box", "mihomo")

# 普通话格式名。它**恒在**清单里, 且它的地址就是主 URL 本身。
FORMAT_URI = "uri"

# 决策结果（reason code）。客户端日志、门禁断言、验收报告都引用这几个字符串,
# 所以它们是接口的一部分, 不许随手改 —— 与 X 侧逐字相同。
R_NO_DECL = "no-declaration"          # 地址上没有声明
R_BAD_SCHEMA = "unknown-schema"       # 声明在, 但规范版本不认识
R_UNKNOWN_KERNEL = "unknown-kernel"   # kernel 缺失 / 不是内核名
R_CROSS_KERNEL = "cross-kernel"       # 内核不同
R_SELF_UNKNOWN = "self-unknown"       # 本机内核/发行版探测不出来（不猜）
R_DIST_NOT_LISTED = "distribution-not-listed"   # 发行版不在 formats 清单里
R_NO_URL = "no-url-for-format"        # 声明了格式, 却没给地址
R_BAD_URL = "bad-native-url"          # 给了地址, 但不是可用的 http(s) URL
R_NATIVE = "native-listed"            # 走原生
CHOICE_NATIVE = "native"
CHOICE_URI = "uri"


# ================================================================ 声明
def normalize_label(v) -> str:
    """发行版/内核标签归一: 去空白 + 小写。

    `sing-box version 1.14.2` 的首词是 `sing-box`（已经是小写）, 但 fork 的
    二进制可能自报 `LxBox` —— 两边各自 lower() 一次就够了, 不做更花的别名表,
    别名表本身就是漂移源。
    """
    return str(v or "").strip().lower()


def build_declaration(kernel, distribution, version="", formats=(FORMAT_URI,),
                      urls=None) -> dict:
    """组装一份声明（有序 dict, 便于生成稳定可读的查询串）。

    urls: {格式名: 取件地址}。`uri` 的地址是主 URL 本身, 不重复写。
    返回的 dict 里 `formats` 一定是 list, `urls` 一定是 dict。

    ★ `formats` 里的非 uri 项是**发行版标签**（不是"格式名"）: 原生产物是用
      **那个构建**的能力渲染的, 客户端能不能无损读它取决于"我是不是那个构建",
      所以客户端规则退化成一句 `我的发行版标签 ∈ formats`。
    """
    fmts = []
    for f in formats or ():
        f = normalize_label(f)
        if f and f not in fmts:
            fmts.append(f)
    if FORMAT_URI not in fmts:
        fmts.insert(0, FORMAT_URI)          # 普通话是保底项, 必须恒在
    clean_urls = {}
    for k, v in (urls or {}).items():
        k = normalize_label(k)
        if k and k != FORMAT_URI and str(v or "").strip():
            clean_urls[k] = str(v).strip()
    # 「给了取件地址」本身就是「提供这个格式」的声明 —— 只写 url-sing-box 而不写
    # formats=sing-box 的话, 客户端会判"清单里没有我的发行版"而永远走普通话,
    # 而地址上明明挂着原生产物 (声明自相矛盾, 且不报错)。
    for k in clean_urls:
        if k not in fmts:
            fmts.append(k)
    if not all(f in clean_urls or f == FORMAT_URI for f in fmts):
        # 声明的清单里有格式却没地址 → 直接把它从清单里去掉（宁可不声明,
        # 不要声明一个客户端取不到的格式: 那会让客户端先试原生再回退,
        # 白跑一次且日志里多一条假的失败）。
        fmts = [f for f in fmts if f == FORMAT_URI or f in clean_urls]
    return {
        MARKER: INTEROP_SCHEMA,
        PARAM_KERNEL: normalize_label(kernel),
        PARAM_DIST: normalize_label(distribution),
        PARAM_VERSION: str(version or "").strip(),
        PARAM_FORMATS: fmts,
        "urls": clean_urls,
    }


def declaration_query(decl) -> str:
    """声明 → 查询串（不含 `?`）。字段顺序固定: 先固定名, 再逐格式的地址。"""
    d = decl or {}
    parts = [
        (MARKER, str(d.get(MARKER, INTEROP_SCHEMA))),
        (PARAM_KERNEL, d.get(PARAM_KERNEL, "")),
        (PARAM_DIST, d.get(PARAM_DIST, "")),
        (PARAM_VERSION, d.get(PARAM_VERSION, "")),
        (PARAM_FORMATS, ",".join(d.get(PARAM_FORMATS, []) or [])),
    ]
    out = [(k, v) for k, v in parts if str(v or "") != ""]
    for fmt, url in (d.get("urls") or {}).items():
        out.append((URL_PREFIX + fmt, url))
    return urllib.parse.urlencode(out, quote_via=urllib.parse.quote, safe="")


def declare_url(url, decl) -> str:
    """把声明并进一个订阅地址（保留地址原有的其它查询参数）。

    原有参数**保留**: 有些面板会在订阅地址上带自己的参数（`?token=` 之类）,
    我们只**追加**声明, 不重写别人的地址。
    """
    u = urllib.parse.urlsplit(str(url or "").strip())
    q = urllib.parse.parse_qsl(u.query, keep_blank_values=True)
    q = [(k, v) for k, v in q if normalize_label(k) not in
         (MARKER, PARAM_KERNEL, PARAM_DIST, PARAM_VERSION, PARAM_FORMATS)
         and not normalize_label(k).startswith(URL_PREFIX)]
    extra = urllib.parse.parse_qsl(declaration_query(decl), keep_blank_values=True)
    frag = u.fragment
    return urllib.parse.urlunsplit(
        (u.scheme, u.netloc, u.path, urllib.parse.urlencode(q + extra), frag))


def parse_declaration(text):
    """从订阅地址（或裸查询串）里读声明。读不到返回 None。

    只读**查询串**: 片段里的同名字段一律不认（那是别的客户端的显示名载体,
    同一份语义有两套载体必然漂移）。任何异常都返回 None（"没有声明"）,
    **绝不抛** —— 一个畸形地址不该让客户端连普通话都拉不了。
    """
    try:
        s = str(text or "").strip()
        if not s:
            return None
        # 「是不是完整地址」只能按**有没有 scheme** 判, 不能按串里有没有字面 `://`:
        # 裸查询串里未编码的取件地址（`…&url-sing-box=http://h/share/n`）也含 `://`,
        # 而它前面是 `interop=1&…`（含 `=`/`&`, 不构成 scheme）—— 先判 `://` 就会去取
        # `urlsplit(s).query`, 那是**空串** → 声明丢了 → 静默 `no-declaration` →
        # 客户端悄悄走普通话, 不报错。本函数的 docstring 承诺支持「或裸查询串」,
        # 承诺了就得做到（三家实现也必须对同一入参同解, 不许各写一套判据）。
        _u = urllib.parse.urlsplit(s)
        if s.startswith("?"):
            q = s.lstrip("?")          # `?a=1&b=2` 形态
        elif _u.scheme:
            q = _u.query               # 完整地址 → 取它的查询串
        elif "=" in s:
            q = s                      # 裸查询串（测试/手工调试用）
        else:
            q = ""                     # 没有查询串 → 没有声明
        raw = {}
        for k, v in urllib.parse.parse_qsl(q, keep_blank_values=True):
            raw.setdefault(k, v)       # 同名参数取第一个（声明是我们自己写的）
        low = {normalize_label(k): v for k, v in raw.items()}
        if MARKER not in low:
            return None
        try:
            schema = int(str(low.get(MARKER, "")).strip())
        except ValueError:
            schema = -1
        urls = {}
        for k, v in low.items():
            if k.startswith(URL_PREFIX) and len(k) > len(URL_PREFIX):
                urls[k[len(URL_PREFIX):]] = str(v or "").strip()
        fmts = [normalize_label(x) for x in
                str(low.get(PARAM_FORMATS, "")).split(",") if x.strip()]
        return {
            MARKER: schema,
            PARAM_KERNEL: normalize_label(low.get(PARAM_KERNEL, "")),
            PARAM_DIST: normalize_label(low.get(PARAM_DIST, "")),
            PARAM_VERSION: str(low.get(PARAM_VERSION, "")).strip(),
            PARAM_FORMATS: fmts,
            "urls": urls,
            # 声明是"认识的"才允许用它做决策。规范版本 / 内核名不在词表里
            # 都算不认识 —— 不认识的声明与没有声明同等对待（走普通话）。
            "recognized": schema == INTEROP_SCHEMA
            and normalize_label(low.get(PARAM_KERNEL, "")) in KERNELS,
            "raw": raw,
        }
    except Exception:                                            # noqa: BLE001
        return None


def _usable_url(u) -> bool:
    try:
        p = urllib.parse.urlsplit(str(u or "").strip())
        return p.scheme in ("http", "https") and bool(p.netloc)
    except Exception:                                            # noqa: BLE001
        return False


def decide(decl, my_kernel, my_distribution):
    """决策: 返回 (choice, reason, url, detail)。

    choice ∈ {"native", "uri"}; url 是**该去取**的地址（uri 时为空串,
    调用方用自己手里那个主地址）。detail 是给人看的一句话（进日志 / 验收报告）。

    规则（与设计文档 §3 逐条对应, 与 X 侧逐条相同）:
      声明缺失 / 版本不认识 / 内核缺失或不认识 → uri
      跨内核                                    → uri
      本机发行版探测不出来                       → uri   (不猜)
      本机发行版不在 formats 清单里               → uri
      清单里有本机发行版但没给地址 / 地址不是 http(s) → uri
      否则                                      → native(地址)
    """
    if not decl:
        return CHOICE_URI, R_NO_DECL, "", "地址上没有内核声明"
    if not decl.get("recognized"):
        return CHOICE_URI, R_BAD_SCHEMA if decl.get(MARKER) != INTEROP_SCHEMA \
            else R_UNKNOWN_KERNEL, "", (
                "声明规范版本 %s 不认识" % decl.get(MARKER)
                if decl.get(MARKER) != INTEROP_SCHEMA
                else "声明的内核 %r 不在内核词表里" % decl.get(PARAM_KERNEL, ""))
    mine = normalize_label(my_kernel)
    dist = normalize_label(my_distribution)
    if not mine or not dist:
        return CHOICE_URI, R_SELF_UNKNOWN, "", "本机内核/发行版探测不出来（不猜）"
    if decl.get(PARAM_KERNEL) != mine:
        return CHOICE_URI, R_CROSS_KERNEL, "", (
            "服务端内核 %s ≠ 本机 %s" % (decl.get(PARAM_KERNEL), mine))
    if dist not in (decl.get(PARAM_FORMATS) or []):
        return CHOICE_URI, R_DIST_NOT_LISTED, "", (
            "服务端提供的格式 %s 里没有本机发行版 %s"
            % (",".join(decl.get(PARAM_FORMATS) or []) or "(空)", dist))
    native = (decl.get("urls") or {}).get(dist, "")
    if not native:
        return CHOICE_URI, R_NO_URL, "", "声明里有 %s 格式, 却没给取件地址" % dist
    if not _usable_url(native):
        return CHOICE_URI, R_BAD_URL, "", "原生取件地址不是可用的 http(s) 地址: %s" % native
    return CHOICE_NATIVE, R_NATIVE, native, (
        "同内核同发行版 (%s/%s) → 取原生" % (mine, dist))


# ================================================================ 本机事实
def binary_candidates():
    """本机 sing-box 二进制的查找顺序（服务端与客户端**同一套**）。

    服务端: SB_BIN（lib.sh 的默认值 $SB_ROOT/sing-box）
    客户端: CLIENT_BIN（client.sh 的默认值 $CLIENT_ROOT/core/sing-box）

    两份拷贝必须给出同一个答案 —— 同一个客户端在两处对"我是哪个内核的哪个版本"
    给出不同结果, 是这类互通里最难查的一类错。
    """
    cands = []
    if os.environ.get("SB_INTEROP_BIN"):
        cands.append(os.environ["SB_INTEROP_BIN"])
    for base in (os.environ.get("SB_BIN"), os.environ.get("CLIENT_BIN")):
        if base:
            cands.append(base)
    root = os.environ.get("CLIENT_ROOT")
    if root:
        cands.append(os.path.join(root, "core", "sing-box"))
    cands += ["sing-box", "/usr/local/bin/sing-box"]
    out = []
    for c in cands:
        if os.path.sep in c and not os.path.exists(c):
            continue
        if c not in out:
            out.append(c)
    return out


def kernel_version_text(bins=None):
    """跑 `sing-box version` → (版本号, 发行版标签)。探测不到返回 ("", "")。

    **真探测, 不写死**。真实输出形如::

        sing-box version 1.14.2
        Environment: go1.26.8 linux/arm64
        Tags: with_gvisor,with_quic,...

    发行版标签取首行**首个词**小写（官方二进制自报 `sing-box` → `sing-box`）,
    与 `src/client/compat2.py:parse_version_output` 取的是同一个词（那里把它
    映射成 compat 的 `upstream`）—— 声明里那个标签必须能在客户端侧一对一地
    重现, 否则"声明匹配上了、能力判定却按另一个名字走"。

    `SB_INTEROP_VERSION` 只为本项目既有的测试/离线场景预留（与
    `SB_COMPAT_VERSION` 同精神）: 生产路径永远真读。
    """
    forced = os.environ.get("SB_INTEROP_VERSION", "").strip()
    if forced:
        return forced, "sing-box"
    for b in (bins if bins is not None else binary_candidates()):
        try:
            p = subprocess.run([b, "version"], capture_output=True, text=True,
                               timeout=10)
            text = ((p.stdout or "") + (p.stderr or "")).strip()
        except Exception:                                        # noqa: BLE001
            continue
        if not text:
            continue
        first = text.splitlines()[0].strip()
        name = normalize_label(first.split(" ", 1)[0]) if first.split(" ", 1) else ""
        ver = ""
        m = re.search(r"\bversion\s+(\S+)", first)
        if m:
            ver = m.group(1).lstrip("vV")
        else:
            m2 = re.search(r"(\d+\.\d+\.\d+\S*)", first)
            ver = m2.group(1) if m2 else ""
        if not name:
            continue
        return ver, name
    return "", ""


def self_facts(prefix=None) -> dict:
    """本机内核事实: {kernel, distribution, version, ok, note}。

    `ok=False` 表示探测不出来 —— 调用方**必须**把它当"不知道"（服务端不产出
    原生、客户端走普通话）, 不许退回一个写死的默认发行版。
    """
    env = os.environ
    old = env.get("SB_INTEROP_BIN")
    if prefix:
        env["SB_INTEROP_BIN"] = prefix
    try:
        ver, name = kernel_version_text()
    finally:
        if prefix:
            if old is None:
                env.pop("SB_INTEROP_BIN", None)
            else:
                env["SB_INTEROP_BIN"] = old
    if not name:
        return {"kernel": "sing-box", "distribution": "", "version": "",
                "ok": False, "note": "sing-box 二进制探测不到（版本行取不到）"}
    # 官方二进制的首词就是 `sing-box`; 别的名字按 fork 处理（compat2 同口径）。
    return {"kernel": "sing-box", "distribution": name, "version": ver,
            "ok": True, "note": ""}


# ================================================================ CLI
def _usage():
    return ("用法:\n"
            "  interop.py declare --kernel K --distribution D [--version V]\n"
            "                     [--url-sing-box URL ...] --url <订阅地址>\n"
            "  interop.py parse <订阅地址>\n"
            "  interop.py decide <订阅地址> [--kernel K] [--distribution D]\n"
            "  interop.py self\n")


def main(argv):
    import json
    if len(argv) < 2:
        print(_usage(), file=sys.stderr)
        return 2
    cmd = argv[1]

    def opt(name, default=""):
        return argv[argv.index(name) + 1] if name in argv and \
            argv.index(name) + 1 < len(argv) else default

    if cmd == "self":
        print(json.dumps(self_facts(), ensure_ascii=False))
        return 0
    if cmd == "parse":
        if len(argv) < 3:
            print(_usage(), file=sys.stderr)
            return 2
        d = parse_declaration(argv[2])
        print(json.dumps(d, ensure_ascii=False))
        return 0
    if cmd == "decide":
        if len(argv) < 3:
            print(_usage(), file=sys.stderr)
            return 2
        facts = self_facts()
        k = opt("--kernel", facts["kernel"])
        dist = opt("--distribution", facts["distribution"])
        d = parse_declaration(argv[2])
        choice, reason, url, detail = decide(d, k, dist)
        print(json.dumps({"choice": choice, "reason": reason, "url": url,
                          "detail": detail, "mine": {"kernel": k,
                                                     "distribution": dist},
                          "declaration": d}, ensure_ascii=False))
        return 0
    if cmd == "declare":
        urls = {}
        for i, a in enumerate(argv):
            if a.startswith("--url-"):
                urls[a[len("--url-"):]] = opt(a)
        decl = build_declaration(opt("--kernel"), opt("--distribution"),
                                 opt("--version"),
                                 formats=opt("--formats", FORMAT_URI).split(","),
                                 urls=urls)
        print(declare_url(opt("--url"), decl))
        return 0
    print(_usage(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
