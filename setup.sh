#!/usr/bin/env bash
# ============================================================================
# Чебурнету — нет! Автоматическая настройка VPN-сервера
# ============================================================================
#
# Протоколы:
#   - VLESS + TCP + TLS (порт 443/TCP)   через 3x-ui / Xray
#   - Trojan + TCP + TLS (порт 8443/TCP) через 3x-ui / Xray
#   - Hysteria2 QUIC    (порт 443/UDP)   h-ui панель + systemd
#   - MTProto Telegram  (порт 993/TCP)   mtg v2, Docker-контейнер
#
# Требования:
#   - Ubuntu 24.04 LTS
#   - Запуск от root: sudo bash setup.sh
#   - Доступ в интернет (Docker Hub, GitHub)
#
# Использование:
#   bash setup.sh
#
# После завершения скрипт выведет все данные доступа.
# SSH-ключ будет выведен в консоль — сохрани его!
# ============================================================================

set -euo pipefail

# ===================== НАСТРОЙКИ (можно менять) ==============================

SSH_PORT=59222          # Новый порт SSH
PANEL_PORT=2053         # Порт веб-панели 3x-ui
HUI_PORT=7391           # Порт веб-панели h-ui (Hysteria2)
XUI_VERSION="2.5.7"     # Версия образа 3x-ui
HY2_USER1="User1"       # Имя первого пользователя Hysteria2
HY2_USER2="User2"       # Имя второго пользователя Hysteria2

# Авто-генерация при пустом значении
PANEL_PASSWORD=""       # Пароль 3x-ui (пусто = сгенерировать)
HY2_PASS1=""            # Пароль Hysteria2 user1 (пусто = сгенерировать)
HY2_PASS2=""            # Пароль Hysteria2 user2 (пусто = сгенерировать)

# ===================== УТИЛИТЫ ==============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "\n${CYAN}${BOLD}[STEP]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

gen_pass() { openssl rand -hex 16; }
get_ip()   { curl -4 -s --max-time 5 ifconfig.me 2>/dev/null \
             || curl -4 -s --max-time 5 api.ipify.org 2>/dev/null \
             || ip -4 addr show scope global | grep -oP 'inet \K[\d.]+' | head -1; }

# Ожидание с ретраями: wait_for <описание> <макс_сек> <команда>
wait_for() {
    local desc="$1" max="$2"; shift 2
    local i=0
    while ! eval "$@" &>/dev/null; do
        ((i++))
        if (( i >= max )); then
            warn "${desc}: не дождались за ${max}с"
            return 1
        fi
        sleep 1
    done
    return 0
}

check_root() {
    [[ $EUID -eq 0 ]] || fail "Запускать от root: sudo bash setup.sh"
}

# ===================== ШАГ 1: Обновление системы ============================

step1_system() {
    info "Шаг 1/11: Обновление системы и установка пакетов"

    export DEBIAN_FRONTEND=noninteractive
    apt update -y
    apt upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"
    apt install -y \
        ufw fail2ban openssl sqlite3 \
        unattended-upgrades apt-listchanges curl

    ok "Система обновлена, пакеты установлены"
}

# ===================== ШАГ 2: BBR ===========================================

step2_bbr() {
    info "Шаг 2/11: BBR — ускорение TCP"

    cat > /etc/sysctl.d/99-bbr.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl -p /etc/sysctl.d/99-bbr.conf
    local BBR; BBR=$(sysctl -n net.ipv4.tcp_congestion_control)
    [[ "$BBR" == "bbr" ]] || fail "BBR не включился (текущее: $BBR)"

    ok "BBR активен"
}

# ===================== ШАГ 3: Автообновления ================================

step3_autoupdate() {
    info "Шаг 3/11: Автоматические обновления безопасности"

    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

    ok "Автообновления настроены"
}

# ===================== ШАГ 4: SSH hardening ==================================

