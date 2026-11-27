#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Backs up Odoo databases to a temporary directory.
# Usage: ./scripts/dataodoo-backupper.sh
# Dependencies: curl, git, sudo, 7z

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

ODOO_FILESTORE_PATH="/var/lib/odoo/$SERVICE_NAME/filestore"
temporary_directory=""
REMOTE_STAGING_DIR=""
REMOTE_SSH_OPTS=()
REMOTE_TARGET=""

read_env_val() {
  local key="$1"
  local file="${2:-$PATH_TO_ODOO/.env}"
  [ -f "$file" ] || return 0
  grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1 | cut -d '=' -f 2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true
}

# --- Centralized Cleanup Hook ---
cleanup_all() {
    local exit_code=$?
    if declare -F queue_lock_release_all >/dev/null 2>&1; then
        queue_lock_release_all
    fi
    if [ -n "$REMOTE_TARGET" ] && [ -n "$REMOTE_STAGING_DIR" ]; then
        ssh "${REMOTE_SSH_OPTS[@]}" "$REMOTE_TARGET" "rm -rf $(printf '%q' "$REMOTE_STAGING_DIR")" >/dev/null 2>&1 || true
    fi
    if [ "$exit_code" -ne 0 ]; then
        if [ -n "$temporary_directory" ] && [ -d "$temporary_directory" ]; then
            rm -rf "$temporary_directory"
        fi
    fi
}
trap cleanup_all EXIT

