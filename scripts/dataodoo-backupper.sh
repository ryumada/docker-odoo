#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Backs up Odoo databases to a temporary directory.
# Usage: ./scripts/dataodoo-backupper.sh
# Dependencies: curl, git, sudo

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

# --- Centralized Cleanup Hook ---
cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        if [ -n "$temporary_directory" ] && [ -d "$temporary_directory" ]; then
            rm -rf "$temporary_directory"
        fi
    fi
}
trap cleanup_on_error EXIT

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
    docker run -i --rm --network="$net" -e PGPASSWORD="$db_pass" postgres pg_dump -h "$db_host" -p "$db_port" -U "$db_user" "$@"
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
    docker run -i --rm --network="$net" -e PGPASSWORD="$db_pass" postgres psql -h "$db_host" -p "$db_port" -U "$db_user" "${db_default[@]}" "$@"
  else
    sudo -u postgres psql "${db_default[@]}" "$@"
  fi
}

function generate_manifest() {
  local db_name="$1"
  local target_file="$2"

  log_info "Gathering exact metadata for manifest.json..."

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

  if ! run_psql -d "$db_name" -t -A -c "$MANIFEST_SQL" > "$target_file" 2>/dev/null; then
    log_warn "Could not query database for manifest. Falling back to basic manifest."
    cat <<EOF > "$target_file"
{
    "odoo_dump": "1",
    "db_name": "$db_name",
    "version": "16.0",
    "version_info": [16, 0, 0, "final", 0, ""],
    "major_version": "16",
    "modules": {}
}
EOF
  fi
}

function isZipInstalled() {
  if ! command -v zip &>/dev/null; then
    log_error "zip command could not be found. Please install zip first."
    echo "For Ubuntu: sudo apt install zip"
    echo "For CentOS: sudo yum install zip"
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

  BACKUP_RESTORE_METHOD=$(grep "^BACKUP_RESTORE_METHOD=" "$PATH_TO_ODOO/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)

  if [ "$BACKUP_RESTORE_METHOD" = "manual" ] || [ "$BACKUP_RESTORE_METHOD" = "semi_manual" ]; then
    isZipInstalled
  else
    isCurlInstalled
  fi

  areYouReallySure "yes"

  DB_LIST="$(whichData)"

  ADMIN_PASSWD=$(grep "^ADMIN_PASSWD=" "$PATH_TO_ODOO/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
  PORT=$(grep "^PORT=" "$PATH_TO_ODOO/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)

  if [ "$BACKUP_RESTORE_METHOD" != "manual" ] && [ "$BACKUP_RESTORE_METHOD" != "semi_manual" ]; then
    if [ -z "$ADMIN_PASSWD" ] || [ -z "$PORT" ]; then
      log_error "ADMIN_PASSWD and/or PORT not set in .env file. Cannot proceed with backup."
      exit 1
    fi
    checkOdooEndpoint
  fi

  temporary_directory="/tmp/$(date +"%Y%m%d-%H%M%S")-dataodoo-backupper"
  if mkdir -p "$temporary_directory"; then
    log_success "Created temporary directory: $temporary_directory"
  else
    log_error "Error creating temporary directory: $temporary_directory"
    exit 1
  fi

  for DB in $(echo "$DB_LIST" | tr "," "\n"); do
    log_info "Backing up Odoo Database: $DB"
    BACKUP_FILE_PATH="$temporary_directory/$DB.zip"

    if [ "$BACKUP_RESTORE_METHOD" = "manual" ] || [ "$BACKUP_RESTORE_METHOD" = "semi_manual" ]; then
      local odoo_filestore_path="/var/lib/odoo/$SERVICE_NAME/filestore/$DB"
      local db_temp_dir
      db_temp_dir=$(mktemp -d -t "backupdata_${DB}_XXXXXX")

      log_info "Backup database $DB using pg_dump..."
      if ! run_pg_dump --no-owner "$DB" > "$db_temp_dir/dump.sql"; then
        log_error "pg_dump failed to dump database '$DB'"
        rm -rf "$db_temp_dir"
        exit 1
      fi

      generate_manifest "$DB" "$db_temp_dir/manifest.json"

      log_info "Copying filestore files..."
      if [ -d "$odoo_filestore_path" ]; then
        mkdir -p "$db_temp_dir/filestore"
        cp -r "$odoo_filestore_path/." "$db_temp_dir/filestore/"
      else
        log_warn "Filestore not found at $odoo_filestore_path. Skipping filestore."
      fi

      if [ -f "$PATH_TO_ODOO/git/git_hashes.txt" ]; then
        cp "$PATH_TO_ODOO/git/git_hashes.txt" "$db_temp_dir/git_hashes.txt"
      fi

      if [ -f "$PATH_TO_ODOO/odoo-base/git_hashes.txt" ]; then
        cp "$PATH_TO_ODOO/odoo-base/git_hashes.txt" "$db_temp_dir/git_hashes.txt"
      fi

      log_info "Zipping backup file into $BACKUP_FILE_PATH..."
      if ! (cd "$db_temp_dir" && zip -r -q "$BACKUP_FILE_PATH" .); then
        log_error "Failed to create backup ZIP archive."
        rm -rf "$db_temp_dir"
        exit 1
      fi

      rm -rf "$db_temp_dir"
      log_success "Backup for '$DB' is completed manually."
    else
      curl -s -X POST \
        -F "master_pwd=$ADMIN_PASSWD" \
        -F "name=$DB" \
        -F "backup_format=zip" \
        -o "$BACKUP_FILE_PATH" \
        "http://localhost:$PORT/web/database/backup"

      if [ -s "$BACKUP_FILE_PATH" ]; then
        log_success "Odoo Database '$DB' has been backed up to: $BACKUP_FILE_PATH"
      else
        log_error "Backup failed for database '$DB'. The output file is empty. Check Odoo logs."
        # Clean up the empty file
        rm -f "$BACKUP_FILE_PATH"
      fi
    fi
  done

  # Set ownership of the backup directory to the user who ran the script with sudo
  if [ -n "$SUDO_USER" ]; then
    chown -R "$SUDO_USER":"$SUDO_USER" "$temporary_directory"
  fi

  log_success "All backup operations are complete. Files are located in: $temporary_directory"
}

main "$@"
