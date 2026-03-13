#!/usr/bin/env bash
# =============================================================================
# deploy-vps.sh — Deploy oCIS + Collaboration + OnlyOffice on Debian 12 VPS
#                 Native installation — no Docker required
#
# Stack
#   • oCIS (Infinite Scale)        — binary from GitHub releases, systemd service
#   • oCIS Collaboration (WOPI)    — same binary, separate systemd service
#   • OnlyOffice Document Server   — native Debian package (official APT repo)
#   • nginx-extras                 — TLS termination and reverse proxy
#   • certbot                      — Let's Encrypt certificate management
#   • ufw                          — firewall
#
# Domains
#   ocis.efimovsergei.ru        – oCIS web frontend
#   onlyoffice.efimovsergei.ru  – OnlyOffice Document Server
#   wopi.efimovsergei.ru        – WOPI / Collaboration endpoint
#
# Requirements
#   • Debian 12 (Bookworm), fresh install recommended
#   • Root or sudo privileges
#   • Ports 80 and 443 open in firewall / security group
#   • DNS A records for all three domains pointing to this server's IP
#
# Usage
#   chmod +x deploy-vps.sh
#   sudo ./deploy-vps.sh
# =============================================================================

set -euo pipefail

# ─── Configuration (override via environment variables) ───────────────────────
OCIS_DOMAIN="${OCIS_DOMAIN:-ocis.efimovsergei.ru}"
ONLYOFFICE_DOMAIN="${ONLYOFFICE_DOMAIN:-onlyoffice.efimovsergei.ru}"
WOPI_DOMAIN="${WOPI_DOMAIN:-wopi.efimovsergei.ru}"

# E-mail for Let's Encrypt notifications.
ACME_EMAIL="${ACME_EMAIL:-}"

# oCIS admin password — leave blank to auto-generate.
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

# oCIS release version — leave blank to auto-detect the latest stable release.
OCIS_VERSION="${OCIS_VERSION:-}"

# Internal TCP ports (all bound to 127.0.0.1; nginx-extras terminates TLS externally).
OCIS_PORT=9200        # oCIS HTTP proxy
ONLYOFFICE_PORT=8083  # OnlyOffice nginx (reconfigured from its default :80)
WOPI_PORT=9300        # oCIS Collaboration / WOPI HTTP

# System paths
OCIS_BIN="/usr/local/bin/ocis"
OCIS_CONFIG_DIR="/etc/ocis"
OCIS_DATA_DIR="/var/lib/ocis"
OCIS_LOG_DIR="/var/log/ocis"
OCIS_USER="ocis"

# Directory containing this script — used to locate repo config files.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Fallback base URL when config files are not found next to the script.
OCIS_CONFIG_REPO_URL="${OCIS_CONFIG_REPO_URL:-https://raw.githubusercontent.com/GLSVAR-KZ/ocis-docker-exx/main/config/ocis}"

# OnlyOffice secrets — generated once and reused across the local.json sections.
# Override via environment variable if you need deterministic values.
OO_DB_PASSWORD="${OO_DB_PASSWORD:-}"
OO_JWT_SECRET="${OO_JWT_SECRET:-}"

# ─── Output helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ─── Preflight ────────────────────────────────────────────────────────────────
check_root() {
    [[ "$EUID" -eq 0 ]] || error "Run as root or with sudo."
}

check_debian12() {
    [[ -f /etc/os-release ]] || { warn "Cannot detect OS — /etc/os-release not found."; return; }
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ "$ID" != "debian" || "$VERSION_ID" != "12" ]]; then
        warn "Designed for Debian 12. Detected: ${PRETTY_NAME:-unknown}. Proceeding anyway."
    fi
}

