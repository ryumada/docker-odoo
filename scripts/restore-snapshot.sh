#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Restores an Odoo snapshot (full, data-only, or via restore_backupdata) from a tar archive.
# Usage: ./scripts/restore-snapshot.sh [--data-only | --restore-backupdata] [SNAPSHOT_FILE] [-y]
# Dependencies: tar, zstd, docker, sudo, psql, 7z

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$CURRENT_DIR")
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO" 2>/dev/null || echo "$USER")
DEFAULT_TAR_FILE_NAME="snapshot-$SERVICE_NAME.tar.zst"

show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS] [SNAPSHOT_FILE]

Restores an Odoo snapshot from a .tar.zst archive.

Options:
  -d, --data, --data-only        Restore ONLY database and filestore (fast mode).
                                 Does not stop container stack or overwrite configs/.env.
  -b, --restore-backupdata,      Extract backup bundle and run restore_backupdata utility
      --backupdata               (with DB prefixing / web endpoint / manual runner).
  -n, --name, --dbname <NAME>    Rename/specify target database name
  -f, --file <PATH>              Path to snapshot .tar.zst file
  --no-clone, --skip-clone       Skip automated git repository cloning
  --no-setup                     Skip running setup.sh during full restore
  --no-start                     Skip starting docker compose stack after restore
  -y, --yes, --force             Skip confirmation prompt
  -h, --help                     Show this help message

Arguments:
  SNAPSHOT_FILE                  Optional path to snapshot file (default: ~/$DEFAULT_TAR_FILE_NAME)

Examples:
  ./scripts/restore-snapshot.sh --data-only -n my_new_db
  ./scripts/restore-snapshot.sh --restore-backupdata -n my_renamed_db
  ./scripts/restore-snapshot.sh ~/$DEFAULT_TAR_FILE_NAME
EOF
}

# Handle --help before elevating
for arg in "$@"; do
  if [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
    show_help
    exit 0
  fi
done

# Self-elevate to root if not already, preserving all arguments
if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
  exit 1
fi

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

OWNER_HOME=$(eval echo "~$REPOSITORY_OWNER")
ODOO_TMP_DIR="$OWNER_HOME/.odoo-tmp/$SERVICE_NAME"
mkdir -p "$ODOO_TMP_DIR" 2>/dev/null || true
chmod 700 "$OWNER_HOME/.odoo-tmp" "$ODOO_TMP_DIR" 2>/dev/null || true
chown -R "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$OWNER_HOME/.odoo-tmp" 2>/dev/null || true

SNAPSHOT_FILE_PATH=""
DATA_ONLY=false
RESTORE_VIA_BACKUPDATA=false
AUTO_CONFIRM=false
AUTO_CLONE_GIT=true
RUN_SETUP=true
START_SERVICES=true
TARGET_DB_NAME=""
TEMP_DIR="$ODOO_TMP_DIR/restore_snapshot_$$"

cleanup_temp_dir() {
  if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
  fi
  if [ -n "${EXTRACTED_BACKUPDATA_ZIP:-}" ] && [ -f "$EXTRACTED_BACKUPDATA_ZIP" ]; then
    rm -f "$EXTRACTED_BACKUPDATA_ZIP"
  fi
}
trap cleanup_temp_dir EXIT

# --- Parse CLI Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--data|--data-only)
      DATA_ONLY=true
      shift
      ;;
    -b|--restore-backupdata|--backupdata)
      RESTORE_VIA_BACKUPDATA=true
      shift
      ;;
    -n|--name|--dbname)
      TARGET_DB_NAME="$2"
      shift 2
      ;;
    --name=*|--dbname=*)
      TARGET_DB_NAME="${1#*=}"
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
    --no-clone|--skip-clone)
      AUTO_CLONE_GIT=false
      shift
      ;;
    --no-setup)
      RUN_SETUP=false
      shift
      ;;
    --no-start)
      START_SERVICES=false
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
      elif [ -z "$TARGET_DB_NAME" ]; then
        TARGET_DB_NAME="$1"
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
  candidates=(
    "$OWNER_HOME/$DEFAULT_TAR_FILE_NAME"
    "/tmp/$DEFAULT_TAR_FILE_NAME"
  )
  for c in "${candidates[@]}"; do
    if [ -f "$c" ]; then
      SNAPSHOT_FILE_PATH="$c"
      break
    fi
  done

  if [ -z "$SNAPSHOT_FILE_PATH" ]; then
    LATEST_SNAPSHOT=$(find "$OWNER_HOME/.odoo-snapshots/$SERVICE_NAME/archives" "$OWNER_HOME" /tmp -maxdepth 2 -name "snapshot-${SERVICE_NAME}*.tar.zst" -printf '%T@ %p\n' 2>/dev/null | sort -k1 -nr | head -n1 | cut -d' ' -f2- || true)
    if [ -n "$LATEST_SNAPSHOT" ] && [ -f "$LATEST_SNAPSHOT" ]; then
      SNAPSHOT_FILE_PATH="$LATEST_SNAPSHOT"
    else
      SNAPSHOT_FILE_PATH="$OWNER_HOME/$DEFAULT_TAR_FILE_NAME"
    fi
  fi
