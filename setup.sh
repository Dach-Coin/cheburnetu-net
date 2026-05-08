#!/usr/bin/env bash
# ============================================================================
# Чебурнету — нет! Автоматическая настройка VPN-сервера
# ============================================================================
#
# Протоколы:
#   - VLESS + Vision + Reality (порт 443/TCP)  через 3x-ui / Xray
#   - VLESS + Vision + Reality (порт 2083/TCP) через 3x-ui / Xray
#   - Trojan + Reality         (порт 2087/TCP) через 3x-ui / Xray
#   - Trojan + TLS self-signed (порт 8443/TCP) через 3x-ui / Xray (резерв)
#   - VLESS + Vision + TLS sf  (порт 8880/TCP) через 3x-ui / Xray (резерв)
#   - Hysteria2 QUIC + Salamander (порт 443/UDP) h-ui панель + systemd
#   - MTProto Telegram         (порт 993/TCP)  mtg v2, Docker-контейнер
#   - AnyTLS                   (порт 8444/TCP) sing-box, отдельный демон
#
# Reality маскировка: SNI = www.yandex.ru (российский домен → DPI-нейтрально).
# spiderX = "/" — антипробинг. Все клиенты с fingerprint=chrome (uTLS).
# Дополнительно — 2 self-signed TLS inbound'а как РЕЗЕРВ: Trojan-TLS на 8443
# и VLESS-TLS на 8880, с общим cert от 3x-ui панели (step7). Идея: если DPI
# когда-нибудь начнёт палить Reality-handshake к yandex.ru, останется
# рабочий канал на TLS. Проверено 2026-05-08: на этом хостере (AS56971)
# self-signed DPI не палит.
#
# AnyTLS (sing-box, step12) — экспериментальный канал с padding+multiplexing,
# ломающий ML-классификаторы packet patterns на Trojan/VLESS-TLS. Свежий
# протокол (2024+), App-ID базы NGFW его пока не знают → плюс для корп-сетей.
# Cert общий с панелью (тот же self-signed). 3 пользователя (User1/2/3),
# управление через /etc/sing-box/config.json + systemctl restart sing-box.
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
HUI_BASE_PATH=""        # basePath h-ui (пусто = сгенерировать)
XUI_VERSION="2.9.4"     # Версия образа 3x-ui — актуальный pin (раз в пару месяцев bump'ить)
XRAY_VERSION="26.3.27"  # Версия Xray для ручной подмены. С 2.9.x — встроенный Xray уже свежий
                        # (2.9.4 шёл с Xray 26.4.25), step9a можно пропускать. Оставлен на случай
                        # если хочется зафиксировать конкретную версию или подменить под старый pin.
HY2_USER1="User1"       # Имя первого пользователя Hysteria2
HY2_USER2="User2"       # Имя второго пользователя Hysteria2

# AnyTLS через sing-box — отдельный демон, не связан с 3x-ui панелью.
# Альтернативный канал на случай отвала Reality. Multi-user через JSON.
ANYTLS_VERSION="1.13.11" # sing-box (на 2026-05): https://github.com/SagerNet/sing-box/releases
ANYTLS_PORT=8444         # порт AnyTLS (8443 занят Trojan-TLS, поэтому 8444)
ANYTLS_USER1="User1"     # имена пользователей AnyTLS — у каждого свой пароль (revoke per-user)
ANYTLS_USER2="User2"
ANYTLS_USER3="User3"

# Reality dest/SNI (target должен быть доступен с сервера — проверяется в финале)
REALITY_SNI="www.yandex.ru"
REALITY_TARGET="www.yandex.ru:443"

# Hysteria2 маскировочный URL (target должен быть доступен с сервера)
HY2_MASQUERADE_URL="https://www.bing.com"

# Авто-генерация при пустом значении
PANEL_PASSWORD=""       # Пароль 3x-ui (пусто = сгенерировать)
HY2_PASS1=""            # Пароль Hysteria2 user1 (пусто = сгенерировать)
HY2_PASS2=""            # Пароль Hysteria2 user2 (пусто = сгенерировать)
HY2_OBFS_PASS=""        # Пароль Salamander obfs (пусто = сгенерировать)
                        # ВАЖНО: под set -u нужно объявить здесь, иначе step10
                        # упадёт `unbound variable` ещё до своей default-генерации.
