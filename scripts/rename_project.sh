#!/usr/bin/env bash
set -e
# Category: Maintenance
# Description: Renames the project, including directory, database, and configuration updates.
# Usage: ./scripts/rename_project.sh
# Dependencies: git, sudo, docker, psql

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

# --- Check for Root ---
if [ "$(id -u)" -ne 0 ]; then
    log_info "Elevating permissions to root..."
    exec sudo "$0" "$@"
fi

# --- Main Logic ---

OLD_SERVICE_NAME="$SERVICE_NAME"
ENV_FILE="$PATH_TO_ODOO/.env"

if [ ! -f "$ENV_FILE" ]; then
    log_error ".env file not found at $ENV_FILE"
    exit 1
fi

log_info "Current Service Name: $OLD_SERVICE_NAME"

# Identify databases owned by the old user
log_info "Identifying databases owned by '$OLD_SERVICE_NAME'..."
if ! command -v psql &> /dev/null; then
  log_error "psql command not found. Please install postgresql-client."
  exit 1
fi

DATABASES_TO_MIGRATE=()
# Get list of databases owned by the service user
while IFS= read -r dbname; do
  DATABASES_TO_MIGRATE+=("$dbname")
done < <(sudo -u postgres psql -tAc "SELECT datname FROM pg_database WHERE datdba = (SELECT usesysid FROM pg_user WHERE usename = '$OLD_SERVICE_NAME');")

