# 3x-ui Installer

One-command installer for [3x-ui](https://github.com/MHSanaei/3x-ui) panel with **auto-renewing self-signed TLS certificates**.

## Quick Install

```bash
bash <(curl -Ls https://raw.githubusercontent.com/YOUR_USERNAME/3x-ui-install/main/setup-3xui.sh)
```

## What it does

1. Updates the system, installs `curl`, `openssl`, `qrencode`
2. Asks for server IP/domain
3. Generates ECC (prime256v1) self-signed certificate valid for 6 days
4. Sets up automatic certificate renewal every 5 days via cron
5. Installs 3x-ui from the official repository
6. Displays panel credentials and certificate info

## Certificate auto-renewal

- Certificate is valid for **6 days**
- Cron job renews it every **5 days** (before expiry)
- Panel restarts automatically after renewal
- No manual intervention required
- Renewal script: `/root/cert/renew-cert.sh`

## After installation

1. Open `https://YOUR_SERVER_IP:PORT` in a browser
2. Go to **Panel Settings → TLS**
3. Set paths:
   - Public key: `/root/cert/cert.crt`
   - Private key: `/root/cert/private.key`
4. Save and restart the panel

## Panel management

```bash
x-ui
```

## Requirements

- Ubuntu 20.04 / 22.04 / 24.04
- Root access