function run_pg_dump() {
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
    PGPASSWORD="$db_pass" docker run -i --rm --network="$net" -e PGPASSWORD postgres pg_dump -h "$db_host" -p "$db_port" -U "$db_user" "$@"
  else
    sudo -u postgres pg_dump "$@"
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

function generate_manifest() {
  local db_name="$1"
  local target_file="${2:-}"

  log_info "Gathering exact metadata for manifest.json..." >&2

  local MANIFEST_SQL="
    WITH installed_modules AS (
        SELECT json_object_agg(name, latest_version) as modules
        FROM ir_module_module
        WHERE state = 'installed'
    ),
    pg_v AS (
        SELECT setting FROM pg_settings WHERE name = 'server_version_num'
    )
    SELECT json_build_object(
        'odoo_dump', '1',
        'db_name', '$db_name',
        'version', split_part(latest_version, '.', 1) || '.' || split_part(latest_version, '.', 2),
        'major_version', split_part(latest_version, '.', 1),
        'pg_version', (SELECT floor(setting::int / 10000) || '.' || floor((setting::int % 10000) / 100) FROM pg_v),
        'modules', (SELECT modules FROM installed_modules),
        'version_info', json_build_array(
            split_part(latest_version, '.', 1)::int,
            split_part(latest_version, '.', 2)::int,
            0, 'final', 0, ''
        )
    ) FROM ir_module_module WHERE name = 'base';
  "

  local manifest_out
  if ! manifest_out=$(run_psql -d "$db_name" -t -A -c "$MANIFEST_SQL" 2>/dev/null) || [ -z "$manifest_out" ]; then
    log_warn "Could not query database for manifest. Falling back to the Odoo version in release.py or .env." >&2
    local MANIFEST_VERSION="" MANIFEST_MAJOR_VERSION="" MANIFEST_VERSION_INFO="null"
    if ! declare -F odoo_version_detect >/dev/null && [ -f "$PATH_TO_ODOO/scripts/lib/odoo_version.sh" ]; then
      # shellcheck source=/dev/null
      source "$PATH_TO_ODOO/scripts/lib/odoo_version.sh"
    fi
    if declare -F odoo_version_detect >/dev/null; then
      odoo_version_detect "$PATH_TO_ODOO"
    else
      log_warn "scripts/lib/odoo_version.sh not found (update docker-odoo and re-run ./setup.sh); manifest.json will have no Odoo version." >&2
    fi
    manifest_out=$(cat <<EOF
{
    "odoo_dump": "1",
    "db_name": "$db_name",
    "version": "$MANIFEST_VERSION",
    "version_info": $MANIFEST_VERSION_INFO,
    "major_version": "$MANIFEST_MAJOR_VERSION",
    "modules": {}
}
EOF
)
  fi

  if [ -n "$target_file" ]; then
    printf '%s\n' "$manifest_out" > "$target_file"
  else
    printf '%s\n' "$manifest_out"
  fi
}

function isZipInstalled() {
  if ! command -v 7z &>/dev/null && ! command -v 7za &>/dev/null; then
    log_error "7z command could not be found. Please install 7zip / p7zip-full first."
    echo "For Ubuntu: sudo apt install 7zip || sudo apt install p7zip-full"
    echo "For CentOS: sudo yum install p7zip p7zip-plugins"
    exit 1
  fi
}

function isCurlInstalled() {
  if ! command -v curl &>/dev/null; then
    log_error "curl is not installed. Please install curl."
    echo "Ubuntu: sudo apt install curl"
    echo "CentOS: sudo yum install curl"
    exit 1
  fi
}

function areYouReallySure() {
  prompt=$1

  echo "Are you sure want to backup odoo datas on $SERVICE_NAME deployment?"
  echo -e "Type '$prompt'\n"
  read -r -p ": " RESPONSE

  if [ "$RESPONSE" != "$prompt" ]; then
    log_error "You don't write the correct phrase. Exiting..."
    log_info "Backup aborted."
    exit 1
  fi
}

function whichData() {
  local DB_LIST

  read -rp "Enter the name of Odoo Database(s) you want to backup (Enter multiple database with comma [,]): " DB_LIST

  if [ -z "$DB_LIST" ]; then
    echo "No database name entered. Exiting..."
    exit 1
  fi

  echo "$DB_LIST"
}

function checkOdooEndpoint() {
  log_info "Checking if Odoo endpoint is accessible on port $PORT..."
  if curl --output /dev/null --silent --head --fail "http://localhost:$PORT"; then
    log_success "Odoo endpoint is accessible."
  else
    log_warn "Odoo endpoint is NOT accessible at http://localhost:$PORT. Retrying with longer timeout..."
    if curl --output /dev/null --silent --head --fail --connect-timeout 10 "http://localhost:$PORT"; then
      log_success "Odoo endpoint is accessible."
    else
      log_error "Odoo endpoint is NOT accessible at http://localhost:$PORT. Please check if the service is running."
      exit 1
    fi
  fi
}

function main() {
  # Self-elevate to root if not already
  if [ "$(id -u)" -ne 0 ]; then
      log_info "Elevating permissions to root..."
      # shellcheck disable=SC2093
      exec sudo "$0" "$@"
      log_error "Failed to elevate to root. Please run with sudo." # This will only run if exec fails
      exit 1
  fi

  BACKUP_RESTORE_METHOD=$(read_env_val "BACKUP_RESTORE_METHOD")
  if [ -z "$BACKUP_RESTORE_METHOD" ]; then
    BACKUP_RESTORE_METHOD="manual"
  fi
  SNAPSHOT_REMOTE_HOST=$(read_env_val "SNAPSHOT_REMOTE_HOST")

  if [ "$BACKUP_RESTORE_METHOD" = "endpoint" ]; then
    isCurlInstalled
  elif [ -z "$SNAPSHOT_REMOTE_HOST" ]; then
    isZipInstalled
  fi

  areYouReallySure "yes"

  DB_LIST="$(whichData)"

  ADMIN_PASSWD=$(read_env_val "ADMIN_PASSWD")
  PORT=$(read_env_val "PORT")

  if [ "$BACKUP_RESTORE_METHOD" = "endpoint" ]; then
    if [ -z "$ADMIN_PASSWD" ] || [ -z "$PORT" ]; then
      log_error "ADMIN_PASSWD and/or PORT not set in .env file. Cannot proceed with backup."
      exit 1
    fi
    checkOdooEndpoint
  fi

  # Shared queue lock (odoo-backup-system): coordinate I/O & mirror/filestore with snapshot.sh
  local SNAPSHOT_QUEUE_NAME="odoo-backup-system"
  local DEFAULT_SNAPSHOT_QUEUE_TIMEOUT=43200
  local SNAPSHOT_QUEUE_TIMEOUT
  SNAPSHOT_QUEUE_TIMEOUT=$(read_env_val "SNAPSHOT_QUEUE_TIMEOUT")
  if ! [[ "$SNAPSHOT_QUEUE_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$SNAPSHOT_QUEUE_TIMEOUT" -le 0 ]; then
    SNAPSHOT_QUEUE_TIMEOUT="$DEFAULT_SNAPSHOT_QUEUE_TIMEOUT"
  fi
  local SNAPSHOT_QUEUE_POLL_INTERVAL SNAPSHOT_QUEUE_STALE_AFTER
  SNAPSHOT_QUEUE_POLL_INTERVAL=$(read_env_val "SNAPSHOT_QUEUE_POLL_INTERVAL")
  [[ "$SNAPSHOT_QUEUE_POLL_INTERVAL" =~ ^[0-9]+$ ]] && [ "$SNAPSHOT_QUEUE_POLL_INTERVAL" -gt 0 ] || SNAPSHOT_QUEUE_POLL_INTERVAL=60
  SNAPSHOT_QUEUE_STALE_AFTER=$(read_env_val "SNAPSHOT_QUEUE_STALE_AFTER")
  [[ "$SNAPSHOT_QUEUE_STALE_AFTER" =~ ^[0-9]+$ ]] && [ "$SNAPSHOT_QUEUE_STALE_AFTER" -gt 0 ] || SNAPSHOT_QUEUE_STALE_AFTER=600

  local QUEUE_LOCK_LIB=""
  if [ -f "$CURRENT_DIR/lib/queue_lock.sh" ]; then
    QUEUE_LOCK_LIB="$CURRENT_DIR/lib/queue_lock.sh"
  elif [ -f "$PATH_TO_ODOO/scripts/lib/queue_lock.sh" ]; then
    QUEUE_LOCK_LIB="$PATH_TO_ODOO/scripts/lib/queue_lock.sh"
  fi
  if [ -n "$QUEUE_LOCK_LIB" ]; then
    # shellcheck source=/dev/null
    source "$QUEUE_LOCK_LIB"
    QUEUE_LOCK_POLL_INTERVAL="$SNAPSHOT_QUEUE_POLL_INTERVAL"
    QUEUE_LOCK_STALE_AFTER="$SNAPSHOT_QUEUE_STALE_AFTER"
    QUEUE_LOCK_LEGACY_STALE_AFTER="$SNAPSHOT_QUEUE_TIMEOUT"
    if ! queue_lock_acquire_local "$SNAPSHOT_QUEUE_NAME" "$SERVICE_NAME" \
        "$SERVICE_NAME (dataodoo-backupper on $(hostname -s 2>/dev/null || hostname))" "$SNAPSHOT_QUEUE_TIMEOUT"; then
      exit 1
    fi
  fi

  if command -v ionice >/dev/null 2>&1; then
    ionice -c2 -n7 -p $$ 2>/dev/null || true
  fi
  renice -n 19 -p $$ >/dev/null 2>&1 || true

  local TARGET_OWNER="${SUDO_USER:-$REPOSITORY_OWNER}"
  local OWNER_HOME
  OWNER_HOME=$(getent passwd "$TARGET_OWNER" 2>/dev/null | cut -d: -f6 || true)
  if [ -z "$OWNER_HOME" ] || [ ! -d "$OWNER_HOME" ]; then
    OWNER_HOME=$(getent passwd "$REPOSITORY_OWNER" 2>/dev/null | cut -d: -f6 || true)
  fi
  local LOCAL_HOSTNAME
  LOCAL_HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "localhost")
  local TIMESTAMP
  TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

  # --- Branch 1: Manual mode offloaded to Secondary VPS (SNAPSHOT_REMOTE_HOST) ---
  if [ "$BACKUP_RESTORE_METHOD" != "endpoint" ] && [ -n "$SNAPSHOT_REMOTE_HOST" ]; then
    local SNAPSHOT_REMOTE_USER SNAPSHOT_REMOTE_PORT SNAPSHOT_REMOTE_KEY
    SNAPSHOT_REMOTE_USER=$(read_env_val "SNAPSHOT_REMOTE_USER")
    SNAPSHOT_REMOTE_PORT=$(read_env_val "SNAPSHOT_REMOTE_PORT")
    SNAPSHOT_REMOTE_KEY=$(read_env_val "SNAPSHOT_REMOTE_KEY")
    [ -z "$SNAPSHOT_REMOTE_PORT" ] && SNAPSHOT_REMOTE_PORT="22"
    if [ -z "$SNAPSHOT_REMOTE_USER" ]; then
      log_error "SNAPSHOT_REMOTE_USER is required when SNAPSHOT_REMOTE_HOST is set in .env!"
      exit 1
    fi

    local KEY_HOME="${OWNER_HOME:-$HOME}"
    if [ -z "$SNAPSHOT_REMOTE_KEY" ] && [ -n "$KEY_HOME" ]; then
      local THIS_VPS CLEAN_TGT
      THIS_VPS=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "vps-source")
      CLEAN_TGT=$(echo "$SNAPSHOT_REMOTE_HOST" | sed -e 's|^.*://||' -e 's|^.*@||' -e 's|:.*$||' -e 's|/.*$||' -e 's|[^a-zA-Z0-9._-]|_|g')
      if [ -f "$KEY_HOME/.ssh/snapshot-${THIS_VPS}-${CLEAN_TGT}" ]; then
        SNAPSHOT_REMOTE_KEY="$KEY_HOME/.ssh/snapshot-${THIS_VPS}-${CLEAN_TGT}"
      elif [ -f "$KEY_HOME/.ssh/id_ed25519-snapshot-$SERVICE_NAME" ]; then
        SNAPSHOT_REMOTE_KEY="$KEY_HOME/.ssh/id_ed25519-snapshot-$SERVICE_NAME"
      elif [ -f "$KEY_HOME/.ssh/id_ed25519_snapshot" ]; then
        SNAPSHOT_REMOTE_KEY="$KEY_HOME/.ssh/id_ed25519_snapshot"
      fi
    elif [ -n "$SNAPSHOT_REMOTE_KEY" ] && [ -n "$KEY_HOME" ]; then
      SNAPSHOT_REMOTE_KEY="${SNAPSHOT_REMOTE_KEY/#\~/$KEY_HOME}"
    fi

    local SSH_OPTS=(-p "$SNAPSHOT_REMOTE_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=5)
    [ -n "$SNAPSHOT_REMOTE_KEY" ] && [ -f "$SNAPSHOT_REMOTE_KEY" ] && SSH_OPTS+=(-i "$SNAPSHOT_REMOTE_KEY")
    REMOTE_SSH_OPTS=("${SSH_OPTS[@]}")
    REMOTE_TARGET="$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST"
    local RSYNC_SSH="ssh"
    for _opt in "${SSH_OPTS[@]}"; do
      RSYNC_SSH+=" $(printf '%q' "$_opt")"
    done

    bk_remote_exec() {
      ssh "${SSH_OPTS[@]}" "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST" "$@"
    }

    log_info "Connecting to Secondary VPS ($SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST:$SNAPSHOT_REMOTE_PORT)..."
    if ! bk_remote_exec "true" 2>/dev/null; then
      log_error "Failed to establish SSH connection with Secondary VPS ($SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST:$SNAPSHOT_REMOTE_PORT)."
      exit 1
    fi

    if declare -F queue_lock_acquire_remote >/dev/null 2>&1; then
      if ! queue_lock_acquire_remote "$SNAPSHOT_QUEUE_NAME" "$SERVICE_NAME" \
          "$SERVICE_NAME (dataodoo-backupper from $(hostname -s 2>/dev/null || hostname))" "$SNAPSHOT_QUEUE_TIMEOUT" bk_remote_exec; then
        exit 1
      fi
    fi

    local REMOTE_ZIP_CMD REMOTE_HOME REMOTE_HOSTNAME
    REMOTE_ZIP_CMD=$(bk_remote_exec "command -v 7z 2>/dev/null || command -v 7za 2>/dev/null || true" | tr -d '\r\n')
    if [ -z "$REMOTE_ZIP_CMD" ]; then
      log_error "7z/7za is not installed on Secondary VPS ($SNAPSHOT_REMOTE_HOST)."
      exit 1
    fi
    REMOTE_HOME=$(bk_remote_exec 'echo "$HOME"' 2>/dev/null | tr -d '\r\n' || true)
    if [ -z "$REMOTE_HOME" ]; then
      log_error "Could not determine HOME directory on Secondary VPS."
      exit 1
    fi
    REMOTE_HOSTNAME=$(bk_remote_exec 'hostname -f 2>/dev/null || hostname' 2>/dev/null | tr -d '\r\n' || echo "$SNAPSHOT_REMOTE_HOST")

    local REMOTE_BASE="$REMOTE_HOME/.odoo-snapshots/$SERVICE_NAME"
    local REMOTE_MIRROR="$REMOTE_BASE/mirror/filestore"
    local REMOTE_OUT_DIR="$REMOTE_HOME/${SERVICE_NAME}-${TIMESTAMP}-dataodoo-backupper"
    REMOTE_STAGING_DIR="$REMOTE_BASE/backupper_staging_$$"
    local ENV_DB_NAME
    ENV_DB_NAME=$(read_env_val "DB_NAME")

    bk_remote_exec "mkdir -p $(printf '%q' "$REMOTE_MIRROR") $(printf '%q' "$REMOTE_OUT_DIR") $(printf '%q' "$REMOTE_STAGING_DIR") && chmod 700 $(printf '%q' "$REMOTE_HOME/.odoo-snapshots")"

    for DB in $(echo "$DB_LIST" | tr "," "\n"); do
      log_info "Backing up Odoo Database '$DB' via Secondary VPS ($REMOTE_HOSTNAME)..."
      local REMOTE_ZIP_PATH="$REMOTE_OUT_DIR/${DB}.zip"
      bk_remote_exec "rm -rf $(printf '%q' "$REMOTE_STAGING_DIR")/* && mkdir -p $(printf '%q' "$REMOTE_STAGING_DIR")"

      log_info "Streaming pg_dump of '$DB' directly to Secondary VPS..."
      if ! run_pg_dump --no-owner "$DB" | bk_remote_exec "cat > $(printf '%q' "$REMOTE_STAGING_DIR/dump.sql")"; then
        log_error "pg_dump stream to Secondary VPS failed for database '$DB'."
        exit 1
      fi

      generate_manifest "$DB" | bk_remote_exec "cat > $(printf '%q' "$REMOTE_STAGING_DIR/manifest.json")"

      local HASH_SRC=""
      if [ -f "$PATH_TO_ODOO/git/git_hashes.txt" ]; then
        HASH_SRC="$PATH_TO_ODOO/git/git_hashes.txt"
      elif [ -f "$PATH_TO_ODOO/odoo-base/git_hashes.txt" ]; then
        HASH_SRC="$PATH_TO_ODOO/odoo-base/git_hashes.txt"
      fi
      if [ -n "$HASH_SRC" ]; then
        rsync -e "$RSYNC_SSH" -az "$HASH_SRC" "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST:$REMOTE_STAGING_DIR/git_hashes.txt"
      fi

      local odoo_filestore_path="$ODOO_FILESTORE_PATH/$DB"
      if [ -d "$odoo_filestore_path" ]; then
        if [ -z "$ENV_DB_NAME" ] || [ "$DB" = "$ENV_DB_NAME" ]; then
          log_info "Syncing filestore incrementally to Secondary VPS snapshot mirror ($REMOTE_MIRROR)..."
          rsync -e "$RSYNC_SSH" -az --delete "$odoo_filestore_path/" "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST:$REMOTE_MIRROR/"
          bk_remote_exec "cp -al $(printf '%q' "$REMOTE_MIRROR") $(printf '%q' "$REMOTE_STAGING_DIR/filestore") 2>/dev/null || cp -r $(printf '%q' "$REMOTE_MIRROR") $(printf '%q' "$REMOTE_STAGING_DIR/filestore")"
        else
          log_info "Syncing non-active DB '$DB' filestore to Secondary VPS staging..."
          rsync -e "$RSYNC_SSH" -az "$odoo_filestore_path/" "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST:$REMOTE_STAGING_DIR/filestore/"
        fi
      else
        log_warn "Filestore not found at $odoo_filestore_path. Skipping filestore."
      fi

      log_info "Compressing $DB.zip on Secondary VPS ($REMOTE_HOSTNAME)..."
      if ! bk_remote_exec "
        set -e
        if command -v ionice >/dev/null 2>&1; then ionice -c2 -n7 -p \$\$ 2>/dev/null || true; fi
        renice -n 19 -p \$\$ >/dev/null 2>&1 || true
        cd $(printf '%q' "$REMOTE_STAGING_DIR")
        meta=(dump.sql manifest.json)
        [ -f git_hashes.txt ] && meta+=(git_hashes.txt)
        $(printf '%q' "$REMOTE_ZIP_CMD") a -tzip -mmt=on $(printf '%q' "$REMOTE_ZIP_PATH") \"\${meta[@]}\" >/dev/null
        if [ -d filestore ]; then
          $(printf '%q' "$REMOTE_ZIP_CMD") a -tzip -mx=0 $(printf '%q' "$REMOTE_ZIP_PATH") filestore >/dev/null
        fi
        rm -rf $(printf '%q' "$REMOTE_STAGING_DIR")/*
      "; then
        log_error "Failed to create backup ZIP archive on Secondary VPS for '$DB'."
        exit 1
      fi
      log_success "Backup for '$DB' saved on Secondary VPS ($REMOTE_HOSTNAME): $REMOTE_ZIP_PATH"
    done

    bk_remote_exec "rm -rf $(printf '%q' "$REMOTE_STAGING_DIR")" >/dev/null 2>&1 || true
    REMOTE_STAGING_DIR=""
    log_success "All backup operations are complete."
    log_info "Retrieve your backup file(s) from Secondary VPS '$REMOTE_HOSTNAME' ($SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST) at: $REMOTE_OUT_DIR"
    return 0
  fi

  # --- Branch 2: Local Mode (endpoint mode or manual mode without SNAPSHOT_REMOTE_HOST) ---
  if [ -n "$OWNER_HOME" ] && [ -d "$OWNER_HOME" ]; then
    temporary_directory="$OWNER_HOME/${SERVICE_NAME}-${TIMESTAMP}-dataodoo-backupper"
  else
    temporary_directory="/tmp/${SERVICE_NAME}-${TIMESTAMP}-dataodoo-backupper"
  fi
  if mkdir -p "$temporary_directory"; then
    log_success "Created backup directory on '$LOCAL_HOSTNAME': $temporary_directory"
  else
    log_error "Error creating backup directory: $temporary_directory"
    exit 1
  fi

  for DB in $(echo "$DB_LIST" | tr "," "\n"); do
    log_info "Backing up Odoo Database: $DB"
    BACKUP_FILE_PATH="$temporary_directory/$DB.zip"

    if [ "$BACKUP_RESTORE_METHOD" != "endpoint" ]; then
      local odoo_filestore_path="$ODOO_FILESTORE_PATH/$DB"
      local db_temp_dir
      db_temp_dir=$(mktemp -d -t "backupdata_${DB}_XXXXXX")

      log_info "Backup database $DB using pg_dump..."
      if ! run_pg_dump --no-owner "$DB" > "$db_temp_dir/dump.sql"; then
        log_error "pg_dump failed to dump database '$DB'"
        rm -rf "$db_temp_dir"
        exit 1
      fi

      generate_manifest "$DB" "$db_temp_dir/manifest.json"

      log_info "Hardlinking filestore..."
      if [ -d "$odoo_filestore_path" ]; then
        cp -al "$odoo_filestore_path" "$db_temp_dir/filestore" 2>/dev/null || cp -r "$odoo_filestore_path" "$db_temp_dir/filestore"
      else
        log_warn "Filestore not found at $odoo_filestore_path. Skipping filestore."
      fi

      if [ -f "$PATH_TO_ODOO/git/git_hashes.txt" ]; then
        cp "$PATH_TO_ODOO/git/git_hashes.txt" "$db_temp_dir/git_hashes.txt"
      fi

      if [ -f "$PATH_TO_ODOO/odoo-base/git_hashes.txt" ]; then
        cp "$PATH_TO_ODOO/odoo-base/git_hashes.txt" "$db_temp_dir/git_hashes.txt"
      fi

      local zip_cmd="7z"
      command -v 7z &>/dev/null || zip_cmd="7za"

      local meta_files=("dump.sql" "manifest.json")
      [ -f "$db_temp_dir/git_hashes.txt" ] && meta_files+=("git_hashes.txt")

      log_info "Compressing database dump and metadata into $BACKUP_FILE_PATH with $zip_cmd (multi-threaded)..."
      if ! (cd "$db_temp_dir" && "$zip_cmd" a -tzip -mmt=on "$BACKUP_FILE_PATH" "${meta_files[@]}" >/dev/null); then
        log_error "Failed to create backup ZIP archive."
        rm -rf "$db_temp_dir"
        exit 1
      fi

      if [ -d "$db_temp_dir/filestore" ]; then
        log_info "Packaging filestore (store-only mode for maximum speed)..."
        if ! (cd "$db_temp_dir" && "$zip_cmd" a -tzip -mx=0 "$BACKUP_FILE_PATH" filestore >/dev/null); then
          log_error "Failed to package filestore into backup ZIP archive."
          rm -rf "$db_temp_dir"
          exit 1
        fi
      fi

      rm -rf "$db_temp_dir"
      log_success "Backup for '$DB' completed on '$LOCAL_HOSTNAME': $BACKUP_FILE_PATH"
    else
      printf '%s' "$ADMIN_PASSWD" | curl -s -X POST \
        -F "master_pwd=<-" \
        -F "name=$DB" \
        -F "backup_format=zip" \
        -o "$BACKUP_FILE_PATH" \
        "http://localhost:$PORT/web/database/backup"

      if [ -s "$BACKUP_FILE_PATH" ]; then
        log_success "Odoo Database '$DB' has been backed up on '$LOCAL_HOSTNAME' to: $BACKUP_FILE_PATH"
      else
        log_error "Backup failed for database '$DB'. The output file is empty. Check Odoo logs."
        rm -f "$BACKUP_FILE_PATH"
      fi
    fi
  done

  if [ -n "$TARGET_OWNER" ] && id "$TARGET_OWNER" >/dev/null 2>&1; then
    chown -R "$TARGET_OWNER":"$TARGET_OWNER" "$temporary_directory"
  fi

  log_success "All backup operations are complete on VPS '$LOCAL_HOSTNAME'. Files are located in: $temporary_directory"
}

main "$@"
