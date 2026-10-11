# SB-Panel — sing-box 服务端 / 客户端面板

个人 sing-box 核心管理面板：**服务端节点管理 + 客户端配置生成 + 分享链接（限次/一次性授权）**。
两端内核均为 [SagerNet/sing-box](https://github.com/SagerNet/sing-box)，当前锁定 **1.14.2**。

- **一个统一 systemd 服务**，绝不为协议开独立服务；多协议节点通过 sing-box `-C` 多文件合并加载。
- **10 个协议模块 + 35 个预置方案**（协议 × TLS 模式 × 传输的常用组合），建节点时选编号即可。
- 协议模块独立 `src/conf/*.sh`，Reality 伪装域名运行时拉取
  https://raw.githubusercontent.com/mi1314cat/One-click-script/main/domains.sh 统一源 `random_website()`（本地不复制），失败才回退 `www.oracle.com`。

> **本文档里所有"支持 / 不支持"的结论都是实测得来的，不是抄文档。**
> 判断某个组合能不能用，一律以 `sing-box check` **加上真实连接**为准 ——
> 本项目反复遇到 `check` 放行、运行时才失败的情况（hysteria2/tuic 的 uTLS、
> naive 的 CGO、anytls 的防火墙放行），详见下文各节的说明。

---

## 目录

- [一键安装](#一键安装)
- [快速上手](#快速上手)
- [架构](#架构)
- [协议与预置方案](#协议与预置方案)
- [批量生成](#批量生成)
- [TLS 模式](#tls-模式)
- [ECH 加密 ClientHello](#ech-加密-clienthello)
- [传输方式](#传输方式vless-vmess-trojan)
- [多路复用](#多路复用multiplex)
- [其他选配](#其他选配)
- [客户端产物支持矩阵](#客户端产物支持矩阵)
- [CDN / nginx 前置](#cdn-nginx-前置)
- [分享链接分发](#分享链接分发)
- [客户端面板](#客户端面板)
- [已知不可用的组合](#已知不可用的组合)
- [卸载](#卸载)

---

## 一键安装

```bash
bash <(curl -Ls https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh)
```

执行后：获取项目 → 初始化 → 自动进入中文管理面板。面板首页显示服务状态 / 版本 / 节点数，
按编号菜单操作。已装机器先显示状态再进面板（输入 `u` 可热更新）。
也可显式：`install.sh server|client` 或 `install.sh update`。

---

## 快速上手

第一次装完，按这个顺序最省事：

1. **菜单 1 → 内核安装**：确认 sing-box 版本（1.14.2）
2. **菜单 2 → 12 全协议一键生成**：一次建出全套节点，回答几个问题即可
3. **菜单 9 → 客户端产物**：导出 JSON / YAML / 分享链接
4. 客户端导入，或把分享链接发给别人

**批量生成会问什么**（详见 [批量生成](#批量生成)）：

```
① 客户端配置写哪个地址   IPv4 / IPv6
② 证书方案              本机真证书（选哪一张）/ 自签
   端口范围              如 20000-25000，回车 = 随机
   CDN 模式              开 / 全直连
③ 多路复用              不开 / 网页党 / 视频党 / 下载党
④ CDN 传输             ws / gRPC / ws+gRPC
⑤ 服务器标识            节点名前缀，回车 = 国旗 + hostname
```

菜单三个选项的区别只在**问多少**和**会不会覆盖**：

| 选项 | 问什么 | 已存在的节点 |
|---|---|---|
| 1 全协议生成 | 上表全部 | 跳过，不动 |
| 2 全协议快速生成 | 只有端口范围 | 跳过，不动 |
| 3 全协议重建 | 只有端口范围 | **强制覆盖** |

（选项 3 用黄色标出，因为它会改掉已经配好的节点。）

---

## 架构

```
/root/catmi/sing-box/
├── sing-box.sh              # 服务端面板主入口
├── install.sh               # 一键安装
├── conf/                    # 协议模块 + 共享库
│   ├── lib.sh               #   公共函数、预置表、ECH/CDN/证书逻辑
│   ├── batch.sh             #   全协议批量生成
│   ├── vless.sh vmess.sh trojan.sh anytls.sh
│   ├── shadowsocks.sh hysteria2.sh tuic.sh
│   ├── naive.sh shadowtls.sh reality.sh
│   ├── cdn.sh cdn_menu.sh cdn_nginx.sh cdn_node.sh
│   ├── to_mihomo.py         #   sing-box outbound → mihomo YAML 转换器
│   ├── share.sh             #   限次分享链接
│   └── ...
├── config/                  # 服务端节点配置（每个 inbound 一个文件）
├── out/                     # 客户端产物（JSON / YAML / 分享链接）
├── cert/                    # 证书与私钥
├── ech/                     # 内核 ECH 密钥对
└── backup/                  # 配置备份
```

**多文件合并**：每个节点一个 `config/<proto>-NN.json`，sing-box 用 `-C config` 合并加载。
新增节点只需写文件，不需要重启 systemd（面板会自动处理）。

---

## 协议与预置方案

10 个协议模块，35 个预置方案：

| 协议 | 预置数 | 模块 | 说明 |
|---|:--:|---|---|
| VLESS | 9 | `vless.sh` | REALITY ×4 + CDN(ws/grpc/h2) ×3 + CDN+ECH ×2 |
| VMess | 8 | `vmess.sh` | REALITY ×4 + CDN(ws/grpc) ×2 + CDN+ECH ×2 |
| Trojan | 7 | `trojan.sh` | REALITY + CDN(ws/grpc) ×2 + CDN+ECH ×2 + TLS |
| AnyTLS | 4 | `anytls.sh` | 自签(pin)、真证书、REALITY、REALITY+padding |
| Shadowsocks | 3 | `shadowsocks.sh` | SS-2022 blake3 + multiplex |
| Hysteria2 | 2 | `hysteria2.sh` | 默认、+内核 ECH（端口跳跃 / obfs 为全局选项） |
| TUIC | 2 | `tuic.sh` | 默认、+内核 ECH |
| NaiveProxy | 2 | `naive.sh` | 自签（默认）、真证书 |
| Reality | — | `reality.sh` | 独立的 VLESS+Reality 入口 |
| ShadowTLS | — | `shadowtls.sh` | v3 + 内层 SS-2022（双 inbound） |

命令行直接调模块：

```bash
bash src/conf/vless.sh add          # 交互式建节点
bash src/conf/vless.sh list|del     # 查看 / 删除
```

---

## 批量生成

菜单「节点管理 → 12 全协议一键生成」，或 `bash src/conf/batch.sh`。

批量之前会**统一问一遍所有功能选项**，而不是生成完再逐个进节点菜单改十几次：

### 产出清单

一轮全协议批量 = **13 个节点**（下表省略服务器前缀；实际 tag 是
`🇺🇸 hostname-anytls01-TLS` 这种形式，见[服务器标识](#服务器标识节点名前缀)）：

| 节点 | 协议 | 接入 | 第二形态 |
|---|---|---|---|
| `anytls01-TLS` | AnyTLS | 直连 | `anytls02-REALITY`（AnyTLS+Reality） |
| `reality01-REALITY` | VLESS | 直连 | — |
| `vless01-TLS-CDN` | VLESS | **CDN** | — |
| `vmess01-TLS-CDN` | VMess | **CDN** | `vmess02-REALITY` |
| `trojan01-TLS-CDN` | Trojan | **CDN** | `trojan02-REALITY` |
| `hysteria201-TLS` / `tuic01-TLS` / `shadowsocks01-plain` / `shadowtls01-TLS` / `naive01-TLS` | — | 直连 | — |

只有 **vless / vmess / trojan** 能走 CDN —— 它们带 Transport 字段（ws/grpc/http），
Cloudflare 代理的是 HTTP(S) 上的东西。anytls / hysteria2 / tuic / shadowsocks /
naive / shadowtls 都是原生 TCP/UDP 协议，**内核层面就过不了 CDN**，名字里
也就不会出现 `-CDN`。

`anytls02-REALITY` 曾经产不出来：`ask_cert` 里
`if SB_FORCE_TLS_REALTY; then c=3` 后面少了一行
`elif [[ -n "$SB_BATCH" ]]; then`，导致批量分支的提示框**紧接在 `c=3` 之后
执行**，把刚设好的值覆盖掉。结果 `anytls01` / `anytls02` 除了端口和密码
完全一样，Reality 形态一个都没产出，看起来"生成成功"实则是废节点。

### 交互项

| 顺序 | 问什么 | 选项 |
|:--:|---|---|
| ① | 客户端配置写哪个地址 | IPv4 / IPv6 |
| ② | 证书方案 | 1) 本机真证书（列出每一张，选一张） 2) 自签 |
| | CDN 模式 | 1) 开启（vless/vmess 走 CDN） 2) 全部直连 |
| ③ | 多路复用 | 1) 不开 2) 网页档(web) 3) 视频党(video) 4) 下载档(download) |
| ③b | Hysteria2 专属 | 1) 端口跳跃 2) obfs 混淆 3) 两个都开 4) 都不开（默认） |
| ④ | CDN 传输 | 1) ws（3 个节点） 2) gRPC（3 个） 3) ws + gRPC（6 个） |
| ⑤ | 服务器标识 | 节点名前缀，回车 = 国旗 + hostname（见下） |

端口范围是单独一问，回车即随机分配（`20000` 起随机起点，跨度 5000）。
要指定就用环境变量，优先级高于交互：

```bash
SB_BATCH_PORT_START=30000 SB_BATCH_PORT_END=31000 bash conf/batch.sh
```

### 服务器标识（节点名前缀）

同一个人在多台服务器上各跑一份全协议是很常见的。两边生成的节点名完全一样
（都是 `anytls01-TLS`），而客户端的节点文件名正好是 `node-<tag>.json` ——
把第二台的订阅拉进同一个客户端时，**直接覆盖第一台的全部节点**，面板还会报
`[OK] 已导入 13 个节点`。

所以每个节点的 tag 都会带上服务器前缀。默认值是**国旗 emoji + 系统 hostname**
（做法参考 [fscarmen/sing-box](https://github.com/fscarmen/sing-box)）：

```
🇺🇸 myserver-anytls01-TLS
```

交互时**每次都会问**，回车即默认，可以改成任意名字。
只输入名字就行，**不用自己带旗帜** —— 提示里已有的旗帜会自动补上
（旗帜是服务器的属性，不是名字的一部分）。用户自己输入了别的旗帜则尊重用户。答案同时存在
`share-state/server-name`，供聚合产物等只需要取值、不该交互的场合使用。

批量（全协议生成 / 全协议快速生成）同样会问这一步 —— 注意批量里每个协议都是
`bash conf/xxx.sh add` 起的独立子进程，在那里问传不回主进程，所以是在
`batch_main` 里统一问一次，再传给各协议。

| 位置 | 表现 |
|---|---|
| 配置 `tag` | 纯 ASCII 的 `myserver-anytls01-TLS`（emoji 剥掉，保证文件名和配置安全） |
| 分享链接 `#` 片段 | `#🇺🇸 myserver anytls01-TLS`（旗帜在这里） |

国旗取自 IP 归属地，查不到就只是没有旗帜，不影响功能。

### Hysteria2 的端口跳跃与 obfs

这两个只对 `hysteria2` 有意义（UDP 协议 + salamander obfs），其他协议内核
没有对应字段，所以不做逐协议勾选，直接问一次"要不要开"。
**之前它们只挂在交互路径上**，批量生成时 `stdin` 是 `/dev/null`，永远拿到
空值 —— 等于恒定关闭，用户在批量里根本选不到。现已接入批量。

**端口跳跃** 开启后做四件事：

1. 服务端装 iptables DNAT：`udp dport 起:止 → REDIRECT --to-ports 真实端口`
2. **防火墙放行整个跳跃范围**（`ufw allow 起:止/udp`）—— 这一步漏了会
   出现"配置全对、服务端在监听、日志里一条连接都没有"，因为 ufw 把包丢了
3. 客户端出站写 `server_ports: ["起:止"]`，sing-box 的分隔符是 `:`，
   写 `-` 会直接报 `bad port range`
4. 分享链接带 `mport=起-止`；mihomo YAML 里叫 `ports`，且**必须是字符串**，
   写成数组会报 `'ports' expected type 'string'`

间隔参数对齐 [fscarmen/sing-box](https://github.com/fscarmen/sing-box) 的做法，
客户端出站一并写 `hop_interval: 30s` / `hop_interval_max: 60s`。

> **建新节点前会先清掉同跳跃范围的旧 DNAT 规则**。否则每建一个节点就多一条
> 指向不同 `--to-ports` 的规则，而这些规则匹配的是同一个 dport 范围 ——
> 客户端往跳跃端口发包时 netfilter 取第一条匹配的改道，包被送进**上一个**
> 节点。表现同样是"只有开了跳跃的 HY2 连不通"，但根因是规则堆积，
> 换协议、重启服务都找不到。（实测连开 4 个节点后复现。）

两个选项都可以**用环境变量预设**，跑非交互批处理时不必逐问答：

```bash
SB_BATCH_HOP=31000-31999 SB_BATCH_OBFS=y bash conf/batch.sh
```

> 交互处直接回车会**沿用预设**，不会把预设清空。（实现上踩过一个坑：
> `local SB_BATCH_HOP=""` 会覆盖同名外部变量，而 `case` 的 `*)` 分支又会在
> 回车时无条件清空，两个 bug 叠加导致"明明传了跳跃范围，产物里没有
> `server_ports`"。）

**obfs 混淆** 开启后服务端与客户端都带
`obfs: {type: salamander, password: <24位hex>}`，mihomo 侧对应
`obfs: salamander` + `obfs-password`。fscarmen 那一版**没有** obfs
（他的 `HY2_REALM_CONFIG` 是 hy2 realm 中转，不是混淆层）。

> **不开混淆时，分享链接里不会出现任何 obfs 参数**（不写即无混淆）。
>
> 这是一条**实测踩出来的硬规矩**：旧代码无条件往链接里写
> `&obfs=none&obfs-password=`，mihomo 解析到"有 obfs 但没密码"直接报
> `initial proxy provider t error: proxy 0 error: missing obfs password`，
> 并把**整条订阅**判成 **0 节点** —— 同一条链接里另外 8 个好节点一起消失
> （跨内核 E2E 实测；M 内核同病，X 侧已先修）。
>
> 严重性口径（实测区分，别记混）：
>
> | 客户端 | 遇到 `obfs=none` |
> |---|---|
> | **mihomo** | **硬失败**：provider 归零，同订阅好节点全丢 |
> | sing-box / xray | **静默忽略**：只当没写 obfs，节点照常用 |
>
> 所以受害面是"把 SB 链接喂给 mihomo 订阅"的场景；SB 自己（分享内容是
> sing-box JSON）与 sing-box/xray 客户端不受影响。

### Hysteria2 的带宽提示（up_mbps / down_mbps）

| 项 | 值 |
|---|---|
| 默认 | **上行 60 / 下行 200** Mbps（= 用户偏好 上行 60、下行 150~200 的上沿） |
| 内核字段名 | sing-box：`up_mbps` / `down_mbps`（服务端 inbound 与客户端 outbound 都写） |
| mihomo 字段名 | 裸 `up` / `down`（`to_mihomo.py` 转换时写成 `"200 Mbps"`；**两种写法 mihomo 都收**，实测 `up: 200` 与 `up: 200 Mbps` 都能连） |
| 改法（非交互） | `SB_HY2_UP_MBPS=60 SB_HY2_DOWN_MBPS=200 bash conf/batch.sh` |
| 改法（交互） | 建 hy2 节点时会问"上行/下行 Mbps"，**回车即默认** |
| 分享链接 | **不带**带宽参数 —— URI 里没有 up/down，谁导入谁自己定；要固定值就改客户端配置 |

这不是限速，是给内核的链路速率提示（拥塞控制参考值）：写小了会自己压住吞吐，
写大了没有惩罚。**显式给的值不会被默认值覆盖** —— 环境变量与交互输入优先。

> 顺带一句：TCP Brutal（多路复用里的 `brutal`）默认值仍是 100/200，它和 hy2 的
> `up_mbps/down_mbps` 是两套东西（brutal 是真限速，填高会丢包），这里没有一起改。

### 设计取舍：为什么是单选而不是逐协议勾选

能不能用 multiplex / CDN 是**内核字段有没有**的问题，不是用户偏好：

- multiplex 只有 `vless` / `vmess` / `trojan` / `shadowsocks` 内核支持（`sb_mux_supported`）
- CDN 只有 `vless` / `vmess` / `trojan` 有 Transport 字段

列 10 个协议让你逐个勾，大部分格子是不能勾的，勾了反而困惑。所以只问
**「开不开、哪一档」，不支持的协议在菜单里直接写明**。

### 一次批量的实际产出

选「真证书 + 网页党 + ws+gRPC」，实测产出 15 个节点：

```
anytls01/02-TLS             直连
hysteria201-TLS            直连
reality01-REALITY          直连
shadowsocks01-plain        直连  mux
shadowtls01-TLS            直连
tuic01-TLS                 直连
vless01-TLS-CDN            CDN   ws     mux
vless02-TLS-CDN            CDN   grpc   mux
vmess01-TLS-CDN            CDN   ws     mux
vmess02-REALITY            直连        mux
vmess03-TLS-CDN            CDN   grpc   mux
trojan01-TLS-CDN           CDN   ws     mux
trojan02-REALITY           直连        mux
trojan03-TLS-CDN           CDN   grpc   mux
```

客户端逐个真实连通：**14/15 通过**（`shadowtls01` 需要外部 TLS 服务配合，单独跑必然失败）。

### 覆盖 / 幂等

| 菜单 | 作用 |
|---|---|
| `12) 全协议一键生成` | 已存在的协议会先问一次：跳过（幂等）或覆盖全部 |
| batch 菜单 `3)` | 强制覆盖，不再询问 |
| `13) 清空全部节点` | 一键删光（配置 + 客户端产物 + 分享令牌），需输入 `yes` |

- 覆盖会更换：监听端口 / password / uuid / 证书 / Reality ShortID
- **不会更换** REALITY 长期密钥对（与 `reality.sh` 共享）
- 旧分享链接因此立即失效

批量模式也可以用环境变量非交互调用：

```bash
SB_BATCH_OVERWRITE=1 \
SB_BATCH_MUX=1 SB_BATCH_MUX_PROFILE=web \
bash src/conf/batch.sh
```

---

## TLS 模式

建节点时的证书选项（各协议菜单略有差异）：

| 模式 | 服务端 | 客户端 | 适用 |
|---|---|---|---|
| 真证书 | `certificate_path` + `key_path` | 正常校验 | 走 CDN 必需；任何客户端都能连 |
| 自签 (pin) | 同上，证书是自签 | `certificate_public_key_sha256` 锁定 | 仅支持 SPKI pin 的客户端 |
| REALITY | `reality.{enabled,private_key,short_id}` | `reality` + uTLS | 免证书；**仅 sing-box 客户端** |

### 自签与 SPKI pin

自签证书用 SPKI pin 锁定，客户端不校验 CA，只校验公钥指纹：

```bash
openssl x509 -in cert.crt -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary | base64
```

> mihomo 的 `fingerprint` 字段是**十六进制证书哈希**（另一套算法），不是 base64 SPKI。
> 两者不能互换。转换器 `to_mihomo.py` 会分别处理。

---

## ECH 加密 ClientHello

ECH 把 ClientHello 的真实 SNI 加密，外层只暴露一个 `public_name`。
本项目支持**两条完全不同的路径**，配置方式、密钥来源、客户端要求都不同。

### 路径一：CDN ECH（密钥由 Cloudflare 持有）

Cloudflare 在边缘终结 TLS 并持有 ECHConfigList 私钥，源站不需要任何 ech 配置。

- 服务端配置里**没有** `tls.ech`
- 客户端：`tls.ech = { enabled, query_server_name }`（去 DNS 取该域名的 ECHConfigList）
- 分享链接参数：`ech=<public_name>+<DoH 上游>`
- 外层 SNI 变成 `cloudflare-ech.com` 之类**与真实域名无关**的名字 → 真实 SNI 确实被藏住
- **任何支持 ECH 的客户端都能用**（不限于 sing-box）

适用于 `vless` / `vmess` / `trojan` 的 ws / grpc / h2 传输。

### 路径二：内核 ECH（TLS 由源站 sing-box 终结）

自己生成密钥对，服务端解密真实 SNI。

```bash
sing-box generate ech-keypair <你的域名>
```

会输出**两个** PEM 块，必须是配对的一对：

| PEM 块 | 给谁 | 配置字段 |
|---|---|---|
| `-----BEGIN ECH CONFIGS-----` | 客户端 | `tls.ech.config`（**内联完整 PEM，含 BEGIN/END 与换行**） |
| `-----BEGIN ECH KEYS-----` | 服务端 | `tls.ech.key_path`（权限 600） |

适用于 `hysteria2` / `tuic` 这类 QUIC 协议（它们没有 CDN 路径）。

**格式坑（都是实测踩出来的）**：

- 客户端字段是 `ech.config`，值是**内联完整 PEM**，含 `BEGIN`/`END` 行和真实换行
  - 只给 base64 正文 → `invalid ECH configs pem`
  - 把 PEM 压成一行 → 同样报这个错
- `ech.config_path` 是**本地文件路径**，服务端能用，客户端打不开
- `ech.configs` / `ech.keys` / `ech.server_keys` → `unknown field`
- 用 `jq -Rs . < file` 能正确转成 JSON 字符串（保留换行）

**只有 sing-box 客户端能用**：内核 ECH 的内联 PEM 形式 mihomo/Clash 不认。
转换器遇到这种节点会打印 `[注意] xxx: ech 用本地 config 文件, mihomo 无法表达`。

### 内核 ECH 能藏什么，不能藏什么

必须说清楚，否则容易高估它的作用：

| | CDN ECH | 内核 ECH |
|---|---|---|
| 内层 ClientHello 加密 | ✓ | ✓ |
| 外层 SNI 是无关域名 | ✓（`cloudflare-ech.com`） | ✗ **见下** |
| 服务器 IP | 隐藏（连的是 Cloudflare） | **暴露** |
| 端口 | 隐藏 | **暴露** |
| 时序 / 包大小 | 部分可辨 | 部分可辨 |
| JA3/JA4 指纹 | uTLS 可伪装 | uTLS 可伪装 |

**关键限制**：`sing-box generate ech-keypair <域名>` 生成的 `public_name`
**就等于你传进去的那个域名**（解出来的 ECH CONFIGS 里能直接看到）。
所以内核 ECH 只加密了 ClientHello 的**内层内容**，外层 SNI 仍然写着同一个域名 ——
对被动观察者来说，真实 SNI 并没有被藏住。`conf/lib.sh` 里对此有明确注释。

结论：内核 ECH 适合 hysteria2 / tuic 这类**必须直连**的协议，
价值在于不让 ClientHello 的细节（ALPN、扩展、ECH 本身）泄露协议特征，
而不是藏住域名本身。

---

## 传输方式（VLESS / VMess / Trojan）

| 菜单项 | sing-box `transport.type` | mihomo | 走 CDN |
|---|---|---|:--:|
| 1) ws（默认） | `ws` | `network: ws` + `ws-opts` | ✓ |
| 2) grpc | `grpc` | `network: grpc` + `grpc-service-name` | ✓ |
| 3) http (HTTP/2) | `http` | `network: h2` + `h2-opts` | ✓ |
| 4) httpupgrade | `httpupgrade` | `network: ws` + `v2ray-http-upgrade: true` | ✓ |
| 5) 裸 TCP | **不写 `transport` 字段** | 不写 `network` | ✗ |

几个必须知道的点：

- **裸 TCP 是"省略字段"，不是 `"type":"tcp"`。** sing-box 的传输类型里没有 `tcp`
  这个值，写上去会直接 `sing-box check` 报错。
- **mihomo 没有 `httpupgrade` 这个 network 值**，必须写成 `network: ws` 加
  `v2ray-http-upgrade: true`；只写 `network: ws` 会被静默降级成裸 TCP
  （表现为配置看着对、却连不上）。
- **gRPC 的 `service_name` 默认每个节点不同。** 如果所有节点都叫 `grpcSvc`，
  生成的 nginx 片段会出现多个同路径 location，nginx 直接报
  `duplicate location` 起不来 —— 一个节点的默认值能连带搞垮整份站点配置。
- **ALPN 跟着传输走**：grpc / http 自动用 `["h2"]`，其余用 `["http/1.1"]`，
  服务端入站、TLS 块、分享链接三处保持一致。

### uTLS 指纹

创建 Reality / AnyTLS / VLESS / VMess / Trojan / ShadowTLS 节点时会问，
默认 `chrome`，回车即用默认值，也支持直接输入英文名。

可选值（sing-box 1.14.2 逐个 `sing-box check` **实测**得出）：

`chrome` `firefox` `edge` `safari` `360` `qq` `ios` `android` `random` `randomized`

> `randomized-noalpn` / `safari-ios` / `ios_simulator` / `firefox_mozilla` /
> `opera` / `chrome_v2` 被内核拒绝，故不提供。mihomo 的 `-t` 不校验该字段
> （乱写也放行），所以以 sing-box 为准。

**不提供 uTLS 的协议**：

| 协议 | 原因 |
|---|---|
| naive | 内核明确 `uTLS is not supported on naive outbound` |
| shadowsocks | 无 TLS 层 |
| hysteria2 / tuic | QUIC 出站，`check` 放行但运行时 `unsupported usage for uTLS` |

> 最后一条是本项目判断支持度的核心教训：**`sing-box check` 通过不代表能用。**

---

## 多路复用（Multiplex）

把多条请求复用到一条连接上。只有 `vless` / `vmess` / `trojan` / `shadowsocks`
内核支持（`sb_mux_supported`），AnyTLS / Naive / Hysteria2 / TUIC 内嵌实现里没有。

### 档位

批量生成时的 ③ 提供三档（单个建节点时是手填参数）：

| 档位 | id | max_connections | min_streams | max_streams | 适用 |
|---|---|--:|--:|--:|---|
| 网页党 | `web` | 1 | 1 | 32 | 复用最大化，单条连接扛住所有并发 |
| 视频党 | `video` | 2 | 2 | 16 | 多一条并行通道，兼顾视频 + 网页（**默认**） |
| 下载党 | `download` | 4 | 4 | 64 | 多物理连接，为高吞吐和大文件 |

三个档位都是保守固定值，复用协议统一 `h2mux`（基于 HTTP/2 流，在 sing-box 里延迟最低，
与 ws/grpc 这类 CDN 传输也更契合）。

### 字段映射

| | sing-box | mihomo |
|---|---|---|
| 协议 | `multiplex.protocol` = `h2mux` / `yamux` / `smux` | `smux: { enabled: true }` |
| 并发上限 | `max_connections` | `max-connections` |
| 流数量 | `min_streams` / `max_streams` | `min-streams` / `max-streams` |

要点：

- **服务端不写 `protocol` 字段。** sing-box 的入站 multiplex 只有
  `enabled` / `padding` / `brutal`；`protocol` 出了站才有。服务端写了会 `check` 报错。
- **brutal 的服务端和客户端数值是镜像的。** 服务端 `up_mbps` 对应客户端的
  `down_mbps`，反之亦然（数据方向相反）。

### 关于 brutal 限速

菜单里的 brutal 默认 **上行 100 / 下行 200 Mbps**（可改），但先看清楚代价：

> **brutal 需要内核的 `tcp-brutal` 模块，而这个模块基本不存在。**
> 它是 out-of-tree 的（rimcoding/tcp_brutal），2023 年被标记归档废弃，从未合进
> Linux 主线。Debian 13 / 6.12 内核没有，apt 源里也没有包。开启后不是
> `sing-box check` 报错，而是**跑到一半才失败**：
>
> ```
> brutal exchange: remote error: enable TCP Brutal: setsockopt IPPROTO_TCP
> TCP_CONGESTION brutal: no such file or directory
> ```

所以本项目做了两件事：

1. 菜单里**先探测模块在不在**（`modinfo tcp-brutal`），不在就说明原因并跳过 brutal 选项，
   而不是让你配一个注定失败的参数。
2. 批量生成时同样跳过，并在输出里注明。

想要高 BDP 线路的吞吐，系统层开 **BBR** 就能达到同样目的，而且没有额外依赖。

---

## 其他选配

### TLS 分片（fragment）

客户端侧的抗 DPI 选项：把 ClientHello 切成多段、段间插随机延时再发，
让按"首包大小"分类的探针看不出这是 TLS 握手。

- 默认**关闭**。每个 ClientHello 多花 10~20ms，高频建连反而更慢；
  少数中间设备对分片 TLS 处理有 bug 会直接断连；已用 REALITY / ECH 的节点也不需要它。
- 建 TLS 节点时会问，选"开启"后可以填首片延时（默认 10ms）。
- REALITY 节点不提供这个选项（REALITY 本身就是更强的手段）。
- 和 `record_fragment` 不是一回事：`fragment` 切的是 **ClientHello 这条记录**，
  `record_fragment` 切的是之后的**每一条 TLS record**。这里只暴露前者。

### AnyTLS padding

`padding_scheme` 控制填充，让 AnyTLS 的流量形状更接近别的协议。
默认值取 sing-anytls 的内置默认值，不自己发明：

| 选项 | 默认 |
|---|---|
| 0) 关闭填充 | `stop=8` / `0=30-30` / `1=100-400` / `2=400-500,c,...` / `3=9-9,500-1000` / `4..7=500-1000` |
| 1) 简单 | `stop=8` |
| 2) 自定义 | 逐条填写 |

