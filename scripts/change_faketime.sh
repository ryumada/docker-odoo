#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Sets or clears FAKETIME in .env and automatically updates containers via docker compose.
# Usage: ./scripts/change_faketime.sh ["YYYY-MM-DD HH:MM:SS" | clear]
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

NEW_FAKETIME_RAW="$*"
# Trim leading and trailing whitespace
NEW_FAKETIME_RAW="$(echo "$NEW_FAKETIME_RAW" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

# Strip surrounding double or single quotes if present
if [[ "$NEW_FAKETIME_RAW" =~ ^\"(.*)\"$ ]] || [[ "$NEW_FAKETIME_RAW" =~ ^\'(.*)\'$ ]]; then
    NEW_FAKETIME_RAW="${BASH_REMATCH[1]}"
fi

NEW_FAKETIME_LOWER=$(echo "$NEW_FAKETIME_RAW" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

if [ -z "$NEW_FAKETIME_RAW" ] || [ "$NEW_FAKETIME_LOWER" = "clear" ] || [ "$NEW_FAKETIME_LOWER" = "none" ] || [ "$NEW_FAKETIME_LOWER" = "--clear" ] || [ "$NEW_FAKETIME_LOWER" = "false" ] || [ "$NEW_FAKETIME_LOWER" = "reset" ]; then
    NEW_FAKETIME=""
else
    NEW_FAKETIME="$NEW_FAKETIME_RAW"
fi

if [ ! -f "$ENV_FILE" ]; then
    log_error ".env file not found at $ENV_FILE"
    exit 1
fi

# Update FAKETIME in .env
if grep -q "^FAKETIME=" "$ENV_FILE"; then
    sed -i "s|^FAKETIME=.*|FAKETIME=$NEW_FAKETIME|" "$ENV_FILE"
else
    echo "FAKETIME=$NEW_FAKETIME" >> "$ENV_FILE"
fi

if [ -z "$NEW_FAKETIME" ]; then
    log_success "Successfully cleared FAKETIME in $ENV_FILE"
else
    log_success "Successfully set FAKETIME to '$NEW_FAKETIME' in $ENV_FILE"
fi

# Automatically run docker compose up -d
log_info "Applying deployment changes via docker compose up -d..."
sudo -u "$CURRENT_DIR_USER" docker compose -f "$COMPOSE_FILE" up -d
log_success "Deployment containers updated successfully."
