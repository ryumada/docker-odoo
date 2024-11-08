#!/bin/bash

PATH_TO_ODOO=$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

TAR_FILE_NAME=snapshot-$SERVICE_NAME.tar.zst
TEMP_DIR=/tmp/snapshot-$SERVICE_NAME

function amIRoot() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "$(getDate) 🔴 This script must be run as root."
    exit 1
  fi
}

function areYouReallySure() {
  echo -e "\nAre you sure?\n⚠️ This script will replace your current Odoo data and deployment files. ⚠️\nType 'yes I am sure' and press enter to continue.\n"
  read -rp ": " response
  case "$response" in
  "yes I am sure")
    echo -e "\n"
    return 0
    ;;
  *)
    echo -e "\n$(getDate) 🔴 You are not sure. Exiting the script."
    echo -e "\n"
    exit 1;
    ;;
  esac
}

function cleanup() {
  echo -e "\n\n$(getDate) 🧹 Cleanup the temporary directory.\n"
  rm -rf "$TEMP_DIR"
}

function getDate() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")]"
}

function isSnapshotFileExist() {
  if [ ! -f "/tmp/$TAR_FILE_NAME" ]; then
    echo "$(getDate) 🔴 /tmp/$TAR_FILE_NAME not found. Please add your snapshot file to /tmp directory. Or create your snapshot using snapshot script."
    exit 1
  fi
}

function isZstdInstalled() {
  if ! command -v zstd >/dev/null 2>&1; then
    echo "$(getDate) 🔴 zstd is not installed. Please install zstd first."
    echo "For Ubuntu: sudo apt install zstd"
    echo "For CentOS: sudo yum install zstd"
    exit 1
  fi
}

function restoreDBCredentials() {
  echo "$(getDate) Restore .secrets/db_user"
  cp -f "$TEMP_DIR/.secrets/db_user" .secrets/db_user || { echo "$(getDate) 🔴 Can't restore .secrets/db_user"; }
  chown odoo: .secrets/db_user
  chmod 400 .secrets/db_user

  echo "$(getDate) Restore .secrets/db_password"
  cp -f "$TEMP_DIR/.secrets/db_password" .secrets/db_password || { echo "$(getDate) 🔴 Can't restore .secrets/db_password"; }
  chown odoo: .secrets/db_password
  chmod 400 .secrets/db_password
}

function restoreOdooData() {
  ODOO_DATABASE_NAME_PRD=$(find "$TEMP_DIR/var/lib/odoo/$SERVICE_NAME/filestore/" -mindepth 1 -maxdepth 1 -type d -print | head -n 1 | xargs -n 1 basename)
  ODOO_DATABASE_USER=$(cat "$PATH_TO_ODOO/.secrets/db_user")

  echo "$(getDate) Restore odoo filestore /var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"
  if [ -d "/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD" ]; then
    rm -rf "/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"
  else
    mkdir -p "/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"
  fi
  cp -r "$TEMP_DIR/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD" "/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD" || { echo "$(getDate) 🔴 Can't restore /var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"; }
  chown -R odoo: "/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"

  echo "$(getDate) Restore database $ODOO_DATABASE_NAME_PRD from $TEMP_DIR/tmp/$ODOO_DATABASE_NAME_PRD.sql"
  sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$ODOO_DATABASE_NAME_PRD\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || echo "$(getDate) 🔴 Can't drop database $ODOO_DATABASE_NAME_PRD"
  sudo -u postgres psql -c "CREATE DATABASE \"$ODOO_DATABASE_NAME_PRD\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || echo "$(getDate) 🔴 Can't create database $ODOO_DATABASE_NAME_PRD"
  sudo -u postgres psql -d "$ODOO_DATABASE_NAME_PRD" -f "$TEMP_DIR/tmp/$ODOO_DATABASE_NAME_PRD.sql" --quiet -t -P pager=off 2> /dev/null > /dev/null || echo "$(getDate) 🔴 Can't restore database $ODOO_DATABASE_NAME_PRD"

  echo "$(getDate) Change the owner of the database."
  sudo -u postgres psql -c "ALTER DATABASE \"$ODOO_DATABASE_NAME_PRD\" OWNER TO \"$ODOO_DATABASE_USER\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || echo "$(getDate) 🔴 Can't change the owner of the database $ODOO_DATABASE_NAME_PRD"
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
  " 2> /dev/null > /dev/null || echo "$(getDate) 🔴 Can't change the owner of the tables, sequences, and views of the database $ODOO_DATABASE_NAME_PRD"
}

