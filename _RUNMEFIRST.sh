#!/bin/bash

CURRENT_DIRNAME="$(basename "$(pwd)")"
SERVICE_NAME=$CURRENT_DIRNAME
ODOO_LINUX_USER="odoo"

# Define the paths
DB_USER_SECRET="./.secrets/db_user"
DB_PASSWORD_SECRET="./.secrets/db_password"
DOCKER_COMPOSE_FILE="./docker-compose.yml"
ENV_FILE="./.env"
GIT_DIR="./git"
ODOO_BASE_DIR="./odoo-base"
ODOO_CONF_FILE="./conf/odoo.conf"
ODOO_DATADIR="/var/lib/odoo"
ODOO_DATADIR_SERVICE="$ODOO_DATADIR/$SERVICE_NAME"
ODOO_LOG_DIR="/var/log/odoo"
ODOO_LOG_DIR_SERVICE="$ODOO_LOG_DIR/$SERVICE_NAME"
REQUIREMENTS_FILE="./requirements.txt"

# Exit immediately if a command exits with a non-zero status
set -e

error_handler() {
  echo "An error occurred on line $1. Exiting..."
  exit 1
}

trap 'error_handler $LINENO' ERR

# Global Variable
TODO=()

function amIRoot() {
  if [ "$EUID" -ne 0 ]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ Please run this script using sudo."
    exit 1
  fi
}

function createDataDir() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Create Odoo datadir..."

  if [ ! -d "$ODOO_DATADIR" ]; then
    sudo mkdir "$ODOO_DATADIR"
    sudo chown $ODOO_LINUX_USER: $ODOO_DATADIR
  fi

  if [ ! -d "$ODOO_DATADIR_SERVICE" ]; then
    sudo mkdir "$ODOO_DATADIR_SERVICE"
    sudo chown $ODOO_LINUX_USER: "$ODOO_DATADIR_SERVICE"
  fi

  writeDatadirVariableOnEnvFile
}

function createLogDir() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Create log directories..."

  if [ ! -d "$ODOO_LOG_DIR" ]; then
    sudo mkdir $ODOO_LOG_DIR
    sudo chown $ODOO_LINUX_USER: $ODOO_LOG_DIR
  fi

  if [ ! -d "$ODOO_LOG_DIR_SERVICE" ]; then
    sudo mkdir "$ODOO_LOG_DIR_SERVICE"
    sudo chown $ODOO_LINUX_USER: "$ODOO_LOG_DIR_SERVICE"
  fi

  writeLogDirVariableOnEnvFile
  installOdooLogRotator
}

function getGitHash() {
  # _inherit = writeGitHash

  git_path=$1

  OUTPUT_GIT_HASHES_FILE="$git_path/../git_hashes.txt"

  cat <<EOF >> "$OUTPUT_GIT_HASHES_FILE"
  Updated at $(date +"%Y-%m-%d %H:%M:%S")
  
  Git Directory: $git_path
  Git Remote: $(git -C "$git_path" remote get-url origin)
  Git Branch: $(git -C "$git_path" branch --show-current)
  Git Hashes: $(git -C "$git_path" rev-parse HEAD)
EOF
}

function getSubDirectories() {
  dir=$1
  subdirs="$(ls -d "$dir"/*/)"
  echo "$subdirs"
}

function installOdooLogRotator() {
  # _inherit = createLogDir

  log_filename="$ODOO_LOG_DIR_SERVICE/$SERVICE_NAME.log"
  
  cat <<-EOF > ~/"$SERVICE_NAME"
$log_filename {
    rotate 14
    olddir $log_filename-old
    su $ODOO_LINUX_USER $ODOO_LINUX_USER
    daily
    missingok
    #notifempty
    nocreate
    createolddir 755 $ODOO_LINUX_USER $ODOO_LINUX_USER
    renamecopy
    compress
    compresscmd /usr/bin/xz
    compressoptions -ze -T 4
    delaycompress
    dateext
    dateformat -%Y%m%d-%H%M%S
}
EOF

  sudo chown root: ~/"$SERVICE_NAME"
  sudo chmod 644 ~/"$SERVICE_NAME"

  sudo mv ~/"$SERVICE_NAME" "/etc/logrotate.d/$SERVICE_NAME"
}