fi

function areYouReallySure() {
  if [ "$AUTO_CONFIRM" = true ]; then
    return 0
  fi

  if [ "$RESTORE_VIA_BACKUPDATA" = true ]; then
    echo -e "\nAre you sure?\n⚠️ This script will extract snapshot data and run restore_backupdata for $SERVICE_NAME. ⚠️\nType 'yes I am sure' and press enter to continue.\n"
  elif [ "$DATA_ONLY" = true ]; then
    echo -e "\nAre you sure?\n⚠️ This script will restore Odoo DATA ONLY (database and filestore) for $SERVICE_NAME. ⚠️\nConfigurations, .env, and secrets will remain untouched.\nType 'yes I am sure' and press enter to continue.\n"
  else
    echo -e "\nAre you sure?\n⚠️ This script will restore FULL SNAPSHOT (database, filestore, AND deployment configs/.env/secrets) for $SERVICE_NAME. ⚠️\nType 'yes I am sure' and press enter to continue.\n"
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
  if [ ! -s "$SNAPSHOT_FILE_PATH" ]; then
    log_error "Snapshot file '$SNAPSHOT_FILE_PATH' is 0 bytes (empty file)."
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
  local secrets_tar_dir="$TEMP_DIR/.secrets"
  if [ -d "$TEMP_DIR/$TAR_PROJECT_ROOT/.secrets" ]; then
    secrets_tar_dir="$TEMP_DIR/$TAR_PROJECT_ROOT/.secrets"
  elif [ ! -d "$secrets_tar_dir" ]; then
    local discovered_secrets
    discovered_secrets=$(find "$TEMP_DIR" -maxdepth 5 -type d -name ".secrets" 2>/dev/null | head -n 1)
    [ -n "$discovered_secrets" ] && secrets_tar_dir="$discovered_secrets"
  fi

  if [ -d "$secrets_tar_dir" ]; then
    mkdir -p "$PATH_TO_ODOO/.secrets"
    cp -rf "$secrets_tar_dir/." "$PATH_TO_ODOO/.secrets/" || { log_error "Can't restore .secrets directory"; }
    chown -R "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$PATH_TO_ODOO/.secrets"
    chmod 700 "$PATH_TO_ODOO/.secrets"
    chmod 600 "$PATH_TO_ODOO/.secrets"/*
  else
    log_warn "Secrets directory not found in snapshot at $secrets_tar_dir"
  fi
}

function ensure_postgres_role_configured() {
  local db_user
  db_user=$(cat "$PATH_TO_ODOO/.secrets/db_user" 2>/dev/null || grep "^ACTIVE_DB_USER=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || echo "odoo")
  [ -z "$db_user" ] && db_user="odoo"

  local db_pass
  db_pass=$(cat "$PATH_TO_ODOO/.secrets/db_password" 2>/dev/null || true)

  local env_file="${PSQL_ENV_FILE:-$PATH_TO_ODOO/.env}"
  local db_host
  db_host=$(grep "^DB_HOST=" "$env_file" 2>/dev/null | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' | sed 's/^["'\'']//;s/["'\'']$//' || true)

  if [ -z "$db_host" ] || [ "$db_host" = "localhost" ]; then
    systemctl start postgresql 2>/dev/null || true

    if command -v psql &>/dev/null; then
      if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$db_user'" 2>/dev/null | grep -q 1; then
        log_info "Creating PostgreSQL role '$db_user'..."
        if [ -n "$db_pass" ]; then
          sudo -u postgres psql -c "CREATE ROLE \"$db_user\" LOGIN CREATEDB PASSWORD '$db_pass';" >/dev/null 2>&1
        else
          sudo -u postgres psql -c "CREATE ROLE \"$db_user\" LOGIN CREATEDB;" >/dev/null 2>&1
        fi
      else
        if [ -n "$db_pass" ]; then
          log_info "Updating PostgreSQL role '$db_user' password to match snapshot secret..."
          sudo -u postgres psql -c "ALTER ROLE \"$db_user\" WITH LOGIN CREATEDB PASSWORD '$db_pass';" >/dev/null 2>&1
        fi
      fi
    fi
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

function run_pg_restore() {
  local env_file="${PSQL_ENV_FILE:-$PATH_TO_ODOO/.env}"
  local db_host
  db_host=$(grep "^DB_HOST=" "$env_file" 2>/dev/null | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
  if [ -n "$db_host" ] && [ "$db_host" != "localhost" ]; then
    local db_port db_user db_pass docker_net net
    db_port=$(grep "^DB_PORT=" "$env_file" 2>/dev/null | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
    db_user=$(cat "$(dirname "$env_file")/.secrets/db_user" 2>/dev/null || true)
    db_pass=$(cat "$(dirname "$env_file")/.secrets/db_password" 2>/dev/null || true)
    docker_net=$(grep "^DOCKER_NETWORK_MODE=" "$env_file" 2>/dev/null | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
    [ -z "$db_port" ] && db_port="5432"
    [ -z "$docker_net" ] && docker_net="host"
    local net=$(echo "$docker_net" | cut -d "," -f 1)
    docker run -i --rm --network="$net" -e PGPASSWORD="$db_pass" postgres pg_restore -h "$db_host" -p "$db_port" -U "$db_user" "$@"
  else
    sudo -u postgres pg_restore "$@"
  fi
}

function restoreOdooData() {
  # Locate extracted backupdata zip file inside tar structure
  local extracted_zip
  extracted_zip=$(find "$TEMP_DIR" -name "backupdata-$SERVICE_NAME.zip" -o -name "backupdata-*.zip" 2>/dev/null | head -n 1)

  if [ -n "$extracted_zip" ]; then
    log_info "Found bundled backup data: $extracted_zip"
    cp -f "$extracted_zip" "/tmp/backupdata-$SERVICE_NAME.zip"

    if [ "$DATA_ONLY" = false ] && [ "$RESTORE_VIA_BACKUPDATA" = false ]; then
      if [ -f "$PATH_TO_ODOO/scripts/restore_backupdata-$SERVICE_NAME.sh" ]; then
        log_info "Running restore_backupdata script..."
        "$PATH_TO_ODOO/scripts/restore_backupdata-$SERVICE_NAME.sh"
        return 0
      elif [ -f "$PATH_TO_ODOO/scripts/restore_backupdata-$SERVICE_NAME" ]; then
        log_info "Running restore_backupdata script..."
        "$PATH_TO_ODOO/scripts/restore_backupdata-$SERVICE_NAME"
        return 0
      elif [ -f "$PATH_TO_ODOO/scripts/restore_backupdata_manual-$SERVICE_NAME.sh" ]; then
        log_info "Running restore_backupdata_manual script..."
        "$PATH_TO_ODOO/scripts/restore_backupdata_manual-$SERVICE_NAME.sh"
        return 0
      elif [ -f "$PATH_TO_ODOO/scripts/restore_backupdata_manual-$SERVICE_NAME" ]; then
        log_info "Running restore_backupdata_manual script..."
        "$PATH_TO_ODOO/scripts/restore_backupdata_manual-$SERVICE_NAME"
        return 0
      fi
    fi

    log_info "Restoring database and filestore directly from backup zip bundle..."
    local zip_stage="$TEMP_DIR/zip_stage"
    mkdir -p "$zip_stage"
    local unpack_ok=false
    if command -v 7z &>/dev/null; then
      7z x -y -o"$zip_stage" "$extracted_zip" >/dev/null && unpack_ok=true
    elif command -v 7za &>/dev/null; then
      7za x -y -o"$zip_stage" "$extracted_zip" >/dev/null && unpack_ok=true
    elif command -v unzip &>/dev/null; then
      unzip -q -o "$extracted_zip" -d "$zip_stage" && unpack_ok=true
    fi

    if [ "$unpack_ok" = false ]; then
      log_error "Failed to unpack $extracted_zip"
      return 1
    fi

    local target_db
    if [ -n "$TARGET_DB_NAME" ]; then
      target_db="$TARGET_DB_NAME"
    else
      target_db=$(grep "^DB_NAME=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
      if [ -z "$target_db" ] && [ -f "$zip_stage/manifest.json" ]; then
        target_db=$(grep -o '"db_name": *"[^"]*"' "$zip_stage/manifest.json" | cut -d'"' -f4 || true)
      fi
      [ -z "$target_db" ] && target_db="$SERVICE_NAME"
    fi

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
      chown -R odoo:odoo "/var/lib/odoo/$SERVICE_NAME" 2>/dev/null || true
    fi

    if [ ! -s "$zip_stage/dump.sql" ]; then
      log_error "dump.sql is missing or 0 bytes inside backup bundle ($extracted_zip)."
      return 1
    fi

    log_info "Restoring database $ODOO_DATABASE_NAME_PRD from dump.sql..."
    run_psql -c "DROP DATABASE IF EXISTS \"$ODOO_DATABASE_NAME_PRD\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || log_error "Can't drop database"
    run_psql -c "CREATE DATABASE \"$ODOO_DATABASE_NAME_PRD\" OWNER \"$ODOO_DATABASE_USER\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || log_error "Can't create database"

    if head -c 5 "$zip_stage/dump.sql" 2>/dev/null | grep -q "PGDMP"; then
      log_info "Detected PostgreSQL custom-format dump. Restoring via pg_restore..."
      local restore_status=0
      run_pg_restore --no-owner -d "$ODOO_DATABASE_NAME_PRD" < "$zip_stage/dump.sql" 2> /dev/null > /dev/null || restore_status=$?
      if [ "$restore_status" -gt 1 ]; then
        log_error "Can't restore database via pg_restore (exit code: $restore_status)"
        return 1
      else
        log_success "Database $ODOO_DATABASE_NAME_PRD restored successfully."
      fi
    else
      sed -i "1i SET ROLE \"$ODOO_DATABASE_USER\";" "$zip_stage/dump.sql"
      if ! run_psql -d "$ODOO_DATABASE_NAME_PRD" --quiet -t -P pager=off < "$zip_stage/dump.sql" 2> /dev/null > /dev/null; then
        log_error "Can't restore database from dump.sql"
        return 1
      fi
      log_success "Database $ODOO_DATABASE_NAME_PRD restored successfully."
    fi
    return 0
  fi

  # Discover database name from filestore path structure inside tar
  local filestore_base_in_tar="$TEMP_DIR/var/lib/odoo/$SERVICE_NAME/filestore"

  if [ ! -d "$filestore_base_in_tar" ]; then
    log_error "Filestore structure not found in snapshot: $filestore_base_in_tar"
    return 1
  fi

  local discovered_db
  discovered_db=$(find "$filestore_base_in_tar" -mindepth 1 -maxdepth 1 -type d -print | head -n 1 | xargs -n 1 basename)

  if [ -n "$TARGET_DB_NAME" ]; then
    ODOO_DATABASE_NAME_PRD="$TARGET_DB_NAME"
  elif [ -n "$discovered_db" ]; then
    ODOO_DATABASE_NAME_PRD="$discovered_db"
  else
    log_error "Could not determine database name from filestore."
    return 1
  fi

  # Discover SQL dump file (supports randomized filename)
  local sql_dump_file
  sql_dump_file=$(find "$TEMP_DIR/tmp" -name "${discovered_db}_*.sql" -o -name "*.sql" -print | head -n 1)

  if [ -z "$sql_dump_file" ]; then
    log_error "SQL dump file for $discovered_db not found in /tmp/ directory of snapshot."
    return 1
  fi

  ODOO_DATABASE_USER=$(cat "$PATH_TO_ODOO/.secrets/db_user" 2>/dev/null || echo "odoo")

  log_info "Restore odoo filestore /var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"
  local target_filestore="/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"

  rm -rf "$target_filestore"
  mkdir -p "$(dirname "$target_filestore")"

  if [ -n "$discovered_db" ] && [ -d "$filestore_base_in_tar/$discovered_db" ]; then
    mv "$filestore_base_in_tar/$discovered_db" "$target_filestore" || { log_error "Can't restore filestore"; }
  fi
  chown -R odoo:odoo "/var/lib/odoo/$SERVICE_NAME"

  log_info "Restore database $ODOO_DATABASE_NAME_PRD from $(basename "$sql_dump_file")"
  run_psql -c "DROP DATABASE IF EXISTS \"$ODOO_DATABASE_NAME_PRD\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || log_error "Can't drop database"
  run_psql -c "CREATE DATABASE \"$ODOO_DATABASE_NAME_PRD\" OWNER \"$ODOO_DATABASE_USER\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || log_error "Can't create database"

  log_info "Setting role to $ODOO_DATABASE_USER in dump to ensure proper ownership"
  sed -i "1i SET ROLE \"$ODOO_DATABASE_USER\";" "$sql_dump_file"

  run_psql -d "$ODOO_DATABASE_NAME_PRD" --quiet -t -P pager=off < "$sql_dump_file" 2> /dev/null > /dev/null || log_error "Can't restore database"
}

function check_git_ssh_access() {
  local remote_url="$1"

  # HTTPS URLs don't need SSH checks
  if [[ "$remote_url" =~ ^https?:// ]]; then
    return 0
  fi

  local ssh_host
  if [[ "$remote_url" =~ @([^:/]+) ]]; then
    ssh_host="${BASH_REMATCH[1]}"
  else
    ssh_host="github.com"
  fi

  # Run non-interactive probe with 5s timeout as REPOSITORY_OWNER
  local probe_output
  probe_output=$(sudo -u "$REPOSITORY_OWNER" ssh -T -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=5 "git@$ssh_host" 2>&1 || true)

  if echo "$probe_output" | grep -qiE "successfully authenticated|welcome to gitlab|logged in as|authenticated via"; then
    return 0
  elif echo "$probe_output" | grep -qi "permission denied (publickey)"; then
    return 1
  else
    if compgen -G "$OWNER_HOME/.ssh/id_*" >/dev/null; then
      return 0
    fi
    return 1
  fi
}

function display_git_metadata_summary() {
  local json_file
  json_file=$(find "$TEMP_DIR" -name "git_hashes*.json" -print 2>/dev/null | head -n 1)

  if [ -n "$json_file" ] && [ -f "$json_file" ]; then
    echo -e "\n==========================================================================="
    log_info "Git & Addon Version Information from Snapshot:"
    python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    repos = d.get("git_repositories", [])
    bundled = d.get("bundled_directories", [])
    if repos:
        print("Git Repositories:")
        for r in repos:
            commit_short = r.get("commit", "")[:8] if r.get("commit") else "N/A"
            print(f"  • {r.get(\"name\")} ({r.get(\"relative_path\")}) branch={r.get(\"branch\")} commit={commit_short} remote={r.get(\"remote\")}")
    if bundled:
        print("Bundled Non-Git Directories:")
        for b in bundled:
            print(f"  • {b.get(\"name\")} ({b.get(\"relative_path\")}) [bundled directly in snapshot]")
except Exception:
    pass
' "$json_file" 2>/dev/null || true
    echo "==========================================================================="
  else
    local hash_file
    hash_file=$(find "$TEMP_DIR" -name "git_hashes*.txt" -print 2>/dev/null | head -n 1)
    if [ -n "$hash_file" ]; then
      echo -e "\n==========================================================================="
      log_info "Git Version Information from Snapshot:"
      cat "$hash_file"
      echo "==========================================================================="
    fi
  fi
}

function restore_git_repositories() {
  [ "$AUTO_CLONE_GIT" = false ] && return 0

  local json_file
  json_file=$(find "$TEMP_DIR" -name "git_hashes*.json" -print 2>/dev/null | head -n 1)

  if [ -z "$json_file" ] || [ ! -f "$json_file" ]; then
    return 0
  fi

  local repos_data
  repos_data=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    for r in data.get("git_repositories", []):
        name = r.get("name", "")
        rel_path = r.get("relative_path", "")
        remote = r.get("remote", "")
        branch = r.get("branch", "HEAD")
        commit = r.get("commit", "HEAD")
        if name and rel_path and remote and remote != "N/A":
            print(f"{name}\t{rel_path}\t{remote}\t{branch}\t{commit}")
except Exception:
    pass
' "$json_file" 2>/dev/null || true)

  if [ -z "$repos_data" ]; then
    return 0
  fi

  # Check SSH access for SSH remotes
  local ssh_needed=false
  local ssh_hosts=()
  while IFS=$'\t' read -r name rel_path remote branch commit; do
    if [[ "$remote" =~ ^git@ ]] || [[ "$remote" =~ ^ssh:// ]]; then
      ssh_needed=true
      if [[ "$remote" =~ @([^:/]+) ]]; then
        local host="${BASH_REMATCH[1]}"
        [[ " ${ssh_hosts[*]} " =~ " ${host} " ]] || ssh_hosts+=("$host")
      fi
    fi
  done <<< "$repos_data"

  local ssh_ready=true
  if [ "$ssh_needed" = true ]; then
    for host in "${ssh_hosts[@]}"; do
      log_info "Verifying Git SSH access to $host for user $REPOSITORY_OWNER..."
      if ! check_git_ssh_access "git@$host"; then
        ssh_ready=false
        log_warn "Git SSH authentication failed or key not configured for $REPOSITORY_OWNER on $host."
      else
        log_success "Git SSH access to $host verified for $REPOSITORY_OWNER."
      fi
    done
  fi

  if [ "$ssh_ready" = false ]; then
    echo -e "\n==========================================================================="
    log_warn "⚠️  GIT SSH SETUP REQUIRED TO CLONE PRIVATE REPOSITORIES ⚠️"
    echo -e "Git SSH keys are not authorized on the remote host(s)."
    echo -e "User: $REPOSITORY_OWNER | SSH Directory: $OWNER_HOME/.ssh"
    if [ -f "$OWNER_HOME/.ssh/id_ed25519.pub" ]; then
      echo -e "Existing public key ($OWNER_HOME/.ssh/id_ed25519.pub):"
      cat "$OWNER_HOME/.ssh/id_ed25519.pub"
    elif [ -f "$OWNER_HOME/.ssh/id_rsa.pub" ]; then
      echo -e "Existing public key ($OWNER_HOME/.ssh/id_rsa.pub):"
      cat "$OWNER_HOME/.ssh/id_rsa.pub"
    else
      echo -e "No public key found. Generate one with:"
      echo -e "  sudo -u $REPOSITORY_OWNER ssh-keygen -t ed25519 -C '$REPOSITORY_OWNER@$(hostname)'"
    fi
    echo -e "\nAfter authorizing the SSH key, clone these repositories manually:"
    while IFS=$'\t' read -r name rel_path remote branch commit; do
      echo -e "  git clone -b $branch $remote $PATH_TO_ODOO/$rel_path && git -C $PATH_TO_ODOO/$rel_path checkout $commit"
    done <<< "$repos_data"
    echo "===========================================================================\n"
    return 0
  fi

  log_info "Synchronizing git repositories..."
  while IFS=$'\t' read -r name rel_path remote branch commit; do
    local target_dir="$PATH_TO_ODOO/$rel_path"
    mkdir -p "$(dirname "$target_dir")"
    chown "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$(dirname "$target_dir")" 2>/dev/null || true

    if [ -d "$target_dir/.git" ]; then
      log_info "Repository '$name' already exists at $rel_path. Updating commit..."
      sudo -u "$REPOSITORY_OWNER" git -C "$target_dir" checkout -q "$commit" 2>/dev/null || {
        sudo -u "$REPOSITORY_OWNER" git -C "$target_dir" fetch -q origin 2>/dev/null || true
        sudo -u "$REPOSITORY_OWNER" git -C "$target_dir" checkout -q "$commit" 2>/dev/null || log_warn "Could not checkout commit $commit on $name"
      }
    else
      log_info "Cloning $name ($branch) from $remote into $rel_path..."
      if sudo -u "$REPOSITORY_OWNER" git clone --branch "$branch" "$remote" "$target_dir" 2>/dev/null; then
        if [ "$commit" != "HEAD" ] && [ -n "$commit" ]; then
          sudo -u "$REPOSITORY_OWNER" git -C "$target_dir" checkout -q "$commit" 2>/dev/null || true
        fi
        log_success "Repository $name restored at commit $(sudo -u "$REPOSITORY_OWNER" git -C "$target_dir" rev-parse --short HEAD 2>/dev/null || echo "$commit")"
      else
        log_error "Failed to clone $name from $remote"
      fi
    fi
    chown -R "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$target_dir" 2>/dev/null || true
  done <<< "$repos_data"
}

function restoreFromSnapshotViaBackupData() {
  log_info "Starting snapshot restoration via restore_backupdata for $SERVICE_NAME"

  areYouReallySure
  isZstdInstalled
  isSnapshotFileExist

  log_info "Extracting backupdata bundle from $SNAPSHOT_FILE_PATH..."
  rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"

  if ! tar -xaf "$SNAPSHOT_FILE_PATH" -C "$TEMP_DIR" --wildcards "*backupdata*.zip" 2>/dev/null; then
    log_info "Selective extraction not matched, extracting full archive..."
    if ! tar -xaf "$SNAPSHOT_FILE_PATH" -C "$TEMP_DIR"; then
      log_error "Failed to extract snapshot."
      exit 1
    fi
  fi

  local extracted_zip
  extracted_zip=$(find "$TEMP_DIR" -name "backupdata-$SERVICE_NAME.zip" -o -name "backupdata-*.zip" 2>/dev/null | head -n 1)

  if [ -z "$extracted_zip" ] || [ ! -f "$extracted_zip" ]; then
    log_error "Bundled backupdata zip not found inside snapshot $SNAPSHOT_FILE_PATH."
    exit 1
  fi

  EXTRACTED_BACKUPDATA_ZIP="$ODOO_TMP_DIR/backupdata-$SERVICE_NAME.zip"
  cp -f "$extracted_zip" "$EXTRACTED_BACKUPDATA_ZIP"
  chown "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$EXTRACTED_BACKUPDATA_ZIP" 2>/dev/null || true
  chmod 644 "$EXTRACTED_BACKUPDATA_ZIP" 2>/dev/null || true
  log_success "Backup bundle extracted and placed at $EXTRACTED_BACKUPDATA_ZIP"

  local restore_args=("$EXTRACTED_BACKUPDATA_ZIP")
  if [ -n "$TARGET_DB_NAME" ]; then
    restore_args+=("-n" "$TARGET_DB_NAME")
  fi

  if [ -f "$PATH_TO_ODOO/scripts/restore_backupdata-$SERVICE_NAME.sh" ]; then
    log_info "Executing $PATH_TO_ODOO/scripts/restore_backupdata-$SERVICE_NAME.sh ${restore_args[*]}..."
    "$PATH_TO_ODOO/scripts/restore_backupdata-$SERVICE_NAME.sh" "${restore_args[@]}"
  elif [ -f "$PATH_TO_ODOO/scripts/restore_backupdata-$SERVICE_NAME" ]; then
    log_info "Executing $PATH_TO_ODOO/scripts/restore_backupdata-$SERVICE_NAME ${restore_args[*]}..."
    "$PATH_TO_ODOO/scripts/restore_backupdata-$SERVICE_NAME" "${restore_args[@]}"
  elif [ -f "$PATH_TO_ODOO/scripts/restore_backupdata_manual-$SERVICE_NAME.sh" ]; then
    log_info "Executing $PATH_TO_ODOO/scripts/restore_backupdata_manual-$SERVICE_NAME.sh ${restore_args[*]}..."
    "$PATH_TO_ODOO/scripts/restore_backupdata_manual-$SERVICE_NAME.sh" "${restore_args[@]}"
  elif [ -f "$PATH_TO_ODOO/scripts/restore_backupdata_manual-$SERVICE_NAME" ]; then
    log_info "Executing $PATH_TO_ODOO/scripts/restore_backupdata_manual-$SERVICE_NAME ${restore_args[*]}..."
    "$PATH_TO_ODOO/scripts/restore_backupdata_manual-$SERVICE_NAME" "${restore_args[@]}"
  elif [ -f "$PATH_TO_ODOO/scripts/restore_backupdata.sh" ]; then
    log_info "Executing $PATH_TO_ODOO/scripts/restore_backupdata.sh ${restore_args[*]}..."
    "$PATH_TO_ODOO/scripts/restore_backupdata.sh" "${restore_args[@]}"
  else
    log_warn "No installed restore_backupdata utility found in scripts/. Running direct data restore..."
    restoreOdooData
  fi

  log_success "Restoration via restore_backupdata completed."
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

  local src_root="$TEMP_DIR"
  if [ -d "$TEMP_DIR/$TAR_PROJECT_ROOT" ]; then
    src_root="$TEMP_DIR/$TAR_PROJECT_ROOT"
  fi

  # Restore bundled non-git directories if present in snapshot
  if [ -d "$src_root/git" ]; then
    log_info "Restoring bundled non-git directories in git/..."
    mkdir -p "$PATH_TO_ODOO/git"
    cp -rn "$src_root/git/." "$PATH_TO_ODOO/git/" 2>/dev/null || true
    chown -R "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$PATH_TO_ODOO/git" 2>/dev/null || true
  fi
  if [ -d "$src_root/odoo-base" ]; then
    log_info "Restoring bundled non-git directories in odoo-base/..."
    mkdir -p "$PATH_TO_ODOO/odoo-base"
    cp -rn "$src_root/odoo-base/." "$PATH_TO_ODOO/odoo-base/" 2>/dev/null || true
    chown -R "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$PATH_TO_ODOO/odoo-base" 2>/dev/null || true
  fi

  # Git metadata display & repository synchronization
  display_git_metadata_summary
  restore_git_repositories

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

  # Path aliases for readability (support direct extraction or legacy root path)
  local src_root="$TEMP_DIR"
  if [ -d "$TEMP_DIR/$TAR_PROJECT_ROOT" ]; then
    src_root="$TEMP_DIR/$TAR_PROJECT_ROOT"
  fi

  log_info "Restoring configuration and environment..."
  [ -f "$src_root/conf/odoo.conf" ] && cp -f "$src_root/conf/odoo.conf" "$PATH_TO_ODOO/conf/odoo.conf"
  [ -f "$src_root/.env" ] && cp -f "$src_root/.env" "$PATH_TO_ODOO/.env"
  [ -f "$src_root/requirements.txt" ] && cp -f "$src_root/requirements.txt" "$PATH_TO_ODOO/requirements.txt"

  chown -R "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$PATH_TO_ODOO/conf/odoo.conf" "$PATH_TO_ODOO/.env" "$PATH_TO_ODOO/requirements.txt" 2>/dev/null

  restoreDBCredentials

  log_info "Stopping services..."
  (cd "$PATH_TO_ODOO" && docker compose down > /dev/null 2>&1)

  # Restore utility scripts
  log_info "Restoring utility scripts..."
  for script in "backupdata-$SERVICE_NAME" "databasecloner-$SERVICE_NAME" "deploy_release_candidate-$SERVICE_NAME" "restore_backupdata-$SERVICE_NAME" "snapshot-$SERVICE_NAME"; do
    if [ -f "$src_root/scripts/$script.sh" ]; then
        cp -f "$src_root/scripts/$script.sh" "$PATH_TO_ODOO/scripts/$script.sh"
        chown "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$PATH_TO_ODOO/scripts/$script.sh"
        chmod 755 "$PATH_TO_ODOO/scripts/$script.sh"
        ln -sf "$PATH_TO_ODOO/scripts/$script.sh" "/usr/local/sbin/$script"
    elif [ -f "$src_root/scripts/$script" ]; then
        cp -f "$src_root/scripts/$script" "$PATH_TO_ODOO/scripts/$script.sh"
        chown "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$PATH_TO_ODOO/scripts/$script.sh"
        chmod 755 "$PATH_TO_ODOO/scripts/$script.sh"
        ln -sf "$PATH_TO_ODOO/scripts/$script.sh" "/usr/local/sbin/$script"
    fi
  done

  # Restore bundled non-git directories if present in snapshot
  if [ -d "$src_root/git" ]; then
    log_info "Restoring bundled non-git directories in git/..."
    mkdir -p "$PATH_TO_ODOO/git"
    cp -rn "$src_root/git/." "$PATH_TO_ODOO/git/" 2>/dev/null || true
    chown -R "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$PATH_TO_ODOO/git" 2>/dev/null || true
  fi
  if [ -d "$src_root/odoo-base" ]; then
    log_info "Restoring bundled non-git directories in odoo-base/..."
    mkdir -p "$PATH_TO_ODOO/odoo-base"
    cp -rn "$src_root/odoo-base/." "$PATH_TO_ODOO/odoo-base/" 2>/dev/null || true
    chown -R "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$PATH_TO_ODOO/odoo-base" 2>/dev/null || true
  fi

  # Git metadata display & repository synchronization
  display_git_metadata_summary
  restore_git_repositories

  # Run setup.sh in auto mode if enabled (provisions OS user 'odoo', datadirs, permissions, builds/pulls image)
  if [ "$RUN_SETUP" = true ] && [ -x "$PATH_TO_ODOO/setup.sh" ]; then
    log_info "Running setup.sh in auto mode to configure environment and build/pull image..."
    if ! "$PATH_TO_ODOO/setup.sh" auto; then
      log_warn "setup.sh completed with warnings. Continuing restoration..."
    fi
  fi

  # Ensure PostgreSQL role and password match .secrets/ (crucial for fresh VPS)
  ensure_postgres_role_configured

  # Restore database and filestore
  restoreOdooData

  # Start Docker compose services and reload registry
  if [ "$START_SERVICES" = true ]; then
    log_info "Starting Docker compose services..."
    if (cd "$PATH_TO_ODOO" && docker compose up -d); then
      log_success "Docker compose services started successfully."
      log_info "Waiting for Odoo container to become ready..."
      local count=0
      while [ $count -lt 30 ]; do
        if docker compose -f "$PATH_TO_ODOO/docker-compose.yml" ps --status running -q odoo 2>/dev/null | grep -q .; then
          break
        fi
        sleep 2
        ((count++))
      done
      sleep 3

      trigger_registry_reload "$ODOO_DATABASE_NAME_PRD" "$PATH_TO_ODOO" 2>/dev/null || true
    else
      log_error "Failed to start docker compose services."
    fi
  fi

  log_success "Restoration complete for $SERVICE_NAME."
}

function main() {
  if [ "$RESTORE_VIA_BACKUPDATA" = true ]; then
    restoreFromSnapshotViaBackupData
  elif [ "$DATA_ONLY" = true ]; then
    restoreSnapshotDataOnly
  else
    restoreSnapshotFull
  fi
}

main "$@"
