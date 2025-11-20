#!/bin/bash

# Safer bash options
set -Eeuo pipefail
IFS=$'\n\t'

# --- Logging Functions & Colors ---
# Define colors for log messages
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[0;33m"
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

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c %U "$CURRENT_DIR")

# Resolve repo root; fallback to parent of scripts dir if not a git repo
if sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel)
else
  PATH_TO_ODOO=$(readlink -f "$CURRENT_DIR/..")
fi
SERVICE_NAME=$(basename "$PATH_TO_ODOO")

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

  # DB user secret
  if [ ! -f "$DB_USER_SECRET" ]; then
    die "DB user secret not found: $DB_USER_SECRET"
  fi
  DB_USER=$(tr -d '\r\n\t ' < "$DB_USER_SECRET")
  if [ -z "${DB_USER:-}" ]; then
    die "DB user secret is empty: $DB_USER_SECRET"
  fi

  DATABASE_COUNT=$(sudo -u postgres psql -tAc "SELECT COUNT(*) FROM pg_database WHERE datdba=(SELECT usesysid FROM pg_user WHERE usename='$DB_USER');")
  if [ "$DATABASE_COUNT" -gt 1 ]; then
    log_error "The postgres user '$DB_USER' has multiple databases. Uninstallation is prohibited."
    die "Please remove the databases manually and leave one, then try running this script again."
  fi

  areYouReallySure "yes"
  echo
  areYouReallySure "yes, remove $SERVICE_NAME deployment"
  echo
  areYouReallySure "yes, remove $SERVICE_NAME deployment permanently"
  echo
  areYouReallySure "yes, remove $SERVICE_NAME deployment permanently and all its data"
  echo

  if [ -x "$SNAPSHOT_SCRIPT_FILE" ]; then
    if ! "$SNAPSHOT_SCRIPT_FILE"; then
      die "The snapshot script failed. Uninstallation is prohibited. Please create the snapshot script first"
    fi
  else
    log_error "The snapshot script is missing or not executable: $SNAPSHOT_SCRIPT_FILE"
    die "Uninstallation is prohibited. Please ensure snapshot is created."
  fi

  cd "$PATH_TO_ODOO"

  stopOdooDeployment

  log_info "Start to remove Odoo deployment..."

  DB_NAME="$(sudo -u postgres psql -tc "SELECT datname FROM pg_database WHERE datdba=(SELECT usesysid FROM pg_user WHERE usename='$DB_USER')" | awk '{print $1}')"
  if [ -z "${DB_NAME:-}" ]; then
    die "Could not determine database name for user '$DB_USER'"
  fi
  log_info "Removing the database: $DB_NAME"
  sudo -u postgres dropdb "$DB_NAME"

  log_info "Removing the datadir: $ODOO_DATADIR_SERVICE"
  rm -rf "$ODOO_DATADIR_SERVICE"

  log_info "Removing the logdir: $ODOO_LOG_DIR_SERVICE"
  rm -rf "$ODOO_LOG_DIR_SERVICE"

  if [ -f "$BACKUPDATA_SCRIPT_FILE" ]; then
    log_info "Removing the backup script: $BACKUPDATA_SCRIPT_FILE"
    rm -f -- "$BACKUPDATA_SCRIPT_FILE"

    BACKUPDATA_SCRIPT_SOFTLINK_FILE="/usr/local/sbin/backupdata-$SERVICE_NAME"
    log_info "Removing the soft-link: $BACKUPDATA_SCRIPT_SOFTLINK_FILE"
    rm -f -- "$BACKUPDATA_SCRIPT_SOFTLINK_FILE"
  fi

  if [ -f "$DATABASECLONER_SCRIPT_FILE" ]; then
    log_info "Removing the database cloner script: $DATABASECLONER_SCRIPT_FILE"
    rm -f -- "$DATABASECLONER_SCRIPT_FILE"

    DATABASECLONER_SCRIPT_SOFTLINK_FILE="/usr/local/sbin/databasecloner-$SERVICE_NAME"
    log_info "Removing the soft-link: $DATABASECLONER_SCRIPT_SOFTLINK_FILE"
    rm -f -- "$DATABASECLONER_SCRIPT_SOFTLINK_FILE"
  fi

  if [ -f "$SNAPSHOT_SCRIPT_FILE" ]; then
    log_info "Removing the snapshot script: $SNAPSHOT_SCRIPT_FILE"
    rm -f -- "$SNAPSHOT_SCRIPT_FILE"

    SNAPSHOT_SCRIPT_SOFTLINK_FILE="/usr/local/sbin/snapshot-$SERVICE_NAME"
    log_info "Removing the soft-link: $SNAPSHOT_SCRIPT_SOFTLINK_FILE"
    rm -f -- "$SNAPSHOT_SCRIPT_SOFTLINK_FILE"
  fi

  if [ -f "$DOCKER_RESTARTOR_SCRIPT_FILE" ]; then
    log_info "Removing the docker restartor script: $DOCKER_RESTARTOR_SCRIPT_FILE"
    rm -f -- "$DOCKER_RESTARTOR_SCRIPT_FILE"

    DOCKER_RESTARTOR_CRON_FILE="/etc/cron.d/restart_$SERVICE_NAME"
    log_info "Removing the cron file: $DOCKER_RESTARTOR_CRON_FILE"
    rm -f -- "$DOCKER_RESTARTOR_CRON_FILE"

    DOCKER_RESTARTOR_LOGROTATE_FILE="/etc/logrotate.d/restart_$SERVICE_NAME"
    log_info "Removing the logrotate: $DOCKER_RESTARTOR_LOGROTATE_FILE"
    rm -f -- "$DOCKER_RESTARTOR_LOGROTATE_FILE"
  fi

  if [ -f "$ODOO_LOG_ROTATOR_FILE" ]; then
    log_info "Removing the Odoo logrotate file: $ODOO_LOG_ROTATOR_FILE"
    rm -f -- "$ODOO_LOG_ROTATOR_FILE"
  fi

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

main "@"
