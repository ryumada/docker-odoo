#!/bin/bash
set -e

# --- Logging Functions & Colors ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[0;33m"
readonly COLOR_ERROR="\033[0;31m"

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

# Check for root
if [ "$(id -u)" -ne 0 ]; then
    log_info "Elevating permissions to root..."
    exec sudo "$0" "$@"
fi

# Change database tables owner and its database
read -rp "Enter Database Name: " SUDOERP_DATABASE_NAME_DEV
read -rp "Enter the Owner for database $SUDOERP_DATABASE_NAME_DEV: " POSTGRES_USER_DEV

log_info "Processing Database: $SUDOERP_DATABASE_NAME_DEV"
log_info "New Owner: $POSTGRES_USER_DEV"

# Check if new owner exists
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$POSTGRES_USER_DEV'" | grep -q 1; then
    log_warn "User '$POSTGRES_USER_DEV' does not exist in PostgreSQL. Creating it now..."
    sudo -u postgres psql -c "CREATE ROLE \"$POSTGRES_USER_DEV\" LOGIN CREATEDB;"
    log_success "Created user '$POSTGRES_USER_DEV'."
fi

log_info "Changing database owner..."
sudo -u postgres psql -c "ALTER DATABASE \"$SUDOERP_DATABASE_NAME_DEV\" OWNER TO \"$POSTGRES_USER_DEV\"";

log_info "Changing ownership of tables, sequences, and views..."
sudo -u postgres psql -d "$SUDOERP_DATABASE_NAME_DEV" -c "
  -- Change the owner of all tables
  DO \$\$
  DECLARE
      rec RECORD;
  BEGIN
      FOR rec IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
          EXECUTE 'ALTER TABLE ' || quote_ident(rec.tablename) || ' OWNER TO \"$POSTGRES_USER_DEV\"';
      END LOOP;
  END \$\$;

  -- Change the owner of all sequences
  DO \$\$
  DECLARE
      rec RECORD;
  BEGIN
      FOR rec IN (SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema = 'public') LOOP
          EXECUTE 'ALTER SEQUENCE ' || quote_ident(rec.sequence_name) || ' OWNER TO \"$POSTGRES_USER_DEV\"';
      END LOOP;
  END \$\$;

  -- Change the owner of all views
  DO \$\$
  DECLARE
      rec RECORD;
  BEGIN
      FOR rec IN (SELECT table_name FROM information_schema.views WHERE table_schema = 'public') LOOP
          EXECUTE 'ALTER VIEW ' || quote_ident(rec.table_name) || ' OWNER TO \"$POSTGRES_USER_DEV\"';
      END LOOP;
  END \$\$;
"

log_success "Ownership transfer complete for database '$SUDOERP_DATABASE_NAME_DEV'."
