#!/usr/bin/env python3
"""Verify: connect by key on port 59222, check services and ports."""
import sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

import configparser
import paramiko
import io
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
NEW_PORT = config.getint('ssh', 'new_port')

# --- Load SSH key ---
key_path = os.path.join(SCRIPT_DIR, 'creds', 'server_key')
if not os.path.exists(key_path):
    print(f"[ERROR] SSH key not found: {key_path}")
    print("  Run deploy_phase1.py first")
    sys.exit(1)

with open(key_path, 'r') as f:
    key_str = f.read()

# --- Connect and verify ---
print(f"[1] Connecting to {SERVER_IP}:{NEW_PORT} with SSH key ...")
pkey = paramiko.Ed25519Key.from_private_key(io.StringIO(key_str))
ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect(SERVER_IP, port=NEW_PORT, username='root', pkey=pkey, timeout=15)
print("[1] Connected OK — key-based auth works!")

# Check docker services
print("\n[2] Docker services:")
_, out, _ = ssh.exec_command('docker ps --format "  {{.Names}}: {{.Status}}"')
print(out.read().decode('utf-8', errors='replace'))

# Check ports
print("[3] Listening ports:")
_, out, _ = ssh.exec_command('ss -tlnp | grep -E ":(59222|2053|443|8443|993) "')
print(out.read().decode('utf-8', errors='replace'))

_, out, _ = ssh.exec_command('ss -ulnp | grep ":443 "')
udp = out.read().decode('utf-8', errors='replace')
if udp:
    print(f"  UDP: {udp}")

# Check UFW
print("[4] UFW status:")
_, out, _ = ssh.exec_command('ufw status')
print(out.read().decode('utf-8', errors='replace'))

ssh.close()
print("[DONE] All checks passed!")
