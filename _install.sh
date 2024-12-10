#!/bin/bash

REPOSITORY_DIRPATH="$(pwd)"
REPOSITORY_DIRNAME="$(basename "$(pwd)")"
REPOSITORY_OWNER=$(stat -c '%U' "$REPOSITORY_DIRPATH")
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
    echo "$(getDate) ❌ Please run this script using sudo."
    exit 1
  fi
}

function checkAddonsPathOnOdooConfFile() {
  addons_string="$(grep 'addons_path' $ODOO_CONF_FILE | grep -v '#' | grep -o 'addons_path = \([^)]*\)' | sed 's/addons_path = //')"
  
  echo "$(getDate) 🟦 You have defined this addons_path on $ODOO_CONF_FILE: $addons_string"

  addons_array=(${addons_string//,/ })

  for addons_path in "${addons_array[@]}"; do

    addons_path_onhost=$(sed "s|/opt/odoo|$REPOSITORY_DIRPATH|" <<< "$addons_path")

    if [ ! -d "$addons_path_onhost" ]; then
      echo "$(getDate) ❌ $addons_path on your conf file is not valid."
      TODO+=("Please check this directory: $addons_path_onhost. Make sure it exists and contains your odoo addons. The addons_path defined in your $ODOO_CONF_FILE: $addons_path.")
    else
      echo "$(getDate) ✅ This addons_path is valid: $addons_path"
    fi
  done
}

function createDataDir() {
  echo "$(getDate) 🟦 Create Odoo datadir... (path: $ODOO_DATADIR_SERVICE)"

  if [ ! -d "$ODOO_DATADIR" ]; then
    sudo mkdir "$ODOO_DATADIR"
    sudo chown $ODOO_LINUX_USER: $ODOO_DATADIR
  fi

  if [ ! -d "$ODOO_DATADIR_SERVICE" ]; then
    sudo mkdir "$ODOO_DATADIR_SERVICE"
    sudo chown $ODOO_LINUX_USER: "$ODOO_DATADIR_SERVICE"
  fi

  if [ ! -d "$ODOO_DATADIR_SERVICE/filestore" ]; then
    sudo mkdir "$ODOO_DATADIR_SERVICE/filestore"
    sudo chown $ODOO_LINUX_USER: "$ODOO_DATADIR_SERVICE/filestore"
  fi

  writeDatadirVariableOnEnvFile
}

function createLogDir() {
  echo "$(getDate) 🟦 Create log directory... (path: $ODOO_LOG_DIR_SERVICE)"

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

function createOdooUtilitiesFromEntrypoint() {
  param=$1
  
  echo "$(getDate) 🟦 Create odoo shell command from entrypoint.sh..."

  entrypoint_file="$REPOSITORY_DIRPATH/entrypoint.sh"
  odoo_utility_file="$REPOSITORY_DIRPATH/utilities/odoo-$param"

  cp "$entrypoint_file" "$odoo_utility_file"

  sed -i 's/: "${PORT:=8069}"/PORT="$(shuf -i 55000-60000 -n 1)"/' "$odoo_utility_file"
  sed -i 's/: "${GEVENT_PORT:=8072}"/GEVENT_PORT="$(shuf -i 50000-54999 -n 1)"/' "$odoo_utility_file"

  sed -i '1a DATABASE_NAME_OR_HELP=$1\
'"$(if [[ $param == "module-upgrade" ]]; then echo "UPDATE_MODULES=\$2\n"; fi)"'\
function show_help() {\
  echo "Usage: odoo-'"$param"' [database_name|help] '"$(if [[ $param == "module-upgrade" ]]; then echo "[--update=module1,module2,...]"; fi)"'"\
  echo "Parameters:"\
  echo "  database_name: The name of the database you want to connect to"\
  echo ""\
  echo "  help:"\
  echo "    help, -h, --help: Show this help message and exit"\
}\n\
case "$DATABASE_NAME_OR_HELP" in\
  help|-h|--help)\
    show_help\
    exit 1\
    ;;\
  "")\
    echo "Usage: odoo-'"$param"' [database_name|help] '"$(if [[ $param == "module-upgrade" ]]; then echo "[--update=module1,module2,...]"; fi)"'"\
    exit 1\
    ;;\
  *)\
    DB_NAME=$DATABASE_NAME_OR_HELP\
    ;;\
esac\
' "$odoo_utility_file"
  
  if [[ "$param" == "shell" ]]; then 

    sed -i 's|"/opt/odoo/odoo-base/$ODOO_BASE_DIRECTORY/odoo-bin" "$@"|"/opt/odoo/odoo-base/$ODOO_BASE_DIRECTORY/odoo-bin\" shell|' "$odoo_utility_file"
  
  elif [[ "$param" == "module-upgrade" ]]; then

    # append line below the pattern with sed
    sed -i '/ODOO_BASE_DIRECTORY=$(basename "$ODOO_BASE_DIRECTORY")/a \
\
add_arg "config" "/etc/odoo/odoo.conf"\n\
if [[ "$UPDATE_MODULES" == "--update="* ]]; then\
  UPDATE_MODULES="${UPDATE_MODULES#--update=}"\
  add_arg "update" "$UPDATE_MODULES"\
else\
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 ERROR?! This script need --update parameter."\
  echo "Usage: odoo-'"$param"' [database_name|help] [--update=module1,module2,...]"\
  exit 1\
fi' "$odoo_utility_file"

    sed -i 's|"/opt/odoo/odoo-base/$ODOO_BASE_DIRECTORY/odoo-bin" "$@"|"/opt/odoo/odoo-base/$ODOO_BASE_DIRECTORY/odoo-bin\"|' "$odoo_utility_file"

  fi

  # delete line on pattern
  sed -i '/ODOO_LOG_FILE=$ODOO_LOG_DIR_SERVICE\/$SERVICE_NAME.log/d' "$odoo_utility_file"
  sed -i '/add_arg "logfile" "$ODOO_LOG_FILE"/d' "$odoo_utility_file"

  chown "$REPOSITORY_OWNER": "$odoo_utility_file"
}

function generatePostgresPassword() {
  # _inherit = generatePostgresSecrets

  postgresusername=$1

  echo "$(getDate) 🟦 Regenerate Postgres password..."

  POSTGRES_ODOO_PASSWORD=$(openssl rand -base64 64 | tr -d '\n')

  sudo -u postgres psql -c "ALTER ROLE \"$postgresusername\" WITH PASSWORD '$POSTGRES_ODOO_PASSWORD';" > /dev/null 2>&1

  writeTextFile "$POSTGRES_ODOO_PASSWORD" "$DB_PASSWORD_SECRET" "password"
}

function generatePostgresSecrets() {
  POSTGRES_ODOO_USERNAME=$SERVICE_NAME

  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$POSTGRES_ODOO_USERNAME'" 2>/dev/null | grep -q 1; then
    echo "$(getDate) ✅ User $POSTGRES_ODOO_USERNAME already exists."

    if [ -f "$DB_USER_SECRET" ]; then
      echo "$(getDate) ✅ $DB_USER_SECRET file exists."
    else
      writeTextFile "$POSTGRES_ODOO_USERNAME" "$DB_USER_SECRET" "username"
    fi
  else
    echo "$(getDate) 🟦 User $POSTGRES_ODOO_USERNAME doesn't exist. Creating the user..."
    sudo -u postgres psql -c "CREATE ROLE \"$POSTGRES_ODOO_USERNAME\" LOGIN CREATEDB;" > /dev/null 2>&1
    writeTextFile "$POSTGRES_ODOO_USERNAME" "$DB_USER_SECRET" "username"
  fi

  read -r -p "$(getDate) ❓ Do you want to regenerate the password for $POSTGRES_ODOO_USERNAME? [y/N] : " response
  if [[ "$response" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
    generatePostgresPassword "$POSTGRES_ODOO_USERNAME"
  fi
  
  setPermissionFileToReadOnlyAndOnlyTo "$ODOO_LINUX_USER" "$DB_USER_SECRET"
  setPermissionFileToReadOnlyAndOnlyTo "$ODOO_LINUX_USER" "$DB_PASSWORD_SECRET"
}

function getDate() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")]"
}

function getGitHash() {
  # _inherit = writeGitHash

  git_path=$1
  git_real_owner=$(stat -c '%U' "$git_path")
  repository_owner=$(stat -c '%U' "$REPOSITORY_DIRPATH")

  chown -R "$repository_owner": "$git_path"

  OUTPUT_GIT_HASHES_FILE="$git_path/../git_hashes.txt"

  cat <<EOF >> "$OUTPUT_GIT_HASHES_FILE"
  Updated at$(getDate)  
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
  echo "$(getDate) 🟦 Install Docker service restartor script and cron job..."
  
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
  echo "$(getDate) 🟦 Install Postgresql restartor script and cron job..."
  # create a script that restarts the postgresql service
  cat <<-EOF > /usr/local/sbin/restart_postgres
#!/bin/bash

exec > >(tee -a /var/log/odoo/_utilities/restart_postgres.log) 2>&1

echo "$(getDate) 🟦 Restarting Postgresql service..."
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
          echo -e "\n$(getDate) 🔴 Invalid Option.\n" >&2
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
    echo "$(getDate) ❌ docker command not found."
    TODO+=("Please install docker engine by following this docs: https://docs.docker.com/engine/install/")
  else
    echo "$(getDate) ✅ docker command found"
  fi
}

function isPostgresInstalled() {
  if ! command -v psql &>/dev/null; then
    echo "$(getDate) ❌ psql command not found."
    TODO+=("Please install postgresql by running the following command: 'sudo apt install postgresql'")
  else
    echo "$(getDate) ✅ psql command found"
  fi
}

function isLogRotateInstalled() {
  if ! command -v logrotate &>/dev/null; then
    echo "$(getDate) ❌ logrotate command not found."
    TODO+=("Please install logrotate by running the following command: 'sudo apt install logrotate'")
  else
    echo "$(getDate) ✅ logrotate command found"
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
        echo "$(getDate) ❌ There are more than one directories found inside $dir. Please keep only one directory."

        TODO+=("Please remove the unnecessary directories inside $dir. Only keep one directory that contains your Odoo base.")
        return 1
      else
        echo "$(getDate) ✅ A directory exists inside $dir"
        return 0
      fi
    else
      echo "$(getDate) ✅ Directories exists inside $dir"
      return 0
    fi
  else
    if [ -n "$todo" ]; then
      TODO+=("$todo")
    fi

    if [ -n "$additional_info" ]; then
      echo "$(getDate) 🟦  $additional_info"
    else
      echo "$(getDate) ❌ No directory found inside $dir"
    fi

    return 1
  fi
}

function isFileExists() {
  file=$1
  todo=$2

  if [ -f "$file" ]; then
    echo "$(getDate) ✅ $file file exists"
    return 0
  else
    TODO+=("$todo")

    echo "$(getDate) ❌ $file file does not exist"
    return 1
  fi
}

function isUserExist() {
  user_name=$1
  user_id=$2
  
  if ! id "$user_name" &>/dev/null; then
    echo "$(getDate) 🟦  Create a new $user_name user."
    if sudo useradd -m -u $user_id -s /bin/bash $user_name; then
      echo "$(getDate) ✅ $user_name user created."
    else
      echo "$(getDate) ❌ Failed to create $user_name user."
      exit 1
    fi
  else
    if [ "$(id -u $user_name)" -ne $user_id ]; then
      echo "$(getDate) ❌ $user_name user already exists but the user id is not $user_id."
      TODO+=("Please change the $user_name user id to $user_id using the following command: 'sudo usermod -u $user_id $user_name '")
    else
      echo "$(getDate) ✅ $user_name user already exists."
    fi
  fi
}

function printTodo() {
  if [[ ${#TODO[@]} -gt 0 ]]; then
    echo

    printTodoMessage "${#TODO[@]}"

    echo
    for i in "${TODO[@]}"; do
      echo "🟦  $i"
    done

    echo
    echo

    printTodoMessage "${#TODO[@]}"
    
    return 1
  else
    return 0
  fi
}

function printTodoMessage() {
  todo_count=$1

  if [ "$todo_count" -eq 1 ]; then
    echo "$(getDate) ❌ There is 1 thing that needs to be done before you can create your docker image."
  else
    echo "$(getDate) ❌ There are $todo_count things that need to be done before you can create your docker image."
  fi
}

function resetGitHashFile(){
  # _inherit = writeGitHash

  git_path=$1
  OUTPUT_GIT_HASHES_FILE="$git_path/../git_hashes.txt"

  cat <<EOF > "$OUTPUT_GIT_HASHES_FILE"
  
EOF
}

function setPermissionFileToReadOnlyAndOnlyTo() {
  owner=$1
  file=$2

  sudo chmod 400 "$file"
  sudo chown -R "$owner": "$file"
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
      echo "$(getDate) 🟨 $dir is not a git repository. You need to backup this directory by adding it to your snapshot utilities."      
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

  echo "$(getDate) 🟦 Writing $type to $file..."

  echo "$password" > "$file"
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
  isUserExist "$ODOO_LINUX_USER" 8069

  installDockerServiceRestartorScript

  read -rp "$(getDate) ❓ Do you want to renew odoo-shell and odoo-module-upgrade scripts? [y/N] : " response
  if [[ "$response" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
    createOdooUtilitiesFromEntrypoint "shell"
    createOdooUtilitiesFromEntrypoint "module-upgrade"
  fi

  echo -e "\n==================================================================="
  echo -e "$(getDate) 🟦 This script will run in $is_build_or_pull Mode."
  echo -e "$(getDate) 🟦 Checking the necessary files and directories..."
  echo "==================================================================="

  if isFileExists "$ENV_FILE" "Please create a .env file by folowing the .env.example file."; then
    createLogDir
    createDataDir

    DB_HOST=$(grep 'DB_HOST' $ENV_FILE | grep -v '#' | grep -o 'DB_HOST=\([^)]*\)' | sed 's/DB_HOST=//')

    if [ "$DB_HOST" == "" ]; then
      isPostgresInstalled
      generatePostgresSecrets
      installPostgresRestartorScript
    else
      echo "$(getDate) 🟨 DB_HOST found on .env file. That means you have a separate postgresql server."
      echo "$(getDate) 🟨 Please make sure that the postgresql server is running and the user and password are setup successfully. See '.secrets' directory to setup the username and password of your postgres user."
    fi
  fi

  isFileExists "$DOCKER_COMPOSE_FILE" "Please create a docker-compose.yml file by following the docker-compose.yml.example file." || true

  if [ "$build_or_pull" -eq 1 ]; then
    if isFileExists "$ODOO_CONF_FILE" "Please create an odoo.conf file by following the odoo.conf.example file."; then
      checkAddonsPathOnOdooConfFile
    fi

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
      echo "$(getDate) ❌ Please add the image name to your docker-compose.yml file."
      TODO+=("Please add the image name to your docker-compose.yml file.")
    else
      echo "$(getDate) ✅ Image name found in docker-compose.yml file."
    fi
  fi

  if printTodo; then
    echo
    echo
    echo "$(getDate) ✅ Everything is ready to build your docker image."
    echo "$(getDate) 🟦 Please run the following command to build your docker image: 'docker compose build'"
    echo "$(getDate) 🟦 Then, you can run the compose using this command: 'docker compose up -d'"
    echo "$(getDate) 🟦 You can combine the command using: 'docker compose up --build -d'."
    exit 0
  else
    exit 1
  fi
}

main
