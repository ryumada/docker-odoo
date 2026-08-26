#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Restores an Odoo snapshot (full or data-only) from a tar archive.
# Usage: ./scripts/restore-snapshot.sh [--data-only] [SNAPSHOT_FILE] [-y]
# Dependencies: tar, zstd, docker, sudo, psql, unzip

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$CURRENT_DIR")
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO" 2>/dev/null || echo "$USER")

# Source common utilities
# shellcheck source=/dev/null
source "$CURRENT_DIR/lib/odoo_utils.sh"

# Configuration
ENV_FILE=".env"
UPDATE_SCRIPT="./scripts/update-env-file.sh"
MAX_BACKUPS=3

# --- Logging Functions & Colors ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[1;33m"
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

# The path inside the tar is the absolute path without the leading slash
TAR_PROJECT_ROOT="${PATH_TO_ODOO#/}"

DEFAULT_TAR_FILE_NAME="snapshot-$SERVICE_NAME.tar.zst"
SNAPSHOT_FILE_PATH=""
DATA_ONLY=false
AUTO_CONFIRM=false
TEMP_DIR="/tmp/snapshot-$SERVICE_NAME"

show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS] [SNAPSHOT_FILE]

Restores an Odoo snapshot from a .tar.zst archive.

Options:
  -d, --data, --data-only   Restore ONLY database and filestore (fast mode).
                            Does not stop container stack or overwrite configs/.env.
  -f, --file <PATH>         Path to snapshot .tar.zst file
  -y, --yes, --force        Skip confirmation prompt
  -h, --help                Show this help message

Arguments:
  SNAPSHOT_FILE             Optional path to snapshot file (default: /tmp/$DEFAULT_TAR_FILE_NAME)

Examples:
  ./scripts/restore-snapshot.sh --data-only
  ./scripts/restore-snapshot.sh --data-only /tmp/snapshot-myproject-20260826.tar.zst -y
  ./scripts/restore-snapshot.sh /tmp/$DEFAULT_TAR_FILE_NAME
EOF
}

# --- Parse CLI Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--data|--data-only)
      DATA_ONLY=true
      shift
      ;;
    -f|--file)
      SNAPSHOT_FILE_PATH="$2"
      shift 2
      ;;
    --file=*)
      SNAPSHOT_FILE_PATH="${1#*=}"
      shift
      ;;
    -y|--yes|--force)
      AUTO_CONFIRM=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    -*)
      log_error "Unknown option: $1"
      show_help
      exit 1
      ;;
    *)
      if [ -z "$SNAPSHOT_FILE_PATH" ]; then
        SNAPSHOT_FILE_PATH="$1"
      else
        log_error "Unexpected argument: $1"
        show_help
        exit 1
      fi
      shift
      ;;
  esac
done

if [ -z "$SNAPSHOT_FILE_PATH" ]; then
  if [ -f "/tmp/$DEFAULT_TAR_FILE_NAME" ]; then
    SNAPSHOT_FILE_PATH="/tmp/$DEFAULT_TAR_FILE_NAME"
  else
    # Find latest snapshot in /tmp matching prefix
    LATEST_TMP_SNAPSHOT=$(find /tmp -maxdepth 1 -name "snapshot-${SERVICE_NAME}*.tar.zst" -printf '%T@ %p\n' 2>/dev/null | sort -k1 -nr | head -n1 | cut -d' ' -f2-)
    if [ -n "$LATEST_TMP_SNAPSHOT" ] && [ -f "$LATEST_TMP_SNAPSHOT" ]; then
      SNAPSHOT_FILE_PATH="$LATEST_TMP_SNAPSHOT"
    else
      SNAPSHOT_FILE_PATH="/tmp/$DEFAULT_TAR_FILE_NAME"
    fi
  fi
fi

function areYouReallySure() {
  if [ "$AUTO_CONFIRM" = true ]; then
    return 0
  fi

  if [ "$DATA_ONLY" = true ]; then
    echo -e "\nAre you sure?\n⚠️ This script will restore Odoo DATA ONLY (database and filestore) for $SERVICE_NAME. ⚠️\nConfigurations, .env, and secrets will remain untouched.\nType 'yes I am sure' and press enter to continue.\n"
  else
    echo -e "\nAre you sure?\n⚠️ This script will replace your current Odoo data and deployment files. ⚠️\nType 'yes I am sure' and press enter to continue.\n"
  fi

  read -rp ": " response
  case "$response" in
  "yes I am sure")
    echo -e "\n"
    return 0
    ;;
  *)
    log_error "You are not sure. Exiting the script."
    echo -e "\n"
    exit 1
    ;;
  esac
}

function cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

