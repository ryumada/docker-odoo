#!/usr/bin/env bash
set -e
# Category: Installer
# Description: Installs the dump_database utility for container-aware database dumping.
# Usage: ./scripts/installer/install-dump_database.sh
# Dependencies: git, sudo

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_ERROR="\033[0;31m"

log() {
  local color="$1"
  local emoji="$2"
  local message="$3"
  echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}"
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }

install_script() {
  local link_name="$1"
  local source_path="$2"
  local target_path="$3"

  if [ -f "$source_path" ]; then
    log_info "Copying '$source_path' to '$target_path'..."
    cp "$source_path" "$target_path"
    chown "$REPOSITORY_OWNER:$REPOSITORY_OWNER" "$target_path"
    chmod +x "$target_path"
    log_success "Script created and made executable at '$target_path'."

    local system_link_path="/usr/local/sbin/$link_name"
    log_info "Creating system-wide symlink at '$system_link_path'..."
    sudo ln -sf "$target_path" "$system_link_path"
    log_success "Symlink created: $system_link_path -> $target_path"
  else
    log_error "Source file '$source_path' does not exist."
    exit 1
  fi
}

main() {
  local link_name="dump_database-$SERVICE_NAME"
  local script_filename="$link_name.sh"
  local target_path="$PATH_TO_ODOO/scripts/$script_filename"
  local source_path="$PATH_TO_ODOO/scripts/example/dump_database.sh.example"

  install_script "$link_name" "$source_path" "$target_path"
  log_success "Database dump utility installed successfully."
}

main "$@"
