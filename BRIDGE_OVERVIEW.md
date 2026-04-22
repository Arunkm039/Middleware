# Bridge — System Overview

NetSuite ↔ Bank SFTP middleware. Moves files between NetSuite and one or more bank SFTP servers, with a web dashboard, audit trail, and duplicate detection.

---

## Architecture

```
NetSuite SFTP  ←──────────────────────────────→  Bank SFTP(s)
                          │
                    bridge.py (FastAPI)
                          │
                    PostgreSQL (audit DB)
                          │
                    data/ (local file store)
```

- Single Python file (`bridge.py`) — FastAPI + asyncssh + asyncio
- Nginx terminates TLS, proxies to bridge on `127.0.0.1:8000`
- Runs as a systemd service on OCI (1 vCPU / 8 GB)

---

## Directory Structure

```
bridge/
├── bridge.py               # Full application
├── requirements.txt
├── templates/
│   ├── dashboard.html
│   ├── login.html
│   ├── mfa_setup.html
│   └── mfa_verify.html
└── data/
    ├── staging/            # Files in-flight (temp)
    ├── upload_staging/     # Manual uploads (temp)
    ├── processed/          # Permanent archive of all completed transfers
    ├── error/              # Abandoned transfers (manual review)
    ├── ACK/                # Copy of successfully transferred files
    │   └── <date>/<bank>/<account>/<direction>/<tid>_<filename>
    ├── NACK/               # Copy of files that failed to transfer
    │   └── <date>/<bank>/<account>/<direction>/<tid>_<filename>
    ├── netsuite/           # Local-mode NS mirror (dev/test only)
    └── banks/              # Local-mode bank mirror (dev/test only)
```

---

## File Flow

```
1. Poll  →  file detected on source SFTP
2. Stage →  downloaded to data/staging/
3. Hash  →  SHA-256 + content SHA-256 computed
4. Dedup →  PostgreSQL advisory lock checks for duplicate
5. Transfer → uploaded to destination SFTP
6. Archive → copied to data/processed/
7. ACK/NACK → copy written to data/ACK/ or data/NACK/
```

**Directions:**
- `outbound` — NetSuite → Bank SFTP
- `inbound`  — Bank SFTP → NetSuite

---

## Key Components

| Component | Purpose |
|---|---|
| `process_file()` | Core pipeline: hash → dedup → deliver → archive |
| `write_ack()` | Copies delivered file to `data/ACK/` |
| `write_nack()` | Copies failed file to `data/NACK/` |
| `retry_transfer()` | Re-attempts a failed transfer from staged file |
| `_deliver()` | SFTP put (or local copy in dev mode) |
| `_staging_cleanup_loop()` | Hourly: removes orphaned staging files > 48h |
| `/api/folders` | Dashboard folder browser endpoint |

**Multi-bank config:** Set `BANKS_JSON` env var to a JSON array — each entry has `id`, `host`, `port`, `user`, `pass`, `key`, `accounts[]`.

---

## File Formats

| Direction | Format | Notes |
|---|---|---|
| NetSuite → Bank | CSV | Standard payment file |
| Bank → NetSuite | MT940 | Bank statement format |

No code changes needed — bridge transfers files as-is.

---

## OCI Production Setup

### 1. Prerequisites
- OCI VM (1 vCPU / 8 GB), Ubuntu 24.04
- Reserved public IP mapped to your domain
- Ports open: 22 (SSH), 80 (HTTP→redirect), 443 (HTTPS)

### 2. System packages
```bash
sudo apt update && sudo apt install -y python3-venv python3-pip postgresql nginx certbot python3-certbot-nginx
```

### 3. PostgreSQL
```bash
sudo -u postgres psql -c "CREATE USER bridge WITH PASSWORD 'strongpassword';"
sudo -u postgres psql -c "CREATE DATABASE bridge OWNER bridge;"
```

### 4. App setup
```bash
cd /opt && sudo mkdir bridge && sudo chown $USER:$USER bridge
git clone <repo> bridge && cd bridge
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
```

