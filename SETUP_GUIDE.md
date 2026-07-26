# VPN-сервер: Полный гайд по развертыванию

**3x-ui + Xray + Hysteria2 на Ubuntu 24.04 VPS**

Время развертывания: ~15-20 минут
Требования: VPS с Ubuntu 24.04, 1 vCPU, 2 GB RAM, 20 GB SSD

### Автоматический деплой (setup.sh)

Для автоматической настройки можно использовать скрипт `setup.sh`:

```bash
# На свежем VPS с Ubuntu 24.04:
curl -O https://raw.githubusercontent.com/<REPO>/setup.sh
bash setup.sh
```

Скрипт выполнит все шаги ниже автоматически и выведет данные доступа.

**После запуска** (`<IP>` = ip сервера, под который мы делаем deploy):
1. Скопировать приватный SSH-ключ из вывода скрипта → сохранить в `creds/<IP>/server_key`
2. Скопировать все credentials из вывода (или с сервера из `/root/vpn_credentials.txt`) в `creds/<IP>/credentials.txt`
3. Установить права на ключ:

```bash
# Linux / macOS:
chmod 600 creds/<IP>/server_key

# Windows (PowerShell):
icacls "creds\<IP>\server_key" /inheritance:r /grant:r "$env:USERNAME:(R)"
```

> Каждый сервер живёт в своей подпапке `creds/<IP>/`. `deploy_phase1.py` создаёт эту структуру автоматически.

### Требования для управления с ПК (paramiko)

Если нужно запускать команды на сервере удалённо из Python (например, для автоматизации):

- **Python** 3.10+
- **pip install paramiko** — SSH-клиент для Python

```bash
pip install paramiko
```

---

## ТЕКУЩИЕ ПРОТОКОЛЫ

1. **VLESS + Vision + Reality** — порт 443/TCP (через 3x-ui/Xray)
2. **VLESS + Vision + Reality** — порт 2083/TCP (резервный нестандартный порт)
3. **Trojan + Reality** — порт 2087/TCP (через 3x-ui/Xray)
4. **Hysteria2 (QUIC + Salamander)** — порт 443/UDP (h-ui панель + systemd)
5. **MTProto proxy (Telegram)** — порт 993/TCP (mtg v2, отдельный Docker-контейнер)

Reality dest/SNI: `www.yandex.ru` (российский домен → DPI-нейтрально, target доступен с большинства VPS).

**Не работают на современной DPI-сети (исключены из проекта):**
- Self-signed TLS на любых портах (8443/8880/4443) — DPI палит самоподписной сертификат
- VMess (любой транспорт) — детектируется по fingerprint
- Shadowsocks (legacy и 2022) — детектируется DPI

### ⚠️ Pre-deploy sanity-check (обязательно)

Перед `setup.sh`/`deploy_phase1.py` запустите готовый скрипт:

```bash
python deploy_precheck.py
```

Он за ~30 секунд проверит:
- **IP/AS/OS** — что за хостер, страна, версия Ubuntu
- **IPv6 egress** — работает ли v6 (битый v6 у части хостеров заставляет Xray тратить секунды на fallback)
- **Reality target кандидаты** — `www.yandex.ru`, `www.microsoft.com`, `www.bing.com`, `cloudflare.com`, `icloud.com`
- **Ru-домены** — реально ли через VPN откроются vk/mail/ok/yandex/sber/wb/ozon и пр. (если хостер режет — клиенты будут жаловаться)
- **Скорость канала** — Cloudflare 30-секундная sustained-загрузка, в Mbit/s
- **GitHub release CDN** — нужен для шага 9a (manual Xray upgrade)

Если в выводе **fatal**: хостер не годится, не запускай deploy — потеряешь 15 минут зря. Меняй VPS.

### Egress-фильтры хостеров (контекст)

Reality маскировка работает только если **target доступен с сервера**. Активный пробинг DPI ходит через нас на target и должен получить настоящий handshake. Часть хостеров (особенно дешёвые европейские, AS56971 «Cloud56971» особенно) режут TCP/443 к российским доменам (vk.ru, mail.ru, ok.ru, dzen.ru), к части CDN (Akamai, Fastly, Azure Blob — куда указывает release-assets.githubusercontent.com), и/или у них битый IPv6.

Если `www.yandex.ru` недоступен — варианты:
- Подобрать SNI среди работающих доменов из вывода precheck
- Сменить хостер: AEZA, Hetzner, FirstByte/FirstVDS, Timeweb обычно с чистым egress

В финале `setup.sh` запускает `egress_check`, который выводит warning при недоступности target/masquerade.

**Клиентские приложения:**
- Телефон: v2rayNG (Android) — https://github.com/2dust/v2rayNG
- ПК: v2rayN (Windows) — https://github.com/2dust/v2rayN

> **Примечание:** v2RayTun НЕ поддерживает Hysteria2

---