function main() {
  echo "$(getDate) Start restore utility for $SERVICE_NAME"

  amIRoot
  areYouReallySure
  isZstdInstalled
  isSnapshotFileExist

  cd "$PATH_TO_ODOO" || { echo "$(getDate) 🔴 Can't change directory to $PATH_TO_ODOO"; exit 1; }

  echo "$(getDate) Extract /tmp/$TAR_FILE_NAME to $TEMP_DIR"
  mkdir "$TEMP_DIR" || { echo "$(getDate) 🔴 Can't create $TEMP_DIR". Maybe the directory exist.; exit 1; }
  tar -xaf "/tmp/$TAR_FILE_NAME" -C "/tmp/snapshot-$SERVICE_NAME" || { echo "$(getDate) 🔴 Can't extract /tmp/$TAR_FILE_NAME"; exit 1; }

  echo "$(getDate) Restore conf/odoo.conf"
  cp -f "$TEMP_DIR/conf/odoo.conf" "conf/odoo.conf" || { echo "$(getDate) 🔴 Can't restore conf/odoo.conf"; }
  chown "$REPOSITORY_OWNER": "conf/odoo.conf"

  echo "$(getDate) Restore environment file (.env)"
  cp -f "$TEMP_DIR/.env" .env || { echo "$(getDate) 🔴 Can't restore .env"; }
  chown "$REPOSITORY_OWNER": .env

  restoreDBCredentials

  echo "$(getDate) Stop $SERVICE_NAME service"
  docker compose down > /dev/null 2>&1 || true

  echo "$(getDate) Restore backupdata script scripts/backupdata-$SERVICE_NAME"
  cp -f $TEMP_DIR/scripts/backupdata-$SERVICE_NAME "scripts/backupdata-$SERVICE_NAME" || { echo "$(getDate) 🔴 Can't restore scripts/backupdata-$SERVICE_NAME"; }
  ln -s "$PATH_TO_ODOO/scripts/backupdata-$SERVICE_NAME" /usr/local/sbin/backupdata-$SERVICE_NAME > /dev/null 2>&1 || { echo "$(getDate) 🔴 Can't create symlink on /usr/local/sbin/backupdata-$SERVICE_NAME. Maybe the symlink is exist."; }
  chown "$REPOSITORY_OWNER": "scripts/backupdata-$SERVICE_NAME"
  chmod 755 "scripts/backupdata-$SERVICE_NAME"

  echo "$(getDate) Restore databasecloner script scripts/databasecloner-$SERVICE_NAME"
  cp -f $TEMP_DIR/scripts/databasecloner-$SERVICE_NAME "scripts/databasecloner-$SERVICE_NAME" || { echo "$(getDate) 🔴 Can't restore scripts/databasecloner-$SERVICE_NAME"; }
  ln -s "$PATH_TO_ODOO/scripts/databasecloner-$SERVICE_NAME" /usr/local/sbin/databasecloner-$SERVICE_NAME > /dev/null 2>&1 || { echo "$(getDate) 🔴 Can't create symlink on /usr/local/sbin/databasecloner-$SERVICE_NAME. Maybe the symlink is exist."; }
  chown "$REPOSITORY_OWNER": "scripts/databasecloner-$SERVICE_NAME"
  chmod 755 "scripts/databasecloner-$SERVICE_NAME"

  echo "$(getDate) Restore the snapshot script scripts/snapshot-$SERVICE_NAME"
  cp -f $TEMP_DIR/scripts/snapshot-$SERVICE_NAME "scripts/snapshot-$SERVICE_NAME" || { echo "$(getDate) 🔴 Can't restore scripts/snapshot-$SERVICE_NAME"; }
  ln -s "$PATH_TO_ODOO/scripts/snapshot-$SERVICE_NAME" /usr/local/sbin/snapshot-$SERVICE_NAME > /dev/null 2>&1 || { echo "$(getDate) 🔴 Can't create symlink on /usr/local/sbin/snapshot-$SERVICE_NAME. Maybe the symlink is exist."; }
  chown "$REPOSITORY_OWNER": "scripts/snapshot-$SERVICE_NAME"
  chmod 755 "scripts/snapshot-$SERVICE_NAME"

  echo "$(getDate) Restore requirements.txt"
  cp -f "$TEMP_DIR/requirements.txt" ./requirements.txt || { echo "$(getDate) 🔴 Can't restore requirements.txt"; }
  chown "$REPOSITORY_OWNER": ./requirements.txt

  restoreOdooData

  echo "$(getDate) Restore Odoo modules without git."
  find "$TEMP_DIR/git/" -mindepth 1 -maxdepth 1 -type d -exec cp -r {} ./git/ \; || { echo "$(getDate) 🔴 Can't restore Odoo modules without git."; }
  chown -R "$REPOSITORY_OWNER": ./git/

  echo -e "\n==========================================================================="

  echo -e "\n$(getDate) git Odoo modules used by the previous snapshot."
  echo -e "$(getDate) ⚠️ You need to clone these repositories manually into git directory. If you want to rebuild the image. ⚠️\n"
  cat "$TEMP_DIR/git/git_hashes.txt"

  echo -e "\n==========================================================================="

  echo -e "\n$(getDate) odoo-base git hashes used by the previous snapshot."
  echo -e "$(getDate) ⚠️ You need to clone these repositories manually into git directory. If you want to rebuild the image. ⚠️\n"
  cat "$TEMP_DIR/odoo-base/git_hashes.txt"

  echo -e "\n==========================================================================="

  cleanup
  
  echo -e "$(getDate) ⚠️ You need to run the following command then follow the instruction whether you want to rebuild or pull the Odoo image. ⚠️\n\
  The script is located at the root of this repository.\n"
  echo -e "     'sudo ./_install.sh'\n"
}

main
