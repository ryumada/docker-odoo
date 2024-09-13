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

FAILED_CHECKS=0

if ! command -v docker &>/dev/null; then
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ docker command not found. Please install docker engine by following this docs: https://docs.docker.com/engine/install/"
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
fi

# Check if there are directories inside the git directory
if [ -d "$GIT_DIR" ] && [ "$(ls -A $GIT_DIR)" ]; then
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ Directories exist inside $GIT_DIR"
else
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ No directories found inside $GIT_DIR"
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
fi

# Check if the .env file exists
if [ -f "$ENV_FILE" ]; then
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ .env file exists"
else
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ .env file does not exist"
  FAILED_CHECKS=$((FAILED_CHECKS + 1))

fi

# Check if the odoo-base directory exists
if [ -d "$ODOO_BASE_DIR" ]; then
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ odoo-base directory exists"
else
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ odoo-base directory does not exist"
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
fi

# Check if the requirements.txt file exists
if [ -f "$REQUIREMENTS_FILE" ]; then
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ requirements.txt file exists"
else
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ requirements.txt file does not exist"
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
fi

# Check if the odoo.conf file exists
if [ -f "$ODOO_CONF_FILE" ]; then
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ odoo.conf file exists"
else
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ odoo.conf file does not exist"
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
fi
