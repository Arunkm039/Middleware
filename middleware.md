# Bridge — NetSuite ↔ Bank SFTP Middleware

> A secure, self-hosted middleware that automatically moves payment files between NetSuite and your bank's SFTP server, with a web dashboard, full audit trail, and duplicate detection.

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [How It Works — Plain English](#2-how-it-works--plain-english)
3. [Technologies Used](#3-technologies-used)
4. [Folder Structure](#4-folder-structure)
5. [Prerequisites](#5-prerequisites)
6. [Local Setup (Development)](#6-local-setup-development)
7. [Environment Variables](#7-environment-variables)
8. [Production Deployment](#8-production-deployment)
9. [First Login and User Setup](#9-first-login-and-user-setup)
10. [Features and Functionality](#10-features-and-functionality)
11. [API Reference](#11-api-reference)
12. [Architecture Deep Dive](#12-architecture-deep-dive)
13. [Data Flow Walkthrough](#13-data-flow-walkthrough)
14. [Configuration and Customization](#14-configuration-and-customization)
15. [Adding a New Bank](#15-adding-a-new-bank)
16. [PGP Encryption Support](#16-pgp-encryption-support)
17. [Troubleshooting](#17-troubleshooting)
18. [Security Notes](#18-security-notes)
19. [Best Practices for Beginners](#19-best-practices-for-beginners)
20. [Maintenance Reference](#20-maintenance-reference)
21. [Assumptions / Information Needed](#21-assumptions--information-needed)

---

## 1. Project Overview

### What is Bridge?

Bridge is a **file-transfer relay server**. It sits between two systems that need to exchange financial files but cannot connect to each other directly:

- **NetSuite** — a cloud ERP (accounting/business) system that generates payment instruction files
- **Bank SFTP servers** — secure file servers run by banks that accept payment files and return account statements

Bridge watches both sides, picks up new files, and delivers them to the other end — automatically, on a schedule, without manual intervention.

### The problem it solves

Companies using NetSuite for payments face a common technical hurdle: NetSuite can place payment files on an SFTP server, but it cannot directly push files to a bank's proprietary SFTP server, and the bank cannot pull from NetSuite. A middleman server is needed.

Bridge is that middleman. It:

- Polls NetSuite's SFTP every 30 seconds for new payment files (CSV format)
- Forwards them to the appropriate bank's SFTP server
- Polls the bank's SFTP for bank statements (MT940, BAI2, or similar formats)
- Delivers those statements back to NetSuite
- Keeps a full database audit trail of every file transferred
- Alerts operators by email on failures
- Detects and blocks duplicate files automatically

### Who is this for?

- Finance/operations teams at companies that use NetSuite and need to automate bank file transfers
- IT administrators setting up or maintaining that automation
- Developers extending or debugging the system

You do **not** need to understand all the code to operate Bridge day-to-day — the web dashboard handles most tasks.

---

## 2. How It Works — Plain English

Think of Bridge like a postal relay station:

1. **NetSuite drops a letter (payment file) in its outbox** — a folder on its SFTP server
2. **Bridge checks that outbox every 30 seconds**, picks up any new letters, and records them in a database
3. **Bridge checks: "Have I seen this exact letter before?"** If yes, it discards the duplicate and sends an alert. If no, it delivers it
4. **Bridge delivers the letter to the bank's inbox** — an upload folder on the bank's SFTP server
5. **Bridge files a copy** in its local archive folder so you can always find it later
6. **The bank drops a reply (bank statement) in its outbox** — Bridge picks that up too and delivers it back to NetSuite

All of this is logged in a PostgreSQL database (a structured data store). An operator can open the web dashboard at any time to see what transferred, what failed, and manually retry anything that went wrong.

> **SFTP** stands for SSH File Transfer Protocol — it is a secure way to upload and download files over the internet, like FTP but encrypted.

> **MT940 / BAI2 / CSV** are file format standards used in banking for statements and payment instructions.

---

## 3. Technologies Used

| Technology | What it does | Beginner explanation |
|---|---|---|
| **Python 3.11+** | Core programming language | The language the whole app is written in |
| **FastAPI** | Web framework | Handles HTTP requests and serves the dashboard |
| **Uvicorn** | Web server | Runs the FastAPI application |
| **asyncssh** | SFTP client library | Connects to and exchanges files with SFTP servers |
| **asyncio** | Python async runtime | Lets the app do multiple things at once (poll + serve web) |
| **PostgreSQL** | Database | Stores transfer records, user accounts, audit logs |
| **psycopg2** | PostgreSQL driver | Python's way of talking to PostgreSQL |
| **bcrypt** | Password hashing | Stores passwords securely (never as plain text) |
| **pyotp** | TOTP/MFA library | Powers the two-factor authentication (Google Authenticator codes) |
| **qrcode** | QR code generator | Creates the setup QR code for authenticator apps |
| **Jinja2** | HTML templating | Renders the dashboard HTML pages |
| **python-gnupg** | PGP encryption | Optional: encrypts/decrypts files using PGP keys |
| **nginx** | Reverse proxy | Handles HTTPS (TLS), rate limiting, sits in front of the app |
| **systemd** | Process manager | Keeps the app running, restarts it if it crashes |
| **Let's Encrypt / certbot** | TLS certificates | Free HTTPS certificates, auto-renewed |
| **fail2ban** | Brute-force protection | Bans IPs that repeatedly fail login |

---

## 4. Folder Structure

### Source code (what you deploy)

```
bridge/
├── bridge.py              ← The entire application — all logic lives here
├── requirements.txt       ← Python package dependencies
├── setup_postgres.sh      ← One-time database setup script (development only)
├── BRIDGE_OVERVIEW.md     ← Legacy reference doc (partially outdated — see note below)
└── templates/
    ├── dashboard.html     ← Main operator web interface
    ├── login.html         ← Login page
    ├── mfa_setup.html     ← MFA enrollment page (shown on first login)
    └── mfa_verify.html    ← MFA code entry page (shown on every login)
```

> **Note on `BRIDGE_OVERVIEW.md`:** This file is a partial reference but is outdated in some areas — particularly the directory structure and environment variable names. The source code (`bridge.py`) is always the authoritative source. When in doubt, check the code.

### Runtime data directories (auto-created when the app starts)

These folders are created automatically inside the directory where `bridge.py` is running. On a production server, that is `/opt/bridge/`:

```
data/
├── staging/               ← Files being downloaded/processed right now (temporary)
├── upload_staging/        ← Files manually uploaded via the dashboard (temporary)
├── processed/             ← Permanent archive of every successfully transferred file
│   └── YYYY-MM-DD/
│       └── <bank_id>/
│           └── [<account_id>/]
│               └── outbound/ or inbound/
│                   └── filename.csv
├── error/                 ← Files from transfers that were manually abandoned
├── netsuite/              ← NetSuite mirror folders, ACK receipts, and NACK records
│   └── <bank_id>/
│       └── [<account_id>/]
│           ├── outbound/  ← (NS_SFTP_SERVER_MODE) NetSuite drops files here
│           ├── inbound/   ← (NS_SFTP_SERVER_MODE) Files ready to go to NetSuite
│           ├── ACK/       ← Copies of files successfully delivered to the bank
│           └── NACK/      ← Copies of files that failed delivery
├── banks/                 ← Only used in local/test mode — simulates bank SFTP dirs
│   └── <bank_id>/
│       ├── outbound/      ← Place test bank statement files here
│       └── inbound/       ← Test payment delivery lands here
├── banks_config.json      ← Runtime bank configuration (created when you add a bank via dashboard)
└── gnupg/                 ← PGP key storage (only if PGP encryption is used)
```

> **ACK** (Acknowledgement) = a copy of a file that was delivered successfully.
> **NACK** (Negative Acknowledgement) = a copy of a file that failed to deliver.

---

## 5. Prerequisites

### For local development / testing

- Python 3.11 or higher
- PostgreSQL 14 or higher (running locally)
- Git (to clone/manage the code)

### For production deployment

- Ubuntu 24.04 server (OCI, AWS, DigitalOcean, or any VPS)
- A domain name pointing to the server's IP address
- Port 22 (SSH), 80 (HTTP), and 443 (HTTPS) open in your firewall
- Python 3.11+, PostgreSQL, nginx, certbot, fail2ban (all installed via `apt`)

---

## 6. Local Setup (Development)

This section walks through running Bridge on your own machine for testing. No live SFTP servers are needed — Bridge has a built-in "local" mode that simulates file exchanges using local folders.

### Step 1 — Clone and enter the project

```bash
git clone <your-repo-url>
cd bridge
```

### Step 2 — Create and activate a Python virtual environment

A **virtual environment** keeps the project's packages isolated from your system Python.

```bash
python3 -m venv venv

# On macOS / Linux:
source venv/bin/activate

# On Windows:
venv\Scripts\activate
```

You will see `(venv)` at the start of your terminal prompt when it is active.

### Step 3 — Install Python dependencies

```bash
pip install --upgrade pip
pip install -r requirements.txt
```

### Step 4 — Set up PostgreSQL

Make sure PostgreSQL is running. Then create the database and user:

```bash
# Option A: Use the provided setup script (development only — uses weak defaults)
bash setup_postgres.sh

# Option B: Manual setup (recommended)
sudo -u postgres psql <<EOF
CREATE USER bridge WITH PASSWORD 'your_strong_password_here';
CREATE DATABASE bridge OWNER bridge;
REVOKE ALL ON DATABASE bridge FROM PUBLIC;
EOF
```

> **What is PostgreSQL?** It is a database — a program that stores structured data in tables, like a powerful spreadsheet that your application can query. Bridge uses it to store transfer records, user accounts, and logs.

Bridge creates all the required tables automatically on first start. You do not need to run any SQL migration scripts manually.

### Step 5 — Create a `.env` file

Create a file called `.env` in the `bridge/` directory with your configuration:

```env
# ── Mode ──────────────────────────────────────────────────
# 'local'  = test mode, no SFTP connections, uses local folders
# 'sftp'   = production mode, connects to real SFTP servers
BRIDGE_MODE=local

# ── Web server ────────────────────────────────────────────
BIND_HOST=127.0.0.1
SESSION_HTTPS_ONLY=false

# Generate with: python3 -c "import secrets; print(secrets.token_hex(32))"
SESSION_SECRET=replace_with_a_long_random_string_here

# ── Admin login ───────────────────────────────────────────
ADMIN_USER=admin
ADMIN_PASS=change_this_password

# ── Database ──────────────────────────────────────────────
PG_HOST=localhost
PG_PORT=5432
PG_DB=bridge
PG_USER=bridge
PG_PASS=your_strong_password_here

# ── NetSuite SFTP (only needed when BRIDGE_MODE=sftp) ─────
NS_HOST=sftp.your-netsuite.com
NS_PORT=22
NS_USER=ns_sftp_user
NS_PASS=ns_sftp_password
NS_OUTBOUND_DIR=/outbound
NS_INBOUND_DIR=/inbound

# ── Banks (one JSON object per bank) ──────────────────────
BANKS_JSON=[
  {
    "id": "mybank",
    "host": "sftp.mybank.com",
    "port": 22,
    "user": "bank_sftp_user",
    "pass": "bank_sftp_password",
    "inbound_dir": "/incoming",
    "outbound_dir": "/outgoing",
    "accounts": []
  }
]

# ── Email alerts (optional but recommended) ───────────────
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=alerts@yourdomain.com
SMTP_PASS=your_app_password
ALERT_TO=ops@yourdomain.com

# ── Tuning ────────────────────────────────────────────────
POLL_SECONDS=30
MAX_FILES_PER_CYCLE=50
MAX_UPLOAD_BYTES=20971520
MAX_CONCURRENT_SFTP=2
STAGING_MAX_AGE_HOURS=48
```

> **Important:** The env var name is `BRIDGE_MODE`, not `MODE`. Using `MODE=sftp` will have no effect — the app defaults to `local` mode if `BRIDGE_MODE` is not set.

### Step 6 — Load environment variables

The app reads environment variables from the process environment. The simplest way for local development:

```bash
# Export all variables from .env before running
export $(grep -v '^#' .env | xargs)
```

Or use a tool like `python-dotenv` (not included — for local convenience only).

### Step 7 — Start the server

```bash
python bridge.py
```

You should see output like:

```
2026-05-12 10:00:00  INFO     PostgreSQL connected (bridge@localhost/bridge)
2026-05-12 10:00:00  INFO     Database ready
2026-05-12 10:00:01  INFO     Poller started (every 30s, mode=local, ...)
```

### Step 8 — Verify it is working

Open your browser and go to: `http://127.0.0.1:8000`

You should see the Bridge login page. Log in with the `ADMIN_USER` and `ADMIN_PASS` values from your `.env`.

On first login you will be prompted to set up MFA (multi-factor authentication) using an app like Google Authenticator or Authy.

### Step 9 — Generate test files (optional)

```bash
python bridge.py --test
```

This creates synthetic payment and statement files in `data/netsuite/<bank>/outbound/` and `data/banks/<bank>/outbound/`. The next poll cycle (within 30 seconds) will process them and you can watch them flow through the dashboard.

---

## 7. Environment Variables

### Complete reference

| Variable | Default | Required | Description |
|---|---|---|---|
| `BRIDGE_MODE` | `local` | Yes (production) | `local` for testing, `sftp` for real SFTP connections |
| `BIND_HOST` | `0.0.0.0` | Production | Set to `127.0.0.1` when running behind nginx |
| `SESSION_SECRET` | random | Yes (production) | Secret key for session cookies — sessions reset on restart if not set |
| `SESSION_HTTPS_ONLY` | `false` | Production | Set to `true` when running over HTTPS |
| `ADMIN_USER` | `admin` | Yes | Username for the initial admin account |
| `ADMIN_PASS` | `admin` | Yes | Password for the initial admin — **change this** |
| `PG_HOST` | `localhost` | Yes | PostgreSQL server hostname |
| `PG_PORT` | `5432` | No | PostgreSQL port |
| `PG_DB` | `bridge` | Yes | Database name |
| `PG_USER` | `bridge` | Yes | Database username |
| `PG_PASS` | `bridge` | Yes | Database password — **use a strong password** |
| `NS_HOST` | _(empty)_ | sftp mode | NetSuite SFTP hostname |
| `NS_PORT` | `22` | No | NetSuite SFTP port |
| `NS_USER` | _(empty)_ | sftp mode | NetSuite SFTP username |
| `NS_PASS` | _(empty)_ | sftp mode | NetSuite SFTP password (or use `NS_KEY`) |
| `NS_KEY` | _(empty)_ | No | Path to SSH private key for NetSuite (preferred over password) |
| `NS_OUTBOUND_DIR` | `/outbound` | No | NetSuite SFTP directory Bridge polls for payment files |
| `NS_INBOUND_DIR` | `/inbound` | No | NetSuite SFTP directory Bridge delivers bank statements to |
| `NS_SFTP_SERVER_MODE` | `false` | No | Set `true` if NetSuite connects IN to your server instead of the reverse |
| `BANKS_JSON` | _(empty)_ | sftp mode | JSON array of bank configurations (see format below) |
| `SFTP_KNOWN_HOSTS` | _(empty)_ | Production | Path to a known_hosts file for SFTP MITM prevention |
| `SFTP_FOLDER_SEGREGATION` | `true` | No | When true, appends `/<bank_id>/<account_id>` to NS SFTP paths |
| `SMTP_HOST` | `smtp.gmail.com` | No | Email server for alerts |
| `SMTP_PORT` | `587` | No | Email server port |
| `SMTP_USER` | _(empty)_ | No | Email address to send alerts from |
| `SMTP_PASS` | _(empty)_ | No | Email password or app password |
| `ALERT_TO` | _(empty)_ | No | Email address to send alerts to |
| `POLL_SECONDS` | `30` | No | How often (in seconds) Bridge checks for new files |
| `MAX_FILES_PER_CYCLE` | `50` | No | Maximum files processed in one poll cycle |
| `MAX_UPLOAD_BYTES` | `20971520` | No | Maximum manual upload size (default: 20 MB) |
| `MAX_CONCURRENT_SFTP` | `2` | No | Maximum simultaneous SFTP connections |
| `STAGING_MAX_AGE_HOURS` | `48` | No | How long before orphaned staging files are cleaned up |
| `SFTP_TIMEOUT` | `30` | No | SFTP operation timeout in seconds |

### `BANKS_JSON` format

```json
[
  {
    "id": "hsbc",
    "name": "HSBC",
    "host": "sftp.hsbc.com",
    "port": 22,
    "user": "your_sftp_username",
    "pass": "your_sftp_password",
    "key": "/opt/bridge/keys/hsbc_rsa",
    "inbound_dir": "/incoming",
    "outbound_dir": "/outgoing",
    "accounts": [
      {
        "id": "acc001",
        "inbound_dir": "/incoming/acc001",
        "outbound_dir": "/outgoing/acc001"
      }
    ],
    "pgp_public_key": "",
    "pgp_private_key": "",
    "pgp_private_key_passphrase": ""
  }
]
```

> **Important:** If a `data/banks_config.json` file exists in the working directory (created when you add/edit banks via the dashboard), it takes precedence over `BANKS_JSON` and all `BANK_*` env vars. Check this file first if bank settings seem wrong.

---

## 8. Production Deployment

This is a condensed production setup guide. For full detail on each step, refer to `BRIDGE_OVERVIEW.md`.

### Step 1 — Prepare the server

```bash
# Update packages and enable auto-security-updates
sudo apt update && sudo apt upgrade -y
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades

# Install all required packages
sudo apt install -y python3-venv python3-pip postgresql postgresql-contrib \
    nginx certbot python3-certbot-nginx fail2ban
```

### Step 2 — Create a dedicated app user

```bash
sudo useradd -r -m -s /bin/bash -d /opt/bridge bridge
sudo passwd -l bridge    # disable password login for this user
```

### Step 3 — Deploy the application

```bash
sudo mkdir -p /opt/bridge
sudo chown bridge:bridge /opt/bridge

# Copy source files to the server (run from your local machine)
scp -r bridge/ ubuntu@<your-server-ip>:/tmp/bridge-deploy
ssh ubuntu@<your-server-ip>
sudo cp -r /tmp/bridge-deploy/* /opt/bridge/
sudo chown -R bridge:bridge /opt/bridge

# Create virtualenv and install dependencies
sudo -u bridge bash -c "
  cd /opt/bridge
  python3 -m venv venv
  source venv/bin/activate
  pip install --upgrade pip
  pip install -r requirements.txt
"
```

### Step 4 — Set up PostgreSQL

```bash
sudo systemctl enable --now postgresql
sudo -u postgres psql <<EOF
CREATE USER bridge WITH PASSWORD 'STRONG_DB_PASSWORD_HERE';
CREATE DATABASE bridge OWNER bridge;
REVOKE ALL ON DATABASE bridge FROM PUBLIC;
EOF
```

### Step 5 — Create the `.env` file

```bash
sudo -u bridge tee /opt/bridge/.env > /dev/null <<'EOF'
BRIDGE_MODE=sftp
BIND_HOST=127.0.0.1
SESSION_HTTPS_ONLY=true
SESSION_SECRET=<output of: python3 -c "import secrets; print(secrets.token_hex(32))">
ADMIN_USER=admin
ADMIN_PASS=<strong-password>
PG_HOST=localhost
PG_DB=bridge
PG_USER=bridge
PG_PASS=STRONG_DB_PASSWORD_HERE
NS_HOST=sftp.your-netsuite.com
NS_USER=ns_sftp_user
NS_KEY=/opt/bridge/keys/netsuite_rsa
NS_OUTBOUND_DIR=/outbound
NS_INBOUND_DIR=/inbound
SFTP_KNOWN_HOSTS=/opt/bridge/known_hosts
BANKS_JSON=[]
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=alerts@yourdomain.com
SMTP_PASS=your_app_password
ALERT_TO=ops@yourdomain.com
EOF

sudo chmod 600 /opt/bridge/.env
sudo chown bridge:bridge /opt/bridge/.env
```

### Step 6 — SSH key authentication for SFTP (recommended)

Using SSH keys is more secure than passwords for SFTP connections:

```bash
sudo -u bridge mkdir -p /opt/bridge/keys && chmod 700 /opt/bridge/keys

# Generate a key pair for NetSuite
sudo -u bridge ssh-keygen -t ed25519 -f /opt/bridge/keys/netsuite_rsa -N ""
cat /opt/bridge/keys/netsuite_rsa.pub   # give this public key to the NetSuite admin

# Generate a key pair per bank
sudo -u bridge ssh-keygen -t ed25519 -f /opt/bridge/keys/hsbc_rsa -N ""
cat /opt/bridge/keys/hsbc_rsa.pub       # give this public key to the bank's IT team

# Capture SFTP server fingerprints (prevents man-in-the-middle attacks)
sudo -u bridge ssh-keyscan -p 22 sftp.your-netsuite.com >> /opt/bridge/known_hosts
sudo -u bridge ssh-keyscan -p 22 sftp.hsbc.com >> /opt/bridge/known_hosts
chmod 600 /opt/bridge/known_hosts
```

### Step 7 — Create the systemd service

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
MemoryMax=512M
CPUQuota=90%
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/opt/bridge/data /opt/bridge/keys
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
```

### Step 8 — Configure nginx with TLS

Add to `/etc/nginx/nginx.conf` inside the `http {}` block:
```nginx
limit_req_zone $binary_remote_addr zone=login:10m rate=10r/m;
```

Create `/etc/nginx/sites-available/bridge`:

```nginx
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

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;

    location /login {
        limit_req zone=login burst=5 nodelay;
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
        client_max_body_size 25M;
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/bridge /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
sudo certbot --nginx -d your.domain.com --non-interactive --agree-tos -m admin@yourdomain.com
```

---

## 9. First Login and User Setup

1. Open `https://your.domain.com` in your browser
2. Log in with the `ADMIN_USER` / `ADMIN_PASS` from your `.env` file
3. You will be redirected to **MFA Setup** — scan the QR code with Google Authenticator or Authy
4. Enter the 6-digit code shown in your authenticator app to complete enrollment
5. Go to the **Users** section in the dashboard header to create named operator accounts
6. Each new user completes their own MFA enrollment on first login
7. Consider disabling or removing the generic `admin` account once you have named admin accounts

> **MFA (Multi-Factor Authentication)** means you need both your password AND a time-based code from your phone to log in. This protects the dashboard even if someone steals your password.

---

## 10. Features and Functionality

### Dashboard

Accessible at `https://your.domain.com` after login.

| Feature | Description |
|---|---|
| **Transfer table** | Live list of all file transfers with status, bank, direction, size — auto-refreshes every 3 seconds |
| **Status filters** | Filter transfers by status (pending, sent, received, failed, duplicate, abandoned) |
| **Bank filter** | Filter transfers by bank |
| **Transfer detail** | Click the info icon on any transfer to see full logs, SHA-256 hashes, timestamps |
| **Retry** | Admin can re-attempt a failed transfer (staged file must still exist) |
| **Abandon** | Admin can move a failed transfer to the `data/error/` folder and mark it abandoned |
| **Delete** | Admin can delete a transfer record and its staged file |
| **Manual upload** | Manually inject a file into the pipeline (choose direction and bank) |
| **Folder browser** | Browse `data/netsuite/`, `data/processed/`, and `data/error/` folder trees |
| **User management** | Admin can create, delete, and reset passwords for user accounts |
| **Health indicator** | Header shows PostgreSQL connection status |
| **Notifications bar** | Shows recent failures and duplicates |

### Summary cards

The top of the dashboard shows live counters for: Sent, Received, Failed, Pending, and Duplicate transfers.

### Transfer statuses

| Status | Meaning |
|---|---|
| `pending` | File discovered and recorded, waiting to be delivered |
| `transferring` | Delivery in progress right now |
| `sent` | Successfully delivered to the bank (outbound) |
| `received` | Successfully delivered to NetSuite (inbound) |
| `failed` | Delivery failed — can be retried if staged file exists |
| `duplicate` | Same file content seen before — blocked, not delivered |
| `abandoned` | Manually marked as abandoned by an admin, file moved to error folder |

### User roles

| Role | Can do |
|---|---|
| `admin` | Everything: view, retry, abandon, delete, upload, manage users, manage bank config |
| `readonly` | View transfers, browse folders, view notifications only |

---

## 11. API Reference

All API endpoints require a valid session cookie (obtained by logging in via the web interface). Responses are JSON.

### Authentication

| Method | Path | Description |
|---|---|---|
| `GET` | `/login` | Login page (HTML) |
| `POST` | `/login` | Submit credentials |
| `POST` | `/logout` | End session |
| `GET/POST` | `/mfa-setup` | First-time MFA enrollment |
| `GET/POST` | `/mfa-verify` | MFA code entry on login |

### Dashboard

| Method | Path | Description |
|---|---|---|
| `GET` | `/` | Dashboard (HTML) — requires login |

### Health

```
GET /api/health
```

Response:
```json
{"status": "ok", "postgres": true}
```

Returns `{"status": "degraded", "postgres": false}` if the database is unreachable.

### Transfers

```
GET /api/summary
```
```json
{
  "total": 142,
  "sent": 88,
  "received": 47,
  "failed": 3,
  "pending": 0,
  "transferring": 1,
  "duplicate": 2,
  "abandoned": 1
}
```

---

```
GET /api/transfers?status=failed&direction=outbound&bank_id=hsbc&page=1&per_page=50
```

Query parameters (all optional):
- `status` — filter by status string
- `direction` — `outbound` or `inbound`
- `bank_id` — filter by bank ID
- `page` — page number (default: 1)
- `per_page` — results per page (1–200, default: 50)

Response:
```json
{
  "items": [
    {
      "id": 42,
      "filename": "payment_20260512.csv",
      "direction": "outbound",
      "status": "failed",
      "size_bytes": 4096,
      "sha256": "a1b2c3...",
      "error": "Connection timed out",
      "retries": 1,
      "bank_id": "hsbc",
      "account_id": "acc001",
      "updated_at": "2026-05-12 10:30:00 UTC"
    }
  ],
  "total": 1,
  "page": 1,
  "per_page": 50
}
```

---

```
GET /api/transfers/{id}
```

Returns a single transfer record including its full event log:
```json
{
  "id": 42,
  "filename": "payment_20260512.csv",
  "direction": "outbound",
  "status": "failed",
  "logs": [
    {"message": "Discovered: payment_20260512.csv (4096B, bank=hsbc)", "time": "2026-05-12 10:00:01 UTC"},
    {"message": "Transferring...", "time": "2026-05-12 10:00:01 UTC"},
    {"message": "Failed: Connection timed out", "time": "2026-05-12 10:00:31 UTC"}
  ]
}
```

---

```
POST /api/transfers/{id}/retry       ← Admin only
POST /api/transfers/{id}/abandon     ← Admin only
DELETE /api/transfers/{id}           ← Admin only
```

Retry response:
```json
{"ok": true, "message": "Transfer succeeded"}
```

Retry failure response (HTTP 400):
```json
{"ok": false, "message": "Staged file no longer exists — please re-upload"}
```

---

### File upload

```
POST /api/upload
Content-Type: multipart/form-data

Fields:
  file       - the file to upload
  direction  - "outbound" or "inbound"
  bank_id    - bank ID (optional, defaults to first configured bank)
  account_id - account ID (optional)
```

Response:
```json
{
  "queued": "payment.csv",
  "stored_as": "20260512100000000000_abc123_payment.csv",
  "direction": "outbound",
  "bank_id": "hsbc"
}
```

---

### Bank configuration (Admin only)

```
GET    /api/banks-config            ← List all banks (passwords masked)
POST   /api/banks-config            ← Create a new bank
PUT    /api/banks-config/{bank_id}  ← Update a bank
DELETE /api/banks-config/{bank_id}  ← Delete a bank (also removes its data dirs)
```

Create bank request body:
```json
{
  "id": "newbank",
  "host": "sftp.newbank.com",
  "port": 22,
  "user": "sftp_user",
  "pass": "sftp_password",
  "key": "/opt/bridge/keys/newbank_rsa",
  "inbound_dir": "/incoming",
  "outbound_dir": "/outgoing",
  "accounts": [],
  "pgp_public_key": "",
  "pgp_private_key": "",
  "pgp_private_key_passphrase": ""
}
```

---

### User management (Admin only)

```
GET    /api/users
POST   /api/users                               ← Body: {username, password, role}
DELETE /api/users/{username}
POST   /api/users/{username}/reset-password     ← Body: {password}
```

---

### Folder browser

```
GET /api/folders?path=
GET /api/folders?path=netsuite
GET /api/folders?path=netsuite/hsbc/ACK
```

Response:
```json
{
  "path": "netsuite/hsbc/ACK",
  "entries": [
    {"name": "42_payment.csv", "type": "file", "size": 4096, "mtime": 1715506800},
    {"name": "43_wire.csv",    "type": "file", "size": 1024, "mtime": 1715506900}
  ]
}
```

Available root paths: `netsuite`, `processed`, `error`.

---

## 12. Architecture Deep Dive

### Single-file design

The entire application lives in one file: `bridge.py`. There are no sub-packages or external service classes. This makes it easy to audit but means all changes happen in one place.

### Components and their responsibilities

```
bridge.py
│
├── CFG dict (line 44)
│   └── Loads all configuration from environment variables at startup
│
├── _load_banks_config() (line 109)
│   └── Loads bank list from: data/banks_config.json → BANKS_JSON env → BANK_* env
│
├── DB class (line 326)
│   ├── connect() / init() — creates connection pool, creates tables
│   ├── insert_or_detect_duplicate() — duplicate detection with advisory lock
│   ├── update() / add_log() — transfer lifecycle updates
│   └── verify_user() / list_users() / create_user() — user management
│
├── process_file() (line 1093)
│   └── Main pipeline: hash → dedup check → mark transferring → deliver → archive → ACK/NACK
│
├── _deliver() (line 964)
│   ├── Outbound: optionally PGP-encrypt, then sftp.put() to bank
│   └── Inbound: optionally PGP-decrypt, then sftp.put() to NetSuite (or local copy)
│
├── _poll_cycle() (line 1188)
│   ├── Iterates all banks × accounts
│   ├── Outbound: sftp.readdir() on NS, sftp.get() each file, sftp.remove() from source
│   └── Inbound: sftp.readdir() on bank, sftp.get() each file, sftp.remove() from source
│
├── poll_loop() (line 1313)
│   └── Runs _poll_cycle() every POLL_SECONDS in an infinite async loop
│
├── _staging_cleanup_loop() (line 1329)
│   └── Runs hourly, removes orphaned staging files older than STAGING_MAX_AGE_HOURS
│
├── FastAPI app + routes (line 1381+)
│   ├── /login, /logout, /mfa-setup, /mfa-verify — authentication flow
│   ├── / — dashboard HTML
│   └── /api/* — JSON API for dashboard and programmatic use
│
└── lifespan() (line 1352)
    └── FastAPI startup/shutdown: starts poll_loop and cleanup_loop tasks
```

### Async model

> **Async** means the app can do multiple things at the same time without one blocking the other. It is like a chef who puts something in the oven (SFTP download) and prepares the next dish (handle a web request) while waiting.

Bridge uses Python's `asyncio` for all concurrent work:
- The web server (FastAPI/uvicorn) runs async
- The poll loop runs as a background asyncio task
- SFTP operations use `asyncssh`, which is async-native
- Database calls (which are blocking) are wrapped in `asyncio.to_thread()` so they do not freeze the event loop

---

## 13. Data Flow Walkthrough

### Full outbound example (payment file: NetSuite → Bank)

```
1. POLL
   poll_loop() wakes up every 30s
   _poll_cycle() iterates: for bank_cfg in BANKS → for account in bank.accounts

2. DISCOVER
   asyncssh connects to NS_HOST
   sftp.readdir("/outbound/hsbc/acc001") → ["payment_20260512.csv"]
   sftp.get("payment_20260512.csv") → saved to data/staging/<uuid>_payment_20260512.csv
   sftp.remove("payment_20260512.csv")  ← file deleted from NetSuite SFTP immediately

3. HASH
   data = staging_file.read_bytes()
   sha256         = hashlib.sha256(data).hexdigest()
   content_sha256 = sha256(normalize_line_endings(data))

4. DEDUP
   PostgreSQL: pg_advisory_xact_lock(hashtext(content_sha256))
   SELECT from transfers WHERE content_sha256 = ? AND direction = 'outbound'
   → No match found

5. RECORD
   INSERT INTO transfers (filename, direction='outbound', status='pending', ...)
   UPDATE transfers SET status='transferring'

6. PGP (if configured)
   _pgp_encrypt_file(staging_file, staging_file.pgp, bank.pgp_public_key)

7. DELIVER
   asyncssh connects to bank SFTP (hsbc)
   sftp.put(staging_file.pgp, "/incoming/payment_20260512.csv.pgp")

8. ARCHIVE
   shutil.move(staging_file) → data/processed/2026-05-12/hsbc/acc001/outbound/payment_20260512.csv

9. ACK
   shutil.copy(archived_file) → data/netsuite/hsbc/acc001/ACK/42_payment_20260512.csv

10. COMPLETE
    UPDATE transfers SET status='sent', archived_path=...
    send_alert(kind='success')
    Temp .pgp file deleted
```

### What happens on failure

If any step from 6 onwards throws an exception:
- `status` is set to `'failed'` with the error message stored in the `error` column
- The staged file is kept (not deleted) so retry is possible
- `write_nack()` copies the staged file to `data/netsuite/<bank>/NACK/`
- An alert email is sent
- The next poll cycle will not retry automatically — an operator must click Retry in the dashboard

### Duplicate detection details

The `content_sha256` hash is computed after normalizing the file:
- Removes UTF-8 BOM (byte order mark)
- Converts all line endings to `\n`
- Strips trailing spaces from each line
- Removes trailing blank lines

This means a CSV resent with different line endings (Windows `\r\n` vs Unix `\n`) will still be caught as a duplicate.

Binary files (containing null bytes `\x00`) are hashed as-is without normalization.

---

## 14. Configuration and Customization

### Changing poll interval

In `.env`:
```env
POLL_SECONDS=60    # poll every 60 seconds instead of 30
```

Restart the service for changes to take effect.

### Changing file size limit for manual uploads

```env
MAX_UPLOAD_BYTES=52428800    # 50 MB
```

Also update nginx's `client_max_body_size` to match.

### Disabling folder segregation

By default Bridge adds `/<bank_id>/<account_id>` subdirectories to all NetSuite SFTP paths. To disable:

```env
SFTP_FOLDER_SEGREGATION=false
```

When disabled, all banks share the same `/outbound` and `/inbound` directories on NetSuite's SFTP. Only use this if you have a single bank with no account sub-directories.

### Using NS_SFTP_SERVER_MODE

In this mode, instead of Bridge dialling out to NetSuite's SFTP, NetSuite (or any other client) connects IN to your server and drops files into a local directory that Bridge watches.

```env
NS_SFTP_SERVER_MODE=true
```

Files must be placed in `data/netsuite/<bank_id>/[<account_id>/]outbound/`. This requires a separate OpenSSH chroot setup on the same server so the external system can log in and write files there.

---

## 15. Adding a New Bank

### Method 1 — Dashboard (recommended, no restart needed)

1. Log in as admin
2. The dashboard header shows a **Banks** management panel
3. Click **Add Bank**
4. Fill in the bank ID, SFTP hostname, credentials, and directories
5. Click **Save** — Bridge hot-reloads the bank list immediately

This writes to `data/banks_config.json`. No restart required.

### Method 2 — Environment variable

Edit your `.env` or systemd `EnvironmentFile` and add the new bank to the `BANKS_JSON` array:

```env
BANKS_JSON=[
  {"id": "hsbc", "host": "sftp.hsbc.com", ...},
  {"id": "barclays", "host": "sftp.barclays.com", "port": 22, "user": "user", "pass": "pass", "inbound_dir": "/payments", "outbound_dir": "/statements", "accounts": []}
]
```

Then restart: `sudo systemctl restart bridge`

> **Important:** If `data/banks_config.json` exists, it overrides `BANKS_JSON`. You must either delete that file or add the bank via the dashboard.

### What to set up for each new bank

1. Generate an SSH key pair: `ssh-keygen -t ed25519 -f /opt/bridge/keys/newbank_rsa -N ""`
2. Give the public key (`newbank_rsa.pub`) to the bank's technical team
3. Capture the bank's SFTP fingerprint: `ssh-keyscan -p 22 sftp.newbank.com >> /opt/bridge/known_hosts`
4. Ask the bank to whitelist your server's IP address
5. Confirm the bank's inbound and outbound directory paths

---

## 16. PGP Encryption Support

Bridge supports optional PGP encryption/decryption per bank.

> **PGP** is an encryption standard. It uses a public key (which you can share with anyone) to encrypt files, and a private key (which only you have) to decrypt them.

### Outbound files (you encrypt before sending to bank)

The bank gives you their **public key**. Bridge encrypts each payment file before uploading to the bank's SFTP.

In the bank configuration (via dashboard or `banks_config.json`):
```json
{
  "pgp_public_key": "/opt/bridge/keys/bank_pubkey.asc"
}
```

### Inbound files (bank encrypts, you decrypt)

You generate a key pair and give the bank your **public key**. The bank encrypts statements before placing them on their SFTP. Bridge decrypts them before forwarding to NetSuite.

```json
{
  "pgp_private_key": "/opt/bridge/keys/bridge_privkey.asc",
  "pgp_private_key_passphrase": "optional_passphrase_if_key_is_protected"
}
```

Bridge automatically detects files ending in `.pgp` and attempts decryption. If no private key is configured, the `.pgp` file is forwarded as-is.

PGP keys and a temporary GPG keyring are stored in `data/gnupg/`. This directory is created with permissions `700` (only the `bridge` user can read it).

---

## 17. Troubleshooting

### "Bridge is running but no files are transferring"

1. **Check the mode.** In `.env`, verify `BRIDGE_MODE=sftp` is set. The env var name is `BRIDGE_MODE`, not `MODE`. If this is wrong, Bridge defaults to local mode and makes no SFTP connections.
   ```bash
   grep BRIDGE_MODE /opt/bridge/.env
   ```

2. **Check logs for SFTP errors.**
   ```bash
   sudo journalctl -u bridge -f --since "10 minutes ago"
   ```
   Look for lines like `NS poll error` or `Bank poll error`.

3. **Check if `data/banks_config.json` has wrong credentials.**
   ```bash
   cat /opt/bridge/data/banks_config.json
   ```

4. **Verify SFTP connectivity manually.**
   ```bash
   sudo -u bridge ssh -i /opt/bridge/keys/netsuite_rsa ns_sftp_user@sftp.your-netsuite.com
   ```

### "Sessions reset every time the app restarts"

Set a persistent `SESSION_SECRET` in `.env`:
```bash
python3 -c "import secrets; print(secrets.token_hex(32))"
```
Paste the output as `SESSION_SECRET=...` in your `.env`.

### "Login shows 'Too many failed attempts'"

The rate-limit lockout is in-memory and resets on restart:
```bash
sudo systemctl restart bridge
```

Or wait 5 minutes for the lockout to expire automatically.

### "Retry button says 'Staged file no longer exists'"

The file was deleted from the staging directory (perhaps by the orphan cleanup loop, or the server was rebuilt). The operator must re-upload the file manually via the dashboard upload button.

### "Duplicate transfers are showing for files I haven't sent before"

Check if `content_sha256` matches another transfer. The duplicate check is based on normalized file content, not filename. Two differently-named files with identical content will be detected as duplicates.

To allow re-delivery of a legitimately duplicate file, delete the original transfer record via the dashboard (admin only) and then re-submit.

### "Can't browse ACK or NACK folders in the dashboard"

The folder browser exposes three roots: `netsuite`, `processed`, and `error`. ACK and NACK files live **inside** the `netsuite` folder tree, at:
```
netsuite/<bank_id>/[<account_id>/]ACK/
netsuite/<bank_id>/[<account_id>/]NACK/
```

Navigate to `netsuite` in the folder browser and drill down.

### "PGP decryption failed"

1. Verify the private key file path in `banks_config.json` is correct and the file exists
2. Check the passphrase if the key is passphrase-protected
3. Verify the GPG home directory is accessible: `ls -la /opt/bridge/data/gnupg/`
4. Check logs for the full error: `sudo journalctl -u bridge | grep -i pgp`

### Database connection errors

```bash
# Check PostgreSQL is running
sudo systemctl status postgresql

# Test connection manually
PGPASSWORD=your_password psql -h localhost -U bridge -d bridge -c "SELECT 1;"

# Check pg_hba.conf allows local connections
sudo cat /etc/postgresql/*/main/pg_hba.conf | grep bridge
```

### Service won't start

```bash
sudo systemctl status bridge       # see the last error
sudo journalctl -u bridge -n 50    # last 50 log lines
```

Common causes:
- Wrong `WorkingDirectory` in systemd service — must be `/opt/bridge`
- `.env` file not readable by the `bridge` user
- PostgreSQL not running
- Python virtual environment not found

---

## 18. Security Notes

### What is already in place

| Layer | Measure |
|---|---|
| OS | ufw firewall, SSH key-only login, fail2ban, automatic security updates |
| App authentication | bcrypt password hashing + mandatory TOTP/MFA |
| Sessions | `SameSite=strict`, HTTPS-only cookies, 8-hour expiry |
| Rate limiting | nginx (10 login requests/minute) + app-level (5 failures → 5-minute lockout) |
| SFTP | SSH key authentication, known_hosts file for host verification |
| Duplicate detection | SHA-256 hash + PostgreSQL advisory lock (prevents race conditions) |
| Path safety | `_safe_id()` on bank/account IDs; `Path().name` on remote filenames |
| Secrets | `.env` file chmod 600, owned by `bridge` user |
| Process isolation | systemd `ProtectSystem=strict`, `NoNewPrivileges`, `PrivateTmp`, `MemoryMax` |
| TLS | Let's Encrypt, TLS 1.2/1.3 only, HSTS header |
| Database | PostgreSQL listening on localhost only, dedicated low-privilege user |

### What you must do yourself

1. **Set `SFTP_KNOWN_HOSTS`** — without it, Bridge connects to SFTP servers without verifying their identity. A malicious server could intercept your files.

2. **Use SSH keys, not passwords** — for all SFTP connections. Keys cannot be brute-forced.

3. **Change `ADMIN_PASS`** immediately after first login.

4. **Secure `data/banks_config.json`** — this file contains SFTP credentials in plain text. Set restrictive permissions:
   ```bash
   chmod 600 /opt/bridge/data/banks_config.json
   ```

5. **Never expose port 8000 directly** — always put nginx in front.

6. **Run `setup_postgres.sh` only for development** — it sets `bridge`/`bridge` as the database password. Use a strong password in production.

---

## 19. Best Practices for Beginners

### Understand what "local mode" means

When `BRIDGE_MODE=local`, Bridge never makes any SFTP connections. Instead of reading from NetSuite's SFTP, it reads from `data/netsuite/<bank>/outbound/`. Instead of writing to the bank's SFTP, it writes to `data/banks/<bank>/inbound/`. This is a safe sandbox for testing.

Always develop and test in local mode before switching to `sftp` mode.

### Never manually edit `data/banks_config.json`

This file is managed by the dashboard. If you edit it directly, you risk breaking the JSON format or losing changes. Use the dashboard bank management UI or `BANKS_JSON` env var instead.

### Staged files are precious

A file in `data/staging/` is the only copy Bridge has if the original source has already been deleted (which happens immediately after download). Do not manually delete staging files — let Bridge manage them. The cleanup loop removes them safely after 48 hours if they are no longer active.

### The `WorkingDirectory` setting is critical

All paths in Bridge are relative. If `WorkingDirectory=/opt/bridge` is not set in the systemd service, `data/` directories will be created in the wrong place and the app may appear to run but transfer nothing. Always verify this setting.

### One transfer record per file

The database has one row per file. Even duplicates get a row (with `status='duplicate'`). This full audit trail is intentional — never bulk-delete transfer records unless you have a specific reason.

### Restarting is safe

The poll loop picks up where it left off after a restart. Transfers in `pending` or `transferring` state at shutdown may need manual retry (check the dashboard after restart). Files already archived to `data/processed/` are safe regardless.

### Log everything significant yourself

When making code changes, follow the existing pattern:
```python
await asyncio.to_thread(db.add_log, tid, "Your message here")
log.info("Your log message %s", variable)
```

Both the database log and the system log should capture important events.

---

## 20. Maintenance Reference

### Daily operations

```bash
# View live service logs
sudo journalctl -u bridge -f

# Check service health
sudo systemctl status bridge
curl -s https://your.domain.com/api/health

# Check for failed transfers
# → Use the dashboard filter: Status = Failed
```

### Common commands

| Task | Command |
|---|---|
| View live logs | `sudo journalctl -u bridge -f` |
| Restart service | `sudo systemctl restart bridge` |
| Deploy updated bridge.py | `sudo cp bridge.py /opt/bridge/bridge.py && sudo systemctl restart bridge` |
| Check disk usage | `du -sh /opt/bridge/data/*/` |
| PostgreSQL transfer count | `sudo -u postgres psql -c "SELECT count(*) FROM transfers;" bridge` |
| Backup database | `pg_dump -U bridge bridge > bridge_$(date +%F).sql` |
| Check TLS cert expiry | `sudo certbot certificates` |
| Check fail2ban status | `sudo fail2ban-client status bridge-login` |
| Check firewall rules | `sudo ufw status verbose` |

### Cleaning old ACK/NACK files

ACK and NACK files live under `data/netsuite/`. To remove files older than 90 days:

```bash
find /opt/bridge/data/netsuite -name "*.csv" -mtime +90 -delete
find /opt/bridge/data/netsuite -name "*.mt940" -mtime +90 -delete
```

> Note: The path is `data/netsuite/`, **not** `data/ACK/` or `data/NACK/` — those top-level directories do not exist.

### Cleaning old processed archives

```bash
find /opt/bridge/data/processed -mtime +365 -type f -delete
```

---

## 21. Assumptions / Information Needed

The following information was not available during this documentation and should be confirmed before going live:

1. **NetSuite SFTP hostname and credentials** — `NS_HOST`, `NS_USER`, and either `NS_PASS` or `NS_KEY` must be obtained from the NetSuite administrator.

2. **Bank SFTP hostname, credentials, and directory structure** — Each bank's technical team must provide their SFTP hostname, username, key authorization process, inbound (upload) directory, and outbound (download) directory.

3. **IP whitelisting** — Both NetSuite and each bank must be asked to allow inbound SFTP connections from the server's reserved IP address. The server's IP must be known and static before contacting them.

4. **PGP requirements** — Check with each bank whether they require PGP encryption for payment files or use it for statement files. If yes, exchange public keys before go-live.

5. **Production domain name** — The nginx and Let's Encrypt configuration requires a domain name pointing to the server. Replace `your.domain.com` throughout this README with the actual domain.

6. **Email alert destination** — Confirm the `ALERT_TO` email address with the operations team.

7. **`setup_postgres.sh` is for development only** — Do not run it on a production server. It sets the database password to `bridge` which is insecure. Use the manual PostgreSQL setup from Section 8 instead.

8. **Backup strategy** — This README covers a manual `pg_dump` command but does not include an automated backup schedule. A recurring database backup (e.g. nightly cron job to S3 or another machine) should be configured before production use.

9. **Monitoring** — No external monitoring (Prometheus, Datadog, uptime alerting) is included. Consider adding uptime monitoring for the `/api/health` endpoint.
