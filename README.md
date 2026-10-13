# Pangolin Docker Stack (with Gerbil, Traefik v3.7 & CrowdSec AppSec WAF)

Production-ready deployment configuration for self-hosting [Pangolin](https://github.com/fosrl/pangolin) reverse-proxy and secure WireGuard tunnel manager, powered by **Gerbil**, **Traefik v3.7** with automatic Let's Encrypt TLS, and **CrowdSec AppSec WAF**.

All secrets and cryptographic keys are **automatically generated** via `./deploy.sh` on fresh installs. Existing installations are automatically detected and safely updated without overwriting secrets or wiping databases.

---

## Architecture Overview

```text
                                  Internet
                                     │
                     [Port 80 / 443 / 51820 / 21820]
                                     ▼
                            Target Host / VPS
   ┌─────────────────────────────────────────────────────────────┐
   │ Gerbil (WireGuard Network Namespace)                        │
   │  ├── Listens on 80/tcp, 443/tcp, 443/udp, 51820/udp, 21820/udp│
   │  │                                                          │
   │  └── Traefik v3.7 Proxy (service:gerbil network mode)       │
   │       ├── Automatic Let's Encrypt TLS Certificates          │
   │       ├── Dynamic routing synced via Pangolin HTTP endpoint │
   │       └── CrowdSec Traefik Bouncer Plugin                   │
   │                                                             │
   │ Pangolin Manager                                            │
   │  ├── Web Dashboard & REST API (/api/v1)                     │
   │  ├── Resource & Target Tunnel Management                    │
   │  └── Embedded SQLite Database (config/db)                   │
   │                                                             │
   │ CrowdSec Intrusion Prevention System                        │
   │  ├── Real-time AppSec WAF on Port 7422                      │
   │  ├── Traefik access log parser & remediation                │
   │  └── Community blocklists                                   │
   └─────────────────────────────────────────────────────────────┘
```

---

## Security, Rate Limiting & Protection Model

This stack implements multi-layered defense-in-depth across both the host OS and application layers:

### 1. SSH Rate Limiting & Brute-Force Defense
* **Key-Only Authentication**: Root password login and keyboard-interactive authentication are disabled.
* **Connection Throttling**: The SSH daemon disconnects sessions after 3 failed authentication attempts (`MaxAuthTries 3`).
* **Automated 24-Hour Firewall Ban**: Fail2ban monitors SSH connection attempts via an aggressive jail (`maxretry = 3`, `findtime = 10m`, `bantime = 24h`), dropping offending IPs at the firewall level.
* **CrowdSec SSH Tracking**: CrowdSec actively parses SSH authentication logs to detect and ban rapid brute-force attacks (`ssh-bf`), slow distributed attacks (`ssh-slow-bf`), and port scanning (`ssh-refused-conn`).

### 2. Application & API Rate Limiting (CrowdSec + Traefik)
* **Layer 7 AppSec WAF**: Traefik inspects inbound HTTP requests through the CrowdSec AppSec engine on port 7422, blocking virtual patches, SQLi, XSS, and directory probes (`.env`, `/.git`, etc.) with `403 Forbidden` before they reach Pangolin.
* **HTTP Brute-Force Protection (`http-generic-bf`)**: High-frequency repeated requests hammering login endpoints or API routes are automatically detected and banned.
* **Aggressive Web Scraper & Crawler Mitigation (`http-crawl-non_statics`)**: Automated high-velocity scrapers hitting non-static application endpoints are throttled and banned.
* **Global Threat Intelligence**: Traefik's CrowdSec bouncer continuously blocks malicious IP addresses distributed via the global CrowdSec consensus blocklist.

---

## Generic Placeholders & How to Replace Them

This repository uses generic placeholders throughout the documentation, configuration templates, and deploy scripts. When preparing your deployment, replace these placeholders with your actual server and domain values:

| Generic Placeholder | Description | Example Real-World Value | Where It Is Used |
| :--- | :--- | :--- | :--- |
| `yourdomain.com` | Your primary base domain | `example.org`, `mycompany.io` | `PANGOLIN_BASE_DOMAIN`, DNS root zone |
| `pangolin.yourdomain.com` | Subdomain allocated for the Pangolin management dashboard | `tunnels.example.org`, `pangolin.mycompany.io` | `PANGOLIN_DOMAIN`, DNS A record |
| `*.yourdomain.com` | Wildcard domain routing client traffic to created tunnels | `*.example.org`, `*.mycompany.io` | Wildcard DNS A record |
| `admin@yourdomain.com` | Administrator email for ACME TLS certificate registration | `noc@example.org`, `devops@mycompany.io` | `LETSENCRYPT_EMAIL`, Let's Encrypt notifications |
| `203.0.113.10` | Public IPv4 address of your VPS / Host server *(RFC 5737 placeholder)* | `198.51.100.42` | DNS **A** record target in your DNS provider |
| `48222` | Custom SSH port configured during OS bootstrap | Any custom port between `1024` and `65535` | `SSH_PORT` environment variable |
| `deploy` | Dedicated non-root user created for running services | Any standard username (e.g. `ubuntu`, `admin`) | `DEPLOY_USER` in `bootstrap-os.sh` |

---

## Supported Operating Systems & Required Binaries

`deploy.sh` is distro-agnostic and will run on **any modern Linux distribution** (Ubuntu, Debian, Fedora, Arch, Rocky, Alpine, etc.) provided the following CLI binaries are available in your `$PATH`:

| Binary | Minimum / Tested Version | Purpose in Stack | How to Install (Examples) |
| :--- | :--- | :--- | :--- |
| **`docker`** | `24.0+` (with Compose v2 plugin) | Container runtime and stack orchestration | Official Docker repo or distro package manager |
| **`openssl`** | `1.1.1` or `3.x` | Generates cryptographic server secrets & bouncer API keys | `apt install openssl` / `dnf install openssl` / `pacman -S openssl` |
| **`bash`** | `4.0+` | Script execution environment (`set -euo pipefail`) | Standard shell (`/bin/bash`) |
| **`sed`** | GNU `sed` or standard BSD | Instantiates runtime templates from `.example` files | Pre-installed on almost all distros |
| **`curl`** or **`dig`** | Any | DNS verification and endpoint health checks | `apt install dnsutils curl` / `dnf install bind-utils curl` |

### Distribution Support Level:
* **Ubuntu & Debian:** Running `./bootstrap-os.sh` automates the entire OS setup (Docker, UFW firewall, Fail2ban with aggressive SSH jail).
* **Fedora, RHEL, Rocky, AlmaLinux, Arch, openSUSE:**
  1. Install `docker` and `openssl` via your native package manager (`dnf`, `pacman`, `zypper`).
  2. Fail2ban will automatically use your native firewall (e.g. `firewallcmd-rich-rules` on RHEL/Fedora or `nftables` on Arch).
  3. Allow Pangolin's required ports in your native firewall (e.g., for `firewalld`):
     ```bash
     sudo firewall-cmd --permanent --add-port=48222/tcp  # Your custom SSH port
     sudo firewall-cmd --permanent --add-port=80/tcp     # ACME / HTTP
     sudo firewall-cmd --permanent --add-port=443/tcp    # HTTPS / Websecure
     sudo firewall-cmd --permanent --add-port=443/udp    # HTTP/3 / QUIC
     sudo firewall-cmd --permanent --add-port=51820/udp  # Gerbil WireGuard tunnel
     sudo firewall-cmd --permanent --add-port=21820/udp  # Gerbil WireGuard data tunnel
     sudo firewall-cmd --reload
     ```
  4. Run `./deploy.sh` directly.

---

## Step-by-Step Deployment Guide

### Step 1: DNS Setup

Pangolin requires two DNS **A records** in your domain registrar or DNS management dashboard (e.g., Cloudflare, Namecheap, Porkbun, GoDaddy, AWS Route 53, Hetzner, etc.):

| Record Type | Host / Name | Target / Value | TTL | Proxy Status *(Cloudflare)* | Explanation |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **A** | `pangolin` | `203.0.113.10` | `Auto` or `300` | **DNS only (Grey Cloud) ☁️** | Routes the management dashboard (`pangolin.yourdomain.com`) |
| **A** | `*` *(wildcard)* | `203.0.113.10` | `Auto` or `300` | **DNS only (Grey Cloud) ☁️** | Routes any tunnel you create (`*.yourdomain.com`) |

*(Replace `203.0.113.10` with your actual VPS public IPv4 address!)*

> [!WARNING]
> **If using Cloudflare:** You **MUST set both records to "DNS only" (Grey cloud)**!
> Pangolin and Gerbil handle raw WireGuard tunneling (`51820/udp`, `21820/udp`) and issue their own TLS certificates via Let's Encrypt. Enabling Cloudflare's HTTP proxy (Orange Cloud) will block tunnel handshakes and disrupt ACME certificate issuance.

Verify DNS propagation before proceeding:
```bash
# Verify dashboard:
dig +short pangolin.yourdomain.com

# Verify wildcard routing:
dig +short test.yourdomain.com
```

---

### Step 2: Base OS Setup & Hardening (Run as root)

Run the included idempotent bootstrap script to configure SSH hardening, Fail2ban, UFW, and install Docker Engine with Compose:

```bash
# Optional: customize SSH port (default is 48222)
export SSH_PORT=48222
sudo bash bootstrap-os.sh
```

**What this does:**
1. Updates system packages and installs prerequisites (`curl`, `ufw`, `fail2ban`, `htop`, `openssl`, etc.).
2. Creates a dedicated `deploy` user with passwordless `sudo` privileges.
3. Configures SSH hardening on the custom port, disabling root password login and keyboard-interactive authentication.
4. Configures Fail2ban with an aggressive SSH jail linked to UFW.
5. Configures UFW firewall to allow only required ports (`SSH`, `80/tcp`, `443/tcp`, `443/udp`, `51820/udp`, `21820/udp`).
6. Installs upstream Docker Engine and the Docker Compose plugin.
7. Configures Docker daemon log rotation to prevent disk exhaustion.

---

### Step 3: Deploy Pangolin Stack

Clone this repository to your target deployment directory (e.g. `/opt/pangolin`) and run `deploy.sh`:

```bash
# Specify your dashboard domain, base domain, and Let's Encrypt email:
export PANGOLIN_DOMAIN="pangolin.yourdomain.com"
export PANGOLIN_BASE_DOMAIN="yourdomain.com"
export LETSENCRYPT_EMAIL="admin@yourdomain.com"

./deploy.sh
```

*Alternatively, pass variables inline:*
```bash
PANGOLIN_DOMAIN="pangolin.yourdomain.com" PANGOLIN_BASE_DOMAIN="yourdomain.com" LETSENCRYPT_EMAIL="admin@yourdomain.com" ./deploy.sh
```

**What happens automatically:**
* `config/config.yml` is generated with an auto-generated cryptographic `server.secret`.
* `config/traefik/dynamic_config.yml` is generated with an auto-generated `crowdsecLapiKey`.
* `config/traefik/traefik_config.yml` is generated from template with your Let's Encrypt email.
* Gerbil WireGuard keys are automatically generated in `config/key`.
* Docker Compose brings up Pangolin, Gerbil, Traefik, and CrowdSec.
* Traefik bouncer is automatically registered with CrowdSec.
* Traefik provisions Let's Encrypt SSL certificates.

---

## Safe In-Place Updates (Zero Secret Overwrites)

When updating an existing Pangolin server (for example, pulling new images or updating configuration from Git):

```bash
cd /opt/pangolin
git pull
./deploy.sh
```

### Safety Guarantees:
* **No domain prompt needed:** The script automatically detects the domain already configured in `config/config.yml`.
* **Zero secret overwrites:** Existing `config.yml`, `dynamic_config.yml`, `traefik_config.yml`, and `config/key` are **preserved untouched**.
* **Zero database wipes:** Embedded database files in `config/db/` persist across updates.
* **Minimal downtime:** Docker Compose only restarts containers whose configuration or image has changed.

---

## Updating CrowdSec Security Rules & AppSec WAF

To pull the latest community IP blocklists, CVE scenarios, and AppSec virtual patches without restarting or rebuilding the stack:

```bash
./deploy.sh --update-rules
```
*(This triggers `cscli hub update && cscli hub upgrade` inside the CrowdSec container with 0 downtime).*

---

## Disaster Recovery & Database Backup / Restore

If rebuilding a VPS from scratch and you want your **existing Pangolin users, organizations, targets, and tunnels** restored:

### Step 1: Deploy the Stack
```bash
export PANGOLIN_DOMAIN="pangolin.yourdomain.com"
export PANGOLIN_BASE_DOMAIN="yourdomain.com"
export LETSENCRYPT_EMAIL="admin@yourdomain.com"

./deploy.sh
```

### Step 2: Restore Database & WireGuard Key
1. Stop the Pangolin services:
   ```bash
   docker compose stop pangolin gerbil
   ```
2. Copy your database backup into `config/`:
   ```bash
   cp -r /path/to/backup/db/ /opt/pangolin/config/
   cp /path/to/backup/key /opt/pangolin/config/
   ```
3. Restart the services:
   ```bash
   docker compose start pangolin gerbil
   ```
All tunnels and users will immediately reconnect!

---

## Verification & Health Testing

Verify that your Pangolin deployment is healthy and protected by CrowdSec AppSec:

```bash
# 1. Normal dashboard access returns 200 OK:
curl -ks -I https://pangolin.yourdomain.com

# 2. Malicious probe returns 403 Forbidden (blocked by CrowdSec AppSec WAF):
curl -ks -I https://pangolin.yourdomain.com/.env
```

Check AppSec metrics and registered bouncers inside the CrowdSec container:
```bash
docker exec crowdsec cscli metrics show appsec
docker exec crowdsec cscli alerts list
docker exec crowdsec cscli bouncers list
```

---

## Pinned Versions

All images are pinned to tested, immutable versions to prevent unexpected breaking changes:
* **Pangolin Manager:** `docker.io/fosrl/pangolin:ee-1.23.0`
* **Gerbil Tunnel:** `docker.io/fosrl/gerbil:1.5.2`
* **Traefik Proxy:** `docker.io/traefik:v3.7`
* **CrowdSec:** `docker.io/crowdsecurity/crowdsec:v1.8.1`

---

## License

This project is licensed under the [MIT License](LICENSE).