## ШАГИ

### 1. Подключиться к серверу и обновить систему

```bash
ssh root@<IP>

apt update && apt upgrade -y
apt install -y ufw fail2ban openssl sqlite3 unattended-upgrades apt-listchanges
```

---

### 2. Настроить BBR (ускорение TCP)

```bash
cat > /etc/sysctl.d/99-bbr.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

sysctl -p /etc/sysctl.d/99-bbr.conf
```

**Проверка:**

```bash
sysctl net.ipv4.tcp_congestion_control
# Должно быть: bbr
```

---

### 3. Настроить автообновления

```bash
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
```

---

### 3b. Настроить ротацию логов (logrotate + journald)

⚠️ **Облачные образы Ubuntu 24.04 часто идут БЕЗ пакета `logrotate`.** При этом конфиги `/etc/logrotate.d/rsyslog` и `/etc/logrotate.d/ufw` на месте — их кладут сами пакеты `rsyslog` и `ufw`. Выглядит как «ротация настроена», но исполнять их некому: ни бинарника, ни `logrotate.timer` в системе нет, и логи растут бесконечно.

Порядок величин — за ~80 дней аптайма в `/var/log` набегает около 765 MB:

| Файл | Размер |
|------|--------|
| journal | ~410 MB |
| syslog | ~170 MB |
| kern.log | ~90 MB |
| ufw.log | ~80 MB |

Основной поставщик строк — `UFW BLOCK` от сканеров, которые долбятся круглосуточно; journal дублирует то же самое третьим экземпляром.

```bash
# Проверить, есть ли logrotate вообще
which logrotate || echo "НЕ УСТАНОВЛЕН"
systemctl list-timers logrotate.timer   # "0 timers listed" = юнита нет

# Установить
apt install -y logrotate

# Ротация rsyslog-логов: каждый день, хранить 30 дней
cat > /etc/logrotate.d/rsyslog << 'EOF'
/var/log/syslog
/var/log/mail.log
/var/log/kern.log
/var/log/auth.log
/var/log/user.log
/var/log/cron.log
{
	daily
	rotate 30
	maxage 30
	missingok
	notifempty
	compress
	delaycompress
	sharedscripts
	postrotate
		/usr/lib/rsyslog/rsyslog-rotate
	endscript
}
EOF

# Ротация ufw.log — самый быстрорастущий лог на VPN-сервере
cat > /etc/logrotate.d/ufw << 'EOF'
/var/log/ufw.log
{
	daily
	rotate 30
	maxage 30
	missingok
	notifempty
	compress
	delaycompress
	sharedscripts
	postrotate
		[ -x /usr/lib/rsyslog/rsyslog-rotate ] && /usr/lib/rsyslog/rsyslog-rotate || true
	endscript
}
EOF

# journald управляется отдельно — logrotate его не трогает
sed -i '/^\s*#\?\s*\(MaxRetentionSec\|SystemMaxUse\|SystemMaxFileSize\)=/d' /etc/systemd/journald.conf
cat >> /etc/systemd/journald.conf << 'EOF'
MaxRetentionSec=1month
SystemMaxUse=300M
SystemMaxFileSize=50M
EOF
systemctl restart systemd-journald

# Включить таймер (ежедневно в 00:00) и сделать первый прогон
systemctl enable --now logrotate.timer
logrotate /etc/logrotate.conf
```

**Почему именно так:**
- `maxage 30` режет по **возрасту** файла, `rotate 30` — по количеству. Нужны оба: без `maxage` редко пишущий лог переживёт срок хранения.
- journald **не управляется** logrotate, у него свои лимиты. Дефолт `SystemMaxUse` — 10% раздела (на типовом VPS-диске 20 GB это около 2 GB), поэтому journal разрастается молча.

**Проверка:**
```bash
systemctl is-enabled logrotate.timer          # enabled
systemctl list-timers logrotate.timer         # NEXT: завтра 00:00
logrotate -d /etc/logrotate.conf 2>&1 | grep -i error   # пусто = синтаксис ок
journalctl --disk-usage                       # должно быть в пределах 300M

# Убедиться, что после рестарта journald логи всё ещё пишутся в оба места
logger -t test "проверка"
tail -1 /var/log/syslog && journalctl -t test -n1
```

**Разовая чистка, если логи уже разрослись:**
```bash
journalctl --vacuum-time=1month               # или --vacuum-size=200M
# Усечь текущие файлы, сохранив последние строки (inode не меняется —
# rsyslog не теряет дескриптор):
for f in /var/log/syslog /var/log/kern.log /var/log/ufw.log; do
    tail -n 20000 "$f" > /tmp/.lt && cat /tmp/.lt > "$f" && rm -f /tmp/.lt
done
systemctl kill -s HUP rsyslog
```

Стабильный размер `/var/log` после настройки — порядка 200 MB.

---

### 4. Настроить SSH (порт + ключ + hardening)