check_dns() {
    info "Checking DNS resolution for configured domains …"
    local missing=()
    for domain in "$OCIS_DOMAIN" "$ONLYOFFICE_DOMAIN" "$WOPI_DOMAIN"; do
        getent hosts "$domain" &>/dev/null || missing+=("$domain")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Not yet resolving: ${missing[*]}"
        warn "Let's Encrypt certificate issuance will fail until DNS propagates."
        warn "Continuing — run certbot manually once DNS is ready."
    else
        success "DNS looks good."
    fi
}

prompt_acme_email() {
    if [[ -z "$ACME_EMAIL" ]]; then
        echo -e "${BOLD}Enter e-mail address for Let's Encrypt certificate notifications:${RESET}"
        read -rp "> " ACME_EMAIL
        [[ -n "$ACME_EMAIL" ]] || error "ACME e-mail is required."
    fi
}

prompt_admin_password() {
    if [[ -z "$ADMIN_PASSWORD" ]]; then
        echo -e "${BOLD}Enter oCIS admin password (blank = auto-generate):${RESET}"
        read -rsp "> " ADMIN_PASSWORD; echo
        if [[ -z "$ADMIN_PASSWORD" ]]; then
            ADMIN_PASSWORD="$(tr -dc 'A-Za-z0-9!@#%^&*()-_=+' </dev/urandom | head -c 24)"
            [[ -n "$ADMIN_PASSWORD" ]] || error "Password generation failed. Set ADMIN_PASSWORD manually."
            info "Generated admin password: ${BOLD}${ADMIN_PASSWORD}${RESET}"
            warn "Save this — it will not be shown again."
        fi
    fi
}

generate_oo_secrets() {
    # Generate random OnlyOffice database password and JWT secret if not provided.
    if [[ -z "$OO_DB_PASSWORD" ]]; then
        OO_DB_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
        [[ -n "$OO_DB_PASSWORD" ]] || error "OnlyOffice DB password generation failed."
    fi
    if [[ -z "$OO_JWT_SECRET" ]]; then
        OO_JWT_SECRET="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
        [[ -n "$OO_JWT_SECRET" ]] || error "OnlyOffice JWT secret generation failed."
    fi
}

# ─── System packages ──────────────────────────────────────────────────────────
install_base_packages() {
    info "Updating apt package lists …"
    apt-get update -qq

    info "Installing base packages …"
    apt-get install -y -qq \
        ca-certificates curl wget gnupg git lsb-release \
        dnsutils ufw jq

    success "Base packages ready."
}

install_nginx_extras() {
    if dpkg -l nginx-extras 2>/dev/null | grep -q '^ii'; then
        success "nginx-extras already installed."
    else
        info "Installing nginx-extras …"
        apt-get install -y -qq nginx-extras
        success "nginx-extras installed."
    fi
    systemctl enable nginx
}

install_certbot() {
    if command -v certbot &>/dev/null; then
        success "certbot already installed."
        return
    fi
    info "Installing certbot …"
    apt-get install -y -qq certbot
    success "certbot installed."
}

# ─── Firewall ─────────────────────────────────────────────────────────────────
configure_firewall() {
    command -v ufw &>/dev/null || { warn "ufw not found — skipping firewall setup."; return; }
    info "Configuring UFW firewall …"
    ufw allow OpenSSH 2>/dev/null || true
    ufw allow 80/tcp  2>/dev/null || true
    ufw allow 443/tcp 2>/dev/null || true
    ufw status | grep -q "Status: active" || ufw --force enable 2>/dev/null || true
    success "Firewall rules applied (SSH, HTTP, HTTPS)."
}

# ─── TLS certificates ─────────────────────────────────────────────────────────
get_certificates() {
    # Stop nginx to free port 80 for the standalone ACME HTTP-01 challenge.
    info "Stopping nginx to free port 80 for standalone ACME challenge …"
    systemctl stop nginx 2>/dev/null || true

    for domain in "$OCIS_DOMAIN" "$ONLYOFFICE_DOMAIN" "$WOPI_DOMAIN"; do
        if [[ -d "/etc/letsencrypt/live/${domain}" ]]; then
            info "Certificate for ${domain} already exists — skipping."
            continue
        fi
        info "Requesting Let's Encrypt certificate for ${domain} …"
        certbot certonly --standalone -n --agree-tos \
            -m "$ACME_EMAIL" -d "$domain" \
            || warn "Could not obtain cert for ${domain}. Fix DNS then run: certbot certonly --standalone -d ${domain}"
    done

    success "Certificate acquisition complete."
}

