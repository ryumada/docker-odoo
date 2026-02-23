#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Transfers ownership of PostgreSQL databases from one user to another.
# Usage: ./scripts/transfer_pg_ownership.sh [OLD_OWNER] [NEW_OWNER]
# Dependencies: sudo, psql

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

# Check for root
if [ "$(id -u)" -ne 0 ]; then
    log_info "Elevating permissions to root..."
    exec sudo "$0" "$@"
fi

# --- Inputs ---

OLD_OWNER="$1"
NEW_OWNER="$2"

if [ -z "$OLD_OWNER" ]; then
    read -rp "Enter the Old Owner (to find databases): " OLD_OWNER
fi

if [ -z "$NEW_OWNER" ]; then
    read -rp "Enter the New Owner: " NEW_OWNER
fi

if [ -z "$OLD_OWNER" ] || [ -z "$NEW_OWNER" ]; then
    log_error "Old Owner and New Owner are required."
    echo "Usage: $0 [OLD_OWNER] [NEW_OWNER]"
    exit 1
fi

log_info "Looking for databases owned by '$OLD_OWNER'..."

DATABASES_TO_MIGRATE=()
while IFS= read -r dbname; do
  DATABASES_TO_MIGRATE+=("$dbname")
done < <(sudo -u postgres psql -tAc "SELECT datname FROM pg_database WHERE datdba = (SELECT usesysid FROM pg_user WHERE usename = '$OLD_OWNER');")

if [ ${#DATABASES_TO_MIGRATE[@]} -eq 0 ]; then
    log_warn "No databases found owned by '$OLD_OWNER'."
    exit 0
else
    log_success "Found ${#DATABASES_TO_MIGRATE[@]} database(s): ${DATABASES_TO_MIGRATE[*]}"
fi

# Check if new owner exists
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$NEW_OWNER'" | grep -q 1; then
    log_warn "User '$NEW_OWNER' does not exist in PostgreSQL. Creating it now..."
    sudo -u postgres psql -c "CREATE ROLE \"$NEW_OWNER\" LOGIN CREATEDB;"
    log_success "Created user '$NEW_OWNER'."
fi

for SUDOERP_DATABASE_NAME_DEV in "${DATABASES_TO_MIGRATE[@]}"; do
    log_info "--------------------------------------------------------"
    log_info "Processing Database: $SUDOERP_DATABASE_NAME_DEV"
    log_info "--------------------------------------------------------"

    log_info "Changing database owner..."
    sudo -u postgres psql -c "ALTER DATABASE \"$SUDOERP_DATABASE_NAME_DEV\" OWNER TO \"$NEW_OWNER\";";

    log_info "Changing ownership of tables, sequences, and views..."
    sudo -u postgres psql -d "$SUDOERP_DATABASE_NAME_DEV" -c "
      -- Change the owner of all tables
      DO \$\$
      DECLARE
          rec RECORD;
      BEGIN
          FOR rec IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
              EXECUTE 'ALTER TABLE ' || quote_ident(rec.tablename) || ' OWNER TO \"$NEW_OWNER\"';
          END LOOP;
      END \$\$;

      -- Change the owner of all sequences
      DO \$\$
      DECLARE
          rec RECORD;
      BEGIN
          FOR rec IN (SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema = 'public') LOOP
              EXECUTE 'ALTER SEQUENCE ' || quote_ident(rec.sequence_name) || ' OWNER TO \"$NEW_OWNER\"';
          END LOOP;
      END \$\$;

      -- Change the owner of all views
      DO \$\$
      DECLARE
          rec RECORD;
      BEGIN
          FOR rec IN (SELECT table_name FROM information_schema.views WHERE table_schema = 'public') LOOP
              EXECUTE 'ALTER VIEW ' || quote_ident(rec.table_name) || ' OWNER TO \"$NEW_OWNER\"';
          END LOOP;
      END \$\$;
    "
    log_success "Ownership transfer complete for database '$SUDOERP_DATABASE_NAME_DEV'."
done
