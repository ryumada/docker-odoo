#!/bin/bash

# This script will create a backupdata utility from the example script.

# Exit immediately if a command exits with a non-zero status
set -e

# --- Logging Functions & Colors ---
# Define colors for log messages
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[0;33m"
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

function main() {
  CURRENT_DIR=$(dirname "$(readlink -f "$0")")
  CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
  PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
  SERVICE_NAME=$(basename "$PATH_TO_ODOO")
  # REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

  # Self-elevate to root if not already
  if [ "$(id -u)" -ne 0 ]; then
      log_info "Elevating permissions to root..."
      # shellcheck disable=SC2093
      exec sudo "$0" "$@" # Re-run the script with sudo
      log_error "Failed to elevate to root. Please run with sudo." # This will only run if exec fails
      exit 1
  fi

  cd "$PATH_TO_ODOO" || exit 1

  log_info "Installing backupdata utility"

  log_info "Copying the latest script from the example script"
  OUTPUT_RSYNC_COMMAND=$(rsync -acz ./scripts/example/backupdata.sh.example "./scripts/backupdata-$SERVICE_NAME" 2>&1) && {
    log_success "Copied the latest script from the example script."
  } || {
    log_error "Failed to copy the latest script from the example script ➡️ $OUTPUT_RSYNC_COMMAND"
    exit 1
  }

  log_info "Changing the permission of the script"
  chmod 755 "./scripts/backupdata-$SERVICE_NAME"

  log_info "Create a softlink to /usr/local/sbin"
  OUTPUT_LN_COMMAND=$(ln -s "$PATH_TO_ODOO/scripts/backupdata-$SERVICE_NAME" /usr/local/sbin/backupdata-"$SERVICE_NAME" 2>&1) && {
    log_success "Created a symbolic link to /usr/local/sbin/backupdata-$SERVICE_NAME"
  } || {
    log_warn "Failed to create a symbolic link to /usr/local/sbin/backupdata-$SERVICE_NAME ➡️ $OUTPUT_LN_COMMAND"
  }
}

main "@"
