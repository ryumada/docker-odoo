#!/bin/bash

function error_handler() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Error on line $1"
  exit 1
}

function getDate() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")]"
}

function amIRoot() {
  if [ "$EUID" -ne 0 ]; then
    echo "$(getDate) 🔴 Please run as root"
    exit 1
  fi
}

function isBackupDataExists() {
  backupdata_file_path="$1"
  if [ ! -f "$backupdata_file_path" ]; then
    echo "$(getDate) 🔴 Backup data file $backupdata_file_path does not exist. Please place your backupdata file on /tmp directory."
    exit 1
  fi
}

function isPg_restoreInstalled() {
  if ! command -v pg_restore &>/dev/null; then
    echo "$(getDate) 🔴 pg_restore is not installed. Please install postgresql-client"
    echo "$(getDate) Ubuntu: sudo apt install postgresql-client"
    echo "$(getDate) CentOS: sudo yum install postgresql-client"
    exit 1
  fi
}

function isRsyncInstalled() {
  if ! command -v rsync &>/dev/null; then
    echo "$(getDate) 🔴 rsync is not installed. Please install rsync"
    echo "$(getDate) Ubuntu: sudo apt install rsync"
    echo "$(getDate) CentOS: sudo yum install rsync"
    exit 1
  fi
}

function isUnZipInstalled() {
  if ! command -v unzip &>/dev/null; then
    echo "$(getDate) 🔴 unzip is not installed. Please install unzip"
    echo "$(getDate) Ubuntu: sudo apt install unzip"
    echo "$(getDate) CentOS: sudo yum install unzip"
    exit 1
  fi
}

function restoreOdooData() {
  restored_db_name="$1"
  odoo_db_user="$2"

  echo "$(getDate) 🏗️ Create the $restored_db_name database"
  sudo -u postgres psql -c "CREATE DATABASE \"$restored_db_name\"" > /dev/null 2>&1

  echo "$(getDate) 📥 Restore the database"
  sudo -u postgres psql -d "$restored_db_name" -f "$TEMP_DIR/dump.sql" > /dev/null 2>&1

  echo "$(getDate) 👤 Change the owner of the database"
  sudo -u postgres psql -c "ALTER DATABASE \"$restored_db_name\" OWNER TO \"$odoo_db_user\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't change the owner of the database $restored_db_name"

  echo "$(getDate) 👤 Change the owner of the tables, sequences, and views"
  sudo -u postgres psql --quiet -t -P pager=off -d "$restored_db_name" -c "
    -- Change the owner of all tables
    DO \$\$
    DECLARE
        rec RECORD;
    BEGIN
        FOR rec IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
            EXECUTE 'ALTER TABLE ' || quote_ident(rec.tablename) || ' OWNER TO \"${odoo_db_user}\"';
        END LOOP;
    END \$\$;

    -- Change the owner of all sequences
    DO \$\$
    DECLARE
        rec RECORD;
    BEGIN
        FOR rec IN (SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema = 'public') LOOP
            EXECUTE 'ALTER SEQUENCE ' || quote_ident(rec.sequence_name) || ' OWNER TO \"${odoo_db_user}\"';
        END LOOP;
    END \$\$;

    -- Change the owner of all views
    DO \$\$
    DECLARE
        rec RECORD;
    BEGIN
        FOR rec IN (SELECT table_name FROM information_schema.views WHERE table_schema = 'public') LOOP
            EXECUTE 'ALTER VIEW ' || quote_ident(rec.table_name) || ' OWNER TO \"${odoo_db_user}\"';
        END LOOP;
    END \$\$;
  " 2> /dev/null > /dev/null || echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't change the owner of the tables, sequences, and views of the database $restored_db_name"
}

trap 'error_handler $LINENO' ERR

function main() {
  PATH_TO_ODOO=$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
  SERVICE_NAME=$(basename "$PATH_TO_ODOO")
  ODOO_DB_USER=$(cat "$PATH_TO_ODOO/.secrets/db_user")
  BACKUPDATA_FILE_NAME="backupdata-$SERVICE_NAME.zip"
  BACKUPDATA_FILE_PATH="/tmp/$BACKUPDATA_FILE_NAME"
  TEMP_DIR="/tmp/backupdata-$SERVICE_NAME"
  RESTORED_DB_NAME=""

  amIRoot
  isBackupDataExists "$BACKUPDATA_FILE_PATH"
  isRsyncInstalled
  isPg_restoreInstalled
  isUnZipInstalled

  echo -e "$(getDate) 🔵 Start restoring backup data for $SERVICE_NAME"

  while true; do
    echo -e "\n$(getDate) Enter database name to restore your data.\n"
    read -rp ": " RESTORED_DB_NAME

    echo "$(getDate) Checking if the database exists"
    if sudo -u postgres psql -c '\l' | grep -wq "$RESTORED_DB_NAME"; then
      echo "$(getDate) 🔴 Database $RESTORED_DB_NAME exists. You need to enter the new database name"
    else
      echo "$(getDate) ✅ Database $RESTORED_DB_NAME does not exist"
      break
    fi
  done
  
  FILESTORE_PATH="/var/lib/odoo/$SERVICE_NAME/filestore/$RESTORED_DB_NAME"
  
  echo "$(getDate) 🛝 Create a temporary directory"
  mkdir -p "$TEMP_DIR"

  echo "$(getDate) 📦 Extract the zip backup file"
  unzip -qqqq -d "$TEMP_DIR" "$BACKUPDATA_FILE_PATH" > /dev/null2>&1

  echo "$(getDate) 🏗️ Create the filestore directory"
  mkdir "$FILESTORE_PATH"

  echo "$(getDate) 📥 Restore the filestore"
  rsync -a "$TEMP_DIR/filestore/" "$FILESTORE_PATH"

  echo "$(getDate) 👤 Changing the ownership of $FILESTORE_PATH to odoo user"
  chown -R odoo: "$FILESTORE_PATH"

  restoreOdooData "$RESTORED_DB_NAME" "$ODOO_DB_USER"

  echo "$(getDate) 🧹 Clean up the temporary directory"
  rm -rf "$TEMP_DIR"

  echo "$(getDate) ✅ Finish restoring backup data for $SERVICE_NAME"
}

main
