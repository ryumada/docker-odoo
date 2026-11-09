#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Restores an Odoo snapshot (full, data-only, or via restore_backupdata) from a tar archive.
# Usage: ./scripts/restore-snapshot.sh [--data-only | --restore-backupdata] [SNAPSHOT_FILE] [-y]
# Dependencies: tar, zstd, docker, sudo, psql

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
# sha256 sidecar helpers (scripts/lib/snapshot_storage.sh)
source "$CURRENT_DIR/lib/snapshot_storage.sh"

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
  verifySnapshotChecksum
}

function verifySnapshotChecksum() {
  # Checks the snapshot against the .sha256 file next to it (next to the real file when
  # SNAPSHOT_FILE_PATH is a symlink such as ~/snapshot-<service>.tar.zst). Runs before
  # anything is dropped, so a damaged snapshot never replaces a working database.
  local real_path sidecar rc=0
  real_path=$(readlink -f "$SNAPSHOT_FILE_PATH")
  sidecar="$real_path.sha256"
  [ -f "$sidecar" ] || sidecar="$SNAPSHOT_FILE_PATH.sha256"
  if [ ! -f "$sidecar" ]; then
    log_warn "No checksum file next to $SNAPSHOT_FILE_PATH (older snapshot?). Restoring without a checksum check."
    return 0
  fi
  log_info "Verifying snapshot checksum ($(basename "$sidecar"))..."
  snap_verify_file "$real_path" "$sidecar" || rc=$?
  case "$rc" in
    0) log_success "Snapshot checksum verified." ;;
    2) log_warn "$(basename "$sidecar") is not a valid checksum file. Restoring without a checksum check." ;;
    *) log_error "CHECKSUM MISMATCH: $SNAPSHOT_FILE_PATH does not match $(basename "$sidecar"). The snapshot is damaged; nothing was restored."
       exit 1 ;;
  esac
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
    PGPASSWORD="$db_pass" docker run -i --rm --network="$net" -e PGPASSWORD postgres psql -h "$db_host" -p "$db_port" -U "$db_user" "${db_default[@]}" "$@"
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
    PGPASSWORD="$db_pass" docker run -i --rm --network="$net" -e PGPASSWORD postgres pg_restore -h "$db_host" -p "$db_port" -U "$db_user" "$@"
  else
    sudo -u postgres pg_restore "$@"
  fi
}

