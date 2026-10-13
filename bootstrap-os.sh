#!/usr/bin/env bash
set -euo pipefail

# VPS Bootstrap & OS Hardening Script
# Prepares a blank Ubuntu/Debian VPS with hardened SSH, Fail2ban, UFW, Docker, and kernel security.
# Run as root.

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root." >&2
   exit 1
fi

SSH_PORT="${SSH_PORT:-39422}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE="${FORCE:-false}"

# --- 0. PRE-FLIGHT CHECK: VERIFY AND LOCATE SSH AUTHORIZED KEYS ---
AUTH_KEYS_FILE=""
if [[ -s "/root/.ssh/authorized_keys" ]]; then
  AUTH_KEYS_FILE="/root/.ssh/authorized_keys"
elif [[ -s "/home/${DEPLOY_USER}/.ssh/authorized_keys" ]]; then
  AUTH_KEYS_FILE="/home/${DEPLOY_USER}/.ssh/authorized_keys"
fi

if [[ -z "${AUTH_KEYS_FILE}" ]]; then
  echo "" >&2
  echo "================================================================================" >&2
  echo " [FATAL ERROR] No SSH authorized public key detected!" >&2
  echo "================================================================================" >&2
  echo " You must install an SSH public key before running bootstrap to prevent lockout:" >&2
  echo "   ssh-copy-id root@<vps-ip>" >&2
  echo "" >&2
  echo " Aborting to prevent lockout. No changes were made." >&2
  echo "================================================================================" >&2
  exit 1
fi

echo "================================================================================"
echo " ==> VPS Bootstrap & Hardening Configuration Summary"
echo " Target Dedicated User: ${DEPLOY_USER}"
echo " Custom SSH Port:       ${SSH_PORT}"
echo " Authorized SSH Key(s):"
ssh-keygen -lf "${AUTH_KEYS_FILE}" 2>/dev/null | sed 's/^/   /' || sed 's/^/   /' "${AUTH_KEYS_FILE}"
echo " Password Policy:       Lock root password, enforce SSH keys, passwordless sudo"
echo " Firewall (UFW):        Deny inbound, allow ports ${SSH_PORT}, 80, 443, 3478, 51820, 21820"
echo " Security Tools:        Fail2ban, unattended-upgrades, kernel network hardening"
echo "================================================================================"

if [[ "${FORCE}" != "true" ]] && [[ -t 0 ]]; then
  read -r -p "Proceed with these bootstrap settings? [y/N]: " confirm
  if [[ "${confirm}" != [yY] && "${confirm}" != [yY][eE][sS] ]]; then
    echo "Aborted by user. No changes were made."
    exit 1
  fi
fi

echo ""
echo "==> 1. Updating base packages & installing security tools..."
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get upgrade -y
apt-get install -y curl ufw fail2ban git sudo htop openssl ca-certificates gnupg lsb-release unattended-upgrades

# Enable automatic security upgrades
systemctl enable --now unattended-upgrades || true

echo "==> 2. Setting up dedicated user (${DEPLOY_USER})..."
if ! id "${DEPLOY_USER}" &>/dev/null; then
  useradd -m -s /bin/bash "${DEPLOY_USER}"
  usermod -aG sudo "${DEPLOY_USER}"
  echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${DEPLOY_USER}"
  chmod 0440 "/etc/sudoers.d/${DEPLOY_USER}"
fi

# Ensure user authorized_keys is populated with strict permissions
mkdir -p "/home/${DEPLOY_USER}/.ssh"
cp "${AUTH_KEYS_FILE}" "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
chmod 700 "/home/${DEPLOY_USER}/.ssh"
chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"

# Lock root account password (keys only, no password brute force)
passwd -l root 2>/dev/null || true

echo "==> 3. Applying Kernel Network Hardening (/etc/sysctl.d/99-security.conf)..."
cat > /etc/sysctl.d/99-security.conf << 'EOF'
# IP spoofing protection (Reverse Path Filtering)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Disable ICMP redirect acceptance (MITM protection)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Do not send ICMP redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Disable source-routed packets
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Log suspicious / martian packets
net.ipv4.conf.all.log_martians = 1

# Ignore ICMP broadcast storms and bogus error responses
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# SYN Flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
EOF
sysctl --system >/dev/null 2>&1 || true

echo "==> 4. Configuring UFW Firewall with Safe Transition..."
ufw default deny incoming
ufw default allow outgoing
# Temporarily allow port 22 to prevent kicking out existing sessions
ufw allow 22/tcp comment "SSH temporary bootstrap"
ufw allow "${SSH_PORT}/tcp" comment "SSH custom port"
ufw allow 80/tcp comment "HTTP - Web / ACME"
ufw allow 443/tcp comment "HTTPS - TLS"
ufw allow 443/udp comment "HTTPS - QUIC / HTTP3"
ufw allow 3478/udp comment "STUN/TURN - NetBird"
ufw allow 51820/udp comment "WireGuard Relay - NetBird / Gerbil"
ufw allow 21820/udp comment "WireGuard Tunnel - Gerbil"
ufw --force enable

echo "==> 5. Configuring SSH Hardening (Port ${SSH_PORT})..."
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-hardening.conf << EOF
Port ${SSH_PORT}
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
chmod 644 /etc/ssh/sshd_config.d/00-hardening.conf

# Validate syntax before reloading
if sshd -t; then
  systemctl reload ssh || systemctl reload sshd || true
else
  echo "[WARN] sshd configuration test failed! Keeping current SSH daemon state." >&2
fi

# Now remove the temporary port 22 rule from UFW
ufw delete allow 22/tcp >/dev/null 2>&1 || true

echo "==> 6. Configuring Fail2ban (Port ${SSH_PORT})..."
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port = ${SSH_PORT}
mode = aggressive
backend = systemd
EOF
systemctl restart fail2ban || true
systemctl enable fail2ban || true

echo "==> 7. Installing Docker Engine & Docker Compose Plugin..."
if ! command -v docker &>/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]')/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

usermod -aG docker "${DEPLOY_USER}"

# Configure Docker daemon log rotation to prevent disk exhaustion
mkdir -p /etc/docker
if [[ ! -f /etc/docker/daemon.json ]]; then
  cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
EOF
fi

systemctl enable docker || true
systemctl restart docker || true

echo "================================================================================"
echo " ==> [SUCCESS] VPS bootstrap & hardening complete!"
echo " User:           ${DEPLOY_USER}"
echo " SSH Port:       ${SSH_PORT}"
echo " Next Step:      Log in via 'ssh -p ${SSH_PORT} ${DEPLOY_USER}@<vps-ip>'"
echo "                 and set user password with 'sudo passwd ${DEPLOY_USER}'."
echo "================================================================================"
