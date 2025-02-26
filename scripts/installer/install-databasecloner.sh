#!/bin/bash

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

  echo "$(getDate) 🚀 Installing databasecloner utility"

  echo "$(getDate) 📎 Copying the latest script from the example script"
  OUTPUT_RSYNC_COMMAND=$(rsync -acz ./scripts/example/databasecloner.sh.example "./scripts/databasecloner-$SERVICE_NAME" 2>&1) && {
    echo "$(getDate) ✅ Copy the latest script from the example script."
  } || {
    echo "$(getDate) ❌ Failed to copy the latest script from the example script ➡️ $OUTPUT_RSYNC_COMMAND"
    exit 1
  }

  echo "$(getDate) 👤 Changing the permission of the script"
  chmod 755 "./scripts/databasecloner-$SERVICE_NAME"

  echo "$(getDate) 🖇️ Create a softlink to /usr/local/sbin"
  OUTPUT_LN_COMMAND=$(ln -s "$PATH_TO_ODOO/scripts/databasecloner-$SERVICE_NAME" /usr/local/sbin/databasecloner-"$SERVICE_NAME" 2>&1) && {
    echo "$(getDate) ✅ Create a symbolic link to /usr/local/sbin/databasecloner-$SERVICE_NAME"
  } || {
    echo "$(getDate) ⚠️ Failed to create a symbolic link to /usr/local/sbin/databasecloner-$SERVICE_NAME ➡️ $OUTPUT_LN_COMMAND"
  }
}

main
