# SB-Panel — Sing-box 服务器/客户端管理面板

> **catmi.singbox** (ラ · Sing - Box)
> 一个开箱即用的 **个人 Sing - box 服务端 + 客户端** 面板，
> 通过一个统一的中文菜单界面，不需要学习任何内部协议或文件结构。
> 支持多协议节点管理、分享链接、网络分流、节点生成、一键部署。

---

## 一键安装

### 直接一键安装
```bash
bash <(curl -Ls https://raw.githubusercontent.com/mi1314cat/sing-box-core/refs/heads/main/install.sh)
```
```bash
# 备用源（若 raw.githubusercontent.com 不可直连）
bash <(curl -Ls https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh)
```

执行后自动列出菜单：**1) 服务端 (Sing-box 面板 + 内核 + 分享服务)** / **2) 客户端 (LAN HTTP/SOCKS + Web UI)** / **0) 退出**，按提示选即可。
已有安装时输入 `u` 可热更新管理脚本，不会动其他部署。

---

## 项目结构（脚本家族风格 = xray-panel.sh / conf/http.sh）
### 1 服务端面板 (`bash sb-panel.sh` 或 `bash src/sing-box.sh`)
- **1** 安装/内核  
- **2** 节点管理 / 每协议子菜单  
- **3** 分享链接管理  
- **4** 网络（端口转发 / DNS / 规则集 / **出站管理 & 域名分流 & 入站绑定出站**）
- **5** 服务管理（启动/停止/重启/软重载）
- **6** 校验配置 + 重载
- **7** 查看日志
- **8** 列出全部配置文件
- **0** 退出

### 2 客户端面板（CC, `bash sb-client`，无参进入）
- **1** 安装内核 · **2** 初始化基础配置 · **3** 添加节点 (share-url)  
- **4** 删除节点 · **5** 列出节点 · **6** 更新节点 (重拉 share)  
- **7** 启动 · **8** 停止 · **9** 重启服务 · **10** 查看状态  
- **11** Web UI / Clash API 信息 · **12** 配置检查 · **0** 退出

---

## 协议说明（sing-box v1.14.1 核心支持的、SB-Panel 都提供）

| # | 协议 | 伪装 / TLS / Reality | 传输 | 备注 |
|---|---|---|---|---|
| 1 | **VLESS-Reality** (Vision / gRPC / HTTP2) | Reality 必选, 或 TLS / XTLS-Vision · 或 自签+SPKI-pin | TCP / gRPC / HTTP2 | flow `xtls-rprx-vision`, 客户端用 `flow` 字段一致 |
| 2 | **Hysteria2** (UDP/QUIC) | 自带 TLS (真证书 / 自签+SPKI pin), 支持 **obfs=salamander** | UDP+QUIC | sing-box 1.14 原生带 `quic` 传输；可随意混立于同一面板 |
| 3 | **AnyReality** (AnyTLS + Reality) — 选配 | AnyTLS 单独可用 / 可叠加 REALITY | TCP | 本身一种 `tls.reality` 增强型 anytls，与 VisionVLESS 共用同一密钥对 |
| 4 | **VLESS (WS + TLS)** | 真证书或自签 SPKI pin | WS (http/1.1) 可叠加 Cloudflare CDN | |
| 5 | **Shadowsocks - 2022**（推荐） | AEAD-2022 系最新 | TCP + **UDP over TCP (UoT)** | `2022-blake3-aes-128-gcm` (x86 默认) / `2022-blake3-chacha20-poly1305` (ARM 默认) / `2022-blake3-aes-256-gcm` (可选) |
| 6 | **TUIC v5** (UDP/QUIC) | QUIC TLS (真/自签+pin) — 不支持 Reality | UDP | 与 Hysteria2 共存 |
| 7 | **VMess** | ws+TLS / ws+Reality / 裸 ws | ws/grpc/h2/tcp | |
| 8 | **Trojan** | TCP+TLS / TCP+Reality | TCP | Reality 同样支持 (基于 sing-box for Reality 方式), 服务端不需要证书 |
| 9 | **NaiveProxy** (HTTP/2) | 真证书 / 自签+SPKI pin | HTTP/2 | 与 Chrome cronet 高兼容 |
| 10 | **ShadowTLS v3** (内层 SS-2022) | 真站 TLS 伪装层 + AEAD | TCP | “SS-2022 + 现代混淆” 方案 |
| — | **Shadowsocks Reality** | — | — | **不支持**（SS 无 TLS 层, 不适用 Reality; sing-box 的 Reality 只在 TCP+TLS 协议上工作）|