# ─── OnlyOffice Document Server ───────────────────────────────────────────────
install_onlyoffice() {
    if dpkg -l onlyoffice-documentserver 2>/dev/null | grep -q '^ii'; then
        success "OnlyOffice Document Server already installed."
        return
    fi

    info "Installing OnlyOffice dependencies …"
    # Accept the Microsoft core fonts EULA without interaction.
    echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" \
        | debconf-set-selections
    # Pre-seed the OnlyOffice database password so the postinst runs non-interactively.
    echo "onlyoffice-documentserver onlyoffice/db-pwd password ${OO_DB_PASSWORD}" \
        | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        postgresql rabbitmq-server redis-server supervisor \
        ttf-mscorefonts-installer fonts-crosextra-caladea \
        fonts-crosextra-carlito fonts-liberation

    info "Adding OnlyOffice GPG key and APT repository …"
    curl -fsSL https://download.onlyoffice.com/GPG-KEY-ONLYOFFICE \
        | gpg --dearmor -o /usr/share/keyrings/onlyoffice.gpg
    echo "deb [signed-by=/usr/share/keyrings/onlyoffice.gpg] https://download.onlyoffice.com/repo/debian squeeze main" \
        > /etc/apt/sources.list.d/onlyoffice.list
    apt-get update -qq

    info "Installing OnlyOffice Document Server (this may take several minutes) …"
    DEBIAN_FRONTEND=noninteractive apt-get install -y onlyoffice-documentserver

    success "OnlyOffice Document Server installed."
}

