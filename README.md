# Чебурнету — нет!

Автоматическая настройка персонального VPN-сервера с 4 протоколами маскировки трафика. Один скрипт — и через 10 минут у вас полностью рабочий сервер с защищёнными каналами связи.

## Что разворачивается

| Протокол         | Порт     | Технология   | Зачем                                        |
| ---------------- | -------- | ------------ | -------------------------------------------- |
| **VLESS + TLS**  | 443/TCP  | 3x-ui / Xray | Основной VPN — маскируется под обычный HTTPS |
| **Trojan + TLS** | 8443/TCP | 3x-ui / Xray | Резервный VPN — альтернативный протокол      |
| **Hysteria2**    | 443/UDP  | QUIC         | Быстрый VPN для видео и скачивания (UDP)     |
| **MTProto**      | 993/TCP  | mtg v2       | Прокси для Telegram без VPN-приложения       |

Дополнительно:
- SSH на нестандартном порту 59222 с авторизацией по ключу (пароль отключён)
- UFW файрвол — открыты только нужные порты
- fail2ban — защита от брутфорса SSH
- BBR — ускорение TCP
- Автоматические обновления безопасности

## Требования

### Сервер

- **VPS с Ubuntu 24.04 LTS** (свежая установка)
- 1 vCPU, 1+ GB RAM, 10+ GB SSD
- Доступ root по SSH (пароль — для первого подключения)

### Локальная машина (для запуска скрипта)

Скрипт можно запустить двумя способами:

**Способ 1 — прямо на сервере (рекомендуется):**

Нужен только SSH-клиент (есть в любой ОС).

**Способ 2 — удалённо через Python/paramiko:**

- Python 3.10+
- paramiko (`pip install paramiko`)

## Быстрый старт

### 1. Подключиться к серверу

```bash
ssh root@<IP_СЕРВЕРА>
```

### 2. Скачать и запустить скрипт

```bash
curl -O https://raw.githubusercontent.com/<OWNER>/<REPO>/main/setup.sh
bash setup.sh
```

### 3. Сохранить данные доступа

Скрипт выведет:
- **SSH-ключ** — сохранить в файл `creds/server_key`
- **Пароль панели 3x-ui** — для управления VLESS/Trojan
- **Пароли Hysteria2** — для двух пользователей
- **Ссылка MTProto** — вставить прямо в Telegram

Все данные также сохраняются на сервере в `/root/vpn_credentials.txt`.

### 4. Установить права на SSH-ключ

```bash
# Linux / macOS:
chmod 600 creds/server_key

# Windows (PowerShell):
icacls "creds\server_key" /inheritance:r /grant:r "$env:USERNAME:(R)"
```

### 5. Подключиться по ключу

```bash
ssh -i creds/server_key -p 59222 root@<IP_СЕРВЕРА>
```

## Что делает setup.sh

Скрипт выполняет 11 шагов полностью автоматически:

1. Обновление системы и установка пакетов
2. Включение BBR (ускорение TCP)
3. Настройка автообновлений безопасности
4. SSH hardening — смена порта, ключ ED25519, отключение пароля
5. Настройка UFW (файрвол)
6. Настройка fail2ban (защита от брутфорса)
7. Установка Docker и запуск 3x-ui
8. Настройка 3x-ui — HTTPS, пароль, скрытый URL
9. Создание inbound'ов — VLESS (443) и Trojan (8443)
10. Установка Hysteria2 (443/UDP)
11. Установка MTProto-прокси для Telegram (993/TCP)

Все пароли и секреты генерируются случайно при каждом запуске. Скрипт не содержит захардкоженных credentials.

### Настраиваемые параметры

В начале `setup.sh` можно изменить:

```bash
SSH_PORT=59222          # Порт SSH
PANEL_PORT=2053         # Порт веб-панели 3x-ui
XUI_VERSION="2.5.7"    # Версия 3x-ui
HY2_USER1="User1"      # Имя пользователя Hysteria2
HY2_USER2="User2"      # Имя пользователя Hysteria2
```

## Структура проекта

```
├── setup.sh                  — Основной скрипт автонастройки
├── SETUP_GUIDE.md            — Пошаговый гайд (ручная установка)
├── templates/                — Шаблоны конфигов (без секретов)
│   ├── sshd_config
│   ├── ssh_socket_override.conf
│   ├── jail.local
│   ├── docker-compose.yml
│   ├── hysteria2-config.yaml
│   ├── hysteria2-docker-compose.yml
│   ├── mtg-config.toml
│   ├── 99-bbr.conf
│   ├── 20auto-upgrades
│   └── 50unattended-upgrades
└── creds/                    — Ваши данные доступа (в .gitignore)
    ├── server_key
    └── credentials.txt
```

## Известные нюансы Ubuntu 24.04

При написании и тестировании скрипта были обнаружены подводные камни, которые **уже учтены в setup.sh**, но полезно знать:

**systemd SSH socket — только IPv6 по умолчанию.** При указании `ListenStream=59222` systemd создаёт только IPv6-сокет `[::]:59222`. Подключиться извне по IPv4 невозможно — сервер станет недоступен. Решение — явно указывать оба адреса:

