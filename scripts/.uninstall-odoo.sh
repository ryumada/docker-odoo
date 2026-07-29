#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Uninstalls the Odoo deployment, removing containers, volumes, and configuration.
# Usage: ./scripts/.uninstall-odoo.sh
# Dependencies: sudo, stat, awk, psql, docker

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

# Error handler
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

FILEPATHS_TO_REMOVE=(
  "/etc/sudoers.d/00-devops_as_devopsadmin"
  "/etc/sudoers.d/00-devops_as_root"
)

die() {
  log_error "$*"
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

function areYouReallySure() {
  local prompt=${1:-yes}

  echo "Are you really sure you want to uninstall $SERVICE_NAME deployment?"
  echo -e "Type '$prompt'\n"
  read -r -p ": " RESPONSE

  if [ "$RESPONSE" != "$prompt" ]; then
    log_error "You don't write the correct phrase. Exiting..."
    log_info "Uninstallation aborted."
    exit 1
  fi
}

function removeWithPrompt() {
  local filepath=$1
  # Only prompt if target exists
  if [ -e "$filepath" ]; then
    read -rp "❓ Do you want to remove $filepath? [y/N] : " response || true
    if [[ "${response:-}" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
      log_info "Removing $filepath"
      rm -f -- "$filepath"
    fi
  fi
}

function stopOdooDeployment() {
  log_info "Stopping Odoo deployment..."
  # Prefer docker compose; fallback to docker-compose
  if have docker && docker compose version >/dev/null 2>&1; then
    docker compose -f "$DOCKER_COMPOSE_FILE" down
  elif have docker-compose; then
    docker-compose -f "$DOCKER_COMPOSE_FILE" down
  else
    die "Docker Compose is not installed. Please install Docker Compose."
  fi
}

function main() {
  # Self-elevate to root if not already
  if [ "$(id -u)" -ne 0 ]; then
      log_info "Elevating permissions to root..."
      # shellcheck disable=SC2093
      exec sudo "$0" "$@" # Re-run the script with sudo
      die "Failed to elevate to root. Please run with sudo." # This will only run if exec fails
  fi

  BACKUPDATA_SCRIPT_FILE="$PATH_TO_ODOO/scripts/backupdata-$SERVICE_NAME"
  DATABASECLONER_SCRIPT_FILE="$PATH_TO_ODOO/scripts/databasecloner-$SERVICE_NAME"
  SNAPSHOT_SCRIPT_FILE="$PATH_TO_ODOO/scripts/snapshot-$SERVICE_NAME"
  DOCKER_RESTARTOR_SCRIPT_FILE="/usr/local/sbin/restart_$SERVICE_NAME"
  ODOO_LOG_ROTATOR_FILE="/etc/logrotate.d/$SERVICE_NAME"

  DB_USER_SECRET="$PATH_TO_ODOO/.secrets/db_user"
  DOCKER_COMPOSE_FILE="$PATH_TO_ODOO/docker-compose.yml"
  ODOO_DATADIR="/var/lib/odoo"
  ODOO_DATADIR_SERVICE="$ODOO_DATADIR/$SERVICE_NAME"
  ODOO_LOG_DIR="/var/log/odoo"
  ODOO_LOG_DIR_SERVICE="$ODOO_LOG_DIR/$SERVICE_NAME"

  # Basic dependency checks
  have sudo || die "sudo is required to run this script."
  have stat || die "stat is required to run this script."
  have awk || die "awk is required to run this script."
  have psql || die "psql (PostgreSQL client) is required."

  # Compose file resolution
  if [ ! -f "$DOCKER_COMPOSE_FILE" ]; then
    # Try relative to cwd if user executed from root already
    if [ -f "./docker-compose.yml" ]; then
      DOCKER_COMPOSE_FILE="./docker-compose.yml"
    else
      die "docker-compose.yml not found at $PATH_TO_ODOO or current directory."
    fi
  fi

  BYPASS_SNAPSHOT=false
  for arg in "$@"; do
    if [ "$arg" == "--bypass-snapshot" ] || [ "$arg" == "bypass-snapshot" ] || [ "$arg" == "-b" ]; then
      BYPASS_SNAPSHOT=true
      log_warn "Bypassing snapshot execution and pre-uninstallation backup verification."
    fi
  done

  # DB user secret
  if [ ! -f "$DB_USER_SECRET" ]; then
    die "DB user secret not found: $DB_USER_SECRET"
  fi
  DB_USER=$(tr -d '\r\n\t ' < "$DB_USER_SECRET")
  if [ -z "${DB_USER:-}" ]; then
    die "DB user secret is empty: $DB_USER_SECRET"
  fi

  # Backup verification per deployment
  if [ "$BYPASS_SNAPSHOT" = "false" ]; then
    AVAILABLE_DEPLOYMENTS=$(grep "^AVAILABLE_DEPLOYMENTS=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
    if [ -n "$AVAILABLE_DEPLOYMENTS" ]; then
      IFS=';' read -ra DEP_ARR <<< "$AVAILABLE_DEPLOYMENTS"
      MISSING_BACKUPS=()
      for dep in "${DEP_ARR[@]}"; do
        if ! ls /tmp/backupdata_*${dep}* /tmp/snapshot_*${dep}* /tmp/backupdata_* /tmp/snapshot_* >/dev/null 2>&1; then
          MISSING_BACKUPS+=("$dep")
        fi
      done

      if [ ${#MISSING_BACKUPS[@]} -gt 0 ]; then
        log_error "Backup files in /tmp/ are missing for deployment(s): ${MISSING_BACKUPS[*]}"
        log_info "To complete uninstallation safely:"
        for dep in "${MISSING_BACKUPS[@]}"; do
          log_info "  1. Switch environment: sudo ./scripts/switch_env.sh $dep"
          log_info "  2. Run backup: sudo ./scripts/backupdata-$SERVICE_NAME (or ./scripts/snapshot-$SERVICE_NAME)"
          log_info "  3. Ensure the backup file is placed in /tmp/"
        done
        log_warn "Alternatively, pass --bypass-snapshot to force uninstallation without backups."
        die "Uninstallation aborted: Missing backup files in /tmp/."
      fi
    fi
  fi

  areYouReallySure "yes"
  echo
  areYouReallySure "yes, remove $SERVICE_NAME deployment"
  echo
  areYouReallySure "yes, remove $SERVICE_NAME deployment permanently"
  echo
  areYouReallySure "yes, remove $SERVICE_NAME deployment permanently and all its data"
  echo

  if [ "$BYPASS_SNAPSHOT" = "false" ]; then
    if [ -x "$SNAPSHOT_SCRIPT_FILE" ]; then
      if ! "$SNAPSHOT_SCRIPT_FILE"; then
        die "The snapshot script failed. Uninstallation is prohibited. Please create the snapshot script first"
      fi
    else
      log_warn "The snapshot script is missing or not executable: $SNAPSHOT_SCRIPT_FILE. Ensure backups exist in /tmp/."
    fi
  fi

  cd "$PATH_TO_ODOO"

  stopOdooDeployment

  log_info "Start to remove Odoo deployment..."

  # Collect all DB Users (base DB_USER, ACTIVE_DB_USER, and deployment DB users)
  DB_USERS_TO_CLEAN=("$DB_USER")
  ACTIVE_DB_USER=$(grep "^ACTIVE_DB_USER=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
  [ -n "$ACTIVE_DB_USER" ] && DB_USERS_TO_CLEAN+=("$ACTIVE_DB_USER")

  AVAILABLE_DEPLOYMENTS=$(grep "^AVAILABLE_DEPLOYMENTS=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
  if [ -n "$AVAILABLE_DEPLOYMENTS" ]; then
    IFS=';' read -ra DEP_ARR <<< "$AVAILABLE_DEPLOYMENTS"
    for dep in "${DEP_ARR[@]}"; do
      DB_USERS_TO_CLEAN+=("${dep}")
    done
  fi

  for db_u in "${DB_USERS_TO_CLEAN[@]}"; do
    DBS=$(sudo -u postgres psql -tAc "SELECT datname FROM pg_database WHERE datdba=(SELECT usesysid FROM pg_user WHERE usename='$db_u' LIMIT 1);" 2>/dev/null || true)
    for db in $DBS; do
      log_info "Removing database: $db (owner: $db_u)"
      sudo -u postgres dropdb "$db" || true
    done
  done

  log_info "Removing datadirs under /var/lib/odoo/${SERVICE_NAME}*"
  rm -rf /var/lib/odoo/${SERVICE_NAME} /var/lib/odoo/${SERVICE_NAME}-* 2>/dev/null || true

  log_info "Removing logdirs under /var/log/odoo/${SERVICE_NAME}*"
  rm -rf /var/log/odoo/${SERVICE_NAME} /var/log/odoo/${SERVICE_NAME}-* 2>/dev/null || true

  log_info "Removing backup/clone/snapshot scripts and soft-links..."
  rm -f -- "$BACKUPDATA_SCRIPT_FILE" "/usr/local/sbin/backupdata-$SERVICE_NAME" 2>/dev/null || true
  rm -f -- "$DATABASECLONER_SCRIPT_FILE" "/usr/local/sbin/databasecloner-$SERVICE_NAME" 2>/dev/null || true
  rm -f -- "$SNAPSHOT_SCRIPT_FILE" "/usr/local/sbin/snapshot-$SERVICE_NAME" 2>/dev/null || true

  log_info "Removing service scripts, cron jobs, and logrotate files..."
  rm -f /usr/local/sbin/restart_${SERVICE_NAME}* /usr/local/sbin/restart-${SERVICE_NAME}* 2>/dev/null || true
  rm -f /etc/cron.d/restart_${SERVICE_NAME}* /etc/cron.d/restart-${SERVICE_NAME}* 2>/dev/null || true
  rm -f /etc/logrotate.d/restart_${SERVICE_NAME}* /etc/logrotate.d/restart-${SERVICE_NAME}* 2>/dev/null || true
  rm -f /etc/logrotate.d/${SERVICE_NAME}* 2>/dev/null || true

  for FILEPATH_TO_REMOVE in "${FILEPATHS_TO_REMOVE[@]}"; do
    removeWithPrompt "$FILEPATH_TO_REMOVE"
  done

  log_success "Completed. $SERVICE_NAME deployment has been removed."

  log_warn "To freeup disk space you need to do this command in order:"
  echo "      1. sudo docker container prune -a"
  echo "      2. sudo docker image prune"
  echo "      3. sudo docker system prune -a"
  echo "      4. sudo docker volume prune"
  echo "      5. sudo docker network prune"

  log_warn "You can delete this repository now, to delete data. Make sure the snapshot file has been moved to the safe location."
}

main "$@"