function restoreOdooData() {
  local target_db
  if [ -n "$TARGET_DB_NAME" ]; then
    target_db="$TARGET_DB_NAME"
  else
    target_db=$(grep "^DB_NAME=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
    if [ -z "$target_db" ]; then
      local manifest_file
      manifest_file=$(find "$TEMP_DIR" -maxdepth 4 -name "manifest.json" 2>/dev/null | head -n 1)
      if [ -n "$manifest_file" ] && [ -f "$manifest_file" ]; then
        target_db=$(grep -o '"db_name": *"[^"]*"' "$manifest_file" | cut -d'"' -f4 || true)
      fi
    fi
    [ -z "$target_db" ] && target_db="$SERVICE_NAME"
  fi

  ODOO_DATABASE_NAME_PRD="$target_db"
  ODOO_DATABASE_USER=$(cat "$PATH_TO_ODOO/.secrets/db_user" 2>/dev/null || grep "^ACTIVE_DB_USER=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || echo "odoo")
  [ -z "$ODOO_DATABASE_USER" ] && ODOO_DATABASE_USER="odoo"

  # 1. Discover SQL dump file directly in extracted snapshot
  local sql_dump_file
  sql_dump_file=$(find "$TEMP_DIR" -maxdepth 4 -name "dump.sql" 2>/dev/null | head -n 1)
  [ -z "$sql_dump_file" ] && sql_dump_file=$(find "$TEMP_DIR" -maxdepth 4 -name "*.sql" 2>/dev/null | head -n 1)

  # 2. If direct SQL dump not found, check for legacy nested backupdata zip
  if [ -z "$sql_dump_file" ]; then
    local extracted_zip
    extracted_zip=$(find "$TEMP_DIR" -name "backupdata-$SERVICE_NAME.zip" -o -name "backupdata-*.zip" 2>/dev/null | head -n 1)

    if [ -n "$extracted_zip" ] && [ -f "$extracted_zip" ]; then
      log_info "Found legacy bundled backup data zip: $extracted_zip"
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

      if [ -f "$zip_stage/dump.sql" ]; then
        sql_dump_file="$zip_stage/dump.sql"
      fi

      if [ -d "$zip_stage/filestore" ]; then
        mv "$zip_stage/filestore" "$TEMP_DIR/filestore" 2>/dev/null || true
      fi
    fi
  fi

  if [ -z "$sql_dump_file" ] || [ ! -s "$sql_dump_file" ]; then
    log_error "SQL dump file not found or empty in snapshot ($TEMP_DIR)."
    return 1
  fi

  # pg_dump ends every complete plain dump with this line. Checked before the filestore or the
  # database is touched, so a cut-short snapshot leaves the current deployment as it is.
  local dump_format=plain
  head -c 5 "$sql_dump_file" 2>/dev/null | grep -q "PGDMP" && dump_format=custom
  if [ "$dump_format" = plain ] && ! tail -c 4096 "$sql_dump_file" | grep -q -- "-- PostgreSQL database dump complete"; then
    log_error "$(basename "$sql_dump_file") is incomplete (it does not end with pg_dump's \"dump complete\" line). Nothing was restored."
    return 1
  fi

  # Discover filestore directory
  local filestore_source
  filestore_source=$(find "$TEMP_DIR" -maxdepth 4 -type d -name "filestore" 2>/dev/null | head -n 1)
  if [ -z "$filestore_source" ] && [ -d "$TEMP_DIR/var/lib/odoo/$SERVICE_NAME/filestore" ]; then
    filestore_source="$TEMP_DIR/var/lib/odoo/$SERVICE_NAME/filestore"
  fi

  # Restore filestore if present
  if [ -n "$filestore_source" ] && [ -d "$filestore_source" ]; then
    log_info "Restoring filestore to /var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD..."
    local target_filestore="/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"
    rm -rf "$target_filestore"
    mkdir -p "$(dirname "$target_filestore")"
    if [ -d "$filestore_source/$ODOO_DATABASE_NAME_PRD" ]; then
      mv "$filestore_source/$ODOO_DATABASE_NAME_PRD" "$target_filestore"
    else
      mv "$filestore_source" "$target_filestore"
    fi
    chown -R odoo:odoo "/var/lib/odoo/$SERVICE_NAME" 2>/dev/null || true
  fi

  # Restore database. Nothing is hidden: each step fails with PostgreSQL's own message, and the
  # full log is kept in $ODOO_TMP_DIR when anything went wrong.
  local db="$ODOO_DATABASE_NAME_PRD" restore_log rc=0
  restore_log="$ODOO_TMP_DIR/restore-$db-$(date +%Y%m%d-%H%M%S).log"
  : > "$restore_log"
  log_info "Restoring database $db from $(basename "$sql_dump_file")..."
  recreate_database "$db" "$ODOO_DATABASE_USER" "$restore_log" || return 1

  if [ "$dump_format" = custom ]; then
    log_info "Detected PostgreSQL custom-format dump. Restoring via pg_restore..."
    run_pg_restore --no-owner -d "$db" < "$sql_dump_file" > /dev/null 2>> "$restore_log" || rc=$?
    check_restore_errors "$restore_log" "$rc" pg_restore || return 1
  else
    # Objects are created as the deployment's database user, streamed so the dump is not rewritten on disk
    { printf 'SET ROLE "%s";\n' "$ODOO_DATABASE_USER"; cat "$sql_dump_file"; } \
      | run_psql -X -d "$db" --quiet -t -P pager=off > /dev/null 2>> "$restore_log" || rc=$?
    check_restore_errors "$restore_log" "$rc" psql || return 1
  fi

  # A restore that ran without errors but left no Odoo behind (empty or foreign dump) is not a restore
  local installed
  installed=$(run_psql -X -d "$db" -tA -c "SELECT count(*) FROM ir_module_module WHERE state = 'installed'" 2>> "$restore_log" | tr -d '[:space:]' || true)
  if ! [[ "$installed" =~ ^[0-9]+$ ]] || [ "$installed" -eq 0 ]; then
    log_error "Database $db was restored but has no installed Odoo modules (ir_module_module: '${installed:-missing}'). Full log: $restore_log"
    return 1
  fi

  [ -s "$restore_log" ] || rm -f "$restore_log"
  log_success "Database $db restored successfully ($installed installed modules)."
  return 0
}

function recreate_database() {
  # Args: database owner log_file. Drops the database, closing any open sessions first (a running
  # Odoo in data-only mode keeps it open, and the drop used to fail silently), then creates it.
  local db="$1" owner="$2" log_file="$3" version out
  version=$(run_psql -X -tA -c "SHOW server_version_num" 2>> "$log_file" | tr -d '[:space:]' || true)
  if ! [[ "$version" =~ ^[0-9]+$ ]]; then
    log_error "Can't connect to PostgreSQL to restore $db: $(tail -n 3 "$log_file" | tr '\n' ' ')"
    return 1
  fi
  if [ "$version" -ge 130000 ]; then
    out=$(run_psql -X -q -c "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE)" 2>&1) \
      || { log_error "Can't drop database $db: $out"; return 1; }
  else
    run_psql -X -q -tA -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid()" > /dev/null 2>&1 || true
    out=$(run_psql -X -q -c "DROP DATABASE IF EXISTS \"$db\"" 2>&1) \
      || { log_error "Can't drop database $db (stop Odoo and retry): $out"; return 1; }
  fi
  out=$(run_psql -X -q -c "CREATE DATABASE \"$db\" OWNER \"$owner\"" 2>&1) \
    || { log_error "Can't create database $db: $out"; return 1; }
  return 0
}

# Errors that are normal when a dump made with --no-owner is restored by the deployment's own
# database user rather than a superuser: comments on objects only a superuser owns.
RESTORE_HARMLESS_ERRORS='must be owner of extension|must be owner of schema public'

function check_restore_errors() {
  # Args: log_file exit_code tool (psql | pg_restore). Fails on a bad exit code or on any error
  # that is not one of RESTORE_HARMLESS_ERRORS; harmless ones are reported as a warning.
  local log_file="$1" rc="$2" tool="$3" errors bad harmless
  # psql: "psql:<file>:<line>: ERROR:  ..." (or "ERROR:  ..."); pg_restore: "pg_restore: error: ..."
  errors=$(grep -a -E 'ERROR:|FATAL:|PANIC:|pg_restore: error:' "$log_file" || true)
  bad=$(printf '%s\n' "$errors" | grep -a -vE "$RESTORE_HARMLESS_ERRORS" | sed '/^$/d' || true)
  harmless=$(printf '%s\n' "$errors" | grep -a -cE "$RESTORE_HARMLESS_ERRORS" || true)

  # psql exits 0 even when statements fail (that is what the error lines are for); any other
  # exit is a lost connection or a crash. pg_restore exits 1 when it hit errors, more on failure.
  if [ -n "$bad" ] || { [ "$tool" = psql ] && [ "$rc" -ne 0 ]; } || [ "$rc" -gt 1 ]; then
    log_error "Database restore failed ($tool exit code $rc, $(printf '%s\n' "$bad" | sed '/^$/d' | wc -l) error(s)). First errors:"
    printf '%s\n' "$bad" | sed '/^$/d' | head -n 5 | cut -c1-300 | sed 's/^/    /' >&2
    [ -z "$bad" ] && tail -n 5 "$log_file" | cut -c1-300 | sed 's/^/    /' >&2
    log_error "Full log: $log_file"
    return 1
  fi
  if [ "${harmless:-0}" -gt 0 ]; then
    log_warn "$harmless harmless restore error(s) ignored (objects only a superuser can comment on). Log: $log_file"
  fi
  return 0
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
            note = " [remote was unreachable when the snapshot was taken]" if r.get("remote_check") == "unreachable" else ""
            print(f"  • {r.get(\"name\")} ({r.get(\"relative_path\")}) branch={r.get(\"branch\")} commit={commit_short} remote={r.get(\"remote\")}{note}")
    if bundled:
        print("Bundled Directories (restored from the snapshot itself):")
        for b in bundled:
            if b.get("is_git"):
                commit_short = b.get("commit", "")[:8] if b.get("commit") else "N/A"
                reasons = ", ".join(b.get("bundled_reasons", []))
                print(f"  • {b.get(\"name\")} ({b.get(\"relative_path\")}) git branch={b.get(\"branch\")} commit={commit_short} remote={b.get(\"remote\")} [bundled: {reasons}]")
            else:
                print(f"  • {b.get(\"name\")} ({b.get(\"relative_path\")}) [non-git, bundled directly in snapshot]")
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

function list_bundled_git_repositories() {
  # Prints "<relative_path>\t<commit>\t<reasons>" for git repositories that were bundled
  # into the snapshot because they could not be re-cloned.
  local json_file
  json_file=$(find "$TEMP_DIR" -name "git_hashes*.json" -print 2>/dev/null | head -n 1)
  [ -n "$json_file" ] && [ -f "$json_file" ] || return 0
  python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    for b in data.get("bundled_directories", []):
        if b.get("is_git") and b.get("relative_path"):
            print("{0}\t{1}\t{2}".format(b["relative_path"], b.get("commit", "N/A"), ",".join(b.get("bundled_reasons", []))))
except Exception:
    pass
' "$json_file" 2>/dev/null || true
}

function prepare_bundled_git_targets() {
  # Bundled git repositories are restored by copying them from the snapshot with `cp -rn`
  # (no-clobber). If the target already exists, no-clobber would silently keep the old files,
  # so move the existing directory aside first and let the snapshot copy land in a clean place.
  local src_root="$1"
  local stamp
  stamp=$(date +"%Y%m%d-%H%M%S")
  while IFS=$'\t' read -r rel_path commit reasons; do
    [ -n "$rel_path" ] || continue
    [ -d "$src_root/$rel_path" ] || continue
    local target_dir="$PATH_TO_ODOO/$rel_path"
    if [ -e "$target_dir" ]; then
      # Kept outside git/ and odoo-base/ so it is never scanned by the next snapshot or put on the addons path
      local backup_dir="$PATH_TO_ODOO/.pre-restore-backups/$stamp/$rel_path"
      mkdir -p "$(dirname "$backup_dir")"
      if mv "$target_dir" "$backup_dir"; then
        log_warn "Existing $rel_path moved to .pre-restore-backups/$stamp/$rel_path so the bundled copy from the snapshot (commit ${commit:0:8}) can be restored. Delete it once you've checked nothing in it is needed."
      else
        log_error "Could not move existing $rel_path aside. The bundled copy may be merged with old files."
      fi
    fi
  done < <(list_bundled_git_repositories)
}

function verify_bundled_git_repositories() {
  # Confirm each bundled git repository landed at the commit recorded in the snapshot.
  local src_root="$1"
  while IFS=$'\t' read -r rel_path commit reasons; do
    [ -n "$rel_path" ] || continue
    [ -d "$src_root/$rel_path" ] || continue
    local target_dir="$PATH_TO_ODOO/$rel_path"
    if [ ! -d "$target_dir" ]; then
      log_error "Bundled repository $rel_path was not restored."
      continue
    fi
    local head
    head=$(sudo -u "$REPOSITORY_OWNER" git -C "$target_dir" rev-parse HEAD 2>/dev/null || true)
    if [ -z "$head" ]; then
      log_warn "Bundled repository $rel_path restored as files only (no usable git metadata, e.g. a worktree). Recorded commit: ${commit:0:8}."
    elif [ "$head" = "$commit" ]; then
      log_success "Bundled repository $rel_path restored at commit ${commit:0:8} (bundled because: $reasons)."
    else
      log_warn "Bundled repository $rel_path is at ${head:0:8}, but the snapshot recorded ${commit:0:8}."
    fi
  done < <(list_bundled_git_repositories)
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
    bundled = {b.get("relative_path") for b in data.get("bundled_directories", [])}
    for r in data.get("git_repositories", []):
        if r.get("relative_path") in bundled:
            continue
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

  local restore_script=""
  if [ -f "$PATH_TO_ODOO/scripts/restore_backupdata_manual-$SERVICE_NAME.sh" ]; then
    restore_script="$PATH_TO_ODOO/scripts/restore_backupdata_manual-$SERVICE_NAME.sh"
  elif [ -f "$PATH_TO_ODOO/scripts/restore_backupdata_manual-$SERVICE_NAME" ]; then
    restore_script="$PATH_TO_ODOO/scripts/restore_backupdata_manual-$SERVICE_NAME"
  elif [ -f "$PATH_TO_ODOO/scripts/restore_backupdata-$SERVICE_NAME.sh" ]; then
    restore_script="$PATH_TO_ODOO/scripts/restore_backupdata-$SERVICE_NAME.sh"
  elif [ -f "$PATH_TO_ODOO/scripts/restore_backupdata-$SERVICE_NAME" ]; then
    restore_script="$PATH_TO_ODOO/scripts/restore_backupdata-$SERVICE_NAME"
  elif [ -f "$PATH_TO_ODOO/scripts/restore_backupdata.sh" ]; then
    restore_script="$PATH_TO_ODOO/scripts/restore_backupdata.sh"
  fi

  if [ -n "$restore_script" ]; then
    local restore_args=("$SNAPSHOT_FILE_PATH")
    if [ -n "$TARGET_DB_NAME" ]; then
      restore_args+=("-n" "$TARGET_DB_NAME")
    fi
    log_info "Executing $restore_script ${restore_args[*]}..."
    "$restore_script" "${restore_args[@]}"
    log_success "Restoration via restore_backupdata completed."
    return 0
  fi

  log_warn "No installed restore_backupdata utility found in scripts/. Running direct data restore..."
  rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
  if ! tar -xaf "$SNAPSHOT_FILE_PATH" -C "$TEMP_DIR"; then
    log_error "Failed to extract snapshot."
    exit 1
  fi
  restoreOdooData
  log_success "Restoration via direct data restore completed."
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

  # Move existing copies of bundled git repositories aside so cp -rn restores the snapshot's version
  prepare_bundled_git_targets "$src_root"

  # Restore bundled directories (non-git, and git repositories that could not be re-cloned)
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
  verify_bundled_git_repositories "$src_root"

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

  # Move existing copies of bundled git repositories aside so cp -rn restores the snapshot's version
  prepare_bundled_git_targets "$src_root"

  # Restore bundled directories (non-git, and git repositories that could not be re-cloned)
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
  verify_bundled_git_repositories "$src_root"

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
