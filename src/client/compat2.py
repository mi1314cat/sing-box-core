#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""compat2.py — `proxy-node-compat` × SB 客户端 的适配层（**唯一判定点**）。

照 X 客户端已跑通的那套做（见 proxy-node-compat/research/integration/x-client-integration.md）,
但内核换成 sing-box, 并且多了一条 sing-box 特有的输入: **build tags**。

职责边界（一句话: 判定只在 compat 发生一次）:
  * 本模块**不写任何能力规则**。节点 → Universal Node Profile → check_node(profile, Target)。
  * 只做两件"策略"上的事, 外加文案渲染:
      1. compat 判 UNKNOWN 且没有任何确定结论 → **退回旧判定**（UNKNOWN 是"我们没有依据",
         不是"不能用"）;
      2. 其余情况取**更差者** —— compat 只许收紧, 不许放宽; 放宽会被挡下并记进 downgrades。
  * 版本与 build tags **真探测**: 读 `sing-box version` 的第一行与 `Tags:` 行。
    探测不到就给 None（未知, 不是"空"）→ compat 判 UNKNOWN → 自动回退旧判定。

一键回滚: `SB_COMPAT_ENGINE=legacy`（不改代码、不改文件）。适配层任何异常都自动落回旧判定。

命令行:
    compat2.py version [--bin P]                    目标四元组（真探测结果）
    compat2.py check-uri <uri>                      单条分享链接: compat / 旧判定 / 合并
    compat2.py check-json <file>                    单个 sing-box JSON 片段: 逐出站判定
    compat2.py filter-json <in> [--out O] [--report R] [--prefix P]
                                                    按 compat 过滤一份 sing-box JSON（供 client.sh 用）
    compat2.py compare <uri>                        旧 vs compat vs 合并（同 check-uri, 人读格式）
    compat2.py selftest                             自检（回归脚本 tools/check_compat_wiring.sh 会调）
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse as up

_HERE = os.path.dirname(os.path.abspath(__file__))
_LIB = os.path.join(_HERE, "lib")
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)

import proxy_node_compat as pnc                                       # noqa: E402
from proxy_node_compat import (Feature, NodeProfile, Presence,        # noqa: E402
                              Provenance, Registry, Target, evaluate)
from proxy_node_compat.uri import TRANSPORT_MAP                       # noqa: E402

KERNEL = "singbox"
ENGINE_ENV = "SB_COMPAT_ENGINE"      # legacy = 一键回滚
BIN_ENV = "SB_COMPAT_BIN"            # 显式指定内核二进制（默认按客户端目录找）
VER_ENV = "SB_COMPAT_VERSION"        # 仅供测试/离线判定, 生产路径不设置
TAGS_ENV = "SB_COMPAT_TAGS"          # 同上

# 状态好坏序（与 engine._STATUS_ORDER 对齐; 这里只用于"取更差者"这一条策略）
_ORDER = {"SUPPORTED": 0, "SUPPORTED_WITH_WARNING": 1, "SUPPORTED_WITH_LOSS": 2,
          "UNKNOWN": 3, "UNSUPPORTED": 4}


def _worst(a, b):
    if a is None:
        return b
    if b is None:
        return a
    return a if _ORDER.get(a, 9) >= _ORDER.get(b, 9) else b


# ==========================================================================
# 1 · 目标四元组: sing-box 版本 + build tags（真读, 不写死）
# ==========================================================================
def find_kernel_bin(explicit=None):
    """按"客户端真实布局"找内核: 显式参数 > SB_COMPAT_BIN > CLIENT_BIN >
    $CLIENT_ROOT/core/sing-box > PATH。"""
    cands = [explicit, os.environ.get(BIN_ENV), os.environ.get("CLIENT_BIN"),
             (os.path.join(os.environ["CLIENT_ROOT"], "core", "sing-box")
              if os.environ.get("CLIENT_ROOT") else None),
             os.path.join(_HERE, "..", "..", "core", "sing-box")]
    for c in cands:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return os.path.abspath(c)
    for d in (os.environ.get("PATH") or "").split(os.pathsep):
        p = os.path.join(d, "sing-box")
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def parse_version_output(text):
    """`sing-box version` → 四元组片段。

    真实输出形如::

        sing-box version 1.14.2
        Environment: go1.26.8 linux/arm64
        Tags: with_gvisor,with_quic,with_utls,...
        Revision: af6e64c3b69e6132ebaee0e1a3d24e93903f6709

    坑: **Tags 行可能整行不存在**（自编译不带任何 tag）。这时 build_tags 必须给
    None（未知）而不是 []（空）—— compat 里 None=未知 → UNKNOWN, []=确定没有 →
    Reality 会被判 BUILD_NOT_ENABLED。两者语义完全不同, 不能混。
    发行版: 第一行的首个词。官方二进制是 `sing-box` → upstream; 别的名字按 fork 处理
    （fork 不继承上游能力, compat 会整体判 UNKNOWN）。
    """
    name = version = revision = None
    tags = None
    for line in (text or "").splitlines():
        line = line.strip()
        if name is None:
            m = re.match(r"^(\S+)\s+version\s+(\S+)", line)
            if m:
                name = m.group(1)
                version = m.group(2).lstrip("vV")
                continue
        low = line.lower()
        if low.startswith("tags:"):
            raw = line.split(":", 1)[1].strip()
            tags = [t for t in raw.split(",") if t]
        elif low.startswith("revision:"):
            revision = line.split(":", 1)[1].strip()
    return {"name": name, "version": version, "build_tags": tags, "revision": revision}