**协议选择推荐**
- 高隐蔽 + 高兼容：`VLESSREALITY (vision)` 
- 传输速度最高：`Hysteria2` + `obfs=salamander`
- 要 UDP 游戏/通话：Hysteria2 / TUIC / `Shadowsocks`+UoT
- 全淡肤 / 复用 Cloudflare CDN：VLESS+ws+TLS / VMess+ws+TLS
- 无证书配置：`ShadowTLS v3+SS-2022` / `Reality` 系所有协议
- 极简单文件 / 携带 payload：`Shadowsocks-2022`

---

## 分享链接服务（面板菜单 3）
管理界面：
```text
 1) 生成链接 (选节点)
 2) 生成全部节点链接 (一个链接带全部)
 3) 列出全部链接
 4) 删除链接
 5) 禁用/启用 (toggle)
 6) 重新生成 token (regen)
 0) 在全量 panel 内做一体; CLI: bash conf/share.sh [create|regen-aggregate|list|del|toggle|regen]
```

参数：
- `max_uses`: `0=不限` / `N=次数`（大于 0 按次消耗）
- `ttl_hours`: 有效期 (`0=永久`, 或选择菜单 1h/24h/7d/30d/自定义)

生成的 all-share URL (例如) :
```
http://<server-ip>:9292/share/<token>
```
内容（outbounds 全量合集）:
- **outbounds** (所有节点 tag 名称 + 客户端 outbounds + `PROXY` 选择器 + `AUTO` urltest)
- `route.final=PROXY`, `PROXY.all = [all-节点 tag]`

**服务端停机时：share 服务返回 503 且不消耗额度**（`do_HEAD` 支持, 订阅客户端健康探测正常）。
**删除节点时：引用该节点的分流/绑定规则自动切回 `direct`**（默认出站保护/失败回退）。

---

## 默认出站保护 + 失败自动回退 (类似于 xary-core 的 selftest)
删除或自检任一自定义出站前会尝试 2-3 次 HTTP 204 请求：
- **通过** → 按可用处理
- **失败** → 自动将**所有**引用此 tag 的分流/绑定规则切回 `direct`；文件移到 `.quarantine/`。信到规则永远有出口，不让某个转发节点挂掉影响全量流量。

涉及菜单：`4. 网络 → 4) 出站管理 → 9) 全量自检`

## 域名分流 & 入站绑定出站
```text
 主面板 → 4. 网络 → 4. 出站管理 →
 4) 域名分流 (添加规则: 指定域名 → 指定出站)
 5) 域名分流 (列出规则)
 6) 域名分流 (删除规则)
 7) 入站绑定出站 (添加)
 8) 入站绑定出站 (删除)
 9) 出站自检+失败自动回退 direct (全量自检)
```
示例:
```json
// config/03-route.json
{ "route": { "rules": [
    { "domain_suffix": ["ipinfo.io"], "outbound": "custom" },
    { "inbound": ["reality01"], "outbound": "direct" }
  ],
  "default_mark": 4
}}
```

---

## 安装

### 一键 (最常见)
```bash
bash <(curl -Ls https://raw.githubusercontent.com/mi1314cat/sing-box-core/refs/heads/main/install.sh)
```
或克隆仓后任意使用:
```bash
git clone https://github.com/mi1314cat/sing-box-core
cd sing-box-core
bash install.sh              # 交互式添加 server / client
```

### 手动 (server)
```bash
bash src/sing-box.sh init
bash src/sing-box.sh status
```
默认路径：
- Server:  `/root/catmi/sing-box`
- Client:  `/opt/sb-client`  
- 分享服务端口：`9292` (`/etc/systemd/system/sing-box-share.service`)

客户端 (Client):
```bash
sb-client add <share-url>
sb-client     # 进入交互面板 [客户端·CLIENT]
```

---

## 面板图标 & 角色
```text
                       |\__/,|   (\
                     _.|o o  |_   ) )
   -------------(((---(((-------------------
                   catmi.singbox
   -----------------------------------------

SB-Panel — Sing-box 管理脚本   [ 服务端 · SERVER ]     ← 角色徽标, 一眼分辨服务端/客户端
```

## 卸载 (不影响 other 服务)
```bash
bash conf/uninstall.sh       # 停 sing-box.service / sing-box-share.service, 不碰 other 服务
```

## ⚠ 版本与 Connections
- **sing-box 内核版本**: v1.14.1
- **SSH Connect**：`bash <(curl -Ls .../install.sh)` 亦可静态下载安装脚本 
- **sing-box 内核**：`src/conf/*.sql` 各协议生成模块独立、模块解耦
- **分享服务器**: 基于 python3 + flock( file-lock 共享只读对话框，Quqeue 与 concurrent consumed)