```bash
# Сгенерить SSH-ключ
mkdir -p /root/.ssh && chmod 700 /root/.ssh
ssh-keygen -t ed25519 -f /root/.ssh/id_admin -N '' -C 'admin-key'
cat /root/.ssh/id_admin.pub >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

> **ВНИМАНИЕ:** Сохранить приватный ключ к себе на локальную машину!

```bash
cat /root/.ssh/id_admin
# Скопировать содержимое в файл admin_key на своем компе
```

```bash
# Настроить sshd_config
sed -i 's/^#*Port .*/Port 59222/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config

# Отключить ssh.socket (Ubuntu 24.04)
# ВАЖНО: socket activation может молча дропать соединения после DoS-атак.
# sshd должен слушать порт напрямую через ssh.service.
systemctl stop ssh.socket 2>/dev/null || true
systemctl disable ssh.socket 2>/dev/null || true
rm -rf /etc/systemd/system/ssh.socket.d

# Применить
mkdir -p /run/sshd   # нужен для sshd -t на Ubuntu 24.04
sshd -t && echo "OK"
systemctl daemon-reload
systemctl enable ssh.service
systemctl restart ssh.service
```

**Проверка:**

```bash
ss -tlnp | grep sshd
# Должно показать 0.0.0.0:59222 и [::]:59222
```

---

### 5. Настроить UFW (файрвол)

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow 59222/tcp comment 'SSH'
ufw allow 2053/tcp  comment '3x-ui panel'
ufw allow 443/tcp   comment 'VLESS Reality (yandex)'
ufw allow 443/udp   comment 'Hysteria2 QUIC+Salamander'
ufw allow 7391/tcp  comment 'h-ui panel (Hysteria2)'
ufw allow 2083/tcp  comment 'VLESS Reality (yandex)'
ufw allow 2087/tcp  comment 'Trojan Reality (yandex)'
ufw allow 8443/tcp  comment 'Trojan TLS self-signed (резерв)'
ufw allow 8880/tcp  comment 'VLESS TLS self-signed (резерв)'
ufw allow 8444/tcp  comment 'AnyTLS (sing-box)'
ufw allow 993/tcp   comment 'MTProto proxy (Telegram)'
echo 'y' | ufw enable
```

**Блок публичных сканеров (Censys/Shodan и т.п.):** их fingerprint-БД используется DPI для пометки VPN-серверов. `insert 1` — чтобы deny срабатывал ПЕРЕД allow:

```bash
# Censys.io (/24 corporate)
for r in 162.142.125.0/24 167.94.138.0/24 167.94.145.0/24 167.94.146.0/24 \
         167.248.133.0/24 199.45.154.0/24 199.45.155.0/24 206.168.34.0/24; do
    ufw insert 1 deny from "$r" comment 'Censys/Shodan blocklist'
done

# Shodan corporate /24
for r in 198.20.69.0/24 198.20.70.0/24 198.20.99.0/24 \
         208.180.20.0/24 209.126.110.0/24 \
         66.240.192.0/24 66.240.236.0/24; do
    ufw insert 1 deny from "$r" comment 'Censys/Shodan blocklist'
done

# Shodan distributed scanners (на shared-провайдерах; Shodan ротирует — сверяться раз в полгода)
for r in 71.6.135.131 71.6.146.130 71.6.146.185 71.6.158.166 71.6.165.200 71.6.167.142 \
         80.82.77.33 80.82.77.139 82.221.105.6 82.221.105.7 \
         85.25.43.94 85.25.103.50 88.198.36.144 88.198.59.10 93.120.27.62; do
    ufw insert 1 deny from "$r" comment 'Censys/Shodan blocklist'
done
```

**Проверка:**

```bash
ufw status verbose
```

---

### 6. Настроить fail2ban

```bash
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
banaction = ufw
backend = systemd

[sshd]
enabled = true
port = 59222
filter = sshd
maxretry = 3
bantime = 7200

[sshd-preauth]
enabled = true
port = 59222
filter = sshd
mode = aggressive
maxretry = 5
findtime = 60
bantime = 3600
EOF

systemctl enable fail2ban
systemctl restart fail2ban
```

> **sshd-preauth** — защита от connection flood (DoS). Режим `aggressive` ловит `Connection closed [preauth]`, которые стандартный jail пропускает.

**Проверка:**

```bash
fail2ban-client status sshd
```

---

### 7. Установить Docker и 3x-ui

```bash
# Docker (если не установлен)
curl -fsSL https://get.docker.com | sh

# Создать структуру
mkdir -p /root/3x-ui/{db,cert}
cd /root/3x-ui

# Сгенерить самоподписной TLS-сертификат
openssl req -x509 -newkey rsa:2048 \
  -keyout /root/3x-ui/cert/private.key \
  -out /root/3x-ui/cert/cert.pem \
  -days 3650 -nodes \
  -subj "/C=FR/ST=Paris/L=Paris/O=Self/CN=<IP_СЕРВЕРА>"
chmod 600 /root/3x-ui/cert/private.key
```

