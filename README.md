# vless-wss-rs

纯 Rust 编写的 VLESS WebSocket + TLS 服务端，体积小（静态二进制），零运行时依赖。

## 功能特性

- VLESS TCP over WebSocket + TLS
- Let's Encrypt 证书（acme.sh DNS-01 自动申请，支持 Cloudflare）
- 支持任意 CDN（如 Cloudflare）
- 纯 Rust，无 OpenSSL 依赖
- 静态编译，无需运行时

## 一键安装（自动模式）

```bash
curl -sL https://raw.githubusercontent.com/qaz69s/vless-wss-rs/main/install.sh -o /tmp/install.sh && bash /tmp/install.sh
```

交互式向导，输入 Cloudflare API Token 后全自动完成（随机子域名生成 → DNS 录入 → 申请证书 → 启动服务）。

## 一键安装（手动模式）

已有证书文件时选择手动模式，指定证书路径即可。

## 手动运行

```bash
vless-wss-rs \
  --cert /root/.acme.sh/example.com_ecc/fullchain.cer \
  --key /root/.acme.sh/example.com_ecc/example.com.key \
  --domain example.com \
  --uuid 你的UUID \
  --listen 0.0.0.0:443
```

## 所有参数

| 参数 | 说明 |
|------|------|
| `--cert` | TLS 证书文件 (PEM)，必填 |
| `--key` | TLS 私钥文件 (PEM)，必填 |
| `--domain` | 域名（用于生成 VLESS 节点链接），必填 |
| `--uuid` | VLESS 用户 UUID，必填 |
| `--listen` | 监听地址 [默认: 0.0.0.0:443] |

## 工作原理

1. 客户端通过 TLS + WebSocket 连接
2. 服务端读取第一个二进制帧（VLESS 首包）
3. 从首包解析 UUID、指令、目标地址/端口
4. 服务端连接到目标上游
5. 双向转发：WebSocket ↔ 上游

## 节点链接格式

```
vless://<UUID>@<域名>:443?encryption=none&flow=xtls-rprx-vision&security=tls&sni=<域名>&fp=chrome&type=ws&host=<域名>&path=%2F#<域名>
```

服务启动后自动打印完整节点链接。

## 自行编译

```bash
git clone https://github.com/qaz69s/vless-wss-rs.git
cd vless-wss-rs
cargo build --release
./target/release/vless-wss-rs --help
```

## 已知限制

- 仅支持 TCP（暂无 UDP/XUDP）
- TLS 内部传输为明文，VLESS 头未加密
- 无连接数限制 / 流量统计
