# Bridge — Quick Reference

NetSuite ↔ Bank SFTP middleware. Transfers CSV (NS→Bank) and MT940 (Bank→NS) files. FastAPI + asyncssh + PostgreSQL. Runs as a systemd service behind nginx on OCI Ubuntu 24.04.

---

## Core Functionalities

| Feature | Description |
|---|---|
| Multi-bank / multi-account | Each bank/account has isolated folders, DB records, SFTP connections |
| Duplicate detection | SHA-256 + content hash + PostgreSQL advisory lock |
| ACK / NACK | Actual file copied to `data/ACK/` on success, `data/NACK/` on failure |
| NACK → ACK promotion | On retry success, NACK copy is automatically removed, ACK copy written |
| Folder browser | Dashboard panel to browse ACK / NACK / processed / error trees |
| Bank config UI | Add/edit/delete bank SFTP details from dashboard — no `.env` editing |
| NS SFTP server mode | Bridge acts as SFTP server; NetSuite connects IN with username+password |
| Manual upload | Inject files directly into the pipeline from dashboard |
| Retry / Abandon | Admin retries failed transfers or moves file to `data/error/` |
| MFA | TOTP mandatory for all users on first login |

---

## File Flow

```
Source SFTP / local dir
  → data/staging/          (download)
  → hash + dedup check
  → destination SFTP / local dir
  → data/processed/        (archive)
  → data/ACK/              (success copy)  OR  data/NACK/  (failure copy)
```

**Directions:** `outbound` = NS → Bank · `inbound` = Bank → NS

---

## Directory Layout

```
data/
├── ACK/        <date>/<bank>/<account>/<direction>/<tid>_<file>
├── NACK/       <date>/<bank>/<account>/<direction>/<tid>_<file>
├── processed/  permanent archive
├── error/      abandoned transfers
├── staging/    in-flight temp
├── netsuite/   <bank>/<account>/outbound|inbound  (local/server mode)
└── banks/      <bank>/<account>/outbound|inbound  (local mode)
```

---

## Modes

| `BRIDGE_MODE` | `NS_SFTP_SERVER_MODE` | NS side | Bank side |
|---|---|---|---|
| `local` | false | Watch local dirs | Copy to local dirs |
| `sftp` | false | Bridge dials out to NS SFTP | Bridge dials out to bank SFTP |
| `sftp` | **true** | NetSuite connects IN to bridge | Bridge dials out to bank SFTP |

---

## Environment Variables

```env
# Core
BRIDGE_MODE=sftp                     # sftp | local
NS_SFTP_SERVER_MODE=false            # true = bridge is SFTP server for NetSuite
BIND_HOST=127.0.0.1                  # 0.0.0.0 if no nginx
SESSION_SECRET=<token_hex_32>
SESSION_HTTPS_ONLY=true

# Admin
ADMIN_USER=admin
ADMIN_PASS=<strong_password>

# PostgreSQL
PG_HOST=localhost
PG_DB=bridge
PG_USER=bridge
PG_PASS=<password>

# NetSuite SFTP (only when NS_SFTP_SERVER_MODE=false)
NS_HOST=sftp.netsuite.com
NS_PORT=22
NS_USER=<username>
NS_PASS=<password>          # or use NS_KEY
NS_KEY=/opt/bridge/keys/netsuite_rsa
NS_OUTBOUND_DIR=/outbound
NS_INBOUND_DIR=/inbound

# Banks — defined via dashboard (data/banks_config.json) or env fallback
BANKS_JSON=[{"id":"bank1","host":"sftp.bank.com","port":22,"user":"u","pass":"p",
             "inbound_dir":"/incoming","outbound_dir":"/outgoing",
             "accounts":[{"id":"acc001","inbound_dir":"/incoming/acc001"}]}]

# Tuning
POLL_SECONDS=30
MAX_FILES_PER_CYCLE=50
MAX_UPLOAD_BYTES=20971520
MAX_CONCURRENT_SFTP=2
STAGING_MAX_AGE_HOURS=48
SFTP_KNOWN_HOSTS=/opt/bridge/known_hosts
```

---

## Production Setup (OCI Ubuntu 24.04)