**docker-compose.yml:**

```yaml
---
version: "3"

services:
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:2.9.4
    container_name: 3x-ui
    hostname: yourhostname
    volumes:
      - $PWD/db/:/etc/x-ui/
      - $PWD/cert/:/root/cert/
    environment:
      XRAY_VMESS_AEAD_FORCED: "false"
      X_UI_ENABLE_FAIL2BAN: "true"
    tty: true
    network_mode: host
    restart: unless-stopped
```

```bash
# Запустить
docker compose up -d

# Подождать запуска
sleep 10
```

---

### 8. Настроить 3x-ui (HTTPS, пароль, basePath)

```bash
# Поставить пароль
docker exec 3x-ui ./x-ui setting -username admin -password <НОВЫЙ_ПАРОЛЬ>

# Настроить TLS и basePath через БД
# (CLI-команды 3x-ui не всегда работают, БД надежнее)
sqlite3 /root/3x-ui/db/x-ui.db "INSERT OR REPLACE INTO settings(key,value) VALUES('webCertFile','/root/cert/cert.pem');"
sqlite3 /root/3x-ui/db/x-ui.db "INSERT OR REPLACE INTO settings(key,value) VALUES('webKeyFile','/root/cert/private.key');"
sqlite3 /root/3x-ui/db/x-ui.db "INSERT OR REPLACE INTO settings(key,value) VALUES('webBasePath','/$(openssl rand -hex 8)/');"

# Перезапустить
docker restart 3x-ui
sleep 5
```

**Проверить:**

```bash
docker logs 3x-ui --tail 5
# Должно быть: "Web server running HTTPS on [::]:2053"
```

**Узнать basePath:**

```bash
sqlite3 /root/3x-ui/db/x-ui.db "SELECT value FROM settings WHERE key='webBasePath';"
```

Панель доступна по адресу: `https://<IP>:2053/<basePath>/`

---

### 9. Обновить Xray-ядро и создать Reality inbound'ы

#### 9a. Замена Xray-бинарника на свежий (опционально)

⚠️ **Начиная с 3x-ui 2.9.x этот шаг обычно НЕ нужен** — Xray внутри образа свежее того, что подкладывали руками (образ 2.9.4 идёт с Xray 26.4.25). Шаг оставлен на случай, когда нужно зафиксировать конкретную версию ядра или откатиться на старую. Если версия из образа устраивает — сразу к 9b.

Подмена бинарника:

```bash
XRAY_VER="26.3.27"
curl -fsSL -o /tmp/xray.zip \
  "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-64.zip"
python3 -m zipfile -e /tmp/xray.zip /tmp/xray-new/
chmod +x /tmp/xray-new/xray
docker cp 3x-ui:/app/bin/xray-linux-amd64 /root/3x-ui/xray-linux-amd64.old   # бэкап
docker cp /tmp/xray-new/xray 3x-ui:/app/bin/xray-linux-amd64
docker exec 3x-ui chmod +x /app/bin/xray-linux-amd64
docker exec 3x-ui /app/bin/xray-linux-amd64 -version
# Должно: Xray 26.3.27
```

Если хостер режет egress к `release-assets.githubusercontent.com` (TLS handshake timeout) — скачать zip локально и закинуть на сервер через `scp`.

#### 9b. Reality inbound'ы (3 штуки)

Все три — на одном SNI=`www.yandex.ru`, каждый со своей парой ключей X25519 (генерируется через `xray x25519` внутри контейнера) и одним рандомным shortID.

```bash
BASE="https://127.0.0.1:2053/<basePath>"
curl -sk -c /tmp/c.txt -X POST "$BASE/login" \
  -d 'username=admin&password=<ПАРОЛЬ>'

add_reality() {
    local PORT="$1" PROTO="$2" REMARK="$3"
    local KEYS PRIV PUB SID SETTINGS STREAM
    KEYS=$(docker exec 3x-ui /app/bin/xray-linux-amd64 x25519)
    PRIV=$(echo "$KEYS" | awk -F': ' '/Private key/ {print $2}')
    PUB=$(echo  "$KEYS" | awk -F': ' '/Public key/  {print $2}')
    SID=$(openssl rand -hex 8)
    if [[ "$PROTO" == "vless" ]]; then
        SETTINGS='{"clients":[],"decryption":"none","fallbacks":[]}'
    else
        SETTINGS='{"clients":[],"fallbacks":[]}'
    fi
    STREAM='{"network":"tcp","security":"reality","externalProxy":[],"realitySettings":{"show":false,"xver":0,"target":"www.yandex.ru:443","serverNames":["www.yandex.ru"],"privateKey":"'"$PRIV"'","shortIds":["'"$SID"'",""],"settings":{"publicKey":"'"$PUB"'","fingerprint":"chrome","serverName":"","spiderX":"/"}},"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}'
    curl -sk -b /tmp/c.txt -X POST "$BASE/panel/api/inbounds/add" \
      --data-urlencode "remark=$REMARK" --data-urlencode 'enable=true' \
      --data-urlencode "port=$PORT" --data-urlencode "protocol=$PROTO" \
      --data-urlencode "settings=$SETTINGS" --data-urlencode "streamSettings=$STREAM" \
      --data-urlencode 'sniffing={"enabled":true,"destOverride":["http","tls","quic","fakedns"]}' \
      --data-urlencode 'up=0' --data-urlencode 'down=0' \
      --data-urlencode 'total=0' --data-urlencode 'expiryTime=0' --data-urlencode 'listen='
}
add_reality 443  vless  vless-reality-443
add_reality 2083 vless  vless-reality-2083
add_reality 2087 trojan trojan-reality-2087
```

