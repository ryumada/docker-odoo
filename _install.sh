#!/bin/bash

REPOSITORY_DIRPATH="$(pwd)"
REPOSITORY_DIRNAME="$(basename "$(pwd)")"
SERVICE_NAME=$REPOSITORY_DIRNAME
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
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🟦 Create Odoo datadir... (path: $ODOO_DATADIR_SERVICE)"

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
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🟦 Create log directory... (path: $ODOO_LOG_DIR_SERVICE)"

  if [ ! -d "$ODOO_LOG_DIR" ]; then
    sudo mkdir $ODOO_LOG_DIR
    sudo chown $ODOO_LINUX_USER: $ODOO_LOG_DIR
  fi

  if [ ! -d "$ODOO_LOG_DIR_SERVICE" ]; then
    sudo mkdir "$ODOO_LOG_DIR_SERVICE"
    sudo chown $ODOO_LINUX_USER: "$ODOO_LOG_DIR_SERVICE"
  fi

  if [ ! -d "$ODOO_LOG_DIR/_utilities" ]; then
    sudo mkdir "$ODOO_LOG_DIR/_utilities"
  fi

  writeLogDirVariableOnEnvFile
  installOdooLogRotator
}

function generatePostgresPassword() {
  # _inherit = generatePostgresSecrets

  postgresusername=$1

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🟦 Regenerate Postgres password..."

  POSTGRES_ODOO_PASSWORD=$(openssl rand -base64 64 | tr -d '\n')

  sudo -u postgres psql -c "ALTER ROLE \"$postgresusername\" WITH PASSWORD '$POSTGRES_ODOO_PASSWORD';" > /dev/null 2>&1

  writeTextFile "$POSTGRES_ODOO_PASSWORD" "$DB_PASSWORD_SECRET" "password"
}

function generatePostgresSecrets() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🟦 Generate Postgres secrets..."

  POSTGRES_ODOO_USERNAME=$SERVICE_NAME

  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$POSTGRES_ODOO_USERNAME'" 2>/dev/null | grep -q 1; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ User $POSTGRES_ODOO_USERNAME already exists."
  else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🟦 User $POSTGRES_ODOO_USERNAME doesn't exist. Creating the user..."
    sudo -u postgres psql -c "CREATE ROLE \"$POSTGRES_ODOO_USERNAME\" LOGIN CREATEDB;" > /dev/null 2>&1
    writeTextFile "$POSTGRES_ODOO_USERNAME" "$DB_USER_SECRET" "username"
  fi

  generatePostgresPassword "$POSTGRES_ODOO_USERNAME"
}

function getGitHash() {
  # _inherit = writeGitHash

  git_path=$1
  git_real_owner=$(stat -c '%U' "$git_path")
  repository_owner=$(stat -c '%U' "$REPOSITORY_DIRPATH")

  chown -R "$repository_owner": "$git_path"

  OUTPUT_GIT_HASHES_FILE="$git_path/../git_hashes.txt"

  cat <<EOF >> "$OUTPUT_GIT_HASHES_FILE"
  Updated at $(date +"%Y-%m-%d %H:%M:%S")
  
  Git Directory: $git_path
  Git Remote: $(git -C "$git_path" remote get-url origin)
  Git Branch: $(git -C "$git_path" branch --show-current)
  Git Hashes: $(git -C "$git_path" rev-parse HEAD)
EOF

  chown -R "$git_real_owner": "$git_path"
}

function getSubDirectories() {
  dir=$1
  subdirs="$(ls -d "$dir"/*/)"
  echo "$subdirs"
}

function installDockerServiceRestartorScript() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🟦 Install Docker service restartor script and cron job..."
  
  # create a script that restarts the docker service
  cat <<-EOF > "/usr/local/sbin/restart_$SERVICE_NAME"
#!/bin/bash

exec > >(tee -a /var/log/odoo/_utilities/restart_$SERVICE_NAME.log) 2>&1

