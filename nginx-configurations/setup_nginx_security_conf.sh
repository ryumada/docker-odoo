#!/usr/bin/env bash
set -e
# Category: Config
# Description: Sets up Nginx security configuration.
# Usage: ./nginx-configurations/setup_nginx_security_conf.sh
# Dependencies: sudo, cat

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

# Configuration
ENV_FILE=".env"
UPDATE_SCRIPT="./scripts/update-env-file.sh"
MAX_BACKUPS=3

# --- Logging Functions & Colors ---
# Define colors for log messages
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[0;31m"

# Function to log messages with a specific color and emoji
log() {
  local color="$1"
  local emoji="$2"
  local message="$3"
  echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}"
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_warn() { log "${COLOR_WARN}" "⚠️" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }
# ------------------------------------

error_handler() {
  log_error "An error occurred on line $1. Exiting..."
  exit 1
}

trap 'error_handler $LINENO' ERR

log_info "Creating Nginx security configuration..."

# Use a temporary file instead of the user's home directory to avoid permission issues if run as root
TEMP_CONF=$(mktemp)

cat << 'EOF' > "$TEMP_CONF"
##
# Security Settings
##

# limit for web/login path
limit_req_zone $binary_remote_addr zone=limitweblogin:20m rate=5r/s;
limit_conn_zone $binary_remote_addr zone=addrweblogin:25m;

# limit for web/database* path
limit_req_zone $binary_remote_addr zone=limitwebdatabase:10m rate=30r/m;
limit_conn_zone $binary_remote_addr zone=addrwebdatabase:10m;

# these settings can impact ram usage of nginx the buffers saved on RAM
client_body_buffer_size         2k;
client_header_buffer_size       2k;
large_client_header_buffers     8 16k;

# Save the request body to a file which beneficial for handling large requests
client_body_in_file_only on;
client_body_temp_path /var/tmp/nginx;

# file upload can be received by nginx. If you have file upload feature with POST method
client_max_body_size            500M;

keepalive_timeout               2700s;
tcp_nodelay                     on;

# disable display nginx server version
server_tokens off;

# OCSP Stapling - improve SSL handshake performance and reduce server load
#ssl_stapling on;
#ssl_stapling_verify on;
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;

# clickjacking protection
add_header X-Frame-Options "SAMEORIGIN";

# prevent user from accepting insecure SSL certificates
add_header Strict-Transport-Security "max-age=31536000; includeSubdomains; preload" always;

# Instruct browser to strictly follow the Content-Type header specified in HTTP headers and not attempt to determine the type of contente by examining the content itself (XSS and Content Injection Protection).
add_header X-Content-Type-Options "nosniff";

# prevent the the destination site to know where the user came from which is useful because this Odoo deployment is a backoffice application
add_header Referrer-Policy "strict-origin-when-cross-origin";

# protect from certain types of attacks, including Cross-site Scripting (XSS) and data injection attacks [VERY RESTRICTIVE]
#add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;

# xss protection for older browsers that don't support Content-Security-Policy [NOT USABLE IN MODERN BROWSER]
#add_header X-XSS-Protection "1; mode=block";

# [DEPRECATED not used anymore; use Wazuh instead] enable modsecurity on specific URL only. You can add it in login page or in database manager block
#modsecurity on;
#modsecurity_rules_file /etc/nginx/modsec/main.conf;

EOF

DEST_FILE="/etc/nginx/conf.d/01-sudo-nginx-security.conf"
log_info "Installing configuration to $DEST_FILE"

# Determine if we need sudo to move the file
if [ -w "$(dirname "$DEST_FILE")" ]; then
    mv "$TEMP_CONF" "$DEST_FILE"
    chown root:root "$DEST_FILE" || log_warn "Could not allow root ownership. Current user: $(whoami)"
else
    if command -v sudo &> /dev/null; then
        sudo mv "$TEMP_CONF" "$DEST_FILE"
        sudo chown root:root "$DEST_FILE"
    else
        log_error "Cannot write to $DEST_FILE and sudo is not available."
        rm -f "$TEMP_CONF"
        exit 1
    fi
fi

log_success "Nginx security configuration installed successfully."
log_info "You may need to reload nginx for changes to take effect: sudo systemctl reload nginx"