def probe_kernel(bin_path=None, refresh=False):
    """真跑一次 `sing-box version`。跑不起来 → 全 None → compat 判 UNKNOWN。"""
    global _PROBE
    if _PROBE is not None and not refresh and bin_path is None:
        return _PROBE
    p = find_kernel_bin(bin_path)
    out = {"bin": p, "distribution": None, "version": None,
           "build_tags": None, "revision": None, "raw": "", "probe_ok": False}
    if p:
        try:
            r = subprocess.run([p, "version"], capture_output=True, text=True, timeout=15)
            if r.returncode == 0 and r.stdout.strip():
                out.update(parse_version_output(r.stdout))
                out["raw"] = r.stdout
                out["probe_ok"] = True
                # 官方二进制自报 `sing-box`; 别的名字按 fork 传下去（compat 不继承上游）
                out["distribution"] = ("upstream" if out["name"] == "sing-box"
                                       else (out["name"] or None))
        except (OSError, subprocess.SubprocessError):
            pass
    if bin_path is None:
        _PROBE = out
    return out


_PROBE = None


def target_of(bin_path=None, version=None, build_tags=None):
    """→ (Target, 探测结果)。VER_ENV/TAGS_ENV 只为测试与离线回归存在,
    生产路径（client.sh / to_sb.py）永远不设它们 —— 那就是"写死"。"""
    info = probe_kernel(bin_path)
    src = "probe"
    ver = version if version is not None else os.environ.get(VER_ENV) or info["version"]
    if version is None and os.environ.get(VER_ENV):
        src = "env-override(SB_COMPAT_VERSION)"
    if build_tags is None:
        if os.environ.get(TAGS_ENV) is not None:
            build_tags = [t for t in os.environ[TAGS_ENV].split(",") if t]
            src = src + "+env-override(SB_COMPAT_TAGS)"
        else:
            build_tags = info["build_tags"]
    tgt = Target(kernel=KERNEL, distribution=(info["distribution"] or "upstream"),
                 version=ver, build_tags=build_tags)
    meta = dict(info, target_source=src, distribution=(info["distribution"] or "upstream"),
                version=ver, build_tags=build_tags)
    return tgt, meta


_REG = None


def registry():
    global _REG
    if _REG is None:
        _REG = Registry.load(pnc.default_registry_path())
    return _REG


# ==========================================================================
# 2 · 节点 → Universal Node Profile
#      (URI 有原文就用 compat 自己的 parse_uri —— 保真最高; JSON 才走字段映射)
# ==========================================================================
_PROTOCOL_FEATURE = {
    "vless": "standard:vless", "vmess": "standard:vmess", "trojan": "standard:trojan",
    "shadowsocks": "standard:shadowsocks", "hysteria2": "standard:hysteria2",
    "tuic": "standard:tuic", "anytls": "standard:anytls", "shadowtls": "standard:shadowtls",
    "naive": "standard:naive", "socks": "standard:socks", "http": "standard:http",
}

# sing-box 出站里已被本适配层消费的键（其余一律进 extensions, 不变式 I2）
_CONSUMED = {"type", "tag", "server", "server_port", "tls", "transport", "flow",
             "multiplex", "detour", "outbounds", "default", "url", "interval",
             "method", "password", "uuid", "username", "alter_id", "security",
             "up_mbps", "down_mbps", "obfs", "server_ports", "congestion_control",
             "udp_relay_mode", "version", "udp_over_tcp", "plugin", "plugin_opts",
             "packet_encoding", "network", "local_address", "private_key",
             "peer_public_key", "pre_shared_key", "mtu"}


def profile_from_sb_outbound(ob, raw_uri=None, tag=None):
    """sing-box 出站 dict → NodeProfile（字段→feature 映射; 未建模的键进 extensions）。

    与 compat 的 parse_json_node 不同: 那个只把整份 JSON 塞进 extensions（不做判定）,
    所以"内核支持什么"这件事在 sing-box 侧本来没有输入。这里按 uri.py 的同一套
    TRANSPORT_MAP / 层级写法把字段映射成 feature, 不改写任何值。
    """
    if not isinstance(ob, dict):
        raise TypeError("outbound 必须是 dict")
    prof = NodeProfile(source_format="SINGBOX_JSON", raw_fields=dict(ob), raw_uri=raw_uri)
    prof.diagnostics.append({"code": "SB_OUTBOUND", "detail": tag or ob.get("tag") or "?"})

    sbtype = (ob.get("type") or "").lower()
    fid = _PROTOCOL_FEATURE.get(sbtype)
    if fid:
        prof.protocol = Feature(id=fid, presence=Presence.EXPLICIT,
                                provenance=Provenance.SINGBOX_JSON)
    elif sbtype:
        prof.add_extension("type", sbtype, "singbox-outbound",
                           "注册表里没有这个协议 feature（未知 ≠ 不支持）")

    tls = ob.get("tls") if isinstance(ob.get("tls"), dict) else None
    if tls and tls.get("enabled") is not False:
        feats = [Feature(id="standard:tls", presence=Presence.EXPLICIT,
                         provenance=Provenance.SINGBOX_JSON)]
        if isinstance(tls.get("reality"), dict) and tls["reality"].get("enabled") is not False:
            feats.append(Feature(id="standard:reality", presence=Presence.EXPLICIT,
                                 provenance=Provenance.SINGBOX_JSON))
        if tls.get("ech") or tls.get("ech_config_list"):
            feats.append(Feature(id="standard:ech", presence=Presence.EXPLICIT,
                                 provenance=Provenance.SINGBOX_JSON))
        if tls.get("insecure") is True:
            feats.append(Feature(id="standard:tls.allow_insecure", presence=Presence.EXPLICIT,
                                 provenance=Provenance.SINGBOX_JSON))
        for f in feats:
            prof.add_feature(f)

    tr = ob.get("transport") if isinstance(ob.get("transport"), dict) else None
    ttype = (tr or {}).get("type") if tr else None
    if not ttype:
        # sing-box 不写 transport 段 = 内核默认 TCP/raw。必须补上, 否则"链接里有 tcp、
        # 出站里没有"会被损失对比误报成"客户端把传输丢了"。
        prof.add_feature(Feature(id="standard:transport.tcp", presence=Presence.DEFAULTED,
                                 provenance=Provenance.SINGBOX_JSON,
                                 note="出站无 transport 段 = 内核默认 tcp"))
    else:
        tfid = TRANSPORT_MAP.get(str(ttype).lower())
        if tfid:
            prof.add_feature(Feature(id=tfid, presence=Presence.EXPLICIT,
                                     provenance=Provenance.SINGBOX_JSON))
        else:
            prof.add_extension("transport.type", ttype, "singbox-outbound",
                               "未知传输, 登记为 unknown: 命名空间 feature")
            prof.add_feature(Feature(id="unknown:transport.%s" % ttype,
                                     presence=Presence.EXPLICIT,
                                     provenance=Provenance.SINGBOX_JSON))

    if ob.get("flow"):
        prof.add_feature(Feature(id="standard:flow", presence=Presence.EXPLICIT,
                                 provenance=Provenance.SINGBOX_JSON))
    if isinstance(ob.get("multiplex"), dict) and ob["multiplex"].get("enabled"):
        prof.add_feature(Feature(id="standard:mux", presence=Presence.EXPLICIT,
                                 provenance=Provenance.SINGBOX_JSON))
    if sbtype == "vless" and (ob.get("encryption") or "").strip() not in ("", "none"):
        prof.add_feature(Feature(id="standard:vless.encryption", presence=Presence.EXPLICIT,
                                 provenance=Provenance.SINGBOX_JSON))

    for k, v in ob.items():
        if k not in _CONSUMED:
            prof.add_extension(k, v, "singbox-outbound")
    return prof


