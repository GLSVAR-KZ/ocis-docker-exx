#!/usr/bin/env bash
# =============================================================================
# deploy-vps.sh — Deploy oCIS + Collaboration + OnlyOffice on Debian 12 VPS
#
# Domains
#   ocis.efimovsergei.ru       – Infinite Scale (oCIS) frontend
#   onlyoffice.efimovsergei.ru – OnlyOffice Document Server
#   wopi.efimovsergei.ru       – WOPI collaboration endpoint (optional; only
#                                needed when OnlyOffice runs outside Docker)
#
# Requirements
#   • Debian 12 (Bookworm), clean install recommended
#   • Root or sudo privileges
#   • Ports 80 and 443 open in the firewall / security group
#   • All three domains pointed at this server's public IP via DNS A records
#
# Usage
#   chmod +x deploy-vps.sh
#   sudo ./deploy-vps.sh
# =============================================================================

set -euo pipefail

# ─── Tuneable defaults (override with environment variables) ──────────────────
OCIS_DOMAIN="${OCIS_DOMAIN:-ocis.efimovsergei.ru}"
ONLYOFFICE_DOMAIN="${ONLYOFFICE_DOMAIN:-onlyoffice.efimovsergei.ru}"
WOPI_DOMAIN="${WOPI_DOMAIN:-wopi.efimovsergei.ru}"

# Email used by Let's Encrypt / ACME for certificate notifications.
ACME_EMAIL="${ACME_EMAIL:-}"

# Deployment directory on the VPS.
DEPLOY_DIR="${DEPLOY_DIR:-/opt/ocis}"

# Source repository.
REPO_URL="${REPO_URL:-https://github.com/GLSVAR-KZ/ocis-docker-exx.git}"

# Set to "true" to also expose the WOPI endpoint at ${WOPI_DOMAIN}.
# For the default all-in-one Docker setup this is NOT required because
# OnlyOffice reaches collaboration-oo over the internal Docker network.
ENABLE_WOPI_DOMAIN="${ENABLE_WOPI_DOMAIN:-false}"

# ─── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ─── Preflight checks ─────────────────────────────────────────────────────────
check_root() {
    [[ "$EUID" -eq 0 ]] || error "Please run this script as root or with sudo."
}

check_debian12() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        if [[ "$ID" != "debian" || "$VERSION_ID" != "12" ]]; then
            warn "This script is designed for Debian 12. Detected: ${PRETTY_NAME:-unknown}."
            warn "Proceeding anyway — some steps may fail on other distributions."
        fi
    else
        warn "/etc/os-release not found. Cannot verify OS."
    fi
}

check_dns() {
    info "Checking DNS resolution for configured domains …"
    local missing=()
    for domain in "$OCIS_DOMAIN" "$ONLYOFFICE_DOMAIN"; do
        if ! getent hosts "$domain" &>/dev/null; then
            missing+=("$domain")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "The following domains do not resolve yet: ${missing[*]}"
        warn "Let's Encrypt certificate issuance will fail until DNS is configured."
        warn "Continuing — Traefik will retry certificate requests automatically."
    else
        success "DNS looks good."
    fi
}

prompt_acme_email() {
    if [[ -z "$ACME_EMAIL" ]]; then
        echo -e "${BOLD}Enter the e-mail address for Let's Encrypt certificate notifications:${RESET}"
        read -rp "> " ACME_EMAIL
        [[ -n "$ACME_EMAIL" ]] || error "ACME e-mail is required."
    fi
}

prompt_admin_password() {
    if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
        echo -e "${BOLD}Enter the oCIS admin password (leave blank to auto-generate):${RESET}"
        read -rsp "> " ADMIN_PASSWORD
        echo
        if [[ -z "$ADMIN_PASSWORD" ]]; then
            ADMIN_PASSWORD="$(tr -dc 'A-Za-z0-9!@#%^&*()-_=+' </dev/urandom | head -c 24)"
            [[ -n "$ADMIN_PASSWORD" ]] || error "Failed to generate a random admin password. Set ADMIN_PASSWORD manually."
            info "Generated admin password: ${BOLD}${ADMIN_PASSWORD}${RESET}"
            warn "Save this password — it will not be shown again."
        fi
    fi
}

