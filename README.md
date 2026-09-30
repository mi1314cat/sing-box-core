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
bash src/conf/anytls.sh add       # AnyTLS (可选 REALITY; sing-box >=1.12)
```

> AnyTLS 早期拆成 `anyreality`(= AnyTLS **+REALITY**) 与 `anytls`(= 纯 AnyTLS) 两个模块，
> 现已合并为 `anytls`，证书选配方式与 `trojan.sh` 一致：
> **1) 真证书　2) 自签(pin)　3) Reality**。
> 选 1/2 的节点两端都能用；**选 3 只能给 sing-box 客户端** ——
> mihomo/Clash 官方明确不支持 AnyTLS+Reality，该形态不会产出 mihomo YAML。
> 旧的 `anyreality-NN.json` 在进入菜单时自动改名为 `anytls-NN.json`，端口/证书/密钥/旧链接全部保持有效。

### uTLS 指纹选配

创建 Reality / AnyTLS / VLESS / VMess / Trojan / ShadowTLS 节点时会询问 uTLS 指纹（ClientHello 伪装），
默认 `chrome`，直接回车即用默认值；也支持直接输入英文名，输入非法值自动回落 `chrome`。

可选值（由 sing-box 1.14.2 内核逐个 `sing-box check` **实测**得出，非抄文档）：
`chrome` `firefox` `edge` `safari` `360` `qq` `ios` `android` `random` `randomized`

> `randomized-noalpn` / `safari-ios` / `ios_simulator` / `firefox_mozilla` / `opera` / `chrome_v2`
> 被内核拒绝，故不提供。mihomo 的 `-t` 不校验该字段（乱写也放行），因此以 sing-box 为准。

**不提供指纹选配的协议：**

| 协议 | 原因 |
|---|---|
| naive | 内核明确 `uTLS is not supported on naive outbound` |
| shadowsocks | 无 TLS 层 |
| hysteria2 / tuic | QUIC 出站，内核运行时返回 `unsupported usage for uTLS`（配置校验阶段放行，实际不可用） |

> hysteria2 / tuic 这一点需要注意：`sing-box check` 对带 utls 的配置**不会报错**，
> 但实际连接时才失败。因此判断某协议是否支持 uTLS，必须以真实连接为准。

### 客户端产物支持矩阵

产物由 `conf/to_mihomo.py` 生成（菜单 9 → 7 出合并 YAML、→ 8 出全部单节点 YAML）。
下表是把本项目能产出的全部「协议 × TLS 模式 × 传输」组合喂给各内核实测得出的，
**不是抄文档**：

| 组合 | sing-box | mihomo | xray |
|---|:--:|:--:|:--:|
| Reality（VLESS+REALITY，vision/grpc/http） | ✓ | ✓ | ✓ |
| VLESS / WS+TLS | ✓ | ✓ | ✓ |
| Trojan / TLS | ✓ | ✓ | ✓ |
| AnyTLS / TLS | ✓ | ✓ | ✗ |
| AnyTLS / Reality | ✓ | ✗ | ✗ |
| Hysteria2 / TLS | ✓ | ✓ | ✗ |
| TUIC / TLS | ✓ | ✓ | ✗ |
| VMess / WS+TLS、VMess / Reality | ✓ | ✓ | ✓ / ✗ |
| Shadowsocks / SS-2022 | ✓ | ✓ | ✓ |
| ShadowTLS（内层 SS-2022） | ✓ | ✗ | ✗ |
| NaiveProxy | ✗ | ✗ | ✗ |

不支持的组合不会产出对应文件，并打印原因：

- **AnyTLS+Reality** — mihomo 官方原文声明不支持且不会支持
- **ShadowTLS** — mihomo 无此独立出站类型（它只是 ss/vmess 的包装插件）
- **NaiveProxy** — 见下

### NaiveProxy 在官方 sing-box 上不可用

`sing-box check` 对服务端入站**通过**，节点能建、服务能起，但**客户端产物连不上**：

```
FATAL initialize outbound[0]: cronet: library not found
```

原因是构建标签：`sing-box version` 的 Tags 里有 `with_naive_outbound`，
但**没有 `with_cronet`** —— naive 依赖的 Cronet 库不在官方发布版里。
这与配置写法无关，换任何 naive 参数都会得到同一句报错。

因此创建 naive 节点后脚本会打印告警。客户端需自行使用带 cronet 的 sing-box 构建。

> 这也是本项目判断协议支持度时坚持「真实连接」而非只看 `check` 的原因：
> hysteria2/tuic 的 uTLS 和 naive 的 Cronet，都是 `check` 放行、运行时才失败。

### 一键生成 / 覆盖重生成 / 清空全部

菜单「节点管理」下的入口：

| 菜单 | 作用 | 说明 |
|---|---|---|
| `12) 全协议一键生成` | 首次生成全部 11 个协议 | 已存在的协议会先问一次：跳过（幂等）或覆盖全部 |
| batch 菜单 `3)` | 强制覆盖 | 不再询问，直接先删后建。**端口/密码/密钥全部更换，已发出的分享链接立即失效** |
| `13) 清空全部节点` | 一键删光 | 删掉所有协议配置 + 客户端产物 + 分享令牌（旧链接立即 404），保留基础骨架与证书。需输入 `yes` 确认，失败自动回滚 |

- 一键生成覆盖的协议（10 个）：`reality` `hysteria2` `anytls` `vless` `shadowsocks` `tuic` `vmess` `trojan` `naive` `shadowtls`（其中 vmess / trojan 还会补 Reality 变体）。
- 批量里的 `anytls` 走**默认形态（非 Reality）**，这样一键生成的节点在 mihomo 客户端里也能直接用。
- 覆盖会更换：监听端口 / password / uuid / 证书 / Reality ShortID。**不会更换** REALITY 长期密钥对（与 `reality.sh` 共享）。旧分享链接因此立即失效。
- 分享链接已发出、怀疑暴露时，用「清空全部节点」一次解决。它会一并删除**端口转发 `portforward` 与出站 `outbound`** 配置（这两类同样对外监听并承载流量，留在外面等于敞口子），相关端口会真正关闭。

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
bash src/client/client.sh init             # 建配置 + 装 sb-client.service + 自动启动
bash src/client/client.sh add https://<server>:9292/share/<token>
bash src/client/client.sh list|del|update  # 多节点池 (share 来源去重, 同源只拉一次)
bash src/client/client.sh start|stop|restart|reload|status|check
bash src/client/client.sh service          # 只安装/更新 systemd unit
bash src/client/client.sh install-ui       # metacubexd (Clash API UI)
```

