#!/usr/bin/env bash
set -e
# Category: Configuration
# Description: Updates the .env file from .env.example, preserving existing values and backing up old configs.
# Usage: ./scripts/update-env-file.sh [template_file]
# Dependencies: git, sed, sudo

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
  TEMPLATE_ENV_FILE=${1:-.env.example}

  echo "-------------------------------------------------------------------------------"
  echo " UPDATE ENV FILE FOR $SERVICE_NAME @ $(date +"%A, %d %B %Y %H:%M %Z")"
  echo "-------------------------------------------------------------------------------"

  log_info "Path to Odoo: $PATH_TO_ODOO"
  if ! cd "$PATH_TO_ODOO"; then
    log_error "Failed to change directory to $PATH_TO_ODOO"
    exit 1
  fi

  if [ -f "$PATH_TO_ODOO/.env" ]; then
    TIMESTAMP=$(date +"%Y%m%d%H%M%S")
    BACKUP_NAME=".env.backup_${TIMESTAMP}"

    log_info "Existing .env found. Creating persistent backup: ${BACKUP_NAME}"
    cp .env "$BACKUP_NAME"
    chown "$REPOSITORY_OWNER": "$BACKUP_NAME"

    # Rotate backups: Keep only the MAX_BACKUPS most recent ones
    BACKUP_COUNT=$(ls -1 .env.backup_* 2>/dev/null | wc -l)

    if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
        log_info "Rotating backups (limit $MAX_BACKUPS)..."
        # List backups by time (oldest first), take the excess count, and delete them
        ls -1t .env.backup_* | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm --
    fi
  else
    log_warn ".env file not found. Backup skipped"
  fi

  if [ -f "$TEMPLATE_ENV_FILE" ]; then
    log_info "Copy $TEMPLATE_ENV_FILE to .env"
    cp "$TEMPLATE_ENV_FILE" .env
  else
    log_error "Source example file not found: $TEMPLATE_ENV_FILE"
    exit 1
  fi

  # Find the most recent backup file
  LATEST_BACKUP=$(ls -1t .env.backup_* 2>/dev/null | head -n 1)

  if [ -f "$LATEST_BACKUP" ]; then
    log_info "Importing values from $LATEST_BACKUP to .env"
    # Use || [ -n "$line" ] to ensure the last line is processed even without a trailing newline
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^[a-zA-Z_]+[a-zA-Z0-9_]*= ]]; then # Check if line is a variable assignment
        variable_name=$(echo "$line" | cut -d'=' -f1)
        variable_value=$(echo "$line" | cut -d'=' -f2-)

        if grep -q "^$variable_name=" .env && [ -n "$variable_value" ]; then
          log_info "Updating $variable_name..."

          # Escape special characters for sed: backslash, ampersand, and the delimiter |
          escaped_value=$(echo "$variable_value" | sed 's/[&\|]/\\&/g')

          sed -i "s|^$variable_name=.*|$variable_name=$escaped_value|" .env
        fi
      fi
    done < "$LATEST_BACKUP"
  else
    log_warn "No backup file found. Import skipped."
  fi

  log_info "Update .env file with current user and group."
  chown "$REPOSITORY_OWNER": .env

  log_success "Update finished"
}

main "$@"