ANYTLS_PASS1=""         # Пароль AnyTLS User1 (пусто = сгенерировать)
ANYTLS_PASS2=""         # Пароль AnyTLS User2 (пусто = сгенерировать)
ANYTLS_PASS3=""         # Пароль AnyTLS User3 (пусто = сгенерировать)

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
    info "Шаг 1/12: Обновление системы и установка пакетов"

    export DEBIAN_FRONTEND=noninteractive

    # Cloud-mirrors некоторых хостеров (nova.clouds, mirror.something) бывают
    # перегружены и режут скорость до десятков kB/s. Заменяем на главный
    # archive.ubuntu.com — у него Fastly CDN, отвечает стабильно везде.
    sed -i 's|[a-z0-9.-]*\.clouds\.archive\.ubuntu\.com|archive.ubuntu.com|g' \
        /etc/apt/sources.list /etc/apt/sources.list.d/*.list \
        /etc/apt/sources.list.d/*.sources 2>/dev/null || true

    # На VPN/VPS не нужно обновлять linux-firmware (~641 MB прошивок Wi-Fi/GPU)
    # и microcode (CPU-микрокод применяется хостером, не гостем). Hold ускоряет
    # apt upgrade в ~10 раз и экономит трафик.
    #
    # Дополнительно — hold openssh-{server,client,sftp-server} + meta `ssh`:
    # апгрейд этих пакетов запускает `systemctl restart ssh.service` в postinst
    # → текущая SSH-сессия (та, через которую мы запускаем setup.sh) умирает,
    # setup.sh получает SIGHUP, deploy ломается посреди процесса. Свежий VPS
    # обычно идёт со свежим sshd, hold безопасен. Юзер при желании отпустит
    # после деплоя: `apt-mark unhold openssh-server && apt upgrade openssh-server`.
    apt-mark hold linux-firmware amd64-microcode intel-microcode \
        openssh-server openssh-client openssh-sftp-server ssh 2>/dev/null || true

    # needrestart любит auto-рестартить сервисы при апгрейде их зависимостей
    # (libssl, libpam). Это ещё один способ убить нашу SSH-сессию посреди apt
    # upgrade. Переводим в режим «list only» — никаких автоматических рестартов.
    # После deploy юзер может вернуть стандартное поведение, удалив этот файл.
    mkdir -p /etc/needrestart/conf.d
    cat > /etc/needrestart/conf.d/00-no-auto-restart.conf << 'EOF'
$nrconf{restart} = 'l';
EOF

    apt update -y
    apt upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"
    apt install -y \
        ufw fail2ban openssl sqlite3 \
        unattended-upgrades apt-listchanges curl

    ok "Система обновлена, пакеты установлены"
}

# ===================== ШАГ 1b: Swap файл ====================================
# На VPS с 1-2 GB RAM swap нужен как страховка от OOM при пиковой нагрузке
# (apt upgrade + docker pull одновременно, или DDoS на сервис). Без swap
# процесс умирает с OOM, восстановление только через ручной рестарт сервиса.
# 1 GB — компромисс: достаточно для buffer'а, не съедает много диска (16 GB
# свободно на VPS с 19 GB). vm.swappiness=10 — VPN-сервисы живут в RAM,
# swap трогать только при реальном давлении (дефолт 60 — слишком агрессивно
# для in-RAM workload).
step1b_swap() {
    info "Шаг 1b/12: Swap файл (1 GB) — защита от OOM"

    if [[ -f /swapfile ]] && swapon --show=NAME --noheadings | grep -q '^/swapfile$'; then
        ok "swap уже настроен"
        return 0
    fi

    if [[ ! -f /swapfile ]]; then
        # fallocate быстрее dd, но на старых ФС без extent может дать sparse
        # файл (mkswap его отвергнет). Fallback на dd на случай.
        fallocate -l 1G /swapfile 2>/dev/null \
            || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
    fi

    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile

    grep -q '^/swapfile' /etc/fstab \
        || echo '/swapfile none swap sw 0 0' >> /etc/fstab

    cat > /etc/sysctl.d/99-swap.conf << 'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
    sysctl -p /etc/sysctl.d/99-swap.conf >/dev/null

    ok "swap включён: 1G, swappiness=10"
}

# ===================== ШАГ 2: BBR ===========================================

step2_bbr() {
    info "Шаг 2/12: BBR — ускорение TCP"

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
    info "Шаг 3/12: Автоматические обновления безопасности"

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
    info "Шаг 4/12: SSH hardening (порт ${SSH_PORT}, ключ ED25519, без пароля)"

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

    # Отключить ssh.socket — на Ubuntu 24.04 socket activation может
    # молча дропать соединения после DoS-атак или при проблемах с handoff.
    # sshd должен слушать порт напрямую через ssh.service.
    systemctl stop ssh.socket 2>/dev/null || true
    systemctl disable ssh.socket 2>/dev/null || true
    rm -rf /etc/systemd/system/ssh.socket.d

    # Проверка конфига
    mkdir -p /run/sshd
    sshd -t || fail "Ошибка в sshd_config"

    # Применить — только ssh.service, без socket
    systemctl daemon-reload
    systemctl enable ssh.service
    systemctl restart ssh.service

    # Проверка (ждём до 15 сек)
    wait_for "sshd порт ${SSH_PORT}" 15 "ss -tlnp | grep -q ':${SSH_PORT}'" \
        || fail "sshd не слушает порт ${SSH_PORT}"
    ok "SSH: порт ${SSH_PORT}, ключевая авторизация:"
    ss -tlnp | grep sshd
}

# ===================== ШАГ 5: UFW ==========================================

step5_ufw() {
    info "Шаг 5/12: UFW (файрвол)"

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_PORT}/tcp"  comment 'SSH'
    ufw allow "${PANEL_PORT}/tcp" comment '3x-ui panel'
    ufw allow '443/tcp'          comment 'VLESS Reality (yandex)'
    ufw allow '443/udp'          comment 'Hysteria2 QUIC+Salamander'
    ufw allow "${HUI_PORT}/tcp"  comment 'h-ui panel (Hysteria2)'
    ufw allow '2083/tcp'         comment 'VLESS Reality (yandex)'
    ufw allow '2087/tcp'         comment 'Trojan Reality (yandex)'
    ufw allow '8443/tcp'         comment 'Trojan TLS self-signed (резерв)'
    ufw allow '8880/tcp'         comment 'VLESS TLS self-signed (резерв)'
    ufw allow "${ANYTLS_PORT}/tcp" comment 'AnyTLS (sing-box)'
    ufw allow '993/tcp'          comment 'MTProto proxy (Telegram)'
    echo 'y' | ufw enable

    ok "UFW активен"
    ufw status verbose
}

# ===================== ШАГ 5b: Блок публичных сканеров =====================
# Censys.io / Shodan / аналоги сканят весь IPv4 раз в несколько дней и публикуют
# fingerprint'ы хостов в открытой БД. Для нас риск: JA3/JA4 наших TLS-инбаундов,
# cert-fingerprint и тег «self-signed» попадают в search.censys.io / shodan.io,
# откуда DPI-системы могут собирать списки «вероятных VPN-серверов».
# Блокируем их сканирующие диапазоны insert'ом ПЕРЕД allow-правилами —
# иначе UFW матчит allow первым.
# Расширять при необходимости (BinaryEdge, ZoomEye, Onyphe).
step5b_scanner_blocklist() {
    info "Шаг 5b/12: UFW blocklist публичных сканеров (Censys + Shodan)"

    local RANGES=(
        # --- Censys.io (https://search.censys.io/about, /24 corporate) ---
        "162.142.125.0/24"
        "167.94.138.0/24"
        "167.94.145.0/24"
        "167.94.146.0/24"
        "167.248.133.0/24"
        "199.45.154.0/24"
        "199.45.155.0/24"
        "206.168.34.0/24"

        # --- Shodan corporate /24 (HKHL Holdings, Shodan LLC) ---
        "198.20.69.0/24"
        "198.20.70.0/24"
        "198.20.99.0/24"
        "208.180.20.0/24"
        "209.126.110.0/24"
        "66.240.192.0/24"
        "66.240.236.0/24"

        # --- Shodan distributed scanners на shared-провайдерах (single IPs).
        # Список «стабильный» в community, но Shodan ротирует — раз в полгода
        # стоит сверяться с актуальным списком (например, github.com/stamparm/maltrail).
        "71.6.135.131"
        "71.6.146.130"
        "71.6.146.185"
        "71.6.158.166"
        "71.6.165.200"
        "71.6.167.142"
        "80.82.77.33"
        "80.82.77.139"
        "82.221.105.6"
        "82.221.105.7"
        "85.25.43.94"
        "85.25.103.50"
        "88.198.36.144"
        "88.198.59.10"
        "93.120.27.62"
    )

    for r in "${RANGES[@]}"; do
        if ufw status | grep -q "${r}"; then
            ok "уже забанен: ${r}"
        else
            ufw insert 1 deny from "${r}" comment 'Censys/Shodan blocklist' >/dev/null
            ok "добавлен deny: ${r}"
        fi
    done
}

# ===================== ШАГ 6: fail2ban =====================================

step6_fail2ban() {
    info "Шаг 6/12: fail2ban"

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
banaction = ufw
backend  = systemd

[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
maxretry = 3
bantime  = 7200

[sshd-preauth]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
mode     = aggressive
maxretry = 5
findtime = 60
bantime  = 3600
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban

    # Ждём пока jail поднимется (до 15 сек)
    wait_for "fail2ban sshd jail" 15 "fail2ban-client status sshd" \
        || warn "jail sshd ещё не готов (нормально при первом запуске)"

    ok "fail2ban настроен (sshd + sshd-preauth)"
}

# ===================== ШАГ 7: Docker + 3x-ui ================================

step7_docker_xui() {
    info "Шаг 7/12: Docker и 3x-ui"

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

    (cd /root/3x-ui && docker compose up -d)

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
    info "Шаг 8/12: Настройка 3x-ui (HTTPS, пароль, basePath)"

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

# ===================== ШАГ 9a: Подмена Xray на свежий ======================
# Образ 3x-ui приклеен к XUI_VERSION, но Xray внутри уходит в legacy за месяц.
# Тащим релизный бинарник с GitHub и подменяем через docker cp. Если pull
# к release-assets timeout-ится (бывает на хостерах с обрезанным egress) —
# работаем со встроенной версией, в финале выводится warn.
step9a_xray_upgrade() {
    info "Шаг 9a/12: Обновление Xray до v${XRAY_VERSION}"

    local URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip"
    if curl -fsSL --max-time 60 -o /tmp/xray-new.zip "${URL}"; then
        python3 -m zipfile -e /tmp/xray-new.zip /tmp/xray-new/
        chmod +x /tmp/xray-new/xray
        docker cp 3x-ui:/app/bin/xray-linux-amd64 /root/3x-ui/xray-linux-amd64.old || true
        docker cp /tmp/xray-new/xray 3x-ui:/app/bin/xray-linux-amd64
        docker exec 3x-ui chmod +x /app/bin/xray-linux-amd64
        # Берём ПЕРВУЮ строку без `| head` / `| awk exit` — оба варианта закрывают
        # stdin и xray ловит SIGPIPE → под pipefail это exit 141 и валит скрипт.
        # Читаем весь stdout, отрезаем хвост через bash parameter expansion.
        local V; V=$(docker exec 3x-ui /app/bin/xray-linux-amd64 -version 2>/dev/null)
        V="${V%%$'\n'*}"
        ok "Xray обновлён: ${V}"
        rm -rf /tmp/xray-new /tmp/xray-new.zip
    else
        warn "Не удалось скачать Xray v${XRAY_VERSION} (хостер режет release-assets?). Остаёмся на встроенной версии."
    fi
}

# ===================== ШАГ 9b: Inbounds (3 × Reality + 2 × TLS-резерв) =====
# Reality (3 шт.) на одном SNI=${REALITY_SNI}. Каждый со своей парой ключей
# X25519 (генерится через xray) и одним рандомным shortID.
# TLS-резерв (2 шт.): Trojan-TLS на 8443 и VLESS-TLS на 8880 с общим
# self-signed cert от 3x-ui панели. Назначение — fallback, если DPI начнёт
# палить Reality-handshake. На AS56971 self-signed работает (2026-05-08).
# Клиенты добавляются через панель — 3x-ui сам подставит uuid/password.
step9b_inbounds() {
    info "Шаг 9b/12: Inbounds — 3 × Reality (${REALITY_SNI}) + 2 × TLS-резерв (8443/8880)"

    local BASE="https://127.0.0.1:${PANEL_PORT}${BASE_PATH}"
    curl -sk -c /tmp/xui_c.txt -X POST "${BASE}login" \
        -d "username=admin&password=${PANEL_PASSWORD}" > /dev/null

    # Идемпотентность: при повторном запуске setup.sh INSERT через panel API
    # создаст дубликаты на тех же портах → port-conflict при рестарте Xray.
    # Чистим записи на наших портах ДО создания. Клиентов в БД на свежем
    # деплое нет; на existing-сервере DELETE снесёт привязанных клиентов —
    # это осознанный trade-off (setup.sh = clean-deploy сценарий).
    sqlite3 /root/3x-ui/db/x-ui.db \
        "DELETE FROM inbounds WHERE port IN (443, 2083, 2087, 8443, 8880);"

    _add_reality_inbound() {
        local PORT="$1" PROTO="$2" REMARK="$3"

        # пара X25519 от xray. Формат вывода менялся между версиями:
        #   Xray <=26.2.x: "Private key: X"   / "Public key: Y"
        #   Xray  26.3.x:  "PrivateKey: X"    / "Password (PublicKey): Y"  / "Hash32: ..."
        # Берём последнее слово на строках содержащих Private/Public/Password.
        local KEYS PRIV PUB SID
        KEYS=$(docker exec 3x-ui /app/bin/xray-linux-amd64 x25519)
        PRIV=$(echo "$KEYS" | awk '/[Pp]rivate/ {print $NF; exit}')
        PUB=$( echo "$KEYS" | awk '/Password|[Pp]ublic/ {print $NF; exit}')
        if [[ -z "$PRIV" || -z "$PUB" ]]; then
            fail "x25519 parse failed: PRIV='$PRIV' PUB='$PUB' RAW=$'\n'$KEYS"
        fi
        SID=$(openssl rand -hex 8)

        local SETTINGS
        if [[ "$PROTO" == "vless" ]]; then
            SETTINGS='{"clients":[],"decryption":"none","fallbacks":[]}'
        else
            SETTINGS='{"clients":[],"fallbacks":[]}'
        fi

        local STREAM
        STREAM=$(cat <<JSON
{"network":"tcp","security":"reality","externalProxy":[],
 "realitySettings":{"show":false,"xver":0,"target":"${REALITY_TARGET}",
  "serverNames":["${REALITY_SNI}"],
  "privateKey":"${PRIV}","shortIds":["${SID}",""],
  "settings":{"publicKey":"${PUB}","fingerprint":"chrome","serverName":"","spiderX":"/"}},
 "tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}
JSON
)

        curl -sk -b /tmp/xui_c.txt -X POST "${BASE}panel/api/inbounds/add" \
            --data-urlencode "remark=${REMARK}" \
            --data-urlencode 'enable=true' \
            --data-urlencode "port=${PORT}" \
            --data-urlencode "protocol=${PROTO}" \
            --data-urlencode "settings=${SETTINGS}" \
            --data-urlencode "streamSettings=${STREAM}" \
            --data-urlencode 'sniffing={"enabled":true,"destOverride":["http","tls","quic","fakedns"]}' \
            --data-urlencode 'up=0' --data-urlencode 'down=0' \
            --data-urlencode 'total=0' --data-urlencode 'expiryTime=0' \
            --data-urlencode 'listen=' > /dev/null
    }

    # TLS-резерв на 8443 / 8880 — общий self-signed cert от панели.
    # Путь /root/cert/ — это mount из step7 ($PWD/cert/ → /root/cert/).
    _add_tls_inbound() {
        local PORT="$1" PROTO="$2" REMARK="$3"

        local SETTINGS
        if [[ "$PROTO" == "vless" ]]; then
            SETTINGS='{"clients":[],"decryption":"none","fallbacks":[]}'
        else
            SETTINGS='{"clients":[],"fallbacks":[]}'
        fi

        local STREAM
        STREAM=$(cat <<JSON
{"network":"tcp","security":"tls","externalProxy":[],
 "tlsSettings":{"serverName":"","minVersion":"1.2","maxVersion":"1.3",
  "cipherSuites":"",
  "certificates":[{"certificateFile":"/root/cert/cert.pem",
                   "keyFile":"/root/cert/private.key"}],
  "alpn":["h2","http/1.1"],
  "settings":{"allowInsecure":false,"fingerprint":"chrome"}},
 "tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}
JSON
)

        curl -sk -b /tmp/xui_c.txt -X POST "${BASE}panel/api/inbounds/add" \
            --data-urlencode "remark=${REMARK}" \
            --data-urlencode 'enable=true' \
            --data-urlencode "port=${PORT}" \
            --data-urlencode "protocol=${PROTO}" \
            --data-urlencode "settings=${SETTINGS}" \
            --data-urlencode "streamSettings=${STREAM}" \
            --data-urlencode 'sniffing={"enabled":true,"destOverride":["http","tls","quic","fakedns"]}' \
            --data-urlencode 'up=0' --data-urlencode 'down=0' \
            --data-urlencode 'total=0' --data-urlencode 'expiryTime=0' \
            --data-urlencode 'listen=' > /dev/null
    }

    _add_reality_inbound 443  vless  vless-reality-443
    _add_reality_inbound 2083 vless  vless-reality-2083
    _add_reality_inbound 2087 trojan trojan-reality-2087
    _add_tls_inbound     8443 trojan trojan-tls-8443-fallback
    _add_tls_inbound     8880 vless  vless-tls-8880-fallback

    rm -f /tmp/xui_c.txt
}

# ===================== ШАГ 9c: Xray template (UseIPv4) ====================
# Если у хостера IPv6 битый или AAAA-резолвинг ведёт в timeout, Xray
# по дефолту тратит секунды на v6-fallback. Форсим IPv4 везде.
step9c_xray_template() {
    info "Шаг 9c/12: Xray template — DNS UseIPv4 (защита от битого IPv6)"

    # Берём текущий config.json (3x-ui генерит его из inbounds в БД),
    # из inbounds оставляем ТОЛЬКО api inbound (нужен для stats / online-tracking
    # в панели — без него client_traffics.up/down=0 и панель не показывает онлайн).
    # Если api inbound в свежем дефолте отсутствует — добавляем принудительно.
    # Пользовательские inbound'ы 3x-ui подмешает из БД при сборке.
    # Дописываем dns.queryStrategy=UseIPv4 и outbound.freedom.domainStrategy=UseIPv4.
    docker exec 3x-ui sh -c 'cat /app/bin/config.json' | python3 -c '
import json, sys
c = json.load(sys.stdin)

# Сохраняем api inbound (3x-ui 2.9.x кладёт его сразу в дефолт), либо создаём.
api_inbound = next((i for i in c.get("inbounds", []) if i.get("tag") == "api"), None)
if api_inbound is None:
    api_inbound = {
        "listen": "127.0.0.1",
        "port": 62789,
        "protocol": "tunnel",
        "settings": {"address": "127.0.0.1"},
        "streamSettings": None,
        "tag": "api",
        "sniffing": None,
    }
c["inbounds"] = [api_inbound]

c["dns"] = {
    "servers": ["1.1.1.1", "8.8.8.8", "https://1.1.1.1/dns-query"],
    "queryStrategy": "UseIPv4"
}
for ob in c.get("outbounds", []):
    if ob.get("protocol") == "freedom":
        ob.setdefault("settings", {})["domainStrategy"] = "UseIPv4"

# Policy для уровня 0 — переопределяем дефолты Xray 26.x. Дефолтные значения
# (connIdle=300, uplinkOnly=2, downlinkOnly=5) ОЧЕНЬ агрессивные и рубят
# долгоживущие idle-соединения через 5 секунд тишины с downlink-стороны.
# Это убивает Telegram-пуши и любые long-poll mqtt-стримы: клиент держит
# тихий TCP к серверу, ждёт push, а Xray его рубит → клиент теряет
# уведомления при заблокированном экране ПК/телефона.
# Ставим:
#   connIdle    = 1800  (30 мин — push-сессии переживают idle)
#   uplinkOnly  = 0     (disabled — не закрывать half-open от клиента)
#   downlinkOnly= 0     (disabled — не закрывать half-open от сервера)
levels = c.setdefault("policy", {}).setdefault("levels", {}).setdefault("0", {})
levels["connIdle"]     = 1800
levels["uplinkOnly"]   = 0
levels["downlinkOnly"] = 0
levels["handshake"]    = 4

print(json.dumps(c, indent=2, ensure_ascii=False))
' > /tmp/xray_template.json
    # Если python3 упал (битый config.json от 3x-ui, отсутствие inbounds, etc),
    # файл будет пустым — `readfile()` запишет '' в xrayTemplateConfig, и
    # 3x-ui сломается на рестарте. Fail-fast здесь, до записи в БД.
    [[ -s /tmp/xray_template.json ]] || fail "xray template пустой (python3 упал?)"

    sqlite3 /root/3x-ui/db/x-ui.db \
        "INSERT OR REPLACE INTO settings(key,value) VALUES('xrayTemplateConfig', readfile('/tmp/xray_template.json'));"
    rm -f /tmp/xray_template.json

    docker restart 3x-ui

    wait_for "VLESS Reality 443"  30 "ss -tlnp | grep -q ':443 '"  || warn "443/tcp не слушает"
    wait_for "VLESS Reality 2083" 15 "ss -tlnp | grep -q ':2083 '" || warn "2083/tcp не слушает"
    wait_for "Trojan Reality 2087" 15 "ss -tlnp | grep -q ':2087 '" || warn "2087/tcp не слушает"
    wait_for "Trojan TLS 8443"    15 "ss -tlnp | grep -q ':8443 '" || warn "8443/tcp не слушает"
    wait_for "VLESS  TLS 8880"    15 "ss -tlnp | grep -q ':8880 '" || warn "8880/tcp не слушает"

    ok "Inbounds: Reality 443/2083/2087 + TLS-резерв 8443/8880, DNS UseIPv4"
}

# ===================== ШАГ 10: Hysteria2 (h-ui) ==============================

step10_hysteria2() {
    info "Шаг 10/12: Hysteria2 через h-ui панель (443/UDP, панель ${HUI_PORT}/TCP)"

    [[ -z "${HY2_PASS1}" ]] && HY2_PASS1=$(gen_pass)
    [[ -z "${HY2_PASS2}" ]] && HY2_PASS2=$(gen_pass)
    [[ -z "${HUI_BASE_PATH}" ]] && HUI_BASE_PATH="/$(openssl rand -hex 6)"
    # OBFS Salamander обязателен на ru-провайдерах: голый QUIC/TLS Hy2
    # детектируется DPI по сигнатуре ClientHello → пакеты до сервера не доходят
    # (в логе h-ui НИ ОДНОГО auth-callback'а — клиент даже до auth не добегает).
    # Salamander = XOR-обфускация всего UDP-трафика по shared password.
    [[ -z "${HY2_OBFS_PASS}" ]] && HY2_OBFS_PASS=$(openssl rand -base64 16 | tr -d '=+/')

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
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable h-ui && systemctl restart h-ui

    # Ждём пока h-ui стартует и создаст БД. Проверяем по факту прослушки
    # порта, а не HTTP-код: h-ui по умолчанию HTTPS-only, после конфигурации
    # basePath любой URL без него возвращает 404 — `grep -q 200` всегда
    # будет false. Слушающий порт — надёжный сигнал, что бинарник стартовал
    # и создал sqlite-БД, в которую мы дальше пишем настройки.
    wait_for "h-ui порт ${HUI_PORT}" 15 "ss -tlnp | grep -q ':${HUI_PORT} '" \
        || warn "h-ui: порт ${HUI_PORT} не слушает (проверь: journalctl -u h-ui)"

    # Настроить HTTPS (использует сертификат от 3x-ui)
    sqlite3 /usr/local/h-ui/data/h_ui.db \
        "UPDATE config SET value='/root/3x-ui/cert/cert.pem' WHERE key='H_UI_CRT_PATH';"
    sqlite3 /usr/local/h-ui/data/h_ui.db \
        "UPDATE config SET value='/root/3x-ui/cert/private.key' WHERE key='H_UI_KEY_PATH';"

    # basePath — скрывает панель за случайным URL (без него — 404)
    python3 -c "
import sqlite3
conn = sqlite3.connect('/usr/local/h-ui/data/h_ui.db')
conn.execute('UPDATE config SET value=? WHERE key=?', ('${HUI_BASE_PATH}', 'H_UI_WEB_CONTEXT'))
conn.commit()
conn.close()
"

    # Настроить Hysteria2 конфиг
    local JWT_SECRET
    JWT_SECRET=$(sqlite3 /usr/local/h-ui/data/h_ui.db "SELECT value FROM config WHERE key='JWT_SECRET';")

    python3 -c "
import sqlite3, hashlib
conn = sqlite3.connect('/usr/local/h-ui/data/h_ui.db')

# Hysteria2 server config (YAML stored as string).
# obfs.salamander обязателен — без него ru-DPI режет QUIC до auth.
config = '''listen: \":443\"
obfs:
  type: salamander
  salamander:
    password: ${HY2_OBFS_PASS}
tls:
  cert: /root/3x-ui/cert/cert.pem
  key: /root/3x-ui/cert/private.key
auth:
  type: http
  http:
    url: https://127.0.0.1:${HUI_PORT}${HUI_BASE_PATH}/hui/hysteria2/auth
    insecure: true
trafficStats:
  listen: \":7653\"
  secret: ${JWT_SECRET}
masquerade:
  type: proxy
  proxy:
    url: ${HY2_MASQUERADE_URL}
    rewriteHost: true'''
conn.execute('UPDATE config SET value=? WHERE key=?', (config, 'HYSTERIA2_CONFIG'))
conn.execute('UPDATE config SET value=? WHERE key=?', ('1', 'HYSTERIA2_ENABLE'))

# Add user accounts (con_pass = username.password, pass = SHA-224 hash).
# Идемпотентность: чистим существующих под этими же username перед INSERT,
# чтобы повторный запуск скрипта не плодил дубликаты в account.
conn.execute('DELETE FROM account WHERE username IN (?, ?)',
             ('${HY2_USER1}', '${HY2_USER2}'))
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
    info "Шаг 11/12: MTProto proxy для Telegram (993/TCP)"
    # Нюансы:
    #   - mtg v2 требует TOML-конфиг (секрет нельзя передать аргументом)
    #   - Обязательно --network host (Docker NAT ломает MTProto-хендшейк)
    #   - domain-fronting-port = 443 обязателен

    mkdir -p /etc/mtg
    MTG_SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret google.com 2>/dev/null)
    # Если pull/run упал (хостер блокирует Docker Hub, образ снят, и т.п.) —
    # MTG_SECRET будет пустой, mtg запустится с `secret = ""` и молча упадёт.
    # Лучше fail-fast здесь.
    [[ -n "${MTG_SECRET}" ]] || fail "mtg: generate-secret вернул пусто (docker pull / run упал?)"

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

# ===================== ШАГ 12: AnyTLS (sing-box) =============================
# AnyTLS — экспериментальный канал на случай отвала Reality. Поверх обычного
# TLS, но с padding/multiplexing → ломает ML-классификаторы packet patterns,
# которые палят Trojan/VLESS-TLS. Не интегрирован в 3x-ui (отдельный демон),
# управление пользователями = редактирование /etc/sing-box/config.json + restart.
# Stealth по cert-fingerprint = такой же как Trojan-TLS на 8443 (общий cert).
# Преимущество — над Trojan-TLS на пассивном NGFW-анализе (App-ID нет в базах).
step12_anytls() {
    info "Шаг 12/12: AnyTLS через sing-box (порт ${ANYTLS_PORT}/TCP)"

    # Авто-генерация паролей если в верхней секции пусто
    [[ -z "${ANYTLS_PASS1}" ]] && ANYTLS_PASS1=$(openssl rand 16 | base64 | tr -d '=' | tr '+/' '-_')
    [[ -z "${ANYTLS_PASS2}" ]] && ANYTLS_PASS2=$(openssl rand 16 | base64 | tr -d '=' | tr '+/' '-_')
    [[ -z "${ANYTLS_PASS3}" ]] && ANYTLS_PASS3=$(openssl rand 16 | base64 | tr -d '=' | tr '+/' '-_')

    # Скачать sing-box (один статический бинарник, ~24MB)
    mkdir -p /usr/local/sing-box /etc/sing-box
    local URL="https://github.com/SagerNet/sing-box/releases/download/v${ANYTLS_VERSION}/sing-box-${ANYTLS_VERSION}-linux-amd64.tar.gz"
    if ! curl -fsSL --max-time 60 -o /tmp/sing-box.tar.gz "${URL}"; then
        warn "sing-box ${ANYTLS_VERSION} не скачался — шаг пропущен"
        return 0
    fi
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/
    cp "/tmp/sing-box-${ANYTLS_VERSION}-linux-amd64/sing-box" /usr/local/sing-box/
    chmod +x /usr/local/sing-box/sing-box
    rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${ANYTLS_VERSION}-linux-amd64"

    # JSON-конфиг с anytls inbound + 3 пользователями. Cert общий с панелью —
    # тот же `/root/3x-ui/cert/cert.pem` (CN=IP, self-signed). Это значит, что
    # пассивные сканеры (Censys/Shodan) пометят 8444 self-signed так же, как
    # 8443 / 8880. Реальный stealth-выигрыш AnyTLS — на packet-pattern уровне.
    cat > /etc/sing-box/config.json << EOF
{
  "log": {"level": "warn", "timestamp": true},
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": ${ANYTLS_PORT},
      "users": [
        {"name": "${ANYTLS_USER1}", "password": "${ANYTLS_PASS1}"},
        {"name": "${ANYTLS_USER2}", "password": "${ANYTLS_PASS2}"},
        {"name": "${ANYTLS_USER3}", "password": "${ANYTLS_PASS3}"}
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "/root/3x-ui/cert/cert.pem",
        "key_path": "/root/3x-ui/cert/private.key"
      }
    }
  ],
  "outbounds": [
    {"type": "direct", "tag": "direct"}
  ]
}
EOF
    chmod 600 /etc/sing-box/config.json

    # Sanity-check конфига до старта — иначе systemd ловит loop рестартов
    /usr/local/sing-box/sing-box check -c /etc/sing-box/config.json \
        || fail "sing-box config invalid"

    cat > /etc/systemd/system/sing-box.service << 'UEOF'
[Unit]
Description=sing-box (AnyTLS server)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sing-box/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UEOF
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box

    wait_for "AnyTLS порт ${ANYTLS_PORT}" 15 "ss -tlnp | grep -q ':${ANYTLS_PORT} '" \
        || warn "AnyTLS: порт ${ANYTLS_PORT} не слушает (проверь: journalctl -u sing-box)"

    ok "AnyTLS (sing-box) запущен на ${ANYTLS_PORT}/tcp"
}

# ===================== EGRESS CHECK =========================================
# Reality маскировка работает корректно только если target доступен с сервера:
# при active probing DPI ходит через нас на target, и должен получить настоящий
# handshake. Если хостер режет egress к target — клиенты могут работать,
# но маскировка ослаблена. Проверяем и предупреждаем.
# Считаем target реально достижимым только если был настоящий TLS handshake:
# code != 000 (curl что-то получил) И time_appconnect > 0 (TLS реально закрылся).
# curl с дефолтной верификацией отбракует MITM с невалидным сертом — там
# time_appconnect остаётся 0. Прозрачные интерсепты с валидным сертом для
# чужого домена в природе у дешёвых VPS-хостеров не встречаются.
_tls_probe() {
    # echo "<code> <appconnect>\n" или "000 0"
    # Trailing \n обязателен: curl -w его не добавляет, и без него
    # `read` ловит EOF до перевода строки и возвращает rc=1 — под
    # `set -e` это валит весь скрипт.
    local url="$1" timeout="${2:-6}"
    curl -s4 --max-time "$timeout" -o /dev/null \
        -w '%{http_code} %{time_appconnect}\n' "$url" 2>/dev/null \
        || echo '000 0'
}

egress_check() {
    info "Проверка egress: достижим ли Reality target и Hy2 masquerade с сервера"

    local TARGET_HOST="${REALITY_SNI}"
    local CODE T
    read -r CODE T < <(_tls_probe "https://${TARGET_HOST}/")
    if [[ "$CODE" == "000" || "$T" == "0,000000" || "$T" == "0.000000" || "$T" == "0" ]]; then
        warn "Reality target ${TARGET_HOST} НЕ доступен с сервера (нет TLS handshake: code=${CODE} appconnect=${T}s)."
        warn "Хостер режет egress / MITM-ит этот домен. Маскировка сломана — смени REALITY_SNI или хостера."
    else
        ok "Reality target ${TARGET_HOST} доступен (code=${CODE}, TLS handshake ${T}s)"
    fi

    local MASQ_HOST; MASQ_HOST=$(echo "${HY2_MASQUERADE_URL}" | awk -F/ '{print $3}')
    read -r CODE T < <(_tls_probe "https://${MASQ_HOST}/")
    if [[ "$CODE" == "000" || "$T" == "0,000000" || "$T" == "0.000000" || "$T" == "0" ]]; then
        warn "Hy2 masquerade ${MASQ_HOST} НЕ доступен с сервера (нет TLS handshake: code=${CODE} appconnect=${T}s)"
    else
        ok "Hy2 masquerade ${MASQ_HOST} доступен (code=${CODE}, TLS handshake ${T}s)"
    fi

    # IPv6 — только sanity-чек "роутится ли v6", без требований к TLS
    local V6
    V6=$(curl -s6 --max-time 4 -o /dev/null -w '%{http_code}' "https://www.google.com/" 2>/dev/null || echo 000)
    if [[ "$V6" == "000" ]]; then
        warn "IPv6 egress битый — DNS UseIPv4 уже включён, защита есть"
    else
        ok "IPv6 egress работает (google v6 -> ${V6})"
    fi
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
    echo "  Панель: https://${SERVER_IP}:${HUI_PORT}${HUI_BASE_PATH}"
    echo "  Логин:  sysadmin / sysadmin  (сменить после первого входа!)"
    echo "  URI ${HY2_USER1}: hysteria2://${HY2_USER1}.${HY2_PASS1}@${SERVER_IP}:443/?obfs=salamander&obfs-password=${HY2_OBFS_PASS}&insecure=1#hy2-${HY2_USER1}"
    echo "  URI ${HY2_USER2}: hysteria2://${HY2_USER2}.${HY2_PASS2}@${SERVER_IP}:443/?obfs=salamander&obfs-password=${HY2_OBFS_PASS}&insecure=1#hy2-${HY2_USER2}"
    echo ""

    echo -e "${BOLD}── MTProto (Telegram) ───────────────────────────────────────${NC}"
    echo "  https://t.me/proxy?server=${SERVER_IP}&port=993&secret=${MTG_SECRET}"
    echo ""

    # AnyTLS: пароли base64-style могут начинаться с '-' — в URI требуют
    # percent-encoding (-→%2D). Раздаём «как есть»: если у клиентов будут
    # проблемы с парсингом — пусть руками подставят %2D.
    echo -e "${BOLD}── AnyTLS (sing-box) ────────────────────────────────────────${NC}"
    echo "  Сервис:  systemctl status sing-box  /  config: /etc/sing-box/config.json"
    echo "  URI ${ANYTLS_USER1}: anytls://${ANYTLS_PASS1}@${SERVER_IP}:${ANYTLS_PORT}/?sni=${SERVER_IP}&insecure=1"
    echo "  URI ${ANYTLS_USER2}: anytls://${ANYTLS_PASS2}@${SERVER_IP}:${ANYTLS_PORT}/?sni=${SERVER_IP}&insecure=1"
    echo "  URI ${ANYTLS_USER3}: anytls://${ANYTLS_PASS3}@${SERVER_IP}:${ANYTLS_PORT}/?sni=${SERVER_IP}&insecure=1"
    echo ""

    echo -e "${BOLD}── Сервисы ──────────────────────────────────────────────────${NC}"
    docker ps --format "  {{.Names}}: {{.Status}}"
    echo ""

    echo -e "${BOLD}── Порты ────────────────────────────────────────────────────${NC}"
    ss -tlnp | grep -E ":(${SSH_PORT}|${PANEL_PORT}|${HUI_PORT}|443|2083|2087|8443|8880|993) " \
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
PANEL=https://${SERVER_IP}:${HUI_PORT}${HUI_BASE_PATH}
PANEL_USER=sysadmin
PANEL_PASS=sysadmin
URI_${HY2_USER1}=hysteria2://${HY2_USER1}.${HY2_PASS1}@${SERVER_IP}:443/?obfs=salamander&obfs-password=${HY2_OBFS_PASS}&insecure=1#hy2-${HY2_USER1}
URI_${HY2_USER2}=hysteria2://${HY2_USER2}.${HY2_PASS2}@${SERVER_IP}:443/?obfs=salamander&obfs-password=${HY2_OBFS_PASS}&insecure=1#hy2-${HY2_USER2}

[MTProto]
LINK=https://t.me/proxy?server=${SERVER_IP}&port=993&secret=${MTG_SECRET}

[AnyTLS]
SERVER=${SERVER_IP}:${ANYTLS_PORT}
USER_${ANYTLS_USER1}=${ANYTLS_PASS1}
USER_${ANYTLS_USER2}=${ANYTLS_PASS2}
USER_${ANYTLS_USER3}=${ANYTLS_PASS3}
URI_${ANYTLS_USER1}=anytls://${ANYTLS_PASS1}@${SERVER_IP}:${ANYTLS_PORT}/?sni=${SERVER_IP}&insecure=1
URI_${ANYTLS_USER2}=anytls://${ANYTLS_PASS2}@${SERVER_IP}:${ANYTLS_PORT}/?sni=${SERVER_IP}&insecure=1
URI_${ANYTLS_USER3}=anytls://${ANYTLS_PASS3}@${SERVER_IP}:${ANYTLS_PORT}/?sni=${SERVER_IP}&insecure=1
EOF
    # Файл с паролями всех сервисов — никто кроме root не должен читать.
    chmod 600 /root/vpn_credentials.txt

    echo -e "  Сводка сохранена в: ${CYAN}/root/vpn_credentials.txt${NC}"
    echo ""
}

# ===================== MAIN =================================================

main() {
    check_root
    step1_system
    step1b_swap
    step2_bbr
    step3_autoupdate
    step4_ssh
    step5_ufw
    step5b_scanner_blocklist
    step6_fail2ban
    step7_docker_xui
    step8_xui_config
    step9a_xray_upgrade
    step9b_inbounds
    step9c_xray_template
    step10_hysteria2
    step11_mtproto
    step12_anytls
    egress_check
    print_summary
}

main
