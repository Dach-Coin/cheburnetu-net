#!/usr/bin/env python3
"""Pre-deploy sanity check: connect to fresh VPS, measure IP / AS / egress / bandwidth.

Запускать ПЕРЕД deploy_phase1.py на свежем VPS, чтобы вовремя увидеть, что
хостер не годится для VPN: дохлый egress к нужным target-доменам, обрезанный
канал, битый IPv6, и т.п. Скрипт ничего не меняет на сервере, только читает.

Использование:
    1. Скопировать deploy_config.example.ini -> deploy_config.ini, заполнить.
    2. python deploy_precheck.py
    3. Прочитать выводы. Если всё ОК — `python deploy_phase1.py`.
"""
import sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

import configparser
import os
import paramiko

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(SCRIPT_DIR, 'deploy_config.ini')

# Что считаем "достаточно" для нормального VPN-сервера
MIN_BANDWIDTH_MBIT = 10        # ниже = клиенты будут страдать
SLOW_BANDWIDTH_MBIT = 50       # ниже = заметно для тяжёлого трафика
HANDSHAKE_OK_SEC = 1.5         # выше = заметные тормоза при connect

# Target-кандидаты для Reality (хотя бы один должен открываться быстро)
REALITY_TARGETS = [
    'www.yandex.ru', 'www.microsoft.com', 'www.bing.com',
    'www.cloudflare.com', 'icloud.com'
]

# Ru-домены для проверки реального egress (актуальный для русскоязычных пользователей)
RU_DOMAINS = [
    'www.yandex.ru', 'ya.ru', 'vk.com', 'mail.ru', 'ok.ru', 'dzen.ru',
    'avito.ru', 'ozon.ru', 'wildberries.ru', 'sberbank.ru', 'tinkoff.ru',
    'gosuslugi.ru', 'rbc.ru', '2gis.ru'
]

# ANSI цвета (PowerShell их понимает в современных Windows 10+)
GREEN, RED, YELLOW, CYAN, BOLD, NC = (
    '\033[0;32m', '\033[0;31m', '\033[1;33m',
    '\033[0;36m', '\033[1m', '\033[0m')

def ok(msg):    print(f'{GREEN}[OK]{NC}   {msg}')
def warn(msg):  print(f'{YELLOW}[WARN]{NC} {msg}')
def fail(msg):  print(f'{RED}[FAIL]{NC} {msg}')
def head(msg):  print(f'\n{CYAN}{BOLD}== {msg} =={NC}')

def run(ssh, cmd, timeout=60):
    """Выполнить команду, вернуть stdout (строкой)."""
    _, out, _ = ssh.exec_command(cmd, timeout=timeout)
    return out.read().decode('utf-8', errors='replace').strip()

