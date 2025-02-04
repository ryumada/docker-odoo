#!/bin/bash

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
ODOO_FILESTORE_PATH="/var/lib/odoo/$SERVICE_NAME/filestore"

function getDate() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")]"
}

function isRoot() {
  if sudo -n true 2>/dev/null; then
    echo "$(getDate) 🟦 Running as root"
  else
    echo "$(getDate) 🔴 Please run this script as root"
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

function whichData() {
  local DB_LIST

  read -rp "Enter the name of Odoo Database you want to remote (Enter multiple database with comma [,]): " DB_LIST

  if [ -z "$DB_LIST" ]; then
    echo "No database name entered. Exiting..."
    exit 1
  fi

  echo "$DB_LIST"
}

function main() {
  isRoot

  areYouReallySure "yes"

  DB_LIST="$(whichData)"

  for DB in $(echo "$DB_LIST" | tr "," "\n"); do
    echo "$(getDate) 🟦 Removing Odoo Database: $DB"
    sudo -u postgres psql -d postgres -c "DROP DATABASE IF EXISTS \"$DB\" WITH (FORCE)" > /dev/null 2>&1 || { echo "$(getDate) 🔴 Error dropping database: $(cat /dev/stderr)"; exit 1; }
    
    echo "$(getDate) 🟦 Removing Odoo Filestore: $ODOO_FILESTORE_PATH/$DB"
    sudo rm -rf "$ODOO_FILESTORE_PATH/$DB"
    
    echo "$(getDate) Odoo Database: $DB has been removed"
  done
}

main
