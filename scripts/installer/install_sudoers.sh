#!/usr/bin/env bash
set -e
# Category: Installer
# Description: Configures sudoers rules for Odoo management scripts.
# Usage: ./scripts/installer/install_sudoers.sh
# Dependencies: sudo, git, visudo

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

DOCKER_ODOO_APP_NAME=$SERVICE_NAME

function create_sudoers_file() {
  local user="$1"
  local script_type="$2"
  local SCRIPT_NAME="$3"

  if ! id "$user" &>/dev/null; then
    log_warn "User '$user' does not exist on this system. Skipping sudoers creation."
    return 0
  fi

  local script_path
  if [ "$script_type" == "scripts" ]; then
    script_path="$PATH_TO_ODOO/scripts/$SCRIPT_NAME.sh"
  else
    script_path="$PATH_TO_ODOO/$SCRIPT_NAME.sh"
  fi

  if [ ! -f "$script_path" ]; then
    log_warn "Target script not found at $script_path. Skipping."
    return 0
  fi

  local sudoers_file_name="01-${user}_as_root-${DOCKER_ODOO_APP_NAME//./_}-${SCRIPT_NAME//./_}"
  local target_path="/etc/sudoers.d/$sudoers_file_name"
  local rule_content="$user ALL=(root) NOPASSWD: $script_path"
  local temp_file
  temp_file=$(mktemp)

  log_info "Creating sudoers file for '$user' user at $target_path to be able to run $script_path..."

  echo "$rule_content" > "$temp_file"
  chmod 0440 "$temp_file"

  # Use a here-document to create the sudoers file content
  if ! visudo -c -f "$temp_file"; then
    log_error "Generated sudoers content for user '$user' is invalid. Aborting."
    rm -f "$temp_file"
    return 1
  fi

  if ! mv "$temp_file" "$target_path"; then
    log_error "Failed to move validated sudoers file to $target_path. Aborting."
    rm -f "$temp_file"
    return 1
  fi

  rm -f "$temp_file"
  log_success "Sudoers file for '$user' created successfully at $target_path."
}

function main() {
  # Self-elevate to root if not already
  if [ "$(id -u)" -ne 0 ]; then
    log_info "Elevating permissions to root..."
    # shellcheck disable=SC2093
    if ! exec sudo "$0" "$@"; then
      log_error "Failed to elevate to root. Please run with sudo."
      exit 1
    fi
  fi

  log_info "Detected Odoo App Name: $DOCKER_ODOO_APP_NAME"

  # Create sudoers file for the 'devops' user
  create_sudoers_file "devops" "scripts" "git_addons_updater"
  create_sudoers_file "devops" "scripts" "git_odoo-base_updater"
  create_sudoers_file "devops" "scripts" "deploy_release_candidate-$SERVICE_NAME"
  create_sudoers_file "devops" "scripts" "restore_backupdata-$SERVICE_NAME"

  # Create sudoers file for the user who ran the script, if they are not 'devops' or 'root'
  local logged_in_user
  logged_in_user=$(logname)
  if [ "$logged_in_user" != "root" ] && [ "$logged_in_user" != "devops" ]; then
    create_sudoers_file "$logged_in_user" "scripts" "git_addons_updater"
    create_sudoers_file "$logged_in_user" "scripts" "git_odoo-base_updater"
    create_sudoers_file "$logged_in_user" "scripts" "deploy_release_candidate-$SERVICE_NAME"
    create_sudoers_file "$logged_in_user" "scripts" "restore_backupdata-$SERVICE_NAME"
    create_sudoers_file "$logged_in_user" "root" "setup"
  fi

  log_success "Finished updating sudoers configurations."
}

main "$@"