docker compose -f $REPOSITORY_DIRPATH/$DOCKER_COMPOSE_FILE restart
EOF

  chmod +x "/usr/local/sbin/restart_$SERVICE_NAME"

  # install cronjob
  cat <<-EOF > "/etc/cron.d/restart_$SERVICE_NAME"
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

5 3 * * * root "/usr/local/sbin/restart_$SERVICE_NAME"
EOF
  
  chmod 644 "/etc/cron.d/restart_$SERVICE_NAME"

  #install logrotation for restart_$SERVICE_NAME.log
  cat <<-EOF > "/etc/logrotate.d/restart_$SERVICE_NAME"
/var/log/odoo/_utilities/restart_$SERVICE_NAME.log {
  rotate 14
  olddir /var/log/odoo/_utilities/restart_$SERVICE_NAME.log-old
  su root root
  daily
  missingok
  #notifempty
  nocreate
  createolddir 755 root root
  renamecopy
  compress
  compresscmd /usr/bin/xz
  compressoptions -ze -T 4
  delaycompress
  dateext
  dateformat -%Y%m%d-%H%M%S
}
EOF
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

function installPostgresRestartorScript() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🟦 Install Postgresql restartor script and cron job..."
  # create a script that restarts the postgresql service
  cat <<-EOF > /usr/local/sbin/restart_postgres
#!/bin/bash

exec > >(tee -a /var/log/odoo/_utilities/restart_postgres.log) 2>&1

echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🟦 Restarting Postgresql service..."
sudo systemctl restart postgresql

EOF

  chmod +x /usr/local/sbin/restart_postgres

  # install cronjob
  cat <<-EOF > /etc/cron.d/restart_postgres
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

0 3 * * * root /usr/local/sbin/restart_postgres
EOF

  chmod 644 /etc/cron.d/restart_postgres

  #install logrotation for restart_postgres.log
  cat <<-EOF > /etc/logrotate.d/restart_postgres
/var/log/odoo/_utilities/restart_postgres.log {
    rotate 14
    olddir /var/log/odoo/_utilities/restart_postgres.log-old
    su root root
    daily
    missingok
    #notifempty
    nocreate
    createolddir 755 root root
    renamecopy
    compress
    compresscmd /usr/bin/xz
    compressoptions -ze -T 4
    delaycompress
    dateext
    dateformat -%Y%m%d-%H%M%S
}
EOF
}

function isBuildOrPull() {
    while true; do
      read -rp "Do you want to build or pull images?
      [1] Build
      [2] Pull

      : " -e user_choice

      choice=()
      case $user_choice in
        1)
          choice=("1" "Build")
          break
          ;;
        2)
          choice=("2" "Pull")
          break
          ;;
        *)
          echo -e "\n[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 Invalid Option.\n" >&2
          ;;
      esac
    done

    echo "${choice[@]}"
}

