#!/bin/bash

CURRENT_DIRNAME=$(dirname "$(readlink -f "$0")")
cd "$CURRENT_DIRNAME/.." || { echo "🔴 Can't change directory to $CURRENT_DIRNAME/.."; exit 1; }
SERVICE_NAME=$(basename "$(pwd)")
PATH_TO_ODOO="$(pwd)"

TAR_FILE_NAME=snapshot-$SERVICE_NAME.tar.zst
TEMP_DIR=/tmp/snapshot-$SERVICE_NAME

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Start restore utility for $SERVICE_NAME"

if [ "$(id -u)" -ne 0 ]; then
  echo "🔴 This script must be run using sudo." 1>&2
  exit 1
fi

if ! command -v zstd >/dev/null 2>&1; then
  echo "🔴 zstd is not installed. Please install zstd first."
  echo "For Ubuntu: sudo apt install zstd"
  echo "For CentOS: sudo yum install zstd"
  exit 1
fi

if [ ! -f "/tmp/$TAR_FILE_NAME" ]; then
  echo "🔴 /tmp/$TAR_FILE_NAME not found. Please add your snapshot file to /tmp directory."
  exit 1
fi

cd $PATH_TO_ODOO || { echo "🔴 Can't change directory to $PATH_TO_ODOO"; exit 1; }

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Stopping $SERVICE_NAME service"
docker compose down

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Extracting /tmp/$TAR_FILE_NAME to $TEMP_DIR"
mkdir $TEMP_DIR
tar -xaf "/tmp/$TAR_FILE_NAME" -C /tmp/snapshot-$SERVICE_NAME

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring conf/odoo.conf"
cp -f $TEMP_DIR/conf/odoo.conf conf/odoo.conf || { echo "🔴 Can't restore conf/odoo.conf"; }

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring environment file (.env)"
cp -f $TEMP_DIR/.env .env || { echo "🔴 Can't restore .env"; }

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring /etc/nginx/sites-available"
cp -rf $TEMP_DIR/etc/nginx/sites-available /etc/nginx/ || { echo "🔴 Can't restore /etc/nginx/sites-available"; }

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring /etc/nginx/sites-enabled"
NGINX_SITES_AVAILABLE_LIST=$(ls /etc/nginx/sites-available)
for NGINX_SITES_AVAILABLE in $NGINX_SITES_AVAILABLE_LIST; do
  if [ "$NGINX_SITES_AVAILABLE" = "default" ]; then
    continue
  fi
  ln -s /etc/nginx/sites-available/$NGINX_SITES_AVAILABLE /etc/nginx/sites-enabled/$NGINX_SITES_AVAILABLE || continue
done

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring /etc/logrotate.d/$SERVICE_NAME"
cp -f $TEMP_DIR/etc/logrotate.d/$SERVICE_NAME* /etc/logrotate.d/ || { echo "🔴 Can't restore /etc/logrotate.d/$SERVICE_NAME"; }

if [ -f "/etc/logrotate.d/sudo-*" ]; then
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring /etc/logrotate.d/sudo-*"
  cp -f $TEMP_DIR/etc/logrotate.d/sudo-* /etc/logrotate.d/ || { echo "🔴 Can't restore /etc/logrotate.d/sudo-*"; }
fi

if [ -f "/usr/local/sbin/sudo-*" ]; then
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring sudo utilities /usr/local/sbin/sudo-*"
  cp -f $TEMP_DIR/usr/local/sbin/sudo-* /usr/local/sbin/ || { echo "🔴 Can't restore /usr/local/sbin/sudo-*"; }
fi

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring .secrets/db_user"
cp -f $TEMP_DIR/.secrets/db_user .secrets/db_user || { echo "🔴 Can't restore .secrets/db_user"; }

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring .secrets/db_password"
cp -f $TEMP_DIR/.secrets/db_password .secrets/db_password || { echo "🔴 Can't restore .secrets/db_password"; }

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring the snapshot script scripts/snapshot-$SERVICE_NAME"
cp -f $TEMP_DIR/scripts/snapshot-$SERVICE_NAME scripts/snapshot-$SERVICE_NAME || { echo "🔴 Can't restore scripts/snapshot-$SERVICE_NAME"; }

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring requirements.txt"
cp -f $TEMP_DIR/requirements.txt ./requirements.txt || { echo "🔴 Can't restore requirements.txt"; }

ODOO_DATABASE_NAME_PRD=$(ls $TEMP_DIR/var/lib/odoo/$SERVICE_NAME/filestore/ | head -n 1)

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring odoo filestore /var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"
if [ -d /var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD ]; then
  rm -rf /var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD
else
  mkdir -p /var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD
  chown -R odoo: /var/lib/odoo
fi
cp -r $TEMP_DIR/var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD /var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD || { echo "🔴 Can't restore /var/lib/odoo/$SERVICE_NAME/filestore/$ODOO_DATABASE_NAME_PRD"; }

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring database $ODOO_DATABASE_NAME_PRD from $TEMP_DIR/tmp/$ODOO_DATABASE_NAME_PRD.sql"
sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$ODOO_DATABASE_NAME_PRD\""
sudo -u postgres psql -c "CREATE DATABASE \"$ODOO_DATABASE_NAME_PRD\""
sudo -u postgres psql -d $ODOO_DATABASE_NAME_PRD -f $TEMP_DIR/tmp/$ODOO_DATABASE_NAME_PRD.sql

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Restoring Odoo modules without git."
find $TEMP_DIR/git/ -mindepth 1 -maxdepth 1 -type d -exec cp -r {} ./git/ \; || { echo "🔴 Can't restore Odoo modules without git."; }

echo "==========================================================================="

echo -e "\n\n[$(date +"%Y-%m-%d %H:%M:%S")] ⚠️ You need to restore the crontab manually. ⚠️"
echo "[$(date +"%Y-%m-%d %H:%M:%S")] Copying the crontab to the root repository."
cp -rf $TEMP_DIR/crontab ./ || { echo "🔴 Can't restore crontab"; }
echo "[$(date +"%Y-%m-%d %H:%M:%S")] You can do ' sudo crontab -e '  then paste content from crontab file"
echo -e "[$(date +"%Y-%m-%d %H:%M:%S")] Then, you can ' sudo crontab -l ' to make sure that your crontab is installed.\n\n"

echo "==========================================================================="

echo -e "\n\n[$(date +"%Y-%m-%d %H:%M:%S")] This is the git Odoo modules used by the previous snapshot.\n"
cat $TEMP_DIR/git/git_hashes.txt
echo -e "\n[$(date +"%Y-%m-%d %H:%M:%S")] ⚠️ You need to clone these repositories manually into git directory. If you want to rebuild the image. ⚠️\n\n"

echo "==========================================================================="

echo -e "\n\n[$(date +"%Y-%m-%d %H:%M:%S")] This is the odoo-base git hashes used by the previous snapshot.\n"
cat $TEMP_DIR/odoo-base/git_hashes.txt
echo -e "\n[$(date +"%Y-%m-%d %H:%M:%S")] ⚠️ You need to clone these repositories manually into odoo-base directory. If you want to rebuild the image. ⚠️\n\n"

echo "==========================================================================="

echo -e "\n\n[$(date +"%Y-%m-%d %H:%M:%S")] If you ready to turn up your deployment, you can run 'docker compose up -d' to start the service.\n\n"