### 1. OCI Console
- Attach reserved public IP to VM
- Security List ingress: TCP 22 (SSH), 80 (HTTP), 443 (HTTPS)
- Add DNS A record pointing domain to reserved IP

### 2. Server hardening
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3-venv postgresql nginx certbot python3-certbot-nginx fail2ban

# Firewall
sudo ufw default deny incoming && sudo ufw default allow outgoing
sudo ufw allow 22/tcp && sudo ufw allow 80/tcp && sudo ufw allow 443/tcp
sudo ufw enable

# SSH — edit /etc/ssh/sshd_config
PermitRootLogin no
PasswordAuthentication no
AllowUsers ubuntu
sudo systemctl restart ssh
```

### 3. PostgreSQL
```bash
sudo systemctl enable --now postgresql
sudo -u postgres psql -c "CREATE USER bridge WITH PASSWORD 'strong_pass';"
sudo -u postgres psql -c "CREATE DATABASE bridge OWNER bridge;"
# In pg_hba.conf: restrict to localhost only
# In postgresql.conf: listen_addresses = 'localhost'
```

### 4. Deploy app
```bash
sudo useradd -r -m -s /bin/bash -d /opt/bridge bridge
sudo mkdir -p /opt/bridge && sudo chown bridge:bridge /opt/bridge
# Copy files to /opt/bridge
sudo -u bridge bash -c "cd /opt/bridge && python3 -m venv venv && source venv/bin/activate && pip install -r requirements.txt"
sudo chmod 600 /opt/bridge/.env && sudo chown bridge:bridge /opt/bridge/.env
```

### 5. systemd `/etc/systemd/system/bridge.service`
```ini
[Unit]
Description=Bridge SFTP Middleware
After=network.target postgresql.service
Requires=postgresql.service