```ini
[Socket]
ListenStream=
ListenStream=0.0.0.0:59222
ListenStream=[::]:59222
```

**sshd -t требует /run/sshd.** На свежей Ubuntu 24.04 каталог `/run/sshd` не создан. Команда `sshd -t` (проверка конфига) падает с ошибкой "Missing privilege separation directory". Решение — `mkdir -p /run/sshd` перед проверкой.

**Определение IP на dual-stack серверах.** Команды `curl ifconfig.me` и `hostname -I` могут вернуть IPv6-адрес вместо IPv4. Решение — `curl -4` или `ip -4 addr show scope global`.

## Клиентские приложения

Для подключения к серверу нужно установить клиент на телефон или компьютер. Ниже — проверенные приложения с поддержкой используемых протоколов.

### Android

| Приложение   | Протоколы                                     | Ссылка                                                                                                                                |
| ------------ | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| **v2rayNG**  | VLESS, Trojan, VMess, SS                      | [GitHub](https://github.com/2dust/v2rayNG)                                                                                            |
| **Hiddify**  | VLESS, Trojan, Hysteria2, SS, TUIC, SSH       | [GitHub](https://github.com/hiddify/hiddify-app)                                                                                      |
| **NekoBox**  | VLESS, Trojan, Hysteria2, SS, TUIC, WireGuard | [GitHub](https://github.com/MatsuriDayo/NekoBoxForAndroid)                                                                            |
| **v2rayTun** | VLESS, Trojan, Hysteria2, VMess, SS           | [GitHub](https://github.com/niceDev0908/v2raytun) / [Google Play](https://play.google.com/store/apps/details?id=com.v2raytun.android) |

### iOS

| Приложение    | Протоколы                               | Ссылка                                                                                                                    |
| ------------- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| **Hiddify**   | VLESS, Trojan, Hysteria2, SS, TUIC, SSH | [GitHub](https://github.com/hiddify/hiddify-app) / [App Store](https://apps.apple.com/app/hiddify-proxy-vpn/id6596777532) |
| **Streisand** | VLESS, Trojan, VMess, SS, Hysteria2     | [App Store](https://apps.apple.com/app/streisand/id6450534064)                                                            |
| **FoXray**    | VLESS, Trojan, VMess, SS                | [App Store](https://apps.apple.com/app/foxray/id6448898396)                                                               |
| **V2Box**     | VLESS, Trojan, VMess, SS                | [App Store](https://apps.apple.com/app/v2box-v2ray-client/id6446814690)                                                   |

### Windows / macOS / Linux

| Приложение  | Платформы             | Протоколы                           | Ссылка                                           |
| ----------- | --------------------- | ----------------------------------- | ------------------------------------------------ |
| **v2rayN**  | Windows, macOS, Linux | VLESS, Trojan, VMess, SS, Hysteria2 | [GitHub](https://github.com/2dust/v2rayN)        |
| **Hiddify** | Windows, macOS, Linux | VLESS, Trojan, Hysteria2, SS, TUIC  | [GitHub](https://github.com/hiddify/hiddify-app) |
| **NekoRay** | Windows, Linux        | VLESS, Trojan, Hysteria2, SS, TUIC  | [GitHub](https://github.com/MatsuriDayo/nekoray) |

### Telegram (MTProto)

Для MTProto-прокси **не нужно отдельное приложение**. Скрипт выдаст ссылку вида:

```
https://t.me/proxy?server=<IP>&port=993&secret=<SECRET>
```

Откройте её в браузере или отправьте в Telegram — приложение предложит добавить прокси.

### Какой клиент выбрать?

- **Hiddify** — универсальный выбор, поддерживает все 4 протокола на всех платформах
- **v2rayNG** (Android) / **v2rayN** (ПК) — проверенная классика для VLESS и Trojan
- **NekoBox** — для продвинутых пользователей, гибкие настройки

> **Важно:** при подключении к VLESS/Trojan включите **allowInsecure = true** (самоподписной сертификат). Для VLESS оставьте Flow **пустым** (не xtls-rprx-vision).

## Развёртывание через AI-ассистента

Проект можно развернуть с помощью AI-агента (Claude Code, Cursor, Windsurf, ChatGPT с Code Interpreter и др.). В файле `AGENTS.md` содержатся подробные инструкции для агента: подводные камни, порядок действий, обработка ошибок.

### Пример промпта

```
Мне нужно настроить VPN-сервер с помощью скрипта setup.sh из этого проекта.

Данные для подключения:
- IP сервера: 203.0.113.42
- Порт SSH: 22
- Пользователь: root
- Пароль: MyPassword123

Задачи:
1. Подключись к серверу по SSH
2. Загрузи setup.sh на сервер и запусти его
3. Дождись завершения и сохрани все данные доступа:
   - SSH-ключ → creds/server_key
   - Credentials → creds/credentials.txt
4. Установи права на файл ключа (icacls на Windows / chmod на Linux)
5. Проверь подключение по ключу на новом порту (59222)

Прочитай AGENTS.md перед началом — там описаны все нюансы.
SETUP_GUIDE.md - последовательность действий
```

## Лицензия

MIT