def profile_from_uri(uri):
    return pnc.parse_uri(uri)


# ==========================================================================
# 3 · 旧判定（SB 客户端现有实现, 一行都没改; 这里只是**调用**它）
# ==========================================================================
def _load_module(path, name):
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def find_outbound_uri():
    """面板侧的严格解析器（"不支持的传输方式 type='xhttp'（本面板支持 …）"就出自它）。
    客户端机器上一般没有它 —— 找不到就算了, 旧判定退回 to_sb.py。"""
    cands = [os.environ.get("OB_URI_PY"),
             os.path.join(_HERE, "..", "conf", "outbound_uri.py"),          # 仓库内
             os.path.join(_HERE, "outbound_uri.py"),
             os.path.join(os.environ.get("SB_CONF_DIR", ""), "outbound_uri.py"),
             os.path.join(os.environ.get("SB_ROOT", ""), "conf", "outbound_uri.py"),
             os.path.join(os.environ.get("CLIENT_ROOT", ""), "share-state", "outbound_uri.py")]
    for c in cands:
        if c and os.path.isfile(c):
            return os.path.abspath(c)
    return None


def legacy_uri(uri):
    """返回 {verdict, detail, source, outbound} —— 现有实现的结论, 原样搬运。

    * panel 列: 面板解析器 outbound_uri.py（有就用; 它的报错文案是"说了缺什么、支持什么"的来源）
    * client 列: to_sb.uri_to_outbound —— **客户端导入时真正跑的那条路**, 合并用的就是它
    """
    out = {"verdict": "UNKNOWN", "detail": "", "source": "", "outbound": None,
           "panel": None, "client": None}

    # ---- client: to_sb.py（真正决定"能不能导入"的那一段）
    ts = os.environ.get("SB_TO_SB") or os.path.join(_HERE, "to_sb.py")
    if os.path.isfile(ts):
        try:
            mod = _load_module(ts, "_sb_to_sb_legacy")
            ob = mod.uri_to_outbound(uri)
            if ob:
                out["client"] = {"verdict": "SUPPORTED",
                                 "detail": "to_sb.py 转换出 type=%s" % ob.get("type")}
                out["outbound"] = ob
                out["source"] = "to_sb.py"
            else:
                scheme = uri.split("://", 1)[0].lower()
                out["client"] = {"verdict": "UNSUPPORTED",
                                 "detail": "to_sb.py 不支持 %s://（或 host/port 缺失）" % scheme}
        except Exception as e:                                    # noqa: BLE001
            out["client"] = {"verdict": "UNKNOWN",
                             "detail": "to_sb.py 异常: %s: %s" % (type(e).__name__, e)}

    # ---- panel: outbound_uri.py（只作参照, 不参与合并 —— 它不是客户端行为）
    p = find_outbound_uri()
    if p:
        scheme = uri.split("://", 1)[0].lower()
        try:
            mod = _load_module(p, "_sb_outbound_uri_legacy")
            parser = mod.PARSERS.get(scheme)
            if parser is None:
                out["panel"] = {"verdict": "UNKNOWN",
                                "detail": "面板解析器没有 %s://（本面板支持: %s）"
                                          % (scheme, "/".join(mod.SUPPORTED_SCHEMES))}
            else:
                body, _, frag = uri.partition("#")
                parser(body, up.unquote(frag).strip())
                out["panel"] = {"verdict": "SUPPORTED", "detail": "面板解析器通过"}
        except Exception as e:                                    # noqa: BLE001
            code = getattr(e, "reason_code", None) or type(e).__name__
            out["panel"] = {"verdict": "UNSUPPORTED",
                            "detail": str(e) if str(e) else code}

    # 合并用的"旧判定"**只能是客户端真实行为**（to_sb.py）。面板解析器是另一个
    # surface, 把它一起取更差者会凭空收紧导入（假 UNSUPPORTED）。面板的结论照样
    # 带出来（legacy.panel）, 两边打架时记 warning, 由人决定 —— 不替用户判死。
    pick = out["client"] or out["panel"] or {}
    out["verdict"] = pick.get("verdict", "UNKNOWN")
    out["detail"] = pick.get("detail", "旧判定无结论")
    if not out["source"]:
        out["source"] = "outbound_uri.py" if out["client"] is None else ""
    return out


