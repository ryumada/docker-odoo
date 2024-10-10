#!/bin/bash

PATH_TO_ODOO=$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

TAR_FILE_NAME=snapshot-$SERVICE_NAME.tar.zst
TEMP_DIR=/tmp/snapshot-$SERVICE_NAME

function amIRoot() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 This script must be run as root."
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
    echo -e "\n"
    exit 1;
    ;;
  esac
}

function cleanup() {
  echo -e "\n\n[$(date +"%Y-%m-%d %H:%M:%S")] 🧹 Cleanup the temporary directory.\n"
  rm -rf "$TEMP_DIR"
}

function isSnapshotFileExist() {
  if [ ! -f "/tmp/$TAR_FILE_NAME" ]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 /tmp/$TAR_FILE_NAME not found. Please add your snapshot file to /tmp directory. Or create your snapshot using snapshot script."
    exit 1
  fi
}

function isZstdInstalled() {
  if ! command -v zstd >/dev/null 2>&1; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 zstd is not installed. Please install zstd first."
    echo "For Ubuntu: sudo apt install zstd"
    echo "For CentOS: sudo yum install zstd"
    exit 1
  fi
}

function restoreDBCredentials() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restore .secrets/db_user"
  cp -f "$TEMP_DIR/.secrets/db_user" .secrets/db_user || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't restore .secrets/db_user"; }
  chown odoo: .secrets/db_user
  chmod 400 .secrets/db_user

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restore .secrets/db_password"
  cp -f "$TEMP_DIR/.secrets/db_password" .secrets/db_password || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't restore .secrets/db_password"; }
  chown odoo: .secrets/db_password
  chmod 400 .secrets/db_password
}

function restoreNginxConfig() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restore /etc/nginx/sites-available"
  cp -rf "$TEMP_DIR/etc/nginx/sites-available" /etc/nginx/ || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't restore /etc/nginx/sites-available"; }

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restore /etc/nginx/sites-enabled"
  NGINX_SITES_AVAILABLE_LIST=$(ls /etc/nginx/sites-available)
  for NGINX_SITES_AVAILABLE in $NGINX_SITES_AVAILABLE_LIST; do
    if [ "$NGINX_SITES_AVAILABLE" = "default" ]; then
      continue
    fi
    ln -s "/etc/nginx/sites-available/$NGINX_SITES_AVAILABLE" "/etc/nginx/sites-enabled/$NGINX_SITES_AVAILABLE" > /dev/null 2>&1 || true
  done
}

function restoreOdooData() {
  ODOO_DATABASE_NAME_PRD=$(find "$TEMP_DIR/var/lib/odoo/$SERVICE_NAME/filestore/" -mindepth 1 -maxdepth 1 -type d -print | head -n 1 | xargs -n 1 basename)
  ODOO_DATABASE_USER=$(cat "$PATH_TO_ODOO/.secrets/db_user")

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restore odoo filestore /var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"
  if [ -d "/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD" ]; then
    rm -rf "/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"
  else
    mkdir -p "/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"
  fi
  cp -r "$TEMP_DIR/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD" "/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD" || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't restore /var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"; }
  chown -R odoo: "/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restore database $ODOO_DATABASE_NAME_PRD from $TEMP_DIR/tmp/$ODOO_DATABASE_NAME_PRD.sql"
  sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$ODOO_DATABASE_NAME_PRD\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't drop database $ODOO_DATABASE_NAME_PRD"
  sudo -u postgres psql -c "CREATE DATABASE \"$ODOO_DATABASE_NAME_PRD\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't create database $ODOO_DATABASE_NAME_PRD"
  sudo -u postgres psql -d "$ODOO_DATABASE_NAME_PRD" -f "$TEMP_DIR/tmp/$ODOO_DATABASE_NAME_PRD.sql" --quiet -t -P pager=off 2> /dev/null > /dev/null || echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't restore database $ODOO_DATABASE_NAME_PRD"

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Change the owner of the database."
  sudo -u postgres psql -c "ALTER DATABASE \"$ODOO_DATABASE_NAME_PRD\" OWNER TO \"$ODOO_DATABASE_USER\"" --quiet -t -P pager=off 2> /dev/null > /dev/null || echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't change the owner of the database $ODOO_DATABASE_NAME_PRD"
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
  " 2> /dev/null > /dev/null || echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't change the owner of the tables, sequences, and views of the database $ODOO_DATABASE_NAME_PRD"
}