configure_onlyoffice() {
    # ── 1. Reconfigure OnlyOffice nginx to listen only on 127.0.0.1:<port> ───
    # The package creates /etc/nginx/conf.d/ds.conf (or a symlink to it).
    # By default it binds 0.0.0.0:80, which conflicts with our outer nginx-extras.
    # We change it to 127.0.0.1:${ONLYOFFICE_PORT} so nginx-extras can proxy inward.
    info "Reconfiguring OnlyOffice nginx to 127.0.0.1:${ONLYOFFICE_PORT} …"

    local ds_conf=""
    for candidate in /etc/nginx/conf.d/ds.conf \
                     /etc/onlyoffice/documentserver/nginx/ds.conf; do
        [[ -f "$candidate" ]] && ds_conf="$candidate" && break
    done

    if [[ -z "${ds_conf:-}" ]]; then
        warn "OnlyOffice nginx config (ds.conf) not found — port not patched."
        warn "Ensure OnlyOffice is reachable on port ${ONLYOFFICE_PORT} or adjust ONLYOFFICE_PORT."
    else
        # Keep an untouched original for reference (no-overwrite).
        cp -n "$ds_conf" "${ds_conf}.orig"

        sed -i \
            -e "s|listen 0\.0\.0\.0:80;|listen 127.0.0.1:${ONLYOFFICE_PORT};|g" \
            -e "s|listen \[::\]:80[^;]*;|# &|g" \
            "$ds_conf"

        # If /etc/nginx/conf.d/ds.conf is a separate non-symlink copy, patch it too.
        local ng="/etc/nginx/conf.d/ds.conf"
        if [[ -f "$ng" && ! -L "$ng" && "$ng" != "$ds_conf" ]]; then
            sed -i \
                -e "s|listen 0\.0\.0\.0:80;|listen 127.0.0.1:${ONLYOFFICE_PORT};|g" \
                -e "s|listen \[::\]:80[^;]*;|# &|g" \
                "$ng"
        fi

        success "OnlyOffice nginx now uses 127.0.0.1:${ONLYOFFICE_PORT}."
    fi

    # ── 2. Write local.json (native setup adjustments) ───────────────────────
    # Key differences from the Docker config/onlyoffice/local.json:
    #   • dbPass            — randomly generated at deploy time (not hardcoded)
    #   • secret strings    — randomly generated at deploy time (not hardcoded)
    #   • ipfilter address "collaboration-oo" → "127.0.0.1"
    #     (services run on the same host, not in separate Docker containers)
    #   • wopi.enable: true  (activates the WOPI protocol in OnlyOffice)
    info "Writing OnlyOffice local.json for native deployment …"

    local json_path="/etc/onlyoffice/documentserver/local.json"
    [[ -f "$json_path" ]] && cp -n "$json_path" "${json_path}.orig"

    cat > "$json_path" << LOCALJSON
{
  "services": {
    "CoAuthoring": {
      "sql": {
        "type": "postgres",
        "dbHost": "localhost",
        "dbPort": "5432",
        "dbName": "onlyoffice",
        "dbUser": "onlyoffice",
        "dbPass": "${OO_DB_PASSWORD}"
      },
      "ipfilter": {
        "rules": [
          { "address": "127.0.0.1", "allowed": true },
          { "address": "*",         "allowed": false }
        ],
        "useforrequest": false,
        "errorcode": 403
      },
      "token": {
        "enable": {
          "request": { "inbox": true, "outbox": true },
          "browser": true
        },
        "inbox":  { "header": "Authorization" },
        "outbox": { "header": "Authorization" }
      },
      "secret": {
        "inbox":   { "string": "${OO_JWT_SECRET}" },
        "outbox":  { "string": "${OO_JWT_SECRET}" },
        "session": { "string": "${OO_JWT_SECRET}" }
      }
    }
  },
  "wopi": {
    "enable": true
  },
  "rabbitmq": {
    "url": "amqp://guest:guest@localhost"
  },
  "FileConverter": {
    "converter": {
      "inputLimits": [
        { "type": "docx;dotx;docm;dotm",          "zip": { "uncompressed": "1GB", "template": "*.xml" } },
        { "type": "xlsx;xltx;xlsm;xltm",          "zip": { "uncompressed": "1GB", "template": "*.xml" } },
        { "type": "pptx;ppsx;potx;pptm;ppsm;potm","zip": { "uncompressed": "1GB", "template": "*.xml" } }
      ]
    }
  }
}
LOCALJSON

    success "OnlyOffice local.json written."

    # Restart OnlyOffice backend processes to pick up the new config.
    if command -v supervisorctl &>/dev/null; then
        supervisorctl restart all 2>/dev/null \
            || warn "supervisorctl restart returned an error — OnlyOffice processes may need a manual restart."
    else
        warn "supervisorctl not found — OnlyOffice processes may not have reloaded the new config."
    fi
}

# ─── oCIS binary ──────────────────────────────────────────────────────────────
resolve_ocis_version() {
    if [[ -n "$OCIS_VERSION" ]]; then
        echo "$OCIS_VERSION"; return
    fi
    info "Detecting latest oCIS release from GitHub …"
    local ver
    ver="$(curl -fsSL 'https://api.github.com/repos/owncloud/ocis/releases/latest' \
          | jq -r '.tag_name' | sed 's/^v//')"
    [[ -n "$ver" && "$ver" != "null" ]] \
        || error "Could not detect oCIS version. Set OCIS_VERSION and retry."
    info "Latest oCIS: v${ver}"
    echo "$ver"
}

