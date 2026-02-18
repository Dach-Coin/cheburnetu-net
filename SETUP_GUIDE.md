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

**После запуска:**
1. Скопировать приватный SSH-ключ из вывода скрипта → сохранить в `creds/server_key`
2. Скопировать все credentials из вывода (или с сервера из `/root/vpn_credentials.txt`)
3. Установить права на ключ:

```bash
# Linux / macOS:
chmod 600 creds/server_key

# Windows (PowerShell):
icacls "creds\server_key" /inheritance:r /grant:r "$env:USERNAME:(R)"
```

### Требования для управления с ПК (paramiko)

Если нужно запускать команды на сервере удалённо из Python (например, для автоматизации):

- **Python** 3.10+
- **pip install paramiko** — SSH-клиент для Python

```bash
pip install paramiko
```

---

## ТЕКУЩИЕ ПРОТОКОЛЫ

1. **VLESS + TCP + TLS** — порт 443/TCP (через 3x-ui/Xray)
2. **Trojan + TCP + TLS** — порт 8443/TCP (через 3x-ui/Xray)
3. **Hysteria2 (QUIC)** — порт 443/UDP (отдельный Docker-контейнер)
4. **MTProto proxy (Telegram)** — порт 993/TCP (mtg v2, отдельный Docker-контейнер)

**Не работают на данной сети (блокируются DPI):**
- VMess (любой транспорт) — детектируется по fingerprint
- Shadowsocks (legacy и 2022) — детектируется DPI

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

# Настроить systemd socket (Ubuntu 24.04!)
# ВАЖНО: явно указать 0.0.0.0 и [::] — иначе слушает только IPv6!
mkdir -p /etc/systemd/system/ssh.socket.d
cat > /etc/systemd/system/ssh.socket.d/override.conf << 'EOF'
[Socket]
ListenStream=
ListenStream=0.0.0.0:59222
ListenStream=[::]:59222
EOF

# Применить
mkdir -p /run/sshd   # нужен для sshd -t на Ubuntu 24.04
sshd -t && echo "OK"
systemctl daemon-reload
systemctl restart ssh.socket ssh.service
```

**Проверка:**

```bash
ss -tlnp | grep sshd
# Должно показать *:59222
```

---

### 5. Настроить UFW (файрвол)

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow 59222/tcp comment 'SSH'
ufw allow 2053/tcp comment '3x-ui panel'
ufw allow 443/tcp comment 'VLESS TLS'
ufw allow 443/udp comment 'Hysteria2 QUIC'
ufw allow 8443/tcp comment 'Trojan TLS'
ufw allow 993/tcp comment 'MTProto proxy (Telegram)'
echo 'y' | ufw enable
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

[sshd]
enabled = true
port = 59222
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200
EOF

systemctl enable fail2ban
systemctl restart fail2ban
```

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
    image: ghcr.io/mhsanaei/3x-ui:2.5.7
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

### 9. Создать inbound'ы (VLESS + Trojan)

```bash
# Залогиниться
BASE="https://127.0.0.1:2053/<basePath>"
curl -sk -c /tmp/c.txt -X POST "$BASE/login" \
  -d 'username=admin&password=<ПАРОЛЬ>'
```

**VLESS + TCP + TLS (порт 443):**

```bash
curl -sk -b /tmp/c.txt -X POST "$BASE/panel/api/inbounds/add" \
  --data-urlencode 'remark=vless-tls' \
  --data-urlencode 'enable=true' \
  --data-urlencode 'port=443' \
  --data-urlencode 'protocol=vless' \
  --data-urlencode 'settings={"clients":[],"decryption":"none","fallbacks":[]}' \
  --data-urlencode 'streamSettings={"network":"tcp","security":"tls","tlsSettings":{"serverName":"","minVersion":"1.2","maxVersion":"1.3","certificates":[{"certificateFile":"/root/cert/cert.pem","keyFile":"/root/cert/private.key"}],"alpn":["h2","http/1.1"],"settings":{"allowInsecure":true,"fingerprint":"chrome"}},"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}' \
  --data-urlencode 'sniffing={"enabled":true,"destOverride":["http","tls","quic","fakedns"]}' \
  --data-urlencode 'up=0' --data-urlencode 'down=0' \
  --data-urlencode 'total=0' --data-urlencode 'expiryTime=0' \
  --data-urlencode 'listen='
```

**Trojan + TCP + TLS (порт 8443):**