function main() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Start restore utility for $SERVICE_NAME"

  amIRoot
  areYouReallySure
  isZstdInstalled
  isSnapshotFileExist

  cd "$PATH_TO_ODOO" || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't change directory to $PATH_TO_ODOO"; exit 1; }

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Extract /tmp/$TAR_FILE_NAME to $TEMP_DIR"
  mkdir "$TEMP_DIR" || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't create $TEMP_DIR". Maybe the directory exist.; exit 1; }
  tar -xaf "/tmp/$TAR_FILE_NAME" -C "/tmp/snapshot-$SERVICE_NAME" || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't extract /tmp/$TAR_FILE_NAME"; exit 1; }

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restore conf/odoo.conf"
  cp -f "$TEMP_DIR/conf/odoo.conf" "conf/odoo.conf" || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't restore conf/odoo.conf"; }
  chown "$REPOSITORY_OWNER": "conf/odoo.conf"

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restore environment file (.env)"
  cp -f "$TEMP_DIR/.env" .env || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't restore .env"; }
  chown "$REPOSITORY_OWNER": .env

  restoreNginxConfig

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restore /etc/logrotate.d/$SERVICE_NAME"
  cp $TEMP_DIR/etc/logrotate.d/$SERVICE_NAME* /etc/logrotate.d/ || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't restore /etc/logrotate.d/$SERVICE_NAME"; }

  if [ -f "/etc/logrotate.d/sudo-*" ]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restore /etc/logrotate.d/sudo-*"
    cp -f $TEMP_DIR/etc/logrotate.d/sudo-* /etc/logrotate.d/ || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't restore /etc/logrotate.d/sudo-*"; }
  fi

  if [ -f "/usr/local/sbin/sudo-*" ]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restore sudo utilities /usr/local/sbin/sudo-*"
    cp -f $TEMP_DIR/usr/local/sbin/sudo-* /usr/local/sbin/ || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't restore /usr/local/sbin/sudo-*"; }
  fi

  restoreDBCredentials

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Stop $SERVICE_NAME service"
  docker compose down > /dev/null 2>&1 || true

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restore the snapshot script scripts/snapshot-$SERVICE_NAME"
  cp -f "$TEMP_DIR/scripts/snapshot-$SERVICE_NAME" "scripts/snapshot-$SERVICE_NAME" || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't restore scripts/snapshot-$SERVICE_NAME"; }
  ln -s "$PATH_TO_ODOO/scripts/snapshot-$SERVICE_NAME" /usr/local/sbin/snapshot-$SERVICE_NAME > /dev/null 2>&1 || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't create symlink for snapshot-$SERVICE_NAME. Maybe the symlink is exist."; }
  chown "$REPOSITORY_OWNER": "scripts/snapshot-$SERVICE_NAME"

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restore requirements.txt"
  cp -f "$TEMP_DIR/requirements.txt" ./requirements.txt || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't restore requirements.txt"; }
  chown "$REPOSITORY_OWNER": ./requirements.txt

  restoreOdooData

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restore Odoo modules without git."
  find "$TEMP_DIR/git/" -mindepth 1 -maxdepth 1 -type d -exec cp -r {} ./git/ \; || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't restore Odoo modules without git."; }
  chown -R "$REPOSITORY_OWNER": ./git/

  echo -e "\n==========================================================================="

  echo -e "\n[$(date +"%Y-%m-%d %H:%M:%S")] ⚠️ You need to restore the crontab manually. ⚠️"
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Copy the crontab to the $PATH_TO_ODOO directory."
  cp -rf "$TEMP_DIR/crontab" ./ || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Can't restore crontab"; }
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] You can do 'sudo crontab -e'  then paste content from crontab file"
  echo -e "[$(date +"%Y-%m-%d %H:%M:%S")] Then, you can 'sudo crontab -l' to make sure that your crontab is installed.\n"

  echo "==========================================================================="

  echo -e "\n[$(date +"%Y-%m-%d %H:%M:%S")] git Odoo modules used by the previous snapshot."
  echo -e "[$(date +"%Y-%m-%d %H:%M:%S")] ⚠️ You need to clone these repositories manually into git directory. If you want to rebuild the image. ⚠️\n"
  cat "$TEMP_DIR/git/git_hashes.txt"

  echo -e "\n==========================================================================="

  echo -e "\n[$(date +"%Y-%m-%d %H:%M:%S")] odoo-base git hashes used by the previous snapshot."
  echo -e "[$(date +"%Y-%m-%d %H:%M:%S")] ⚠️ You need to clone these repositories manually into git directory. If you want to rebuild the image. ⚠️\n"
  cat "$TEMP_DIR/odoo-base/git_hashes.txt"

  echo -e "\n==========================================================================="

  cleanup
  
  echo -e "[$(date +"%Y-%m-%d %H:%M:%S")] ⚠️ You need to run the following command then follow the instruction whether you want to rebuild or pull the Odoo image. ⚠️\n\
  The script is located at the root of this repository.\n"
  echo -e "     'sudo ./_RUNMEFIRST.sh'\n"
}

main