另外 AnyTLS 出站支持 `idle_session_check_interval` / `idle_session_timeout` /
`min_idle_session`（控制空闲会话的保活与回收），0 表示不写该字段。

### 服务端监听地址

服务端监听**固定双栈 `::`**，不询问。`::` 在 `bindv6only=0` 时同时收 IPv4 和 IPv6，
严格优于只收 IPv4 的 `0.0.0.0`，没有理由让你为一个更差的选项做选择。

只有走 CDN 时地址由接入方式决定（Cloudflare 直连 = `0.0.0.0`，
经 nginx = `127.0.0.1`），那是接入方式的结果，不是需要你选的东西。

需要区分 IPv4 / IPv6 的是**客户端产物里写哪个地址**（批量生成的 ①），那边保留选择。

### 切换产物地址族时改哪些地址（菜单 9 → 9）

**只替换确实指向本机的 IP**（`conf/addr_family.py`）：本机探测到的旧地址 + 本机
同族的其它公网地址。其余一律原样保留，并在结果里逐条列出：

| 产物里的地址 | 会不会被改 | 为什么 |
|---|---|---|
| 本机 IPv4 / IPv6 | **改** | 这是本功能的用途：产物从一族的地址换到另一族 |
| 域名（CDN 节点、手工填写、导入的节点） | 不改 | 地址族对域名没有意义；CDN 节点的域名是**故意**写的（走 Cloudflare，源站通常只听 `127.0.0.1`），换成源站 IP 就等于把 CDN 绕过 |
| 其它服务器的 IP（中转 / 导入的节点） | 不改 | 那不是本机地址，改了这些节点当场失联 |
| 私网 / WARP 等隧道地址 | 不改 | 指向别处或对外不可达，改了只会更糟 |

