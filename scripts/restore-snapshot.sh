#!/bin/bash

CURRENT_DIRNAME=$(dirname "$(readlink -f "$0")")
cd "$CURRENT_DIRNAME/.." || { echo "🔴 Can't change directory to $CURRENT_DIRNAME/.."; exit 1; }
SERVICE_NAME=$(basename "$(pwd)")
PATH_TO_ODOO="$(pwd)"
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

TAR_FILE_NAME=snapshot-$SERVICE_NAME.tar.zst
TEMP_DIR=/tmp/snapshot-$SERVICE_NAME

function amIRoot() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "🔴 This script must be run as root."
    exit 1
  fi
}
function areYouReallySure() {
  echo -e "Are you sure?\n⚠️ This script will replace your current Odoo data and deployment files. ⚠️\n"
  read -rep "Type 'yes I am sure': " response
  case "$response" in
  "yes I am sure")
    return 0
    ;;
  *)
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
    echo "🔴 /tmp/$TAR_FILE_NAME not found. Please add your snapshot file to /tmp directory. Or create your snapshot using snapshot script."
    exit 1
  fi
}

function isZstdInstalled() {
  if ! command -v zstd >/dev/null 2>&1; then
    echo "🔴 zstd is not installed. Please install zstd first."
    echo "For Ubuntu: sudo apt install zstd"
    echo "For CentOS: sudo yum install zstd"
    exit 1
  fi
}

function restoreDBCredentials() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring .secrets/db_user"
  cp -f "$TEMP_DIR/.secrets/db_user" .secrets/db_user || { echo "🔴 Can't restore .secrets/db_user"; }
  chown odoo: .secrets/db_user
  chmod 400 .secrets/db_user

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring .secrets/db_password"
  cp -f "$TEMP_DIR/.secrets/db_password" .secrets/db_password || { echo "🔴 Can't restore .secrets/db_password"; }
  chown odoo: .secrets/db_password
  chmod 400 .secrets/db_password
}

function restoreNginxConfig() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring /etc/nginx/sites-available"
  cp -rf "$TEMP_DIR/etc/nginx/sites-available" /etc/nginx/ || { echo "🔴 Can't restore /etc/nginx/sites-available"; }

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring /etc/nginx/sites-enabled"
  NGINX_SITES_AVAILABLE_LIST=$(ls /etc/nginx/sites-available)
  for NGINX_SITES_AVAILABLE in $NGINX_SITES_AVAILABLE_LIST; do
    if [ "$NGINX_SITES_AVAILABLE" = "default" ]; then
      continue
    fi
    ln -s "/etc/nginx/sites-available/$NGINX_SITES_AVAILABLE" "/etc/nginx/sites-enabled/$NGINX_SITES_AVAILABLE" || continue
  done
}

function restoreOdooData() {
  ODOO_DATABASE_NAME_PRD=$(find "$TEMP_DIR/var/lib/odoo/$SERVICE_NAME/filestore/" -mindepth 1 -maxdepth 1 -type d -print | head -n 1 | xargs -n 1 basename)
  ODOO_DATABASE_USER=$(cat "$PATH_TO_ODOO/.secrets/db_user")

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring odoo filestore /var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"
  if [ -d "/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD" ]; then
    rm -rf "/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"
  else
    mkdir -p "/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"
  fi
  cp -r "$TEMP_DIR/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD" "/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD" || { echo "🔴 Can't restore /var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"; }
  chown -R odoo: "/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring database $ODOO_DATABASE_NAME_PRD from $TEMP_DIR/tmp/$ODOO_DATABASE_NAME_PRD.sql"
  sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$ODOO_DATABASE_NAME_PRD\""
  sudo -u postgres psql -c "CREATE DATABASE \"$ODOO_DATABASE_NAME_PRD\""
  sudo -u postgres psql -d "$ODOO_DATABASE_NAME_PRD" -f "$TEMP_DIR/tmp/$ODOO_DATABASE_NAME_PRD.sql" -q

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Change the owner of the database."
  sudo -u postgres psql -c "ALTER DATABASE \"$ODOO_DATABASE_NAME_PRD\" OWNER TO \"$ODOO_DATABASE_USER\"";
  sudo -u postgres psql -d "$ODOO_DATABASE_NAME_PRD" -c "
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
  "
}

