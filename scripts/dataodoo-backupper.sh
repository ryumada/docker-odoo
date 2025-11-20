#!/bin/bash

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")

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

function isCurlInstalled() {
  if ! command -v curl &>/dev/null; then
    log_error "curl is not installed. Please install curl."
    echo "Ubuntu: sudo apt install curl"
    echo "CentOS: sudo yum install curl"
    exit 1
  fi
}

function areYouReallySure() {
  prompt=$1

  echo "Are you sure want to backup odoo datas on $SERVICE_NAME deployment?"
  echo -e "Type '$prompt'\n"
  read -r -p ": " RESPONSE

  if [ "$RESPONSE" != "$prompt" ]; then
    log_error "You don't write the correct phrase. Exiting..."
    log_info "Backup aborted."
    exit 1
  fi
}

function whichData() {
  local DB_LIST

  read -rp "Enter the name of Odoo Database(s) you want to backup (Enter multiple database with comma [,]): " DB_LIST

  if [ -z "$DB_LIST" ]; then
    echo "No database name entered. Exiting..."
    exit 1
  fi

  echo "$DB_LIST"
}

function main() {
  # Self-elevate to root if not already
  if [ "$(id -u)" -ne 0 ]; then
      log_info "Elevating permissions to root..."
      # shellcheck disable=SC2068
      exec sudo "$0" ${@}
      log_error "Failed to elevate to root. Please run with sudo." # This will only run if exec fails
      exit 1
  fi
  isCurlInstalled

  areYouReallySure "yes"

  DB_LIST="$(whichData)"

  ADMIN_PASSWD=$(grep "^ADMIN_PASSWD=" "$PATH_TO_ODOO/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')
  PORT=$(grep "^PORT=" "$PATH_TO_ODOO/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')

  if [ -z "$ADMIN_PASSWD" ] || [ -z "$PORT" ]; then
    log_error "ADMIN_PASSWD and/or PORT not set in .env file. Cannot proceed with backup."
    exit 1
  fi

  temporary_directory="/tmp/$(date +"%Y%m%d-%H%M%S")-dataodoo-backupper"
  if mkdir -p "$temporary_directory"; then
    log_success "Created temporary directory: $temporary_directory"
  else
    log_error "Error creating temporary directory: $temporary_directory"
    exit 1
  fi

  for DB in $(echo "$DB_LIST" | tr "," "\n"); do
    log_info "Backing up Odoo Database: $DB"
    BACKUP_FILE_PATH="$temporary_directory/$DB.zip"

    curl -s -X POST \
      -F "master_pwd=$ADMIN_PASSWD" \
      -F "name=$DB" \
      -F "backup_format=zip" \
      -o "$BACKUP_FILE_PATH" \
      "http://localhost:$PORT/web/database/backup"

    if [ -s "$BACKUP_FILE_PATH" ]; then
      log_success "Odoo Database '$DB' has been backed up to: $BACKUP_FILE_PATH"
    else
      log_error "Backup failed for database '$DB'. The output file is empty. Check Odoo logs."
      # Clean up the empty file
      rm -f "$BACKUP_FILE_PATH"
    fi
  done

  # Set ownership of the backup directory to the user who ran the script with sudo
  if [ -n "$SUDO_USER" ]; then
    chown -R "$SUDO_USER":"$SUDO_USER" "$temporary_directory"
  fi

  log_success "All backup operations are complete. Files are located in: $temporary_directory"
}

main "@"
