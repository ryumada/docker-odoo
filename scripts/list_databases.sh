#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Lists all databases owned by the project's pg user.
# Usage: ./scripts/list_databases.sh
# Dependencies: docker, psql

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel)

# --- Logging Functions & Colors ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_ERROR="\033[0;31m"

log() {
    local color="$1"
    local emoji="$2"
    local message="$3"
    echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}"
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }

function run_psql() {
    local env_file="${PSQL_ENV_FILE:-$PATH_TO_ODOO/.env}"
    local db_host=$(grep "^DB_HOST=" "$env_file" 2>/dev/null | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
    if [ -n "$db_host" ] && [ "$db_host" != "localhost" ]; then
        local db_port=$(grep "^DB_PORT=" "$env_file" 2>/dev/null | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
        local db_user=$(cat "$(dirname "$env_file")/.secrets/db_user" 2>/dev/null || true)
        local db_pass=$(cat "$(dirname "$env_file")/.secrets/db_password" 2>/dev/null || true)
        local docker_net=$(grep "^DOCKER_NETWORK_MODE=" "$env_file" 2>/dev/null | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
        [ -z "$db_port" ] && db_port="5432"
        [ -z "$docker_net" ] && docker_net="host"
        local net=$(echo "$docker_net" | cut -d "," -f 1)
        docker run -i --rm --network="$net" -e PGPASSWORD="$db_pass" postgres psql -h "$db_host" -p "$db_port" -U "$db_user" "$@"
    else
        sudo -u postgres psql "$@"
    fi
}

db_user_file="$PATH_TO_ODOO/.secrets/db_user"
if [ ! -f "$db_user_file" ]; then
    log_error "Secrets file not found: $db_user_file"
    exit 1
fi

db_user=$(cat "$db_user_file" | tr -d '[:space:]')

if [ -z "$db_user" ]; then
    log_error "Database user is empty in $db_user_file"
    exit 1
fi

log_info "Listing databases owned by user: $db_user"
echo "--------------------------------------------------"
run_psql -t -c "SELECT datname FROM pg_database WHERE datdba = (SELECT oid FROM pg_roles WHERE rolname = '$db_user');" | awk '{$1=$1};1' | grep -v '^\s*$' || echo "No databases found."
echo "--------------------------------------------------"
