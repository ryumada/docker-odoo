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

DOCKER_ODOO_APP_NAME=$SERVICE_NAME

function append_sudoers_rule() {
  local user="$1"
  local script_type="$2"
  local SCRIPT_NAME="$3"
  local output_file="$4"

  if ! id "$user" &>/dev/null; then
    log_warn "User '$user' does not exist on this system. Skipping sudoers rule for '$user'."
    return 0
  fi

  local script_path
  if [ "$script_type" == "scripts" ]; then
    script_path="$PATH_TO_ODOO/scripts/$SCRIPT_NAME.sh"
    if [ ! -f "$script_path" ] && [ -f "$PATH_TO_ODOO/scripts/$SCRIPT_NAME" ]; then
      script_path="$PATH_TO_ODOO/scripts/$SCRIPT_NAME"
    fi
  else
    script_path="$PATH_TO_ODOO/$SCRIPT_NAME.sh"
    if [ ! -f "$script_path" ] && [ -f "$PATH_TO_ODOO/$SCRIPT_NAME" ]; then
      script_path="$PATH_TO_ODOO/$SCRIPT_NAME"
    fi
  fi

  if [ ! -f "$script_path" ]; then
    log_warn "Target script not found at $script_path. Skipping."
    return 0
  fi

  local rule_content="$user ALL=(root) NOPASSWD: $script_path"
  if ! grep -qF "$rule_content" "$output_file"; then
    echo "$rule_content" >> "$output_file"
    log_info "Added sudoers rule for '$user': $script_path"
  fi
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

  local sudoers_file_name="01-${DOCKER_ODOO_APP_NAME//./_}"
  local target_path="/etc/sudoers.d/$sudoers_file_name"
  local temp_file
  temp_file=$(mktemp)

  cat <<EOF > "$temp_file"
# Consolidated sudoers configuration for service: $SERVICE_NAME
# Generated automatically by install_sudoers.sh

EOF

  # Create sudoers rules for the 'devops' user
  append_sudoers_rule "devops" "scripts" "change_database" "$temp_file"
  append_sudoers_rule "devops" "scripts" "git_addons_updater" "$temp_file"
  append_sudoers_rule "devops" "scripts" "git_odoo-base_updater" "$temp_file"
  append_sudoers_rule "devops" "scripts" "list-databases" "$temp_file"
  append_sudoers_rule "devops" "scripts" "deploy_release_candidate-$SERVICE_NAME" "$temp_file"
  append_sudoers_rule "devops" "scripts" "restore_backupdata-$SERVICE_NAME" "$temp_file"

  # Create sudoers rules for the 'odoo' user
  append_sudoers_rule "odoo" "scripts" "change_database" "$temp_file"
  append_sudoers_rule "odoo" "scripts" "git_addons_updater" "$temp_file"
  append_sudoers_rule "odoo" "scripts" "git_odoo-base_updater" "$temp_file"
  append_sudoers_rule "odoo" "scripts" "list-databases" "$temp_file"
  append_sudoers_rule "odoo" "scripts" "deploy_release_candidate-$SERVICE_NAME" "$temp_file"
  append_sudoers_rule "odoo" "scripts" "restore_backupdata-$SERVICE_NAME" "$temp_file"

  # Create sudoers rules for the user who ran the script, if they are not 'devops' or 'root'
  local logged_in_user
  logged_in_user="${SUDO_USER:-${REPOSITORY_OWNER:-$(id -un)}}"
  if [ "$logged_in_user" != "root" ] && [ "$logged_in_user" != "devops" ]; then
    append_sudoers_rule "$logged_in_user" "scripts" "change_database" "$temp_file"
    append_sudoers_rule "$logged_in_user" "scripts" "git_addons_updater" "$temp_file"
    append_sudoers_rule "$logged_in_user" "scripts" "git_odoo-base_updater" "$temp_file"
    append_sudoers_rule "$logged_in_user" "scripts" "list-databases" "$temp_file"
    append_sudoers_rule "$logged_in_user" "scripts" "backupdata-$SERVICE_NAME" "$temp_file"
    append_sudoers_rule "$logged_in_user" "scripts" "databasecloner-$SERVICE_NAME" "$temp_file"
    append_sudoers_rule "$logged_in_user" "scripts" "deploy_release_candidate-$SERVICE_NAME" "$temp_file"
    append_sudoers_rule "$logged_in_user" "scripts" "restore_backupdata-$SERVICE_NAME" "$temp_file"
    append_sudoers_rule "$logged_in_user" "scripts" "snapshot-$SERVICE_NAME" "$temp_file"
    append_sudoers_rule "$logged_in_user" "root" "setup" "$temp_file"
  fi

  chmod 0440 "$temp_file"
  chown root:root "$temp_file" 2>/dev/null || true

  if ! visudo -c -f "$temp_file"; then
    log_error "Generated sudoers content for $SERVICE_NAME is invalid. Aborting."
    rm -f "$temp_file"
    return 1
  fi

  # Clean up legacy per-action sudoers files for this service to resolve sudoers limit
  for old_sudoers in /etc/sudoers.d/01-*_as_root-${DOCKER_ODOO_APP_NAME//./_}-* /etc/sudoers.d/01-*-${DOCKER_ODOO_APP_NAME//./_}-*; do
    if [ -f "$old_sudoers" ]; then
      log_info "Removing legacy sudoers file: $old_sudoers"
      rm -f "$old_sudoers"
    fi
  done

  log_info "Installing consolidated sudoers file at $target_path..."
  if ! mv "$temp_file" "$target_path"; then
    log_error "Failed to move validated sudoers file to $target_path. Aborting."
    rm -f "$temp_file"
    return 1
  fi

  rm -f "$temp_file" 2>/dev/null || true
  log_success "Consolidated sudoers file for $SERVICE_NAME created successfully at $target_path."
  log_success "Finished updating sudoers configurations."
}

main "$@"
