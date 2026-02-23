#!/usr/bin/env bash
set -e
# Category: Configuration
# Description: Updates odoo.conf based on .env variables and odoo.conf.example.
# Usage: ./scripts/update-odoo-config.sh
# Dependencies: git, sed, sudo

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

# Set the paths to the configuration files
ODOO_CONF_EXAMPLE="$PATH_TO_ODOO/conf/odoo.conf.example"
ODOO_CONF="$PATH_TO_ODOO/conf/odoo.conf"
ENV_FILE_PATH="$PATH_TO_ODOO/.env"

ODOO_LINUX_USER="odoo"

log_info "Updating Odoo configuration file..."

# Copy the example configuration file to the final configuration file
if [ -f "$ODOO_CONF_EXAMPLE" ]; then
  if [ -f "$ODOO_CONF" ]; then
    log_info "Backing up existing odoo.conf to odoo.conf.bak..."
    cp "$ODOO_CONF" "$ODOO_CONF.bak"
    log_success "Backup created."
  fi
  log_info "Copying odoo.conf.example to odoo.conf..."
  cp "$ODOO_CONF_EXAMPLE" "$ODOO_CONF"
  log_success "Copied odoo.conf.example to odoo.conf."
else
    log_error "odoo.conf.example not found. Please make sure the file exists."
    exit 1
fi

# Check if the .env file exists
if [ -f "$ENV_FILE_PATH" ]; then
  # Read the .env file and export the variables
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    # shellcheck disable=SC2163
    export "$line"
  done < <(tr -d '\r' < "$ENV_FILE_PATH")

  # Check if the ADMIN_PASSWD variable is set in the .env file
  if [ -n "$ADMIN_PASSWD" ]; then
    log_info "Injecting admin_passwd to $ODOO_CONF..."
    # Replace the admin_passwd value in the odoo.conf file
    sed -i "s|enter_random_password_string|$ADMIN_PASSWD|" "$ODOO_CONF"
    log_success "Updated admin_passwd in $ODOO_CONF."
  else
    log_warn "ADMIN_PASSWD not set in .env file. Using default value from odoo.conf.example."
  fi

  # Check if the ADDONS_PATH variable is set in the .env file
  if [ -n "$ADDONS_PATH" ]; then
    log_info "Injecting addons_path to $ODOO_CONF..."
    # Replace the addons_path value in the odoo.conf file
    sed -i "s|enter_addons_paths|$ADDONS_PATH|" "$ODOO_CONF"
    log_success "Updated addons_path in $ODOO_CONF."
  else
    log_warn "ADDONS_PATH not set in .env file. Using default value from odoo.conf.example."
  fi

  if [ -n "$ODOO_ADDITIONAL_CONF" ]; then
    log_info "Injecting Additional odoo.conf configuration to $ODOO_CONF..."
    CONFIG_DATA=$(echo "$ODOO_ADDITIONAL_CONF" | sed 's/=/ = /g; s/\;/\\n/g')
    FORMATTED_CONF=$(printf '\n# Additional custom odoo configuration generated from .env file\n%s'"$CONFIG_DATA")

    TEMP_FILE=$(mktemp)
    echo "$FORMATTED_CONF" > "$TEMP_FILE"

    sed -i "/^proxy_mode = True/r $TEMP_FILE" "$ODOO_CONF"
    log_success "Appended ODOO_ADDITIONAL_CONF to $ODOO_CONF."
  else
    log_warn "ODOO_ADDITIONAL_CONF not set in .env file. Additional odoo.conf will not be added."
  fi
else
  log_warn ".env file not found. Using default values from odoo.conf.example."
fi

# Ensure correct ownership of the generated configuration files
log_info "Ensuring correct ownership of configuration files..."
chown "$ODOO_LINUX_USER:$ODOO_LINUX_USER" "$ODOO_CONF"
if [ -f "$ODOO_CONF.bak" ]; then
  chown "$ODOO_LINUX_USER:$ODOO_LINUX_USER" "$ODOO_CONF.bak"
fi

log_success "Odoo configuration file has been updated."