def legacy_outbound(ob):
    """sing-box JSON 路径下客户端**没有**逐节点判定（只靠 `sing-box check` 与真实拨测）,
    所以旧判定是"无意见", 合并时 compat 的结论直接生效。"""
    return {"verdict": "UNKNOWN", "source": "无（客户端只做整份 sing-box check + 真实拨测）",
            "detail": "客户端不逐节点判定"}


# ==========================================================================
# 4 · reason_code → 文案（保住"说了缺什么、支持什么"这个优点）
# ==========================================================================
_TRANSPORT_FEATURES = ["standard:transport.tcp", "standard:transport.ws",
                       "standard:transport.grpc", "standard:transport.http_h2",
                       "standard:transport.httpupgrade", "standard:transport.quic",
                       "standard:xhttp", "standard:mkcp"]
_FEATURE_SHORT = {"standard:transport.tcp": "tcp", "standard:transport.ws": "ws",
                  "standard:transport.grpc": "grpc", "standard:transport.http_h2": "http(h2)",
                  "standard:transport.httpupgrade": "httpupgrade",
                  "standard:transport.quic": "quic", "standard:xhttp": "xhttp",
                  "standard:mkcp": "mkcp"}


def feature_verdict(fid, tgt):
    """"这个内核在这个版本/构建上支不支持 X" —— 仍然问 compat, 不在适配层写规则。

    做法: 造一个只含该 feature 的最小 profile 调 evaluate（同一判定点）。
    返回 "SUPPORTED" / "SUPPORTED_WITH_LOSS" / "UNSUPPORTED" / "UNKNOWN"（取 config 层）。
    """
    prof = NodeProfile(source_format="SINGBOX_JSON", raw_fields={"_synthetic": fid},
                       features=[Feature(id=fid, provenance=Provenance.EXTENSION)])
    try:
        res = evaluate(prof, tgt, registry())
    except Exception:                                             # noqa: BLE001
        return "UNKNOWN"
    return res.levels.get("config", "UNKNOWN")


def supported_transports(tgt):
    """按 _TRANSPORT_FEATURES 的固定顺序枚举"这个内核支持哪些传输" —— 逐条问 compat。"""
    out = []
    for fid in _TRANSPORT_FEATURES:
        if feature_verdict(fid, tgt) in ("SUPPORTED", "SUPPORTED_WITH_LOSS"):
            out.append(_FEATURE_SHORT[fid])
    return out


def transport_hint(tgt):
    """→ "本内核可用: …（… 注册表未收录, 未知≠不支持）"

    为什么要把"未收录"单列: 注册表只钉了有证据的那几条传输（ws/grpc/httpupgrade）,
    tcp/http(h2)/quic 没有规则。只报有规则的那几条会让人误以为 tcp 不可用 ——
    UNKNOWN 是"我们没有依据", 不是"不支持"。这句话必须说清楚。
    """
    yes, unknown = [], []
    for fid in _TRANSPORT_FEATURES:
        short = _FEATURE_SHORT[fid]
        v = feature_verdict(fid, tgt)
        if v in ("SUPPORTED", "SUPPORTED_WITH_LOSS"):
            yes.append(short)
        elif v == "UNKNOWN":
            unknown.append(short)
        else:
            pass                     # UNSUPPORTED 就是不列（它才是"缺什么"）
    s = "本内核可用: " + ("、".join(yes) if yes else "（无）")
    if unknown:
        s += "（%s 注册表未收录, 未知≠不支持）" % "、".join(unknown)
    return s


_RULE_TEXT = {
    "singbox.xhttp.never":
        "不支持的传输方式 type='xhttp'（sing-box 内核从来没有 xhttp/splithttp 出站）。{alts}",
    "singbox.mkcp.never":
        "不支持的传输方式 type='kcp/mkcp'（sing-box 没有 mKCP 出站）。{alts}",
    "singbox.ss_reality.never":
        "shadowsocks 出站没有 tls/reality 字段 —— ss+Reality 这个组合在 sing-box 上不存在"
        "（内核报 unknown field \"tls\"）。可用: 换 vless/vmess/trojan+Reality, 或去掉 security",
    "singbox.vless.encryption.never":
        "vless 的 encryption（VLESS Encryption）sing-box 未实现 —— 链接里的 encryption "
        "会被丢弃/或配置期报错。本内核可用: vless 明文（无 encryption）",
    "singbox.reality.build_tags":
        "该 sing-box 构建缺少 with_utls —— Reality/uTLS 没编进内核, 配置期就会失败",
    "singbox.ech.representation":
        "ECH 的表示法不一致: sing-box 的 tls.ech.config 要 PEM（-----BEGIN ECH CONFIGS-----）, "
        "不是 base64 —— 喂 base64 会 FATAL: invalid ECH configs pem",
    "singbox.mux.semantics":
        "mux 在三家内核里不同构（Xray=mux.cool / mihomo=smux / sing-box=multiplex）, "
        "跨内核搬运不保证语义一致; 且 sing-box 的 multiplex 与 ws/grpc 的语义也不完全对齐",
}

_REASON_TEXT = {
    "KERNEL_NEVER_SUPPORTED": "该内核从来没有支持过这个能力（不是版本问题, 换版本也没用）",
    "KERNEL_REMOVED": "该字段在新版内核里已移除, 配置期就会报错（用户看得见）",
    "BUILD_NOT_ENABLED": "这个内核**构建**没有编入所需组件（build tags 缺项）",
    "RUNTIME_CONDITION_NOT_MET": "运行期条件没满足, 连接会失败",
    "SEMANTIC_MISMATCH": "语义不一致: 配置能过 check, 但运行期行为与链接的意图不同",
    "UNKNOWN_CAPABILITY": "没有覆盖该组合的证据（未知 ≠ 不支持, 所以不据此判死）",
}


