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
# /sub/<token>       -> 出站 + DNS + 路由 (不含入站)
# /sub/<token>/tun   -> 同上 + tun 入站 (手机 / Windows 命令行用这个)
# 为什么要 tun 变体: SagerNet 的 openTun() 里直接写着
#   error("android: tun inbound requires VPN service")
# 也就是配置里没有 tun 入站, 它根本不会去启动 Android 的 VpnService。
# 表现是节点和延迟全都正常, 也能点启动不报错, 但状态栏永远没有 VPN 图标,
# 手机流量压根没进代理。所以给手机用必须带 tun。


def load_token(path):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return ""


# TUN 入站模板。
#
# 不写 stack —— 省略即默认 system, 这是覆盖面最广的选择:
#   1. mixed 的语义是 "system 的 TCP + gVisor 的 UDP"。也就是说即使 TCP
#      走内核态, **UDP 那一半仍然要 gVisor**。官方 App 和多数第三方内核
#      没有 with_gvisor 构建标签, 发 mixed 过去手机直接起不来, 报
#      "gVisor is not included in this build, rebuild with -tags with_gvisor"。
#   2. stack 这个字段本身在 1.15.0 已废弃, 1.17.0 移除。不写它就不会
#      在新版本上报 deprecated, 语义还正好是想要的 system。
#   3. sing-box check **不验证 gVisor 是否真编进内核**, 要到 start inbound
#      才炸。所以本机(带 gVisor)测永远是绿的, 只有用户手机才暴露。
#      这个坑只能靠"不发可能不兼容的值"来躲, 没法靠测试发现。
TUN_INBOUND = {
    "type": "tun",
    "tag": "tun-in",
    "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
    "mtu": 9000,
    "auto_route": True,
    "strict_route": True,
}



def _is_foreign_resolver(srv):
    """判断一个 DNS 上游是不是境外解析器。

    走隧道时, 境外解析器返回的地址与代理出口匹配(谷歌等境外站点正常),
    国内解析器返回的是国内线路地址, 与境外出口不匹配。所以境外优先。

    只认明确的境外 DoH 公共解析器, 认不出来就当国内的(保守)。
    """
    host = str(srv.get("server", "")).lower()
    if host in ("1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4",
                "9.9.9.9", "149.112.112.112", "208.67.222.222"):
        return True
    name = str(srv.get("tls", {}).get("server_name", "")).lower()
    for dom in ("cloudflare-dns.com", "dns.google", "dns.quad9.net",
                "dns.nextdns.io"):
        if name.endswith(dom):
            return True
    return False


