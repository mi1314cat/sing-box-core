# Phase 0 调研报告 — sing-box 管理脚本（SB-Panel）

调研时间：2026-09（sing-box 官方文档/源码当前版本 v1.14.1）

## 1. xary-core（我的 Xray 仓库）架构分析

### 实际调用链（panel → conf/*.sh → 配置 → service）
```
xray-panel.sh
 ├─ VEVLRE.sh            安装 xray（curl | bash 拉取）
 ├─ conf/tunnel.sh       隧道节点
 ├─ conf/hysteria2.sh    Hysteria2
 ├─ conf/sock5.sh        SOCKS5
 ├─ conf/vlessecn.sh     VLESS-ECN(tcp)
 ├─ conf/http.sh         HTTP
 ├─ conf/vlessxhttpecn.sh VLESS-xHTTP
 ├─ conf/GDargo.sh / lsargo.sh  固定/临时 Argo
 ├─ conf/XRevise.sh → nconf.sh / cconf.sh   修改配置
 ├─ conf/verify.sh       校验 + 重启
 ├─ conf/outbound.sh     出站管理
 ├─ conf/split.sh        分流规则
 ├─ conf/fd/*            反向代理（server/client）
 └─ uninstall_xray.sh / unused/xray_install.sh（历史遗留）
每个 add 调用后主面板 systemctl restart xrayls.service
```

### 关键架构事实（RN 实机验证）
- **单 service**：`/etc/systemd/system/xrayls.service` → `ExecStart=/root/catmi/xray/xrayls -confdir /root/catmi/xray/conf`
- **配置目录**：`/root/catmi/xray/conf/*.json`（hysteria-01.json、vless-xhttp-01.json、out-01.json、socks-01.json、nginx.json…）——与 SB 目标架构同构：**一个内核 + 单 service + confdir 级联加载**。
- **协议模块模式**（以 hysteria2.sh 为模板）：
  - 顶部重复实现 UI 工具（printInfo/Ok/Error、safe_read、端口随机/占用检测、IPv4/IPv6 检测、get_next_index `PROTO-NN.json` 编号）
  - 证书扫描（catmi/cloudflare/certs、acme.sh、nginx 容器挂载等 8 处目录）→ 真证书/自签双方案（ECDSA P-256 10年）
  - `jq -e .` 校验 JSON 后才落盘
  - `out/` 产物三件套：xray 客户端 json + mihomo yaml + 分享链接 txt + `hy2_meta-NN.json` 持久化元数据（供删除时清理 iptables 端口跳跃规则）
  - 端口跳跃（iptables REDIRECT，默认不开，防呆 6 层）
  - 防火墙放行（ufw/firewall-cmd/iptables 三级回退）
- **存量节点类型**：tunnel、socks5、vless-ecn、http、vless-xhttp、hy2、argo（fixed/ephemeral）。
- **服务器基线**：RN = amd64，公网 IP 107.173.154.178，占用 TCP/UDP 端口：53,80,443,6541,7890,8074,8787,8899,9997,9998,9999,10011,12588,19188,19595,22108,28021,31722,33934,41721,45630,45900,49184,52341。已装 jq。CC = Armbian **aarch64**（客户端机），mihomo/hysteria-client/argo 在跑——**SB 客户端需 arm64 构建**。

