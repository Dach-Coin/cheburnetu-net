#!/usr/bin/env python3
"""Phase 1: Connect to server, upload setup.sh, run it with streaming output."""
import sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

import configparser
import paramiko
import time
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(SCRIPT_DIR, 'deploy_config.ini')

# --- Load config ---
if not os.path.exists(CONFIG_PATH):
    print(f"[ERROR] Config not found: {CONFIG_PATH}")
    print("  Copy deploy_config.example.ini -> deploy_config.ini and fill in your data")
    sys.exit(1)

config = configparser.ConfigParser()
config.read(CONFIG_PATH, encoding='utf-8')

SERVER_IP = config.get('server', 'ip')
SSH_PORT = config.getint('server', 'ssh_port')
USERNAME = config.get('server', 'username')
PASSWORD = config.get('server', 'password')

LOCAL_SETUP = os.path.join(SCRIPT_DIR, 'setup.sh')

# --- Phase 1: Connect and run setup.sh ---
print(f"[1] Connecting to {SERVER_IP}:{SSH_PORT} ...")
ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect(SERVER_IP, port=SSH_PORT, username=USERNAME, password=PASSWORD, timeout=15)
print("[1] Connected OK")

# Upload setup.sh via SFTP
print(f"[2] Uploading setup.sh -> /root/setup.sh ...")
sftp = ssh.open_sftp()
sftp.put(LOCAL_SETUP, '/root/setup.sh')
sftp.chmod('/root/setup.sh', 0o755)
sftp.close()
print("[2] Upload OK")

# Run setup.sh with streaming output
print("[3] Running setup.sh (this takes 5-15 minutes) ...")
print("=" * 70)

transport = ssh.get_transport()
channel = transport.open_session()
channel.set_combine_stderr(True)
channel.settimeout(900)  # 15 minutes max
channel.exec_command('bash /root/setup.sh 2>&1')

full_output = []
while True:
    if channel.recv_ready():
        data = channel.recv(8192)
        if not data:
            break
        text = data.decode('utf-8', errors='replace')
        full_output.append(text)
        print(text, end='', flush=True)
    elif channel.exit_status_ready():
        # Drain remaining data
        while channel.recv_ready():
            data = channel.recv(8192)
            text = data.decode('utf-8', errors='replace')
            full_output.append(text)
            print(text, end='', flush=True)
        break
    else:
        time.sleep(0.5)

exit_code = channel.recv_exit_status()
print("=" * 70)
print(f"[3] setup.sh exit code: {exit_code}")

if exit_code != 0:
    print("[ERROR] setup.sh failed!")
    ssh.close()
    sys.exit(1)

print("[3] setup.sh completed successfully!")

# --- Phase 2: Download credentials and key via SFTP ---
print("[4] Downloading credentials and SSH key ...")

creds_dir = os.path.join(SCRIPT_DIR, 'creds')
os.makedirs(creds_dir, exist_ok=True)

try:
    sftp = ssh.open_sftp()
    sftp.get('/root/.ssh/id_admin', os.path.join(creds_dir, 'server_key'))
    print("[4] Downloaded server_key")
    sftp.get('/root/vpn_credentials.txt', os.path.join(creds_dir, 'credentials.txt'))
    print("[4] Downloaded credentials.txt")
    sftp.close()
except Exception as e:
    print(f"[4] SFTP download failed on existing connection: {e}")
    print("[4] Attempting new connection on port 22 with password...")
    ssh.close()
    try:
        ssh2 = paramiko.SSHClient()
        ssh2.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        ssh2.connect(SERVER_IP, port=SSH_PORT, username=USERNAME, password=PASSWORD, timeout=15)
        sftp = ssh2.open_sftp()
        sftp.get('/root/.ssh/id_admin', os.path.join(creds_dir, 'server_key'))
        print("[4] Downloaded server_key (via reconnect)")
        sftp.get('/root/vpn_credentials.txt', os.path.join(creds_dir, 'credentials.txt'))
        print("[4] Downloaded credentials.txt (via reconnect)")
        sftp.close()
        ssh2.close()
    except Exception as e2:
        print(f"[4] Reconnect also failed: {e2}")
        print("[4] Will try key-based connection on port 59222 later")

ssh.close()
print("[DONE] Phase 1 complete")