def _rule_of(rid):
    for r in registry().rules:
        if r.rule_id == rid:
            return r
    return None


def _negative_rules(res, tgt):
    """哪几条**被应用的规则**真的给出了否定结论。

    为什么要这一步: rules_applied 只说明"这条规则参与了判定", 参与 ≠ 出问题。
    （坑: `singbox.reality.build_tags` 在 with_utls 齐备时也是"参与", 直接按
    rules_applied 渲染文案会让每个 Reality 节点都显示"构建缺少 with_utls"。）
    判据只看结果侧: 损失/警告里点了名的规则, 以及"段的 reason_code 真的出现在
    reason_codes 里"或"段的 requires_build_tags 确实没满足"的规则。
    """
    neg = set()
    for l in res.losses:
        if isinstance(l, dict) and l.get("rule"):
            neg.add(l["rule"])
    for w in res.warnings:
        if isinstance(w, dict) and w.get("rule"):
            neg.add(w["rule"])
    tags = tgt.build_tags
    rcs = set(res.reason_codes or [])
    for rid in res.rules_applied:
        rule = _rule_of(rid)
        if rule is None:
            continue
        for seg in rule.segments:
            if seg.requires_build_tags and tags is not None \
                    and not set(seg.requires_build_tags).issubset(set(tags)):
                neg.add(rid)
            if seg.reason_code and seg.reason_code in rcs:
                neg.add(rid)
    return neg


def render_reason(res, tgt, prof=None):
    """把 EvaluationResult 翻成"人看得懂 + 说了缺什么、支持什么"的文案。

    **只由 reason_code / rules_applied / losses / warnings 生成**, 不在这里判任何能力。
    """
    lines, seen = [], set()
    alts = None
    neg = _negative_rules(res, tgt)
    for rid in res.rules_applied:
        tpl = _RULE_TEXT.get(rid)
        if not tpl or rid not in neg:
            continue
        if "{alts}" in tpl:
            alts = alts if alts is not None else transport_hint(tgt)
            tpl = tpl.format(alts=alts)
        if tpl not in seen:
            seen.add(tpl)
            lines.append(tpl)
    for rc in res.reason_codes:
        t = _REASON_TEXT.get(rc)
        # "没有证据"这句话只在 compat 真的没有结论时才说 —— 有确定结论时它是噪音
        if rc == "UNKNOWN_CAPABILITY" and res.status not in ("UNKNOWN",):
            continue
        if t and t not in seen:
            seen.add(t)
            lines.append(t)
    if res.message:
        for part in [p.strip() for p in res.message.split(";") if p.strip()]:
            if part not in seen:
                seen.add(part)
                lines.append(part)
    for ls in res.losses:
        t = "会丢能力: %s" % (ls.get("what") or ls.get("feature"))
        if t not in seen:
            seen.add(t)
            lines.append(t)
    for wn in res.warnings:
        d = wn.get("detail") if isinstance(wn, dict) else str(wn)
        if d and d not in seen:
            seen.add(d)
            lines.append(d)
    return lines


# ==========================================================================
# 5 · 双跑 + 合并（compat 只许收紧）
# ==========================================================================
def _compat_run(prof, tgt):
    res = evaluate(prof, tgt, registry())
    d = res.to_dict()
    d["evidence"] = [{"id": e.get("id"), "type": e.get("type"),
                      "confidence": e.get("confidence"), "claim": e.get("claim")}
                     for e in d.get("evidence") or []]
    return res, d


def merge_verdict(compat_status, legacy_v, reason_codes, res):
    """两条策略（X 客户端那套的 sing-box 版）:

    1. compat 判 UNKNOWN / SUPPORTED_WITH_WARNING 且没有任何确定结论 → 退回旧判定。
       理由: UNKNOWN 是"我们没有依据", 不是"不能用"; 拿它推翻客户端已有的依据会让
       本来能用的节点凭空变成不可用。
    2. 其余取更差者。compat 比旧判定宽 → 取旧判定, 并记进 downgrades（保险丝留痕）。
    """
    ls = legacy_v.get("verdict", "UNKNOWN")
    # "没有确定结论" 的判据: 状态 UNKNOWN、没有损失、没有 silent/hard 失败模式,
    # 且原因码只有"没证据"这一类。**不能只看 status**: compat 判 UNKNOWN 时按惯例
    # 一定带一个 UNKNOWN_CAPABILITY（"注册表没有覆盖该组合的规则"）, 那是"我们没依据",
    # 不是"不能用" —— 拿它当结论会把本来能用的节点显示成未知。
    undecided = (compat_status == "UNKNOWN" and not res.losses
                 and not res.failure_mode
                 and all(rc == "UNKNOWN_CAPABILITY" for rc in (res.reason_codes or [])))
    if undecided:
        return (ls if ls != "UNKNOWN" else "UNKNOWN",
                "legacy（compat 判 UNKNOWN, 无确定结论）", [])
    if ls == "UNKNOWN":
        return compat_status, "compat（旧判定无意见）", []
    if _ORDER.get(ls, 9) > _ORDER.get(compat_status, 9):
        dw = [{"what": "compat 判定比旧判定宽, 已按'只许收紧'取旧判定",
               "compat": compat_status, "legacy": ls,
               "reason_codes": reason_codes}]
        return ls, "legacy（比 compat 更差, 取更差者）", dw
    return compat_status, "compat", []


