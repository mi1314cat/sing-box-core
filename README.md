# SB-Panel — sing-box Server / Client 面板

个人 sing-box 核心管理面板：**服务端节点管理 + 客户端配置生成 + 分享链接（限次/一次性授权）**，
两端内核均为 [SagerNet/sing-box](https://github.com/SagerNet/sing-box)（URL 全部示例用于 v1.14.x 字段）。

- **一个统一 systemd 服务**，绝不为协议开独立服务；多协议节点通过 sing-box `-C` 多文件合并加载。
- 协议模块独立 `src/conf/*.sh`，Reality 伪装域名运行时拉取
  https://raw.githubusercontent.com/mi1314cat/One-click-script/main/domains.sh 统一源 `random_website()`（本地不复制），失败才回退 `www.oracle.com`。

## 一键安装（从 GitHub 拉取）
```bash
# 服务端 (面板 + sing-box 内核 + share 服务)
bash <(curl -Ls https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh) server
# 客户端 (sing-box 内核 + LAN HTTP/SOCKS:2080 + Web UI)
bash <(curl -Ls https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh) client
# 升级已装机器
bash <(curl -Ls https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh) update
```


## 一键安装（从 GitHub 拉取）
```bash
# 服务端
bash <(curl -Ls https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh) server
# 客户端
bash <(curl -Ls https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh) client
# 升级
bash <(curl -Ls https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh) update
```

## Server

```bash
bash src/sing-box.sh                       # 菜单
bash src/sing-box.sh init|check|reload|restart|status|list
# 添加协议节点 (菜单或直接调模块):
bash src/conf/reality.sh add      # VLESS+Reality (可选 transport: vision / grpc / http-H2)
bash src/conf/vmess.sh add        # VMess + ws/grpc/h2/tcp + TLS/自签/Reality
bash src/conf/trojan.sh add       # Trojan + TLS
bash src/conf/naive.sh add        # Naive (HTTP/2 CONNECT; 需真证书)
bash src/conf/shadowtls.sh add    # ShadowTLS v3 + 内层 SS-2022 (双 inbound)
bash src/conf/hysteria2.sh add    # Hysteria2 (UDP + 可选端口跳跃/obfs)
bash src/conf/tuic.sh add         # TUIC v5
bash src/conf/shadowsocks.sh add  # SS-2022 blake3
bash src/conf/anyreality.sh add   # AnyTLS + Reality (sing-box >=1.12)
```

### Share URL（限次/一次性分发）

```bash
bash src/conf/share.sh create reality01 1 24
bash src/conf/share.sh create hysteria01 10 168
bash src/conf/share.sh list
bash src/conf/share.sh toggle <token|tag>     # 立即禁用
bash src/conf/share.sh del|regen <token|tag>
# 服务: systemd (`sing-box-share`, 默认 :9292, SHARE_DIR/PORT 可覆盖)
```

- URL 仅含 128-bit 随机 token，**不**包含任何节点信息；返回完整客户端 outbound JSON；
- `max_uses` / `expires_at` / `enabled` 三类独立失效，均可显式 DENY(410)；
- 并发安全：flock 串行 read-modify-write，10 并发抢 1 次授权仍只放行 1 个（已实测）；
- 客户端只有**收到完整 200 响应**才计数；服务端配置异常一律 `503` 且不消耗次数。

## Client (`src/client/client.sh`)

```bash
bash src/client/client.sh install           # 内核 (arm64/amd64, glibc/musl 回退)
bash src/client/client.sh init             # mixed 0.0.0.0:2080 + clash API 0.0.0.0:19090 (secret 自动)
bash src/client/client.sh add https://<server>:9292/share/<token>
bash src/client/client.sh list|del|update  # 多节点池 (share 来源都记录)
bash src/client/client.sh start|stop|restart|status|check
bash src/client/client.sh install-ui       # metacubexd (Clash API UI)
```

- 端点：HTTP+SOCKS5 同口 **`:2080`，LAN 设备直接填这个地址即可**；
- Clash API: `:19090`（secret 保护，官方要求非 loopback 监听必须设置 secret）；
- metacubexd Web UI: `http://<client-ip>:19090/ui/` — 节点切换/延迟测试/连接查看；
- 多节点 = selector `PROXY` + urltest `AUTO`（`final=PROXY`），detour 辅助出站（如 shadowtls-out）自动排除；
- **不实现 TUN/透明代理/FakeIP**（有意避免）；
- 端口避让已有服务（metacubexd 默认不再占 9090：默认 **19090**）；面板设计一个"端口占用清单"页展示 server 端口全量。
