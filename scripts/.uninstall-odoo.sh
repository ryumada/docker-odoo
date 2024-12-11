#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

error_handler() {
  echo "An error occurred on line $1. Exiting..."
  exit 1
}

trap 'error_handler $LINENO' ERR

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c %U "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")

function amIRoot() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "$(getDate) 🔴 Please run this script as root." 1>&2
    exit 1
  fi
}

function areYouReallySure() {
  prompt=$1

  echo "Are you really sure you want to uninstall $SERVICE_NAME deployment?"
  echo -e "Type '$prompt'\n"
  read -r -p ": " RESPONSE
  
  if [ "$RESPONSE" != "$prompt" ]; then
    echo -e "\n$(getDate) 🔴 You don't write the correct phrase. Exiting..."
    echo "$(getDate) 🆗 Uninstallation aborted."
    exit 1
  fi
}

function getDate() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")]"
}

function stopOdooDeployment() {
  echo "$(getDate) 🛑 Stopping Odoo deployment..." 1>&2
  docker compose -f "$DOCKER_COMPOSE_FILE" down
}

function main() {
  amIRoot

  BACKUPDATA_SCRIPT_FILE="$PATH_TO_ODOO/scripts/backupdata-$SERVICE_NAME"
  DATABASECLONER_SCRIPT_FILE="$PATH_TO_ODOO/scripts/databasecloner-$SERVICE_NAME"
  SNAPSHOT_SCRIPT_FILE="$PATH_TO_ODOO/scripts/snapshot-$SERVICE_NAME"
  DOCKER_RESTARTOR_SCRIPT_FILE="/usr/local/sbin/restart_$SERVICE_NAME"
  ODOO_LOG_ROTATOR_FILE="/etc/logrotate.d/$SERVICE_NAME"

  DB_USER_SECRET="$PATH_TO_ODOO/.secrets/db_user"
  DOCKER_COMPOSE_FILE="./docker-compose.yml"
  ODOO_DATADIR="/var/lib/odoo"
  ODOO_DATADIR_SERVICE="$ODOO_DATADIR/$SERVICE_NAME"
  ODOO_LOG_DIR="/var/log/odoo"
  ODOO_LOG_DIR_SERVICE="$ODOO_LOG_DIR/$SERVICE_NAME"

  DB_USER=$(cat "$DB_USER_SECRET")

  DATABASE_COUNT=$(sudo -u postgres psql -tAc "SELECT COUNT(*) FROM pg_database WHERE datdba=(SELECT usesysid FROM pg_user WHERE usename='$DB_USER');")
  if [ "$DATABASE_COUNT" -gt 1 ]; then
    echo "$(getDate) 🔴 The postgres user '$DB_USER' has multiple databases. Uninstallation is prohibited."
    echo "$(getDate) 🔴 Please remove the databases manually and leave one, then try running this script again."
    exit 1
  fi

  areYouReallySure "yes"
  echo
  areYouReallySure "yes, remove $SERVICE_NAME deployment"
  echo
  areYouReallySure "yes, remove $SERVICE_NAME deployment permanently"
  echo
  areYouReallySure "yes, remove $SERVICE_NAME deployment permanently and all its data"
  echo

  "$SNAPSHOT_SCRIPT_FILE" || { echo "$(getDate) 🔴 The snapshot script failed. Uninstallation is prohibited. Please create the snapshot script first"; exit 1; }

  cd "$PATH_TO_ODOO"

  stopOdooDeployment

  echo "$(getDate) 🗑️ Start to remove Odoo deployment..."

  DB_NAME="$(sudo -u postgres psql -tc "SELECT datname FROM pg_database WHERE datdba=(SELECT usesysid FROM pg_user WHERE usename='$DB_USER')" | awk '{print $1}')"
  echo "$(getDate) 🗑️ Remove the database: $DB_NAME"
  sudo -u postgres dropdb "$DB_NAME"

  echo "$(getDate) 🗑️ Remove the datadir: $ODOO_DATADIR_SERVICE"
  rm -rf "$ODOO_DATADIR_SERVICE"

  echo "$(getDate) 🗑️ Remove the logdir: $ODOO_LOG_DIR_SERVICE"
  rm -rf "$ODOO_LOG_DIR_SERVICE"

  if [ -f "$BACKUPDATA_SCRIPT_FILE" ]; then
    echo "$(getDate) 🗑️ Remove the backup script: $BACKUPDATA_SCRIPT_FILE"
    rm "$BACKUPDATA_SCRIPT_FILE"

    BACKUPDATA_SCRIPT_SOFTLINK_FILE="/usr/local/sbin/backupdata-$SERVICE_NAME"
    echo "$(getDate) 🗑️ remove the soft-link: $BACKUPDATA_SCRIPT_SOFTLINK_FILE"
    rm "$BACKUPDATA_SCRIPT_SOFTLINK_FILE"
  fi

  if [ -f "$DATABASECLONER_SCRIPT_FILE" ]; then
    echo "$(getDate) 🗑️ Remove the database cloner script: $DATABASECLONER_SCRIPT_FILE"
    rm "$DATABASECLONER_SCRIPT_FILE"

    DATABASECLONER_SCRIPT_SOFTLINK_FILE="/usr/local/sbin/databasecloner-$SERVICE_NAME"
    echo "$(getDate) 🗑️ remove the soft-link: $DATABASECLONER_SCRIPT_SOFTLINK_FILE"
    rm "$DATABASECLONER_SCRIPT_SOFTLINK_FILE"
  fi

  if [ -f "$SNAPSHOT_SCRIPT_FILE" ]; then
    echo "$(getDate) 🗑️ Remove the snapshot script: $SNAPSHOT_SCRIPT_FILE"
    rm "$SNAPSHOT_SCRIPT_FILE"

    SNAPSHOT_SCRIPT_SOFTLINK_FILE="/usr/local/sbin/snapshot-$SERVICE_NAME"
    echo "$(getDate) 🗑️ remove the soft-link: $SNAPSHOT_SCRIPT_SOFTLINK_FILE"
    rm "$SNAPSHOT_SCRIPT_SOFTLINK_FILE"
  fi

  if [ -f "$DOCKER_RESTARTOR_SCRIPT_FILE" ]; then
    echo "$(getDate) 🗑️ Remove the docker restartor script: $DOCKER_RESTARTOR_SCRIPT_FILE"
    rm "$DOCKER_RESTARTOR_SCRIPT_FILE"

    DOCKER_RESTARTOR_CRON_FILE="/etc/cron.d/restart_$SERVICE_NAME"
    echo "$(getDate) 🗑️ Remove the cron file: $DOCKER_RESTARTOR_CRON_FILE"
    rm "$DOCKER_RESTARTOR_CRON_FILE"

    DOCKER_RESTARTOR_LOGROTATE_FILE="/etc/logrotate.d/restart_$SERVICE_NAME"
    echo "$(getDate) 🗑️ Remove the logrotate: $DOCKER_RESTARTOR_LOGROTATE_FILE"
    rm "$DOCKER_RESTARTOR_LOGROTATE_FILE"
  fi

  if [ -f "$ODOO_LOG_ROTATOR_FILE" ]; then
    echo "$(getDate) 🗑️ Remove the Odoo logrotate file: $ODOO_LOG_ROTATOR_FILE"
    rm "$ODOO_LOG_ROTATOR_FILE"
  fi

  echo "$(getDate) ✅ Completed. $SERVICE_NAME deployment has been removed."

  echo "$(getDate) 🟨 To freeup disk space you need to do this command in order:"
  echo "      1. sudo docker container prune -a"
  echo "      2. sudo docker image prune"
  echo "      3. sudo docker system prune -a"
  echo "      4. sudo docker volume prune"
  echo "      5. sudo docker network prune"

  echo "$(getDate) 🟨 You can delete this repository now, to delete data. Make sure the snapshot file has been moved to the safe location."
}

main