# ─── System setup ─────────────────────────────────────────────────────────────
install_prerequisites() {
    info "Updating package lists …"
    apt-get update -qq

    info "Installing prerequisite packages …"
    apt-get install -y -qq \
        ca-certificates \
        curl \
        gnupg \
        git \
        lsb-release \
        dnsutils \
        ufw 2>/dev/null || true
    success "Prerequisites installed."
}

install_docker() {
    if command -v docker &>/dev/null; then
        success "Docker is already installed ($(docker --version))."
        return
    fi

    info "Installing Docker Engine …"

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add the Docker apt repository
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/debian \
        $(lsb_release -cs) stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker
    success "Docker installed ($(docker --version))."
}

configure_firewall() {
    if ! command -v ufw &>/dev/null; then
        warn "ufw not found — skipping firewall configuration."
        return
    fi

    info "Configuring UFW firewall …"
    ufw allow OpenSSH   2>/dev/null || true
    ufw allow 80/tcp    2>/dev/null || true
    ufw allow 443/tcp   2>/dev/null || true
    # Enable only if not already active to avoid breaking the session
    if ! ufw status | grep -q "Status: active"; then
        ufw --force enable 2>/dev/null || true
    fi
    success "Firewall rules applied (SSH, HTTP, HTTPS)."
}

# ─── Repository ───────────────────────────────────────────────────────────────
setup_repo() {
    if [[ -d "$DEPLOY_DIR/.git" ]]; then
        info "Repository already present at ${DEPLOY_DIR}. Pulling latest changes …"
        if ! git -C "$DEPLOY_DIR" pull --ff-only; then
            warn "git pull failed (possible local changes or merge conflict)."
            warn "Resolve manually in ${DEPLOY_DIR}, then re-run this script."
            error "Aborting — repository is not up to date."
        fi
    elif [[ -f "$(dirname "$0")/docker-compose.yml" ]]; then
        # Running from inside the already-cloned repository
        DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
        info "Using current directory as deploy dir: ${DEPLOY_DIR}"
    else
        info "Cloning repository into ${DEPLOY_DIR} …"
        git clone --depth=1 "$REPO_URL" "$DEPLOY_DIR"
    fi
    success "Repository ready at ${DEPLOY_DIR}."
}

# ─── Environment file ─────────────────────────────────────────────────────────
write_env() {
    local env_file="${DEPLOY_DIR}/.env"

    info "Writing production .env …"

    # Build the COMPOSE_FILE value.
    # Always: base + ocis + tika + onlyoffice
    # Optional: wopi external endpoint
    local compose_file='docker-compose.yml${OCIS:-}${TIKA:-}${S3NG:-}${S3NG_MINIO:-}${MONITORING:-}${IMPORTER:-}${CLAMAV:-}${ONLYOFFICE:-}${EXTENSIONS:-}${UNZIP:-}${DRAWIO:-}${JSONVIEWER:-}${PROGRESSBARS:-}${EXTERNALSITES:-}${MAIL_SERVER:-}'
    local wopi_fragment=""
    if [[ "$ENABLE_WOPI_DOMAIN" == "true" ]]; then
        compose_file='docker-compose.yml${OCIS:-}${TIKA:-}${S3NG:-}${S3NG_MINIO:-}${MONITORING:-}${IMPORTER:-}${CLAMAV:-}${ONLYOFFICE:-}${WOPI:-}${EXTENSIONS:-}${UNZIP:-}${DRAWIO:-}${JSONVIEWER:-}${PROGRESSBARS:-}${EXTERNALSITES:-}${MAIL_SERVER:-}'
        wopi_fragment="WOPI=:wopi.yml"
    fi

    cat > "$env_file" <<EOF
## ==========================================================================
## Production .env — generated by deploy-vps.sh
## Domains: ${OCIS_DOMAIN} | ${ONLYOFFICE_DOMAIN}$(
    [[ "$ENABLE_WOPI_DOMAIN" == "true" ]] && echo " | ${WOPI_DOMAIN}" || true
)
## ==========================================================================

