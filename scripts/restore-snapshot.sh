#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Restores an Odoo snapshot (files and database) from a tar archive.
# Usage: ./scripts/restore-snapshot.sh
# Dependencies: tar, zstd, docker, sudo, psql

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

# The path inside the tar is the absolute path without the leading slash
TAR_PROJECT_ROOT="${PATH_TO_ODOO#/}"

TAR_FILE_NAME=snapshot-$SERVICE_NAME.tar.zst
TEMP_DIR=/tmp/snapshot-$SERVICE_NAME

function areYouReallySure() {
  echo -e "\nAre you sure?\n⚠️ This script will replace your current Odoo data and deployment files. ⚠️\nType 'yes I am sure' and press enter to continue.\n"
  read -rp ": " response
  case "$response" in
  "yes I am sure")
    echo -e "\n"
    return 0
    ;;
  *)
    log_error "You are not sure. Exiting the script."
    echo -e "\n"
    exit 1;
    ;;
  esac
}

function cleanup() {
  log_info "Cleanup the temporary directory."
  rm -rf "$TEMP_DIR"
}

function isSnapshotFileExist() {
  if [ ! -f "/tmp/$TAR_FILE_NAME" ]; then
    log_error "/tmp/$TAR_FILE_NAME not found. Please add your snapshot file to /tmp directory. Or create your snapshot using snapshot script."
    exit 1
  fi
}

function isZstdInstalled() {
  if ! command -v zstd >/dev/null 2>&1; then
    log_error "zstd is not installed. Please install zstd first."
    echo "For Ubuntu: sudo apt install zstd"
    echo "For CentOS: sudo yum install zstd"
    exit 1
  fi
}