function isSnapshotFileExist() {
  if [ ! -f "$SNAPSHOT_FILE_PATH" ]; then
    log_error "Snapshot file '$SNAPSHOT_FILE_PATH' not found."
    log_info "Please specify a valid snapshot file, or download one using:"
    log_info "  ./scripts/download-snapshot.sh latest"
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

function run_psql() {
  local env_file="${PSQL_ENV_FILE:-$PATH_TO_ODOO/.env}"
  local db_host
  db_host=$(grep "^DB_HOST=" "$env_file" 2>/dev/null | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
  local has_db=false
  for arg in "$@"; do
    if [[ "$arg" == "-d" || "$arg" == -d* || "$arg" == "--dbname="* || "$arg" == "--dbname" ]]; then
      has_db=true
      break
    fi
  done
  local db_default=()
  if [ "$has_db" = false ]; then
    db_default=(-d postgres)
  fi
  if [ -n "$db_host" ] && [ "$db_host" != "localhost" ]; then
    local db_port db_user db_pass docker_net net
    db_port=$(grep "^DB_PORT=" "$env_file" 2>/dev/null | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
    db_user=$(cat "$(dirname "$env_file")/.secrets/db_user" 2>/dev/null || true)
    db_pass=$(cat "$(dirname "$env_file")/.secrets/db_password" 2>/dev/null || true)
    docker_net=$(grep "^DOCKER_NETWORK_MODE=" "$env_file" 2>/dev/null | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
    [ -z "$db_port" ] && db_port="5432"
    [ -z "$docker_net" ] && docker_net="host"
    local net=$(echo "$docker_net" | cut -d "," -f 1)
    docker run -i --rm --network="$net" -e PGPASSWORD="$db_pass" postgres psql -h "$db_host" -p "$db_port" -U "$db_user" "${db_default[@]}" "$@"
  else
    sudo -u postgres psql "${db_default[@]}" "$@"
  fi
}

function restoreOdooData() {
  # Locate extracted backupdata zip file inside tar structure
  local extracted_zip
  extracted_zip=$(find "$TEMP_DIR" -name "backupdata-$SERVICE_NAME.zip" -o -name "backupdata-*.zip" 2>/dev/null | head -n 1)

  if [ -n "$extracted_zip" ]; then
    log_info "Found bundled backup data: $extracted_zip"
    cp -f "$extracted_zip" "/tmp/backupdata-$SERVICE_NAME.zip"

    if [ -f "$PATH_TO_ODOO/scripts/restore_backupdata-$SERVICE_NAME" ]; then
      log_info "Running restore_backupdata script..."
      "$PATH_TO_ODOO/scripts/restore_backupdata-$SERVICE_NAME"
      return 0
    elif [ -f "$PATH_TO_ODOO/scripts/restore_backupdata_manual-$SERVICE_NAME" ]; then
      log_info "Running restore_backupdata_manual script..."
      "$PATH_TO_ODOO/scripts/restore_backupdata_manual-$SERVICE_NAME"
      return 0
    else
      log_info "Restoring directly from backup bundle zip..."
      local zip_stage="$TEMP_DIR/zip_stage"
      mkdir -p "$zip_stage"
      if ! unzip -q -o "$extracted_zip" -d "$zip_stage"; then
        log_error "Failed to unpack $extracted_zip"
        return 1
      fi

      local target_db
      target_db=$(grep "^DB_NAME=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
      if [ -z "$target_db" ] && [ -f "$zip_stage/manifest.json" ]; then
        target_db=$(grep -o '"db_name": *"[^"]*"' "$zip_stage/manifest.json" | cut -d'"' -f4)
      fi
      [ -z "$target_db" ] && target_db="$SERVICE_NAME"

      ODOO_DATABASE_NAME_PRD="$target_db"
      ODOO_DATABASE_USER=$(cat "$PATH_TO_ODOO/.secrets/db_user" 2>/dev/null || grep "^ACTIVE_DB_USER=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || echo "odoo")
      [ -z "$ODOO_DATABASE_USER" ] && ODOO_DATABASE_USER="odoo"

      if [ -d "$zip_stage/filestore" ]; then
        log_info "Restoring filestore to /var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD..."
        local target_filestore="/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"
        rm -rf "$target_filestore"
        mkdir -p "$(dirname "$target_filestore")"
        if [ -d "$zip_stage/filestore/$ODOO_DATABASE_NAME_PRD" ]; then
          mv "$zip_stage/filestore/$ODOO_DATABASE_NAME_PRD" "$target_filestore"
        else
          mv "$zip_stage/filestore" "$target_filestore"
        fi
        chown -R odoo: "/var/lib/odoo/$SERVICE_NAME" 2>/dev/null || true
      fi

      if [ -f "$zip_stage/dump.sql" ]; then
        log_info "Restoring database $ODOO_DATABASE_NAME_PRD from dump.sql..."
        run_psql -c "DROP DATABASE IF EXISTS \"$ODOO_DATABASE_NAME_PRD\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || log_error "Can't drop database"
        run_psql -c "CREATE DATABASE \"$ODOO_DATABASE_NAME_PRD\" OWNER \"$ODOO_DATABASE_USER\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || log_error "Can't create database"

        sed -i "1i SET ROLE \"$ODOO_DATABASE_USER\";" "$zip_stage/dump.sql"
        run_psql -d "$ODOO_DATABASE_NAME_PRD" --quiet -t -P pager=off < "$zip_stage/dump.sql" 2> /dev/null > /dev/null || log_error "Can't restore database"
        log_success "Database $ODOO_DATABASE_NAME_PRD restored successfully."
      fi
      return 0
    fi
  fi

  # Discover database name from filestore path structure inside tar
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
  local sql_dump_file
  sql_dump_file=$(find "$TEMP_DIR/tmp" -name "${ODOO_DATABASE_NAME_PRD}_*.sql" -print | head -n 1)

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
  run_psql -c "DROP DATABASE IF EXISTS \"$ODOO_DATABASE_NAME_PRD\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || log_error "Can't drop database"
  run_psql -c "CREATE DATABASE \"$ODOO_DATABASE_NAME_PRD\" OWNER \"$ODOO_DATABASE_USER\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || log_error "Can't create database"

  log_info "Setting role to $ODOO_DATABASE_USER in dump to ensure proper ownership"
  sed -i "1i SET ROLE \"$ODOO_DATABASE_USER\";" "$sql_dump_file"

  run_psql -d "$ODOO_DATABASE_NAME_PRD" --quiet -t -P pager=off < "$sql_dump_file" 2> /dev/null > /dev/null || log_error "Can't restore database"
}

function restoreSnapshotDataOnly() {
  log_info "Starting DATA-ONLY snapshot restoration for $SERVICE_NAME (fast mode)"

  areYouReallySure
  isZstdInstalled
  isSnapshotFileExist

  log_info "Performing fast selective extraction from $SNAPSHOT_FILE_PATH..."
  rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"

  # Fast selective extraction: unpack only backup bundle, filestore, dump sql, and metadata
  if ! tar -xaf "$SNAPSHOT_FILE_PATH" -C "$TEMP_DIR" --wildcards "*backupdata*.zip" "*filestore*" "*.sql" "*manifest.json*" "*git_hashes*" 2>/dev/null; then
    log_info "Selective extraction not matched, extracting full archive..."
    if ! tar -xaf "$SNAPSHOT_FILE_PATH" -C "$TEMP_DIR"; then
      log_error "Failed to extract snapshot."
      exit 1
    fi
  fi

  log_info "Restoring Odoo database and filestore..."
  restoreOdooData

  # Reload registry dynamically without downtime
  trigger_registry_reload "$ODOO_DATABASE_NAME_PRD" "$PATH_TO_ODOO" 2>/dev/null || true

  # Git hashes display
  local hash_file
  hash_file=$(find "$TEMP_DIR" -name "git_hashes_*.txt" -print 2>/dev/null | head -n 1)
  if [ -n "$hash_file" ]; then
    echo -e "\n==========================================================================="
    log_info "Git Version Information from Snapshot:"
    cat "$hash_file"
    echo "==========================================================================="
  fi

  log_success "Data-only restoration completed successfully in fast mode."
}

function restoreSnapshotFull() {
  log_info "Start FULL restore utility for $SERVICE_NAME"

  areYouReallySure
  isZstdInstalled
  isSnapshotFileExist

  log_info "Extracting full snapshot from $SNAPSHOT_FILE_PATH..."
  rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
  if ! tar -xaf "$SNAPSHOT_FILE_PATH" -C "$TEMP_DIR"; then
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
  for script in "backupdata-$SERVICE_NAME" "databasecloner-$SERVICE_NAME" "snapshot-$SERVICE_NAME"; do
    if [ -f "$src_root/scripts/$script" ]; then
        cp -f "$src_root/scripts/$script" "$PATH_TO_ODOO/scripts/$script"
        chown "$REPOSITORY_OWNER": "$PATH_TO_ODOO/scripts/$script"
        chmod 755 "$PATH_TO_ODOO/scripts/$script"
        ln -sf "$PATH_TO_ODOO/scripts/$script" "/usr/local/sbin/$script"
    fi
  done

  restoreOdooData

  trigger_registry_reload "$ODOO_DATABASE_NAME_PRD" "$PATH_TO_ODOO" 2>/dev/null || true

  # Git hashes display
  local hash_file
  hash_file=$(find "$TEMP_DIR" -name "git_hashes_*.txt" -print 2>/dev/null | head -n 1)
  if [ -n "$hash_file" ]; then
    echo -e "\n==========================================================================="
    log_info "Git Version Information from Snapshot:"
    cat "$hash_file"
    echo "==========================================================================="
  fi
  log_success "Restoration complete."
  log_warn "Run 'sudo ./setup.sh' to rebuild or pull the Odoo image as needed."
}

function main() {
  if [ "$(id -u)" -ne 0 ]; then
      exec sudo "$0" "$@"
      exit 1
  fi

  if [ "$DATA_ONLY" = true ]; then
    restoreSnapshotDataOnly
  else
    restoreSnapshotFull
  fi
}

main "$@"
