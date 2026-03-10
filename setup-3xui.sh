#!/bin/bash
set -euo pipefail

# ============================================================
#  3x-ui installer with auto-renewing self-signed certificates
#  Cert lifetime: 6 days, auto-renewal via cron every 5 days
#  Tested on: Ubuntu 20.04 / 22.04 / 24.04
# ============================================================

# ====================== YOUR LINKS ==========================
# Change these to your own URLs:
CHANNEL_URL="https://t.me/YOUR_CHANNEL"        # Telegram / YouTube / etc.
DONATE_URL="https://boosty.to/YOUR_PAGE"        # Boosty / DonationAlerts / etc.
CHANNEL_NAME="My Channel"
DONATE_NAME="Support on Boosty"
# =============================================================

CERT_DIR="/root/cert"
CERT_DAYS=6             # 6 days
CERT_KEY="$CERT_DIR/private.key"
CERT_CRT="$CERT_DIR/cert.crt"
RENEW_SCRIPT="$CERT_DIR/renew-cert.sh"
CRON_INTERVAL=5         # renew every 5 days (before 6-day expiry)

# -------------------- helpers --------------------
info()  { printf '\n\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*"; }
error() { printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*"; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || error "Run this script as root: sudo bash $0"
}

# -------------------- system update --------------------
install_deps() {
    info "Обновление системы и установка зависимостей..."
    apt-get update -y
    apt-get install -y curl openssl qrencode
}

# -------------------- certificate generation --------------------
generate_cert() {
    info "Генерация самоподписного SSL-сертификата (срок: $CERT_DAYS дней)..."

    mkdir -p "$CERT_DIR"

    read -rp "Введите IP-адрес или домен сервера (например 123.45.67.89 или panel.example.com): " SERVER_ADDR
    [[ -z "$SERVER_ADDR" ]] && error "Адрес сервера не может быть пустым."

    # Save address for renewal script
    echo "$SERVER_ADDR" > "$CERT_DIR/.server_addr"

    _issue_cert

    info "Сертификат создан:"
    echo "  🔐 Ключ:      $CERT_KEY"
    echo "  📜 Сертификат: $CERT_CRT"
    echo ""
    openssl x509 -in "$CERT_CRT" -noout -subject -dates
}

_issue_cert() {
    local addr="$SERVER_ADDR"
    local san

    if [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        san="IP:$addr"
    else
        san="DNS:$addr"
    fi

    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$CERT_KEY" \
        -out "$CERT_CRT" \
        -days "$CERT_DAYS" \
        -subj "/CN=$addr" \
        -addext "subjectAltName=$san" 2>/dev/null

    chmod 600 "$CERT_KEY"
    chmod 644 "$CERT_CRT"
}

# -------------------- auto-renewal setup --------------------
setup_auto_renewal() {
    info "Настройка автопродления сертификата (каждые $CRON_INTERVAL дней)..."

    # Create renewal script
    cat > "$RENEW_SCRIPT" << 'RENEW_EOF'
#!/bin/bash
CERT_DIR="/root/cert"
CERT_KEY="$CERT_DIR/private.key"
CERT_CRT="$CERT_DIR/cert.crt"
CERT_DAYS=6
SERVER_ADDR=$(cat "$CERT_DIR/.server_addr" 2>/dev/null)

[[ -z "$SERVER_ADDR" ]] && exit 1

if [[ "$SERVER_ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SAN="IP:$SERVER_ADDR"
else
    SAN="DNS:$SERVER_ADDR"
fi

openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$CERT_KEY" \
    -out "$CERT_CRT" \
    -days "$CERT_DAYS" \
    -subj "/CN=$SERVER_ADDR" \
    -addext "subjectAltName=$SAN" 2>/dev/null

chmod 600 "$CERT_KEY"
chmod 644 "$CERT_CRT"

# Restart x-ui to pick up the new certificate
systemctl restart x-ui 2>/dev/null || true

logger "x-ui cert renewed for $SERVER_ADDR (valid $CERT_DAYS days)"
RENEW_EOF

    chmod 700 "$RENEW_SCRIPT"

    # Add cron job (runs at 3:00 AM every N days)
    local CRON_LINE="0 3 */$CRON_INTERVAL * * $RENEW_SCRIPT"
    ( crontab -l 2>/dev/null | grep -v "$RENEW_SCRIPT"; echo "$CRON_LINE" ) | crontab -

    info "Cron-задача установлена:"
    echo "  ⏰ Каждые $CRON_INTERVAL дней в 03:00 — автоматическая перегенерация сертификата"
    echo "  📄 Скрипт продления: $RENEW_SCRIPT"
}

# -------------------- 3x-ui installation --------------------
install_3xui() {
    info "Установка панели 3x-ui..."
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)
}

# -------------------- read panel settings --------------------
read_panel_settings() {
    local XUI_BIN="/usr/local/x-ui/x-ui"
    PANEL_USER=""; PANEL_PASS=""; PANEL_PORT=""; PANEL_PATH=""

    if [[ -x "$XUI_BIN" ]]; then
        local settings
        settings=$($XUI_BIN setting -show 2>/dev/null || true)

        PANEL_USER=$(echo "$settings" | grep -i 'username' | head -1 | awk -F': ' '{print $2}' | xargs)
        PANEL_PASS=$(echo "$settings" | grep -i 'password' | head -1 | awk -F': ' '{print $2}' | xargs)
        PANEL_PORT=$(echo "$settings" | grep -i 'port'     | head -1 | awk -F': ' '{print $2}' | xargs)
        PANEL_PATH=$(echo "$settings" | grep -i 'webBasePath\|base.*path' | head -1 | awk -F': ' '{print $2}' | xargs)
    fi

    [[ -z "$PANEL_USER" ]] && PANEL_USER="(см. вывод установщика выше)"
    [[ -z "$PANEL_PASS" ]] && PANEL_PASS="(см. вывод установщика выше)"
    [[ -z "$PANEL_PORT" ]] && PANEL_PORT="2053"
    [[ -z "$PANEL_PATH" ]] && PANEL_PATH="/"
}

# -------------------- QR codes --------------------
show_qr_codes() {
    echo ""
    echo -e "\033[1;36m══════════════════════════════════════════════════\033[0m"
    echo -e "\033[1;36m       Спасибо, что используете установщик!       \033[0m"
    echo -e "\033[1;36m══════════════════════════════════════════════════\033[0m"
    echo ""

    if command -v qrencode &>/dev/null; then
        echo -e "\033[1;33m  📢 $CHANNEL_NAME:\033[0m"
        echo "  $CHANNEL_URL"
        qrencode -t ANSIUTF8 "$CHANNEL_URL"
        echo ""

        echo -e "\033[1;33m  💰 $DONATE_NAME:\033[0m"
        echo "  $DONATE_URL"
        qrencode -t ANSIUTF8 "$DONATE_URL"
        echo ""
    else
        echo "  📢 $CHANNEL_NAME: $CHANNEL_URL"
        echo "  💰 $DONATE_NAME:  $DONATE_URL"
    fi
}

# -------------------- summary --------------------
print_summary() {
    read_panel_settings

    local PANEL_LINK="https://${SERVER_ADDR}:${PANEL_PORT}${PANEL_PATH}"

    echo ""
    echo -e "\033[1;32m╔══════════════════════════════════════════════════\033[0m"
    echo -e "\033[1;32m║    ✅ УСТАНОВКА ЗАВЕРШЕНА! ДАННЫЕ ДЛЯ ВХОДА:\033[0m"
    echo -e "\033[1;32m╚══════════════════════════════════════════════════\033[0m"
    echo ""
    echo -e "\033[1;31m  ⚠️  ВНИМАНИЕ! ЭТИ ДАННЫЕ ВАЖНО СОХРАНИТЬ!\033[0m"
    echo ""
    echo -e "\033[1;36m┌──────────────────────────────────────────────────\033[0m"
    echo -e "\033[1;36m│         🖥  Данные панели 3X-UI\033[0m"
    echo -e "\033[1;36m├──────────────────────────────────────────────────\033[0m"
    echo -e "\033[1;37m│  👤 Имя пользователя: \033[1;33m$PANEL_USER\033[0m"
    echo -e "\033[1;37m│  🔑 Пароль:           \033[1;33m$PANEL_PASS\033[0m"
    echo -e "\033[1;37m│  🔌 Порт:             \033[1;33m$PANEL_PORT\033[0m"
    echo -e "\033[1;37m│  📁 Путь панели:      \033[1;33m$PANEL_PATH\033[0m"
    echo -e "\033[1;37m│  🌐 Ссылка для входа: \033[1;33m$PANEL_LINK\033[0m"
    echo -e "\033[1;36m└──────────────────────────────────────────────────\033[0m"
    echo ""
    echo -e "\033[1;36m┌──────────────────────────────────────────────────\033[0m"
    echo -e "\033[1;36m│         🔒 SSL-сертификат (автопродление)\033[0m"
    echo -e "\033[1;36m├──────────────────────────────────────────────────\033[0m"
    echo -e "\033[1;37m│  📜 Сертификат:    \033[1;33m$CERT_CRT\033[0m"
    echo -e "\033[1;37m│  🔐 Приватный ключ: \033[1;33m$CERT_KEY\033[0m"
    echo -e "\033[1;37m│  ⏳ Срок действия:  \033[1;33m${CERT_DAYS} дней\033[0m"
    echo -e "\033[1;37m│  🔄 Автопродление:  \033[1;33mкаждые ${CRON_INTERVAL} дней (cron)\033[0m"
    echo -e "\033[1;37m│  📄 Скрипт продления: \033[1;33m$RENEW_SCRIPT\033[0m"
    echo -e "\033[1;36m└──────────────────────────────────────────────────\033[0m"
    echo ""
    echo -e "\033[1;32m   ✅ Теперь можно пользоваться панелью!\033[0m"
    echo ""

    show_qr_codes

    echo -e "\033[1;36m══════════════════════════════════════════════════\033[0m"
    echo ""
}

# -------------------- main --------------------
main() {
    check_root
    install_deps
    generate_cert
    setup_auto_renewal
    install_3xui
    print_summary
}

main