install_ocis_binary() {
    local version="$1"
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *)        error "Unsupported CPU architecture: $arch" ;;
    esac

    if [[ -x "$OCIS_BIN" ]] && "$OCIS_BIN" --version 2>&1 | grep -q "$version"; then
        success "oCIS v${version} already installed."
        return
    fi

    local url="https://github.com/owncloud/ocis/releases/download/v${version}/ocis-${version}-linux-${arch}"
    info "Downloading oCIS v${version} for linux/${arch} …"
    curl -fsSL "$url" -o /tmp/ocis_bin
    install -m 0755 /tmp/ocis_bin "$OCIS_BIN"
    rm -f /tmp/ocis_bin

    success "oCIS installed: $("$OCIS_BIN" --version 2>&1 | head -1)"
}

setup_ocis_user_dirs() {
    info "Creating oCIS system user and directories …"
    id "$OCIS_USER" &>/dev/null \
        || useradd --system \
                   --home-dir "$OCIS_DATA_DIR" \
                   --create-home \
                   --shell /usr/sbin/nologin \
                   "$OCIS_USER"
    mkdir -p "$OCIS_CONFIG_DIR" "$OCIS_DATA_DIR" "$OCIS_LOG_DIR"
    chown -R "${OCIS_USER}:${OCIS_USER}" \
        "$OCIS_CONFIG_DIR" "$OCIS_DATA_DIR" "$OCIS_LOG_DIR"
    success "oCIS user and directories ready."
}

install_ocis_configs() {
    info "Installing oCIS configuration files …"
    # Use files from the repository this script lives in; fall back to GitHub.
    local src_dir="${SCRIPT_DIR}/config/ocis"

    for f in app-registry.yaml csp.yaml banned-password-list.txt; do
        if [[ -f "${src_dir}/${f}" ]]; then
            cp "${src_dir}/${f}" "${OCIS_CONFIG_DIR}/${f}"
        else
            warn "${f} not found locally — downloading from ${OCIS_CONFIG_REPO_URL} …"
            curl -fsSL "${OCIS_CONFIG_REPO_URL}/${f}" -o "${OCIS_CONFIG_DIR}/${f}" \
                || warn "Could not download ${f}. Some oCIS features may not work."
        fi
    done

    # Patch app-registry: use OnlyOffice for ODF types (Collabora is not deployed).
    local registry="${OCIS_CONFIG_DIR}/app-registry.yaml"
    if [[ -f "$registry" ]] && grep -q "default_app: Collabora" "$registry"; then
        sed -i 's/default_app: Collabora/default_app: OnlyOffice/g' "$registry"
        info "app-registry.yaml: ODF types now open with OnlyOffice."
    fi

    chown -R "${OCIS_USER}:${OCIS_USER}" "$OCIS_CONFIG_DIR"
    success "oCIS config files installed."
}

init_ocis() {
    local ocis_yaml="${OCIS_CONFIG_DIR}/ocis.yaml"
    if [[ -f "$ocis_yaml" ]]; then
        info "oCIS already initialised (${ocis_yaml} exists) — skipping."
        return
    fi
    info "Initialising oCIS (generating secrets) …"
    sudo -u "$OCIS_USER" \
        OCIS_URL="https://${OCIS_DOMAIN}" \
        OCIS_CONFIG_DIR="$OCIS_CONFIG_DIR" \
        "$OCIS_BIN" init || true
    chown -R "${OCIS_USER}:${OCIS_USER}" "$OCIS_CONFIG_DIR"
    success "oCIS initialised."
}

