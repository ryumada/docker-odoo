#!/bin/bash

# TODO: FIX THIS SCRIPT SEE ENTRYPOINT TO CHECK THE DIRECTORIES INSIDE

# Define the paths
GIT_DIR="./git"
ODOO_BASE_DIR="./odoo-base"
REQUIREMENTS_FILE="./requirements.txt"
ODOO_CONF_FILE="./conf/odoo.conf"
ENV_FILE="./.env"

# Exit immediately if a command exits with a non-zero status
set -e

error_handler() {
  echo "An error occurred on line $1. Exiting..."
  exit 1
}

trap 'error_handler $LINENO' ERR

TODO=()

if ! command -v docker &>/dev/null; then
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ docker command not found."
  TODO+=("Please install docker engine by following this docs: https://docs.docker.com/engine/install/")
else
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ docker command found"
fi

# Check if there are directories inside the git directory
if $(ls -d "$GIT_DIR"/*/ 1> /dev/null 2>&1); then
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ Directories exist inside $GIT_DIR"
else
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ℹ️ No directories found inside $GIT_DIR. That means no Odoo custom module will be added to your Odoo image."
fi

# Check if the odoo-base directory exists
if $(ls -d "$ODOO_BASE_DIR"/*/ 1> /dev/null 2>&1); then
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ directory exists inside $ODOO_BASE_DIR"
else
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ no directories found inside $ODOO_BASE_DIR"
  TODO+=("Please clone your odoo-base repository inside the odoo-base directory")
fi

# Check if the .env file exists
if [ -f "$ENV_FILE" ]; then
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ .env file exists"
else
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ .env file does not exist"
  TODO+=("Please create a .env file by folowing the .env.example file.")
fi

# Check if the requirements.txt file exists
if [ -f "$REQUIREMENTS_FILE" ]; then
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ requirements.txt file exists"
else
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ requirements.txt file does not exist"
  TODO+=("Please create a requirements.txt file by following the requirements.txt.example file.")
fi

# Check if the odoo.conf file exists
if [ -f "$ODOO_CONF_FILE" ]; then
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ odoo.conf file exists"
else
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ odoo.conf file does not exist"
  TODO+=("Please create a odoo.conf file by following the odoo.conf.example file.")
fi

if [[ ${#TODO[@]} -gt 0 ]]; then
  echo
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ There are some things that need to be done before we create your docker image."
  echo
  for i in "${TODO[@]}"; do
    echo "ℹ️  $i"
  done
  echo
  exit 1
else
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ Everything is ready to build your docker image."
fi
