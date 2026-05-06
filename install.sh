#!/bin/bash
# vless-wss-rs — 一键安装 + 自动配置
#
# 自动模式（随机二级域名 + CF DNS A记录 + Let's Encrypt 证书）:
#   bash install.sh \
#     --cf-token  CF_API_TOKEN \
#     --base-domain example.com \
#     --email     you@example.com \
#     [--uuid     YOUR_UUID]       # 不填则随机生成
#     [--listen   0.0.0.0:443]
#
# 手动证书模式:
#   bash install.sh \
#     --cert /path/fullchain.pem \
#     --key  /path/privkey.pem \
#     --uuid YOUR_UUID

set -euo pipefail

# ────────────────────────────────────────────────────────────
# 0. 解析参数
# ────────────────────────────────────────────────────────────
CF_TOKEN="" BASE_DOMAIN="" EMAIL=""
UUID="" CERT="" KEY=""
LISTEN="0.0.0.0:443"

while [[ $# -gt 0 ]]; do
    case $1 in
        --cf-token)    CF_TOKEN="$2";    shift 2 ;;
        --base-domain) BASE_DOMAIN="$2"; shift 2 ;;
        --email)       EMAIL="$2";       shift 2 ;;
        --uuid)        UUID="$2";        shift 2 ;;
        --cert)        CERT="$2";        shift 2 ;;
        --key)         KEY="$2";         shift 2 ;;
        --listen)      LISTEN="$2";      shift 2 ;;
        *) echo "[-] 未知参数: $1"; exit 1 ;;
    esac
done

# ────────────────────────────────────────────────────────────
# 1. 安装二进制
# ────────────────────────────────────────────────────────────
install_binary() {
    if command -v vless-wss-rs &>/dev/null; then
        echo "[+] vless-wss-rs 已安装，跳过下载"
        return
    fi

    echo "[*] 正在下载 vless-wss-rs..."
    local REPO="qaz69s/vless-wss-rs"
    local TMP
    TMP=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf $TMP" RETURN

    if curl -sLf \
        "https://github.com/$REPO/releases/latest/download/vless-wss-rs-x86_64-unknown-linux-musl.tar.gz" \
        -o "$TMP/vless.tar.gz" 2>/dev/null; then

        tar xzf "$TMP/vless.tar.gz" -C "$TMP"
        chmod +x "$TMP/vless-wss-rs"
        mv "$TMP/vless-wss-rs" /usr/local/bin/
        echo "[+] 已从 Release 安装"
    else
        echo "[*] 未找到 Release，从源码编译..."
        if ! command -v cargo &>/dev/null; then
            echo "[-] 未安装 Rust/cargo，请先运行："
            echo "    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
            exit 1
        fi
        local BUILD
        BUILD=$(mktemp -d)
        git clone "https://github.com/$REPO.git" --depth=1 "$BUILD/repo"
        cargo build --release --manifest-path "$BUILD/repo/Cargo.toml"
        mv "$BUILD/repo/target/release/vless-wss-rs" /usr/local/bin/
        rm -rf "$BUILD"
        echo "[+] 编译完成，已安装到 /usr/local/bin/"
    fi
}

# ────────────────────────────────────────────────────────────
# 2. CF 工具函数
# ────────────────────────────────────────────────────────────