def load_config(confdir, with_tun=False):
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

    if with_tun:
        merged["inbounds"] = [dict(TUN_INBOUND)]
        route = merged.setdefault("route", {})
        _fix_rules_for_tun(route.setdefault("rules", []))

        # 防路由回环 —— Android 上必须同时开这两个。
        #
        # auto_detect_interface 的官方说明是
        #   "Only supported on Linux, Windows and macOS."
        # 也就是说**它在 Android 上是空转的**, 而它恰恰是 Linux 上防回环
        # 的唯一手段。结果就是 sing-box 连代理节点的出站被 Android 的
        # VpnService 抓回 VPN -> 回到 TUN -> route.final=PROXY -> 再连代理
        # -> 再回 TUN, 无限循环。
        #
        # 症状很有辨识度: VPN 图标正常出来, 但一个网页都打不开, 连接列表
        # 里反复出现同一个失败连接然后消失。App 内的"测速"不走 TUN 路由,
        # 所以节点延迟一切正常 —— 正是"测速能过但实际不通"的成因。
        #
        # override_android_vpn 的官方说明是
        #   "Only supported on Android.
        #    Accept Android VPN as upstream NIC when auto_detect_interface enabled."
        # 作用是让 sing-box 把 Android 的 VPN 接口当作上游真实网卡来绑定
        # 出站, 出站因此走物理网络而不是回灌 TUN。
        #
        # 注意: 这两个字段是配对的。override_android_vpn 只在
        # auto_detect_interface 启用时才有意义, 所以两个一起设, 且
        # auto_detect_interface 必须保持 true (它的作用是在 Android 上
        # 作为 override_android_vpn 的前置开关)。
        route["auto_detect_interface"] = True
        route["override_android_vpn"] = True

        # ---- DNS 上游的可达性: TUN 模式下必须挑直连能通的 -------------
        #
        # 这一轮终于拿到了完整因果链, 每一环都有实测支撑。
        #
        # 用户的启动日志:
        #   network: updated default interface wlan0, index 12, type wifi
        #     -> auto_detect_interface + override_android_vpn 生效, 网卡识别正确
        #   outbound/hysteria2[rn-hysteria201-TLS]: outbound connection to
        #     111.13.40.28:5222
        #     -> 普通出站完全正常
        #   dns: exchange app.market.xiaomi.com. IN A
        #     <--- 之后没有任何日志
        #
        # 于是只剩一个解释: **DNS 上游的地址在本地网络上直连不通**。
        # DNS 模块的 dialer 默认等价于一个空的 direct 出站 —— 它**不走代理**,
        # 是从物理网卡直接出去的。实测(本机, 不经代理):
        #   223.5.5.5  ->  TCP 连通, 0.1s 返回 HTTP/1.1 200 OK
        #   1.1.1.1    ->  TCP 连接超时
        # 而面板生成的 dns.final 指向的正是 **1.1.1.1**(doh-fallback)。
        # 那个可达的 223.5.5.5(doh-main) 只挂在 route.default_domain_resolver
        # 上, 仅用于解析代理节点域名, **普通查询永远轮不到它**。
        #
        # 为什么日志里连报错都没有: TCP 超时是静默等待, sing-box 在超时前
        # 不打日志。所以只有 exchange 一行, 之后什么都没有 —— 与现象吻合。
        #
        # 注意: 我前面测过"经代理访问 1.1.1.1 返回 400", 据此以为它没事。
        # 那是个错误结论 —— 代理路径能通不代表直连路径能通, 而 DNS 走的
        # 恰恰是直连。
        #
        # 修法(最小): TUN 模式下把 dns.final 指向**实测直连可达**的上游。
        # 不改节点、不改协议、不改标签、不改订阅结构。
        # ---- DNS 必须走隧道, 否则既泄露又解析到国内 IP -------------------
        #
        # 用户反馈: 手机上"有些网页能打开, 但 DNS 泄露了, 谷歌搜索不流畅"。
        # 三者是同一个根因。
        #
        # 上一版只把 dns.final 指向了**直连可达**的 223.5.5.5, 那只是让
        # DNS 能出网, 但它是阿里 DNS —— 解析结果按**国内**线路下发, 而且
        # 这个查询本身是**明文可见地发给国内运营商的**(就算加密也仍是国内
        # 解析器)。于是:
        #   * DNS 泄露检测会报出 223.5.5.5
        #   * google.com 解析到国内优化的地址, 但流量又从海外出口出去,
        #     两者不匹配 -> 搜索慢、不稳定
        #
        # 正确做法: 让 DNS 查询本身也走代理隧道, 这样
        #   * 解析器看到的是代理出口 IP, 不会泄露
        #   * 返回的地址按境外线路下发, 和出口匹配 -> 谷歌等恢复正常
        #
        # 实测 detour 是否真的生效(两组对照, 上游都指到直连不通的 9.9.9.9):
        #   无 detour:     dns: lookup failed: dial tcp 9.9.9.9:44...
        #                  (直连, 失败)
        #   detour=PROXY: outbound/anytls[...]: outbound connection to
        #                  9.9.9.9:443
        #                  (DNS 确实进了隧道)
        # 结论: detour 指向 selector 时, DNS 会复用该出站的连接。
        #
        # 注意 detour 不能指向 direct —— 内核会 FATAL:
        #   "detour to an empty direct outbound makes no sense"
        #
        # 上游选谁: 走隧道后不再受"本地能否直连"限制, 所以优先用境外
        # 解析器(1.1.1.1), 它的结果与境外出口匹配; 境外那个不可用时
        # 再退到国内的那个。
        dns = merged.get("dns")
        if isinstance(dns, dict):
            servers = dns.get("servers", [])
            # 走隧道后, 优先级不再由"本地直连可达性"决定, 而是由
            # "解析结果是否与代理出口匹配"决定 —— 境外解析器优先。
            foreign = [x for x in servers
                       if _is_foreign_resolver(x)]
            domestic = [x for x in servers if x not in foreign]
            ordered = foreign + domestic
            for srv in ordered:
                # detour 只对需要出网的上游有意义; local/hosts 没有 dial 阶段
                if srv.get("type") in ("https", "quic", "tls", "h3",
                                       "http", "tcp", "udp"):
                    srv["detour"] = "PROXY"
            if ordered:
                dns["final"] = ordered[0]["tag"]

    return json.dumps(merged, ensure_ascii=False, indent=2).encode("utf-8")