def conversion_losses(uri_prof, ob_prof):
    """**客户端转换环节**丢的东西（不是内核能力）: 链接里有、写出配置里没有。

    为什么必须单列: to_sb.py 遇到没写的传输是**静默降级**（xhttp → tcp）, 内核
    那边看起来一切正常, 只有连不上。compat 判的是"节点是什么", 这里判的是
    "客户端有没有照做" —— 两件事, 所以分开报。
    """
    if uri_prof is None or ob_prof is None:
        return []
    have = set(ob_prof.feature_ids())
    out = []
    for fid in uri_prof.feature_ids():
        if fid in have or not fid.startswith("standard:"):
            continue
        out.append({"feature": fid,
                    "what": "分享链接里有 %s, 写出的出站里没有 —— 客户端转换环节丢了"
                            "（内核侧不会报错, 只会连不上）" % fid})
    ut = [f for f in uri_prof.feature_ids() if f.startswith("standard:transport.")]
    ot = [f for f in have if f.startswith("standard:transport.")]
    if ut and ot and set(ut) != set(ot):
        out.append({"feature": ut[0],
                    "what": "传输方式被改写: %s → %s（不是同一个东西）"
                            % (ut[0].split(".")[-1], ot[0].split(".")[-1])})
    return out


def judge(uri=None, outbound=None, tag=None, tgt=None, engine=None):
    """唯一入口。uri 与 outbound 至少给一个; 两个都给 = "原文 + 客户端写出来的配置"。

    返回结构（losses/unknowns/warnings/extensions/raw_uri 一定带出）::

        {ok, verdict, engine, verdict_source, reason_codes, message[],
         raw_uri, target{...}, compat{...}, legacy{...},
         extensions[], client_losses[], downgrades[], warnings[], unknowns[]}
    """
    tgt = tgt or target_of()[0]
    engine = (engine or os.environ.get(ENGINE_ENV) or "compat").strip().lower()
    explicit_outbound = outbound is not None
    res = {"ok": True, "verdict": "UNKNOWN", "engine": engine, "verdict_source": "",
           "reason_codes": [], "message": [], "raw_uri": None, "target": tgt.to_dict(),
           "compat": None, "legacy": None, "extensions": [], "client_losses": [],
           "downgrades": [], "warnings": [], "unknowns": [], "tag": tag}

    prof = None
    prof_json = None
    if outbound is not None:
        prof_json = profile_from_sb_outbound(outbound, raw_uri=uri, tag=tag)
    if uri:
        try:
            prof = profile_from_uri(uri)
        except Exception as e:                                    # noqa: BLE001
            prof = None
            res["warnings"].append({"code": "URI_PARSE_FAILED",
                                    "detail": "%s: %s" % (type(e).__name__, e)})
    if prof is None:
        prof = prof_json
    if prof is None:
        res.update(ok=False, verdict="UNSUPPORTED",
                   message=["既没有可解析的分享链接, 也没有出站配置"])
        return res
    res["raw_uri"] = prof.raw_uri or uri
    res["extensions"] = list(prof.extensions)
    if prof_json is not None and prof is not prof_json:
        # 两份 profile 的 extensions 合并（原文那份 + 出站那份）, 不丢键
        keys = {e.get("key") for e in res["extensions"]}
        res["extensions"] += [e for e in prof_json.extensions if e.get("key") not in keys]

    # ---- 旧判定（客户端真实行为）
    if uri:
        leg = legacy_uri(uri)
        if outbound is None:
            outbound = leg.get("outbound")       # 客户端本来会写出来的那份（用于损失对比）
    else:
        leg = legacy_outbound(outbound)
    res["legacy"] = {k: v for k, v in leg.items() if k != "outbound"}
    pv = (leg.get("panel") or {}).get("verdict")
    if pv == "UNSUPPORTED" and leg.get("verdict") == "SUPPORTED":
        res["warnings"].append({
            "code": "LEGACY_SURFACES_DISAGREE",
            "detail": "面板解析器判不支持（%s）, 客户端 to_sb.py 能转 —— 两个 surface "
                      "已有分歧, 未据此改判定" % (leg.get("panel") or {}).get("detail", "")})

    if engine == "legacy":                       # 一键回滚: 不跑 compat
        res["verdict"] = leg.get("verdict", "UNKNOWN")
        res["verdict_source"] = "legacy（SB_COMPAT_ENGINE=legacy 回滚开关）"
        res["ok"] = res["verdict"] != "UNSUPPORTED"
        res["message"] = [leg.get("detail") or "回滚到旧判定"]
        return res

    try:
        cres, cdict = _compat_run(prof, tgt)
    except Exception as e:                                        # noqa: BLE001
        # 适配层任何异常都必须落回旧判定, 绝不阻断导入
        res["warnings"].append({"code": "COMPAT_FAILED",
                                "detail": "%s: %s" % (type(e).__name__, e)})
        res["verdict"] = leg.get("verdict", "UNKNOWN")
        res["verdict_source"] = "legacy（compat 异常, 自动回退）"
        res["ok"] = res["verdict"] != "UNSUPPORTED"
        res["message"] = [leg.get("detail") or "compat 异常"]
        return res

    res["compat"] = cdict
    res["reason_codes"] = list(cdict["reason_codes"])
    res["unknowns"] = list(cdict["unknowns"])
    res["warnings"] = res["warnings"] + list(cdict["warnings"])
    verdict, source, downgrades = merge_verdict(cdict["status"], leg, cdict["reason_codes"], cres)
    res["verdict"] = verdict
    res["verdict_source"] = source
    res["downgrades"] = downgrades
    res["ok"] = verdict != "UNSUPPORTED"
    res["message"] = render_reason(cres, tgt, prof)
    if verdict == "UNSUPPORTED" and not res["message"]:
        res["message"] = [leg.get("detail") or "compat 判定不可用"]

    # ---- 客户端转换环节的损失（"链接里是什么" vs "客户端写出来什么"）
    #      不是内核能力, 所以单列 client_losses 并附在文案后面 —— 内核侧不会报错,
    #      只有连不上, 用户最难自己查出来的就是这一类。
    if uri:
        if explicit_outbound:
            ref = prof_json
        elif leg.get("outbound"):
            ref = profile_from_sb_outbound(leg["outbound"])
        else:
            ref = None
        if ref is not None:
            res["client_losses"] = conversion_losses(prof, ref)
            if res["ok"]:
                for cl in res["client_losses"]:
                    res["message"].append(cl["what"])
    return res


