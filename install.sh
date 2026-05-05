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

read -p "Cloudflare API Token: " CF_TOKEN

# Auto-detect domain from CF token
echo "[*] Fetching domains from Cloudflare..."
DOMAINS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" | \
    python3 -c "import sys,json; data=json.load(sys.stdin); [print(z['name']) for z in data.get('result',[])]" 2>/dev/null)

if [ -z "$DOMAINS" ]; then
    echo "[-] Failed to fetch domains. Check your CF Token permissions (needs Zone.Read)."
    exit 1
fi

DOMAIN_COUNT=$(echo "$DOMAINS" | wc -l)
if [ "$DOMAIN_COUNT" -eq 1 ]; then
    DOMAIN="$DOMAINS"
    echo "[*] Auto-detected domain: $DOMAIN"
else
    echo "[*] Available domains:"
    echo "$DOMAINS"
    echo ""
    read -p "Select domain: " DOMAIN
fi

# Auto-detect server public IP
echo "[*] Detecting server public IP..."
SERVER_IP=$(curl -s https://api.ipify.org 2>/dev/null || curl -s https://ifconfig.me 2>/dev/null)
if [ -z "$SERVER_IP" ]; then
    read -p "Could not detect IP, please enter manually: " SERVER_IP
else
    echo "[*] Server IP: $SERVER_IP"
fi

# Add/update DNS A record
read -p "Add DNS A record automatically? [Y/n]: " ADD_DNS
ADD_DNS=${ADD_DNS:-Y}

if [[ "$ADD_DNS" =~ ^[Yy]$ ]]; then
    echo "[*] Adding DNS A record $DOMAIN -> $SERVER_IP ..."

    # Get zone ID
    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" | \
        python3 -c "import sys,json; data=json.load(sys.stdin); print(data['result'][0]['id'] if data['result'] else '')" 2>/dev/null)

    if [ -z "$ZONE_ID" ]; then
        echo "[-] Could not find zone ID for $DOMAIN"
    else
        # Check if A record exists
        RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$DOMAIN" \
            -H "Authorization: Bearer $CF_TOKEN" \
            -H "Content-Type: application/json" | \
            python3 -c "import sys,json; data=json.load(sys.stdin); print(data['result'][0]['id'] if data['result'] else '')" 2>/dev/null)

        if [ -n "$RECORD_ID" ]; then
            # Update existing
            curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
                -H "Authorization: Bearer $CF_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$SERVER_IP\",\"proxied\":false}" > /dev/null
            echo "[*] Updated existing A record"
        else
            # Create new
            curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
                -H "Authorization: Bearer $CF_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$SERVER_IP\",\"proxied\":false}" > /dev/null
            echo "[*] Created A record"
        fi
    fi
fi

# Auto-generate random email
EMAIL="letsencrypt-$(uuidgen | cut -c1-8)@$DOMAIN"
echo "[*] Auto-generated email: $EMAIL"

# Generate UUID
UUID=$(cat /proc/sys/kernel/random/uuid)
echo "[*] Generated UUID: $UUID"

echo ""
echo "[*] Starting vless-wss-rs..."
exec vless-wss-rs \
    --get-cert "$DOMAIN" \
    --email "$EMAIL" \
    --cf-token "$CF_TOKEN" \
    --uuid "$UUID"
