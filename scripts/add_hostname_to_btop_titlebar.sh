#!/usr/bin/env bash
set -e
# Category: Configuration
# Description: Appends the server's hostname to the 'btop' title bar (clock format) for all users.
# Usage: ./scripts/add_hostname_to_btop_titlebar.sh
# Dependencies: sudo, sed

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

function main() {
  # Self-elevate to root if not already
  if [ "$(id -u)" -ne 0 ]; then
      log_info "Elevating permissions to root..."
      # shellcheck disable=SC2093
      exec sudo "$0" "$@" # Re-run the script with sudo
      log_error "Failed to elevate to root. Please run with sudo." # This will only run if exec fails
      exit 1
  fi

  for user_dir in /home/*; do
    if [ -d "$user_dir" ]; then
      user=$(basename "$user_dir")
      config_file="$user_dir/.config/btop/btop.conf"

      log_info "Checking for $user's btop.conf at $config_file..."

      if [ -f "$config_file" ]; then
        log_info "$user's btop.conf exists. Attempting modification..."

        if sudo sed -i '/^clock_format *= *".*"$/ s/"$/ - \/host"/' "$config_file"; then
          log_success "Successfully modified clock_format for user $user."
        else
          log_error "An unexpected error occurred while modifying $user's btop.conf."
        fi
      else
        log_warn "$user's btop.conf file is not exist."
      fi
    else
      log_warn "$user's dir not found."
    fi
  done

  log_success "Finished attempting to modify btop.conf for all users in /home."
}

main "$@"