step4_ssh() {
    info "Шаг 4/11: SSH hardening (порт ${SSH_PORT}, ключ ED25519, без пароля)"

    # Генерация ключа
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    rm -f /root/.ssh/id_admin /root/.ssh/id_admin.pub
    ssh-keygen -t ed25519 -f /root/.ssh/id_admin -N '' -C 'admin-key'
    cat /root/.ssh/id_admin.pub >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    # Вывод приватного ключа (сохрани!)
    echo ""
    echo "================================================================"
    echo "  ПРИВАТНЫЙ SSH-КЛЮЧ — СОХРАНИ В НАДЁЖНОЕ МЕСТО!"
    echo "================================================================"
    cat /root/.ssh/id_admin
    echo "================================================================"
    echo ""

    # Настройка sshd_config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    sed -i "s/^#*Port .*/Port ${SSH_PORT}/"                       /etc/ssh/sshd_config
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/'  /etc/ssh/sshd_config
    sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/'                   /etc/ssh/sshd_config
    sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/'  /etc/ssh/sshd_config
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/'   /etc/ssh/sshd_config
    sed -i 's/^#*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config

    # systemd socket override — ВАЖНО: явно оба IPv4 и IPv6!
    # Без явного 0.0.0.0 сокет создаётся только для IPv6 и снаружи не работает.
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat > /etc/systemd/system/ssh.socket.d/override.conf << EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:${SSH_PORT}
ListenStream=[::]:${SSH_PORT}
EOF

    # Проверка конфига
    mkdir -p /run/sshd
    sshd -t || fail "Ошибка в sshd_config"

    # Применить
    systemctl daemon-reload
    systemctl restart ssh.socket ssh.service

    # Проверка (ждём до 15 сек)
    wait_for "sshd порт ${SSH_PORT}" 15 "ss -tlnp | grep -q ':${SSH_PORT}'" \
        || fail "sshd не слушает порт ${SSH_PORT}"
    ok "SSH: порт ${SSH_PORT}, ключевая авторизация:"
    ss -tlnp | grep sshd
}

# ===================== ШАГ 5: UFW ==========================================

step5_ufw() {
    info "Шаг 5/11: UFW (файрвол)"

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_PORT}/tcp"  comment 'SSH'
    ufw allow "${PANEL_PORT}/tcp" comment '3x-ui panel'
    ufw allow '443/tcp'          comment 'VLESS TLS'
    ufw allow '443/udp'          comment 'Hysteria2 QUIC'
    ufw allow "${HUI_PORT}/tcp"  comment 'h-ui panel (Hysteria2)'
    ufw allow '8443/tcp'         comment 'Trojan TLS'
    ufw allow '993/tcp'          comment 'MTProto proxy (Telegram)'
    echo 'y' | ufw enable

    ok "UFW активен"
    ufw status verbose
}

# ===================== ШАГ 6: fail2ban =====================================