def main():
    if not os.path.exists(CONFIG_PATH):
        fail(f'Config not found: {CONFIG_PATH}')
        print('  Copy deploy_config.example.ini -> deploy_config.ini and fill in your data')
        sys.exit(2)

    cfg = configparser.ConfigParser()
    cfg.read(CONFIG_PATH, encoding='utf-8')
    ip       = cfg.get('server', 'ip')
    ssh_port = cfg.getint('server', 'ssh_port', fallback=22)
    user     = cfg.get('server', 'username', fallback='root')
    password = cfg.get('server', 'password')

    head(f'Connecting to {ip}:{ssh_port}')
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        # 45s timeouts: некоторые хостеры дают далёкие IP с RTT 300+ ms
        # и нестабильным пингом — 15s банально не хватает на handshake.
        ssh.connect(ip, port=ssh_port, username=user, password=password,
                    timeout=45, banner_timeout=45, auth_timeout=45)
    except Exception as e:
        fail(f'SSH connect failed: {e}')
        sys.exit(2)
    ok('SSH connected')

    fatal = 0     # фундаментальные проблемы — deploy запрещаем
    notes = 0     # просто warning, на усмотрение пользователя

    # --- IP / AS / OS ---
    head('IP / AS / OS')
    info = run(ssh, "curl -s4 --max-time 8 https://ipinfo.io/ 2>/dev/null")
    if info:
        # извлечём ключевые поля без json-парсера, чтоб не падать на странном выводе
        for k in ('ip', 'city', 'country', 'org'):
            for line in info.splitlines():
                if f'"{k}"' in line:
                    print('  ' + line.strip().rstrip(','))
                    break
    osrel = run(ssh, "grep -E '^(NAME|VERSION_ID)=' /etc/os-release")
    print('  ' + osrel.replace('\n', '  '))
    arch  = run(ssh, "uname -m")
    print(f'  arch: {arch}')
    if 'Ubuntu' not in osrel:
        warn('Non-Ubuntu OS — setup.sh рассчитан на Ubuntu 24.04. Может не запуститься.')
        notes += 1

    # --- IPv6 egress (битый v6 на хостере = проблема) ---
    head('IPv6 egress')
    v6 = run(ssh, "curl -s6 --max-time 5 -o /dev/null -w '%{http_code}|%{time_appconnect}' https://www.google.com/ 2>/dev/null")
    code, _, t = (v6 or '000|0|0').partition('|')
    if code in ('200', '301', '302'):
        ok(f'IPv6 to google.com -> {code} ({t}s)')
    else:
        warn('IPv6 битый — Xray шаблон с DNS UseIPv4 спасёт, но имей в виду')
        notes += 1

    # --- Reality target кандидаты ---
    head('Reality target candidates (TCP/443 + TLS handshake)')
    alive_targets = []
    for d in REALITY_TARGETS:
        line = run(ssh,
            f"curl -s4 --max-time 6 -o /dev/null -w '%{{http_code}}|%{{time_appconnect}}' https://{d}/ 2>/dev/null")
        code, _, t = (line or '000|0').partition('|')
        try:
            t_f = float(t)
        except ValueError:
            t_f = 0.0
        if code != '000' and t_f > 0:
            mark = ok if t_f < HANDSHAKE_OK_SEC else warn
            mark(f'{d:25} -> {code} hs={t}s')
            alive_targets.append((d, t_f))
        else:
            fail(f'{d:25} -> blocked (timeout)')
    if not alive_targets:
        fail('Все кандидаты Reality-target недоступны. Хостер режет egress полностью — ищи другой.')
        fatal += 1
    elif not any(d == 'www.yandex.ru' for d, _ in alive_targets):
        warn('www.yandex.ru недоступен. Перед deploy подмени REALITY_SNI/REALITY_TARGET в setup.sh на работающий target.')
        notes += 1

    # --- Реальный egress на крупные ru-домены (для российских клиентов через VPN) ---
    head('Russian domains egress (через VPN клиенты будут ходить с этого IP)')
    bad = []
    for d in RU_DOMAINS:
        line = run(ssh,
            f"curl -s4 --max-time 5 -o /dev/null -w '%{{http_code}}|%{{time_appconnect}}' https://{d}/ 2>/dev/null")
        code, _, t = (line or '000|0').partition('|')
        if code == '000':
            bad.append(d)
            print(f'  {RED}{d:25}{NC} blocked')
        else:
            print(f'  {GREEN}{d:25}{NC} {code} hs={t}s')
    pct_bad = 100 * len(bad) / len(RU_DOMAINS)
    if pct_bad >= 50:
        fail(f'{len(bad)}/{len(RU_DOMAINS)} ru-доменов недоступны ({pct_bad:.0f}%) — VPN будет частично рабочий.')
        fatal += 1
    elif pct_bad >= 20:
        warn(f'{len(bad)}/{len(RU_DOMAINS)} ru-доменов недоступны ({pct_bad:.0f}%) — клиенты будут жаловаться.')
        notes += 1
    else:
        ok(f'{len(RU_DOMAINS)-len(bad)}/{len(RU_DOMAINS)} ru-доменов открываются')

    # --- Bandwidth: Hetzner 100MB download (стабильно работает с любого IP) ---
    head('Bandwidth (Hetzner 100MB sustained download)')
    speed_line = run(ssh,
        "curl -sL4 --max-time 30 -o /dev/null -w 'size=%{size_download} t=%{time_total} speed=%{speed_download}' "
        "'https://fsn1-speed.hetzner.com/100MB.bin'", timeout=40)
    print(f'  raw: {speed_line}')
    # speed_download у curl — bytes/sec
    speed_bps = 0
    for tok in speed_line.split():
        if tok.startswith('speed='):
            try:
                speed_bps = float(tok.split('=', 1)[1])
            except ValueError:
                pass
    mbit = speed_bps * 8 / 1_000_000
    print(f'  ≈ {mbit:.1f} Mbit/s sustained')
    if mbit < MIN_BANDWIDTH_MBIT:
        fail(f'Канал {mbit:.1f} Mbit/s — на VPN это смерть. Меняй тариф/хостер ДО deploy.')
        fatal += 1
    elif mbit < SLOW_BANDWIDTH_MBIT:
        warn(f'Канал {mbit:.1f} Mbit/s — ОК для базового использования, но на тяжёлом трафике будет узким.')
        notes += 1
    else:
        ok(f'Канал {mbit:.1f} Mbit/s — норма')

    # --- GitHub release CDN (для шага 9a — manual Xray upgrade) ---
    head('GitHub release CDN (нужен для свежего Xray bin)')
    gh = run(ssh,
        "curl -sL4 --max-time 10 -o /dev/null -w '%{http_code}|%{size_download}' "
        "'https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-64.zip' 2>/dev/null")
    code, _, size = (gh or '000|0').partition('|')
    try:
        size_i = int(size)
    except ValueError:
        size_i = 0
    if size_i > 1_000_000:
        ok(f'release-assets reachable ({size_i} bytes pulled in test)')
    else:
        warn('GitHub release CDN режется. setup.sh скачает локально и перебросит — workaround сработает.')
        notes += 1

    ssh.close()

    head('SUMMARY')
    print(f'  fatal issues: {fatal}')
    print(f'  warnings:     {notes}')
    if fatal:
        fail('Хостер не подходит. Не запускай deploy_phase1.py — потеряешь время. Меняй VPS.')
        sys.exit(1)
    if notes:
        warn('Есть замечания. Deploy запустить можно, но прочитай warnings выше.')
    else:
        ok('Сервер выглядит здоровым. Можно запускать `python deploy_phase1.py`.')
    sys.exit(0)


if __name__ == '__main__':
    main()