覆盖范围：`sb_client-*.json`（单节点 / 聚合 / CDN 版）、`sb_client-*.yaml`（含合并
YAML）、`sb_share-*.txt` 与 `sb_links-all.txt`（URI 链接，含 vmess 的 base64 地址）、
`share_tag-*.txt`（订阅 URL 的主机）。IPv6 会自动补方括号。

> 反例（旧实现的实际后果）：无条件改写会把 CDN 节点的
> `server: <证书域名>` 换成 `server: <源站 IP>`，于是产物直连源站、CDN 失效，
> 而分享链接里仍是域名 —— 同一个节点的两种产物给出的地址不一致。

---

## 客户端产物支持矩阵

产物由 `conf/to_mihomo.py` 生成（菜单 9 → 7 出合并 YAML、→ 8 出全部单节点 YAML）。
下表是把本项目能产出的全部「协议 × TLS 模式 × 传输」组合喂给各内核实测得出的，
**不是抄文档**：

| 组合 | sing-box | mihomo | xray |
|---|:--:|:--:|:--:|
| Reality（VLESS+REALITY，vision/grpc/http） | ✓ | ✓ | ✓ |
| VLESS / WS+TLS、VLESS / 裸TCP+TLS | ✓ | ✓ | ✓ |
| Trojan / TLS | ✓ | ✓ | ✓ |
| **AnyTLS / 普通 TLS** | **✓** | ✓ | ✗ |
| AnyTLS / Reality | ✓ | ✗ | ✗ |
| Hysteria2 / TLS | ✓ | ✓ | ✗ |
| TUIC / TLS | ✓ | ✓ | ✗ |
| VMess / WS+TLS、VMess / Reality | ✓ | ✓ | ✓ / ✗ |
| Shadowsocks / SS-2022 | ✓ | ✓ | ✓ |
| 内核 ECH（hysteria2 / tuic） | ✓ | ✗ | ✗ |
| CDN + ECH | ✓ | ✓ | ✗ |
| ShadowTLS（内层 SS-2022） | ✓ | ✗ | ✗ |
| NaiveProxy | ✗ | ✗ | ✗ |

