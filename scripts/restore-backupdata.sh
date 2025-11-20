#!/bin/bash

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

function error_handler() {
  log_error "Error on line $1"
  exit 1
}

function amIRoot() {
  if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root"
    exit 1
  fi
}

function isBackupDataExists() {
  backupdata_file_path="$1"
  if [ ! -f "$backupdata_file_path" ]; then
    log_error "Backup data file $backupdata_file_path does not exist. Please place your backupdata file on /tmp directory."
    exit 1
  fi
}

function isCurlInstalled() {
  if ! command -v curl &>/dev/null; then
    log_error "curl is not installed. Please install curl."
    echo "Ubuntu: sudo apt install curl"
    echo "CentOS: sudo yum install curl"
    exit 1
  fi
}

function restoreOdooDataViaEndpoint() {
  log_info "Restoring database via Odoo endpoint..."
  response=$(curl -s -X POST -F "master_pwd=$ADMIN_PASSWD" -F "name=$RESTORED_DB_NAME" -F "backup_file=@$BACKUPDATA_FILE_PATH" -F "copy=true" "http://localhost:$PORT/web/database/restore")
  if [[ "$response" != *"error"* ]] && [[ "$response" != *"incorrect master password"* ]]; then
    log_success "Database restore command sent successfully."
  else
    log_error "Failed to restore database via endpoint. Response: $response"
    exit 1
  fi
}

trap 'error_handler $LINENO' ERR

function main() {
  CURRENT_DIR=$(dirname "$(readlink -f "$0")")
  CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
  PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
  ENV_FILE="$PATH_TO_ODOO/.env"
  SERVICE_NAME=$(basename "$PATH_TO_ODOO")
  BACKUPDATA_FILE_NAME="backupdata-$SERVICE_NAME.zip"
  BACKUPDATA_FILE_PATH="/tmp/$BACKUPDATA_FILE_NAME"
  RESTORED_DB_NAME=""

  ADMIN_PASSWD=$(grep "^ADMIN_PASSWD=" "$ENV_FILE" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')
  PORT=$(grep "^PORT=" "$ENV_FILE" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')
  if [ -z "$ADMIN_PASSWD" ] || [ -z "$PORT" ]; then
      log_error "ADMIN_PASSWD and/or PORT not set in .env file. Cannot proceed with restore."
      exit 1
  fi

  amIRoot
  isBackupDataExists "$BACKUPDATA_FILE_PATH"
  isCurlInstalled

  log_info "Start restoring backup data for $SERVICE_NAME"

  while true; do

    PROMPT_FOR_DATABASE_NAME=$(grep "^PROMPT_FOR_DATABASE_NAME=" "$PATH_TO_ODOO/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')
    if [ -z "$PROMPT_FOR_DATABASE_NAME" ]; then
      ODOO_DATABASE_NAME_PRD=$(grep "^DB_NAME=" "$PATH_TO_ODOO/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')
      if [ -z "$ODOO_DATABASE_NAME_PRD" ]; then
        RESTORED_DB_NAME="$SERVICE_NAME-$(date +"%Y%m%d-%H%M%S")"
      else
        RESTORED_DB_NAME="$ODOO_DATABASE_NAME_PRD-$(date +"%Y%m%d-%H%M%S")"
      fi
    else
      read -rp "Enter the new database name: " RESTORED_DB_NAME
    fi

    log_info "Database name would be $RESTORED_DB_NAME"

    log_info "Checking if the database exists"
    if sudo -u postgres psql -c '\l' | grep -wq "$RESTORED_DB_NAME"; then
      log_error "Database $RESTORED_DB_NAME exists. You need to enter the new database name"
    else
      log_success "Database $RESTORED_DB_NAME does not exist"
      break
    fi
  done

  restoreOdooDataViaEndpoint

  log_success "Finish restoring backup data for $SERVICE_NAME"
}

main