## Basic Settings
LOG_DRIVER=
# Production: set INSECURE=false so TLS between Traefik and oCIS is validated.
INSECURE=false


## Traefik Settings
TRAEFIK_DOCKER_TAG=v3.6.7
TRAEFIK_DASHBOARD=false
TRAEFIK_DOMAIN=
TRAEFIK_BASIC_AUTH_USERS=
TRAEFIK_ACME_MAIL=${ACME_EMAIL}
TRAEFIK_ACME_CASERVER=


## Infinite Scale Settings
OCIS=:ocis.yml
OCIS_DOCKER_IMAGE=owncloud/ocis
OCIS_DOCKER_TAG=
OCIS_DOMAIN=${OCIS_DOMAIN}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
DEMO_USERS=false
LOG_LEVEL=
# OCIS_CONFIG_DIR=/your/local/ocis/config
# OCIS_DATA_DIR=/your/local/ocis/data

## S3 Storage (disabled)
S3NG_ENDPOINT=
S3NG_REGION=
S3NG_ACCESS_KEY=
S3NG_SECRET_KEY=
S3NG_BUCKET=
MINIO_DOMAIN=

## SMTP (configure if e-mail notifications are required)
SMTP_HOST=
SMTP_PORT=
SMTP_SENDER=
SMTP_USERNAME=
SMTP_PASSWORD=
SMTP_AUTHENTICATION=
SMTP_INSECURE=

## Additional startup services (notifications is mandatory)
START_ADDITIONAL_SERVICES="notifications"


## oCIS Web Extensions (disabled)
COMPANION_IMAGE=
COMPANION_DOMAIN=
COMPANION_ONEDRIVE_KEY=
COMPANION_ONEDRIVE_SECRET=


## Default Enabled Services

### Apache Tika (full-text search) — enabled
TIKA=:tika.yml
TIKA_IMAGE=

### Collabora — DISABLED (OnlyOffice is used instead)
# COLLABORA=:collabora.yml
COLLABORA_DOCKER_TAG=25.04.8.1.1
COLLABORA_DOMAIN=
COLLABORA_ADMIN_USER=
COLLABORA_ADMIN_PASSWORD=
COLLABORA_SSL_ENABLE=false
COLLABORA_SSL_VERIFICATION=false


## OnlyOffice — ENABLED
ONLYOFFICE=:onlyoffice.yml
ONLYOFFICE_IMAGE=onlyoffice/documentserver
ONLYOFFICE_DOCKER_TAG=9.2.1.1
# ONLYOFFICE_DEACTIVATE_LICENSE points to /dev/null to disable license loading.
# This allows the Community Edition to run without a license file.
# To use the Enterprise Edition, comment the line below and set ONLYOFFICE_LICENSE_LOCAL.
ONLYOFFICE_DEACTIVATE_LICENSE=/dev/null
# ONLYOFFICE_LICENSE_LOCAL=./config/onlyoffice/license.lic
ONLYOFFICE_DOMAIN=${ONLYOFFICE_DOMAIN}
# ONLYOFFICE_JWT_ENABLED=false
# ONLYOFFICE_REDIS_HOST=localhost
# ONLYOFFICE_REDIS_PORT=6379


## WOPI external endpoint$(
    if [[ "$ENABLE_WOPI_DOMAIN" == "true" ]]; then
        echo ""
        echo "# Enabled — OnlyOffice will use ${WOPI_DOMAIN} for WOPI callbacks."
        echo "${wopi_fragment}"
        echo "WOPI_DOMAIN=${WOPI_DOMAIN}"
    else
        echo ""
        echo "# Disabled — OnlyOffice reaches collaboration-oo via internal Docker network."
        echo "# To enable, set ENABLE_WOPI_DOMAIN=true when running deploy-vps.sh."
        echo "# WOPI=:wopi.yml"
        echo "# WOPI_DOMAIN=${WOPI_DOMAIN}"
    fi
)