**AnyTLS / 普通 TLS 这一格是实测出来的反直觉结论**，下一节展开。

---

## 已知不可用的组合

这些是实测确认**连不通**的组合。项目里已经撤掉相关预置或加了警告，
但结论值得写在这里，避免后人重新踩一遍。

### ~~AnyTLS + 普通 TLS：服务端在 ClientHello 阶段就 reset~~（**已推翻**）

> **本节原结论是错的，2026-10 更正并撤回。保留文字是为了说明这个坑是怎么踩的。**

**原结论**：AnyTLS 配普通 TLS（`certificate_path`/`key_path`）时连接必挂，
于是撤掉了全部 TLS 预置、批量强制走 REALITY。

**实际情况**：AnyTLS 原生 TLS **完全可用**，`check` 通过、真实连接稳定 8/8
（sing-box 与 mihomo 双内核各验一轮）。

**错因**：当时在测试机上临时起服务，那个端口**没在防火墙放行**，
CC 连过去是 `i/o timeout`。我把这个现象读成了"服务端在 ClientHello 阶段
reset connection by peer"，当成内核限制写进了文档 —— 实际上
`connection reset by peer` 和 `i/o timeout` 是两回事，前者才是应用层拒绝。

**复核方式**（可重复验证）：

| 条件 | 结果 |
|---|---|
| anytls + 自签/真证书，防火墙已放行 | 8/8 |
| 服务端有无 alpn × 客户端有无 alpn（四种组合） | 全部 8/8 |
| **删掉 ufw 放行规则，其余配置一字不改** | **0/6 `i/o timeout`** |

