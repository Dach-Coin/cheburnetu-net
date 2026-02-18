# Инструкции для AI-агента: развёртывание VPN-сервера

Этот файл содержит инструкции для AI-ассистента (Claude, ChatGPT, Cursor, Kilo и др.) по развёртыванию VPN-сервера с помощью скрипта `setup.sh`.

## Общий план действий

1. Подключиться к серверу по SSH (порт 22, пароль)
2. Загрузить `setup.sh` на сервер
3. Запустить `setup.sh`
4. Дождаться завершения, перехватить вывод (SSH-ключ, credentials)
5. Сохранить ключ и credentials локально в `creds/`
6. Установить права на файл ключа
7. Проверить подключение по ключу на новом порту

## Подключение к серверу (paramiko)

На Windows нет `sshpass`/`expect`. Единственный рабочий способ — **paramiko** (Python SSH-клиент).

### ОБЯЗАТЕЛЬНО в начале каждого Python-скрипта:

```python
import sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
```

Без этого вывод команд `apt` и других утилит упадёт с ошибкой кодировки cp1251 на Windows.

### Подключение с паролем (первое подключение):

```python
import paramiko

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('IP_АДРЕС', port=22, username='root', password='ПАРОЛЬ', timeout=15)
```

### Подключение с ключом (после настройки SSH):

```python
import paramiko, io

key_str = """-----BEGIN OPENSSH PRIVATE KEY-----
...содержимое ключа...
-----END OPENSSH PRIVATE KEY-----"""

pkey = paramiko.Ed25519Key.from_private_key(io.StringIO(key_str))
ssh.connect('IP_АДРЕС', port=59222, username='root', pkey=pkey, timeout=15)
```

## Загрузка и запуск setup.sh

### Загрузка через SFTP:

```python
sftp = ssh.open_sftp()
sftp.put('setup.sh', '/root/setup.sh')   # локальный путь → серверный путь
sftp.chmod('/root/setup.sh', 0o755)
sftp.close()
```

### Запуск с потоковым выводом:

```python
transport = ssh.get_transport()
channel = transport.open_session()
channel.set_combine_stderr(True)
channel.settimeout(600)  # 10 минут — скрипт долгий!
channel.exec_command('bash /root/setup.sh 2>&1')

while True:
    if channel.recv_ready():
        data = channel.recv(8192)
        if not data:
            break
        print(data.decode('utf-8', errors='replace'), end='', flush=True)
    elif channel.exit_status_ready():
        while channel.recv_ready():
            data = channel.recv(8192)
            print(data.decode('utf-8', errors='replace'), end='', flush=True)
        break
    else:
        time.sleep(0.5)

exit_code = channel.recv_exit_status()
```

**Timeout должен быть не менее 600 секунд** (10 минут). Скрипт скачивает Docker-образы — на медленных серверах это занимает время.

## Перехват данных из вывода

Скрипт выводит в stdout:

1. **SSH-ключ** — между маркерами:
   ```
   ================================================================
     ПРИВАТНЫЙ SSH-КЛЮЧ — СОХРАНИ В НАДЁЖНОЕ МЕСТО!
   ================================================================
   -----BEGIN OPENSSH PRIVATE KEY-----
   ...
   -----END OPENSSH PRIVATE KEY-----
   ================================================================
   ```

2. **Credentials** — в итоговой сводке после `НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО`.

3. **Файл на сервере** — `/root/vpn_credentials.txt` содержит все данные. Можно скачать через SFTP:
   ```python
   sftp.get('/root/vpn_credentials.txt', 'creds/credentials.txt')
   sftp.get('/root/.ssh/id_admin', 'creds/server_key')
   ```

## Сохранение ключа и права доступа

### Сохранение ключа:

```python
sftp = ssh.open_sftp()
sftp.get('/root/.ssh/id_admin', 'creds/server_key')
sftp.close()
```

### Права на файл ключа (Windows):

```bash
icacls "creds\server_key" /inheritance:r /grant:r "ИМЯПОЛЬЗОВАТЕЛЯ:(R)"
```

Получить имя пользователя:
```python
import os
username = os.environ.get('USERNAME', os.environ.get('USER', 'user'))
```

### КРИТИЧНО: НЕ запускать icacls на один и тот же файл дважды!

Повторный вызов `icacls /inheritance:r /grant:r` может заблокировать файл навсегда (Windows ACL lock). Если файл заблокирован — сохранить ключ под другим именем (`server_key_v2`) и работать с ним.

