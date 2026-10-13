#!/usr/bin/env bash
set -euo pipefail

# Pangolin Stack Deployment Script
# Supports:
#   1. Running from scratch on a blank VPS (requires PANGOLIN_DOMAIN and PANGOLIN_BASE_DOMAIN)
#   2. Running on an existing VPS (safely detects domain and updates containers without overwriting)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Dedicated option to update CrowdSec threat intelligence & AppSec virtual patches
if [[ "${1:-}" == "--update-rules" ]] || [[ "${1:-}" == "--update-security" ]]; then
  echo "==> [Pangolin] Updating CrowdSec Hub rules & AppSec virtual patches..."
  docker compose exec -T crowdsec cscli hub update
  docker compose exec -T crowdsec cscli hub upgrade
  docker compose exec -T crowdsec cscli reload
  echo "==> [Pangolin] CrowdSec security rules updated successfully."
  exit 0
fi

echo "==> [Pangolin] Checking environment & dependencies..."

# Ensure required CLI utilities are installed
if ! command -v openssl &>/dev/null; then
  echo "    --> Installing missing dependency: openssl..."
  if command -v apt-get &>/dev/null; then
    sudo apt-get update -y && sudo apt-get install -y openssl
  elif command -v yum &>/dev/null; then
    sudo yum install -y openssl
  else
    echo "    [ERROR] 'openssl' is required to generate cryptographic secrets but could not be installed." >&2
    exit 1
  fi
fi

if ! command -v docker &>/dev/null; then
  echo "    [ERROR] 'docker' is not installed! Please run ./bootstrap-os.sh first." >&2
  exit 1
fi

# 1. Detect domain and email if already configured on an existing deployment
EXISTING_DOMAIN=""
EXISTING_BASE=""
EXISTING_EMAIL=""
if [[ -f config/config.yml ]]; then
  EXISTING_DOMAIN="$(grep 'dashboard_url:' config/config.yml | head -n1 | cut -d ':' -f2- | sed -e 's|https://||' -e 's|http://||' -e 's|/.*||' | tr -d '\"' | tr -d ' ' || true)"
  EXISTING_BASE="$(grep 'base_domain:' config/config.yml | head -n1 | cut -d ':' -f2- | tr -d '\"' | tr -d ' ' || true)"
fi

if [[ -f config/traefik/traefik_config.yml ]]; then
  EXISTING_EMAIL="$(grep '^[[:space:]]*email:' config/traefik/traefik_config.yml | head -n1 | awk '{print $2}' | tr -d " \"'" || true)"
  if [[ "${EXISTING_EMAIL}" == "admin@yourdomain.com" ]]; then
    EXISTING_EMAIL=""
  fi
fi

DOMAIN="${PANGOLIN_DOMAIN:-${EXISTING_DOMAIN}}"
BASE_DOMAIN="${PANGOLIN_BASE_DOMAIN:-${EXISTING_BASE}}"
LE_EMAIL="${LETSENCRYPT_EMAIL:-${EXISTING_EMAIL:-admin@${BASE_DOMAIN}}}"

# 2. If no domain is configured and none was provided, FAIL WITH HOW-TO GUIDE
if [[ -z "${DOMAIN}" ]] || [[ -z "${BASE_DOMAIN}" ]]; then
  echo "" >&2
  echo "================================================================================" >&2
  echo " [ERROR] PANGOLIN_DOMAIN or PANGOLIN_BASE_DOMAIN is not set!" >&2
  echo "================================================================================" >&2
  echo " No existing Pangolin deployment was detected in this directory." >&2
  echo "" >&2
  echo " To deploy Pangolin from scratch, specify your domain and base domain:" >&2
  echo "" >&2
  echo "   export PANGOLIN_DOMAIN=\"pangolin.yourdomain.com\"" >&2
  echo "   export PANGOLIN_BASE_DOMAIN=\"yourdomain.com\"" >&2
  echo "   export LETSENCRYPT_EMAIL=\"admin@yourdomain.com\"" >&2
  echo "   ./deploy.sh" >&2
  echo "" >&2
  echo " Or pass inline:" >&2
  echo "   PANGOLIN_DOMAIN=\"pangolin.yourdomain.com\" PANGOLIN_BASE_DOMAIN=\"yourdomain.com\" ./deploy.sh" >&2
  echo "" >&2
  echo " See README.md for the complete step-by-step guide." >&2
  echo "================================================================================" >&2
  exit 1
fi

mkdir -p config/traefik/logs config/letsencrypt config/crowdsec/acquis.d config/db

FORCE="${FORCE:-false}"

