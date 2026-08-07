#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Sets DB_NAME in .env and automatically updates containers via docker compose.
# Usage: ./scripts/change_database.sh <db_name>
# Dependencies: bash, sed, docker

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel)

ENV_FILE="$PATH_TO_ODOO/.env"
COMPOSE_FILE="$PATH_TO_ODOO/docker-compose.yml"

# --- Logging Functions & Colors ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_ERROR="\033[0;31m"

log() {
    local color="$1"
    local emoji="$2"
    local message="$3"
    echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}" >&2
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }

NEW_DB="$1"

if [ -z "$NEW_DB" ]; then
    log_error "Missing database name. Usage: $0 <db_name>"
    exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
    log_error ".env file not found at $ENV_FILE"
    exit 1
fi

# Update DB_NAME in .env
if grep -q "^DB_NAME=" "$ENV_FILE"; then
    sed -i "s/^DB_NAME=.*/DB_NAME=$NEW_DB/" "$ENV_FILE"
else
    echo "DB_NAME=$NEW_DB" >> "$ENV_FILE"
fi

log_success "Successfully set DB_NAME to '$NEW_DB' in $ENV_FILE"

# Automatically run docker compose up -d
log_info "Applying deployment changes via docker compose up -d..."
sudo -u "$CURRENT_DIR_USER" docker compose -f "$COMPOSE_FILE" up -d
log_success "Deployment containers updated successfully."