```bash
curl -sk -b /tmp/c.txt -X POST "$BASE/panel/api/inbounds/add" \
  --data-urlencode 'remark=trojan-tcp' \
  --data-urlencode 'enable=true' \
  --data-urlencode 'port=8443' \
  --data-urlencode 'protocol=trojan' \
  --data-urlencode 'settings={"clients":[],"fallbacks":[]}' \
  --data-urlencode 'streamSettings={"network":"tcp","security":"tls","tlsSettings":{"serverName":"","minVersion":"1.2","maxVersion":"1.3","certificates":[{"certificateFile":"/root/cert/cert.pem","keyFile":"/root/cert/private.key"}],"alpn":["h2","http/1.1"],"settings":{"allowInsecure":true,"fingerprint":"chrome"}},"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}' \
  --data-urlencode 'sniffing={"enabled":true,"destOverride":["http","tls","quic","fakedns"]}' \
  --data-urlencode 'up=0' --data-urlencode 'down=0' \
  --data-urlencode 'total=0' --data-urlencode 'expiryTime=0' \
  --data-urlencode 'listen='
```

```bash
# Перезапустить для применения
docker restart 3x-ui
```

---

### 10. Установить Hysteria2 (отдельный контейнер)

```bash
mkdir -p /root/hysteria2

# Сгенерить пароли для пользователей
PASS1=$(openssl rand -hex 16)
PASS2=$(openssl rand -hex 16)
echo "User1 password: $PASS1"
echo "User2 password: $PASS2"
```

**Конфиг Hysteria2:**

```yaml
listen: :443

tls:
  cert: /etc/hysteria/cert.pem
  key: /etc/hysteria/private.key

auth:
  type: userpass
  userpass:
    User1: $PASS1
    User2: $PASS2

masquerade:
  type: proxy
  proxy:
    url: https://www.apple.com
    rewriteHost: true
```

**Docker Compose для Hysteria2:**

```yaml
services:
  hysteria2:
    image: tobyxdd/hysteria:v2
    container_name: hysteria2
    restart: always
    network_mode: host
    volumes:
      - ./config.yaml:/etc/hysteria/config.yaml
      - /root/3x-ui/cert/cert.pem:/etc/hysteria/cert.pem:ro
      - /root/3x-ui/cert/private.key:/etc/hysteria/private.key:ro
    command: ["server", "-c", "/etc/hysteria/config.yaml"]
```

```bash
cd /root/hysteria2
docker compose pull
docker compose up -d
```

**Проверка:**

```bash
sleep 3
docker logs hysteria2
# Должно быть: "server up and running"
```

> Hysteria2 использует 443/UDP (QUIC), не конфликтует с VLESS на 443/TCP

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
# Пример вывода: ee37ec8160a09d1e96dbd4a9c2f5c8dd39676f6f676c652e636f6d

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

**VLESS и Trojan** — через веб-панель 3x-ui:
- URL: `https://<IP>:2053/<basePath>/`
- Для каждого inbound нажать "+" и создать клиента

**Важно для VLESS:**
- allowInsecure = true (самоподписной сертификат)
- Flow: оставить ПУСТЫМ (не xtls-rprx-vision!)
- Fingerprint: chrome

**Важно для Trojan:**
- allowInsecure = true (самоподписной сертификат)

**Hysteria2** — через config.yaml:
- Добавить строку в секцию userpass: `ИмяЮзера: <пароль>`
- Перезапустить: `docker restart hysteria2`

**Ссылка для клиента:**
```
hysteria2://ИмяЮзера:пароль@<IP>:443?insecure=1#название
```

---

## СТРУКТУРА ФАЙЛОВ НА СЕРВЕРЕ

| Путь                                             | Описание                                |
| ------------------------------------------------ | --------------------------------------- |
| `/etc/ssh/sshd_config`                           | SSH конфиг                              |
| `/etc/systemd/system/ssh.socket.d/override.conf` | SSH порт (systemd)                      |
| `/etc/fail2ban/jail.local`                       | fail2ban                                |
| `/etc/sysctl.d/99-bbr.conf`                      | BBR                                     |
| `/etc/apt/apt.conf.d/20auto-upgrades`            | автообновления                          |
| `/etc/apt/apt.conf.d/50unattended-upgrades`      | автообновления                          |
| `/root/3x-ui/docker-compose.yml`                 | Docker Compose (3x-ui)                  |
| `/root/3x-ui/db/x-ui.db`                         | БД 3x-ui (настройки, inbounds, клиенты) |
| `/root/3x-ui/cert/cert.pem`                      | TLS сертификат (общий)                  |
| `/root/3x-ui/cert/private.key`                   | TLS приватный ключ (общий)              |
| `/root/hysteria2/docker-compose.yml`             | Docker Compose (Hysteria2)              |
| `/root/hysteria2/config.yaml`                    | Конфиг Hysteria2 (пользователи тут)     |
| `/etc/mtg/config.toml`                           | Конфиг MTProto-прокси (секрет, порт)    |