# 用 CF API 查询 Zone ID（自动从 base-domain 逐级匹配）
cf_zone_id() {
    local domain="$1"
    # 逐级缩短域名，找到第一个在 CF 中存在的 zone
    # 例如 sub.foo.example.com → foo.example.com → example.com
    local IFS='.'
    read -ra parts <<< "$domain"
    local n=${#parts[@]}
    for ((i=0; i<n-1; i++)); do
        local candidate="${parts[*]:$i}"   # bash 数组切片，IFS='.' 拼成域名
        local zone_id
        zone_id=$(curl -sf \
            "https://api.cloudflare.com/client/v4/zones?name=${candidate}&status=active" \
            -H "Authorization: Bearer ${CF_TOKEN}" \
            -H "Content-Type: application/json" \
            | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        if [[ -n "$zone_id" ]]; then
            echo "$zone_id"
            return 0
        fi
    done
    return 1
}

# 创建 CF DNS A 记录，返回记录 ID（供后续删除/更新）
cf_create_a_record() {
    local zone_id="$1" fqdn="$2" ip="$3"
    local resp
    resp=$(curl -sf -X POST \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"A\",\"name\":\"${fqdn}\",\"content\":\"${ip}\",\"ttl\":60,\"proxied\":false}")

    if ! echo "$resp" | grep -q '"success":true'; then
        echo "[-] CF 建 DNS 记录失败: $resp" >&2
        exit 1
    fi

    # 提取并返回记录 ID
    echo "$resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4
}

# ────────────────────────────────────────────────────────────
# 3. 获取本机公网 IP
# ────────────────────────────────────────────────────────────
get_public_ip() {
    local ip
    ip=$(curl -sf --max-time 5 https://api.ipify.org \
      || curl -sf --max-time 5 https://ifconfig.me \
      || curl -sf --max-time 5 https://icanhazip.com) || true
    if [[ -z "$ip" ]]; then
        echo "[-] 无法获取公网 IP" >&2
        exit 1
    fi
    echo "$ip"
}

# ────────────────────────────────────────────────────────────
# 4. acme.sh 安装 + 申请证书
# ────────────────────────────────────────────────────────────
install_acme() {
    if [[ -f ~/.acme.sh/acme.sh ]]; then
        echo "[+] acme.sh 已安装"
        return
    fi
    echo "[*] 安装 acme.sh..."
    if [[ -z "$EMAIL" ]]; then
        echo "[-] 需要 --email 来注册 Let's Encrypt 账号" >&2; exit 1
    fi
    curl -sf https://get.acme.sh | sh -s "email=${EMAIL}"
    # 加载环境（acme.sh 安装后会修改 ~/.bashrc，这里直接 source env 文件）
    # shellcheck source=/dev/null
    [[ -f ~/.acme.sh/acme.sh.env ]] && source ~/.acme.sh/acme.sh.env || true
}

issue_cert_dns01() {
    local fqdn="$1"
    local ACME=~/.acme.sh/acme.sh

    # 设置默认 CA 为 Let's Encrypt（幂等，失败无害）
    "$ACME" --set-default-ca --server letsencrypt 2>/dev/null || true

    echo "[*] 申请证书: ${fqdn}（DNS-01，使用 Cloudflare）"
    # CF_Token 通过环境变量传给 acme.sh，而不是嵌在 shell 命令串里
    CF_Token="$CF_TOKEN" \
        "$ACME" --issue --dns dns_cf -d "${fqdn}" --keylength ec-256 --server letsencrypt

    # acme.sh 输出路径规范：
    #   fullchain: ~/.acme.sh/<domain>_ecc/fullchain.cer   (ec-256)
    #   key:       ~/.acme.sh/<domain>_ecc/<domain>.key
    local cert_dir=~/.acme.sh/${fqdn}_ecc
    if [[ ! -f "${cert_dir}/fullchain.cer" ]]; then
        echo "[-] 证书文件不存在，acme.sh 申请失败" >&2; exit 1
    fi

    CERT="${cert_dir}/fullchain.cer"
    KEY="${cert_dir}/${fqdn}.key"
}

# ────────────────────────────────────────────────────────────
# 5. 生成 UUID
# ────────────────────────────────────────────────────────────
gen_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        # 用 openssl 拼一个标准格式 UUID
        local h
        h=$(openssl rand -hex 16)
        printf '%s-%s-%s-%s-%s\n' \
            "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
    fi
}

# ────────────────────────────────────────────────────────────
# 主流程
# ────────────────────────────────────────────────────────────
install_binary

if [[ -n "$CERT" && -n "$KEY" ]]; then
    # ── 手动证书模式 ──────────────────────────────────────────
    echo "[*] 使用手动证书模式"
    [[ -f "$CERT" ]] || { echo "[-] 证书文件不存在: $CERT"; exit 1; }
    [[ -f "$KEY"  ]] || { echo "[-] 私钥文件不存在: $KEY";  exit 1; }

elif [[ -n "$CF_TOKEN" && -n "$BASE_DOMAIN" ]]; then
    # ── 自动模式：随机子域名 + CF DNS + acme.sh ───────────────
    [[ -n "$EMAIL" ]] || { echo "[-] 自动模式需要 --email"; exit 1; }

    # 1) 随机生成 6 位 hex 二级域名前缀，例如 a3f9c1.example.com
    SUB=$(openssl rand -hex 3)
    FQDN="${SUB}.${BASE_DOMAIN}"
    echo "[*] 随机子域名: ${FQDN}"

    # 2) 获取公网 IP
    SERVER_IP=$(get_public_ip)
    echo "[*] 本机公网 IP: ${SERVER_IP}"

    # 3) 查询 CF Zone ID
    echo "[*] 查询 Cloudflare Zone ID..."
    ZONE_ID=$(cf_zone_id "$BASE_DOMAIN") || {
        echo "[-] 未找到域名 ${BASE_DOMAIN} 对应的 Cloudflare Zone，请检查 --cf-token 和 --base-domain"
        exit 1
    }
    echo "[+] Zone ID: ${ZONE_ID}"

    # 4) 创建 DNS A 记录（关闭 CF 代理，acme.sh DNS-01 不需要 HTTP 可达）
    RECORD_ID=$(cf_create_a_record "$ZONE_ID" "$FQDN" "$SERVER_IP")
    echo "[+] DNS A 记录已创建 (record_id=${RECORD_ID})"

    # 5) 安装 acme.sh（如未安装）
    install_acme

    # 6) 申请 TLS 证书（DNS-01，不需要 80/443 对外开放）
    issue_cert_dns01 "$FQDN"

    echo ""
    echo "┌─────────────────────────────────────────────────────┐"
    echo "│  域名:      ${FQDN}"
    echo "│  证书:      ${CERT}"
    echo "│  私钥:      ${KEY}"
    echo "└─────────────────────────────────────────────────────┘"
    echo ""
else
    cat <<'EOF'
用法:

  自动模式（推荐）—— 随机子域名 + CF DNS 建记录 + 自动申请证书:
    bash install.sh \
      --cf-token  <Cloudflare API Token> \
      --base-domain example.com \
      --email     you@example.com \
      [--uuid     <UUID>]          \  # 不填则随机生成
      [--listen   0.0.0.0:443]

  手动证书模式:
    bash install.sh \
      --cert /path/to/fullchain.pem \
      --key  /path/to/privkey.pem   \
      --uuid <UUID>

CF API Token 需要的权限: Zone:Read + DNS:Edit
EOF
    exit 1
fi

# UUID（不传则自动生成）
if [[ -z "$UUID" ]]; then
    UUID=$(gen_uuid)
    echo "[*] 随机生成 UUID: ${UUID}"
fi

echo "[*] 启动 vless-wss-rs..."
echo "    监听:  ${LISTEN}"
echo "    UUID:  ${UUID}"
echo "    证书:  ${CERT}"
echo ""

exec /usr/local/bin/vless-wss-rs \
    --cert   "$CERT"   \
    --key    "$KEY"    \
    --uuid   "$UUID"   \
    --listen "$LISTEN"
