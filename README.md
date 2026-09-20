
## 协议 → TLS/Reality 能力矩阵 (sing-box v1.14.1, 实测核验)
| 协议 | 不带 TLS | TLS | Reality | 备注 |
|---|---|---|---|---|
| VLESS (Reality/vision/grpc/http) | ✗ | ✓ | ✓ | 客户端 flow=xtls-rprx-vision |
| VMess (ws/grpc/h2/tcp) | ✓ (裸 ws) | ✓ | ✓ | 选择 4) Reality 时走 vmess+REALITY |
| Trojan (TCP+TLS) | ✗ | ✓ | ✓ | 服务端 reality.handshake 反向 |
| AnyTLS (+REALITY) | ✓ | ✓ | ✓ | 通过 `tls.reality` 挂上即成为"AnyReality"，**选配**，非必配 |
| Hysteria2 (UDP/QUIC) | ✗ | 仅自身 TLS (real/自签+pin) | ✗ | Reality 是 TCP-TLS 方案, QUIC 协议不适用 |
| TUIC v5 (UDP/QUIC) | ✗ | 仅自身 TLS | ✗ | 同上 |
| Naive (HTTP/2) | ✗ | 仅自身 TLS | ✗ | **顺序** sing-box 使用 LE 真证书或 `tls.CertificateAuthority`; 自签仅 SPKI pin (客户端支持) |
| ShadowTLS | unset TLS (伪装端口) | ✓ 内层 SS-2022 | — | 本身就靠 TLS 伪装；Reality 不适用 |

可见："Reality" 只在 sing-box 基于 TCP+TLS 的连接上有意义 (VLESS/vmess/trojan/AnyTLS)。UDP/QUIC 系 (Hysteria2/TUIC) 不走 Reality。

## Shadowsocks 支持 (sing-box v1.14.1, 已实测核验)
| 指标 | 状态 |
|---|---|
| 方法 (`method`) 支持 | `2022-blake3-aes-128-gcm` / `aes-128-gcm` / `aes-256-gcm` / `chacha20-ietf-poly1305` 等 全部支持 |
| **旧版** AES-CFB / rc4 等已废弃算法 | **服务端已不可用**（sing-box 1.14 `initialize inbound: unsupported method`；仅**出站**兼容） |
| 我们部署的协议版本 | **SS-2022 (最新)**, 加密 `2022-blake3-aes-128-gcm`(默认)/`2022-blake3-aes-256-gcm` |
| UDP 转发能力 | 客户端 `udp_over_tcp: true`--- UDP over TCP (UoT 协议, sing-box 1.11+ 新增) —— 本次 SS 客户端配置已添加 (by-new) |
| UoT | 服务端无需显式打开, 客户端侧配置 `udp_over_tcp: true` 转发 |
| 密钥格式 | SS-2022: `base64` 每字节 16字符 (aes-128) 或 32字节 (aes-256), 严格校验, 不接受弱 key |

="