#### 9c. Xray template — DNS UseIPv4 (защита от битого IPv6 хостера)

У части хостеров AAAA-резолвинг отдаёт IPv6, который не маршрутизируется → Xray тратит секунды на v6-fallback при каждом запросе. Форсим IPv4:

```bash
docker exec 3x-ui sh -c 'cat /app/bin/config.json' | python3 -c '
import json, sys
c = json.load(sys.stdin)
c.pop("inbounds", None)
c["dns"] = {
    "servers": ["1.1.1.1", "8.8.8.8", "https://1.1.1.1/dns-query"],
    "queryStrategy": "UseIPv4"
}
for ob in c.get("outbounds", []):
    if ob.get("protocol") == "freedom":
        ob.setdefault("settings", {})["domainStrategy"] = "UseIPv4"
print(json.dumps(c, indent=2, ensure_ascii=False))
' > /tmp/xray_template.json

sqlite3 /root/3x-ui/db/x-ui.db \
  "INSERT OR REPLACE INTO settings(key,value) VALUES('xrayTemplateConfig', readfile('/tmp/xray_template.json'));"
docker restart 3x-ui
```

3x-ui перегенерирует `bin/config.json`, подмешивая шаблон + inbound'ы из БД.

---

### 10. Установить Hysteria2 (h-ui панель)

h-ui — веб-панель для управления Hysteria2 с UI для пользователей, трафика и подписок.

```bash
# Скачать h-ui
mkdir -p /usr/local/h-ui/
curl -fsSL https://github.com/jonssonyan/h-ui/releases/latest/download/h-ui-linux-amd64 \
  -o /usr/local/h-ui/h-ui
chmod +x /usr/local/h-ui/h-ui

# Скачать systemd unit и установить порт
curl -fsSL https://raw.githubusercontent.com/jonssonyan/h-ui/main/h-ui.service \
  -o /etc/systemd/system/h-ui.service
sed -i 's|ExecStart=/usr/local/h-ui/h-ui|ExecStart=/usr/local/h-ui/h-ui -p 7391|' \
  /etc/systemd/system/h-ui.service

# Запустить
systemctl daemon-reload && systemctl enable h-ui && systemctl restart h-ui
sleep 3
```

**Настроить HTTPS для панели (через SQLite):**

```bash
# Включить HTTPS (использует тот же сертификат что и 3x-ui)
sqlite3 /usr/local/h-ui/data/h_ui.db \
  "UPDATE config SET value='/root/3x-ui/cert/cert.pem' WHERE key='H_UI_CRT_PATH';"
sqlite3 /usr/local/h-ui/data/h_ui.db \
  "UPDATE config SET value='/root/3x-ui/cert/private.key' WHERE key='H_UI_KEY_PATH';"
```

**Установить basePath (скрывает панель за случайным URL):**

```bash
# Сгенерировать случайный basePath
HUI_BASE_PATH="/$(openssl rand -hex 6)"

python3 -c "
import sqlite3
conn = sqlite3.connect('/usr/local/h-ui/data/h_ui.db')
conn.execute('UPDATE config SET value=\"${HUI_BASE_PATH}\" WHERE key=\"H_UI_WEB_CONTEXT\"')
conn.commit()
conn.close()
"
```

> **ВАЖНО:** после установки basePath, auth URL для Hysteria2 тоже должен включать basePath

**Настроить Hysteria2 через SQLite:**