## Virus scanner (disabled)
# CLAMAV=:clamav.yml
CLAMAV_DOCKER_TAG=

## Mail server for testing (disabled in production)
# Mailpit (axllent/mailpit) acts as an SMTP catcher — do NOT use in production.
# MAIL_SERVER=:mailserver.yml
MAIL_SERVER_DOMAIN=
MAIL_SERVER_DOCKER_TAG=v1.28.0


## IMPORTANT — must be the last line
COMPOSE_FILE=${compose_file}
EOF

    success ".env written to ${env_file}."
    info  "Review it at any time with: cat ${env_file}"
}

# ─── Config directory fixes for OnlyOffice-only setup ─────────────────────────
patch_app_registry() {
    local registry="${DEPLOY_DIR}/config/ocis/app-registry.yaml"
    [[ -f "$registry" ]] || return

    # If Collabora is not deployed, redirect ODF mime-types to OnlyOffice.
    # Only patch when Collabora lines are still present.
    if grep -q "default_app: Collabora" "$registry"; then
        info "Patching app-registry.yaml: setting OnlyOffice as default for ODF types …"
        sed -i 's/default_app: Collabora/default_app: OnlyOffice/g' "$registry"
        success "app-registry.yaml patched."
    fi
}

# ─── Launch ───────────────────────────────────────────────────────────────────
start_services() {
    info "Pulling Docker images (this may take a few minutes) …"
    docker compose --project-directory "$DEPLOY_DIR" pull

    info "Starting services …"
    docker compose --project-directory "$DEPLOY_DIR" up -d

    success "Services started."
}

print_summary() {
    echo
    echo -e "${GREEN}${BOLD}============================================================${RESET}"
    echo -e "${GREEN}${BOLD}  Deployment complete!${RESET}"
    echo -e "${GREEN}${BOLD}============================================================${RESET}"
    echo
    echo -e "  ${BOLD}oCIS frontend:${RESET}      https://${OCIS_DOMAIN}"
    echo -e "  ${BOLD}OnlyOffice:${RESET}         https://${ONLYOFFICE_DOMAIN}"
    if [[ "$ENABLE_WOPI_DOMAIN" == "true" ]]; then
        echo -e "  ${BOLD}WOPI endpoint:${RESET}      https://${WOPI_DOMAIN}"
    fi
    echo
    echo -e "  ${BOLD}oCIS admin user:${RESET}    admin"
    echo -e "  ${BOLD}oCIS admin pass:${RESET}    ${ADMIN_PASSWORD}"
    echo
    echo -e "  ${BOLD}Deployment dir:${RESET}     ${DEPLOY_DIR}"
    echo
    echo -e "  Traefik will obtain Let's Encrypt certificates automatically."
    echo -e "  If a domain isn't resolving yet the certificate will be"
    echo -e "  issued automatically once DNS propagates."
    echo
    echo -e "  ${BOLD}Useful commands:${RESET}"
    echo -e "    # View running services"
    echo -e "    docker compose --project-directory ${DEPLOY_DIR} ps"
    echo
    echo -e "    # Follow logs"
    echo -e "    docker compose --project-directory ${DEPLOY_DIR} logs -f"
    echo
    echo -e "    # Restart a specific service (e.g. ocis)"
    echo -e "    docker compose --project-directory ${DEPLOY_DIR} restart ocis"
    echo
    echo -e "    # Stop everything"
    echo -e "    docker compose --project-directory ${DEPLOY_DIR} down"
    echo -e "${GREEN}${BOLD}============================================================${RESET}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  oCIS + Collaboration + OnlyOffice — Debian 12 deployer ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    check_root
    check_debian12
    prompt_acme_email
    prompt_admin_password

    install_prerequisites
    install_docker
    configure_firewall
    check_dns

    setup_repo
    write_env
    patch_app_registry
    start_services
    print_summary
}

main "$@"