# ─── Systemd environment files ────────────────────────────────────────────────
write_env_files() {
    info "Writing systemd environment files …"

    # ── oCIS main service ─────────────────────────────────────────────────────
    cat > "${OCIS_CONFIG_DIR}/ocis.env" << EOF
# oCIS service environment — managed by deploy-vps.sh
OCIS_URL=https://${OCIS_DOMAIN}
OCIS_LOG_LEVEL=info
OCIS_LOG_COLOR=false
OCIS_LOG_PRETTY=false
# nginx-extras terminates TLS; oCIS listens on plain HTTP internally
PROXY_TLS=false
GATEWAY_GRPC_ADDR=0.0.0.0:9142
OCIS_INSECURE=false
PROXY_ENABLE_BASIC_AUTH=false
IDM_ADMIN_PASSWORD=${ADMIN_PASSWORD}
IDM_CREATE_DEMO_USERS=false
# SMTP — fill in if you want e-mail notifications
NOTIFICATIONS_SMTP_HOST=
NOTIFICATIONS_SMTP_PORT=
NOTIFICATIONS_SMTP_SENDER=
NOTIFICATIONS_SMTP_USERNAME=
NOTIFICATIONS_SMTP_INSECURE=false
MICRO_REGISTRY_ADDRESS=127.0.0.1:9233
NATS_NATS_HOST=0.0.0.0
NATS_NATS_PORT=9233
PROXY_CSP_CONFIG_FILE_LOCATION=${OCIS_CONFIG_DIR}/csp.yaml
ONLYOFFICE_DOMAIN=${ONLYOFFICE_DOMAIN}
COMPANION_DOMAIN=
# Notifications service is mandatory
OCIS_ADD_RUN_SERVICES=notifications
OCIS_PASSWORD_POLICY_BANNED_PASSWORDS_LIST=banned-password-list.txt
OCIS_CONFIG_DIR=${OCIS_CONFIG_DIR}
EOF

    # ── oCIS Collaboration (WOPI) service ─────────────────────────────────────
    cat > "${OCIS_CONFIG_DIR}/collaboration.env" << EOF
# oCIS Collaboration (WOPI/OnlyOffice) environment — managed by deploy-vps.sh
COLLABORATION_GRPC_ADDR=0.0.0.0:9301
COLLABORATION_HTTP_ADDR=0.0.0.0:${WOPI_PORT}
MICRO_REGISTRY=nats-js-kv
MICRO_REGISTRY_ADDRESS=127.0.0.1:9233
# Public HTTPS URL of the WOPI endpoint — OnlyOffice calls back here on saves
COLLABORATION_WOPI_SRC=https://${WOPI_DOMAIN}
COLLABORATION_APP_NAME=OnlyOffice
COLLABORATION_APP_PRODUCT=OnlyOffice
COLLABORATION_APP_ADDR=https://${ONLYOFFICE_DOMAIN}
COLLABORATION_APP_ICON=https://${ONLYOFFICE_DOMAIN}/web-apps/apps/documenteditor/main/resources/img/favicon.ico
COLLABORATION_APP_INSECURE=false
COLLABORATION_CS3API_DATAGATEWAY_INSECURE=false
COLLABORATION_LOG_LEVEL=info
OCIS_URL=https://${OCIS_DOMAIN}
OCIS_CONFIG_DIR=${OCIS_CONFIG_DIR}
EOF

    chmod 600 "${OCIS_CONFIG_DIR}/ocis.env" "${OCIS_CONFIG_DIR}/collaboration.env"
    chown root:root "${OCIS_CONFIG_DIR}/ocis.env" "${OCIS_CONFIG_DIR}/collaboration.env"
    success "Environment files written."
}

# ─── Systemd service units ────────────────────────────────────────────────────
create_systemd_services() {
    info "Creating systemd service units …"

    # ── ocis.service ──────────────────────────────────────────────────────────
    cat > /etc/systemd/system/ocis.service << EOF
[Unit]
Description=ownCloud Infinite Scale Server
Documentation=https://doc.owncloud.com/ocis/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${OCIS_USER}
Group=${OCIS_USER}
EnvironmentFile=${OCIS_CONFIG_DIR}/ocis.env
ExecStart=${OCIS_BIN} server
Restart=on-failure
RestartSec=10
StandardOutput=append:${OCIS_LOG_DIR}/ocis.log
StandardError=append:${OCIS_LOG_DIR}/ocis.log

[Install]
WantedBy=multi-user.target
EOF

    # ── ocis-collaboration.service ────────────────────────────────────────────
    cat > /etc/systemd/system/ocis-collaboration.service << EOF
[Unit]
Description=ownCloud Infinite Scale — Collaboration / WOPI (OnlyOffice)
Documentation=https://doc.owncloud.com/ocis/
After=ocis.service
Wants=ocis.service

[Service]
Type=simple
User=${OCIS_USER}
Group=${OCIS_USER}
EnvironmentFile=${OCIS_CONFIG_DIR}/collaboration.env
ExecStart=${OCIS_BIN} collaboration server
Restart=on-failure
RestartSec=10
StandardOutput=append:${OCIS_LOG_DIR}/collaboration.log
StandardError=append:${OCIS_LOG_DIR}/collaboration.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ocis ocis-collaboration
    success "Systemd service units created and enabled."
}