```bash
JWT_SECRET=$(sqlite3 /usr/local/h-ui/data/h_ui.db "SELECT value FROM config WHERE key='JWT_SECRET';")

python3 -c "
import sqlite3
config = '''listen: \":443\"
tls:
  cert: /root/3x-ui/cert/cert.pem
  key: /root/3x-ui/cert/private.key
auth:
  type: http
  http:
    url: https://127.0.0.1:7391${HUI_BASE_PATH}/hui/hysteria2/auth
    insecure: true
trafficStats:
  listen: \":7653\"
  secret: ${JWT_SECRET}
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true'''
conn = sqlite3.connect('/usr/local/h-ui/data/h_ui.db')
conn.execute('UPDATE config SET value=? WHERE key=?', (config, 'HYSTERIA2_CONFIG'))
conn.execute('UPDATE config SET value=? WHERE key=?', ('1', 'HYSTERIA2_ENABLE'))
conn.commit()
conn.close()
"

# Перезапустить для применения
systemctl restart h-ui
```

**Получить/сбросить креды панели:**

```bash
systemctl stop h-ui
cd /usr/local/h-ui && ./h-ui reset
systemctl start h-ui
# Дефолт (ручная установка): sysadmin / sysadmin
```

**Проверка:**

```bash
sleep 3
curl -sk -o /dev/null -w '%{http_code}' https://localhost:7391/
# Должно быть: 200

ss -ulnp | grep :443
# Должно показать: hysteria-linux-...
```

Панель доступна по адресу: `https://<IP>:7391/<basePath>/`

> Hysteria2 использует 443/UDP (QUIC), не конфликтует с VLESS на 443/TCP
> Управление пользователями — через веб-панель h-ui (добавление, трафик, лимиты)

---

### 11. Установить MTProto-прокси для Telegram (mtg v2)

MTProto-прокси позволяет использовать Telegram без VPN-приложения — достаточно вставить ссылку прямо в Telegram. Работает на мобильных операторах; домашние провайдеры с жёсткой фильтрацией могут блокировать нестандартные порты (идеален был бы 443, но он занят xray).

#### Нюансы, которые важно знать

- **mtg v2 требует TOML-конфиг** — секрет нельзя передать аргументом командной строки
- **Обязательно `--network host`** — Docker NAT (port mapping `-p`) на практике ломает MTProto-хендшейк
- **`domain-fronting-port = 443`** — без этого mtg пытается подключиться к google.com на том же порту что клиент, а не на 443
- **Секрет в hex и base64url — одно и то же**, Telegram принимает оба формата
- **Порт 993** (IMAPS) — TLS-трафик на этом порту выглядит естественно; работает на мобильных операторах

```bash
# Создать конфиг
mkdir -p /etc/mtg

# Сгенерить секрет (каждый запуск даёт новый — сохрани!)
docker run --rm nineseconds/mtg:2 generate-secret google.com
# Пример вывода (формат): ee<32 hex-знаков, рандом><hex от google.com — 9676f6f676c652e636f6d>

# Записать конфиг (подставить свой секрет)
cat > /etc/mtg/config.toml << 'EOF'
secret = "<ТВОЙ_СЕКРЕТ>"
bind-to = "0.0.0.0:993"
domain-fronting-port = 443
EOF

# Запустить контейнер
docker run -d \
  --name mtg \
  --restart always \
  --network host \
  -v /etc/mtg/config.toml:/config.toml \
  nineseconds/mtg:2 run /config.toml
```

**Проверка:**

```bash
sleep 3
docker logs mtg 2>&1 | head -5
ss -tlnp | grep :993
# Должно быть: users:(("mtg",...))
```

**Итоговая ссылка для Telegram:**

```
https://t.me/proxy?server=<IP>&port=993&secret=<ТВОЙ_СЕКРЕТ>
```

Открыть в браузере или отправить себе в Telegram — клиент предложит добавить прокси.

> **Про порт 443:** Если нужно работать и на WiFi с жёсткой фильтрацией — можно настроить SNI-роутинг (nginx stream) или fallback в xray, чтобы mtg делил порт 443 с xray. Это усложняет конфиг, поэтому на старте не делается.

---

### 12. Добавить клиентов

**VLESS Reality и Trojan Reality** — через веб-панель 3x-ui:
- URL: `https://<IP>:2053/<basePath>/`
- Для каждого inbound нажать "+" и создать клиента
- Панель сама генерирует ссылку и QR с правильными `pbk`/`sid`/`spx` из inbound

