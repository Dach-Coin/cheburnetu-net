#!/usr/bin/env python3
"""Phase 1: upload setup.sh to fresh VPS, run it DETACHED via nohup, then
poll /root/setup.log over repeated SSH sessions.

Why detached: Ubuntu apt-upgrade на свежем VPS обычно тащит libpam/dbus/systemd,
постинст-скрипты которых дёргают `systemctl restart` некоторых демонов, что
рвёт SSH-сессию ИЗНУТРИ deb-пакета. apt-mark hold openssh-* и needrestart=l
закрывают только прямые рестарты sshd; косвенные эффекты — нет. Раньше при
обрыве setup.sh получал SIGHUP и умирал посреди deploy. Теперь скрипт отвязан
от нашей сессии (nohup + disown + redir стдин/-аут) и переживает любые обрывы.

Поток:
  1. SSH (password, port 22) → SFTP setup.sh → запустить detached, вернуть PID.
  2. Поллинг: периодически подключаемся, читаем инкрементальный хвост лога,
     сохраняем ключ ed25519 как только видим `BEGIN..END KEY` блок (inline).
  3. После step4 setup.sh sshd уезжает на 59222 + пароль выключается. Поллер
     ловит ConnectionRefusedError/AuthFail на 22 → переключается на ключ:59222.
  4. Завершение detect'ится по появлению /root/setup.exitcode. Читаем код.
  5. SFTP /root/vpn_credentials.txt → creds/<IP>/credentials.txt.
"""
import sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

import configparser
import os
import re
import socket
import time
import paramiko

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(SCRIPT_DIR, 'deploy_config.ini')
LOCAL_SETUP = os.path.join(SCRIPT_DIR, 'setup.sh')

# Path of remote artefacts created by our nohup-wrapper
REMOTE_LOG      = '/root/setup.log'
REMOTE_EXITCODE = '/root/setup.exitcode'
REMOTE_PID      = '/root/setup.pid'

# Poll loop budget. Каждые POLL_INTERVAL секунд лезем по SSH; если NN итераций
# подряд без новых байт в логе И без появления exitcode-файла — прерываемся.
# apt upgrade на свежем VPS с распаковкой kernel-image (~150МБ) может молчать
# по 5-10 минут — лимит тишины должен быть выше этого.
POLL_INTERVAL_SEC = 3
MAX_QUIET_ITERS   = 300   # 300 * 3с = 15 минут тишины OK

# --- Load config ---
if not os.path.exists(CONFIG_PATH):
    print(f"[ERROR] Config not found: {CONFIG_PATH}")
    print("  Copy deploy_config.example.ini -> deploy_config.ini and fill in your data")
    sys.exit(1)

config = configparser.ConfigParser()
config.read(CONFIG_PATH, encoding='utf-8')

SERVER_IP = config.get('server', 'ip')
SSH_PORT  = config.getint('server', 'ssh_port')
USERNAME  = config.get('server', 'username')
PASSWORD  = config.get('server', 'password')
NEW_PORT  = config.getint('ssh', 'new_port', fallback=59222)

creds_dir   = os.path.join(SCRIPT_DIR, 'creds', SERVER_IP)
os.makedirs(creds_dir, exist_ok=True)
key_path    = os.path.join(creds_dir, 'server_key')
creds_path  = os.path.join(creds_dir, 'credentials.txt')
summary_path = os.path.join(creds_dir, 'deploy_summary.txt')

KEY_PATTERN = re.compile(
    r'-----BEGIN OPENSSH PRIVATE KEY-----\s*\n'
    r'(?:.*\n)*?'
    r'-----END OPENSSH PRIVATE KEY-----'
)

