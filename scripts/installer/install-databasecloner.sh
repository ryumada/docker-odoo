#!/usr/bin/env bash
set -e
# Category: Installer
# Description: Installs the databasecloner utility (Standard or Manual) based on .env config.
# Usage: ./scripts/installer/install-databasecloner.sh
# Dependencies: rsync, git, sudo, ssh, ssh-keygen

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

# Source shared SSH utilities
if [ -f "$PATH_TO_ODOO/scripts/lib/ssh_utils.sh" ]; then
  source "$PATH_TO_ODOO/scripts/lib/ssh_utils.sh"
fi

# --- Logging Functions & Colors ---
# Define colors for log messages
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[0;31m"
readonly COLOR_CYAN="\033[0;36m"
readonly COLOR_BOLD="\033[1m"

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

function install_script() {
    local link_name="$1"
    local source_path="$2"
    local target_path="$3"

    log_info "Processing $target_path..."
    log_info "Copying from: $source_path"

    if OUTPUT_RSYNC_COMMAND=$(rsync -acz "$source_path" "$target_path" 2>&1); then
        log_success "Copied script file successfully."
    else
        log_error "Failed to copy script ➡️ $OUTPUT_RSYNC_COMMAND"
        exit 1
    fi

    log_info "Changing permission to 755"
    chmod 755 "$target_path"

    log_info "Linking /usr/local/sbin/$link_name"

    # Using -sf to force overwrite if the link already exists
    if OUTPUT_LN_COMMAND=$(ln -sf "$target_path" "/usr/local/sbin/$link_name" 2>&1); then
        log_success "Created symbolic link: /usr/local/sbin/$link_name"
    else
        log_error "Failed to create symbolic link ➡️ $OUTPUT_LN_COMMAND"
    fi
}

function main() {
    # Self-elevate to root if not already
    if [ "$(id -u)" -ne 0 ]; then
        log_info "Elevating permissions to root..."
        # shellcheck disable=SC2093
        exec sudo "$0" "$@"
        log_error "Failed to elevate to root."
        exit 1
    fi

    if ! cd "$PATH_TO_ODOO"; then
        log_error "Failed to change directory to $PATH_TO_ODOO"
        exit 1
    fi

    log_info "Checking configuration in .env file..."

    local ENV_FILE_PATH="$PATH_TO_ODOO/.env"
    local BACKUP_RESTORE_METHOD

    if [ -f "$ENV_FILE_PATH" ]; then
        log_info "Found .env file at: $ENV_FILE_PATH"
        BACKUP_RESTORE_METHOD=$(grep "^BACKUP_RESTORE_METHOD=" "$PATH_TO_ODOO/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
    else
        log_error "No .env file found at: $ENV_FILE_PATH"
        exit 1
    fi

    if [ -z "$BACKUP_RESTORE_METHOD" ]; then
        BACKUP_RESTORE_METHOD="manual"
    fi

    local link_name="databasecloner-$SERVICE_NAME"
    local script_filename="$link_name.sh"
    local target_path="$PATH_TO_ODOO/scripts/$script_filename"
    local source_path

    if [ "$BACKUP_RESTORE_METHOD" == "endpoint" ]; then
      log_info "Installing databasecloner utility using standard Odoo endpoint method for service: $SERVICE_NAME"
      source_path="$PATH_TO_ODOO/scripts/example/databasecloner.sh.example"
    else
      log_info "Installing databasecloner utility using method '$BACKUP_RESTORE_METHOD' for service: $SERVICE_NAME"
      source_path="$PATH_TO_ODOO/scripts/example/databasecloner_manual.sh.example"
    fi

    install_script "$link_name" "$source_path" "$target_path"

    # Cross-VPS Remote SSH Cloner Validation & Setup
    local CLONER_SSH_HOST
    CLONER_SSH_HOST=$(grep "^CLONER_SSH_HOST=" "$ENV_FILE_PATH" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)

    if [ -n "$CLONER_SSH_HOST" ]; then
      log_info "Detected cross-VPS configuration for Database Cloner (CLONER_SSH_HOST=$CLONER_SSH_HOST)."
      local CLONER_SSH_USER CLONER_SSH_PORT CLONER_SSH_KEY CLONER_SSH_DEST_PATH
      CLONER_SSH_USER=$(grep "^CLONER_SSH_USER=" "$ENV_FILE_PATH" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
      CLONER_SSH_PORT=$(grep "^CLONER_SSH_PORT=" "$ENV_FILE_PATH" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
      CLONER_SSH_KEY=$(grep "^CLONER_SSH_KEY=" "$ENV_FILE_PATH" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
      CLONER_SSH_DEST_PATH=$(grep "^CLONER_SSH_DEST_PATH=" "$ENV_FILE_PATH" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)

      [ -z "$CLONER_SSH_PORT" ] && CLONER_SSH_PORT="22"
      [ -z "$CLONER_SSH_USER" ] && CLONER_SSH_USER="$REPOSITORY_OWNER"

      if [ -z "$CLONER_SSH_DEST_PATH" ]; then
        log_warn "CLONER_SSH_DEST_PATH is not defined in .env. Remote cloning requires the absolute path to destination docker-odoo root."
      fi

      local OWNER_HOME
      OWNER_HOME=$(eval echo "~$REPOSITORY_OWNER")
      local THIS_VPS_HOSTNAME CLEAN_TARGET_HOSTNAME
      THIS_VPS_HOSTNAME=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "vps-source")
      CLEAN_TARGET_HOSTNAME=$(echo "$CLONER_SSH_HOST" | sed -e 's|^.*://||' -e 's|^.*@||' -e 's|:.*$||' -e 's|/.*$||' -e 's|[^a-zA-Z0-9._-]|_|g')

      if [ -z "$CLONER_SSH_KEY" ]; then
        CLONER_SSH_KEY="$OWNER_HOME/.ssh/cloner-${THIS_VPS_HOSTNAME}-${CLEAN_TARGET_HOSTNAME}"
        log_info "CLONER_SSH_KEY is not defined in .env, defaulting to $CLONER_SSH_KEY"
        if grep -q "^CLONER_SSH_KEY=" "$ENV_FILE_PATH"; then
          sed -i "s|^CLONER_SSH_KEY=.*|CLONER_SSH_KEY=$CLONER_SSH_KEY|" "$ENV_FILE_PATH"
        else
          echo "CLONER_SSH_KEY=$CLONER_SSH_KEY" >> "$ENV_FILE_PATH"
        fi
      fi

      CLONER_SSH_KEY="${CLONER_SSH_KEY/#\~/$OWNER_HOME}"

      if [ ! -f "$CLONER_SSH_KEY" ]; then
        log_info "Generating dedicated ed25519 SSH key pair at $CLONER_SSH_KEY..."
        mkdir -p "$(dirname "$CLONER_SSH_KEY")"
        chown "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$(dirname "$CLONER_SSH_KEY")"
        chmod 700 "$(dirname "$CLONER_SSH_KEY")"
        ssh-keygen -t ed25519 -N "" -f "$CLONER_SSH_KEY" -C "cloner-${THIS_VPS_HOSTNAME}-${CLEAN_TARGET_HOSTNAME}@${THIS_VPS_HOSTNAME}"
        chown "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$CLONER_SSH_KEY" "${CLONER_SSH_KEY}.pub"
        chmod 600 "$CLONER_SSH_KEY"
        chmod 644 "${CLONER_SSH_KEY}.pub"
        log_success "Generated SSH key pair: $CLONER_SSH_KEY"
      fi

      local ssh_verified=false
      log_info "Verifying passwordless SSH key authentication with Remote VPS ($CLONER_SSH_USER@$CLONER_SSH_HOST:$CLONER_SSH_PORT)..."
      if ssh -i "$CLONER_SSH_KEY" -p "$CLONER_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$CLONER_SSH_USER@$CLONER_SSH_HOST" "true" 2>/dev/null; then
        log_success "Passwordless SSH key authentication verified on Remote VPS."
        ssh_verified=true
      else
        log_warn "Passwordless SSH key not yet verified on Remote VPS ($CLONER_SSH_HOST)."
        echo -e "${COLOR_WARN}Choose an option to install SSH key on Remote VPS:${COLOR_RESET}"
        echo "  [1] Password authentication as '$CLONER_SSH_USER' (via ssh-copy-id)"
        echo "  [2] Administrator account with sudo (installs key, sets up permissions and sudoers)"
        echo "  [N] Skip automatic setup (show manual configuration instructions)"
        echo -ne "${COLOR_CYAN}Select option [1/2/N] (default: 2): ${COLOR_RESET}"
        read -r cloner_auth_choice
        [ -z "$cloner_auth_choice" ] && cloner_auth_choice="2"

        if [ "$cloner_auth_choice" = "1" ]; then
          log_info "Copying public SSH key to Remote VPS as '$CLONER_SSH_USER'..."
          if command -v ssh-copy-id >/dev/null 2>&1; then
            ssh-copy-id -i "${CLONER_SSH_KEY}.pub" -p "$CLONER_SSH_PORT" -o StrictHostKeyChecking=accept-new "$CLONER_SSH_USER@$CLONER_SSH_HOST" || true
          else
            cat "${CLONER_SSH_KEY}.pub" | ssh -p "$CLONER_SSH_PORT" -o StrictHostKeyChecking=accept-new "$CLONER_SSH_USER@$CLONER_SSH_HOST" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" || true
          fi
        elif [ "$cloner_auth_choice" = "2" ]; then
          echo -ne "${COLOR_CYAN}Enter remote sudo administrator username: ${COLOR_RESET}"
          read -r remote_admin_user
          if [ -n "$remote_admin_user" ]; then
            echo -ne "${COLOR_CYAN}Enter password for '$remote_admin_user': ${COLOR_RESET}"
            read -s -r remote_admin_password
            echo ""
            local dest_svc_param=""
            [ -n "$CLONER_SSH_DEST_PATH" ] && dest_svc_param=$(basename "$CLONER_SSH_DEST_PATH")
            if declare -f install_pubkey_via_admin >/dev/null 2>&1; then
              install_pubkey_via_admin "$CLONER_SSH_HOST" "$CLONER_SSH_PORT" "$remote_admin_user" "$CLONER_SSH_USER" "${CLONER_SSH_KEY}.pub" "auto" "cloner" "$dest_svc_param" "$CLONER_SSH_DEST_PATH" "$remote_admin_password" || true
            else
              log_error "install_pubkey_via_admin function not available."
            fi
          else
            log_warn "No administrator user entered. Skipping admin provisioning."
          fi
        else
          log_info "Skipping automatic SSH key provisioning to Remote VPS."
        fi

        # Re-verify with BatchMode=yes
        if ssh -i "$CLONER_SSH_KEY" -p "$CLONER_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$CLONER_SSH_USER@$CLONER_SSH_HOST" "true" 2>/dev/null; then
          log_success "Passwordless SSH key installed and verified on Remote VPS."
          ssh_verified=true
        else
          log_warn "Automatic key copy did not result in verified passwordless SSH access."
        fi
      fi

      # Remote environment and sudo verification
      if [ "$ssh_verified" = true ] && [ -n "$CLONER_SSH_DEST_PATH" ]; then
        log_info "Checking destination path on Remote VPS ($CLONER_SSH_DEST_PATH)..."
        local dest_svc_name
        dest_svc_name=$(basename "$CLONER_SSH_DEST_PATH")
        local cloner_ssh_opts=(-i "$CLONER_SSH_KEY" -p "$CLONER_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

        if ! ssh "${cloner_ssh_opts[@]}" "$CLONER_SSH_USER@$CLONER_SSH_HOST" "[ -d '$CLONER_SSH_DEST_PATH' ]" 2>/dev/null; then
          log_warn "Destination directory '$CLONER_SSH_DEST_PATH' not found on Remote VPS."
        else
          log_success "Destination path '$CLONER_SSH_DEST_PATH' exists on Remote VPS."
          # Verify sudo access for restore script
          if ssh "${cloner_ssh_opts[@]}" "$CLONER_SSH_USER@$CLONER_SSH_HOST" "sudo -n true" 2>/dev/null; then
            log_success "Remote user '$CLONER_SSH_USER' has verified sudo execution permissions."
          else
            log_warn "Remote user '$CLONER_SSH_USER' cannot run 'sudo -n true'. Ensure sudoers permissions are configured on Remote VPS."
          fi
        fi
      fi
    fi

    log_success "All Database Cloner scripts installed successfully."
    exit 0
}

main "$@"