---

## СТРУКТУРА ПАПКИ TEMPLATES (эта папка)

```
templates/
├── sshd_config                    -- конфиг SSH
├── ssh_socket_override.conf       -- systemd socket override
├── jail.local                     -- конфиг fail2ban
├── docker-compose.yml             -- Docker Compose (3x-ui)
├── hysteria2-docker-compose.yml   -- Docker Compose (Hysteria2)
├── hysteria2-config.yaml          -- Шаблон конфига Hysteria2 (без паролей)
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

**3. SSH socket override:**

```bash
ssh root@<IP> "mkdir -p /etc/systemd/system/ssh.socket.d"
scp -P 22 templates/ssh_socket_override.conf root@<IP>:/etc/systemd/system/ssh.socket.d/override.conf
```

**4. SSH ключ:**

```bash
ssh root@<IP> "mkdir -p /root/.ssh && chmod 700 /root/.ssh"
# Добавить публичный ключ из admin_key
ssh root@<IP> "echo '<YOUR_PUBLIC_KEY from server_key.pub>' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
```

**5. Применить настройки:**

```bash
ssh root@<IP> "sysctl -p /etc/sysctl.d/99-bbr.conf && sshd -t && systemctl daemon-reload && systemctl restart ssh.socket ssh.service && systemctl enable fail2ban && systemctl restart fail2ban && ufw --force reset && ufw default deny incoming && ufw default allow outgoing && ufw allow 59222/tcp comment 'SSH' && ufw allow 2053/tcp comment '3x-ui panel' && ufw allow 443/tcp comment 'VLESS/Trojan TLS' && ufw allow 443/udp comment 'Hysteria2 QUIC' && ufw allow 8443/tcp comment 'Trojan-TCP' && ufw allow 993/tcp comment 'MTProto proxy (Telegram)' && echo y | ufw enable"
```

**6. 3x-ui:**

```bash
mkdir -p /root/3x-ui/{db,cert}
scp -P 22 templates/docker-compose.yml root@<IP>:/root/3x-ui/docker-compose.yml
scp -P 22 templates/secrets/cert.pem root@<IP>:/root/3x-ui/cert/cert.pem
scp -P 22 templates/secrets/private.key root@<IP>:/root/3x-ui/cert/private.key
ssh -p 59222 -i creds/server_key root@<IP> "cd /root/3x-ui && docker compose up -d"
# Настроить через БД (шаг 8 из гайда)
# Создать inbound'ы (шаг 9)
```

**7. Hysteria2:**

```bash
mkdir -p /root/hysteria2
scp -P 22 templates/hysteria2-docker-compose.yml root@<IP>:/root/hysteria2/docker-compose.yml
scp -P 22 templates/secrets/hysteria2-config.yaml root@<IP>:/root/hysteria2/config.yaml
ssh -p 59222 -i creds/server_key root@<IP> "cd /root/hysteria2 && docker compose up -d"
```

**8. MTProto-прокси:**

```bash
ssh -p 59222 -i creds/server_key root@<IP> "mkdir -p /etc/mtg"
scp -P 59222 templates/secrets/mtg-config.toml root@<IP>:/etc/mtg/config.toml

ssh -p 59222 -i creds/server_key root@<IP> \
  "docker run -d --name mtg --restart always --network host \
   -v /etc/mtg/config.toml:/config.toml \
   nineseconds/mtg:2 run /config.toml"
```

---

## ПОЛЕЗНЫЕ КОМАНДЫ

**Подключение:**

```bash
ssh -i creds/server_key -p 59222 root@<IP>
```

> **Windows: права на SSH-ключ** — SSH требует, чтобы файл ключа был доступен только владельцу.
> Выполнить один раз в PowerShell из корня репозитория:
> ```powershell
> $acl = $env:USERNAME + ":(R)"
> icacls "creds\server_key" /inheritance:r /grant:r $acl
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
docker logs hysteria2 --tail 30
docker logs mtg --tail 30
docker logs -f 3x-ui              # в реальном времени
```

**Перезапуск:**

```bash
docker restart 3x-ui
docker restart hysteria2
docker restart mtg
```

**Бэкап БД (самое важное!):**

```bash
cp /root/3x-ui/db/x-ui.db ~/x-ui-backup.db
```

**Добавить пользователя Hysteria2:**
- Редактировать `/root/hysteria2/config.yaml`, добавить строку в userpass
- Затем: `docker restart hysteria2`

**Заблокировать IP вручную:**

```bash
ufw insert 1 deny from <BAD_IP>
```

**Разбанить IP в fail2ban:**

```bash
fail2ban-client set sshd unbanip <IP>
```
