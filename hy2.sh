#!/usr/bin/env bash

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_DIR="/root/hy2"
SERVICE_NAME="hy2"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}        Hysteria 2 Installer${NC}"
echo -e "${GREEN}========================================${NC}"
echo

# بررسی root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}این اسکریپت باید با root اجرا شود.${NC}"
    exit 1
fi

# دریافت پورت
while true; do
    read -rp "Port: " PORT

    if [[ "$PORT" =~ ^[0-9]+$ ]] && \
       [ "$PORT" -ge 1 ] && \
       [ "$PORT" -le 65535 ]; then
        break
    fi

    echo -e "${RED}پورت نامعتبره.${NC}"
done

# دریافت پسورد
while true; do
    read -rsp "Password: " PASSWORD
    echo

    if [[ -n "$PASSWORD" ]]; then
        break
    fi

    echo -e "${RED}پسورد نمی‌تواند خالی باشد.${NC}"
done

echo
echo -e "${YELLOW}در حال نصب پیش‌نیازها...${NC}"

apt-get update -y
apt-get install -y curl wget jq openssl ca-certificates

# دریافت IP عمومی
echo -e "${YELLOW}در حال دریافت IP سرور...${NC}"

SERVER_IP=$(curl -4 -s --max-time 10 https://api.ipify.org || true)

if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(curl -4 -s --max-time 10 https://ifconfig.me || true)
fi

if [[ -z "$SERVER_IP" ]]; then
    echo -e "${RED}نتوانستم IP عمومی سرور را پیدا کنم.${NC}"
    exit 1
fi

echo -e "${GREEN}Server IP: ${SERVER_IP}${NC}"

# تشخیص معماری
ARCH=$(uname -m)

case "$ARCH" in
    x86_64)
        HY_ARCH="amd64"
        ;;
    aarch64|arm64)
        HY_ARCH="arm64"
        ;;
    *)
        echo -e "${RED}معماری پشتیبانی نمی‌شود: $ARCH${NC}"
        exit 1
        ;;
esac

echo -e "${GREEN}Architecture: ${HY_ARCH}${NC}"

# ایجاد پوشه
mkdir -p "$INSTALL_DIR"

# دریافت آخرین Release
echo -e "${YELLOW}در حال پیدا کردن آخرین نسخه Hysteria...${NC}"

RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/apernet/hysteria/releases/latest)

TAG=$(echo "$RELEASE_JSON" | jq -r '.tag_name')

if [[ -z "$TAG" ]] || [[ "$TAG" == "null" ]]; then
    echo -e "${RED}نتوانستم آخرین نسخه Hysteria را پیدا کنم.${NC}"
    exit 1
fi

echo -e "${GREEN}Latest version: ${TAG}${NC}"

# پیدا کردن فایل مناسب
ASSET_URL=$(echo "$RELEASE_JSON" | jq -r \
    --arg ARCH "$HY_ARCH" \
    '.assets[] |
    select(.name == ("hysteria-linux-" + $ARCH)) |
    .browser_download_url' | head -n 1)

if [[ -z "$ASSET_URL" ]] || [[ "$ASSET_URL" == "null" ]]; then
    echo -e "${RED}فایل مناسب برای معماری ${HY_ARCH} پیدا نشد.${NC}"
    echo -e "${YELLOW}Assets موجود:${NC}"

    echo "$RELEASE_JSON" | jq -r '.assets[].name'

    exit 1
fi

echo -e "${YELLOW}در حال دانلود Hysteria...${NC}"

rm -f "$INSTALL_DIR/hysteria"

curl -L --fail --retry 3 \
    -o "$INSTALL_DIR/hysteria" \
    "$ASSET_URL"

chmod +x "$INSTALL_DIR/hysteria"

# تست فایل
if ! "$INSTALL_DIR/hysteria" version; then
    echo -e "${RED}فایل Hysteria اجرا نشد.${NC}"
    exit 1
fi

echo -e "${GREEN}Hysteria با موفقیت دانلود شد.${NC}"

# ساخت Certificate
echo -e "${YELLOW}در حال ساخت TLS Certificate...${NC}"

openssl req -x509 \
    -newkey rsa:2048 \
    -nodes \
    -keyout "$INSTALL_DIR/server.key" \
    -out "$INSTALL_DIR/server.crt" \
    -days 3650 \
    -subj "/CN=$SERVER_IP"

chmod 600 "$INSTALL_DIR/server.key"

# ساخت کانفیگ Hysteria
echo -e "${YELLOW}در حال ساخت config...${NC}"

cat > "$INSTALL_DIR/config.yaml" <<EOF
listen: :$PORT

tls:
  cert: $INSTALL_DIR/server.crt
  key: $INSTALL_DIR/server.key

auth:
  type: password
  password: $PASSWORD

obfs:
  type: salamander
  salamander:
    password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://www.cloudflare.com
    rewriteHost: true
EOF

# ساخت سرویس systemd
echo -e "${YELLOW}در حال ساخت systemd service...${NC}"

cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/hysteria server -c $INSTALL_DIR/config.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME.service"
systemctl restart "$SERVICE_NAME.service"

sleep 2

if ! systemctl is-active --quiet "$SERVICE_NAME.service"; then
    echo -e "${RED}سرویس اجرا نشد.${NC}"
    echo
    journalctl -u "$SERVICE_NAME.service" -n 30 --no-pager
    exit 1
fi

# تنظیم UFW در صورت فعال بودن
if command -v ufw &> /dev/null; then
    if ufw status | grep -q "Status: active"; then
        echo -e "${YELLOW}باز کردن پورت UDP...${NC}"
        ufw allow "$PORT/udp"
    fi
fi

# ساخت کانفیگ کلاینت
HY2_CONFIG="hysteria2://${PASSWORD}@${SERVER_IP}:${PORT}/?insecure=1&obfs=salamander&obfs-password=${PASSWORD}&sni=google.com#Hy2"

echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}       نصب با موفقیت انجام شد 🎉${NC}"
echo -e "${GREEN}========================================${NC}"
echo

echo -e "${YELLOW}HY2 CONFIG:${NC}"
echo
echo "$HY2_CONFIG"
echo

echo -e "${GREEN}Service Status:${NC}"
systemctl status "$SERVICE_NAME.service" --no-pager