#!/bin/bash

# TODO: FIX THIS SCRIPT SEE ENTRYPOINT TO CHECK THE DIRECTORIES INSIDE

# Define the paths
GIT_DIR="./git"
ODOO_BASE_DIR="./odoo-base"
ODOO_CONF_FILE="./conf/odoo.conf"
ODOO_DATADIR="./datadir"
ODOO_LOG_DIR="./log"
DB_PASSWORD_SECRET="./.secrets/db_password"
REQUIREMENTS_FILE="./requirements.txt"
ENV_FILE="./.env"
DOCKER_COMPOSE_FILE="./docker-compose.yml"

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
    return 0
  else
    TODO+=("$todo")

    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ $file file does not exist"
    return 1
  fi
}

function isOdooUserExists() {
  if ! id "odoo" &>/dev/null; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ℹ️  Create a new Odoo user."
    if sudo useradd -m -u 8069 -s /bin/bash odoo; then
      echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ odoo user created."
    else
      echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ Failed to create odoo user."
      exit 1
    fi
  else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ odoo user already exists"
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
    
    return 1
  else
    return 0
  fi
}

function amIRoot() {
  if [ "$EUID" -ne 0 ]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ Please run this script using sudo."
    exit 1
  fi
}

function main() {
  amIRoot

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Path for working directory: $(pwd)/"

  sleep 7
  
  isDockerInstalled

  isOdooUserExists

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Change the ownership of datadir and log dir."
  sudo chown -R odoo: $ODOO_LOG_DIR
  sudo chown -R odoo: $ODOO_DATADIR

  isSubDirectoryExists "$GIT_DIR" "" "No directories found inside $GIT_DIR. That means no Odoo custom module will be added to your Odoo image."
  isSubDirectoryExists "$ODOO_BASE_DIR" "Please clone your odoo-base repository inside the odoo-base directory" ""

  isFileExists "$ENV_FILE" "Please create a .env file by folowing the .env.example file." || true
  isFileExists "$REQUIREMENTS_FILE" "Please create a requirements.txt file by following the requirements.txt.example file." || true
  isFileExists "$DOCKER_COMPOSE_FILE" "Please create a docker-compose.yml file by following the docker-compose.yml.example file." || true
  
  isFileExists "$ODOO_CONF_FILE" "Please create an odoo.conf file by following the odoo.conf.example file." || true
  
  if isFileExists "$DB_PASSWORD_SECRET" "Please create a db_password file by following the db_password.example file."; then
    sudo chmod 600 $DB_PASSWORD_SECRET
    sudo chown -R odoo: $DB_PASSWORD_SECRET
  fi

  if printTodo; then
    echo
    echo
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ Everything is ready to build your docker image."
  else
    echo
    echo
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ There are some things that need to be done before we create your docker image."
  fi
}

main
