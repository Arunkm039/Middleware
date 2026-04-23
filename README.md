# Bridge — Production System Overview

NetSuite ↔ Bank SFTP middleware. Moves payment files (CSV) and bank statements (MT940) between NetSuite and one or more bank SFTP servers, with a web dashboard, audit trail, and duplicate detection.

---

## Architecture

```
[NetSuite SFTP]                        [Bank SFTP(s)]
  (client-managed)                    (bank-managed)
       │                                     │
       │  SSH/SFTP (outbound: push CSV)       │
       │  SSH/SFTP (inbound: pull MT940)      │
       └──────────────┬──────────────────────┘
                      │
              [OCI VM — Ubuntu 24.04]
              ┌───────────────────────┐
              │  nginx (443/TLS)      │
              │  ↓                   │
              │  bridge.py (FastAPI)  │
              │  ↓                   │
              │  PostgreSQL (local)   │
              │  ↓                   │
              │  data/ (file store)   │
              └───────────────────────┘
                      │
              [Operator browser — HTTPS dashboard]
```

**Components:**
- `bridge.py` — single-file FastAPI app, asyncssh, asyncio event loop
- PostgreSQL — audit DB (transfers, logs, users); runs on same VM
- nginx — TLS terminator, reverse proxy, rate limiter
- systemd — service supervisor with OS-level sandboxing

---

## File Formats

| Direction | Format | Flow |
|---|---|---|
| NetSuite → Bank | CSV | Payment instruction file |
| Bank → NetSuite | MT940 | Bank statement |

Bridge transfers files byte-for-byte — no parsing or transformation.

---

## File Flow (per transfer)

```
1. Poll       SFTP source polled every 30s
2. Download   File saved to data/staging/<uuid>
3. Hash       SHA-256 + content SHA-256 computed
4. Dedup      PostgreSQL advisory lock — duplicate blocked & alerted
5. Deliver    File uploaded to destination SFTP
6. Archive    Copied to data/processed/<date>/<bank>/<account>/<direction>/
7. ACK/NACK   Actual file copied to data/ACK/ (success) or data/NACK/ (failure)
8. Cleanup    Staging copy removed; orphaned files purged hourly
```

---

## Directory Structure

```
/opt/bridge/
├── bridge.py
├── requirements.txt
├── .env                          # secrets & config (chmod 600)
├── templates/
│   ├── dashboard.html
│   ├── login.html
│   ├── mfa_setup.html
│   └── mfa_verify.html
└── data/
    ├── staging/                  # in-flight temp files
    ├── upload_staging/           # manual upload temp
    ├── processed/                # permanent archive
    │   └── <date>/<bank>/<account>/<direction>/<filename>
    ├── error/                    # abandoned transfers (manual review)
    ├── ACK/                      # copy of successfully transferred files
    │   └── <date>/<bank>/<account>/<direction>/<tid>_<filename>
    └── NACK/                     # copy of failed transfer files
        └── <date>/<bank>/<account>/<direction>/<tid>_<filename>
```

---

## Production Setup — Step by Step

### Step 1 — OCI Console (before touching the server)

1. Ensure VM has a **Reserved Public IP** attached (Networking → Reserved IPs).
2. Open OCI **Security List** (or NSG) ingress rules:
   - Port 22 — SSH (restrict to your office IP if possible)
   - Port 80 — HTTP (nginx redirect only)
   - Port 443 — HTTPS (public)
   - Block everything else inbound
3. Map your domain to the reserved IP via an **A record** in your DNS provider.
4. Wait for DNS propagation before running certbot (`dig your.domain.com` to verify).

---

### Step 2 — OS Hardening (Ubuntu 24.04)

SSH in as `ubuntu` then run all of the following.

#### 2a. System updates
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades   # enable auto security patches
```

#### 2b. Firewall (ufw)
```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw allow 80/tcp comment 'HTTP→redirect'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable
sudo ufw status
```

#### 2c. Harden SSH
Edit `/etc/ssh/sshd_config`:
```
PermitRootLogin no
PasswordAuthentication no        # key-only login
X11Forwarding no
AllowUsers ubuntu
MaxAuthTries 3
```
```bash
sudo systemctl restart ssh
```

#### 2d. Dedicated app user
```bash
sudo useradd -r -m -s /bin/bash -d /opt/bridge bridge
sudo passwd -l bridge            # disable password login
```

#### 2e. Kernel / sysctl hardening
Create `/etc/sysctl.d/99-bridge.conf`:
```
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
kernel.dmesg_restrict = 1
```
```bash
sudo sysctl --system
```

---

### Step 3 — Install Required Packages

```bash
sudo apt install -y python3-venv python3-pip postgresql postgresql-contrib \
    nginx certbot python3-certbot-nginx fail2ban