# ─── nginx-extras virtual-host configuration ──────────────────────────────────
configure_nginx() {
    info "Writing nginx-extras virtual-host configurations …"

    # Remove the default nginx site to avoid port conflicts.
    rm -f /etc/nginx/sites-enabled/default

    # Shared TLS hardening snippet
    mkdir -p /etc/nginx/snippets
    cat > /etc/nginx/snippets/ssl-params.conf << 'SSLEOF'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
ssl_prefer_server_ciphers off;
ssl_session_cache   shared:SSL:10m;
ssl_session_timeout 10m;
ssl_stapling        on;
ssl_stapling_verify on;
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
SSLEOF

    # ── oCIS ──────────────────────────────────────────────────────────────────
    cat > "/etc/nginx/sites-available/${OCIS_DOMAIN}.conf" << EOF
# oCIS (Infinite Scale) — ${OCIS_DOMAIN}

server {
    listen 80;
    listen [::]:80;
    server_name ${OCIS_DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${OCIS_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${OCIS_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${OCIS_DOMAIN}/privkey.pem;
    include snippets/ssl-params.conf;

    # No upload size limit — oCIS handles arbitrarily large files.
    client_max_body_size 0;

    # Required for WebDAV clients that encode slashes in path segments.
    merge_slashes off;

    location / {
        proxy_pass         http://127.0.0.1:${OCIS_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;

        # WebSocket support (oCIS web UI uses WebSockets).
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";

        # Long timeouts for WebDAV clients that do not support TUS resumable upload.
        proxy_read_timeout 43200s;
        proxy_send_timeout 43200s;
    }
}
EOF

    # ── OnlyOffice Document Server ────────────────────────────────────────────
    cat > "/etc/nginx/sites-available/${ONLYOFFICE_DOMAIN}.conf" << EOF
# OnlyOffice Document Server — ${ONLYOFFICE_DOMAIN}

server {
    listen 80;
    listen [::]:80;
    server_name ${ONLYOFFICE_DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${ONLYOFFICE_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${ONLYOFFICE_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${ONLYOFFICE_DOMAIN}/privkey.pem;
    include snippets/ssl-params.conf;

    client_max_body_size 100m;

    location / {
        proxy_pass         http://127.0.0.1:${ONLYOFFICE_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        # Must be "https" so OnlyOffice generates correct callback URLs.
        proxy_set_header   X-Forwarded-Proto https;

        # WebSocket support (required for real-time co-editing).
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

    # ── WOPI / Collaboration endpoint ─────────────────────────────────────────
    cat > "/etc/nginx/sites-available/${WOPI_DOMAIN}.conf" << EOF
# oCIS WOPI / Collaboration endpoint — ${WOPI_DOMAIN}

server {
    listen 80;
    listen [::]:80;
    server_name ${WOPI_DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${WOPI_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${WOPI_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${WOPI_DOMAIN}/privkey.pem;
    include snippets/ssl-params.conf;

    client_max_body_size 0;

    location / {
        proxy_pass         http://127.0.0.1:${WOPI_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
}
EOF

    # Enable all three sites.
    for domain in "$OCIS_DOMAIN" "$ONLYOFFICE_DOMAIN" "$WOPI_DOMAIN"; do
        ln -sf "/etc/nginx/sites-available/${domain}.conf" \
               "/etc/nginx/sites-enabled/${domain}.conf"
    done

    nginx -t && success "nginx configuration is valid."
}

# ─── Start all services ───────────────────────────────────────────────────────
start_services() {
    info "Starting nginx …"
    systemctl start nginx

    info "Starting oCIS …"
    systemctl start ocis

    # The collaboration service connects to oCIS via NATS.
    # Give oCIS time to bring up the internal registry before starting it.
    info "Waiting 20 s for oCIS NATS registry to become ready …"
    sleep 20

    info "Starting oCIS Collaboration service …"
    systemctl start ocis-collaboration

    # Reload OnlyOffice supervisor processes (may already be running).
    if command -v supervisorctl &>/dev/null; then
        supervisorctl reload 2>/dev/null \
            || warn "supervisorctl reload returned an error — check 'supervisorctl status'."
    fi

    # Register a certbot auto-renewal cron job if one does not exist yet.
    if ! crontab -u root -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -u root -l 2>/dev/null
         echo "0 3 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx'") \
            | crontab -u root -
        info "Certbot auto-renewal cron job added to root's crontab (daily at 03:00)."
    fi

    success "All services started."
}

print_summary() {
    echo
    echo -e "${GREEN}${BOLD}============================================================${RESET}"
    echo -e "${GREEN}${BOLD}  Deployment complete!${RESET}"
    echo -e "${GREEN}${BOLD}============================================================${RESET}"
    echo
    echo -e "  ${BOLD}oCIS frontend:${RESET}       https://${OCIS_DOMAIN}"
    echo -e "  ${BOLD}OnlyOffice:${RESET}          https://${ONLYOFFICE_DOMAIN}"
    echo -e "  ${BOLD}WOPI endpoint:${RESET}       https://${WOPI_DOMAIN}"
    echo
    echo -e "  ${BOLD}oCIS admin user:${RESET}     admin"
    echo -e "  ${BOLD}oCIS admin pass:${RESET}     ${ADMIN_PASSWORD}"
    echo
    echo -e "  ${BOLD}Config dir:${RESET}          ${OCIS_CONFIG_DIR}"
    echo -e "  ${BOLD}Data dir:${RESET}            ${OCIS_DATA_DIR}"
    echo -e "  ${BOLD}Log dir:${RESET}             ${OCIS_LOG_DIR}"
    echo
    echo -e "  ${BOLD}Useful commands:${RESET}"
    echo -e "    systemctl status ocis"
    echo -e "    systemctl status ocis-collaboration"
    echo -e "    journalctl -u ocis -f"
    echo -e "    tail -f ${OCIS_LOG_DIR}/ocis.log"
    echo -e "    nginx -t && systemctl reload nginx"
    echo -e "    certbot renew --dry-run"
    echo -e "${GREEN}${BOLD}============================================================${RESET}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  oCIS + OnlyOffice — Debian 12 native deployer          ║"
    echo "║  nginx-extras  •  certbot  •  systemd  (no Docker)      ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    check_root
    check_debian12
    prompt_acme_email
    prompt_admin_password
    generate_oo_secrets

    install_base_packages
    install_nginx_extras
    install_certbot
    configure_firewall
    check_dns

    # Stop nginx → certbot standalone → certs written to /etc/letsencrypt/
    get_certificates

    # APT install; its postinst may restart nginx with ds.conf (port 80)
    install_onlyoffice
    # Change ds.conf listen port to 127.0.0.1:${ONLYOFFICE_PORT}; write local.json
    configure_onlyoffice

    local ver
    ver="$(resolve_ocis_version)"
    install_ocis_binary "$ver"
    setup_ocis_user_dirs
    install_ocis_configs
    init_ocis
    write_env_files
    create_systemd_services

    # Write our server blocks and validate nginx config
    configure_nginx

    start_services
    print_summary
}

main "$@"
