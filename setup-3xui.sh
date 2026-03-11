#!/bin/bash
set -eu

# ============================================================
#  3x-ui installer — fully automatic, no user input needed
#  Cert: 6 days, auto-renewal every 5 days via cron
#  Tested on: Ubuntu 20.04 / 22.04 / 24.04
# ============================================================

# ====================== YOUR LINKS ==========================
CHANNEL_URL="https://t.me/Anton_Pro_IT"
DONATE_URL="https://pay.cloudtips.ru/p/0e541e9b"
CHANNEL_NAME="Подписывайся на канал — Антон PRO IT"
DONATE_NAME="Поддержать автора"
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

# -------------------- detect server IP --------------------
detect_ip() {
    info "Определение IP-адреса сервера..."
    SERVER_ADDR=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
    [[ -z "$SERVER_ADDR" ]] && error "Не удалось определить IP-адрес сервера."
    info "IP сервера: $SERVER_ADDR"
}

# -------------------- certificate generation --------------------
generate_cert() {
    info "Генерация SSL-сертификата (срок: $CERT_DAYS дней)..."

    mkdir -p "$CERT_DIR"
    echo "$SERVER_ADDR" > "$CERT_DIR/.server_addr"

    _issue_cert
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
    set +e
    yes "" | bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) 2>&1
    set -e
}

# -------------------- generate random credentials --------------------
gen_random() {
    local len=$1
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
}

gen_random_port() {
    shuf -i 10000-59999 -n 1
}

gen_random_path() {
    local path
    path=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
    echo "/$path/"
}

# -------------------- configure panel --------------------
configure_panel() {
    local XUI_BIN="/usr/local/x-ui/x-ui"

    if [[ ! -x "$XUI_BIN" ]]; then
        warn "x-ui не найден, пропускаю настройку."
        return 0
    fi

    info "Генерация уникальных данных для входа..."

    GEN_USER=$(gen_random 10)
    GEN_PASS=$(gen_random 10)
    GEN_PORT=$(gen_random_port)
    GEN_PATH=$(gen_random_path)

    $XUI_BIN setting -username "$GEN_USER" -password "$GEN_PASS" 2>/dev/null || true
    $XUI_BIN setting -port "$GEN_PORT" 2>/dev/null || true
    $XUI_BIN setting -webBasePath "$GEN_PATH" 2>/dev/null || true
    $XUI_BIN setting -certFile "$CERT_CRT" -keyFile "$CERT_KEY" 2>/dev/null || true

    # Save credentials for panel-info.sh
    cat > "$CERT_DIR/.panel_creds" << CREDEOF
PANEL_USER=$GEN_USER
PANEL_PASS=$GEN_PASS
PANEL_PORT=$GEN_PORT
PANEL_PATH=$GEN_PATH
CREDEOF
    chmod 600 "$CERT_DIR/.panel_creds"

    systemctl restart x-ui 2>/dev/null || true
    info "Панель настроена с уникальными данными."
}

# -------------------- create info script --------------------
create_info_script() {
    info "Сохранение скрипта с данными панели..."

    cat > /root/panel-info.sh << 'INFOEOF'
#!/bin/bash
CERT_DIR="/root/cert"
CERT_KEY="$CERT_DIR/private.key"
CERT_CRT="$CERT_DIR/cert.crt"
RENEW_SCRIPT="$CERT_DIR/renew-cert.sh"
CERT_DAYS=6
CRON_INTERVAL=5

CHANNEL_URL="https://t.me/Anton_Pro_IT"
DONATE_URL="https://pay.cloudtips.ru/p/0e541e9b"
CHANNEL_NAME="Подписывайся на канал — Антон PRO IT"
DONATE_NAME="Поддержать автора"

SERVER_ADDR=$(cat "$CERT_DIR/.server_addr" 2>/dev/null)

# Read saved credentials
if [[ -f "$CERT_DIR/.panel_creds" ]]; then
    source "$CERT_DIR/.panel_creds"
else
    XUI_BIN="/usr/local/x-ui/x-ui"
    PANEL_USER=""; PANEL_PASS=""; PANEL_PORT=""; PANEL_PATH=""
    if [[ -x "$XUI_BIN" ]]; then
        settings=$($XUI_BIN setting -show 2>/dev/null || true)
        PANEL_USER=$(echo "$settings" | grep -i 'username' | head -1 | awk -F': ' '{print $2}' | xargs)
        PANEL_PASS=$(echo "$settings" | grep -i 'password' | head -1 | awk -F': ' '{print $2}' | xargs)
        PANEL_PORT=$(echo "$settings" | grep -i 'port'     | head -1 | awk -F': ' '{print $2}' | xargs)
        PANEL_PATH=$(echo "$settings" | grep -i 'webBasePath\|base.*path' | head -1 | awk -F': ' '{print $2}' | xargs)
    fi
    [[ -z "$PANEL_USER" ]] && PANEL_USER="admin"
    [[ -z "$PANEL_PASS" ]] && PANEL_PASS="admin"
    [[ -z "$PANEL_PORT" ]] && PANEL_PORT="2053"
    [[ -z "$PANEL_PATH" ]] && PANEL_PATH="/"
fi

PANEL_LINK="https://${SERVER_ADDR}:${PANEL_PORT}${PANEL_PATH}"

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
echo -e "\033[1;36m══════════════════════════════════════════════════\033[0m"
echo ""

# Remove one-time trigger from .bashrc
sed -i '/# 3xui-panel-info/d' /root/.bashrc 2>/dev/null || true
INFOEOF

    chmod +x /root/panel-info.sh

    # Add one-time auto-run: triggers on next shell prompt
    if ! grep -q '3xui-panel-info' /root/.bashrc 2>/dev/null; then
        echo 'bash /root/panel-info.sh # 3xui-panel-info' >> /root/.bashrc
    fi
}

# -------------------- main --------------------
main() {
    check_root
    install_deps
    detect_ip
    generate_cert
    setup_auto_renewal
    create_info_script
    install_3xui
    configure_panel

    echo ""
    read -rp $'\033[1;32m[INFO]\033[0m Установка завершена! Нажмите Enter для просмотра данных панели и QR-кодов...'
    bash /root/panel-info.sh
}
main
