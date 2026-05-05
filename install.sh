#!/bin/bash
set -e

REPO="qaz69s/vless-wss-rs"
TMPDIR=$(mktemp -d)
cd "$TMPDIR"

echo "[*] Downloading vless-wss-rs..."
curl -sL "https://github.com/$REPO/releases/download/v1.0.0/vless-wss-rs-x86_64-unknown-linux-musl.tar.gz" -o vless.tar.gz

if [ -f vless.tar.gz ] && [ -s vless.tar.gz ]; then
    tar xzf vless.tar.gz
    chmod +x vless-wss-rs
    mv vless-wss-rs /usr/local/bin/
    rm -rf "$TMPDIR"
    echo "[+] Installed to /usr/local/bin/vless-wss-rs"
else
    echo "[*] Building from source..."
    rm -rf "$TMPDIR"
    BUILD_DIR=$(mktemp -d)
    cd "$BUILD_DIR"
    git clone "https://github.com/$REPO.git" --depth=1
    cd vless-wss-rs
    cargo build --release 2>/dev/null
    mv target/release/vless-wss-rs /usr/local/bin/
    rm -rf "$BUILD_DIR"
    echo "[+] Built and installed to /usr/local/bin/vless-wss-rs"
fi

echo ""
echo "=== VLESS WSS Server Setup ==="
echo ""

read -p "Domain (e.g. vless.example.com): " DOMAIN
read -p "Email for Let's Encrypt: " EMAIL
read -p "Cloudflare API Token: " CF_TOKEN
read -p "VLESS UUID (press Enter to generate random): " UUID

if [ -z "$UUID" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "[*] Generated UUID: $UUID"
fi

echo ""
echo "[*] Issuing Let's Encrypt certificate for: $DOMAIN"
echo "[*] This will configure DNS via Cloudflare..."
echo ""

# Run vless-wss-rs with --get-cert — it will call acme.sh internally
exec vless-wss-rs \
    --get-cert "$DOMAIN" \
    --email "$EMAIL" \
    --cf-token "$CF_TOKEN" \
    --uuid "$UUID"
