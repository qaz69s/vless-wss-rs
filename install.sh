#!/bin/bash

REPO="qaz69s/vless-wss-rs"
TMPDIR=$(mktemp -d)
cd "$TMPDIR"

echo "[*] Downloading vless-wss-rs..."
curl -sL --max-time 30 "https://github.com/$REPO/releases/download/v1.0.0/vless-wss-rs-x86_64-unknown-linux-musl.tar.gz" -o vless.tar.gz 2>&1

if [ ! -f vless.tar.gz ] || [ ! -s vless.tar.gz ]; then
    echo "[-] Download failed."
    exit 1
fi

tar xzf vless.tar.gz
chmod +x vless-wss-rs
mv vless-wss-rs /usr/local/bin/
rm -rf "$TMPDIR"
echo "[+] Installed to /usr/local/bin/vless-wss-rs"

echo ""
echo "=== VLESS WSS Server Setup ==="
echo ""

read -p "Cloudflare API Token: " CF_TOKEN

# Step 1: Fetch domains from CF
echo "[*] Fetching domains from Cloudflare..."
RESP=$(curl -s --max-time 15 -X GET "https://api.cloudflare.com/client/v4/zones" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" 2>&1)

if echo "$RESP" | grep -q '"success":false'; then
    echo "[-] Cloudflare API error:"
    echo "$RESP" | grep -o '"message":"[^"]*"' | head -1
    exit 1
fi

if ! echo "$RESP" | grep -q '"name":"'; then
    echo "[-] No domains found or unexpected response."
    exit 1
fi

# Extract domains line by line
DOMAINS=$(echo "$RESP" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"$//')
DOMAIN_COUNT=$(echo "$DOMAINS" | wc -l)

if [ "$DOMAIN_COUNT" -eq 0 ]; then
    echo "[-] No domains in CF account."
    exit 1
fi

if [ "$DOMAIN_COUNT" -eq 1 ]; then
    DOMAIN=$(echo "$DOMAINS")
    echo "[+] Auto-detected domain: $DOMAIN"
else
    echo "[*] Available domains:"
    n=0
    for d in $DOMAINS; do
        echo "  [$n] $d"
        n=$((n+1))
    done
    echo ""
    read -p "Select domain index [0]: " IDX
    IDX=${IDX:-0}
    DOMAIN=$(echo "$DOMAINS" | sed -n "$((IDX+1))p")
fi

# Step 2: Get zone ID from the zone we selected
ZONE_ID=$(echo "$RESP" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"$//')

# Step 3: Detect public IP
echo "[*] Detecting server public IP..."
SERVER_IP=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -s --max-time 10 https://ifconfig.me 2>/dev/null)
fi
if [ -z "$SERVER_IP" ]; then
    read -p "Could not detect IP, enter manually: " SERVER_IP
else
    echo "[+] Server IP: $SERVER_IP"
fi

# Step 4: Auto-add DNS A record
echo "[*] Adding DNS A record $DOMAIN -> $SERVER_IP ..."

RECORD_RESP=$(curl -s --max-time 15 -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$DOMAIN" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" 2>&1)

RECORD_ID=$(echo "$RECORD_RESP" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"$//')

if [ -n "$RECORD_ID" ]; then
    curl -s --max-time 15 -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$SERVER_IP\",\"proxied\":false}" > /dev/null 2>&1
    echo "[+] Updated existing A record"
else
    curl -s --max-time 15 -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$SERVER_IP\",\"proxied\":false}" > /dev/null 2>&1
    echo "[+] Created new A record"
fi

# Step 5: Wait for DNS
echo "[*] Waiting for DNS propagation (15s)..."
sleep 15

# Step 6: Issue certificate via HTTP-01
echo "[*] Installing acme.sh..."
if [ ! -f ~/.acme.sh/acme.sh ]; then
    curl https://get.acme.sh | sh -s email=letsencrypt@"$DOMAIN" 2>&1 | tail -5
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt 2>&1 | tail -3

echo "[*] Issuing certificate (HTTP-01 port 80)..."
~/.acme.sh/acme.sh --issue --standalone --httpport 80 -d "$DOMAIN" --keylength 2048 --server letsencrypt 2>&1

CERT_DIR="/root/.acme.sh/$DOMAIN"
KEY_FILE=$(ls "$CERT_DIR"/*.key 2>/dev/null | head -1)
FULLCHAIN="$CERT_DIR/fullchain.cer"

if [ ! -f "$FULLCHAIN" ] || [ ! -f "$KEY_FILE" ]; then
    echo "[-] Certificate issue failed."
    echo "    Check: port 80 is free, DNS has propagated."
    exit 1
fi
echo "[+] Certificate: $FULLCHAIN"

# Step 7: UUID + start
UUID=$(cat /proc/sys/kernel/random/uuid)
echo "[+] UUID: $UUID"

mkdir -p /etc/vless-wss-rs
cat > /etc/vless-wss-rs/config.json << EOF
{
  "uuid": "$UUID",
  "domain": "$DOMAIN"
}
EOF

echo ""
echo "[*] Starting vless-wss-rs..."
exec vless-wss-rs \
    --cert "$FULLCHAIN" \
    --key "$KEY_FILE" \
    --domain "$DOMAIN" \
    --uuid "$UUID"
