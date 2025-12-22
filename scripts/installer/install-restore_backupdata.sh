#!/bin/bash

# This script will install the restore_backupdata utility based on .env configuration.

# Exit immediately if a command exits with a non-zero status
set -e

# --- Logging Functions & Colors ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[0;33m"
readonly COLOR_ERROR="\033[0;31m"

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

function install_script() {
    local link_name="$1"
    local source_path="$2"
    local target_path="$3"

    log_info "Processing $target_path..."
    log_info "Copying from: $source_path"

    if OUTPUT_RSYNC_COMMAND=$(rsync -acz "$source_path" "$target_path" 2>&1); then
        log_success "Copied script file successfully."
    else
        log_error "Failed to copy script ➡️ $OUTPUT_RSYNC_COMMAND"
        exit 1
    fi

    log_info "Changing permission to 755"
    chmod 755 "$target_path"

    log_info "Linking /usr/local/sbin/$link_name"

    # Using -sf to force overwrite if the link already exists
    if OUTPUT_LN_COMMAND=$(ln -sf "$target_path" "/usr/local/sbin/$link_name" 2>&1); then
        log_success "Created symbolic link: /usr/local/sbin/$link_name"
    else
        log_error "Failed to create symbolic link ➡️ $OUTPUT_LN_COMMAND"
    fi
}

function main() {
    CURRENT_DIR=$(dirname "$(readlink -f "$0")")
    CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
    PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
    SERVICE_NAME=$(basename "$PATH_TO_ODOO")

    # Self-elevate to root if not already
    if [ "$(id -u)" -ne 0 ]; then
        log_info "Elevating permissions to root..."
        # shellcheck disable=SC2093
        exec sudo "$0" "$@"
        log_error "Failed to elevate to root."
        exit 1
    fi

    if ! cd "$PATH_TO_ODOO"; then
        log_error "Failed to change directory to $PATH_TO_ODOO"
        exit 1
    fi

    log_info "Checking configuration in .env file..."

    local ENV_FILE_PATH="$PATH_TO_ODOO/.env"
    local BACKUP_RESTORE_METHOD=""

    if [ -f "$ENV_FILE_PATH" ]; then
        log_info "Found .env file at: $ENV_FILE_PATH"
        # The '|| true' prevents script crash if the grep finds nothing (set -e safety)
        BACKUP_RESTORE_METHOD=$(grep "^BACKUP_RESTORE_METHOD=" "$PATH_TO_ODOO/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
    else
        log_error "No .env file found at: $ENV_FILE_PATH"
        exit 1
    fi

    # Define the single command name used by the system
    local link_name="restore_backupdata-$SERVICE_NAME"
    local script_filename="$link_name.sh"
    local target_path="$PATH_TO_ODOO/scripts/$script_filename"
    local source_path=""

    if [ "$BACKUP_RESTORE_METHOD" == "manual" ]; then
      log_info "Configuration set to 'manual'. Installing Manual Restore Backup utility."
      source_path="$PATH_TO_ODOO/scripts/example/restore_backupdata_manual.sh.example"
    else
      log_info "Configuration is empty or set to standard. Installing Standard Restore Backup utility."
      source_path="$PATH_TO_ODOO/scripts/example/restore_backupdata.sh.example"
    fi

    install_script "$link_name" "$source_path" "$target_path"

    log_success "Restore Backup Data utility installed successfully."
    exit 0
}

main "$@"
