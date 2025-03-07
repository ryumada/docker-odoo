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

  echo "Are you sure want to backup odoo datas on $SERVICE_NAME deployment?"
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

  read -rp "Enter the name of Odoo Database(s) you want to backup (Enter multiple database with comma [,]): " DB_LIST

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

  temporary_directory="/tmp/$(date +"%Y%m%d-%H%M%S")-dataodoo-backupper"
  output_mkdir=$(mkdir -p "$temporary_directory" 2>&1) && {
    echo "$(getDate) ✅ Create temporary directory: $temporary_directory"
  } || {
    echo "$(getDate) 🔴 Error creating temporary directory: $output_mkdir"
    exit 1
  }

  output_chmod=$(chmod 777 "$temporary_directory" 2>&1) && {
    echo "$(getDate) ✅ Change the permission of $temporary_directory to 777"
  } || {
    echo "$(getDate) 🔴 Error changing the $temporary_directory directory: $output_chmod"
  }

  cd "$temporary_directory" || {
    echo "🔴 Error change directory to $temporary_directory"
    exit 1
  }

  for DB in $(echo "$DB_LIST" | tr "," "\n"); do
    echo "$(getDate) 🟦 Synchronize the filestore of: $DB"
    output_rsync=$(rsync -avzc "$ODOO_FILESTORE_PATH/$DB" ./filestore/) && {
      echo "$(getDate) ✅ Filestore is synchronized"
    } || {
      echo "$(getDate) 🔴 Error synchronize filestore: $output_rsync"
    }

    echo "$(getDate) 🟦 Backup Odoo Database: $DB"
    output_pg_dump=$(sudo -u postgres pg_dump -d "$DB" -f "./dump.sql" 2>&1) || {
      echo "$(getDate) 🔴 Error dump database: $output_pg_dump"
    }

    echo "$(getDate) 📦 Archiving the backupdata..."
    output_zip=$(zip -r "./$DB.zip" ./dump.sql ./filestore 2>&1) && {
      echo "$(getDate) ✅ Backup data created: $temporary_directory/$DB.zip"
    } || {
      echo "$(getDate) 🔴 Error archiving the backupdata: $output_zip"
    }
    
    echo "$(getDate) 🧹 Removing the temporary backup files"
    output_rm=$(rm -rf "$temporary_directory/filestore" "$temporary_directory/dump.sql" 2>&1) && {
      echo "$(getDate) ✅ The temporary backup files is removed"
    } || {
      echo "$(getDate) 🔴 Cannot remove the temporary backup files: $output_rm"
    }
    
    echo "$(getDate) ✅ Odoo Database: $DB has been backupped"
  done
}

main