def _fix_rules_for_tun(rules):
    """把 TUN 模式下会坏掉的两条规则挪到正确的位置。

    面板生成的规则顺序是:
        [0] ip_is_private -> direct
        [1] protocol=dns -> hijack-dns
        [2] port=53      -> hijack-dns
    在 mixed 入站下这个顺序没问题(客户端自己解析域名, sing-box 看不到
    DNS 查询)。但在 TUN 模式下会彻底断网:

    TUN 的 DNS 地址是 172.19.0.2(address 里第一个 IPv4 条目的下一个地址,
    官方文档的默认行为), 而 172.19.0.0/12 是私有地址段。于是每一个 DNS
    查询都先命中 [0] ip_is_private -> direct, 被当���"内网流量"直连出去,
    发到 172.19.0.2 —— 而那个地址上什么都没有。

    现象是: VPN 图标正常出来, 但一个网页都打不开, 因为连域名都解析不了。
    更隐蔽的是就算不用 DNS(纯 IP 访问)也可能因为 sniff/分流链断掉而异常。

    所以把 hijack-dns 提到 ip_is_private 前面。dns_mode 默认是 hijack,
    这些规则必须最先命中才有机会接管 DNS。

    顺带说明: 这条规则顺序问题只影响 TUN 变体, 所以放在这里改而不是
    去动面板的 regen_selector —— 面板自己跑在 mixed 入站上, 那个顺序
    对它是对的, 改坏了反而影响本机。
    """
    # sniff 必须在最前面: 否则 TUN 进来的流量只有 IP 没有域名, 分流失准
    if not any(r.get("action") == "sniff" for r in rules):
        rules.insert(0, {"action": "sniff"})

    hijack = [r for r in rules if r.get("action") == "hijack-dns"]
    if not hijack:
        return
    for r in hijack:
        rules.remove(r)

    # 插到 sniff 之后、所有其它规则之前
    pos = 1 if any(r.get("action") == "sniff" for r in rules) else 0
    for r in reversed(hijack):
        rules.insert(pos, r)


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
        """只认 /sub/<token> 和 /sub/<token>/tun 两种路径。"""
        tok = load_token(self.token_path)
        if not tok:
            return False          # token 还没生成, 不能让 /sub/ 裸奔
        exp = SUB_PATH + tok
        return path in (exp, exp + "/tun")

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if not self._authorized(path):
            self._deny()
            return
        try:
            body = load_config(self.conf_dir,
                               path.endswith("/tun"))
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
        self.send_header("Content-Length", str(
                len(load_config(self.conf_dir, path.endswith("/tun")))))
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