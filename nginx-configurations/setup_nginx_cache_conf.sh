#!/usr/bin/env bash
set -e
# Category: Config
# Description: Sets up Nginx cache configuration.
# Usage: ./nginx-configurations/setup_nginx_cache_conf.sh
# Dependencies: sudo, cat, git, stat

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

# Configuration
ENV_FILE=".env"
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

error_handler() {
  local exit_code=$1
  local line_no=$2
  local command_name=$3
  log_error "An error occurred on line $line_no."
  log_error "Exit Code: $exit_code"
  log_error "Command: $command_name"
  log_error "Note: The specific error message should be printed in the lines above this error."
  exit "$exit_code"
}

trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR

# Self-elevate to root if not already
if [ "$(id -u)" -ne 0 ]; then
  log_info "Elevating permissions to root..."
  # shellcheck disable=SC2093
  exec sudo "$0" "$@"
  log_error "Failed to elevate to root. Please run with sudo." # This will only run if exec fails
  exit 1
fi
# ------------------------------------

log_info "Creating Nginx cache configuration..."

# Use a temporary file instead of the user's home directory to avoid permission issues if run as root
TEMP_CONF=$(mktemp)

log_info "Enter the domain name:"
read -r DOMAIN

if [ -z "$DOMAIN" ]; then
    log_error "Domain name cannot be empty."
    exit 1
fi

cat << EOF >> "$TEMP_CONF"
proxy_cache_path /var/cache/nginx/${DOMAIN}_image_cache levels=1:2 keys_zone=${DOMAIN}_image_cache:50m max_size=2g inactive=24h use_temp_path=off;
proxy_cache_path /var/cache/nginx/${DOMAIN}_static_cache levels=1:2 keys_zone=${DOMAIN}_static_cache:50m max_size=2g inactive=24h use_temp_path=off;
EOF

DEST_FILE="/etc/nginx/conf.d/02-nginx-cache-${DOMAIN}.conf"
log_info "Installing configuration to $DEST_FILE"

# Since we are root, we can directly create directories and move files
log_info "Creating cache directories..."
mkdir -p "/var/cache/nginx/${DOMAIN}_image_cache"
mkdir -p "/var/cache/nginx/${DOMAIN}_static_cache"
log_success "Cache directories ensured."

log_info "Installing configuration to $DEST_FILE"
mv "$TEMP_CONF" "$DEST_FILE"
chown root:root "$DEST_FILE"
chmod 644 "$DEST_FILE"

log_success "Nginx cache configuration installed successfully."
log_info "You may need to reload nginx for changes to take effect: sudo systemctl reload nginx"
