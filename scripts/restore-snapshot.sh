#!/bin/bash

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

TAR_FILE_NAME=snapshot-$SERVICE_NAME.tar.zst
TEMP_DIR=/tmp/snapshot-$SERVICE_NAME

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
  log_info "Restore .secrets/db_user"
  cp -f "$TEMP_DIR/.secrets/db_user" .secrets/db_user || { log_error "Can't restore .secrets/db_user"; }
  chown odoo: .secrets/db_user
  chmod 400 .secrets/db_user

  log_info "Restore .secrets/db_password"
  cp -f "$TEMP_DIR/.secrets/db_password" .secrets/db_password || { log_error "Can't restore .secrets/db_password"; }
  chown odoo: .secrets/db_password
  chmod 400 .secrets/db_password
}

function restoreOdooData() {
  ODOO_DATABASE_NAME_PRD=$(find "$TEMP_DIR/var/lib/odoo/$SERVICE_NAME/filestore/" -mindepth 1 -maxdepth 1 -type d -print | head -n 1 | xargs -n 1 basename)
  ODOO_DATABASE_USER=$(cat "$PATH_TO_ODOO/.secrets/db_user")

  log_info "Restore odoo filestore /var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"
  if [ -d "/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD" ]; then
    rm -rf "/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"
  else
    mkdir -p "/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"
  fi
  mv "$TEMP_DIR/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD" "/var/lib/odoo/$SERVICE_NAME/filestore/" || { log_error "Can't restore /var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"; }
  chown -R odoo: "/var/lib/odoo/$SERVICE_NAME"

  log_info "Restore database $ODOO_DATABASE_NAME_PRD from $TEMP_DIR/tmp/$ODOO_DATABASE_NAME_PRD.sql"
  sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$ODOO_DATABASE_NAME_PRD\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || log_error "Can't drop database $ODOO_DATABASE_NAME_PRD"
  sudo -u postgres psql -c "CREATE DATABASE \"$ODOO_DATABASE_NAME_PRD\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || log_error "Can't create database $ODOO_DATABASE_NAME_PRD"
  sudo -u postgres psql -d "$ODOO_DATABASE_NAME_PRD" -f "$TEMP_DIR/tmp/$ODOO_DATABASE_NAME_PRD.sql" --quiet -t -P pager=off 2> /dev/null > /dev/null || log_error "Can't restore database $ODOO_DATABASE_NAME_PRD"

  log_info "Change the owner of the database."
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

  # Self-elevate to root if not already
  if [ "$(id -u)" -ne 0 ]; then
      log_info "Elevating permissions to root..."
      exec sudo "$0" "$@"
      log_error "Failed to elevate to root. Please run with sudo." # This will only run if exec fails
      exit 1
  fi

  areYouReallySure
  isZstdInstalled
  isSnapshotFileExist

  cd "$PATH_TO_ODOO" || { log_error "Can't change directory to $PATH_TO_ODOO"; exit 1; }

  log_info "Extract /tmp/$TAR_FILE_NAME to $TEMP_DIR"
  mkdir "$TEMP_DIR" || { log_error "Can't create $TEMP_DIR. Maybe the directory exist."; exit 1; }
  tar -xaf "/tmp/$TAR_FILE_NAME" -C "/tmp/snapshot-$SERVICE_NAME" || { log_error "Can't extract /tmp/$TAR_FILE_NAME"; exit 1; }

  log_info "Restore conf/odoo.conf"
  cp -f "$TEMP_DIR/conf/odoo.conf" "conf/odoo.conf" || { log_error "Can't restore conf/odoo.conf"; }
  chown "$REPOSITORY_OWNER": "conf/odoo.conf"

  log_info "Restore environment file (.env)"
  cp -f "$TEMP_DIR/.env" .env || { log_error "Can't restore .env"; }
  chown "$REPOSITORY_OWNER": .env

  restoreDBCredentials

  log_info "Stop $SERVICE_NAME service"
  docker compose down > /dev/null 2>&1 || true

  log_info "Restore backupdata script scripts/backupdata-$SERVICE_NAME"
  cp -f $TEMP_DIR/scripts/backupdata-$SERVICE_NAME "scripts/backupdata-$SERVICE_NAME" || { log_error "Can't restore scripts/backupdata-$SERVICE_NAME"; }
  ln -s "$PATH_TO_ODOO/scripts/backupdata-$SERVICE_NAME" /usr/local/sbin/backupdata-$SERVICE_NAME > /dev/null 2>&1 || { log_warn "Can't create symlink on /usr/local/sbin/backupdata-$SERVICE_NAME. Maybe the symlink is exist."; }
  chown "$REPOSITORY_OWNER": "scripts/backupdata-$SERVICE_NAME"
  chmod 755 "scripts/backupdata-$SERVICE_NAME"

  log_info "Restore databasecloner script scripts/databasecloner-$SERVICE_NAME"
  cp -f $TEMP_DIR/scripts/databasecloner-$SERVICE_NAME "scripts/databasecloner-$SERVICE_NAME" || { log_error "Can't restore scripts/databasecloner-$SERVICE_NAME"; }
  ln -s "$PATH_TO_ODOO/scripts/databasecloner-$SERVICE_NAME" /usr/local/sbin/databasecloner-$SERVICE_NAME > /dev/null 2>&1 || { log_warn "Can't create symlink on /usr/local/sbin/databasecloner-$SERVICE_NAME. Maybe the symlink is exist."; }
  chown "$REPOSITORY_OWNER": "scripts/databasecloner-$SERVICE_NAME"
  chmod 755 "scripts/databasecloner-$SERVICE_NAME"

  log_info "Restore the snapshot script scripts/snapshot-$SERVICE_NAME"
  cp -f $TEMP_DIR/scripts/snapshot-$SERVICE_NAME "scripts/snapshot-$SERVICE_NAME" || { log_error "Can't restore scripts/snapshot-$SERVICE_NAME"; }
  ln -s "$PATH_TO_ODOO/scripts/snapshot-$SERVICE_NAME" /usr/local/sbin/snapshot-$SERVICE_NAME > /dev/null 2>&1 || { log_warn "Can't create symlink on /usr/local/sbin/snapshot-$SERVICE_NAME. Maybe the symlink is exist."; }
  chown "$REPOSITORY_OWNER": "scripts/snapshot-$SERVICE_NAME"
  chmod 755 "scripts/snapshot-$SERVICE_NAME"

  log_info "Restore requirements.txt"
  cp -f "$TEMP_DIR/requirements.txt" ./requirements.txt || { log_error "Can't restore requirements.txt"; }
  chown "$REPOSITORY_OWNER": ./requirements.txt

  restoreOdooData

  log_info "Restore Odoo modules without git."
  find "$TEMP_DIR/git/" -mindepth 1 -maxdepth 1 -type d -exec cp -r {} ./git/ \; || { log_error "Can't restore Odoo modules without git."; }
  chown -R "$REPOSITORY_OWNER": ./git/

  echo -e "\n==========================================================================="

  log_warn "git Odoo modules used by the previous snapshot."
  log_warn "You need to clone these repositories manually into git directory. If you want to rebuild the image."
  cat "$TEMP_DIR/git/git_hashes.txt"

  echo -e "\n==========================================================================="

  log_warn "odoo-base git hashes used by the previous snapshot."
  log_warn "You need to clone these repositories manually into git directory. If you want to rebuild the image."
  cat "$TEMP_DIR/odoo-base/git_hashes.txt"

  echo -e "\n==========================================================================="

  cleanup

  log_warn "You need to run the following command then follow the instruction whether you want to rebuild or pull the Odoo image."
  echo -e "The script is located at the root of this repository.\n"
  echo -e "     'sudo ./_install.sh'\n"
}

main "@"
