#!/bin/bash

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
ODOO_FILESTORE_PATH="/var/lib/odoo/$SERVICE_NAME/filestore"

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

function isRoot() {
  if [ "$(id -u)" -ne 0 ]; then
    log_error "Please run this script as root"
    exit 1
  fi
}

function areYouReallySure() {
  prompt=$1

  echo "Are you sure want to delete data on $SERVICE_NAME deployment?"
  echo -e "Type '$prompt'\n"
  read -r -p ": " RESPONSE

  if [ "$RESPONSE" != "$prompt" ]; then
    log_error "You don't write the correct phrase. Exiting..."
    log_info "Deletion aborted."
    exit 1
  fi
}

function whichData() {
  local DB_LIST

  read -rp "Enter the name of Odoo Database you want to remote (Enter multiple database with comma [,]): " DB_LIST

  if [ -z "$DB_LIST" ]; then
    echo "No database name entered. Exiting..."
    exit 1
  fi

  echo "$DB_LIST"
}

function main() {
  isRoot

  areYouReallySure "yes"

  DB_LIST="$(whichData)"

  for DB in $(echo "$DB_LIST" | tr "," "\n"); do
    log_info "Removing Odoo Database: $DB"
    sudo -u postgres psql -d postgres -c "DROP DATABASE IF EXISTS \"$DB\" WITH (FORCE)" > /dev/null 2>&1 || { log_error "Error dropping database: $(cat /dev/stderr)"; exit 1; }

    log_info "Removing Odoo Filestore: $ODOO_FILESTORE_PATH/$DB"
    sudo rm -rf "$ODOO_FILESTORE_PATH/$DB"

    log_success "Odoo Database: $DB has been removed"
  done
}

main
