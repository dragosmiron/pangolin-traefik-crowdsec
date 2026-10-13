# Security & Protection Model

This stack implements defense-in-depth across the host OS, network ingress, and application layers.

---

## 1. Host OS Hardening (`bootstrap-os.sh`)

- **SSH Hardening**:
  - Root password login and keyboard-interactive authentication are locked (`PermitRootLogin prohibit-password`, `PasswordAuthentication no`).
  - Strict connection throttling: SSH daemon disconnects sessions after 3 failed attempts (`MaxAuthTries 3`).
  - Custom non-standard SSH port configurable via `SSH_PORT` (default: `48222`).
- **Fail2ban 24-Hour Firewall Ban**:
  - Aggressive jail (`maxretry = 3`, `findtime = 10m`, `bantime = 24h`).
  - Offending IPs failing authentication 3 times are immediately dropped at the firewall level for 24 hours.
- **Kernel Network Hardening (`/etc/sysctl.d/99-security.conf`)**:
  - SYN flood protection (`tcp_syncookies = 1`, `tcp_max_syn_backlog = 2048`).
  - IP spoofing protection (Strict reverse path filtering `rp_filter = 1`).
  - ICMP redirect ignores and broadcast storm protection.
- **Firewall Policy (UFW)**:
  - Default policy: `deny incoming`, `allow outgoing`.
  - Only required ports are whitelisted: SSH, `80/tcp`, `443/tcp,udp`, `51820/udp`, `21820/udp`.

---

## 2. Edge Reverse Proxy (Traefik v3.7)

- **Automated TLS**: Auto-provisions and renews Let's Encrypt certificates via TLS-ALPN-01 / HTTP challenges.
- **Security Headers**: Injects HSTS (`max-age=63072000; includeSubDomains; preload`), `X-Frame-Options: SAMEORIGIN`, and `X-Content-Type-Options: nosniff`.
- **CrowdSec Traefik Bouncer Plugin**: Runs in Stream Mode, querying local CrowdSec API every 15 seconds to cache decisions in memory for sub-millisecond request validation.

---

## 3. Application Security & WAF (CrowdSec AppSec)

- **Layer 7 AppSec Inspection**: Inbound requests pass through CrowdSec's AppSec engine on port `7422`.
- **Virtual Patching**: Blocks exploits, SQLi, XSS, and directory probes (`.env`, `/.git`, path traversal) with `403 Forbidden` before they reach Pangolin.
- **Behavioral Rate Limiting**:
  - `crowdsecurity/http-generic-bf`: Automatically bans clients attempting high-frequency brute-force attacks.
  - `crowdsecurity/http-crawl-non_statics`: Mitigates aggressive scraping and crawling against dynamic endpoints.
- **Global Consensus Blocklists**: Community-driven threat intelligence continuously updates blocked malicious IPs.

---

## Manual Firewall Configuration (Non-Debian Distributions)

If deploying on RHEL, Fedora, Rocky, or Arch instead of using `bootstrap-os.sh`:
```bash
# Example for firewalld:
sudo firewall-cmd --permanent --add-port=48222/tcp  # Custom SSH port
sudo firewall-cmd --permanent --add-port=80/tcp     # ACME / HTTP
sudo firewall-cmd --permanent --add-port=443/tcp    # HTTPS / Websecure
sudo firewall-cmd --permanent --add-port=443/udp    # HTTP/3 / QUIC
sudo firewall-cmd --permanent --add-port=51820/udp  # Gerbil WireGuard tunnel
sudo firewall-cmd --permanent --add-port=21820/udp  # Gerbil WireGuard data tunnel
sudo firewall-cmd --reload
```