function main() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Start restore utility for $SERVICE_NAME"

  amIRoot
  areYouReallySure
  isZstdInstalled
  isSnapshotFileExist

  cd "$PATH_TO_ODOO" || { echo "🔴 Can't change directory to $PATH_TO_ODOO"; exit 1; }

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Stopping $SERVICE_NAME service"
  docker compose down

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Extracting /tmp/$TAR_FILE_NAME to $TEMP_DIR"
  mkdir "$TEMP_DIR"
  tar -xaf "/tmp/$TAR_FILE_NAME" -C "/tmp/snapshot-$SERVICE_NAME"

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring conf/odoo.conf"
  cp -f "$TEMP_DIR/conf/odoo.conf" "conf/odoo.conf" || { echo "🔴 Can't restore conf/odoo.conf"; }
  chown "$REPOSITORY_OWNER": "conf/odoo.conf"

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring environment file (.env)"
  cp -f "$TEMP_DIR/.env" .env || { echo "🔴 Can't restore .env"; }
  chown "$REPOSITORY_OWNER": .env

  restoreNginxConfig

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring /etc/logrotate.d/$SERVICE_NAME"
  cp -f "$TEMP_DIR/etc/logrotate.d/$SERVICE_NAME*" /etc/logrotate.d/ || { echo "🔴 Can't restore /etc/logrotate.d/$SERVICE_NAME"; }

  if [ -f "/etc/logrotate.d/sudo-*" ]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring /etc/logrotate.d/sudo-*"
    cp -f "$TEMP_DIR/etc/logrotate.d/sudo-*" /etc/logrotate.d/ || { echo "🔴 Can't restore /etc/logrotate.d/sudo-*"; }
  fi

  if [ -f "/usr/local/sbin/sudo-*" ]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring sudo utilities /usr/local/sbin/sudo-*"
    cp -f "$TEMP_DIR/usr/local/sbin/sudo-*" /usr/local/sbin/ || { echo "🔴 Can't restore /usr/local/sbin/sudo-*"; }
  fi

  restoreDBCredentials

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring the snapshot script scripts/snapshot-$SERVICE_NAME"
  cp -f "$TEMP_DIR/scripts/snapshot-$SERVICE_NAME" "scripts/snapshot-$SERVICE_NAME" || { echo "🔴 Can't restore scripts/snapshot-$SERVICE_NAME"; }
  ln -s "$PATH_TO_ODOO/scripts/snapshot-$SERVICE_NAME" /usr/local/sbin/snapshot-$SERVICE_NAME || { echo "🔴 Can't create symlink for /usr/local/sbin/snapshot-$SERVICE_NAME"; }
  chown "$REPOSITORY_OWNER": "scripts/snapshot-$SERVICE_NAME"

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring requirements.txt"
  cp -f "$TEMP_DIR/requirements.txt" ./requirements.txt || { echo "🔴 Can't restore requirements.txt"; }
  chown "$REPOSITORY_OWNER": ./requirements.txt

  restoreOdooData

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring Odoo modules without git."
  find "$TEMP_DIR/git/" -mindepth 1 -maxdepth 1 -type d -exec cp -r {} ./git/ \; || { echo "🔴 Can't restore Odoo modules without git."; }
  chown -R "$REPOSITORY_OWNER": ./git/

  echo -e "\n==========================================================================="

  echo -e "\n[$(date +"%Y-%m-%d %H:%M:%S")] ⚠️ You need to restore the crontab manually. ⚠️"
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Copying the crontab to the root repository."
  cp -rf "$TEMP_DIR/crontab" ./ || { echo "🔴 Can't restore crontab"; }
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] You can do 'sudo crontab -e'  then paste content from crontab file"
  echo -e "[$(date +"%Y-%m-%d %H:%M:%S")] Then, you can 'sudo crontab -l' to make sure that your crontab is installed.\n"

  echo "==========================================================================="

  echo -e "\n[$(date +"%Y-%m-%d %H:%M:%S")] git Odoo modules used by the previous snapshot.\n"
  cat "$TEMP_DIR/git/git_hashes.txt"
  echo -e "\n[$(date +"%Y-%m-%d %H:%M:%S")] ⚠️ You need to clone these repositories manually into git directory. If you want to rebuild the image. ⚠️\n"

  echo "==========================================================================="

  echo -e "\n[$(date +"%Y-%m-%d %H:%M:%S")] odoo-base git hashes used by the previous snapshot.\n"
  cat "$TEMP_DIR/odoo-base/git_hashes.txt"
  echo -e "\n[$(date +"%Y-%m-%d %H:%M:%S")] ⚠️ You need to clone these repositories manually into odoo-base directory. If you want to rebuild the image. ⚠️\n"

  echo "==========================================================================="

  cleanup
  
  echo -e "[$(date +"%Y-%m-%d %H:%M:%S")] ⚠️ You need to run the following command to rebuild the Odoo image. ⚠️"
  echo -e "     'sudo ./_RUNMEFIRST.sh'\n"
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] If you are ready to turn up your deployment, can run this command:"
  echo -e "     'sudo docker compose up -d'\n"
}

main
