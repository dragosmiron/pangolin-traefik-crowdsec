# Pangolin Docker Stack (with Gerbil, Traefik v3.7 & CrowdSec AppSec WAF)

Production-ready deployment configuration for self-hosting [Pangolin](https://github.com/fosrl/pangolin) reverse-proxy and secure WireGuard tunnel manager, protected by **Traefik v3.7** with automatic Let's Encrypt TLS and **CrowdSec AppSec WAF**.

---

## Why Use This Stack vs. Standard Install?

| Feature | Standard Docker Install | This Hardened Stack |
| :--- | :--- | :--- |
| **Edge Protection** | Exposed directly to internet | **CrowdSec AppSec WAF** blocks `.env` scans, SQLi, and exploits with 403 Forbidden |
| **TLS & Routing** | Manual certbot / reverse proxy setup | **Traefik v3.7** with automated Let's Encrypt TLS & HTTP/3 (QUIC) support |
| **Secrets & Keys** | Manual generation in YAML files | **Zero-touch**: Cryptographic keys & bouncer tokens auto-generated on fresh deploy |
| **OS Security** | Default OS settings | **`bootstrap-os.sh`** configures UFW firewall, Fail2ban 24h jail, and kernel hardening |
| **Updates** | Risk of overwriting live configs | **Safe in-place updates**: Preserves existing secrets, keys, and SQLite databases |

---

## Configuration Variables

Replace these generic placeholders with your real values during deployment:

| Variable | Description | Example Value | Where Used |
| :--- | :--- | :--- | :--- |
| `PANGOLIN_DOMAIN` | Dashboard subdomain | `pangolin.yourdomain.com` | Web UI & API endpoint |
| `PANGOLIN_BASE_DOMAIN` | Base domain for created tunnels | `yourdomain.com` | Tunnel subdomain routing |
| `LETSENCRYPT_EMAIL` | Admin email for TLS notices | `admin@yourdomain.com` | Let's Encrypt certificate registration |
| `203.0.113.10` | Public IPv4 of your VPS | `198.51.100.42` | DNS **A** record target |

---

## Quick Start (3 Steps)

### 1. DNS Setup
Add two **A records** in your DNS provider (e.g. Cloudflare, Porkbun, Namecheap):

| Record Type | Host / Name | Target / IPv4 | Proxy Status *(Cloudflare)* | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| **A** | `pangolin` | `203.0.113.10` | **DNS only (Grey Cloud) ☁️** | Management dashboard |
| **A** | `*` *(wildcard)* | `203.0.113.10` | **DNS only (Grey Cloud) ☁️** | Dynamic tunnels created under base domain |

> [!WARNING]
> Set records to **DNS only (Grey cloud)**. Cloudflare CDN proxying blocks raw WireGuard UDP (`51820/udp`, `21820/udp`).

### 2. Base OS Hardening (Run as root)
Prepares a fresh Ubuntu/Debian VPS with hardened SSH, UFW firewall, Fail2ban, and Docker:

```bash
# Optional: customize SSH port (default is 48222)
export SSH_PORT=48222
sudo bash bootstrap-os.sh
```

### 3. Deploy Stack
Clone to your target deployment directory (e.g. `/opt/pangolin`) and run `deploy.sh`:

```bash
cd /opt/pangolin
PANGOLIN_DOMAIN="pangolin.yourdomain.com" PANGOLIN_BASE_DOMAIN="yourdomain.com" LETSENCRYPT_EMAIL="admin@yourdomain.com" ./deploy.sh
```

---

## Common Operations

### Safe In-Place Updates
Pull latest updates without touching existing secrets or wiping databases:
```bash
cd /opt/pangolin && git pull && ./deploy.sh
```

### Update CrowdSec Security Rules & Threat Intelligence
Pull latest CVE scenarios, IP blocklists, and virtual patches with zero downtime:
```bash
./deploy.sh --update-rules
```

### Verify Health & WAF Protection
```bash
# Normal dashboard access returns 200 OK:
curl -ks -I https://pangolin.yourdomain.com

# Malicious probe returns 403 Forbidden (dropped by CrowdSec AppSec WAF):
curl -ks -I https://pangolin.yourdomain.com/.env
```

---

## Detailed Documentation

- [Security, Rate Limiting & Firewall Guide](docs/security.md)
- [Backup & Disaster Recovery Guide](docs/backup-restore.md)

---

## Pinned Versions

- **Pangolin Manager:** `fosrl/pangolin:ee-1.23.0`
- **Gerbil WireGuard Tunnel:** `fosrl/gerbil:1.5.2`
- **Traefik Reverse Proxy:** `traefik:v3.7`
- **CrowdSec IPS & WAF:** `crowdsecurity/crowdsec:v1.8.1`

---

## License

This project is licensed under the [MIT License](LICENSE).