function isDirectoryGitRepository {
  dir=$1

  if [ -d "$dir/.git" ]; then
    if git rev-parse --is-inside-work-tree &>/dev/null; then
      return 0
    else
      return 1
    fi
  else
    return 1
  fi  
}

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
    return 0
  else
    if [ -n "$todo" ]; then
      TODO+=("$todo")
    fi

    if [ -n "$additional_info" ]; then
      echo "[$(date +"%Y-%m-%d %H:%M:%S")] ℹ️  $additional_info"
    else
      echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ No directory found inside $dir"
    fi

    return 1
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

function resetGitHashFile(){
  # _inherit = writeGitHash

  git_path=$1
  OUTPUT_GIT_HASHES_FILE="$git_path/../git_hashes.txt"

  cat <<EOF > "$OUTPUT_GIT_HASHES_FILE"
  
EOF
}

function writeGitHash() {
  dir=$1
  subdirs="$(getSubDirectories "$dir")"

  flag=0
  for dir in $subdirs; do
    
    if [ $flag -eq 0 ]; then
      resetGitHashFile "$dir"
      flag=1
    fi

    if isDirectoryGitRepository "$dir"; then
      getGitHash "$dir"
    else
      echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ $dir is not a git repository. You need to backup this directory."      
    fi
  done
}

function writeDatadirVariableOnEnvFile() {
  # _inherit = CreateDataDir

  if ! grep -q "ODOO_DATADIR_SERVICE" "$ENV_FILE"; then
    cat <<-EOF >> "$ENV_FILE"
ODOO_DATADIR_SERVICE=$ODOO_DATADIR_SERVICE
EOF
  fi
}

function writeLogDirVariableOnEnvFile() {
  # _inherit = createLogDir

  if ! grep -q "SERVICE_NAME" "$ENV_FILE"; then
    cat <<-EOF >> "$ENV_FILE"

# # # # # # # # # # # # #
# DIRECTORIES           #
# # # # # # # # # # # # #
SERVICE_NAME=$SERVICE_NAME
ODOO_LOG_DIR_SERVICE=$ODOO_LOG_DIR_SERVICE
EOF
  fi
}

function main() {
  amIRoot

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Path for working directory: $(pwd)/"
  sleep 7
  
  isDockerInstalled
  isOdooUserExists

  if isFileExists "$DB_USER_SECRET" "Please create a db_user file by following the db_user.example file."; then
    sudo chmod 400 $DB_USER_SECRET
    sudo chown -R $ODOO_LINUX_USER: $DB_USER_SECRET
  fi

  if isFileExists "$DB_PASSWORD_SECRET" "Please create a db_password file by following the db_password.example file."; then
    sudo chmod 400 $DB_PASSWORD_SECRET
    sudo chown -R $ODOO_LINUX_USER: $DB_PASSWORD_SECRET
  fi

  if isFileExists "$ENV_FILE" "Please create a .env file by folowing the .env.example file."; then
    createLogDir
    createDataDir
  fi
  
  isFileExists "$DOCKER_COMPOSE_FILE" "Please create a docker-compose.yml file by following the docker-compose.yml.example file." || true

  isFileExists "$ODOO_CONF_FILE" "Please create an odoo.conf file by following the odoo.conf.example file." || true

  if isSubDirectoryExists "$GIT_DIR" "" "No directories found inside $GIT_DIR. That means no Odoo custom module will be added to your Odoo image."; then
    writeGitHash "$GIT_DIR"
  fi

  if isSubDirectoryExists "$ODOO_BASE_DIR" "Please clone your odoo-base repository inside the odoo-base directory" ""; then
    writeGitHash "$ODOO_BASE_DIR"
  fi

  isFileExists "$REQUIREMENTS_FILE" "Please create a requirements.txt file by following the requirements.txt.example file." || true

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
