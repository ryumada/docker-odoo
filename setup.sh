#!/bin/bash

REPOSITORY_DIRPATH="$(pwd)"
REPOSITORY_OWNER=$(stat -c '%U' "$REPOSITORY_DIRPATH")
SERVICE_NAME="$(basename "$(pwd)")"
ODOO_LINUX_USER="odoo"
DEVOPS_USER="devops"

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

# --- Logging Functions & Colors ---
# Define colors for log messages
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[0;33m"
readonly COLOR_ERROR="\033[0;31m"

# Function to log messages with a specific color and emoji
log() {
  local color="$1"
  local emoji="$2"
  local message="$3"
  echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}"
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_warn() { log "${COLOR_WARN}" "⚠️" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }
# ------------------------------------

trap 'error_handler $LINENO' ERR

# Global Variable
TODO=()

function checkAddonsPathOnOdooConfFile() {
  addons_string="$(grep 'addons_path' $ODOO_CONF_FILE | grep -v '#' | grep -o 'addons_path = \([^)]*\)' | sed 's/addons_path = //')"

  log_info "You have defined this addons_path on $ODOO_CONF_FILE: $addons_string"

  # shellcheck disable=SC2206
  addons_array=(${addons_string//,/ }) # Intentionally splitting string into array

  for addons_path in "${addons_array[@]}"; do

    if ! echo "$addons_path" | grep -q "/opt/odoo/"; then
      log_error "The addons_path ($addons_path) should be started with /opt/odoo/."
      TODO+=("Please check your odoo.conf file. The addons_path ($addons_path) should be started with /opt/odoo.")
    else
      addons_path_onhost="${addons_path/\/opt\/odoo/$REPOSITORY_DIRPATH}"

      if [ ! -d "$addons_path_onhost" ]; then
        log_error "$addons_path on your conf file is not valid."
        TODO+=("Please check this directory: $addons_path_onhost. Make sure it exists and contains your odoo addons. The addons_path defined in your $ODOO_CONF_FILE: $addons_path.")
      else
        log_success "This addons_path is valid: $addons_path"
      fi
    fi
  done
}

function checkImportantEnvVariable() {
  local param=$1
  local env_file=$2

  env_variable_value=$(grep "^$param=" "$env_file" | cut -d '=' -f 2)

  if [ "$env_variable_value" == "" ]; then
    log_error "$param variable has empty value."
    TODO+=("Please fill in the $param variable in your $env_file file.")
  else
    log_success "$param is set to $env_variable_value"
  fi
}

function createDataDir() {
  log_info "Create Odoo datadir... (path: $ODOO_DATADIR_SERVICE)"

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
  log_info "Create log directory... (path: $ODOO_LOG_DIR_SERVICE)"

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

  log_info "Create odoo shell command from entrypoint.sh..."

  entrypoint_file="$REPOSITORY_DIRPATH/entrypoint.sh"
  odoo_utility_file="$REPOSITORY_DIRPATH/utilities/odoo-$param"

  cp "$entrypoint_file" "$odoo_utility_file"

  # shellcheck disable=SC2016
  sed -i 's/: "${PORT:=8069}"/PORT="$(shuf -i 55000-60000 -n 1)"/' "$odoo_utility_file"
  # shellcheck disable=SC2016
  sed -i 's/: "${GEVENT_PORT:=8072}"/GEVENT_PORT="$(shuf -i 50000-54999 -n 1)"/' "$odoo_utility_file"

  # Use a temporary file and a "Here Document" to avoid complex sed escaping
  temp_header_file=$(mktemp)

  # The 'EOF' is quoted to prevent any variable expansion within the block.
  # This is crucial because variables like $1 need to be interpreted by the
  # generated script, not by this setup script.
  cat <<'EOF' > "$temp_header_file"
DATABASE_NAME_OR_HELP=$1
UPDATE_MODULES=$2

function show_help() {
  echo "Usage: odoo-PARAM [database_name|help] [--update=module1,module2,...]"
  echo "Parameters:"
  echo "  database_name: The name of the database you want to connect to"
  echo ""
  echo "  help:"
  echo "    help, -h, --help: Show this help message and exit"
}

case "$DATABASE_NAME_OR_HELP" in
  help|-h|--help) show_help; exit 1 ;;
  "") show_help; exit 1 ;;
  *) DB_NAME=$DATABASE_NAME_OR_HELP ;;
esac
EOF

  # Replace the PARAM placeholder with the actual script name (e.g., "shell")
  sed -i "s/PARAM/$param/g" "$temp_header_file"
  # Inject the content of the temp file after line 1 of the utility script
  sed -i '1r '"$temp_header_file" "$odoo_utility_file"
  # Clean up the temporary file
  rm "$temp_header_file"

  if [[ "$param" == "shell" ]]; then

    # shellcheck disable=SC2016
    sed -i 's|"/opt/odoo/odoo-base/$ODOO_BASE_DIRECTORY/odoo-bin"|"/opt/odoo/odoo-base/$ODOO_BASE_DIRECTORY/odoo-bin\" shell|' "$odoo_utility_file"

  elif [[ "$param" == "module-upgrade" ]]; then
    # Use a temporary file for the module upgrade logic to keep it readable
    temp_upgrade_logic=$(mktemp)
    cat <<'EOF' > "$temp_upgrade_logic"

if [[ "$UPDATE_MODULES" != "--update="* ]]; then
  echo "[$$(date +'%Y-%m-%d %H:%M:%S')] 🔴 ERROR?! This script needs the --update parameter."
  echo "Usage: odoo-PARAM [database_name|help] --update=module1,module2,..."
  exit 1;
fi
UPDATE_MODULES="${UPDATE_MODULES#--update=}"
add_arg "update" "$UPDATE_MODULES"
add_arg "stop-after-init"
EOF
    sed -i "s/PARAM/$param/g" "$temp_upgrade_logic"
    # Use sed 'r' to read the temp file and insert it after the matching line
    # shellcheck disable=SC2016
    sed -i '/ODOO_BASE_DIRECTORY=\$(basename "\$ODOO_BASE_DIRECTORY")/r '"$temp_upgrade_logic" "$odoo_utility_file"
    rm "$temp_upgrade_logic"
  fi

  # delete line on pattern
  # shellcheck disable=SC2016
  sed -i '/ODOO_LOG_FILE=$ODOO_LOG_DIR_SERVICE\/$SERVICE_NAME.log/d' "$odoo_utility_file"
  # shellcheck disable=SC2016
  sed -i '/add_arg "logfile" "$ODOO_LOG_FILE"/d' "$odoo_utility_file"

  chown "$REPOSITORY_OWNER": "$odoo_utility_file"
}

