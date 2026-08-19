#!/usr/bin/env bash
set -e
# Category: Installer
# Description: Upgrades and installs the snapshot utility from the example script.
# Usage: ./scripts/installer/install-snapshot.sh
# Dependencies: rsync, git, sudo, cron, ssh

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

  if [ -z "$GCS_BUCKET_NAME" ]; then
    log_warn "GCS_BUCKET_NAME is not set in the .env file. The snapshot will not run automatically."
  else
    log_info "Create a cron to run automatically the snapshot script."
    cat << EOF > "$HOME/snapshot-$SERVICE_NAME"
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

EOF

    # Why on minute 27? I just want to avoid the cron from the application run altogether with this snapshot cron
    if [ -z "$SNAPSHOT_TIME_LIST" ]; then
      cat << EOF >> "$HOME/snapshot-$SERVICE_NAME"
# Run the snapshot script every 4 hours
27 */4 * * * root "/usr/local/sbin/snapshot-$SERVICE_NAME"

EOF
    else
      for SNAPSHOT_TIME in $(echo "$SNAPSHOT_TIME_LIST" | tr "," "\n"); do
        cat << EOF >> "$HOME/snapshot-$SERVICE_NAME"
# Run the snapshot script at $SNAPSHOT_TIME
27 $SNAPSHOT_TIME * * * root "/usr/local/sbin/snapshot-$SERVICE_NAME"

EOF
      done
    fi

    log_info "Move the cron file to /etc/cron.d"
    sudo mv "$HOME/snapshot-$SERVICE_NAME" "/etc/cron.d/snapshot-$SERVICE_NAME"
    log_info "Change the ownership of the snapshot file"
    sudo chown root: "/etc/cron.d/snapshot-$SERVICE_NAME"
    log_info "Change the permission of the snapshot file"
    sudo chmod 644 "/etc/cron.d/snapshot-$SERVICE_NAME"
    log_info "Restart the cron service"
    sudo systemctl restart cron
  fi
}

validateSnapshotTimeList() {
  local snapshot_times="$1"

  if [ -z "$snapshot_times" ]; then
    log_warn "SNAPSHOT_TIME_LIST is empty. No validation needed."
    return 0
  fi

  IFS=',' read -ra times <<< "$snapshot_times"
  for time in "${times[@]}"; do
    if ! [[ "$time" =~ ^[0-9]+$ ]] || [ "$time" -lt 0 ] || [ "$time" -gt 23 ]; then
      log_error "Invalid snapshot time: $time. It must be an integer between 0 and 23."
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

  GCS_BUCKET_NAME=$(grep "^GCS_BUCKET_NAME=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d "=" -f 2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
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

  # Validate remote SSH connectivity & prerequisites if SNAPSHOT_REMOTE_HOST is set
  if [ -n "$SNAPSHOT_REMOTE_HOST" ]; then
    if [ -z "$SNAPSHOT_REMOTE_USER" ]; then
      log_error "SNAPSHOT_REMOTE_USER must be set in .env when SNAPSHOT_REMOTE_HOST is specified."
      exit 1
    fi

    local ssh_test_opts=(-p "$SNAPSHOT_REMOTE_PORT" -o StrictHostKeyChecking=accept-new)
    if [ -n "$SNAPSHOT_REMOTE_KEY" ]; then
      ssh_test_opts+=(-i "$SNAPSHOT_REMOTE_KEY")
    fi

    log_info "Testing SSH connectivity to Secondary VPS ($SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST:$SNAPSHOT_REMOTE_PORT)..."
    if ! ssh "${ssh_test_opts[@]}" "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST" "true" 2>/dev/null; then
      log_warn "Could not connect to Secondary VPS via SSH. Please verify SSH key setup and network connectivity."
    else
      log_success "SSH connection to Secondary VPS verified."

      if [ -n "$GCS_BUCKET_NAME" ]; then
        log_info "Checking Google Cloud Storage access on Secondary VPS..."
        if ! ssh "${ssh_test_opts[@]}" "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST" "command -v gcloud >/dev/null 2>&1" 2>/dev/null; then
          log_warn "gcloud CLI is not installed on Secondary VPS ($SNAPSHOT_REMOTE_HOST)."
        elif ! ssh "${ssh_test_opts[@]}" "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST" "gcloud storage ls 'gs://$GCS_BUCKET_NAME' >/dev/null 2>&1" 2>/dev/null; then
          log_warn "Secondary VPS cannot access bucket gs://$GCS_BUCKET_NAME. Ensure gcloud is authenticated on Secondary VPS."
        else
          log_success "Secondary VPS has verified access to gs://$GCS_BUCKET_NAME."
        fi
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

  installCronJob "$GCS_BUCKET_NAME" "$SNAPSHOT_TIME_LIST"

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
}

main "$@"