- 端点：HTTP+SOCKS5 同口 **`:2080`，LAN 设备直接填这个地址即可**；
- Clash API: `:19090`（secret 保护，官方要求非 loopback 监听必须设置 secret）；
- metacubexd Web UI: `http://<client-ip>:19090/ui/` — 节点切换/延迟测试/连接查看；
- 多节点 = selector `PROXY` + urltest `AUTO`（`final=PROXY`），detour 辅助出站（如 shadowtls-out）自动排除；
- **不实现 TUN/透明代理/FakeIP**（有意避免）；
- 端口避让已有服务（metacubexd 默认不再占 9090：默认 **19090**）。

### 服务与状态（客户端）

- 客户端同样**一个内核 + 一个 systemd 服务**（`sb-client.service`，`init`/`service` 时自动安装并 `enable`），
  `ExecReload` 为 `kill -HUP $MAINPID`，故 `reload` 为零断流软重载；节点增删改与端口变更**自动应用**（优先软重载）。
- 面板状态**不以 `systemctl is-active` 单一字符串为准**，而是分层判定：
  systemd 单元 → 本客户端 sing-box 进程（按 `/proc/<pid>/exe` + 配置目录精确匹配）→ 端口监听 → 配置检查 → 真实连通性。
  因此可以区分「未运行 / 启动失败 / 未初始化 / 进程在但没监听 / 配置异常」，不再出现“其实在跑却显示未运行”。
- 节点数量取自 `conf/90-outbounds.json` 里**实际被加载的出站**（排除 selector/urltest/direct），不是文件个数。

### 端口（客户端）

- 两个端口**都必须独立存在**：sing-box **不支持** mixed 入站与 clash API 共用同一端口
  （`sing-box check` 会通过，但运行时报 `bind: address already in use` 直接 FATAL）。
  面板在改端口时会拒绝与另一端口相同的取值。
- `sing-box check` **只校验配置语法，不检测端口占用**，所以冲突只在启动时暴露。
  面板「客户端设置 → 端口占用检测」用 `ss` 预检，列出占用进程与 PID，并在写入前拦截。
- 端口/监听地址的真实来源是 `conf/00-mixed.json` 与 `conf/01-clash.json`，面板读 JSON 而不是读脚本变量，
  手改 JSON 后显示不会失真。
- 监听地址切 `127.0.0.1` 属于启动期参数，面板会自动重启使新 bind 生效。


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
