# SB-Panel — sing-box Server / Client 面板

个人 sing-box 核心管理面板：**服务端节点管理 + 客户端配置生成 + 分享链接（限次/一次性授权）**，
两端内核均为 [SagerNet/sing-box](https://github.com/SagerNet/sing-box)（URL 全部示例用于 v1.14.x 字段）。

- **一个统一 systemd 服务**，绝不为协议开独立服务；多协议节点通过 sing-box `-C` 多文件合并加载。
- 协议模块独立 `src/conf/*.sh`，Reality 伪装域名运行时拉取
  https://raw.githubusercontent.com/mi1314cat/One-click-script/main/domains.sh 统一源 `random_website()`（本地不复制），失败才回退 `www.oracle.com`。

## 一键安装（从 GitHub 拉取）
```bash
bash <(curl -Ls https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh)
```
执行后: 获取项目 → 初始化 → 自动进入中文管理面板。面板首页显示服务状态/版本/节点数; 按编号菜单操作。已装机器先显示状态再进面板 (输入 u 可热更新)。也可显式: `install.sh server|client` 或 `install.sh update`。



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

## 分享链接管理（服务端菜单 3）
- **1) 生成链接**：先列本机可分享节点（编号+协议+端口），回车=全部节点一条链接。
- **2) 全部节点一条链接**：列出“共 N 个可分享节点”，标准创建流程 (`max_uses` + 有效期菜单)。
- **3) 列表/4) 删除/5) 禁用/6) regen**：带编号列表，输入编号或 token 前缀均可定位。
- `max_uses`：`0=不限` / N=次数；`有效期` 菜单：1h / 24h / 7d / 30d / 永久 / 自定义。
- 已修复：`max_uses=abc`/负数不再误删旧链接；`ttl=0` 语义统一为"永久"；410/404/503 错误分支明确文案；sing-box 停机时分发 503 且不消耗额度（HEAD 预检支持）。

## 客户端
```bash
bash client.sh                     # 交互面板 [ 客户端 · CLIENT ] 无参进入
sb-client add <share-url>
sb-client del <tag>                # 支持 tag 编号
sb-client update                   # 重新拉取其 share 源并重载
```
- 链接导入支持**同一 URL 三连导入零副本**（`source` meta 记录唯一身份）。
- 错误文案区分 `410 已用尽/404 不存在/503 服务未运行`，curl -f 陷阱已移除。

## Reality flow 与节点删除级联
- 服务端 Reality `users` 内建 `flow = xtls-rprx-vision`，与客户端一致（修复 QA 发现的全 flow mismatch 不可连）。
- 任何节点删除动作:**自动清理其 share token** 并刷新 all 聚合（token 不变内容即时更新），不会再把已删节点悄悄分发出去。

## 卸载 (不影响 Other 服务)
```bash
bash conf/uninstall.sh       # CLI 菜单: 1) 卸载 SB 整套  2) 仅停服务
```
停止并移除仅 SB 自家的 systemd 单元 (`sing-box.service` / `sing-box-share.service`), 可选删数据目录 / `/root/catmi/sing-box`。绝不触碰其它 systemd 服务、证书 (`/etc/letsencrypt` 等)、客户端侧 `sb-client`。删除前会显示确切影响范围, 必须 yes 确认。
