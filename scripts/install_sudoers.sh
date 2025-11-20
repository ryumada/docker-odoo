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

function create_sudoers_file() {
  local user="$1"
  local sudoers_file_name="01-${user}_as_root-$DOCKER_ODOO_APP_NAME-git_addons_updater"
  local sudoers_file_path="/etc/sudoers.d/$sudoers_file_name"

  log_info "Creating sudoers file for '$user' user at $sudoers_file_path..."

  # Use a here-document to create the sudoers file content
  if ! (
    echo "$user ALL=(root) NOPASSWD: \\"
    echo "/opt/$DOCKER_ODOO_APP_NAME/scripts/git_addons_updater.sh"
  ) | visudo -c -f -; then
    log_error "Generated sudoers content for user '$user' is invalid. Aborting for this user."
    return 1
  fi

  (umask 0227; echo "$user ALL=(root) NOPASSWD: /opt/$DOCKER_ODOO_APP_NAME/scripts/git_addons_updater.sh" > "$sudoers_file_path")
  log_success "Sudoers file for '$user' created successfully."
}

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

  # Create sudoers file for the 'devops' user
  create_sudoers_file "devops"

  # Create sudoers file for the user who ran the script, if they are not 'devops' or 'root'
  local logged_in_user
  logged_in_user=$(logname)
  if [ "$logged_in_user" != "root" ] && [ "$logged_in_user" != "devops" ]; then
    create_sudoers_file "$logged_in_user"
  fi

  log_success "Finished updating sudoers configurations."
}

main "@"