function generateDockerComposeAndDockerfile() {
  log_info "Create docker-compose.yml file..."

  cp docker-compose.yml.example docker-compose.yml
  chown "$REPOSITORY_OWNER": docker-compose.yml

  # Inject Custom Secrets from .env
  custom_secrets=$(grep "^CUSTOM_SECRETS_FILES=" "$REPOSITORY_DIRPATH/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')
  if [ -n "$custom_secrets" ]; then
    log_info "Found custom secrets: $custom_secrets. Injecting into docker-compose.yml..."
    IFS=',' read -ra ADDR <<< "$custom_secrets"
    for secret in "${ADDR[@]}"; do
      # trim whitespace
      secret=$(echo "$secret" | xargs)
      if [ -n "$secret" ]; then
         setPermissionFileToReadOnlyAndOnlyTo "$ODOO_LINUX_USER" ".secrets/$secret"

         # Inject into services > odoo > secrets
         sed -i "/      - db_password/a \      - $secret" docker-compose.yml

         # Inject into top-level secrets
         cat <<EOF >> docker-compose.yml
  $secret:
    file: .secrets/$secret
EOF
      fi
    done
  fi

  log_info "Bind mounts enabled for Development and Builder modes."
  sed -i '/volumes/a \
     - ./git:/opt/odoo/git\
     - ./odoo-base:/opt/odoo/odoo-base' docker-compose.yml

  generateDockerFile
}

function generateDockerFile() {
  # _inherit = generateDockerComposeFile

  log_info "Create dockerfile..."
  cp dockerfile.example dockerfile
  chown "$REPOSITORY_OWNER": dockerfile

  log_info "Setting up dockerfile with mount strategy..."

  FAKETIME=$(grep "^FAKETIME=" "$REPOSITORY_DIRPATH/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')
  [ -n "$FAKETIME" ] && validateDatetimeFormat "$FAKETIME" " FAKETIME on .env file" && {
    log_info "Setting up faketime..."
    sed -i '/USER root/a \
RUN apt install -y libfaketime\
ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/faketime/libfaketime.so.1' dockerfile
  } || true
}

function generatePostgresPassword() {
  # _inherit = generatePostgresSecrets

  postgresusername=$1

  log_info "Regenerate Postgres password..."

  POSTGRES_ODOO_PASSWORD=$(openssl rand -base64 64 | tr -d '\n')

  sudo -u postgres psql -c "ALTER ROLE \"$postgresusername\" WITH PASSWORD '$POSTGRES_ODOO_PASSWORD';" > /dev/null 2>&1

  writeTextFile "$POSTGRES_ODOO_PASSWORD" "$DB_PASSWORD_SECRET" "password"
}

function generatePostgresSecrets() {
  POSTGRES_ODOO_USERNAME=$SERVICE_NAME

  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$POSTGRES_ODOO_USERNAME'" 2>/dev/null | grep -q 1; then
    log_success "User $POSTGRES_ODOO_USERNAME already exists."
  else
    log_info "User $POSTGRES_ODOO_USERNAME doesn't exist. Creating the user..."
    sudo -u postgres psql -c "CREATE ROLE \"$POSTGRES_ODOO_USERNAME\" LOGIN CREATEDB;" > /dev/null 2>&1
  fi

  writeTextFile "$POSTGRES_ODOO_USERNAME" "$DB_USER_SECRET" "username"

  # while true; do
  #   read -r -p "❓ Do you want to regenerate the password for $POSTGRES_ODOO_USERNAME? [yes/no][y/N] : " response

  #   case $response in
  #     [yY][eE][sS]|[yY])
  #       generatePostgresPassword "$POSTGRES_ODOO_USERNAME"
  #       break
  #       ;;
  #     [nN][oO]|[nN])
  #       log_info "Okay, You don't want to regenerate password."
  #       break
  #       ;;
  #     *)
  #       log_error "Invalid option"
  #       ;;
  #   esac
  # done

  generatePostgresPassword "$POSTGRES_ODOO_USERNAME"

  setPermissionFileToReadOnlyAndOnlyTo "$ODOO_LINUX_USER" "$DB_USER_SECRET"
  setPermissionFileToReadOnlyAndOnlyTo "$ODOO_LINUX_USER" "$DB_PASSWORD_SECRET"
}

function getGitHash() {
  # _inherit = writeGitHash

  git_path=$1
  git_real_owner=$(stat -c '%U' "$git_path")
  repository_owner=$(stat -c '%U' "$REPOSITORY_DIRPATH")

  chown -R "$repository_owner": "$git_path"

  OUTPUT_GIT_HASHES_FILE="$git_path/../git_hashes.txt"

  cat <<EOF >> "$OUTPUT_GIT_HASHES_FILE"
  Updated at [$(date +"%Y-%m-%d %H:%M:%S")]
  Git Directory: $git_path
  Git Remote: $(git -C "$git_path" remote get-url origin)
  Git Branch: $(git -C "$git_path" branch --show-current)
  Git Hashes: $(git -C "$git_path" rev-parse HEAD)
EOF

  chown -R "$git_real_owner": "$git_path"
}

function getSubDirectories() {
  # _inherit = writeGitHash

  dir=$1
  subdirs="$(ls -d "$dir"/*/)"
  echo "$subdirs"
}

function installDockerServiceRestartorScript() {
  log_info "Install Docker service restartor script and cron job..."

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
  log_info "Install Postgresql restartor script and cron job..."
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

function selectMode() {
    while true; do
      read -rp "Select the deployment mode:
      [1] Development (Build locally, bind-mounts)
      [2] Builder (Build, check versions, push to registry)
      [3] Production (Pull from registry)

      : " -e user_choice

      case $user_choice in
        1)
          echo "1 Development"
          break
          ;;
        2)
          echo "2 Builder"
          break
          ;;
        3)
          echo "3 Production"
          break
          ;;
        *)
          echo -e "\nInvalid Option.\n" >&2
          ;;
      esac
    done
}

