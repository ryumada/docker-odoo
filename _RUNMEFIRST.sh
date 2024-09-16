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

# Global Variable
TODO=()

function isDockerInstalled() {
  if ! command -v docker &>/dev/null; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ docker command not found."
    TODO+=("Please install docker engine by following this docs: https://docs.docker.com/engine/install/")
  else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ docker command found"
  fi
}

function isSubDirectoryExists() {
  dir=$1
  todo=$2
  additional_info=$3

  if ls -d "$dir"/*/ >/dev/null 2>&1; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ A directory exists inside $dir"
  else
    if [ -n "$todo" ]; then
      TODO+=("$todo")
    fi

    if [ -n "$additional_info" ]; then
      echo "[$(date +"%Y-%m-%d %H:%M:%S")] ℹ️  $additional_info"
    else
      echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ No directory found inside $dir"
    fi
  fi
}

function isFileExists() {
  file=$1
  todo=$2

  if [ -f "$file" ]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ $file file exists"
  else
    TODO+=("$todo")

    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ $file file does not exist"
  fi
}

function printTodo() {
  if [[ ${#TODO[@]} -gt 0 ]]; then
    echo
    echo "There are ${#TODO[@]} items need to be done."
    echo
    for i in "${TODO[@]}"; do
      echo "ℹ️  $i"
    done
    echo
    
    return 1
  else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ Everything is ready to build your docker image."

    return 0
  fi
}

function main() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Path for working directory: $(pwd)/"

  sleep 7
  
  isDockerInstalled

  isSubDirectoryExists "$GIT_DIR" "" "No directories found inside $GIT_DIR. That means no Odoo custom module will be added to your Odoo image."
  isSubDirectoryExists "$ODOO_BASE_DIR" "Please clone your odoo-base repository inside the odoo-base directory" ""

  isFileExists "$ENV_FILE" "Please create a .env file by folowing the .env.example file."
  isFileExists "$REQUIREMENTS_FILE" "Please create a requirements.txt file by following the requirements.txt.example file."
  isFileExists "$ODOO_CONF_FILE" "Please create a odoo.conf file by following the odoo.conf.example file."

  if printTodo; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ Everything is ready to build your docker image."
  else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ There are some things that need to be done before we create your docker image."
  fi
}

main