```

---

### Step 4 — PostgreSQL Setup

```bash
sudo systemctl enable --now postgresql

# Create DB user and database
sudo -u postgres psql <<EOF
CREATE USER bridge WITH PASSWORD 'STRONG_DB_PASSWORD_HERE';
CREATE DATABASE bridge OWNER bridge;
REVOKE ALL ON DATABASE bridge FROM PUBLIC;
EOF
```

#### Harden PostgreSQL
Edit `/etc/postgresql/16/main/pg_hba.conf` — ensure only local connections:
```
local   bridge   bridge   md5
host    bridge   bridge   127.0.0.1/32   md5
```
Edit `/etc/postgresql/16/main/postgresql.conf`:
```
listen_addresses = 'localhost'    # never expose externally
```
```bash
sudo systemctl restart postgresql
```

---

### Step 5 — Deploy the App

```bash
sudo mkdir -p /opt/bridge
sudo chown bridge:bridge /opt/bridge

# Copy files to server (from your machine)
scp -r bridge/ ubuntu@<your-ip>:/tmp/bridge-deploy
sudo cp -r /tmp/bridge-deploy/* /opt/bridge/
sudo chown -R bridge:bridge /opt/bridge

# Create virtualenv and install deps
sudo -u bridge bash -c "
  cd /opt/bridge
  python3 -m venv venv
  source venv/bin/activate
  pip install --upgrade pip
  pip install -r requirements.txt
"

# Create data directories
sudo -u bridge mkdir -p /opt/bridge/data/{staging,upload_staging,processed,error,ACK,NACK}
```

---

### Step 6 — Environment Configuration

Create `/opt/bridge/.env` (as root, then lock it down):

```bash
sudo -u bridge tee /opt/bridge/.env > /dev/null <<'EOF'
MODE=sftp
BIND_HOST=127.0.0.1
SESSION_HTTPS_ONLY=true

# Generate once: python3 -c "import secrets; print(secrets.token_hex(32))"
SESSION_SECRET=REPLACE_WITH_GENERATED_SECRET

# Admin account (change immediately after first login)
ADMIN_USER=admin
ADMIN_PASS=REPLACE_WITH_STRONG_PASSWORD

# PostgreSQL
PG_HOST=localhost
PG_DB=bridge
PG_USER=bridge
PG_PASS=STRONG_DB_PASSWORD_HERE

# NetSuite SFTP (credentials from NetSuite admin)
NS_HOST=sftp.netsuite-instance.com
NS_PORT=22
NS_USER=ns_sftp_user
NS_PASS=ns_sftp_password
# OR use key: NS_KEY=/opt/bridge/keys/netsuite_rsa
NS_OUTBOUND_DIR=/outbound
NS_INBOUND_DIR=/inbound

# Banks — one entry per bank (add more objects for multiple banks)
BANKS_JSON=[
  {
    "id": "bank1",
    "host": "sftp.bank1.com",
    "port": 22,
    "user": "bank_sftp_user",
    "pass": "bank_sftp_password",
    "inbound_dir": "/incoming",
    "accounts": [
      {"id": "acc001", "inbound_dir": "/incoming/acc001"}
    ]
  }
]

# Email alerts (optional but recommended)
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=alerts@yourdomain.com
SMTP_PASS=app_password_here
ALERT_TO=ops@yourdomain.com

# Known hosts for SFTP MITM prevention
# Generate: ssh-keyscan -p 22 sftp.bank1.com >> /opt/bridge/known_hosts
SFTP_KNOWN_HOSTS=/opt/bridge/known_hosts

# Tuning (suitable for 1 vCPU / 8 GB)
POLL_SECONDS=30
MAX_FILES_PER_CYCLE=50
MAX_UPLOAD_BYTES=20971520
MAX_CONCURRENT_SFTP=2
STAGING_MAX_AGE_HOURS=48
EOF

sudo chmod 600 /opt/bridge/.env
sudo chown bridge:bridge /opt/bridge/.env
```

---

### Step 7 — SFTP Key Authentication (recommended over password)

Using SSH keys is more secure than passwords for SFTP connections.

```bash
sudo -u bridge mkdir -p /opt/bridge/keys && chmod 700 /opt/bridge/keys

# Generate a key pair for NetSuite connection
sudo -u bridge ssh-keygen -t ed25519 -f /opt/bridge/keys/netsuite_rsa -N ""

# Show the public key — give this to the NetSuite admin to authorize
cat /opt/bridge/keys/netsuite_rsa.pub

# Repeat for each bank
sudo -u bridge ssh-keygen -t ed25519 -f /opt/bridge/keys/bank1_rsa -N ""
cat /opt/bridge/keys/bank1_rsa.pub
```

Update `.env`:
```env
NS_KEY=/opt/bridge/keys/netsuite_rsa
# In BANKS_JSON add: "key": "/opt/bridge/keys/bank1_rsa"
```

#### Capture known_hosts (MITM prevention)
```bash
# Run once per SFTP host — verifies the server fingerprint
sudo -u bridge ssh-keyscan -p 22 sftp.netsuite-instance.com >> /opt/bridge/known_hosts
sudo -u bridge ssh-keyscan -p 22 sftp.bank1.com >> /opt/bridge/known_hosts
chmod 600 /opt/bridge/known_hosts
```

---

### Step 8 — systemd Service

Create `/etc/systemd/system/bridge.service`:

```ini
[Unit]
Description=Bridge SFTP Middleware
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=bridge
Group=bridge
WorkingDirectory=/opt/bridge
EnvironmentFile=/opt/bridge/.env
ExecStart=/opt/bridge/venv/bin/python bridge.py
Restart=on-failure
RestartSec=10
TimeoutStopSec=30

# Resource limits
MemoryMax=512M
CPUQuota=90%

# OS hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/opt/bridge/data /opt/bridge/keys

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=bridge

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable bridge
sudo systemctl start bridge
sudo systemctl status bridge
# Check logs
sudo journalctl -u bridge -f
```

---

### Step 9 — nginx + TLS

#### 9a. Site config — `/etc/nginx/sites-available/bridge`

```nginx
# Rate limiting zone (add inside the http{} block of /etc/nginx/nginx.conf)
# limit_req_zone $binary_remote_addr zone=login:10m rate=10r/m;

server {
    listen 80;
    server_name your.domain.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name your.domain.com;

    ssl_certificate     /etc/letsencrypt/live/your.domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/your.domain.com/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'" always;

    # Login endpoint — rate limited
    location /login {
        limit_req zone=login burst=5 nodelay;
        proxy_pass         http://127.0.0.1:8000;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }

    # All other routes
    location / {
        proxy_pass         http://127.0.0.1:8000;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
        client_max_body_size 25M;
    }
}
```

#### 9b. Enable and get TLS certificate

```bash
# Add rate limit zone to nginx.conf http block
sudo sed -i '/http {/a\    limit_req_zone $binary_remote_addr zone=login:10m rate=10r/m;' /etc/nginx/nginx.conf

sudo ln -s /etc/nginx/sites-available/bridge /etc/nginx/sites-enabled/
sudo nginx -t                          # verify config
sudo systemctl reload nginx

# Get Let's Encrypt certificate
sudo certbot --nginx -d your.domain.com --non-interactive --agree-tos -m admin@yourdomain.com

# Auto-renewal (certbot installs a timer — verify it)
sudo systemctl status certbot.timer
```

---

### Step 10 — fail2ban (brute-force protection at OS level)

Create `/etc/fail2ban/jail.d/bridge.conf`:

```ini
[bridge-login]
enabled  = true
port     = 443
filter   = bridge-login
logpath  = /var/log/nginx/access.log
maxretry = 10
bantime  = 600
findtime = 300

[sshd]
enabled  = true
maxretry = 5
bantime  = 3600
```

Create `/etc/fail2ban/filter.d/bridge-login.conf`:
```ini
[Definition]
failregex = ^<HOST> .* "POST /login HTTP.*" 401
```

```bash
sudo systemctl enable --now fail2ban
sudo fail2ban-client status
```

---

### Step 11 — First Login & User Setup

1. Open `https://your.domain.com` in browser
2. Log in with `ADMIN_USER` / `ADMIN_PASS` from `.env`
3. Complete MFA enrollment (scan QR code with Google Authenticator / Authy)
4. Go to **👥 Users** → create named operator accounts (avoid sharing the admin account)
5. Each new user will enroll their own MFA on first login
6. Optionally disable the `admin` env-var account once a personal admin user is created

---

## Integration Details

### Bridge ↔ NetSuite

| Parameter | Detail |
|---|---|
| Protocol | SFTP (SSH port 22) |
| Auth | SSH key (preferred) or password |
| Outbound dir | `/outbound` — bridge polls this, picks up CSV files |
| Inbound dir | `/inbound` — bridge pushes MT940 files here |
| Folder segregation | Enabled by default: `/inbound/<bank_id>/<account_id>/` |
| Credentials | Obtain from NetSuite admin; provide bridge's public key to authorize |
| Firewall | NetSuite SFTP server must allow inbound from OCI reserved IP |

**What to tell NetSuite admin:**
> "Allow SFTP connections from IP `<your reserved OCI IP>`. Authorize the public key below for user `<ns_sftp_user>`. Drop payment CSV files into `/outbound`. Bridge will deliver MT940 statements to `/inbound/<bank_id>/`."

---

### Bridge ↔ Bank SFTP

| Parameter | Detail |
|---|---|
| Protocol | SFTP (SSH port 22) |
| Auth | SSH key (preferred) or password |
| Inbound dir | Bank's incoming folder — bridge pushes CSV payments here |
| Outbound dir | Bank's outgoing folder — bridge polls for MT940 statements |
| known_hosts | Capture bank server fingerprint before going live (Step 7) |
| Credentials | Obtain from bank's technical team |
| Firewall | Bank SFTP must allow inbound from OCI reserved IP |

**What to tell the bank's technical team:**
> "Allow SFTP connections from IP `<your reserved OCI IP>`. Authorize the public key below for user `<bank_sftp_user>`. We will push payment files to `<inbound_dir>` and pull statements from `<outbound_dir>`."

---

### Communication Flow (end-to-end)

```
[NetSuite drops payment.csv in /outbound]
          │
          │  Bridge polls every 30s
          ▼
[Bridge downloads payment.csv → data/staging/]
          │
          │  Hash + dedup check
          ▼
[Bridge pushes payment.csv → Bank SFTP /incoming]
          │
          │  On success
          ▼
[ACK copy → data/ACK/2026-04-23/bank1/acc001/outbound/42_payment.csv]
[Archive  → data/processed/...]
[DB record updated → status=sent]
          │
          │  (later) Bank drops statement.mt940 in /outgoing
          ▼
[Bridge polls Bank SFTP → downloads statement.mt940]
          │
          ▼
[Bridge pushes statement.mt940 → NetSuite SFTP /inbound/bank1/]
          │
          ▼
[ACK copy → data/ACK/.../inbound/43_statement.mt940]
[DB record updated → status=received]
```

---

## Security Features Summary

| Layer | Measure |
|---|---|
| OS | ufw firewall, SSH key-only, fail2ban, auto security updates |
| App auth | bcrypt passwords + mandatory TOTP/MFA |
| Sessions | SameSite=strict, HTTPS-only cookies, server-side session |
| Rate limiting | nginx (10 req/min on /login) + app-level (5 attempts → 5-min lockout) |
| SFTP | SSH key auth, known_hosts MITM prevention |
| Duplicate detection | SHA-256 + content SHA-256 + PostgreSQL advisory lock |
| Path traversal | `_safe_id()` on all bank/account IDs; `Path().name` on remote filenames |
| Secrets | `.env` chmod 600, owned by `bridge` user |
| Process isolation | systemd `ProtectSystem`, `NoNewPrivileges`, `PrivateTmp`, `MemoryMax` |
| TLS | Let's Encrypt, TLS 1.2/1.3 only, HSTS, CSP headers |
| DB | PostgreSQL localhost-only, dedicated low-privilege user |

---

## Dashboard

Access: `https://your.domain.com`

| Feature | Description |
|---|---|
| Transfer table | Live list with status, retries, errors — auto-refreshes every 3s |
| Retry / Abandon | Admin retries failed transfers or moves file to `data/error/` |
| Upload | Manual file inject into the pipeline |
| 📁 Folders | Browse ACK / NACK / processed / error folder trees |
| Users (admin) | Create/delete users, reset passwords, view MFA status |
| Health indicator | PostgreSQL status shown in header |

---

## Operational Checks

```bash
# Service status
sudo systemctl status bridge
sudo journalctl -u bridge -f --since "1 hour ago"

# API health
curl -s https://your.domain.com/api/health
# → {"status":"ok","postgres":true}

# PostgreSQL
sudo -u postgres psql -c "SELECT count(*) FROM transfers;" bridge

# Disk usage
du -sh /opt/bridge/data/*/

# Firewall
sudo ufw status verbose

# fail2ban
sudo fail2ban-client status bridge-login

# TLS cert expiry
sudo certbot certificates
```

---

## Maintenance

| Task | Command |
|---|---|
| View live logs | `sudo journalctl -u bridge -f` |
| Restart service | `sudo systemctl restart bridge` |
| Deploy update | Copy new `bridge.py` → `sudo systemctl restart bridge` |
| Renew TLS cert | Auto — verify with `sudo systemctl status certbot.timer` |
| DB backup | `pg_dump -U bridge bridge > bridge_$(date +%F).sql` |
| Clear old ACK/NACK | `find /opt/bridge/data/ACK -mtime +90 -delete` |
