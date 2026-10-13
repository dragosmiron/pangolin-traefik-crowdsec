# Pangolin Backup & Disaster Recovery Guide

When rebuilding a server from scratch or migrating to a new VPS, follow this guide to restore all your existing Pangolin users, organizations, targets, and tunnels.

---

## 1. What Needs to be Backed Up?

Only two items are required for a complete restore:
1. `config/db/` (Contains the SQLite database files with your users, organizations, and tunnel definitions)
2. `config/key` (Contains the Gerbil WireGuard private key)

---

## 2. Backup Procedure

From inside `/opt/pangolin`:
```bash
# Create an archive of database and keys
tar -czvf pangolin-backup-$(date +%F).tar.gz config/db/ config/key
```

Save this `.tar.gz` file securely off-site (e.g. to S3, encrypted local storage, or your password manager).

---

## 3. Restore Procedure on a Fresh VPS

### Step 1: Deploy Fresh Stack
Deploy the stack as documented in the main README:
```bash
export PANGOLIN_DOMAIN="pangolin.yourdomain.com"
export PANGOLIN_BASE_DOMAIN="yourdomain.com"
export LETSENCRYPT_EMAIL="admin@yourdomain.com"

./deploy.sh
```

### Step 2: Stop Services & Restore Files
```bash
# 1. Stop Pangolin and Gerbil
docker compose stop pangolin gerbil

# 2. Extract your backup into config/
tar -xzvf pangolin-backup-YYYY-MM-DD.tar.gz

# 3. Start services
docker compose start pangolin gerbil
```

All connected clients, WireGuard tunnels, and user sessions will immediately reconnect without re-configuration.
