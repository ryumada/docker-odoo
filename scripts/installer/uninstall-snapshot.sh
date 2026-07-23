#!/usr/bin/env bash
set -e
# Category: Installer
# Description: Uninstalls the snapshot utility, removing script, symlink, cron, and logrotate configs.
# Usage: ./scripts/installer/uninstall-snapshot.sh
# Dependencies: sudo, git, systemctl

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")

# --- Logging Functions & Colors ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[1;33m"
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

error_handler() {
  local exit_code=$1
  local line_no=$2
  local command_name=$3
  log_error "An error occurred on line $line_no."
  log_error "Exit Code: $exit_code"
  log_error "Command: $command_name"
  exit "$exit_code"
}

trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR

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

  log_info "Uninstalling snapshot utility for service: $SERVICE_NAME"

  local CRON_FILE="/etc/cron.d/snapshot-$SERVICE_NAME"
  local LOGROTATE_FILE="/etc/logrotate.d/snapshot-$SERVICE_NAME"
  local SOFTLINK_FILE="/usr/local/sbin/snapshot-$SERVICE_NAME"
  local SCRIPT_FILE="$PATH_TO_ODOO/scripts/snapshot-$SERVICE_NAME"

  if [ -f "$CRON_FILE" ]; then
    log_info "Removing cron job: $CRON_FILE"
    rm -f -- "$CRON_FILE"
    log_info "Restarting cron service..."
    systemctl restart cron || true
  fi

  if [ -f "$LOGROTATE_FILE" ]; then
    log_info "Removing logrotate configuration: $LOGROTATE_FILE"
    rm -f -- "$LOGROTATE_FILE"
  fi

  if [ -L "$SOFTLINK_FILE" ] || [ -f "$SOFTLINK_FILE" ]; then
    log_info "Removing symbolic link: $SOFTLINK_FILE"
    rm -f -- "$SOFTLINK_FILE"
  fi

  if [ -f "$SCRIPT_FILE" ]; then
    log_info "Removing snapshot script file: $SCRIPT_FILE"
    rm -f -- "$SCRIPT_FILE"
  fi

  log_success "Snapshot utility uninstalled successfully."
}

main "$@"