### Права на файл ключа (Linux/macOS):

```bash
chmod 600 creds/server_key
```

## Проверка после развёртывания

После завершения скрипта проверить:

```python
# Подключение по ключу на новый порт
ssh.connect('IP', port=59222, username='root', pkey=pkey, timeout=15)

# Проверка сервисов
_, out, _ = ssh.exec_command('docker ps --format "{{.Names}}: {{.Status}}"')
print(out.read().decode())
# Ожидаемый вывод: 3x-ui, hysteria2, mtg — все Up

# Проверка портов
_, out, _ = ssh.exec_command('ss -tlnp | grep -E ":(59222|2053|443|8443|993) "')
print(out.read().decode())
```

## Критические ошибки и как их избежать

### 1. Скрипт упал на шаге 4: "Missing privilege separation directory"

**Причина:** на свежей Ubuntu 24.04 нет каталога `/run/sshd`.
**Решение:** уже исправлено в `setup.sh` (`mkdir -p /run/sshd`). Если используете старую версию скрипта — добавьте эту строку перед `sshd -t`.

### 2. Скрипт отработал, но IP в credentials — IPv6

**Причина:** `curl ifconfig.me` на dual-stack серверах может вернуть IPv6.
**Решение:** уже исправлено в `setup.sh` (`curl -4`). Если в выводе IPv6 — замените на реальный IPv4:
```python
creds = creds.replace('IPv6_АДРЕС', 'РЕАЛЬНЫЙ_IPv4')
```

### 3. SSH-подключение отвалилось после шага 4

**Что произошло:** скрипт сменил порт SSH на 59222 и отключил пароль.
**Что делать:**
- Если скрипт завершился успешно — подключаться по ключу на порт 59222
- Если скрипт упал на шаге 4 — подключаться по ключу на порт 22 (сервис ещё не перезапущен) или на порт 59222 (если перезапущен)
- Если ключ не сохранён — переустановить ОС на сервере и начать заново

### 4. `paramiko.ssh_exception.AuthenticationException`

Возможные причины:
- Сервер ещё не готов после переустановки ОС — подождать 30-60 секунд и попробовать снова
- Пароль неверный — уточнить у пользователя
- Пароль уже отключён (скрипт отработал) — использовать ключ

### 5. `PermissionError` при записи файла ключа на Windows

**Причина:** файл заблокирован предыдущим вызовом `icacls`.
**Решение:** записать ключ в файл с другим именем (`server_key_v2`).

### 6. Timeout при выполнении скрипта

Скрипт может работать 5-15 минут. Не прерывать! Основное время уходит на:
- `apt update && apt upgrade` — 1-3 мин
- `curl -fsSL https://get.docker.com | sh` — 1-2 мин
- Скачивание Docker-образов (3x-ui ~60MB, hysteria2 ~15MB, mtg ~10MB) — 1-5 мин

## Двухфазное подключение

Скрипт `setup.sh` на шаге 4 **меняет порт SSH и отключает парольную авторизацию**. Это значит:

- **Фаза 1** (до запуска скрипта): подключение по паролю на порт 22
- **Фаза 2** (после завершения): подключение по ключу на порт 59222

Между фазами нужно:
1. Распарсить вывод скрипта и извлечь SSH-ключ
2. Или скачать ключ через SFTP (пока соединение фазы 1 ещё активно)

Оптимальный подход:
1. Подключиться по паролю (порт 22)
2. Загрузить и запустить `setup.sh`
3. Дождаться завершения — соединение может разорваться (порт сменился), это нормально
4. Скачать ключ: подключиться по паролю на порт 22 (если sshd ещё не перезапущен) или по ключу на 59222
5. Далее работать по ключу на 59222

## Что НЕ надо делать

- **НЕ** запускать скрипт повторно на уже настроенном сервере — он не идемпотентный
- **НЕ** менять `setup.sh` на сервере — всегда загружать свежую версию из репозитория
- **НЕ** пытаться подключиться по паролю после завершения скрипта — пароль отключён
- **НЕ** прерывать скрипт во время выполнения — может оставить сервер в несогласованном состоянии
- **НЕ** запускать `icacls` повторно на тот же файл ключа
- **НЕ** использовать `ssh.exec_command()` для долгих команд — использовать `channel` с потоковым чтением