function restoreDBCredentials() {
  log_info "Restore .secrets directory"
  # Try the project-relative path inside tar
  local secrets_tar_dir="$TEMP_DIR/$TAR_PROJECT_ROOT/.secrets"

  if [ -d "$secrets_tar_dir" ]; then
    mkdir -p "$PATH_TO_ODOO/.secrets"
    cp -rf "$secrets_tar_dir/." "$PATH_TO_ODOO/.secrets/" || { log_error "Can't restore .secrets directory"; }
    chown -R "$REPOSITORY_OWNER": "$PATH_TO_ODOO/.secrets"
    chmod 700 "$PATH_TO_ODOO/.secrets"
    chmod 600 "$PATH_TO_ODOO/.secrets"/*
  else
    log_warn "Secrets directory not found in snapshot at $secrets_tar_dir"
  fi
}

function restoreOdooData() {
  # Discover database name from filestore path structure inside tar
  # Path in tar: var/lib/odoo/$SERVICE_NAME/filestore/[DB_NAME]
  local filestore_base_in_tar="$TEMP_DIR/var/lib/odoo/$SERVICE_NAME/filestore"

  if [ ! -d "$filestore_base_in_tar" ]; then
    log_error "Filestore structure not found in snapshot: $filestore_base_in_tar"
    return 1
  fi

  ODOO_DATABASE_NAME_PRD=$(find "$filestore_base_in_tar" -mindepth 1 -maxdepth 1 -type d -print | head -n 1 | xargs -n 1 basename)

  if [ -z "$ODOO_DATABASE_NAME_PRD" ]; then
    log_error "Could not determine database name from filestore."
    return 1
  fi

  # Discover SQL dump file (supports randomized filename)
  local sql_dump_file=$(find "$TEMP_DIR/tmp" -name "${ODOO_DATABASE_NAME_PRD}_*.sql" -print | head -n 1)

  if [ -z "$sql_dump_file" ]; then
    log_error "SQL dump file for $ODOO_DATABASE_NAME_PRD not found in /tmp/ directory of snapshot."
    return 1
  fi

  ODOO_DATABASE_USER=$(cat "$PATH_TO_ODOO/.secrets/db_user" 2>/dev/null || echo "odoo")

  log_info "Restore odoo filestore /var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"
  local target_filestore="/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"

  rm -rf "$target_filestore"
  mkdir -p "$(dirname "$target_filestore")"

  mv "$filestore_base_in_tar/$ODOO_DATABASE_NAME_PRD" "$target_filestore" || { log_error "Can't restore filestore"; }
  chown -R odoo: "/var/lib/odoo/$SERVICE_NAME"

  log_info "Restore database $ODOO_DATABASE_NAME_PRD from $(basename "$sql_dump_file")"
  sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$ODOO_DATABASE_NAME_PRD\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || log_error "Can't drop database"
  sudo -u postgres psql -c "CREATE DATABASE \"$ODOO_DATABASE_NAME_PRD\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || log_error "Can't create database"
  sudo -u postgres psql -d "$ODOO_DATABASE_NAME_PRD" -f "$sql_dump_file" --quiet -t -P pager=off 2> /dev/null > /dev/null || log_error "Can't restore database"

  log_info "Fixing database ownership for user: $ODOO_DATABASE_USER"
  sudo -u postgres psql -c "ALTER DATABASE \"$ODOO_DATABASE_NAME_PRD\" OWNER TO \"$ODOO_DATABASE_USER\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || log_error "Can't change the owner of the database $ODOO_DATABASE_NAME_PRD"

  sudo -u postgres psql --quiet -t -P pager=off -d "$ODOO_DATABASE_NAME_PRD" -c "
    -- Change the owner of all tables
    DO \$\$
    DECLARE
        rec RECORD;
    BEGIN
        FOR rec IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
            EXECUTE 'ALTER TABLE ' || quote_ident(rec.tablename) || ' OWNER TO \"${ODOO_DATABASE_USER}\"';
        END LOOP;
    END \$\$;

    -- Change the owner of all sequences
    DO \$\$
    DECLARE
        rec RECORD;
    BEGIN
        FOR rec IN (SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema = 'public') LOOP
            EXECUTE 'ALTER SEQUENCE ' || quote_ident(rec.sequence_name) || ' OWNER TO \"${ODOO_DATABASE_USER}\"';
        END LOOP;
    END \$\$;

    -- Change the owner of all views
    DO \$\$
    DECLARE
        rec RECORD;
    BEGIN
        FOR rec IN (SELECT table_name FROM information_schema.views WHERE table_schema = 'public') LOOP
            EXECUTE 'ALTER VIEW ' || quote_ident(rec.table_name) || ' OWNER TO \"${ODOO_DATABASE_USER}\"';
        END LOOP;
    END \$\$;
  " 2> /dev/null > /dev/null || log_error "Can't change the owner of the tables, sequences, and views of the database $ODOO_DATABASE_NAME_PRD"
}

function main() {
  log_info "Start restore utility for $SERVICE_NAME"

  if [ "$(id -u)" -ne 0 ]; then
      exec sudo "$0" "$@"
      exit 1
  fi

  areYouReallySure
  isZstdInstalled
  isSnapshotFileExist

  log_info "Extracting snapshot..."
  rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
  if ! tar -xaf "/tmp/$TAR_FILE_NAME" -C "$TEMP_DIR"; then
    log_error "Failed to extract snapshot."
    exit 1
  fi

  # Path aliases for readability
  local src_root="$TEMP_DIR/$TAR_PROJECT_ROOT"

  log_info "Restoring configuration and environment..."
  [ -f "$src_root/conf/odoo.conf" ] && cp -f "$src_root/conf/odoo.conf" "$PATH_TO_ODOO/conf/odoo.conf"
  [ -f "$src_root/.env" ] && cp -f "$src_root/.env" "$PATH_TO_ODOO/.env"
  [ -f "$src_root/requirements.txt" ] && cp -f "$src_root/requirements.txt" "$PATH_TO_ODOO/requirements.txt"

  chown -R "$REPOSITORY_OWNER": "$PATH_TO_ODOO/conf/odoo.conf" "$PATH_TO_ODOO/.env" "$PATH_TO_ODOO/requirements.txt" 2>/dev/null

  restoreDBCredentials

  log_info "Stopping services..."
  (cd "$PATH_TO_ODOO" && docker compose down > /dev/null 2>&1)

  # Restore utility scripts
  log_info "Restoring utility scripts..."
  # Note: scripts/backupdata-SERVICE_NAME etc are legacy? The plan is to standardize.
  # But the snapshot contains them. I will allow restoration but they might be overwritten by setup.sh later if managed there.
  for script in "backupdata-$SERVICE_NAME" "databasecloner-$SERVICE_NAME" "snapshot-$SERVICE_NAME"; do
    if [ -f "$src_root/scripts/$script" ]; then
        cp -f "$src_root/scripts/$script" "$PATH_TO_ODOO/scripts/$script"
        chown "$REPOSITORY_OWNER": "$PATH_TO_ODOO/scripts/$script"
        chmod 755 "$PATH_TO_ODOO/scripts/$script"
        ln -sf "$PATH_TO_ODOO/scripts/$script" "/usr/local/sbin/$script"
    fi
  done

  restoreOdooData

  # Git hashes display
  local hash_file=$(find "$TEMP_DIR/tmp" -name "git_hashes_*.txt" -print | head -n 1)
  if [ -n "$hash_file" ]; then
    echo -e "\n==========================================================================="
    log_info "Git Version Information from Snapshot:"
    cat "$hash_file"
    echo "==========================================================================="
  fi

  cleanup

  log_success "Restoration complete."
  log_warn "Run 'sudo ./setup.sh' to rebuild or pull the Odoo image as needed."
}

main "$@"
