#!/usr/bin/env bash
set -e
# Category: Installer
# Description: Installs the deploy_release_candidate utility based on .env configuration.
# Usage: ./scripts/installer/install-deploy_release_candidate.sh
# Dependencies: rsync, git, sudo

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
    local link_name="deploy_release_candidate-$SERVICE_NAME"
    local script_filename="$link_name.sh"
    local target_path="$PATH_TO_ODOO/scripts/$script_filename"
    local source_path=""

    if [ "$BACKUP_RESTORE_METHOD" == "manual" ]; then
      log_info "Configuration set to 'manual'. Installing Manual Deploy Release Candidate utility."
      source_path="$PATH_TO_ODOO/scripts/example/deploy_release_candidate_manual.sh.example"
    else
      log_info "Configuration is empty or set to standard. Installing Standard Deploy Release Candidate utility."
      source_path="$PATH_TO_ODOO/scripts/example/deploy_release_candidate.sh.example"
    fi

    install_script "$link_name" "$source_path" "$target_path"

    log_success "Deploy Release Candidate utility installed successfully."
    exit 0
}

main "$@"
