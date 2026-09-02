#!/usr/bin/env bash
set -e
# Category: Installer
# Description: Upgrades and installs the snapshot utility from the example script.
# Usage: ./scripts/installer/install-snapshot.sh
# Dependencies: rsync, git, sudo, cron, ssh, curl

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

# Configuration
ENV_FILE=".env"
UPDATE_SCRIPT="./scripts/update-env-file.sh"
MAX_BACKUPS=3

# --- Logging Functions & Colors ---
# Define colors for log messages
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[0;31m"
readonly COLOR_BOLD="\033[1m"
readonly COLOR_CYAN="\033[0;36m"

TODO_LIST=()


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

error_handler() {
  local exit_code=$1
  local line_no=$2
  local command_name=$3
  log_error "An error occurred on line $line_no."
  log_error "Exit Code: $exit_code"
  log_error "Command: $command_name"
  log_error "Note: The specific error message should be printed in the lines above this error."
  exit "$exit_code"
}

trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR

function installCronJob() {
  local GCS_BUCKET_NAME="$1"
  local SNAPSHOT_TIME_LIST="$2"
  local GDRIVE_ACCESS_TOKEN="$3"
  local GDRIVE_SERVICE_ACCOUNT_KEY="$4"
  local SNAPSHOT_REMOTE_HOST="$5"
  local ENABLE_SNAPSHOT="$6"

  local cron_target="/etc/cron.d/snapshot-$SERVICE_NAME"

  if [ -z "$SNAPSHOT_TIME_LIST" ]; then
    if [ -f "$cron_target" ]; then
      log_info "Removing existing snapshot cron job: $cron_target"
      sudo rm -f "$cron_target"
      log_info "Restarting cron service..."
      sudo systemctl restart cron || true
    fi
    log_info "SNAPSHOT_TIME is empty. Periodic snapshot cron is disabled (tool available for manual execution)."
    return 0
  fi

  if [ -z "$ENABLE_SNAPSHOT" ] && [ -z "$GCS_BUCKET_NAME" ] && [ -z "$GDRIVE_ACCESS_TOKEN" ] && [ -z "$GDRIVE_SERVICE_ACCOUNT_KEY" ] && [ -z "$SNAPSHOT_REMOTE_HOST" ]; then
    log_warn "ENABLE_SNAPSHOT is not set in .env. The snapshot will not run automatically."
    return 0
  fi

  log_info "Creating cron job to run snapshot script periodically..."
  cat << EOF > "$HOME/snapshot-$SERVICE_NAME"
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

EOF

  for SNAPSHOT_TIME in $(echo "$SNAPSHOT_TIME_LIST" | tr "," "\n"); do
    cat << EOF >> "$HOME/snapshot-$SERVICE_NAME"
# Run the snapshot script at $SNAPSHOT_TIME
27 $SNAPSHOT_TIME * * * root "/usr/local/sbin/snapshot-$SERVICE_NAME"

EOF
  done

  log_info "Move the cron file to /etc/cron.d"
  sudo mv "$HOME/snapshot-$SERVICE_NAME" "$cron_target"
  log_info "Change the ownership of the snapshot file"
  sudo chown root: "$cron_target"
  log_info "Change the permission of the snapshot file"
  sudo chmod 644 "$cron_target"
  log_info "Restart the cron service"
  sudo systemctl restart cron
}

validateSnapshotTimeList() {
  local snapshot_times="$1"

  if [ -z "$snapshot_times" ]; then
    log_info "SNAPSHOT_TIME is empty. Snapshot utility will be installed for manual execution only."
    return 0
  fi

  IFS=',' read -ra times <<< "$snapshot_times"
  for time in "${times[@]}"; do
    if [[ "$time" =~ ^\*/[1-9][0-9]*$ ]] || [[ "$time" =~ ^[0-9]+-[0-9]+(/[1-9][0-9]*)?$ ]]; then
      continue
    fi
    if ! [[ "$time" =~ ^[0-9]+$ ]] || [ "$time" -lt 0 ] || [ "$time" -gt 23 ]; then
      log_error "Invalid snapshot time: '$time'. It must be an integer between 0 and 23 or a cron interval like '*/4'."
      return 1
    fi
  done

  return 0
}

function main() {
  # Self-elevate to root if not already
  if [ "$(id -u)" -ne 0 ]; then
      log_info "Elevating permissions to root..."
      # shellcheck disable=SC2093
      exec sudo "$0" "$@" # Re-run the script with sudo
      log_error "Failed to elevate to root. Please run with sudo." # This will only run if exec fails
      exit 1
  fi
  if ! cd "$PATH_TO_ODOO"; then
    log_error "Failed to change directory to $PATH_TO_ODOO"
    exit 1
  fi

  ENABLE_SNAPSHOT=$(grep "^ENABLE_SNAPSHOT=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d "=" -f 2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
  GCS_BUCKET_NAME=$(grep "^GCS_BUCKET_NAME=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d "=" -f 2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
  GDRIVE_ACCESS_TOKEN=$(grep "^GDRIVE_ACCESS_TOKEN=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
  GDRIVE_SERVICE_ACCOUNT_KEY=$(grep "^GDRIVE_SERVICE_ACCOUNT_KEY=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
  SNAPSHOT_TIME_LIST=$(grep "^SNAPSHOT_TIME=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d "=" -f 2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
  SNAPSHOT_REMOTE_HOST=$(grep "^SNAPSHOT_REMOTE_HOST=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d "=" -f 2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
  SNAPSHOT_REMOTE_USER=$(grep "^SNAPSHOT_REMOTE_USER=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d "=" -f 2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
  SNAPSHOT_REMOTE_PORT=$(grep "^SNAPSHOT_REMOTE_PORT=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d "=" -f 2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
  SNAPSHOT_REMOTE_KEY=$(grep "^SNAPSHOT_REMOTE_KEY=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d "=" -f 2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
  [ -z "$SNAPSHOT_REMOTE_PORT" ] && SNAPSHOT_REMOTE_PORT="22"

  validateSnapshotTimeList "$SNAPSHOT_TIME_LIST" || {
    log_error "the SNAPSHOT_TIME is not correct. Please revise it in your .env file."
    exit 1
  }

  log_info "Installing snapshot utility"

  OWNER_HOME=$(eval echo "~$REPOSITORY_OWNER")

  # Validate remote SSH connectivity & prerequisites if SNAPSHOT_REMOTE_HOST is set
  if [ -n "$SNAPSHOT_REMOTE_HOST" ]; then
    if [ -z "$SNAPSHOT_REMOTE_USER" ]; then
      log_error "SNAPSHOT_REMOTE_USER must be set in .env when SNAPSHOT_REMOTE_HOST is specified."
      exit 1
    fi

    THIS_VPS_HOSTNAME=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "vps-source")
    CLEAN_TARGET_HOSTNAME=$(echo "$SNAPSHOT_REMOTE_HOST" | sed -e 's|^.*://||' -e 's|^.*@||' -e 's|:.*$||' -e 's|/.*$||' -e 's|[^a-zA-Z0-9._-]|_|g')

    if [ -z "$SNAPSHOT_REMOTE_KEY" ]; then
      SNAPSHOT_REMOTE_KEY="$OWNER_HOME/.ssh/snapshot-${THIS_VPS_HOSTNAME}-${CLEAN_TARGET_HOSTNAME}"
      log_info "SNAPSHOT_REMOTE_KEY is not defined in .env, defaulting to $SNAPSHOT_REMOTE_KEY"
      if grep -q "^SNAPSHOT_REMOTE_KEY=" "$PATH_TO_ODOO/.env"; then
        sed -i "s|^SNAPSHOT_REMOTE_KEY=.*|SNAPSHOT_REMOTE_KEY=$SNAPSHOT_REMOTE_KEY|" "$PATH_TO_ODOO/.env"
      else
        echo "SNAPSHOT_REMOTE_KEY=$SNAPSHOT_REMOTE_KEY" >> "$PATH_TO_ODOO/.env"
      fi
    fi

    # Expand tilde if user configured path with ~
    SNAPSHOT_REMOTE_KEY="${SNAPSHOT_REMOTE_KEY/#\~/$OWNER_HOME}"

    # Generate SSH key pair if not exists
    if [ ! -f "$SNAPSHOT_REMOTE_KEY" ]; then
      log_info "Generating dedicated SSH key pair at $SNAPSHOT_REMOTE_KEY..."
      mkdir -p "$(dirname "$SNAPSHOT_REMOTE_KEY")"
      chown "$REPOSITORY_OWNER": "$(dirname "$SNAPSHOT_REMOTE_KEY")"
      chmod 700 "$(dirname "$SNAPSHOT_REMOTE_KEY")"
      ssh-keygen -t ed25519 -N "" -f "$SNAPSHOT_REMOTE_KEY" -C "snapshot-${THIS_VPS_HOSTNAME}-${CLEAN_TARGET_HOSTNAME}@${THIS_VPS_HOSTNAME}"
      chown "$REPOSITORY_OWNER": "$SNAPSHOT_REMOTE_KEY" "${SNAPSHOT_REMOTE_KEY}.pub"
      chmod 600 "$SNAPSHOT_REMOTE_KEY"
      chmod 644 "${SNAPSHOT_REMOTE_KEY}.pub"
      log_success "Generated SSH key pair: $SNAPSHOT_REMOTE_KEY"
    fi

    # Verify passwordless SSH connectivity strictly with BatchMode=yes
    local ssh_verified=false
    log_info "Verifying passwordless SSH key authentication with Secondary VPS ($SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST:$SNAPSHOT_REMOTE_PORT)..."
    if ssh -i "$SNAPSHOT_REMOTE_KEY" -p "$SNAPSHOT_REMOTE_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST" "true" 2>/dev/null; then
      log_success "Passwordless SSH key authentication verified on Secondary VPS."
      ssh_verified=true
    else
      log_warn "Passwordless SSH key not yet verified on Secondary VPS ($SNAPSHOT_REMOTE_HOST)."
      echo -ne "${COLOR_WARN}Do you want to automatically copy the public SSH key to Secondary VPS ($SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST)? [y/N]: ${COLOR_RESET}"
      read -r copy_confirm
      if [[ "$copy_confirm" =~ ^[Yy]$ ]]; then
        log_info "Copying public SSH key to Secondary VPS (you may be prompted for password)..."

        if command -v ssh-copy-id >/dev/null 2>&1; then
          ssh-copy-id -i "${SNAPSHOT_REMOTE_KEY}.pub" -p "$SNAPSHOT_REMOTE_PORT" -o StrictHostKeyChecking=accept-new "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST" || true
        else
          cat "${SNAPSHOT_REMOTE_KEY}.pub" | ssh -p "$SNAPSHOT_REMOTE_PORT" -o StrictHostKeyChecking=accept-new "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" || true
        fi

        # Re-verify with BatchMode=yes
        if ssh -i "$SNAPSHOT_REMOTE_KEY" -p "$SNAPSHOT_REMOTE_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST" "true" 2>/dev/null; then
          log_success "Passwordless SSH key installed and verified on Secondary VPS."
          ssh_verified=true
        else
          log_warn "Automatic key copy did not result in verified passwordless SSH access."
        fi
      else
        log_info "Skipping automatic SSH key copy to Secondary VPS."
      fi
    fi

    if [ "$ssh_verified" = false ]; then
      local pub_key_content
      pub_key_content=$(cat "${SNAPSHOT_REMOTE_KEY}.pub" 2>/dev/null || echo "")
      TODO_LIST+=("SSH Key Registration on Secondary VPS:
  Key File   : $SNAPSHOT_REMOTE_KEY
  Public Key :
  ${pub_key_content}

  Please manually authorize this public key on the Secondary VPS (${SNAPSHOT_REMOTE_HOST}) as user '${SNAPSHOT_REMOTE_USER}':
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    echo '${pub_key_content}' >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys

  Test the connection afterwards from this VPS:
    ssh -i $SNAPSHOT_REMOTE_KEY -p $SNAPSHOT_REMOTE_PORT -o BatchMode=yes $SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST 'echo Connection successful'")
    fi

    local ssh_test_opts=(-i "$SNAPSHOT_REMOTE_KEY" -p "$SNAPSHOT_REMOTE_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

    if [ -n "$GCS_BUCKET_NAME" ]; then
      if [ "$ssh_verified" = true ]; then
        log_info "Checking Google Cloud Storage access on Secondary VPS..."
        if ! ssh "${ssh_test_opts[@]}" "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST" "command -v gcloud >/dev/null 2>&1" 2>/dev/null; then
          log_warn "gcloud CLI is not installed on Secondary VPS ($SNAPSHOT_REMOTE_HOST)."
        elif ! ssh "${ssh_test_opts[@]}" "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST" "gcloud storage ls 'gs://$GCS_BUCKET_NAME' >/dev/null 2>&1" 2>/dev/null; then
          log_warn "Secondary VPS cannot access bucket gs://$GCS_BUCKET_NAME. Ensure gcloud is authenticated on Secondary VPS."
        else
          log_success "Secondary VPS has verified access to gs://$GCS_BUCKET_NAME."
        fi
      else
        log_warn "Google Cloud Storage verification skipped because SSH access to Secondary VPS is pending."
        TODO_LIST+=("Google Cloud Storage on Secondary VPS:
  Once SSH key is authorized, ensure gcloud is installed and authenticated to access gs://$GCS_BUCKET_NAME.")
      fi
    fi
  fi

  log_info "Copying the latest script from the example script"
  if OUTPUT_RSYNC_COMMAND=$(rsync -acz ./scripts/example/snapshot.sh.example "./scripts/snapshot-$SERVICE_NAME" 2>&1); then
    log_success "Copied the latest script from the example script."
  else
    log_error "Failed to copy the latest script from the example script ➡️ $OUTPUT_RSYNC_COMMAND"
    exit 1
  fi

  log_info "Changing the permission of the script"
  chmod 755 "./scripts/snapshot-$SERVICE_NAME"

  log_info "Create a softlink to /usr/local/sbin"
  if OUTPUT_LN_COMMAND=$(ln -sf "$PATH_TO_ODOO/scripts/snapshot-$SERVICE_NAME" /usr/local/sbin/snapshot-"$SERVICE_NAME" 2>&1); then
    log_success "Created a symbolic link to /usr/local/sbin/snapshot-$SERVICE_NAME"
  else
    log_warn "Failed to create a symbolic link to /usr/local/sbin/snapshot-$SERVICE_NAME ➡️ $OUTPUT_LN_COMMAND"
  fi

  if [ -f "$PATH_TO_ODOO/scripts/list-snapshot.sh" ]; then
    ln -sf "$PATH_TO_ODOO/scripts/list-snapshot.sh" "/usr/local/sbin/list-snapshot-$SERVICE_NAME" 2>/dev/null || true
  fi

  if [ -f "$PATH_TO_ODOO/scripts/download-snapshot.sh" ]; then
    ln -sf "$PATH_TO_ODOO/scripts/download-snapshot.sh" "/usr/local/sbin/download-snapshot-$SERVICE_NAME" 2>/dev/null || true
  fi

  if [ -f "$PATH_TO_ODOO/scripts/upload-snapshot.sh" ]; then
    ln -sf "$PATH_TO_ODOO/scripts/upload-snapshot.sh" "/usr/local/sbin/upload-snapshot-$SERVICE_NAME" 2>/dev/null || true
  fi

  installCronJob "$GCS_BUCKET_NAME" "$SNAPSHOT_TIME_LIST" "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_SERVICE_ACCOUNT_KEY" "$SNAPSHOT_REMOTE_HOST" "$ENABLE_SNAPSHOT"

  # Ensure local prerequisites
  if zstd --version > /dev/null 2>&1; then
    log_success "zstd is already installed"
  else
    log_info "Install zstd"
    if sudo apt install zstd -y; then
      log_success "zstd is installed"
    else
      log_error "Failed to install zstd"
      exit 1
    fi
  fi

  if zip --version > /dev/null 2>&1; then
    log_success "zip is already installed"
  else
    log_info "Install zip"
    if sudo apt install zip -y; then
      log_success "zip is installed"
    else
      log_error "Failed to install zip"
      exit 1
    fi
  fi

  if curl --version > /dev/null 2>&1; then
    log_success "curl is already installed"
  else
    log_info "Install curl"
    if sudo apt install curl -y; then
      log_success "curl is installed"
    else
      log_error "Failed to install curl"
      exit 1
    fi
  fi

  if rsync --version > /dev/null 2>&1; then
    log_success "rsync is already installed"
  else
    log_info "Install rsync"
    if sudo apt install rsync -y; then
      log_success "rsync is installed"
    else
      log_error "Failed to install rsync"
      exit 1
    fi
  fi

  log_info "Install the logrotate utility"
  cat << EOF | sudo tee "$HOME/snapshot-$SERVICE_NAME" > /dev/null
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

  log_info "Change the ownership of the logrotate file"
  sudo chown root: "$HOME/snapshot-$SERVICE_NAME"
  log_info "Change the permission of the logrotate file"
  sudo chmod 644 "$HOME/snapshot-$SERVICE_NAME"
  log_info "Move the logrotate file to /etc/logrotate.d"
  sudo mv "$HOME/snapshot-$SERVICE_NAME" "/etc/logrotate.d/snapshot-$SERVICE_NAME"

  log_success "Installation finished"

  if [ ${#TODO_LIST[@]} -gt 0 ]; then
    echo ""
    echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
    echo -e "${COLOR_WARN}${COLOR_BOLD}📋 TODO / PENDING ACTIONS FOR SNAPSHOT SETUP${COLOR_RESET}"
    echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
    for todo in "${TODO_LIST[@]}"; do
      echo -e "$todo"
      echo -e "${COLOR_BOLD}--------------------------------------------------------------------------------${COLOR_RESET}"
    done
    echo ""
  fi
}

main "$@"