function isDirectoryGitRepository() {
  # _inherit = writeGitHash

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
    log_error "docker command not found."
    TODO+=("Please install docker engine by following this docs: https://docs.docker.com/engine/install/")
  else
    log_success "docker command found"
  fi
}

function isPostgresInstalled() {
  if ! command -v psql &>/dev/null; then
    log_error "psql command not found."
    TODO+=("Please install postgresql by running the following command: 'sudo apt install postgresql'")
    return 1
  else
    log_success "psql command found"
    return 0
  fi
}

function isInteger() {
  # _inherit = validateDatetimeFormat
  [[ "$1" =~ ^[0-9]+$ ]]
}

function isLogRotateInstalled() {
  if ! command -v logrotate &>/dev/null; then
    log_error "logrotate command not found."
    TODO+=("Please install logrotate by running the following command: 'sudo apt install logrotate'")
  else
    log_success "logrotate command found"
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
        log_error "There are more than one directories found inside $dir. Please keep only one directory."

        TODO+=("Please remove the unnecessary directories inside $dir. Only keep one directory that contains your Odoo base.")
        return 1
      else
        log_success "A directory exists inside $dir"
        return 0
      fi
    else
      log_success "Directories exists inside $dir"
      return 0
    fi
  else
    if [ -n "$todo" ]; then
      TODO+=("$todo")
    fi

    if [ -n "$additional_info" ]; then
      log_info "$additional_info"
    else
      log_error "No directory found inside $dir"
    fi

    return 1
  fi
}