def _try_save_key(joined_output):
    """Сохранить ключ из joined-stdout в key_path если ещё не сохранён."""
    if os.path.exists(key_path):
        return True
    m = KEY_PATTERN.search(joined_output)
    if not m:
        return False
    key_text = m.group(0).rstrip() + '\n'
    with open(key_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(key_text)
    try:
        os.chmod(key_path, 0o600)
    except Exception:
        pass
    print(f"\n[!] Captured server_key -> {key_path} ({len(key_text)} bytes)\n", flush=True)
    return True

def _connect(ip, port, *, password=None, pkey=None):
    s = paramiko.SSHClient()
    s.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    s.connect(ip, port=port, username=USERNAME, password=password, pkey=pkey,
              timeout=45, banner_timeout=45, auth_timeout=45)
    return s

# === Phase 1: Upload + start detached ===
print(f"[1] Connecting to {SERVER_IP}:{SSH_PORT} ...")
ssh = _connect(SERVER_IP, SSH_PORT, password=PASSWORD)
print("[1] Connected OK")

print(f"[2] Uploading setup.sh -> /root/setup.sh ...")
sftp = ssh.open_sftp()
sftp.put(LOCAL_SETUP, '/root/setup.sh')
sftp.chmod('/root/setup.sh', 0o755)
sftp.close()
print("[2] Upload OK")

print("[3] Starting setup.sh (DETACHED via nohup; survives SSH drops) ...")
# Враппер: запускает setup.sh, по выходу пишет код в setup.exitcode.
# Все три FD перенаправлены — процесс полностью отвязан от controlling tty.
RUNNER = (
    f"rm -f {REMOTE_LOG} {REMOTE_EXITCODE} {REMOTE_PID}; "
    f"nohup bash -c 'bash /root/setup.sh; echo $? > {REMOTE_EXITCODE}' "
    f"  >{REMOTE_LOG} 2>&1 </dev/null & "
    f"echo $! > {REMOTE_PID}; disown $!; "
    f"cat {REMOTE_PID}"
)
_, out, _ = ssh.exec_command(RUNNER, timeout=20)
setup_pid = out.read().decode().strip()
ssh.close()
print(f"[3] setup.sh started, PID={setup_pid}, log={REMOTE_LOG}")
print()

# === Phase 1.5: Pull key file directly via SFTP while password:22 still works ===
# step4_ssh СНАЧАЛА создаёт /root/.ssh/id_admin (ssh-keygen), ПОТОМ редактирует
# sshd_config + рестартует ssh.service. Между «файл создан» и «sshd на новом
# порту» проходит ~1-3 секунды. Если в этом окне SFTP'ом забрать файл —
# гарантированно получим ключ независимо от того, успел ли поллер прочитать
# stdout-блок «BEGIN..END KEY» в логе. Иначе ловим race: апгрейд может убить
# нашу сессию ровно посреди step4, мы пропустим ключ-блок в логе и теряем
# доступ к серверу до перезаливки.
last_pos    = 0
full_output = []
key_saved   = False
print("[3.5] Polling /root/.ssh/id_admin via password:22 (до закрытия окна) ...")
phase15_attempt = 0
while not key_saved:
    phase15_attempt += 1
    try:
        ssh = _connect(SERVER_IP, SSH_PORT, password=PASSWORD)
    except paramiko.AuthenticationException:
        # Пароль уже выключен → step4 завершился, окно закрыто. Если ключа
        # ещё нет в creds/<IP>/ — мы его упустили. Пойдём в Phase 2 и будем
        # надеяться поймать BEGIN..END KEY блок в логе.
        print("[3.5] Auth failed (password disabled) — окно закрыто, переходим в poll-режим без ключа", flush=True)
        break
    except (paramiko.SSHException, socket.timeout, ConnectionError, OSError) as e:
        # Сетевой сбой — порт может быть переключаемым прямо сейчас
        if phase15_attempt > 600:  # ~10 мин
            print(f"[3.5] giving up on password:22 (10 min): {e}", flush=True)
            break
        time.sleep(1)
        continue
    try:
        sftp = ssh.open_sftp()
        try:
            sftp.get('/root/.ssh/id_admin', key_path)
            try:
                os.chmod(key_path, 0o600)
            except Exception:
                pass
            key_saved = True
            print(f"[3.5] Captured /root/.ssh/id_admin -> {key_path}", flush=True)
        except FileNotFoundError:
            # step4 ещё не дошёл до ssh-keygen, ждём
            pass
        # Заодно подтягиваем тот лог что уже накоплен
        try:
            size = sftp.stat(REMOTE_LOG).st_size
            if size > last_pos:
                with sftp.open(REMOTE_LOG, 'rb') as f:
                    f.seek(last_pos)
                    chunk = f.read(size - last_pos)
                if chunk:
                    text = chunk.decode('utf-8', errors='replace')
                    full_output.append(text)
                    sys.stdout.write(text)
                    sys.stdout.flush()
                    last_pos += len(chunk)
        except FileNotFoundError:
            pass
        sftp.close()
    finally:
        ssh.close()
    if not key_saved:
        time.sleep(1)

# Резерв: если ключ не пришёл через файл, попытаемся ещё разобрать stdout-блок
if not key_saved and full_output:
    joined = ''.join(full_output)
    m = KEY_PATTERN.search(joined)
    if m:
        key_text = m.group(0).rstrip() + '\n'
        with open(key_path, 'w', encoding='utf-8', newline='\n') as f:
            f.write(key_text)
        try: os.chmod(key_path, 0o600)
        except Exception: pass
        key_saved = True
        print(f"[3.5] Recovered key from stdout fallback -> {key_path}", flush=True)

print("[4] Polling log (key:59222 from now) ...")
print("=" * 70)

# === Phase 2: Poll log via repeated SSH ===
exit_code         = None
on_new_port       = True   # Phase 1.5 закрыла password:22 — сразу идём через ключ
quiet_iters       = 0
last_status_print = 0

while exit_code is None:
    if quiet_iters > MAX_QUIET_ITERS:
        print(f"\n[!] No log activity for ~{MAX_QUIET_ITERS * POLL_INTERVAL_SEC}s. Bailing out.")
        print(f"[!] setup.sh PID={setup_pid} может быть ещё жив — проверь руками:")
        print(f"     ssh -i {key_path} -p {NEW_PORT} root@{SERVER_IP} 'tail -f {REMOTE_LOG}'")
        break
    try:
        # Подбираем вход: пока step4 не отработал — пароль:22, потом ключ:59222
        if not on_new_port:
            try:
                ssh = _connect(SERVER_IP, SSH_PORT, password=PASSWORD)
            except (paramiko.AuthenticationException, paramiko.SSHException,
                    socket.timeout, ConnectionError, OSError) as e:
                # Скорее всего step4 закрыл пароль / сменил порт
                on_new_port = True
                quiet_iters += 1
                time.sleep(POLL_INTERVAL_SEC)
                continue
        else:
            if not os.path.exists(key_path):
                # Ключ ещё не перехвачен — нужно ждать пока step4 завершится
                # (увидим в логе через старый канал, но он уже закрыт). Подождём.
                quiet_iters += 1
                time.sleep(POLL_INTERVAL_SEC)
                continue
            try:
                pkey = paramiko.Ed25519Key.from_private_key_file(key_path)
                ssh = _connect(SERVER_IP, NEW_PORT, pkey=pkey)
            except (paramiko.SSHException, socket.timeout, ConnectionError, OSError):
                # sshd ещё не поднялся на новом порту — попробуем позже
                quiet_iters += 1
                time.sleep(POLL_INTERVAL_SEC)
                continue
        progress_made = False
        sftp = ssh.open_sftp()
        try:
            # Проверяем размер лога; читаем только новое
            try:
                size = sftp.stat(REMOTE_LOG).st_size
            except FileNotFoundError:
                size = 0
            if size > last_pos:
                with sftp.open(REMOTE_LOG, 'rb') as f:
                    f.seek(last_pos)
                    chunk = f.read(size - last_pos)
                if chunk:
                    text = chunk.decode('utf-8', errors='replace')
                    full_output.append(text)
                    sys.stdout.write(text)
                    sys.stdout.flush()
                    last_pos += len(chunk)
                    progress_made = True
                    if not key_saved:
                        key_saved = _try_save_key(''.join(full_output))
            elif size < last_pos:
                # Лог почему-то откатился (maybe truncated) — перечитаем целиком.
                # На практике не должно случаться, но защита от inconsistent state.
                last_pos = 0
            # Проверяем sentinel exit-code
            try:
                with sftp.open(REMOTE_EXITCODE, 'rb') as f:
                    ec_text = f.read().decode().strip()
                if ec_text.isdigit():
                    exit_code = int(ec_text)
            except FileNotFoundError:
                pass
        finally:
            sftp.close()
        ssh.close()
        if progress_made:
            quiet_iters = 0
        else:
            quiet_iters += 1
            now = time.time()
            if now - last_status_print > 30:
                print(f"\n[poll] no new bytes (quiet_iters={quiet_iters}/{MAX_QUIET_ITERS})", flush=True)
                last_status_print = now
    except (paramiko.SSHException, socket.timeout, ConnectionError, OSError) as e:
        # SSH рвётся — переподключимся в следующей итерации.
        if not on_new_port:
            on_new_port = True  # вторая попытка пойдёт на ключе:59222
        quiet_iters += 1
    if exit_code is None:
        time.sleep(POLL_INTERVAL_SEC)

print("\n" + "=" * 70)
print(f"[3] setup.sh exit_code: {exit_code}")

if exit_code is None:
    print("[ERROR] setup.sh не завершился (timeout). Сервер в полу-настроенном состоянии.")
    print("[!] У нас перехвачен ключ:" if key_saved else "[!] Ключа НЕТ — нужна console провайдера")
    if key_saved:
        print(f"     Подключение: ssh -i {key_path} -p {NEW_PORT} root@{SERVER_IP}")
    sys.exit(1)
if exit_code != 0:
    print(f"[ERROR] setup.sh вернул код {exit_code}")
    sys.exit(1)

print("[3] setup.sh завершился успешно!")

# Сводка credentials из stdout (между «НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО» и концом).
joined = ''.join(full_output)
sm = re.search(r'НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО.*', joined, re.DOTALL)
if sm:
    with open(summary_path, 'w', encoding='utf-8') as f:
        f.write(sm.group(0))
    print(f"[3.5] Saved deploy_summary.txt -> {summary_path}")

# === Phase 3: SFTP /root/vpn_credentials.txt ===
print(f"[4] Downloading /root/vpn_credentials.txt ...")
try:
    pkey = paramiko.Ed25519Key.from_private_key_file(key_path)
    ssh = _connect(SERVER_IP, NEW_PORT, pkey=pkey)
    sftp = ssh.open_sftp()
    sftp.get('/root/vpn_credentials.txt', creds_path)
    sftp.close()
    ssh.close()
    print(f"[4] -> {creds_path}")
except Exception as e:
    print(f"[4] SFTP failed: {e}")
    print(f"[4] Сервер настроен. Возьми credentials руками:")
    print(f"     ssh -i {key_path} -p {NEW_PORT} root@{SERVER_IP} cat /root/vpn_credentials.txt")

print("[DONE] Phase 1 complete")