def filter_profile(data, tgt=None, engine=None, prefix=""):
    """整份 sing-box JSON → (保留下来的 outbounds, 报告)。UNSUPPORTED 的丢掉并说明原因。"""
    obs = [o for o in (data.get("outbounds") or []) if isinstance(o, dict)]
    keep, nodes = [], []
    for ob in obs:
        t = (ob.get("type") or "").lower()
        if t in ("selector", "urltest", "direct", "block", "dns"):
            keep.append(ob)
            continue
        r = judge(outbound=ob, tag=ob.get("tag"), tgt=tgt, engine=engine)
        if prefix and ob.get("tag"):
            pass                                   # tag 前缀由 to_sb.py 处理, 这里不动
        nodes.append({"tag": ob.get("tag"), "type": ob.get("type"),
                      "verdict": r["verdict"], "verdict_source": r["verdict_source"],
                      "reason_codes": r["reason_codes"], "message": r["message"],
                      "losses": (r["compat"] or {}).get("losses", []),
                      "unknowns": r["unknowns"], "extensions": r["extensions"],
                      "raw_uri": r["raw_uri"], "ok": r["ok"],
                      "verdict_engine": r["engine"]})
        if r["ok"]:
            keep.append(ob)
    tgt = tgt or target_of()[0]
    rep = {"target": tgt.to_dict(), "engine": (engine or os.environ.get(ENGINE_ENV) or "compat"),
           "total": len(nodes), "kept": len(keep), "dropped": len(nodes) - len(keep),
           "nodes": nodes,
           "dropped_nodes": [n for n in nodes if not n["ok"]],
           "with_loss": [n for n in nodes if n["ok"] and n["losses"]]}
    return keep, rep


def report_lines(rep, limit=8):
    """给人看的摘要（client.sh 直接打印）。"""
    out = []
    for n in rep.get("dropped_nodes", [])[:limit]:
        out.append("  ✗ 跳过 %s（%s）: %s" % (n.get("tag"), n.get("type"),
                                            "；".join(n.get("message") or []) or "不支持"))
    for n in rep.get("with_loss", [])[:limit]:
        out.append("  ⚠ %s: %s" % (n.get("tag"), "；".join(n.get("message") or [])[:200]))
    if rep.get("dropped", 0) > limit:
        out.append("  …（还有 %d 条同类, 见 --report）" % (rep["dropped"] - limit))
    return out


# ==========================================================================
# 6 · CLI
# ==========================================================================
def _dump(o):
    print(json.dumps(o, ensure_ascii=False, indent=1))


def _load_sb_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def cmd_version(a):
    tgt, meta = target_of(a.bin)
    _dump({"target": tgt.to_dict(), "probe": meta})
    return 0


def cmd_check_uri(a):
    r = judge(uri=a.uri, tgt=target_of(a.bin)[0], engine=a.engine)
    if a.json:
        _dump(r)
    else:
        print("%s  →  %s  [%s]" % (a.uri.split("://", 1)[0], r["verdict"], r["verdict_source"]))
        for l in r["message"]:
            print("   · %s" % l)
        for l in r["client_losses"]:
            print("   ! %s" % l["what"])
    return 0 if r["ok"] else 1


def cmd_check_json(a):
    d = _load_sb_json(a.path)
    keep, rep = filter_profile(d, tgt=target_of(a.bin)[0], engine=a.engine)
    if a.json:
        _dump(rep)
    else:
        print("共 %d 个出站, 保留 %d, 跳过 %d" % (rep["total"], rep["kept"], rep["dropped"]))
        for n in rep["nodes"]:
            print("  %-28s %-11s %-8s %s" % (n["tag"], n["type"], n["verdict"],
                                             "；".join(n["message"])[:110]))
    return 0


def cmd_filter_json(a):
    d = _load_sb_json(a.path)
    keep, rep = filter_profile(d, tgt=target_of(a.bin)[0], engine=a.engine)
    if a.prefix:
        for ob in keep:
            if ob.get("tag"):
                ob["tag"] = a.prefix + ob["tag"]
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            json.dump({"outbounds": keep}, fh, ensure_ascii=False, indent=1)
    else:
        _dump({"outbounds": keep})
    if a.report:
        with open(a.report, "w", encoding="utf-8") as fh:
            json.dump(rep, fh, ensure_ascii=False, indent=1)
    for l in report_lines(rep):
        sys.stderr.write(l + "\n")
    return 0


def cmd_compare(a):
    r = judge(uri=a.uri, tgt=target_of(a.bin)[0], engine=a.engine)
    print("链接 : %s" % a.uri)
    print("旧判定: %s  —— %s" % ((r["legacy"] or {}).get("verdict"),
                                 (r["legacy"] or {}).get("detail")))
    print("compat: %s" % ((r["compat"] or {}).get("status")))
    print("合并  : %s  [%s]" % (r["verdict"], r["verdict_source"]))
    for l in r["message"]:
        print("   · %s" % l)
    for cl in r["client_losses"]:
        print("   ! 客户端转换丢的: %s" % cl["what"])
    if r["downgrades"]:
        print("   ! 保险丝: %s" % json.dumps(r["downgrades"], ensure_ascii=False))
    if r["extensions"]:
        print("   · extensions: %s" % "、".join(str(e.get("key")) for e in r["extensions"]))
    return 0


