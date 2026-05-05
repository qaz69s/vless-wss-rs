#!/bin/bash
# one-line install for vless-wss-rs
# Usage:
#   With existing cert:
#     curl -sL https://raw.githubusercontent.com/qaz69s/vless-wss-rs/main/install.sh | bash -s -- --cert fullchain.pem --key privkey.pem --uuid UUID
#   Issue LE cert first:
#     curl -sL https://raw.githubusercontent.com/qaz69s/vless-wss-rs/main/install.sh | bash -s -- --get-cert example.com --email you@example.com --cf-token TOKEN --uuid UUID

set -e

REPO="qaz69s/vless-wss-rs"
TMPDIR=$(mktemp -d)
cd "$TMPDIR"

echo "[*] Downloading vless-wss-rs..."
curl -sL "https://github.com/$REPO/releases/download/v1.0.0/vless-wss-rs-x86_64-unknown-linux-musl.tar.gz" -o vless.tar.gz

if [ -f vless.tar.gz ]; then
    tar xzf vless.tar.gz
    chmod +x vless-wss-rs
    mv vless-wss-rs /usr/local/bin/
    rm -rf "$TMPDIR"
    echo "[+] Installed to /usr/local/bin/vless-wss-rs"
else
    echo "[*] No release found, building from source..."
    rm -rf "$TMPDIR"
    BUILD_DIR=$(mktemp -d)
    cd "$BUILD_DIR"
    git clone "https://github.com/$REPO.git" --depth=1
    cd vless-wss-rs
    cargo build --release
    mv target/release/vless-wss-rs /usr/local/bin/
    rm -rf "$BUILD_DIR"
    echo "[+] Built and installed to /usr/local/bin/vless-wss-rs"
fi

echo ""
echo "[*] Usage:"
echo "  # Issue Let's Encrypt cert (first time):"
echo "  vless-wss-rs --get-cert example.com --email you@example.com --cf-token TOKEN --uuid UUID"
echo ""
echo "  # Use existing cert:"
echo "  vless-wss-rs --cert fullchain.pem --key privkey.pem --uuid UUID"