step6_fail2ban() {
    info "Шаг 6/11: fail2ban"

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
banaction = ufw

[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 7200
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban

    # Ждём пока jail поднимется (до 15 сек)
    wait_for "fail2ban sshd jail" 15 "fail2ban-client status sshd" \
        || warn "jail sshd ещё не готов (нормально при первом запуске)"

    ok "fail2ban настроен"
}

# ===================== ШАГ 7: Docker + 3x-ui ================================

step7_docker_xui() {
    info "Шаг 7/11: Docker и 3x-ui"

    # Docker
    if ! command -v docker &>/dev/null; then
        curl -fsSL https://get.docker.com | sh
    else
        ok "Docker уже установлен: $(docker --version)"
    fi

    # Структура директорий
    mkdir -p /root/3x-ui/{db,cert}

    # TLS сертификат (самоподписной)
    local SERVER_IP; SERVER_IP=$(get_ip)
    openssl req -x509 -newkey rsa:2048 \
        -keyout /root/3x-ui/cert/private.key \
        -out    /root/3x-ui/cert/cert.pem \
        -days 3650 -nodes \
        -subj "/C=FR/ST=Paris/L=Paris/O=Self/CN=${SERVER_IP}"
    chmod 600 /root/3x-ui/cert/private.key

    # docker-compose.yml
    cat > /root/3x-ui/docker-compose.yml << EOF
services:
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:${XUI_VERSION}
    container_name: 3x-ui
    hostname: vpn-server
    volumes:
      - \$PWD/db/:/etc/x-ui/
      - \$PWD/cert/:/root/cert/
    environment:
      XRAY_VMESS_AEAD_FORCED: "false"
      X_UI_ENABLE_FAIL2BAN: "true"
    tty: true
    network_mode: host
    restart: unless-stopped
EOF

    cd /root/3x-ui && docker compose up -d

    # Ждём пока контейнер поднимется и панель стартует (до 60 сек)
    wait_for "3x-ui контейнер" 60 "docker ps | grep -q '3x-ui'" \
        || fail "Контейнер 3x-ui не запустился"
    # Ждём пока панель начнёт слушать порт
    wait_for "3x-ui порт ${PANEL_PORT}" 30 "ss -tlnp | grep -q ':${PANEL_PORT}'" \
        || warn "3x-ui: порт ${PANEL_PORT} не слушает (проверь: docker logs 3x-ui)"

    ok "3x-ui запущен"
}

# ===================== ШАГ 8: Настройка 3x-ui ==============================

step8_xui_config() {
    info "Шаг 8/11: Настройка 3x-ui (HTTPS, пароль, basePath)"

    [[ -z "${PANEL_PASSWORD}" ]] && PANEL_PASSWORD=$(gen_pass)

    # Установить пароль
    docker exec 3x-ui ./x-ui setting -username admin -password "${PANEL_PASSWORD}"

    # Настройка TLS и basePath через SQLite
    BASE_PATH="/$(openssl rand -hex 8)/"
    sqlite3 /root/3x-ui/db/x-ui.db \
        "INSERT OR REPLACE INTO settings(key,value) VALUES('webCertFile','/root/cert/cert.pem');"
    sqlite3 /root/3x-ui/db/x-ui.db \
        "INSERT OR REPLACE INTO settings(key,value) VALUES('webKeyFile','/root/cert/private.key');"
    sqlite3 /root/3x-ui/db/x-ui.db \
        "INSERT OR REPLACE INTO settings(key,value) VALUES('webBasePath','${BASE_PATH}');"

    docker restart 3x-ui

    # Ждём пока панель перезапустится с HTTPS (до 30 сек)
    wait_for "3x-ui HTTPS" 30 "ss -tlnp | grep -q ':${PANEL_PORT}'" \
        || warn "3x-ui: порт ${PANEL_PORT} не слушает после рестарта"

    ok "3x-ui: basePath=${BASE_PATH}"
}

# ===================== ШАГ 9: Inbounds (VLESS + Trojan) ====================

step9_inbounds() {
    info "Шаг 9/11: Inbounds (VLESS 443/TCP + Trojan 8443/TCP)"

    local BASE="https://127.0.0.1:${PANEL_PORT}${BASE_PATH}"

    # Логин
    curl -sk -c /tmp/xui_c.txt -X POST "${BASE}login" \
        -d "username=admin&password=${PANEL_PASSWORD}"

    # VLESS + TCP + TLS (443)
    curl -sk -b /tmp/xui_c.txt -X POST "${BASE}panel/api/inbounds/add" \
        --data-urlencode 'remark=vless-tls' \
        --data-urlencode 'enable=true' \
        --data-urlencode 'port=443' \
        --data-urlencode 'protocol=vless' \
        --data-urlencode 'settings={"clients":[],"decryption":"none","fallbacks":[]}' \
        --data-urlencode 'streamSettings={"network":"tcp","security":"tls","tlsSettings":{"serverName":"","minVersion":"1.2","maxVersion":"1.3","certificates":[{"certificateFile":"/root/cert/cert.pem","keyFile":"/root/cert/private.key"}],"alpn":["h2","http/1.1"],"settings":{"allowInsecure":true,"fingerprint":"chrome"}},"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}' \
        --data-urlencode 'sniffing={"enabled":true,"destOverride":["http","tls","quic","fakedns"]}' \
        --data-urlencode 'up=0' --data-urlencode 'down=0' \
        --data-urlencode 'total=0' --data-urlencode 'expiryTime=0' \
        --data-urlencode 'listen=' > /dev/null

    # Trojan + TCP + TLS (8443)
    curl -sk -b /tmp/xui_c.txt -X POST "${BASE}panel/api/inbounds/add" \
        --data-urlencode 'remark=trojan-tcp' \
        --data-urlencode 'enable=true' \
        --data-urlencode 'port=8443' \
        --data-urlencode 'protocol=trojan' \
        --data-urlencode 'settings={"clients":[],"fallbacks":[]}' \
        --data-urlencode 'streamSettings={"network":"tcp","security":"tls","tlsSettings":{"serverName":"","minVersion":"1.2","maxVersion":"1.3","certificates":[{"certificateFile":"/root/cert/cert.pem","keyFile":"/root/cert/private.key"}],"alpn":["h2","http/1.1"],"settings":{"allowInsecure":true,"fingerprint":"chrome"}},"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}' \
        --data-urlencode 'sniffing={"enabled":true,"destOverride":["http","tls","quic","fakedns"]}' \
        --data-urlencode 'up=0' --data-urlencode 'down=0' \
        --data-urlencode 'total=0' --data-urlencode 'expiryTime=0' \
        --data-urlencode 'listen=' > /dev/null

    docker restart 3x-ui

    # Ждём пока xray поднимет порты 443 и 8443 (до 30 сек)
    wait_for "VLESS порт 443" 30 "ss -tlnp | grep -q ':443 '" \
        || warn "VLESS: порт 443 не слушает"
    wait_for "Trojan порт 8443" 15 "ss -tlnp | grep -q ':8443 '" \
        || warn "Trojan: порт 8443 не слушает"

    ok "Inbounds: VLESS (443) + Trojan (8443)"
}

# ===================== ШАГ 10: Hysteria2 (h-ui) ==============================

step10_hysteria2() {
    info "Шаг 10/11: Hysteria2 через h-ui панель (443/UDP, панель ${HUI_PORT}/TCP)"

    [[ -z "${HY2_PASS1}" ]] && HY2_PASS1=$(gen_pass)
    [[ -z "${HY2_PASS2}" ]] && HY2_PASS2=$(gen_pass)

    # Скачать h-ui
    mkdir -p /usr/local/h-ui/
    curl -fsSL https://github.com/jonssonyan/h-ui/releases/latest/download/h-ui-linux-amd64 \
        -o /usr/local/h-ui/h-ui
    chmod +x /usr/local/h-ui/h-ui

    # Systemd unit
    cat > /etc/systemd/system/h-ui.service << EOF
[Unit]
Description=h-ui Service
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=/usr/local/h-ui/
ExecStart=/usr/local/h-ui/h-ui -p ${HUI_PORT}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable h-ui && systemctl restart h-ui

    # Ждём пока h-ui стартует и создаст БД
    wait_for "h-ui панель" 15 "curl -sk -o /dev/null -w '%{http_code}' http://localhost:${HUI_PORT}/ | grep -q 200" \
        || warn "h-ui: панель не отвечает на порту ${HUI_PORT}"

    # Настроить HTTPS (использует сертификат от 3x-ui)
    sqlite3 /usr/local/h-ui/data/h_ui.db \
        "UPDATE config SET value='/root/3x-ui/cert/cert.pem' WHERE key='H_UI_CRT_PATH';"
    sqlite3 /usr/local/h-ui/data/h_ui.db \
        "UPDATE config SET value='/root/3x-ui/cert/private.key' WHERE key='H_UI_KEY_PATH';"

    # Настроить Hysteria2 конфиг
    local JWT_SECRET
    JWT_SECRET=$(sqlite3 /usr/local/h-ui/data/h_ui.db "SELECT value FROM config WHERE key='JWT_SECRET';")

    python3 -c "
import sqlite3, hashlib
conn = sqlite3.connect('/usr/local/h-ui/data/h_ui.db')

# Hysteria2 server config (YAML stored as string)
config = '''listen: \":443\"
tls:
  cert: /root/3x-ui/cert/cert.pem
  key: /root/3x-ui/cert/private.key
auth:
  type: http
  http:
    url: https://127.0.0.1:${HUI_PORT}/hui/hysteria2/auth
    insecure: true
trafficStats:
  listen: \":7653\"
  secret: ${JWT_SECRET}
masquerade:
  type: proxy
  proxy:
    url: https://www.apple.com
    rewriteHost: true'''
conn.execute('UPDATE config SET value=? WHERE key=?', (config, 'HYSTERIA2_CONFIG'))
conn.execute('UPDATE config SET value=? WHERE key=?', ('1', 'HYSTERIA2_ENABLE'))

# Add user accounts (con_pass = username.password, pass = SHA-224 hash)
for user, pwd in [('${HY2_USER1}', '${HY2_PASS1}'), ('${HY2_USER2}', '${HY2_PASS2}')]:
    h = hashlib.sha224(pwd.encode()).hexdigest()
    con_pass = f'{user}.{pwd}'
    conn.execute('''INSERT INTO account (username, pass, con_pass, quota, download, upload,
        expire_time, kick_util_time, device_no, role, deleted)
        VALUES (?, ?, ?, -1, 0, 0, 253370736000000, 0, 3, 'user', 0)''', (user, h, con_pass))

conn.commit()
conn.close()
"

    # Перезапустить для применения всех настроек
    systemctl restart h-ui

    # Ждём пока Hysteria2 поднимет 443/UDP (до 30 сек)
    wait_for "Hysteria2 порт 443/udp" 30 "ss -ulnp | grep -q ':443 '" \
        || warn "Hysteria2: порт 443/UDP не слушает (проверь: journalctl -u h-ui)"

    ok "h-ui + Hysteria2 запущены"
}

# ===================== ШАГ 11: MTProto proxy =================================

step11_mtproto() {
    info "Шаг 11/11: MTProto proxy для Telegram (993/TCP)"
    # Нюансы:
    #   - mtg v2 требует TOML-конфиг (секрет нельзя передать аргументом)
    #   - Обязательно --network host (Docker NAT ломает MTProto-хендшейк)
    #   - domain-fronting-port = 443 обязателен

    mkdir -p /etc/mtg
    MTG_SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret google.com 2>/dev/null)

    cat > /etc/mtg/config.toml << EOF
secret = "${MTG_SECRET}"
bind-to = "0.0.0.0:993"
domain-fronting-port = 443
EOF

    docker run -d \
        --name mtg \
        --restart always \
        --network host \
        -v /etc/mtg/config.toml:/config.toml \
        nineseconds/mtg:2 run /config.toml

    # Ждём пока MTProto поднимет 993/TCP (до 30 сек)
    wait_for "MTProto порт 993" 30 "ss -tlnp | grep -q ':993 '" \
        || warn "MTProto: порт 993 не слушает (проверь: docker logs mtg)"

    ok "MTProto запущен"
}