function isDirectoryGitRepository() {
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

function isLogRotateInstalled() {
  if ! command -v logrotate &>/dev/null; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ logrotate command not found."
    TODO+=("Please install logrotate by running the following command: 'sudo apt install logrotate'")
  else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ logrotate command found"
  fi
}

function isSubDirectoryExists() {
  dir=$1
  todo=$2
  additional_info=$3
  only_one=$4

  if ls -d "$dir"/*/ >/dev/null 2>&1; then
    if [ -n "$only_one" ]; then
      if [ "$(find "$dir" -mindepth 1 -maxdepth 1 -type d | wc -l)" -ne 1 ]; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ There are more than one directories found inside $dir. Please keep only one directory."

        TODO+=("Please remove the unnecessary directories inside $dir. Only keep one directory that contains your Odoo base.")
        return 1
      else
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ A directory exists inside $dir"
        return 0
      fi
    else
      echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ Directories exists inside $dir"
      return 0
    fi
  else
    if [ -n "$todo" ]; then
      TODO+=("$todo")
    fi

    if [ -n "$additional_info" ]; then
      echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🟦  $additional_info"
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
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🟦  Create a new Odoo user."
    if sudo useradd -m -u 8069 -s /bin/bash odoo; then
      echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ odoo user created."
    else
      echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ Failed to create odoo user."
      exit 1
    fi
  else
    if [ "$(id -u odoo)" -ne 8069 ]; then
      echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ odoo user already exists but the user id is not 8069."
      TODO+=("Please change the odoo user id to 8069 using the following command: 'sudo usermod -u 8069 odoo '")
    else
      echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ odoo user already exists."
    fi
  fi
}

function printTodo() {
  if [[ ${#TODO[@]} -gt 0 ]]; then
    echo
    echo "There are ${#TODO[@]} items need to be done."
    echo
    for i in "${TODO[@]}"; do
      echo "🟦  $i"
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
      echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🟨 $dir is not a git repository. You need to backup this directory by adding it to your snapshot utilities."      
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

# # # # # # # # # # # # # # # #
# DIRECTORIES                 #
# # # # # # # # # # # # # # # #
SERVICE_NAME=$SERVICE_NAME
ODOO_LOG_DIR_SERVICE=$ODOO_LOG_DIR_SERVICE
EOF
  fi
}

function writeTextFile() {
  password=$1
  file=$2
  type=$3

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🟦 Writing $type to $file..."

  echo "$password" > "$file"

  sudo chmod 400 "$file"
  sudo chown -R $ODOO_LINUX_USER: "$file"
}

function main() {
  amIRoot

  echo -e "\n==================================================================="
  echo "Path for working directory : $REPOSITORY_DIRPATH"
  echo "Deployment name will be    : $SERVICE_NAME"
  echo -e "===================================================================\n"

  read -rp "Press enter key to continue..."
  echo

  isbuildorpull=($(isBuildOrPull))
  is_build_or_pull="${isbuildorpull[1]}"
  build_or_pull="${isbuildorpull[0]}"

  echo -e "\n==================================================================="

  isDockerInstalled
  isLogRotateInstalled
  isOdooUserExists

  installPostgresRestartorScript
  installDockerServiceRestartorScript


  echo -e "\n==================================================================="
  echo -e "[$(date +"%Y-%m-%d %H:%M:%S")] 🟦 This script will run in $is_build_or_pull Mode."
  echo -e "[$(date +"%Y-%m-%d %H:%M:%S")] 🟦 Checking the necessary files and directories..."
  echo "==================================================================="

  generatePostgresSecrets

  if isFileExists "$ENV_FILE" "Please create a .env file by folowing the .env.example file."; then
    createLogDir
    createDataDir
  fi

  isFileExists "$DOCKER_COMPOSE_FILE" "Please create a docker-compose.yml file by following the docker-compose.yml.example file." || true

  if [ "$build_or_pull" -eq 1 ]; then
    isFileExists "$ODOO_CONF_FILE" "Please create an odoo.conf file by following the odoo.conf.example file." || true

    if isSubDirectoryExists "$GIT_DIR" "" "No directories found inside $GIT_DIR. That means no Odoo custom module will be added to your Odoo image."; then
      writeGitHash "$GIT_DIR"
    fi

    if isSubDirectoryExists "$ODOO_BASE_DIR" "Please clone your odoo-base repository inside the odoo-base directory" "" "only-one"; then
      writeGitHash "$ODOO_BASE_DIR"
    fi

    isFileExists "$REQUIREMENTS_FILE" "Please create a requirements.txt file by following the requirements.txt.example file." || true
  elif [ "$build_or_pull" -eq 2 ]; then
    # check if docker-compose file has image name
    if ! grep -q "^[^#]*image:" "$DOCKER_COMPOSE_FILE"; then
      echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ Please add the image name to your docker-compose.yml file."
      TODO+=("Please add the image name to your docker-compose.yml file.")
    else
      echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ Image name found in docker-compose.yml file."
    fi
  fi

  if printTodo; then
    echo
    echo
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ Everything is ready to build your docker image."
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🟦 Please run the following command to build your docker image: 'docker compose build'"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🟦 Then, you can run the compose using this command: 'docker compose up -d'"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🟦 You can combine the command using: 'docker compose up --build -d'."
    exit 0
  else
    echo
    echo
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ There are some things that need to be done before you can create your docker image."
    exit 1
  fi
}

main