def cmd_selftest(a):
    """自检: 目标探测 / 双跑 / 回滚 / 文案 / 不写规则。"""
    fails = []
    tgt, meta = target_of(a.bin)
    if not meta.get("probe_ok") and not os.environ.get(VER_ENV):
        fails.append("内核版本探测失败（既没有 sing-box 二进制也没有 %s）" % VER_ENV)

    def eq(got, want, what):
        if got != want:
            fails.append("%s: got=%r want=%r" % (what, got, want))

    # 1) 永远不支持的传输: compat 必须判死, 且文案要说出"支持什么"
    r = judge(uri="vless://11111111-1111-1111-1111-111111111111@example.com:443"
                  "?type=xhttp&security=tls&sni=a.example.com#xhttp", tgt=tgt)
    eq(r["verdict"], "UNSUPPORTED", "xhttp 必须 UNSUPPORTED")
    if "KERNEL_NEVER_SUPPORTED" not in r["reason_codes"]:
        fails.append("xhttp 的 reason_code 丢了")
    if not any("可用" in m for m in r["message"]):
        fails.append("xhttp 文案没有说出'支持什么'")
    if r["raw_uri"] is None:
        fails.append("raw_uri 没带出")

    # 2) 正常节点: 必须有 losses/unknowns 字段（可以为空, 但键要在）
    r2 = judge(uri="vless://11111111-1111-1111-1111-111111111111@example.com:443"
                   "?type=ws&security=tls&sni=a.example.com&path=%2Fws#ws", tgt=tgt)
    for k in ("losses", "unknowns", "extensions", "raw_uri", "downgrades"):
        if (r2["compat"] or {}).get(k) is None and k in ("losses", "unknowns"):
            fails.append("compat 结果缺字段 %s" % k)
    eq(r2["verdict"], "SUPPORTED", "vless+ws+tls 必须 SUPPORTED")

    # 3) 回滚开关: 同一个链接在 legacy 引擎下不出现 compat 段
    r3 = judge(uri="vless://11111111-1111-1111-1111-111111111111@example.com:443"
                   "?type=xhttp&security=tls#xhttp", tgt=tgt, engine="legacy")
    eq(r3["engine"], "legacy", "回滚开关 engine")
    if r3["compat"] is not None:
        fails.append("回滚开关下不该跑 compat")
    if r3["verdict"] != "SUPPORTED":
        fails.append("回滚开关下必须回到旧判定（to_sb 认 xhttp 链接）")

    # 4) sing-box JSON 路径: 出站里的 xhttp 不存在（内核根本没有这个枚举）, 用
    #    mkcp/未知传输验证字段映射; 用 multiplex 验证标准规则能被映射到
    ob = {"type": "shadowsocks", "tag": "t", "server": "1.2.3.4", "server_port": 1,
          "method": "aes-128-gcm", "password": "x",
          "multiplex": {"enabled": True, "padding": True}, "whatever": 1}
    r4 = judge(outbound=ob, tag="t", tgt=tgt)
    if r4["verdict"] == "UNSUPPORTED":
        fails.append("ss+multiplex 被误判 UNSUPPORTED")
    if not any(e.get("key") == "whatever" for e in r4["extensions"]):
        fails.append("未建模的键没有进 extensions（不变式 I2）")

    # 5) build tags 真的进了判定: 把 tags 说成空 → Reality 必须被拦下
    tgt_notags = Target(kernel=KERNEL, distribution="upstream", version=tgt.version,
                        build_tags=[])
    r5 = judge(uri="vless://11111111-1111-1111-1111-111111111111@example.com:443"
                   "?security=reality&pbk=AAA&sid=00&type=tcp#r", tgt=tgt_notags)
    if tgt.build_tags and "with_utls" in tgt.build_tags and r5["verdict"] != "UNSUPPORTED":
        fails.append("build_tags=[] 时 Reality 没被拦下 —— tags 没真正参与判定")
    if "BUILD_NOT_ENABLED" not in r5["reason_codes"] and tgt.build_tags is not None:
        fails.append("BUILD_NOT_ENABLED 没出现")

    if fails:
        print("selftest 失败:")
        for f in fails:
            print("  ✗ %s" % f)
        return 1
    print("selftest 通过（target=%s/%s tags=%s）"
          % (tgt.kernel, tgt.version, tgt.build_tags))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="compat2.py", description="SB 客户端 × proxy-node-compat 适配层")
    ap.add_argument("--bin", default=None, help="sing-box 二进制路径（默认自动探测）")
    ap.add_argument("--engine", default=None, help="compat | legacy（默认读 SB_COMPAT_ENGINE）")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("version"); p.set_defaults(f=cmd_version)
    p = sub.add_parser("check-uri"); p.add_argument("uri"); p.add_argument("--json", action="store_true")
    p.set_defaults(f=cmd_check_uri)
    p = sub.add_parser("check-json"); p.add_argument("path"); p.add_argument("--json", action="store_true")
    p.set_defaults(f=cmd_check_json)
    p = sub.add_parser("filter-json"); p.add_argument("path"); p.add_argument("--out")
    p.add_argument("--report"); p.add_argument("--prefix", default="")
    p.set_defaults(f=cmd_filter_json)
    p = sub.add_parser("compare"); p.add_argument("uri"); p.set_defaults(f=cmd_compare)
    p = sub.add_parser("selftest"); p.set_defaults(f=cmd_selftest)

    a = ap.parse_args(argv)
    return a.f(a)


if __name__ == "__main__":
    sys.exit(main())