### 五类文件归档
| 类别 | 文件 |
|---|---|
| 当前有效 | xray-panel.sh、VEVLRE.sh、conf/{tunnel,hysteria2,sock5,vlessecn,http,vlessxhttpecn,GDargo,lsargo,XRevise,nconf,cconf,verify,outbound,split}.sh、conf/fd/*、uninstall_xray.sh |
| 协议模块 | conf/*.sh（每协议一文件：生成/列出/删除/改） |
| 配置文件 | /root/catmi/xray/conf/*.json（xrayls 内部才是真 runtime config 拼装处） |
| 服务管理 | xray-panel.sh 主循环 + verify.sh |
| 历史遗留/废弃 | unused/*（xray_install.sh 等）、根目录 vlessxhttpecn.sh 副本、conf.bak-*、.quarantine |
| 不能迁移到 SB | Argo 模块（SB 无 argo 传输）、xhttp/spider 传输（SB 不支持 xHTTP）、nginx.json（属 nginx 体系）、Xray 专属流控 vision |

## 2. sing-box 官方技术事实（v1.14.1，2026-09-15 latest stable）

### 多配置机制（源码 cmd_run.go 实证）
- `sing-box -c <file>`（可重复）/ `-C <dir>`（只读**顶层** `*.json`，不递归）/ `-D <dir>`（工作目录）。全局参数必须在 `run` 子命令**之前**。
- 加载：先 `-c` 顺序，再 `-C` 目录顶层 .json，最终按**完整路径字典序排序**合并。
- 合并语义（badjson.MergeJSON）：对象递归合并、**数组 append**（inbounds/outbounds/endpoints 拼接）、标量冲突时旧值胜出（不报错）；合并后统一 `checkOptions`：**outbound 与 endpoint 的 tag 同一命名空间查重**，inbound 独立命名空间。
- 任一文件非法 → **整体失败**（log.Fatal，不部分加载）。SIGHUP 热重载失败是唯一保留旧实例的场景。
- 校验：`sing-box check -D <dir> -C <configs>` — 未知字段/tag 冲突/对象初始化均验证；**不验证端口绑定、证书文件可载性**（需启动测试兜底）。
- `sing-box format -w` 存在；`sing-box merge out.json` 可把全部 sh 片段合并导出。
- 官方 systemd 模板：`ExecStart=/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run`（全局参数在 run 前）。
- **结论：单 service + 配置目录多文件完全受官方支持，inbounds/outbounds 全局一级字段在 1.14 并未废弃。**

### 版本与安装
- latest stable **v1.14.1**；1.15.0-alpha 系列存在（pre-release）。默认应锁定 stable，更新由用户主动触发。
- 资产：`sing-box-<v>-linux-amd64.tar.gz`（另 -glibc/-musl），arm64 同构；官方 deb（deb.sagernet.org）也有。RN 用 amd64，CC 用 arm64。
- 官方默认 build tags 已含 with_utls,with_quic,with_gvisor,with_clash_api 等，release 资产直接可用。

### 必须规避的 deprecated/removed 字段（写配置生成逻辑时的红线）
| 旧 | 现状 | 替代 |
|---|---|---|
| DNS `address`/`tls://8.8.8.8` | **1.14.0 已移除** | `{"type":"tls","server":"1.1.1.1"}` 对象格式 |
| `dns.fakeip` 顶层 | **1.14 已移除** | DNS server `{"type":"fakeip","inet4_range":...}` |
| geosite/geoip 字段 | 1.12 已移除 | rule-set（.srs） |
| block/dns 特殊 outbound | 1.13 已移除 | route rule `action: reject / hijack-dns` |
| DNS inline `server` 字段、`inbound.sniff` | 已移除 | rule action 对象（route/reject/sniff/hijack-dns/resolve/bypass/predefined） |
| `dns.independent_cache` | 1.14 deprecated（1.16 移除） | 直接删字段 |
| `store_rdrc` | deprecated | `cache_file.store_dns: true` |
| remote rule-set `download_detour` | 1.14 deprecated（1.16 移除） | `http_client` |
| DNS rule `strategy`/redirect route action `strategy` | 部分已 deprecated | 服务器级/全局 strategy、domain_resolver |
| DNS `optimistic`/`timeout`/`cache_capacity` | 1.11~1.14 新增可用 | — |
| TUN `dns_mode`(1.14)、`auto_redirect`（仍在用） | — | — |

### AnyReality 结论
- **非独立协议**：社区称呼 = **AnyTLS + TLS(REALITY)** 组合。sing-box **1.12.0** 起原生支持 AnyTLS；REALITY 是共享 `tls.reality` 字段，直接叠加。
- 服务端：inbound `{type:"anytls", users:[{name,password}], padding_scheme?, tls:{reality:{handshake,private_key,short_id[]}}}`；客户端 outbound：`{type:"anytls", server, server_port, password, tls:{ server_name, utls:{fingerprint:"chrome"}(REALITY 硬依赖), reality:{public_key, short_id(string)} }}`。服务端 short_id 是数组、客户端是单字符串。
- 未标 experimental 但有变更：1.13.16/1.14 默认移除 client_metadata；padding_scheme/idle_session_* 最易变。mihomo 写不出 anytls+reality（无 reality-opts）→ 订阅互通差，CC 侧可放 sing-box 客户端配置解决。
- 与 VLESS-Reality 区别：单 password（非 uuid）、内建多路复用+padding（非 vision）。

### 端口转发结论
- **原生支持**：inbound `direct`（tunnel server），`listen`+`listen_port`，**`override_address`/`override_port`** 指定目标 → 路由到 direct outbound 即完成转发。
- `"listen":"::"` 双栈；**listen_port 不支持端口范围**（issue #204 官方 "No."）→ 端口段需多条 inbound 或防火墙层。
- tproxy/redirect 是透明代理（还原原始目的地址），非静态转发；无需 socat/iptables。

### 两个第三方脚本（功能参考，不搬架构）
- **fscarmen/sing-box v1.3.25**：11+ 协议（Reality/hy2/TUIC/SS2022/Trojan/AnyTLS/Naive/ShadowTLS…）、conf 00-22 编号分片 + check + SIGHUP 热更、force_version 锁版本、Argo 四模式 + nginx 订阅（Clash/sing-box/v2rayN 输出）、自签 SPKI pin 输出。避坑：**单文件 322KB**、数组索引位对齐易错、状态分散、无事务。
- **mack-a/v2ray-agent**：Xray/sing-box 双核、自动 TLS 申请续期、订阅、分流/黑名单、两户二级菜单结构。
- 借鉴点：conf 分片 + check、锁定版本、自签证书 pin 分享（不 insecure）、meta 持久化（本已有）；自己架构的差异化：模块化 conf/*.sh（学 xary-core），不做巨型单体。
