#!/usr/bin/env bash
set -euo pipefail

# VPS Bootstrap & OS Hardening Script for Pangolin Stack
# Prepares a blank Ubuntu/Debian VPS with hardened SSH, Fail2ban, UFW, and Docker.
# Run as root.

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root." >&2
   exit 1
fi

SSH_PORT="${SSH_PORT:-48222}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> 1. Updating base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get upgrade -y
apt-get install -y curl ufw fail2ban git sudo htop openssl ca-certificates gnupg lsb-release

echo "==> 2. Setting up deploy user (${DEPLOY_USER})..."
if ! id "${DEPLOY_USER}" &>/dev/null; then
  useradd -m -s /bin/bash "${DEPLOY_USER}"
  usermod -aG sudo "${DEPLOY_USER}"
  echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${DEPLOY_USER}"
  chmod 0440 "/etc/sudoers.d/${DEPLOY_USER}"
  # Copy root authorized keys if present
  if [[ -f /root/.ssh/authorized_keys ]]; then
    mkdir -p "/home/${DEPLOY_USER}/.ssh"
    cp /root/.ssh/authorized_keys "/home/${DEPLOY_USER}/.ssh/"
    chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
    chmod 700 "/home/${DEPLOY_USER}/.ssh"
    chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"
  fi
fi

echo "==> 3. Configuring SSH Hardening (Port ${SSH_PORT})..."
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
systemctl reload ssh || systemctl reload sshd

echo "==> 4. Configuring Fail2ban (Port ${SSH_PORT})..."
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3
banaction = ufw
banaction_allports = ufw

[sshd]
enabled = true
port = ${SSH_PORT}
mode = aggressive
backend = systemd
EOF
systemctl restart fail2ban
systemctl enable fail2ban

echo "==> 5. Configuring UFW Firewall for Pangolin..."
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment "SSH custom port"
ufw allow 80/tcp comment "HTTP - ACME / Let's Encrypt & Web"
ufw allow 443/tcp comment "HTTPS - TLS & Dashboard"
ufw allow 443/udp comment "HTTPS - QUIC / HTTP3"
ufw allow 51820/udp comment "WireGuard - Gerbil tunnel endpoint"
ufw allow 21820/udp comment "WireGuard - Gerbil client tunnel"
ufw --force enable

echo "==> 6. Installing Docker Engine & Docker Compose Plugin..."
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

systemctl enable docker
systemctl restart docker

echo "==> [SUCCESS] Pangolin host bootstrap complete! SSH is on port ${SSH_PORT}."
