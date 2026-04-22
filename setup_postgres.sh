#!/usr/bin/env bash
# ================================================================
#  One-time PostgreSQL setup for the Bridge
#  Run this on the machine where PostgreSQL will run.
# ================================================================
set -euo pipefail

echo "── Installing PostgreSQL ──────────────────────────"
sudo apt update
sudo apt install -y postgresql postgresql-client

sudo systemctl enable --now postgresql

echo "── Creating database and user ─────────────────────"
sudo -u postgres psql <<'SQL'
CREATE USER bridge WITH PASSWORD 'bridge';
CREATE DATABASE bridge OWNER bridge;
GRANT ALL PRIVILEGES ON DATABASE bridge TO bridge;
SQL

echo "── Verifying connection ───────────────────────────"
PGPASSWORD=bridge psql -h localhost -U bridge -d bridge -c "SELECT 'PostgreSQL ready' AS status;"

echo ""
echo "Done. The bridge will create tables automatically on first start."
echo ""
echo "Add these to your .env (or export them):"
echo "  PG_HOST=localhost"
echo "  PG_PORT=5432"
echo "  PG_DB=bridge"
echo "  PG_USER=bridge"
echo "  PG_PASS=bridge"
echo ""
echo "  # --- Login (REQUIRED in production) ---"
echo "  ADMIN_USER=admin"
echo "  ADMIN_PASS=<pick-a-strong-password>"
echo "  SESSION_SECRET=<32+ random chars, e.g. openssl rand -hex 32>"
echo "  SESSION_HTTPS_ONLY=true   # once you're behind HTTPS"
