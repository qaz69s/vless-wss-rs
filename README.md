# vless-wss-rs

VLESS WSS Server — a minimal, pure Rust implementation for personal use.

## Features

- VLESS TCP over WebSocket + TLS
- Let's Encrypt certificate via acme.sh (DNS-01 challenge with Cloudflare)
- Zero runtime dependencies (static binary)
- Supports any CDN

## One-line Install

```bash
curl -sL https://raw.githubusercontent.com/qaz69s/vless-wss-rs/main/install.sh | bash
```

Or with parameters:

```bash
curl -sL https://raw.githubusercontent.com/qaz69s/vless-wss-rs/main/install.sh | bash -s -- \
  --get-cert example.com --email you@example.com --cf-token CF_TOKEN --uuid UUID
```

## Usage

### Issue a Let's Encrypt certificate (first time)

Requires Cloudflare DNS API token with permission to add TXT records.

```bash
vless-wss-rs \
  --get-cert example.com \
  --email you@example.com \
  --cf-token CF_TOKEN \
  --uuid YOUR_UUID \
  --listen 0.0.0.0:8443
```

Certificate is saved to `~/.acme.sh/{domain}/` and auto-renewed by acme.sh.

### Use existing certificate

```bash
vless-wss-rs \
  --cert fullchain.pem \
  --key privkey.pem \
  --uuid YOUR_UUID \
  --listen 0.0.0.0:8443
```

### All options

```
--cert <PATH>        TLS certificate (PEM)
--key <PATH>         TLS private key (PEM)
--get-cert <DOMAIN>  Issue a Let's Encrypt cert for this domain
--email <EMAIL>  Email for Let's Encrypt registration
--cf-token <TOKEN>   Cloudflare DNS API token (for DNS-01 challenge)
--uuid <UUID>        VLESS user UUID
--listen <ADDR>      Listen address [default: 0.0.0.0:8443]
```

## Build from source

```bash
git clone https://github.com/qaz69s/vless-wss-rs.git
cd vless-wss-rs
cargo build --release
./target/release/vless-wss-rs --help
```

## How it works

1. Client connects via TLS + WebSocket
2. Server reads the first WebSocket binary frame (VLESS first packet)
3. Server parses UUID, command, target address/port from the packet
4. Server connects to the target upstream
5. Bidirectional relay: WebSocket ↔ upstream

## Limitations

- TCP only (no UDP/XUDP)
- No encryption beyond TLS — the VLESS header is plaintext
- No connection limits or statistics