# ===================== ИТОГОВАЯ СВОДКА ======================================

print_summary() {
    local SERVER_IP; SERVER_IP=$(get_ip)

    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║           НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО!                  ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "${BOLD}Сервер:${NC} ${SERVER_IP}"
    echo ""

    echo -e "${BOLD}── SSH ──────────────────────────────────────────────────────${NC}"
    echo "  Порт:    ${SSH_PORT}"
    echo "  Ключ:    /root/.ssh/id_admin  (был выведен выше — сохрани!)"
    echo "  Команда: ssh -i server_key -p ${SSH_PORT} root@${SERVER_IP}"
    echo ""

    echo -e "${BOLD}── 3x-ui Панель ─────────────────────────────────────────────${NC}"
    echo "  URL:     https://${SERVER_IP}:${PANEL_PORT}${BASE_PATH}"
    echo "  Логин:   admin"
    echo "  Пароль:  ${PANEL_PASSWORD}"
    echo ""

    echo -e "${BOLD}── h-ui (Hysteria2) ─────────────────────────────────────────${NC}"
    echo "  Панель: https://${SERVER_IP}:${HUI_PORT}"
    echo "  Логин:  sysadmin / sysadmin  (сменить после первого входа!)"
    echo "  URI ${HY2_USER1}: hysteria2://${HY2_USER1}.${HY2_PASS1}@${SERVER_IP}:443/?insecure=1#hy2-${HY2_USER1}"
    echo "  URI ${HY2_USER2}: hysteria2://${HY2_USER2}.${HY2_PASS2}@${SERVER_IP}:443/?insecure=1#hy2-${HY2_USER2}"
    echo ""

    echo -e "${BOLD}── MTProto (Telegram) ───────────────────────────────────────${NC}"
    echo "  https://t.me/proxy?server=${SERVER_IP}&port=993&secret=${MTG_SECRET}"
    echo ""

    echo -e "${BOLD}── Сервисы ──────────────────────────────────────────────────${NC}"
    docker ps --format "  {{.Names}}: {{.Status}}"
    echo ""

    echo -e "${BOLD}── Порты ────────────────────────────────────────────────────${NC}"
    ss -tlnp | grep -E ":(${SSH_PORT}|${PANEL_PORT}|${HUI_PORT}|443|8443|993) " \
        | awk '{print "  TCP " $4}' | sort -u
    ss -ulnp | grep ':443 ' | awk '{print "  UDP " $4}' | sort -u
    echo ""

    # Сохранить сводку в файл
    cat > /root/vpn_credentials.txt << EOF
# VPN Server Credentials — $(date)
SERVER_IP=${SERVER_IP}

[SSH]
PORT=${SSH_PORT}
KEY=/root/.ssh/id_admin
CMD=ssh -i server_key -p ${SSH_PORT} root@${SERVER_IP}

[3x-ui]
URL=https://${SERVER_IP}:${PANEL_PORT}${BASE_PATH}
USER=admin
PASS=${PANEL_PASSWORD}

[h-ui (Hysteria2)]
PANEL=https://${SERVER_IP}:${HUI_PORT}
PANEL_USER=sysadmin
PANEL_PASS=sysadmin
URI_${HY2_USER1}=hysteria2://${HY2_USER1}.${HY2_PASS1}@${SERVER_IP}:443/?insecure=1#hy2-${HY2_USER1}
URI_${HY2_USER2}=hysteria2://${HY2_USER2}.${HY2_PASS2}@${SERVER_IP}:443/?insecure=1#hy2-${HY2_USER2}

[MTProto]
LINK=https://t.me/proxy?server=${SERVER_IP}&port=993&secret=${MTG_SECRET}
EOF

    echo -e "  Сводка сохранена в: ${CYAN}/root/vpn_credentials.txt${NC}"
    echo ""
}

# ===================== MAIN =================================================

main() {
    check_root
    step1_system
    step2_bbr
    step3_autoupdate
    step4_ssh
    step5_ufw
    step6_fail2ban
    step7_docker_xui
    step8_xui_config
    step9_inbounds
    step10_hysteria2
    step11_mtproto
    print_summary
}

main