**Важно для VLESS Reality:**
- Flow: **xtls-rprx-vision**
- Fingerprint: **chrome**
- spiderX: **/**
- SNI клиента = `www.yandex.ru` (или ваш `REALITY_SNI`)

**Важно для Trojan Reality:**
- Те же параметры (fp=chrome, spx=/, SNI=yandex.ru)
- Flow в Trojan не используется

> Для Reality `insecure`/`allowInsecure` НЕ нужен — сертификат не используется, клиент верифицирует сервер по `publicKey` (X25519). Это и есть преимущество Reality перед TLS.

**Пример конфига sing-box/Hiddify — VLESS Reality:**
```json
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-443",
      "server": "<IP>",
      "server_port": 443,
      "uuid": "<UUID>",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "www.yandex.ru",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true,
          "public_key": "<PUBLIC_KEY из панели>",
          "short_id": "<SHORT_ID из панели>"
        }
      },
      "packet_encoding": "xudp"
    }
  ]
}
```

**Пример конфига sing-box/Hiddify — Trojan Reality:**
```json
{
  "outbounds": [
    {
      "type": "trojan",
      "tag": "trojan-reality-2087",
      "server": "<IP>",
      "server_port": 2087,
      "password": "<PASSWORD>",
      "tls": {
        "enabled": true,
        "server_name": "www.yandex.ru",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true,
          "public_key": "<PUBLIC_KEY из панели>",
          "short_id": "<SHORT_ID из панели>"
        }
      }
    }
  ]
}
```

**Hysteria2** — через веб-панель h-ui:
- URL: `https://<IP>:7391`
- Добавить пользователя в разделе Accounts
- Панель генерирует ссылку автоматически (добавить `insecure=1` если самоподписной сертификат)

**Формат ссылки:**
```
hysteria2://ИмяЮзера.пароль@<IP>:443/?insecure=1#название
```

> **Важно:** в h-ui auth-строка клиента — это `username.password` (точка-разделитель), а не `username:password`

---

## СТРУКТУРА ФАЙЛОВ НА СЕРВЕРЕ

| Путь                                             | Описание                                |
| ------------------------------------------------ | --------------------------------------- |
| `/etc/ssh/sshd_config`                           | SSH конфиг                              |
| `/etc/fail2ban/jail.local`                       | fail2ban (sshd + sshd-preauth)          |
| `/etc/sysctl.d/99-bbr.conf`                      | BBR                                     |
| `/etc/apt/apt.conf.d/20auto-upgrades`            | автообновления                          |
| `/etc/apt/apt.conf.d/50unattended-upgrades`      | автообновления                          |
| `/root/3x-ui/docker-compose.yml`                 | Docker Compose (3x-ui)                  |
| `/root/3x-ui/db/x-ui.db`                         | БД 3x-ui (настройки, inbounds, клиенты) |
| `/root/3x-ui/cert/cert.pem`                      | TLS сертификат (общий)                  |
| `/root/3x-ui/cert/private.key`                   | TLS приватный ключ (общий)              |
| `/usr/local/h-ui/h-ui`                           | Бинарник h-ui (панель Hysteria2)         |
| `/usr/local/h-ui/data/h_ui.db`                   | БД h-ui (конфиг, пользователи)           |
| `/usr/local/h-ui/bin/hysteria-linux-amd64`       | Бинарник Hysteria2 (управляется h-ui)    |
| `/etc/systemd/system/h-ui.service`               | Systemd unit h-ui                        |
| `/etc/mtg/config.toml`                           | Конфиг MTProto-прокси (секрет, порт)    |

---

## СТРУКТУРА ПАПКИ TEMPLATES (эта папка)

```
templates/
├── sshd_config                    -- конфиг SSH
├── jail.local                     -- конфиг fail2ban (sshd + sshd-preauth)
├── docker-compose.yml             -- Docker Compose (3x-ui)
├── h-ui.service                   -- Systemd unit для h-ui (панель Hysteria2)
├── mtg-config.toml                -- Шаблон конфига MTProto (без секрета)
├── 99-bbr.conf                    -- sysctl BBR
├── 20auto-upgrades                -- apt автообновления
└── 50unattended-upgrades          -- apt автообновления

creds/                           -- ⚠️  НЕ ДЕЛИТЬСЯ! Только для своего бэкапа (в .gitignore)
    server_key                   -- SSH приватный ключ
    credentials.txt              -- Все данные доступа (пароли, URL, ссылки)
```

---

## ВОССТАНОВЛЕНИЕ ИЗ БЭКАПА (быстрый деплой)

**1. На свежем VPS с Ubuntu 24.04:**

```bash
apt update && apt upgrade -y
apt install -y ufw fail2ban openssl sqlite3 unattended-upgrades
curl -fsSL https://get.docker.com | sh
```

**2. Скопировать файлы из templates/ на сервер:**

```bash
scp -P 22 templates/sshd_config root@<IP>:/etc/ssh/sshd_config
scp -P 22 templates/jail.local root@<IP>:/etc/fail2ban/jail.local
scp -P 22 templates/99-bbr.conf root@<IP>:/etc/sysctl.d/
scp -P 22 templates/20auto-upgrades root@<IP>:/etc/apt/apt.conf.d/
scp -P 22 templates/50unattended-upgrades root@<IP>:/etc/apt/apt.conf.d/
```

**3. Отключить ssh.socket (Ubuntu 24.04):**

```bash
ssh root@<IP> "systemctl stop ssh.socket 2>/dev/null; systemctl disable ssh.socket 2>/dev/null; rm -rf /etc/systemd/system/ssh.socket.d"
```

**4. SSH ключ:**

```bash
ssh root@<IP> "mkdir -p /root/.ssh && chmod 700 /root/.ssh"
# Добавить публичный ключ из admin_key
ssh root@<IP> "echo '<YOUR_PUBLIC_KEY from server_key.pub>' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
```

**5. Применить настройки:**

```bash
ssh root@<IP> "sysctl -p /etc/sysctl.d/99-bbr.conf && sshd -t && systemctl daemon-reload && systemctl enable ssh.service && systemctl restart ssh.service && systemctl enable fail2ban && systemctl restart fail2ban && ufw --force reset && ufw default deny incoming && ufw default allow outgoing && ufw allow 59222/tcp comment 'SSH' && ufw allow 2053/tcp comment '3x-ui panel' && ufw allow 443/tcp comment 'VLESS Reality (yandex)' && ufw allow 443/udp comment 'Hysteria2 QUIC+Salamander' && ufw allow 7391/tcp comment 'h-ui panel' && ufw allow 2083/tcp comment 'VLESS Reality (yandex)' && ufw allow 2087/tcp comment 'Trojan Reality (yandex)' && ufw allow 993/tcp comment 'MTProto proxy (Telegram)' && echo y | ufw enable"
```

**6. 3x-ui:**

```bash
mkdir -p /root/3x-ui/{db,cert}
scp -P 22 templates/docker-compose.yml root@<IP>:/root/3x-ui/docker-compose.yml
scp -P 22 templates/secrets/cert.pem root@<IP>:/root/3x-ui/cert/cert.pem
scp -P 22 templates/secrets/private.key root@<IP>:/root/3x-ui/cert/private.key
ssh -p 59222 -i creds/<IP>/server_key root@<IP> "cd /root/3x-ui && docker compose up -d"
# Настроить через БД (шаг 8 из гайда)
# Создать inbound'ы (шаг 9)
```

**7. Hysteria2 (h-ui):**

```bash
# Установить h-ui (шаг 10 из гайда)
ssh -p 59222 -i creds/<IP>/server_key root@<IP> "mkdir -p /usr/local/h-ui/ && \
  curl -fsSL https://github.com/jonssonyan/h-ui/releases/latest/download/h-ui-linux-amd64 \
  -o /usr/local/h-ui/h-ui && chmod +x /usr/local/h-ui/h-ui"
scp -P 59222 -i creds/<IP>/server_key templates/h-ui.service root@<IP>:/etc/systemd/system/h-ui.service
ssh -p 59222 -i creds/<IP>/server_key root@<IP> "systemctl daemon-reload && systemctl enable h-ui && systemctl restart h-ui"
# Настроить HTTPS, Hysteria2 конфиг и пользователей через веб-панель https://<IP>:7391
```

**8. MTProto-прокси:**

```bash
ssh -p 59222 -i creds/<IP>/server_key root@<IP> "mkdir -p /etc/mtg"
scp -P 59222 templates/secrets/mtg-config.toml root@<IP>:/etc/mtg/config.toml

ssh -p 59222 -i creds/<IP>/server_key root@<IP> \
  "docker run -d --name mtg --restart always --network host \
   -v /etc/mtg/config.toml:/config.toml \
   nineseconds/mtg:2 run /config.toml"
```

---

## ПОЛЕЗНЫЕ КОМАНДЫ

**Подключение:**

```bash
ssh -i creds/<IP>/server_key -p 59222 root@<IP>
```

> **Windows: права на SSH-ключ** — SSH требует, чтобы файл ключа был доступен только владельцу.
> Выполнить один раз в PowerShell из корня репозитория:
> ```powershell
> $acl = $env:USERNAME + ":(R)"
> icacls "creds\<IP>\server_key" /inheritance:r /grant:r $acl
> ```

**Статус сервисов:**

```bash
ufw status numbered
fail2ban-client status sshd
docker ps
ss -tlnp          # TCP порты
ss -ulnp          # UDP порты
```

**Логи:**

```bash
docker logs 3x-ui --tail 30
docker logs mtg --tail 30
docker logs -f 3x-ui              # в реальном времени
journalctl -u h-ui --no-pager -n 30   # h-ui панель
cat /usr/local/h-ui/logs/hysteria2.log # Hysteria2 через h-ui
```

**Перезапуск:**

```bash
docker restart 3x-ui
docker restart mtg
systemctl restart h-ui             # h-ui + Hysteria2
```

**Бэкап БД (самое важное!):**

```bash
cp /root/3x-ui/db/x-ui.db ~/x-ui-backup.db
cp /usr/local/h-ui/data/h_ui.db ~/h-ui-backup.db
```

**Добавить пользователя Hysteria2:**
- Через веб-панель h-ui: `https://<IP>:7391/<basePath>/` → Accounts → Add

**Заблокировать IP вручную:**

```bash
ufw insert 1 deny from <BAD_IP>
```

**Разбанить IP в fail2ban:**

```bash
fail2ban-client set sshd unbanip <IP>
```
