#!/bin/bash

# This script will upgrade and install snapshot utility from the example script.

# Exit immediately if a command exits with a non-zero status
set -e

error_handler() {
  echo "An error occurred on line $1. Exiting..."
  exit 1
}

trap 'error_handler $LINENO' ERR

function amIRoot() {
  if [ "$EUID" -ne 0 ]; then
    echo "$(getDate) ❌ Please run this script using sudo."
    exit 1
  fi
}

function getDate() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")]"
}

function main() {
  CURRENT_DIR=$(dirname "$(readlink -f "$0")")
  CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
  PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
  SERVICE_NAME=$(basename "$PATH_TO_ODOO")
  # REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

  amIRoot
  cd "$PATH_TO_ODOO" || exit 1

  GCS_BUCKET_NAME=$(awk -F "=" '/GCS_BUCKET_NAME/ {gsub(/^ +/, "", $2); print $2}' "$PATH_TO_ODOO/.env")

  echo "$(getDate) 🚀 Installing snapshot utility"

  echo "$(getDate) 📎 Copying the latest script from the example"
  rsync -acz ./scripts/example/snapshot.sh.example "./scripts/snapshot-$SERVICE_NAME" > /dev/null  && {
    echo "$(getDate) ✅ Copy the latest script from the example script."
  } || {
    echo "$(getDate) ❌ Failed to copy the latest script from the example script."
    exit 1
  }

  echo "$(getDate) 🖇️ Create a softlink to /usr/local/sbin"
  ln -s "$PATH_TO_ODOO/scripts/snapshot-$SERVICE_NAME" /usr/local/sbin/snapshot-"$SERVICE_NAME" && {
    echo "$(getDate) ✅ Create a symbolic link to /usr/local/sbin/snapshot-$SERVICE_NAME"
  } || {
    echo "$(getDate) ⚠️ Failed to create a symbolic link to /usr/local/sbin/snapshot-$SERVICE_NAME. It may be already exists."
  }

  if [ -z "$GCS_BUCKET_NAME" ]; then
    echo "$(getDate) ⚠️ GCS_BUCKET_NAME is not set in the .env file. The snapshot will not run automatically."
  else
    echo "$(getDate) ⏱️ Create a cron to run automatically the snapshot script."
    cat << EOF > ~/snapshot-$SERVICE_NAME
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

27 */4 * * * root "/usr/local/sbin/snapshot-$SERVICE_NAME"

EOF

    echo "$(getDate) 📝 Move the cron file to /etc/cron.d"
    sudo mv ~/snapshot-$SERVICE_NAME /etc/cron.d/snapshot-$SERVICE_NAME
    echo "$(getDate) 👤 Change the ownership of the snapshot file"
    sudo chown root: /etc/cron.d/snapshot-$SERVICE_NAME
    echo "$(getDate) 🔒 Change the permission of the snapshot file"
    sudo chmod 644 /etc/cron.d/snapshot-$SERVICE_NAME
    echo "$(getDate) 🔄️ Restart the cron service"
    sudo systemctl restart cron
  fi

  if zstd --version > /dev/null 2>&1; then
    echo "$(getDate) ✅ zstd is already installed"
  else
    echo "$(getDate) 📦 Install zstd"
    sudo apt install zstd -y && {
      echo "$(getDate) ✅ zstd is installed"
    } || {
      echo "$(getDate) 🔴 Failed to install zstd"
      exit 1
    }
  fi

  echo "$(getDate) ⚒️ Install the logrotate utility"
  sudo cat << EOF > ~/snapshot-$SERVICE_NAME
/var/log/odoo/_utilities/snapshot-$SERVICE_NAME.log {
    rotate 4
    su root syslog
    olddir /var/log/odoo/_utilities/snapshot-$SERVICE_NAME.log-old
    weekly
    missingok
    #notifempty
    nocreate
    createolddir 775 odoo root
    renamecopy
    compress
    compresscmd /usr/bin/zstd
    compressoptions -7T0
    delaycompress
    dateext
    dateformat -%Y%m%d-%H%M%S
}

EOF

  echo "$(getDate) 👤 Change the ownership of the logrotate file"
  sudo chown root: ~/snapshot-$SERVICE_NAME
  echo "$(getDate) 🔒 Change the permission of the logrotate file"
  sudo chmod 644 ~/snapshot-$SERVICE_NAME
  echo "$(getDate) 📝 Move the logrotate file to /etc/logrotate.d"
  sudo mv ~/snapshot-$SERVICE_NAME /etc/logrotate.d/snapshot-$SERVICE_NAME

  echo "$(getDate) ✅ Installation finished"
}

main