[Service]
User=bridge
WorkingDirectory=/opt/bridge
EnvironmentFile=/opt/bridge/.env
ExecStart=/opt/bridge/venv/bin/python bridge.py
Restart=on-failure
RestartSec=10
MemoryMax=512M
NoNewPrivileges=true
ProtectSystem=strict
PrivateTmp=true
ReadWritePaths=/opt/bridge/data /opt/bridge/keys

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload && sudo systemctl enable --now bridge
```

### 6. nginx + TLS
```bash
# /etc/nginx/sites-available/bridge
# Add to http{} in nginx.conf: limit_req_zone $binary_remote_addr zone=login:10m rate=10r/m;
sudo ln -s /etc/nginx/sites-available/bridge /etc/nginx/sites-enabled/
sudo certbot --nginx -d your.domain.com
sudo systemctl reload nginx
```

Nginx config essentials:
```nginx
server { listen 80; return 301 https://$host$request_uri; }
server {
    listen 443 ssl http2;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header Strict-Transport-Security "max-age=31536000" always;
    location /login { limit_req zone=login burst=5 nodelay; proxy_pass http://127.0.0.1:8000; }
    location / { proxy_pass http://127.0.0.1:8000; client_max_body_size 25M; }
}
```

---

## NS SFTP Server Mode Setup

Use when NetSuite connects IN to bridge instead of bridge dialling out.

### OS setup
```bash
# Create chroot SFTP user
sudo useradd -r -s /usr/sbin/nologin netsuite_sftp
sudo passwd netsuite_sftp          # give this password to NetSuite

# Chroot permissions
sudo chown root:root /opt/bridge/data/netsuite && sudo chmod 755 /opt/bridge/data/netsuite
sudo usermod -aG bridge netsuite_sftp

# After bridge starts and creates dirs:
sudo find /opt/bridge/data/netsuite -type d -exec chmod 775 {} \;
sudo find /opt/bridge/data/netsuite -type d -exec chgrp bridge {} \;
```

Add to end of `/etc/ssh/sshd_config`:
```
Match User netsuite_sftp
    ChrootDirectory /opt/bridge/data/netsuite
    ForceCommand internal-sftp
    AllowTcpForwarding no
    PasswordAuthentication yes
```
```bash
sudo sshd -t && sudo systemctl restart ssh
sudo ufw allow from <netsuite-ip> to any port 22
```

### bridge `.env`
```env
BRIDGE_MODE=sftp
NS_SFTP_SERVER_MODE=true
# Remove NS_HOST, NS_USER, NS_PASS, NS_KEY
```

### What to give NetSuite
```
Host:      your.bridge.domain.com
Port:      22
Username:  netsuite_sftp
Password:  <password set above>
Outbound:  /<bank_id>/<account_id>/outbound/   (NetSuite drops files here)
Inbound:   /<bank_id>/<account_id>/inbound/    (NetSuite picks files from here)
```

**No public key needed from NetSuite — password auth only.**

---

## Adding Banks

### Via dashboard (recommended)
1. Login as admin → click **🏦 Banks**
2. Click **+ Add Bank** → fill host, port, user, password, dirs, accounts
3. Save → bridge reloads within 30s, starts polling automatically
4. Config saved to `data/banks_config.json` (persists across restarts)

### Priority order on startup
```
data/banks_config.json  >  BANKS_JSON env var  >  BANK_* env vars
```

---

## Local Testing (single EC2)

```bash
# .env
BRIDGE_MODE=local
BANKS_JSON=[
  {"id":"bank1","host":"x","port":22,"user":"x","pass":"x","accounts":[{"id":"acc001"},{"id":"acc002"}]},
  {"id":"bank2","host":"x","port":22,"user":"x","pass":"x","accounts":[{"id":"current"},{"id":"payroll"}]},
  {"id":"bank3","host":"x","port":22,"user":"x","pass":"x"}
]
POLL_SECONDS=10
```

```bash
# Simulate NS → Bank (drop file into outbound)
echo "id,amount" > data/netsuite/bank1/acc001/outbound/test.csv
# Bridge picks up within 10s → delivers to data/banks/bank1/acc001/inbound/

# Simulate Bank → NS (drop MT940 for bridge to forward to NS)
echo ":20:STMT" > data/banks/bank1/acc001/outbound/stmt.mt940
# Bridge picks up → delivers to data/netsuite/bank1/acc001/inbound/
```

---

## Key Rules & Edge Cases

| Rule | Detail |
|---|---|
| NACK cleared on success | `_clear_nack_for(tid)` runs after every successful delivery |
| Duplicate blocked | Same SHA-256 OR same content SHA-256 — whichever fires first |
| Retry requires staged file | If staged file is gone, re-upload is needed |
| Bank ID in paths | Sanitized via `_safe_id()` — only `[a-zA-Z0-9_-]` allowed |
| Password on edit | Leave blank to keep existing — never wiped accidentally |
| New bank via dashboard | In local mode, restart bridge once to create outbound dirs |
| NS_SFTP_SERVER_MODE | Only controls bridge.py behaviour — SFTP server is OpenSSH, always independent |
| OCI port 22 blocked | Security List ingress rule required — ufw alone is not enough |
| Session expiry | Set `SESSION_SECRET` in `.env` — omitting causes sessions to reset on restart |

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Dashboard inaccessible | `BIND_HOST=0.0.0.0` if no nginx; `127.0.0.1` behind nginx |
| SFTP timeout from client | OCI Security List port 22 ingress rule missing |
| FileZilla timeout | Must use **SFTP protocol**, not FTP/FTPS |
| Bridge not picking up files | Check `BRIDGE_MODE`, `NS_SFTP_SERVER_MODE`, correct dir path |
| Duplicate blocked unexpectedly | Content SHA-256 match — file content identical even if name differs |
| Bank not polling after dashboard add | In sftp mode: starts next cycle (≤30s). In local mode: restart bridge once |
| NACK file not cleared after retry | Confirm retry succeeded — check dashboard status and ACK folder |
| PostgreSQL degraded in header | `sudo systemctl status postgresql` — check DB is running |

---

## Health & Operations

```bash
# Service
sudo systemctl status bridge
sudo journalctl -u bridge -f

# API health
curl -s https://your.domain.com/api/health
# → {"status":"ok","postgres":true}

# DB check
sudo -u postgres psql -c "SELECT id,bank_id,status FROM transfers ORDER BY id DESC LIMIT 10;" bridge

# Disk
du -sh /opt/bridge/data/*/

# TLS renewal
sudo systemctl status certbot.timer
```