echo ""
echo "================================================================================"
echo " ==> Deployment Configuration Summary"
echo " Dashboard Domain:    ${DOMAIN}"
echo " Base Domain:         ${BASE_DOMAIN}"
echo " Let's Encrypt Email: ${LE_EMAIL}"
echo " Deployment Type:     $([[ -n "${EXISTING_DOMAIN}" ]] && echo 'Existing In-Place Update' || echo 'Fresh Installation')"
echo "================================================================================"
echo " To customize these values (e.g. PANGOLIN_DOMAIN, PANGOLIN_BASE_DOMAIN), see README.md."
echo " Press Ctrl+C or answer 'n' to abort and adjust your environment variables."
echo "================================================================================"

if [[ "${FORCE}" != "true" ]] && [[ -t 0 ]]; then
  read -r -p "Proceed with these settings? [y/N]: " confirm
  if [[ "${confirm}" != [yY] && "${confirm}" != [yY][eE][sS] ]]; then
    echo "Aborted by user. No changes were made."
    exit 1
  fi
fi

# 3. Generate config/traefik/traefik_config.yml if missing
if [[ ! -f config/traefik/traefik_config.yml ]]; then
  if [[ -f configs/traefik_config.yml.example ]]; then
    echo "    --> Creating config/traefik/traefik_config.yml with Let's Encrypt email..."
    sed -e "s|admin@yourdomain\.com|${LE_EMAIL}|g" \
        -e "s|email: .*|email: ${LE_EMAIL}|g" \
        configs/traefik_config.yml.example > config/traefik/traefik_config.yml
    chmod 644 config/traefik/traefik_config.yml
  else
    echo "    [WARN] config/traefik/traefik_config.yml missing and configs/traefik_config.yml.example not found." >&2
  fi
elif [[ -n "${LETSENCRYPT_EMAIL:-}" ]]; then
  # Only update email if explicitly passed via CLI/env
  sed -i.bak -e "s|email: .*|email: ${LETSENCRYPT_EMAIL}|g" config/traefik/traefik_config.yml && rm -f config/traefik/traefik_config.yml.bak
fi

# 4. Generate config/config.yml if missing
if [[ ! -f config/config.yml ]]; then
  if [[ -f configs/config.yml.example ]]; then
    echo "    --> Creating config/config.yml with auto-generated server secret..."
    SECRET="$(openssl rand -base64 32)"
    sed -e "s|pangolin\.example\.com|${DOMAIN}|g" \
        -e "s|example\.com|${BASE_DOMAIN}|g" \
        -e "s|secret: \"GENERATE_RANDOM_BASE64_32_CHARS\"|secret: \"${SECRET}\"|g" \
        configs/config.yml.example > config/config.yml
    chmod 600 config/config.yml
  else
    echo "    [WARN] config/config.yml missing and configs/config.yml.example not found." >&2
  fi
fi

# 5. Generate config/traefik/dynamic_config.yml if missing
if [[ ! -f config/traefik/dynamic_config.yml ]]; then
  if [[ -f configs/dynamic_config.yml.example ]]; then
    echo "    --> Creating config/traefik/dynamic_config.yml with auto-generated CrowdSec LAPI key..."
    LAPI_KEY="$(openssl rand -base64 32)"
    sed -e "s|pangolin\.example\.com|${DOMAIN}|g" \
        -e "s|crowdsecLapiKey: GENERATE_CROWDSEC_LAPI_KEY|crowdsecLapiKey: ${LAPI_KEY}|g" \
        configs/dynamic_config.yml.example > config/traefik/dynamic_config.yml
    chmod 600 config/traefik/dynamic_config.yml
  else
    echo "    [WARN] config/traefik/dynamic_config.yml missing and configs/dynamic_config.yml.example not found." >&2
  fi
fi

echo "==> [Pangolin] Validating Docker Compose syntax..."
docker compose config --quiet

echo "==> [Pangolin] Starting services..."
docker compose up -d

echo "==> [Pangolin] Ensuring CrowdSec Traefik bouncer is registered..."
BOUNCER_KEY="$(grep 'crowdsecLapiKey:' config/traefik/dynamic_config.yml | awk '{print $2}' | tr -d '\"' || true)"
if [[ -n "${BOUNCER_KEY}" ]]; then
  for i in {1..30}; do
    if docker compose exec -T crowdsec cscli lapi status >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if ! docker compose exec -T crowdsec cscli bouncers list 2>/dev/null | grep -q 'traefik'; then
    docker compose exec -T crowdsec cscli bouncers add traefik-bouncer -k "${BOUNCER_KEY}" >/dev/null 2>&1 || true
  fi
fi

# 6. Ensure host logrotate is configured for Traefik access log
if [[ -d /etc/logrotate.d ]] && [[ ! -f /etc/logrotate.d/pangolin-traefik ]]; then
  if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
    sudo bash -c "cat > /etc/logrotate.d/pangolin-traefik << 'EOF'
${SCRIPT_DIR}/config/traefik/logs/access.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF" || true
  fi
fi

echo "==> [Pangolin] Status:"
docker compose ps

echo "==> [Pangolin] Deployment finished successfully."