### 5. Environment — `/opt/bridge/.env`
```env
MODE=sftp
SESSION_SECRET=<generate: python3 -c "import secrets;print(secrets.token_hex(32))">
SESSION_HTTPS_ONLY=true
BIND_HOST=127.0.0.1

# PostgreSQL
PG_HOST=localhost
PG_DB=bridge
PG_USER=bridge
PG_PASS=strongpassword

# NetSuite SFTP
NS_HOST=<netsuite-sftp-host>
NS_PORT=22
NS_USER=<user>
NS_PASS=<pass>
NS_OUTBOUND_DIR=/outbound
NS_INBOUND_DIR=/inbound

# Banks (multi-bank JSON)
BANKS_JSON=[{"id":"bank1","host":"sftp.bank.com","port":22,"user":"u","pass":"p","inbound_dir":"/inbound","accounts":[{"id":"acc1"}]}]

# Alerts (optional)
SMTP_USER=alerts@yourdomain.com
SMTP_PASS=<pass>
ALERT_TO=ops@yourdomain.com

# Tuning
POLL_SECONDS=30
MAX_FILES_PER_CYCLE=50
MAX_UPLOAD_BYTES=20971520
MAX_CONCURRENT_SFTP=2
STAGING_MAX_AGE_HOURS=48
```

### 6. systemd — `/etc/systemd/system/bridge.service`
```ini
[Unit]
Description=Bridge SFTP Middleware
After=network.target postgresql.service

[Service]
User=ubuntu
WorkingDirectory=/opt/bridge
EnvironmentFile=/opt/bridge/.env
ExecStart=/opt/bridge/venv/bin/python bridge.py
Restart=always
RestartSec=5
MemoryMax=512M
ProtectSystem=strict
NoNewPrivileges=true
ReadWritePaths=/opt/bridge/data

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now bridge
```

### 7. Nginx — `/etc/nginx/sites-available/bridge`
```nginx
server {
    listen 80;
    server_name your.domain.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name your.domain.com;

    ssl_certificate     /etc/letsencrypt/live/your.domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/your.domain.com/privkey.pem;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;

    location /login {
        limit_req zone=login burst=5 nodelay;
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        client_max_body_size 25M;
    }
}
```
Add to `nginx.conf` http block: `limit_req_zone $binary_remote_addr zone=login:10m rate=10r/m;`

```bash
sudo ln -s /etc/nginx/sites-available/bridge /etc/nginx/sites-enabled/
sudo certbot --nginx -d your.domain.com
sudo systemctl reload nginx
```

---

## Security Features

| Feature | Detail |
|---|---|
| Auth | bcrypt passwords + TOTP/MFA (mandatory per user) |
| Sessions | Starlette SessionMiddleware, SameSite=strict, HTTPS-only |
| Rate limiting | Login: 5 attempts → 5-min lockout; MFA: same |
| Duplicate detection | SHA-256 + content SHA-256 + PostgreSQL advisory lock |
| Path traversal | `_safe_id()` sanitizes bank/account IDs; `Path().name` on remote filenames |
| Open redirect | `_safe_next_url()` validates redirect targets |
| SFTP MITM | known_hosts verification |
| OS hardening | systemd `ProtectSystem`, `NoNewPrivileges`, `MemoryMax` |

---

## Dashboard

Access: `https://your.domain.com` — requires login + MFA.

| Feature | Description |
|---|---|
| Transfer table | Live list of all transfers with status, retries, errors |
| Retry / Abandon | Admin can retry failed transfers or move to `data/error/` |
| Upload | Manual file inject into the pipeline |
| 📁 Folders | Browse ACK / NACK / processed / error folder trees |
| Users (admin) | Create/delete users, reset passwords |
| Health indicator | PostgreSQL connectivity shown in header |

---

## Default Credentials

First run creates no users automatically. Set via env or create on first login prompt.

```env
ADMIN_USER=admin
ADMIN_PASS=<set a strong password>
```

Change immediately after first login. All users must enroll MFA on first login.

---

## Health Check

```bash
curl https://your.domain.com/api/health
# {"status":"ok","postgres":true}

sudo systemctl status bridge
sudo journalctl -u bridge -f
```