function isFileExists() {
  file=$1
  todo=$2

  if [ -f "$file" ]; then
    log_success "$file file exists"
    return 0
  else
    TODO+=("$todo")

    log_error "$file file does not exist"
    return 1
  fi
}

function isUserExist() {
  user_name=$1
  user_id=$2

  if ! id "$user_name" &>/dev/null; then
    log_info "Create a new $user_name user."
    if sudo useradd -m -u "$user_id" -s /bin/bash "$user_name"; then
      log_success "$user_name user created."
    else
      log_error "Failed to create $user_name user."
      exit 1
    fi
  else
    if [ "$(id -u "$user_name")" -ne "$user_id" ]; then
      log_error "$user_name user already exists but the user id is not $user_id."
      TODO+=("Please change the $user_name user id to $user_id using the following command: 'sudo usermod -u $user_id $user_name '")
    else
      log_success "$user_name user already exists."
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
    log_error "There is 1 thing that needs to be done before you can create your docker image."
  else
    log_error "There are $todo_count things that need to be done before you can create your docker image."
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

function setupAutoDevops() {
  isUserExist "$DEVOPS_USER" 7689

  cat <<EOF > ~/00-devops_permissions
devops ALL=(devopsadmin) NOPASSWD: \\
  /usr/bin/git, \\
  /usr/bin/docker compose *, \\
  /usr/bin/docker container prune -f, \\
  /usr/bin/docker image prune -f, \\
  /usr/bin/docker system prune -f

devops ALL=(root) NOPASSWD: \\
  /usr/bin/sync, \\
  /usr/bin/tee /proc/sys/vm/drop_caches

EOF

  sudo chmod 440 ~/00-devops_permissions
  sudo chown root: ~/00-devops_permissions
  sudo mv ~/00-devops_permissions /etc/sudoers.d/
}

function validateDatetimeFormat() {
  local datetime_string="$1"
  local varmsg="$2"
  local regex="^([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})$"

  # 1. Check overall format using regex
  if [[ ! "$datetime_string" =~ $regex ]]; then
    log_error "Error$varmsg: Format does not match YYYY-MM-DD HH:MM:SS."
    TODO+=("Error$varmsg: Format does not match YYYY-MM-DD HH:MM:SS.")
    return 1
  fi

  # Extract components using BASH_REMATCH array
  local year="${BASH_REMATCH[1]}"
  local month="${BASH_REMATCH[2]}"
  local day="${BASH_REMATCH[3]}"
  local hour="${BASH_REMATCH[4]}"
  local minute="${BASH_REMATCH[5]}"
  local second="${BASH_REMATCH[6]}"

  # 2. Validate numerical ranges and basic date logic

  # Year: Simple check for 4 digits (regex already handles this)
  # For more advanced checks, you might check against a reasonable range (e.g., 1900-2100)
  # if (( year < 1900 || year > 2100 )); then #
  #   echo "$(getDate) 🔴 Error$varmsg: Year ($year) is out of a reasonable range (e.g., 1900-2100)."
  # TODO+=("Error$varmsg: Year ($year) is out of a reasonable range (e.g., 1900-2100).")
  #   return 1
  # fi

  # Month (01-12)
  if ! isInteger "$month" || (( 10#$month < 1 || 10#$month > 12 )); then
    log_error "Error$varmsg: Month ($month) is invalid. Must be between 01 and 12."
    TODO+=("Error$varmsg: Month ($month) is invalid. Must be between 01 and 12.")
    return 1
  fi

  # Day (01-31, with consideration for month and leap year)
  if ! isInteger "$day" || (( 10#$day < 1 || 10#$day > 31 )); then
    log_error "Error$varmsg: Day ($day) is invalid. Must be between 01 and 31."
    TODO+=("Error$varmsg: Day ($day) is invalid. Must be between 01 and 31.")
    return 1
  fi

  # Basic day-of-month validation (more robust check below)
  case "$month" in
    02) # February
      if (( year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) )); then
        # Leap year
        if (( 10#$day > 29 )); then
          log_error "Error$varmsg: Day ($day) is invalid for February in a leap year ($year)."
          TODO+=("Error$varmsg: Day ($day) is invalid for February in a leap year ($year).")
          return 1
        fi
      else
        # Non-leap year
        if (( 10#$day > 28 )); then
          log_error "Error$varmsg: Day ($day) is invalid for February in a non-leap year ($year)."
          TODO+=("Error$varmsg: Day ($day) is invalid for February in a non-leap year ($year).")
          return 1
        fi
      fi
      ;;
    04|06|09|11) # April, June, September, November (30 days)
      if (( 10#$day > 30 )); then
        log_error "Error$varmsg: Day ($day) is invalid for month $month. Must be 30 or less."
        TODO+=("Error$varmsg: Day ($day) is invalid for month $month. Must be 30 or less.")
        return 1
      fi
      ;;
    *) # All other months (31 days) - regex already checked for 31 max
      ;;
  esac

  # Hour (00-23)
  if ! isInteger "$hour" || (( 10#$hour < 0 || 10#$hour > 23 )); then
    log_error "Error$varmsg: Hour ($hour) is invalid. Must be between 00 and 23."
    TODO+=("Error$varmsg: Hour ($hour) is invalid. Must be between 00 and 23.")
    return 1
  fi

  # Minute (00-59)
  if ! isInteger "$minute" || (( 10#$minute < 0 || 10#$minute > 59 )); then
    log_error "Error$varmsg: Minute ($minute) is invalid. Must be between 00 and 59."
    TODO+=("Error$varmsg: Minute ($minute) is invalid. Must be between 00 and 59.")
    return 1
  fi

  # Second (00-59)
  if ! isInteger "$second" || (( 10#$second < 0 || 10#$second > 59 )); then
    log_error "Error$varmsg: Second ($second) is invalid. Must be between 00 and 59."
    TODO+=("Error$varmsg: Second ($second) is invalid. Must be between 00 and 59.")
    return 1
  fi

  log_success "Success validate$varmsg: '$datetime_string' is a valid YYYY-MM-DD HH:MM:SS format."
  return 0
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
      log_warn "$dir is not a git repository. You need to backup this directory by adding it to your snapshot utilities."
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

# # # # # # # # # # # # # # # # #
# DIRECTORIES                   #
# # # # # # # # # # # # # # # # #
SERVICE_NAME=$SERVICE_NAME
ODOO_LOG_DIR_SERVICE=$ODOO_LOG_DIR_SERVICE
EOF
  fi
}

function writeTextFile() {
  password=$1
  file=$2
  type=$3

  log_info "Writing $type to $file..."

  echo "$password" > "$file"
}

function checkRegistryConnection() {
    image_name=$1
    if [ -z "$image_name" ]; then return 0; fi

    registry=$(echo "$image_name" | cut -d/ -f1)

    # Basic heuristic to warn user if not logged in
    # This is not a blocker, just a warning
    if [[ "$registry" == *"index.docker.io"* ]] || [[ "$registry" != *"."* ]]; then
        # Docker Hub or official library
        if ! grep -q "index.docker.io" ~/.docker/config.json 2>/dev/null; then
             log_warn "It seems you are not logged into Docker Hub. Please ensure you are logged in ('docker login') if the repository is private."
        fi
    elif [[ "$registry" == *"ghcr.io"* ]]; then
         if ! grep -q "ghcr.io" ~/.docker/config.json 2>/dev/null; then
             log_warn "It seems you are not logged into GitHub Container Registry. Please ensure you are logged in."
         fi
    elif [[ "$registry" == *"gitlab.com"* ]]; then
         if ! grep -q "gitlab.com" ~/.docker/config.json 2>/dev/null; then
             log_warn "It seems you are not logged into GitLab Registry. Please ensure you are logged in."
         fi
    fi
    # Proceed anyway, checking "if connection is already successful" implies we trust the environment or just try.
    log_info "Registry connection check passed (soft check)."
}

function main() {
  # Self-elevate to root if not already
  if [ "$(id -u)" -ne 0 ]; then
      log_info "Elevating permissions to root..."
      # shellcheck disable=SC2093
      exec sudo "$0" "$@"
      log_error "Failed to elevate to root. Please run with sudo." # This will only run if exec fails
      exit 1
  fi

  echo -e "\n==================================================================="
  echo "Path for working directory : $REPOSITORY_DIRPATH"
  echo "Deployment name will be    : $SERVICE_NAME"
  echo -e "===================================================================\n"

  if [ "$1" != "auto" ]; then
    read -rp "Press enter key to continue..."
  fi

  "$REPOSITORY_DIRPATH/scripts/update-env-file.sh"

  DOCKER_BUILD_MODE=$(grep "^DOCKER_BUILD_MODE=" "$REPOSITORY_DIRPATH/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')

  if [ -z "$DOCKER_BUILD_MODE" ]; then
    mode_selection=$(selectMode)
  else
      # Map old values or just use what we have if it matches "1 Development" etc.
      # For backward compatibility or direct env usage, we assume strict values or we map 1 -> Development
    if [ "$DOCKER_BUILD_MODE" == "1" ]; then mode_selection="1 Development"; fi
    if [ "$DOCKER_BUILD_MODE" == "2" ]; then mode_selection="2 Builder"; fi
    if [ "$DOCKER_BUILD_MODE" == "3" ]; then mode_selection="3 Production"; fi
  fi

  mode_number=$(echo "$mode_selection" | awk '{print $1}')
  mode_name=$(echo "$mode_selection" | cut -d ' ' -f 2-)

  echo -e "\n==================================================================="

  isDockerInstalled
  isLogRotateInstalled
  isUserExist "$ODOO_LINUX_USER" 8069

  setupAutoDevops

  installDockerServiceRestartorScript

  if [ "$1" != "auto" ]; then
    read -rp "❓ Do you want to renew odoo-shell and odoo-module-upgrade scripts? [y/N] : " response

    if [[ "$response" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
      createOdooUtilitiesFromEntrypoint "shell"
      createOdooUtilitiesFromEntrypoint "module-upgrade"
    fi
  else
    createOdooUtilitiesFromEntrypoint "shell"
    createOdooUtilitiesFromEntrypoint "module-upgrade"
  fi

  echo -e "\n==================================================================="
  log_info "This script will run in $mode_name Mode."
  log_info "Checking the necessary files and directories..."
  echo "==================================================================="

  generateDockerComposeAndDockerfile

  if isFileExists "$ENV_FILE" "Please create a .env file by folowing the .env.example file."; then
    createLogDir
    createDataDir

    DB_HOST=$(grep 'DB_HOST' $ENV_FILE | grep -v '#' | grep -o 'DB_HOST=\([^)]*\)' | sed 's/DB_HOST=//')

    if [ "$DB_HOST" == "" ]; then
      if isPostgresInstalled; then
        DB_REGENERATE_SECRETS=$(grep 'DB_REGENERATE_SECRETS' $ENV_FILE | grep -v '#' | grep -o 'DB_REGENERATE_SECRETS=\([^)]*\)' | sed 's/DB_REGENERATE_SECRETS=//')
        if [ "$DB_REGENERATE_SECRETS" == "Y" ]; then
          log_info "Regenerate Postgres secrets..."
          generatePostgresSecrets "$DB_REGENERATE_SECRETS"
        fi
        sed -i "s/DB_REGENERATE_SECRETS=Y/DB_REGENERATE_SECRETS=N/" "$ENV_FILE"

        installPostgresRestartorScript
      fi
    else
      log_warn "DB_HOST found on .env file. That means you have a separate postgresql server."
      log_warn "Please make sure that the postgresql server is running and the user and password are setup successfully. See '.secrets' directory to setup the username and password of your postgres user."
    fi

    checkImportantEnvVariable "PYTHON_VERSION" $ENV_FILE
    checkImportantEnvVariable "PORT" $ENV_FILE
    checkImportantEnvVariable "GEVENT_PORT" $ENV_FILE
    checkImportantEnvVariable "ADMIN_PASSWD" $ENV_FILE
    checkImportantEnvVariable "ADDONS_PATH" $ENV_FILE
    checkImportantEnvVariable "WKHTMLTOPDF_DIRECT_DOWNLOAD_URL" $ENV_FILE
  fi

  ODOO_ADMIN_PASSWD=$(grep "^ADMIN_PASSWD=" "$REPOSITORY_DIRPATH/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')
  ODOO_ADDONS_PATH=$(grep "^ADDONS_PATH=" "$REPOSITORY_DIRPATH/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')

  if [ -n "$ODOO_ADMIN_PASSWD" ] && [ -n "$ODOO_ADDONS_PATH" ]; then
    log_info "Updating odoo.conf file..."
    "$REPOSITORY_DIRPATH/scripts/update-odoo-config.sh"
  else
    log_error "You need to fill ADMIN_PASSWD and ADDONS_PATH variables in your .env file."
  fi

  isFileExists "$DOCKER_COMPOSE_FILE" "Please create a docker-compose.yml file by following the docker-compose.yml.example file." || true

  # Extract ODOO_IMAGE_NAME early as it's used in 2 and 3
  ODOO_IMAGE_NAME=$(grep "^ODOO_IMAGE_NAME=" "$ENV_FILE" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')

  # MODE 1: DEVELOPMENT or MODE 2: BUILDER
  if [ "$mode_number" -eq 1 ] || [ "$mode_number" -eq 2 ]; then
    if isFileExists "$ODOO_CONF_FILE" "Please create an odoo.conf file by following the odoo.conf.example file."; then
      checkAddonsPathOnOdooConfFile
    fi

    if isSubDirectoryExists "$GIT_DIR" "" "No directories found inside $GIT_DIR. That means no Odoo custom module will be added to your Odoo image."; then
      writeGitHash "$GIT_DIR"
    fi

    if isSubDirectoryExists "$ODOO_BASE_DIR" "Please clone your odoo-base repository inside the odoo-base directory" "" "only-one"; then
      writeGitHash "$ODOO_BASE_DIR"

      ODOO_BASE_DIRECTORY=$(find $ODOO_BASE_DIR -mindepth 1 -maxdepth 1 -type d -print -quit)
      log_info "Add execute permission to odoo-bin binary"
      chmod +x "$ODOO_BASE_DIRECTORY"/odoo-bin

      if ! isFileExists "$REQUIREMENTS_FILE" "Please copy your requirements.txt file from your 'odoo-base' or create the file by following the requirements.txt.example file."; then
        log_info "Copying $REQUIREMENTS_FILE file..."
        cp "$ODOO_BASE_DIRECTORY/$REQUIREMENTS_FILE" "$REQUIREMENTS_FILE"
        chown "$REPOSITORY_OWNER:$REPOSITORY_OWNER" "$REQUIREMENTS_FILE"
        log_success "$REQUIREMENTS_FILE file copied."
      fi
    fi

  ODOO_IMAGE_NAME=$(grep "^ODOO_IMAGE_NAME=" "$REPOSITORY_DIRPATH/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')
  ODOO_IMAGE_VERSION=$(grep "^ODOO_IMAGE_VERSION=" "$REPOSITORY_DIRPATH/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')

  if [ -n "$ODOO_IMAGE_NAME" ] && [ -n "$ODOO_IMAGE_VERSION" ]; then
    ODOO_IMAGE_NAME="${ODOO_IMAGE_NAME}:${ODOO_IMAGE_VERSION}"
    log_info "Using automated tag: $ODOO_IMAGE_NAME"
    export ODOO_IMAGE_NAME
  elif [ -n "$ODOO_IMAGE_NAME" ]; then
    export ODOO_IMAGE_NAME
  fi

  # Builder Mode Specifics
  if [ "$mode_number" -eq 2 ]; then
      if [ -z "$ODOO_IMAGE_NAME" ]; then
          log_error "ODOO_IMAGE_NAME variable is not set in your .env file. Builder mode requires this."
          TODO+=("Please set the ODOO_IMAGE_NAME variable in your .env file.")
      else
          log_success "ODOO_IMAGE_NAME variable is set to $ODOO_IMAGE_NAME"
          checkRegistryConnection "$ODOO_IMAGE_NAME"
      fi
  fi

  # MODE 3: PRODUCTION
  elif [ "$mode_number" -eq 3 ]; then
    if [ -z "$ODOO_IMAGE_NAME" ]; then
      log_error "ODOO_IMAGE_NAME variable is not set in your .env file. Production mode requires this to pull the image."
      TODO+=("Please set the ODOO_IMAGE_NAME variable in your .env file.")
    else
      log_success "ODOO_IMAGE_NAME variable is set to $ODOO_IMAGE_NAME"
    fi
  fi

  "$REPOSITORY_DIRPATH/scripts/installer/install-backupdata.sh"
  "$REPOSITORY_DIRPATH/scripts/installer/install-deploy_release_candidate.sh"
  "$REPOSITORY_DIRPATH/scripts/installer/install-restore_backupdata.sh"
  "$REPOSITORY_DIRPATH/scripts/installer/install_sudoers.sh"

  ENABLE_DATABASE_CLONER=$(grep "^ENABLE_DATABASE_CLONER=" "$REPOSITORY_DIRPATH/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')
  if [ -n "$ENABLE_DATABASE_CLONER" ]; then
    "$REPOSITORY_DIRPATH/scripts/installer/install-databasecloner.sh"
  else
    log_warn "databasecloner utility is not installed. Please fill ENABLE_DATABASE_CLONER variable in your .env file, then re-run this install script to install databasecloner utility."
  fi

  ENABLE_SNAPSHOT=$(grep "^ENABLE_SNAPSHOT=" "$REPOSITORY_DIRPATH/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')
  ODOO_DB_NAME=$(grep "^DB_NAME=" "$REPOSITORY_DIRPATH/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')
  if [ -n "$ENABLE_SNAPSHOT" ] && [ -n "$ODOO_DB_NAME" ]; then
    "$REPOSITORY_DIRPATH/scripts/installer/install-snapshot.sh"
  else
    log_warn "snapshot utility is not installed. Please fill ENABLE_SNAPSHOT and DB_NAME variables in your .env file, then re-run this install script to install snapshot utility."
  fi

  if printTodo; then
    echo
    echo
    log_success "Configuration complete."

    if [ "$mode_number" -eq 1 ]; then
        log_info "MODE: DEVELOPMENT"
        log_info "1. Building image..."
        if sudo -u "$REPOSITORY_OWNER" docker compose build; then
            log_success "Image built successfully."
            log_info "Now run: 'docker compose up -d'"
        else
            log_error "Build failed."
            exit 1
        fi

    elif [ "$mode_number" -eq 2 ]; then
        log_info "MODE: BUILDER"
        log_info "1. Building image..."
        if sudo -u "$REPOSITORY_OWNER" docker compose build; then
            log_success "Image built successfully."
        else
            log_error "Build failed."
            exit 1
        fi

        log_info "2. Verifying and extracting versions..."
        # Use the built image (ODOO_IMAGE_NAME or Service Name default)
        TARGET_IMAGE=${ODOO_IMAGE_NAME:-$SERVICE_NAME:latest}

        log_info "Running version checks on $TARGET_IMAGE..."

        log_info "--- Odoo Base Version ---"
        sudo -u "$REPOSITORY_OWNER" docker run --rm \
            "$TARGET_IMAGE" \
            getinfo-odoo_base || log_error "Failed to get Odoo base version"

        log_info "--- Odoo Addons Version ---"
        sudo -u "$REPOSITORY_OWNER" docker run --rm \
            "$TARGET_IMAGE" \
            getinfo-odoo_git_addons || log_error "Failed to get Addons version"

        log_info "3. Pushing image to $TARGET_IMAGE..."
        if sudo -u "$REPOSITORY_OWNER" docker push "$TARGET_IMAGE"; then
            log_success "Image pushed successfully!"

            # Dual Tagging: If we pushed a specific version, also update 'latest'
            if [ -n "$ODOO_IMAGE_VERSION" ] && [ "$ODOO_IMAGE_VERSION" != "latest" ]; then
                BASIC_IMAGE_NAME=$(echo "$TARGET_IMAGE" | cut -d: -f1)
                LATEST_TAG="${BASIC_IMAGE_NAME}:latest"
                log_info "Dual Tagging: Also pushing $LATEST_TAG..."

                if sudo -u "$REPOSITORY_OWNER" docker tag "$TARGET_IMAGE" "$LATEST_TAG"; then
                    if sudo -u "$REPOSITORY_OWNER" docker push "$LATEST_TAG"; then
                        log_success "Latest tag pushed successfully!"
                    else
                        log_warn "Failed to push 'latest' tag. Detailed error above."
                    fi
                else
                    log_error "Failed to create 'latest' tag."
                fi
            fi
        else
            log_error "Detailed push error usually involves authentication or permission."
            log_error "Failed to push image."
            exit 1
        fi

    elif [ "$mode_number" -eq 3 ]; then
        log_info "MODE: PRODUCTION"
        log_info "1. Pulling image $ODOO_IMAGE_NAME..."
        if sudo -u "$REPOSITORY_OWNER" docker compose pull; then
            log_success "Image pulled successfully."
            log_info "Now run: 'docker compose up -d'"
        else
            log_error "Pull failed."
            exit 1
        fi
    fi

    exit 0
  else
    exit 1
  fi
}

main "$@"