变量是防火墙，不是 alpn，也不是任何协议限制。中途还误判过一次「必须带
ALPN」，同样被这张表推翻 —— ALPN 在四种组合下都通。

**交叉验证**：[fscarmen/sing-box](https://github.com/fscarmen/sing-box)
（6852 行、社区使用量最大的一版）的 anytls 服务端与客户端**都不写 alpn**，
照常工作，与本项目实测一致。本项目仍给两端写 `alpn: [h2, http/1.1]`
（与服务端一致，无副作用），但那**不是**连不上的原因。

**代码影响**：已恢复 `lib.sh` 预置表里的
`① 自签 (pin)` / `② 真证书` 两项，移除了 `conf/anytls.sh` 里批量强制
`c=3` 的逻辑，并在 `to_mihomo.py` 补齐 anytls 的
`udp` / `idle-session-*` 字段。

### REALITY 的 dest 站点必须实测（**配置全对也可能 0/N**）

同样一份配置，**只改 dest 站点**，REALITY 节点可以从 5/5 变成 0/5：

| dest | 结果 |
|---|---|
| `openjdk.org` | **5/5** |
| `images-na.ssl-images-amazon.com` | **0/5**（客户端报 `connection reset by peer`） |

验证方式是**只改一个变量**：同一份密钥、同一端口、同一协议，只替换
`.tls.reality.handshake.server`，其余一字不动。已排除的变量：

- 服务端 `short_id` / 公钥与客户端完全匹配
- dest 站点从服务端可达、TLS1.3 正常、HTTP 200、时延 0.2s
- `multiplex` 开关、ws/TCP 传输、协议类型（trojan / vless 均复现）
- 对照组 `reality01`（dest = `openjdk.org`）同一时刻稳定 5/5

所以**不是配置错误，也不是内核限制**，是 REALITY 与该 dest 的握手兼容性。
`connection reset by peer` 在这里是服务端 REALITY 校验不过的表现。

**排查顺序建议**：先用已知可用 dest（`openjdk.org`）确认基础链路，再逐个
替换 dest 定位。整批节点如果都 0/N，第一个要怀疑的就是 dest —— 批量生成
会复用同一批 dest，一个不可用就拖垮全部 REALITY 节点。

> **教训**：判定"内核不支持某组合"之前，先确认端口在防火墙上是通的。
> 本项目已在多处踩过，**每次的真凶都是防火墙，不是内核**。
> 排查时用 `i/o timeout`（网络层没通）和 `connection reset by peer`
> （应用层拒绝）区分，前者一律先查防火墙。


### NaiveProxy：取决于内核是否用 CGO 编译（**原写"缺少 Cronet 库"，已更正**）

`sing-box check` 对服务端入站**通过**，节点能建、服务能起，但客户端产物连不上：

```
FATAL initialize outbound[0]: cronet: library not found
```

**原判断**：构建标签里有 `with_naive_outbound` 却没有 `with_cronet`，
所以官方发布版不含 Cronet 库。这条是**错的** —— 两个平台的
`sing-box version` 输出的 Tags 完全相同，naive 却一个能用一个不能用。

**真实条件是 CGO**。Cronet 需要 CGO，而官方发布版的 CGO 取舍按平台不同：

| 平台 | `sing-box version` 里的 CGO | naive 实测 |
|---|---|---|
| ARM64 客户端 | `CGO: enabled` | **可用**，`NaiveProxy started, version: 150.0.7871.63`，连通 5/5 |
| AMD64 服务端 | `CGO: disabled` | `cronet: library not found` |

与配置写法无关，换任何 naive 参数都是同一句报错。**客户端要用带 CGO 的
sing-box 构建** —— 官方 ARM64 发布版就是。

### Hysteria2 / TUIC + uTLS

`check` 放行，实际连接时返回 `unsupported usage for uTLS`。项目不提供这个选项。

### 内核 ECH 在 mihomo 上不可用

内联 PEM 形式只有 sing-box 客户端认。转换器会为这类节点打印：

```
[注意] tuic02-TLS-ECH: ech 用本地 config 文件, mihomo 无法表达
```

YAML 仍然会生成（只是少了 ech 字段），连得上但**没有 ECH 保护** ——
不要把"mihomo 能连通"误当成"mihomo 支持 ECH"。

### mihomo 不支持的组合

- **AnyTLS + REALITY** —— mihomo 官方原文声明不支持且不会支持
- **ShadowTLS** —— mihomo 无此独立出站类型（它只是 ss/vmess 的包装插件）

这些组合不会产出对应文件，并打印原因。

**REALITY + ws 传输也跳过**（2026-10 实测，**原写"trojan/vmess + REALITY"，已更正**）。

上一版的结论是错的。当时那批节点的 transport 恰好不同、dest 也没控制，
变量混在一起。做控制变量实验（同一密钥、同 short-id、同 dest=openjdk.org，
一次只换一个变量）后真实规律是：

| 传输 | vless | trojan | vmess |
|---|---|---|---|
| **TCP** | 5/5 | 5/5 | 5/5 |
| **ws** | 0/5 | 0/5 | 0/5 |

再固定协议为 vless、只换 dest（`www.mysql.com` / `apps.apple.com` /
`s0.awsstatic.com`）—— 全部 5/5，说明 **与协议无关、与 dest 无关，
只与传输层有关：mihomo 的 REALITY 不能配 ws**。

sing-box 客户端两种传输都能用，所以服务端配置照常生成，只是不给 mihomo
产出连不上的 YAML。

> 与其产出一份**看着正常、实际连不上的** YAML，不如跳过并写明原因。
> 服务端配置照常生成 —— 换 sing-box 客户端是能用的。

**URI 分享链接层面**（2026-10 用 mihomo 1.19.32 逐条实测，13 条 SB 链接）：

| 链接 | mihomo 能否解析 | 能否连通 |
|---|---|---|
| vless/trojan(shadowsocks)/hy2/tuic/ss/anytls(纯 TLS)/vmess(TLS) | 能 | 能（8/11 实测 204） |
| vless+REALITY | 能 | **能**（REALITY 只有 vless 在 mihomo 里可用） |
| trojan+REALITY / vmess+REALITY / anytls+REALITY | 能解析 | **连不通**（mihomo 的 REALITY 只支持 vless） |
| `naive+https://` / `shadowtls://` | **认不出** | —（mihomo 没有这两个独立出站；这两行会被**跳过**，不会打挂整条订阅） |

⇒ 给 mihomo 用的订阅，**REALITY 节点请用 vless 形态**；naive / shadowtls 的链接
只对 sing-box / xray 系客户端有意义。

---

## CDN / nginx 前置

能走 CDN 的协议只有 **VLESS / VMess / Trojan**（它们有 Transport 字段）。
其余 6 个是原生 TCP/UDP 或专用协议，Cloudflare 代理不了，只能直连。

### Cloudflare 侧

- 需要有**已接管**的域名
- 源站回源证书必须是 **CA 可信的**（自签一律拒绝）
- 面板会列出本机检测到的真证书让你选，不会替你申请证书
- 节点建好后**只监听 `127.0.0.1`**，源站端口不对外暴露

### nginx 侧

ws / grpc / http / httpupgrade 都能过 Cloudflare + nginx：

```nginx
server {
    listen 443 ssl;
    http2 on;                      # 缺这行 grpc 和 http(H2) 全废
    location /yourpath {
        grpc_pass grpcs://127.0.0.1:PORT;   # grpc / http(H2) 用 grpc_pass
        grpc_set_header Host $host;         # 不写 sing-box 会报 bad host
    }
    location /yourpath2 {
        proxy_pass https://127.0.0.1:PORT;   # ws / httpupgrade 用 proxy_pass
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
```

- `http2 on;` 必须写。只写 `listen 443 ssl;` 时 ALPN 会退回 http/1.1，
  grpc 和 http(H2) 的客户端握手直接失败。
- 节点开着 TLS 时 `grpc_pass` 必须用 `grpcs://`；用 `grpc://` 会 502
  （`recv() failed: Connection reset by peer`）。
- 别用 `proxy_http_version 2`：nginx 低于 1.29.4 会直接 `[emerg] invalid value "2"`。
- 面板会只读检查你的 server 块并提示是否缺 `http2 on;`，但**不会替你改**。

### CDN 汇总

批量生成结束时打印本次有多少节点走了 CDN。若是 0，通常是真证书没选对
（Cloudflare 不接受自签回源）。

---

## 分享链接分发

菜单 3，或：

```bash
bash src/conf/share.sh create reality01 1 24      # tag 次数 有效期(小时)
bash src/conf/share.sh create hysteria01 10 168
bash src/conf/share.sh list
bash src/conf/share.sh toggle <token|tag>          # 立即禁用
bash src/conf/share.sh del|regen <token|tag>
bash src/conf/share.sh check all                   # 生成后一致性校验 (只读)
# 存储: 公共基础服务 proxy-share-service (provider=sing-box, 默认 :9443,
#       端口由 share_client.py 读, 不写死) —— 与 mihomo / xray 共用一套存储
```

- URL 仅含 128-bit 随机 token，**不**包含任何节点信息；返回完整客户端 outbound JSON

### 三家互通：地址上的内核声明 + 两条产品（URI 普通话 / 原生 sing-box JSON）

SB 的分享地址**自己声明**"我是哪个内核的哪个发行版、我提供哪些格式、每种格式从哪取"：

```
http://<host>:9443/share/<token>?interop=1&kernel=sing-box&distribution=sing-box
   &version=1.14.2&formats=uri,sing-box&url-sing-box=<原生 token 的地址>
```

* **主产品 = 普通话 = URI 列表**（一行一个分享链接）：xbd / mihomo / 第三方面板都能读。
  改前 SB 的主产品是 sing-box JSON —— `xbd` 报"订阅里没有解析出节点"、mihomo 报
  `file must have a 'proxies' field`，两格**恒失败**（跨生态格式边界）。
* **附带产品 = 原生 = sing-box JSON**：只有同内核同发行版的客户端读，没有 URI 那层损失。
  同内核客户端读声明后**自动**拉原生 —— 与改前**逐字节相同**的那份内容。
* 声明放**查询串**：公共分享服务的路由先剥查询串再分发（`share_service.py:768`），所以
  带声明与裸地址返回**逐字节相同**，对第三方客户端零影响。响应头 / `/meta` 两条路都被
  冻结的公共服务堵死（设计文档 `proxy-node-compat/docs/three-way-interop.md` §1）。
* **客户端决策**（`src/client/client.sh`）：同内核同发行版 → 原生；跨内核 / 声明缺失 /
  声明不认识 / 发行版不在清单 → 普通话。原生取件失败（网络/404/空）**回退**普通话并把
  原因打出来。日志一行：`本次拉取: 原生 sing-box JSON —— …` / `本次拉取: 普通话 URI 列表 —— …`。
* **发布前四道闸门**：节点集合一致（两条产品同源）→ **链接校验**
  （`src/conf/link_guard.py`，与 `tools/check_share_links.sh` 同一份规则）→ **URI 表达力标注**
  （`src/conf/uri_express.py`，注册表驱动；URI 装不下的能力与 UNKNOWN **都打出来**）→
  与真实配置一致。任一不过 = **拒绝发布**。
* 一条分享是**两条记录**（主 + 附带原生）：停用 / 撤销 / 改次数 / 重建 token **成对**生效，
  只动主记录会留下一条还活着的原生分享（这个错误是静默的）。
* 门禁：`tools/check_share_links.sh`（含 F 段"声明/决策/回退链"断言与 E 段对角线）、
  `tools/check_compat_wiring.sh`（接线断言）；端到端验证台 `tools/interop-e2e.sh`
  （真 `share.sh create` + 真分享服务代码独立实例 + 真 `client.sh add`，可用
  `SB_E2E_CORPUS=/root/catmi/sing-box` 直接吃真实部署的只读拷贝）。
  真机验收：`proxy-node-compat/research/integration/three-way-interop-sb.md`。
- `max_uses` / `expires_at` / `enabled` 三类独立失效，均可显式 DENY(410)
- 并发安全：flock 串行 read-modify-write，10 并发抢 1 次授权仍只放行 1 个（已实测）
- 客户端只有**收到完整 200 响应**才计数；服务端配置异常一律 `503` 且不消耗次数
- **删除任何节点会自动清理其 share token** 并刷新 all 聚合，不会把已删节点悄悄分发出去
  （这条承诺一度失效：存储搬到公共服务后，删除路径只扫了**旧的本地目录**
  `share/shares/`，等于空转 —— 记录留在服务里、内容冻结在"已删节点的客户端配置"，
  而刷新逻辑找不到产物只能跳过，那条链接**永远不会自愈**。现已补上公共服务侧下架。）

### 分享内容 vs 真实监听：生成后一致性校验

分享内容 = `out/sb_client-<tag>.json` 的**字节副本**（不做二次渲染，所以不存在
"分享层与产物不一致"）。但副本在创建那一刻**冻结**，于是有另一类不一致：
**产物 vs 真实配置/监听**。发布前现在会过一遍 `sb_share_consistency_check`：

1. 内容里每个 outbound 的 tag 必须能在 `config/*.json` 的 `inbounds[].tag` 找到
   （兼容聚合产物的 `<服务器前缀>-` 前缀与 shadowtls 的内层 `<tag>-out`）；
2. 直连节点的 `server_port` 必须等于该 inbound 的 `listen_port`
   （CDN 节点跳过：它只听 `127.0.0.1`，客户端走 `域名:443`，两者本来不同）；
3. 端口当前是否真的在监听（`ss`）—— 只告警不拦（刚写完配置还没 reload 会短暂为假）。

**不一致就拒绝发布**（并把具体节点打出来），绝不发死节点。刷新路径同理：产物已经
不存在（节点被删）的记录会被**直接下架**，而不是留在服务里继续发旧内容。

### 链接格式：几条会让对方**整条订阅归零**的硬规矩

`tools/check_share_links.sh` 把这些规矩固化成回归检查（可在服务器上直接跑，
支持 `--out-dir DIR` / `--fix` / `--no-gen`），断言：

| 规矩 | 违反后果（mihomo 实测） |
|---|---|
| hy2 不写无效 obfs（`obfs=none` / 空密码） | `missing obfs password` → provider **0 节点** |
| 真开混淆时 `obfs=salamander` 必须带非空密码 | 同上 |
| `vmess://` 必须是 base64(JSON)，含 `ps` 与标准 `id`，且**结尾不加 `#片段`** | `convert v2ray subscribe error: format invalid` → **0 节点** |
| vmess+REALITY 必须写成 `vmess://`（不能写成 `vless://`） | vless 链接错误：`invaild vless encryption value: aes-128-gcm` → **0 节点**；而且协议本身就错 |
| `vless://` 的 `encryption` 只能是 `none` | 同上（这是"vmess 被误标成 vless"的指纹） |
| 链接里的 `sni` 不能是 IP | `x509: cannot validate certificate for <IP>` |
| hy2 / tuic 必须带 `alpn` | 部分中间设备/客户端直接握手失败 |

`--fix` 会把**已经发出去**的老产物（旧代码生成的 `out/sb_share-*.txt` /
`out/sb_links-all.txt`）里的无效 obfs 参数就地删掉；`vmess://` 的老形态无法原地
修好（字段名与片段都在 base64 里），删掉节点重建即可。

### 门禁: 「SB 分享 → SB 客户端」对角线必须一直能跑通

用户点名的一条红线：**自家分享给自家客户端，不能自己认不出来**。这不是假想 ——
mihomo 侧真的断过一次（加旗帜命名把自家分享生成打成 0/19，整条不可用）。

```bash
# 服务端: 发一条聚合分享, 拿到 URL (token 用完/过期就再发一条)
bash src/conf/share.sh create-all 8 1

# 客户端机 (装过 sb-client 的机器): 跑门禁的 E 段
bash tools/check_share_links.sh \
     --share-url http://<server>:9443/share/<token> \
     --client-bin /opt/sb-client/core/sing-box
```

断言四件事（缺一即 FAIL）：

1. 走客户端**真实入口** `client.sh add <url>`（CLI 分派直接调 `add_node`），
   导入节点数**非 0** 并打印具体数字；
2. 导入后的客户端配置 `sing-box check` 通过；
3. 至少一条真连 204；
4. 生产 `sb-client` 的 MainPID 前后不变（隔离没漏）。

隔离做法：`CLIENT_ROOT`/`CONF`/`NODES` 全部指向 `mktemp` 目录，只调 `add_node`
**不调 `apply_change`/`do_start`**，所以不会重启生产服务；若 `/etc/sb-client.env`
把 `CLIENT_ROOT` 抢走，这一段立刻 fail-closed 退出。

实测基线（CC 真机 arm64 + sing-box 1.14.2 内核）：**13 节点导入 / check 通过 /
真连 204**；改前（`7009d93`）与改后（本次修复）逐项一致 —— 对角线没有倒退。

> 注意区分**修复在仓库 HEAD** 与**修复已分发到某台服务器**：改完代码不等于
> 现网产物就变了 —— `out/` 里的链接是**生成时**写下的快照，节点不重建就不会变。
> 升级后请跑一次 `check_share_links.sh`（看 `--out-dir` 那段的结论）。

---

## 客户端面板

`src/client/client.sh`：

```bash
bash src/client/client.sh install           # 内核 (arm64/amd64, glibc/musl 回退)
bash src/client/client.sh init             # 建配置 + 装 sb-client.service + 自动启动
bash src/client/client.sh add http://<server>:9443/share/<token>   # 公共分享服务端口 (不写死, 见 share_client.py)
bash src/client/client.sh list|del|update  # 多节点池 (share 来源去重)
bash src/client/client.sh start|stop|restart|reload|status|check
bash src/client/client.sh service          # 只安装/更新 systemd unit
bash src/client/client.sh install-ui       # metacubexd (Clash API UI)
```

### 节点的三种来源

面板的「添加节点」不只认自家 share 服务给的 sing-box JSON，它会**先识别格式再转换**，
以下都能直接喂进去：

| 格式 | 例子 | 处理方式 |
|------|------|----------|
| sing-box JSON | 自家 `share/<token>` | 内核直接认，原样导入 |
| base64 订阅 | 整份 base64，解开是一堆 URI | 解码后逐条转 |
| 明文 share URI | 一行一个 `vmess://` `vless://` `trojan://` `ss://` | 逐条转 |
| mihomo YAML 片段 | `- name: Browser-Dialer` + `type: socks5` … | 取 proxies 转 |
| mihomo 整份 YAML | 含 `proxies:` 段 | 只取 proxies，忽略 rules |

转换器是 `src/client/to_sb.py`，安装时复制到客户端的 `share-state/to_sb.py`。
只用标准库，PyYAML 有就用、没有就降级到内置的平铺 YAML 解析器（用户手贴的
片段本来就是平铺的，够用）。识别不了的条目**跳过并计数，不猜**。

支持的协议：vless / vmess / trojan / shadowsocks / socks5 / http / hysteria2 /
tuic / anytls / snell / wireguard。

**外部订阅一律加前缀。** 订阅里的节点名多半是裸的（`anytls01-TLS`），不加前缀
就会和自己的节点重名 —— 重名的后果是静默覆盖旧的、面板还报 `[OK]`。面板会先问
前缀，默认从域名猜（`sub.example.com` → `sub`），回车即用，也可以自己输入。

### 订阅管理

外部订阅会登记进 `subscriptions.json`，「订阅管理」页可以**列出 / 更新 / 删除**：

- 更新 = 重拉该订阅并**重建它名下的节点**（先删旧节点，否则改名后会留下孤儿）
- 删除订阅 = 连同它的节点一起删

### 简易 HTTP / SOCKS 节点

客户端机器上常还跑着别的内核（mihomo / sing-box / v2ray），想让本客户端把它们
当成**出站**用 —— 在 `PROXY` 选择器里多一个选项，选它就走那个端口出去。

```bash
# 菜单 4, 或者
{"type":"socks","tag":"...","server":"127.0.0.1","server_port":1080}
{"type":"socks","tag":"...","server":"...","server_port":1080,"username":"u","password":"p"}
{"type":"http","tag":"...","server":"...","server_port":8080}
```

- **目标地址默认 `127.0.0.1`** —— 链本机上另一个内核是最常见用法；接别的机器直接输入 IP/域名
- **用户名 / 密码留空 = 不认证**（就不写进配置）；填了就两个一起写入
- 端口做 1–65535 校验：`sing-box check` 放行 `server_port: 0`（语法合法、运行时才炸），这种错提前拦

> 这是**出站**（客户端主动连出去），不是在本机开一个 socks 入站端口给别人连 ——
> 后者是 mixed-port `:2080` 的事，两者方向相反。

- 端点：HTTP + SOCKS5 同口 **`:2080`**，LAN 设备直接填这个地址
- Clash API `:19090`（secret 保护）；metacubexd UI `http://<client-ip>:19090/ui/`
- 多节点 = selector `PROXY` + urltest `AUTO`（`final=PROXY`）
- **不实现 TUN / 透明代理 / FakeIP**（有意避免）
- 节点增删改与端口变更**自动应用**（`ExecReload` 为 `kill -HUP`，零断流软重载）
- 状态判定分层：systemd 单元 → 进程（按 `/proc/<pid>/exe` 精确匹配）→ 端口监听
  → 配置检查 → 真实连通性，可以区分「未运行 / 启动失败 / 未初始化 / 配置异常」
- 端口冲突：`sing-box check` **不检测端口占用**，冲突只在启动时暴露
  （`bind: address already in use`）。面板用 `ss` 预检并在写入前拦截

### 局域网配置分发

让同一局域网里的其他设备（手机、平板、另一台电脑）通过一个 URL
拉走**这台客户端当前的完整配置**，导入到它们自己的 sing-box 里直接用。

面板主菜单 `19` 进。启动后它会打印**两个**地址：

```
http://<本机地址>:9293/sub/<32位随机token>         # 只有节点 + DNS
http://<本机地址>:9293/sub/<32位随机token>/tun     # 额外带 TUN 入站
```

其他设备把地址当成「订阅 URL」导入即可 —— 拿到的是**出站 + DNS +
路由规则**的全套配置，不是单条节点链接。

**该用哪个地址**

| 客户端 | 用哪个 | 原因 |
|---|---|---|
| **sing-box for Android (SagerNet)** | **`/tun`** | 见下 |
| **Windows / Linux 命令行 sing-box** | **`/tun`** | 命令行不会自己造入站 |
| 带 TUN 开关的 GUI 客户端 | 不带 `/tun` | 客户端自己会注入 TUN，重复注入会冲突 |
| 只想把节点并进已有配置 | 不带 `/tun` | 不会覆盖你现有的入站 |

> **为什么 SagerNet 必须用 `/tun`**：它的 `PlatformInterface.openTun()` 里
> 写着 `error("android: tun inbound requires VPN service")` —— 走的是 Android
> 的 `VpnService`，**只有配置里存在 tun 入站时它才会去启动**。
>
> 少了 tun 入站时的症状很有迷惑性：节点、分组、延时**全都正常显示**，
> 点「启动」也**不报错**，但状态栏永远不出 VPN 图标，手机流量压根没进代理。
> 因为延迟测试是 App 自己发起的请求，不经过 TUN。

**分发出去的内容**

| 字段 | `/tun` | 不带 `/tun` | 说明 |
|---|---|---|---|
| 出站（节点 / 分组 / PROXY / AUTO） | ✅ | ✅ | 全部分组原样带过去 |
| DNS（DoH 服务器、策略） | ✅ | ✅ | 防泄露 DNS 一并带过去 |
| 路由规则 | ✅ | ✅ | `hijack-dns` 等规则原样带过去 |
| `inbounds` | ✅ 仅 tun | ❌ | 见下 |
| `route.rules[0] = sniff` | ✅ 自动插入 | ❌ | 见下 |
| `experimental` | ❌ | ❌ | 见下 |

**为什么 `/tun` 版不写 `stack` 字段**：省略即默认 `system`，覆盖面最广。
曾经写成 `mixed`，结果手机直接起不来：

```
start inbound/tun[tun-in]: gVisor is not included in this build,
rebuild with -tags with_gvisor
```

`mixed` 的语义是「system 的 TCP + **gVisor 的 UDP**」—— 也就是说 TCP 走内核态，
**UDP 那一半仍然要 gVisor**。官方 App 和多数第三方内核没有 `with_gvisor`
构建标签，必然踩这个坑。

三个容易踩的点：

1. `sing-box check` **不验证 gVisor 是否真编进内核**，要到 `start inbound`
   时才报错。所以本地测永远是绿的，只有真实用户设备才暴露 —— 这个 bug
   靠测试发现不了，只能靠「不发可能不兼容的值」来躲。
2. `stack` 字段在 sing-box 1.15.0 已废弃，1.17.0 移除。不写它，新版本也
   不会报 deprecated，语义还正好是想要的 `system`。
3. 想要 gVisor 只能让对方换一个带 `with_gvisor` 标签的内核，改配置解决不了。

**为什么默认不带 `inbounds`**：别的设备要用 TUN 还是 SOCKS、监听哪个端口，
是它自己的事。把本机的 `2080` 硬塞过去，既可能端口冲突，也可能把它的本机
代理暴露出去（`listen: 0.0.0.0`）。需要 TUN 时用 `/tun` 那个地址，那份里
只有 tun 一个入站。

**为什么 `/tun` 版会自动插入 `sniff` 规则**：TUN 进来的流量只有 IP 没有
域名，没有 sniff 就只能按 IP 分流，规则会失准。sniff 必须排在规则最前面。

**为什么 `/tun` 版会重排 `hijack-dns` 规则**：这是让手机「图标出来但完全
没网」的真正原因。面板生成的规则顺序是：

```
[0] ip_is_private -> direct
[1] protocol=dns  -> hijack-dns
[2] port=53       -> hijack-dns
```

在 mixed 入站下这个顺序没问题（客户端自己解析域名，sing-box 看不到 DNS
查询）。但 TUN 模式下会彻底断网：

- TUN 的 DNS 地址是 `172.19.0.2`（`address` 里第一个 IPv4 条目的下一个地址，
  官方文档的默认行为）
- `172.19.0.0/12` 是私有地址段
- 于是**每一个 DNS 查询都先命中 `[0] ip_is_private -> direct`**，被当作
  「内网流量」直连出去，发到 `172.19.0.2` —— 而那里什么都没有

现象是 VPN 图标正常出来，但一个网页都打不开，因为连域名都解析不了。
`/tun` 版因此把 `hijack-dns` 提到 `ip_is_private` 之前：

```
[0] sniff
[1] hijack-dns  dns
[2] hijack-dns  53
[3] ip_is_private -> direct
```

注意这个重排**只发生在 `/tun` 版**。面板自己跑在 mixed 入站上，那个顺序
对它是对的 —— 所以不去动 `regen_selector`，只在分发时调整。

**为什么去掉 `experimental`**：`clash_api.external_ui` 是本机绝对路径
（`/opt/sb-client/ui`），在别的设备上根本不存在，保留只会报错。

**刷新是实时的**：服务端每次请求都重新合并 `conf/` 下的配置片段，不读
预生成的快照。所以在面板里加节点、删节点、更新订阅之后，别人下一次拉取
拿到的就是最新的，不需要重启任何东西。

**访问控制**：URL 里的 token 是 32 位随机十六进制，局域网里没有它的人
拉不到。token 校验失败返回 404（不是 403 —— 不告诉探测者「这个路径存在
但你没权限」）。菜单里可以随时重置 token，旧链接立即失效。

**端口**：默认 `9293`，不与 mixed（2080）或 Clash API（19090）冲突。
改端口在 `client.sh` 顶部的 `SUB_PORT`。

**服务常驻**：安装成 `sb-client-sub.service`（systemd，开机自启）。
没有 systemd 时退回 `setsid` 临时进程 —— 此时面板退出后服务仍在，但
重启机器就没了。

> 注意：这个功能和「分享链接分发」是两回事。
> 分享链接分发每次生成的都是**一次性**链接（`max_uses: 1`），
> 给别人临时用一条；配置分发是**固定地址**，给自家设备长期用。

---

## 卸载

```bash
bash conf/uninstall.sh       # 1) 卸载 SB 整套  2) 仅停服务
```

停止并移除仅 SB 自家的 systemd 单元（`sing-box.service` / `sing-box-share.service`），
可选删数据目录 `/root/catmi/sing-box`。

**绝不触碰**其它 systemd 服务、证书（`/etc/letsencrypt` 等）、客户端侧 `sb-client`。
删除前会显示确切影响范围，必须 `yes` 确认。

---

## 说明

- 本项目面向**个人自用 / 小规模部署**，不是通用生产级面板
- 端口冲突、证书续期、CDN 配置这些需要你自己在系统层处理，面板只做检查和提示
- 文档里所有实测结论基于 **sing-box 1.14.2 / Debian 13 (6.12 内核)**，
  升级内核版本后请重新验证