if [ ${#DATABASES_TO_MIGRATE[@]} -eq 0 ]; then
    log_warn "No databases found owned by user '$OLD_SERVICE_NAME'."
else
    log_success "Found ${#DATABASES_TO_MIGRATE[@]} database(s) to migrate: ${DATABASES_TO_MIGRATE[*]}"
fi

# Ask for new Service Name
echo -e "\nPlease enter the NEW Service Name. (e.g., partsindo_16)"
read -rp "New Service Name: " NEW_SERVICE_NAME

if [ -z "$NEW_SERVICE_NAME" ]; then
    log_error "New Service Name cannot be empty."
    exit 1
fi

if [ "$NEW_SERVICE_NAME" == "$OLD_SERVICE_NAME" ]; then
    log_error "New Service Name is the same as the old one."
    exit 1
fi

log_info "Preparing to rename '$OLD_SERVICE_NAME' to '$NEW_SERVICE_NAME'..."
log_warn "This operation will restart services and move directories."
read -rp "Are you sure you want to proceed? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[yY] ]]; then
    log_info "Operation cancelled."
    exit 0
fi

# Pre-calculate absolute paths for the new location
NEW_PATH_TO_ODOO="$(dirname "$PATH_TO_ODOO")/$NEW_SERVICE_NAME"
NEW_ENV_FILE="$NEW_PATH_TO_ODOO/.env"

# Create a temporary script to handle the actual move and restart
TEMP_SCRIPT=$(mktemp)
chmod +x "$TEMP_SCRIPT"

cat <<EOF > "$TEMP_SCRIPT"
#!/bin/bash
set -e

# Re-define log functions for the temp script
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[0;33m"
readonly COLOR_ERROR="\033[0;31m"

log() {
  local color="\$1"
  local emoji="\$2"
  local message="\$3"
  echo -e "\${color}[\$(date +"%Y-%m-%d %H:%M:%S")] \${emoji} \${message}\${COLOR_RESET}"
}
log_info() { log "\${COLOR_INFO}" "ℹ️" "\$1"; }
log_success() { log "\${COLOR_SUCCESS}" "✅" "\$1"; }
log_warn() { log "\${COLOR_WARN}" "⚠️" "\$1"; }
log_error() { log "\${COLOR_ERROR}" "❌" "\$1"; }

error_handler() {
  log_error "An error occurred on line \$1. Exiting..."
  exit 1
}
trap 'error_handler \$LINENO' ERR

# Use static absolute paths calculated by proper logic in parent script
OLD_DIR="$PATH_TO_ODOO"
NEW_DIR="$NEW_PATH_TO_ODOO"
ENV_FILE="$NEW_ENV_FILE"

# Read current data/log paths from .env before moving anything
OLD_DATADIR=\$(grep "^ODOO_DATADIR_SERVICE=" "\$ENV_FILE" | cut -d "=" -f 2)
OLD_LOGDIR=\$(grep "^ODOO_LOG_DIR_SERVICE=" "\$ENV_FILE" | cut -d "=" -f 2)

# Calculate new paths (replacing the service name part)
NEW_DATADIR="\${OLD_DATADIR/$OLD_SERVICE_NAME/$NEW_SERVICE_NAME}"
NEW_LOGDIR="\${OLD_LOGDIR/$OLD_SERVICE_NAME/$NEW_SERVICE_NAME}"

log_info "Stopping containers in \$OLD_DIR..."
cd "\$OLD_DIR" || exit 1
docker compose down || true

log_info "Renaming project directory..."
# Safety check: Ensure the target directory does not exist to avoid nesting
if [ -d "\$NEW_DIR" ]; then
    log_error "Target directory \$NEW_DIR already exists! Aborting to prevent nesting."
    exit 1
fi

# Move out of the directory we are about to rename
cd "\$(dirname "\$OLD_DIR")"
# Use absolute paths for safely moving the project root
mv "\$OLD_DIR" "\$NEW_DIR"

log_info "Renaming data directories..."
# Move Data Directory (Filestore)
if [ -n "\$OLD_DATADIR" ] && [ -d "\$OLD_DATADIR" ]; then
    log_info "Moving Data Dir: \$OLD_DATADIR -> \$NEW_DATADIR"
    sudo mv "\$OLD_DATADIR" "\$NEW_DATADIR"
else
    log_warn "Data directory \$OLD_DATADIR not found or not set."
fi

# Move Log Directory
if [ -n "\$OLD_LOGDIR" ] && [ -d "\$OLD_LOGDIR" ]; then
    log_info "Moving Log Dir: \$OLD_LOGDIR -> \$NEW_LOGDIR"
    sudo mv "\$OLD_LOGDIR" "\$NEW_LOGDIR"
else
    log_warn "Log directory \$OLD_LOGDIR not found or not set."
fi

log_info "Updating .env file..."
# Script is now in the new location, but we use the static absolute path to be safe
sed -i "s|^SERVICE_NAME=.*|SERVICE_NAME=$NEW_SERVICE_NAME|" "\$ENV_FILE"
# Update paths using the variables we captured
if [ -n "\$OLD_LOGDIR" ]; then
    sed -i "s|\$OLD_LOGDIR|\$NEW_LOGDIR|g" "\$ENV_FILE"
fi
if [ -n "\$OLD_DATADIR" ]; then
    sed -i "s|\$OLD_DATADIR|\$NEW_DATADIR|g" "\$ENV_FILE"
fi

# Enable DB secret regeneration so setup.sh creates the new user/password
sed -i "s|^DB_REGENERATE_SECRETS=.*|DB_REGENERATE_SECRETS=Y|" "\$ENV_FILE"

log_info "Running setup.sh to configure new user and permissions..."
cd "\$NEW_DIR"

# Fix "detected dubious ownership" error because we are root but repo is owned by user
git config --global --add safe.directory "\$NEW_DIR"

sudo ./setup.sh

log_info "Transferring database ownership from '$OLD_SERVICE_NAME' to '$NEW_SERVICE_NAME'..."
./scripts/transfer_pg_ownership.sh "$OLD_SERVICE_NAME" "$NEW_SERVICE_NAME"

log_info "Rebuilding and starting services..."
docker compose up -d --build
docker compose restart

log_success "Rename operation completed successfully! New service is running at \$NEW_DIR"

EOF

exec "$TEMP_SCRIPT"
