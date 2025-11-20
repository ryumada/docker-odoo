#!/bin/bash

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

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
PATH_TO_ROOT_REPOSITORY=$(git -C "$CURRENT_DIR" rev-parse --show-toplevel)
DOCKER_ODOO_APP_NAME=$(basename "$PATH_TO_ROOT_REPOSITORY")

function main() {
  # Self-elevate to root if not already
  if [ "$(id -u)" -ne 0 ]; then
      log_info "Elevating permissions to root..."
      # shellcheck disable=SC2093
      exec sudo "$0" "$@" # Re-run the script with sudo
      log_error "Failed to elevate to root. Please run with sudo." # This will only run if exec fails
      exit 1
  fi

  log_info "Detected Odoo App Name: $DOCKER_ODOO_APP_NAME"

  SUDOERS_FILE_NAME="01-devops_as_root-$DOCKER_ODOO_APP_NAME-git_addons_updater"
  SUDOERS_FILE_PATH="/etc/sudoers.d/$SUDOERS_FILE_NAME"

  # Create a secure temporary file
  TEMP_SUDOERS_FILE=$(mktemp)
  # Ensure cleanup on exit
  trap 'rm -f "$TEMP_SUDOERS_FILE"' EXIT

  log_info "Creating sudoers file for devops user..."

  cat <<EOF > "$TEMP_SUDOERS_FILE"
devops ALL=(root) NOPASSWD: \\
/opt/$DOCKER_ODOO_APP_NAME/scripts/git_addons_updater.sh
EOF

  chmod 440 "$TEMP_SUDOERS_FILE"
  chown root:root "$TEMP_SUDOERS_FILE"

  log_info "Validating sudoers file syntax..."
  if visudo -c -f "$TEMP_SUDOERS_FILE"; then
    log_success "Syntax is valid. Moving file to $SUDOERS_FILE_PATH"
    mv "$TEMP_SUDOERS_FILE" "$SUDOERS_FILE_PATH"
  else
    log_error "Sudoers file syntax is invalid. Aborting."
    exit 1
  fi

  log_success "Sudoers file created successfully at $SUDOERS_FILE_PATH"
  log_info "devops user can now run git_addons_updater.sh with root privileges without a password."
}

main "@"
