#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Switch the Odoo deployment environment dynamically and restart container.
# Usage: ./scripts/switch_env.sh <deployment_name>
# Dependencies: docker, git, sudo, sed, awk, grep

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

# --- Logging Functions & Colors ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[0;31m"

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

error_handler() {
  local exit_code=$1
  local line_no=$2
  local command_name=$3
  log_error "An error occurred on line $line_no."
  log_error "Exit Code: $exit_code"
  log_error "Command: $command_name"
  exit "$exit_code"
}

trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR

# Self-elevate to root if not already
if [ "$(id -u)" -ne 0 ]; then
    log_info "Elevating permissions to root..."
    exec sudo "$0" "$@"
fi

# Ensure .env file exists
ENV_FILE_PATH="$PATH_TO_ODOO/.env"
if [ ! -f "$ENV_FILE_PATH" ]; then
    log_error ".env file does not exist. Please run setup.sh first."
    exit 1
fi

# Read ENABLE_MULTI_DEPLOYMENT toggle from .env
ENABLE_MULTI_DEPLOYMENT=$(grep "^ENABLE_MULTI_DEPLOYMENT=" "$ENV_FILE_PATH" | cut -d "=" -f 2- | sed 's/[[:space:]]*#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^["'\''\\]*//; s/["'\''\\]*$//')

if [[ ! "$ENABLE_MULTI_DEPLOYMENT" =~ ^([yY][eE][sS]|[yY]|1|true|TRUE)$ ]]; then
    log_warn "Multi-deployment is disabled (ENABLE_MULTI_DEPLOYMENT is '$ENABLE_MULTI_DEPLOYMENT')."
    log_info "Single-deployment mode remains active. Bypassing environment switch."
    exit 0
fi

# Discover available deployment directories under deployments/
DEPLOYMENTS_DIR="$PATH_TO_ODOO/deployments"
AVAILABLE_DEPLOYMENTS=()
if [ -d "$DEPLOYMENTS_DIR" ]; then
    for dir in "$DEPLOYMENTS_DIR"/*/; do
        if [ -d "$dir" ]; then
            dep_name=$(basename "$dir")
            AVAILABLE_DEPLOYMENTS+=("$dep_name")
        fi
    done
fi

if [ ${#AVAILABLE_DEPLOYMENTS[@]} -eq 0 ]; then
    log_error "No deployment profiles found under '$DEPLOYMENTS_DIR/' directory."
    exit 1
fi

TARGET_DEPLOYMENT="$1"
# Verify target deployment argument is provided
if [ -z "$TARGET_DEPLOYMENT" ]; then
    log_error "Target deployment name is required."
    echo "Usage: $0 <deployment_name>"
    echo "Available deployments: ${AVAILABLE_DEPLOYMENTS[*]}"
    exit 1
fi

# Check if target deployment directory exists
TARGET_DEP_DIR="$DEPLOYMENTS_DIR/$TARGET_DEPLOYMENT"
if [ ! -d "$TARGET_DEP_DIR" ]; then
    log_error "Deployment '$TARGET_DEPLOYMENT' profile directory does not exist at '$TARGET_DEP_DIR'."
    echo "Available deployments: ${AVAILABLE_DEPLOYMENTS[*]}"
    exit 1
fi

# Determine deployment env file (.env or .env.example)
DEP_ENV_FILE="$TARGET_DEP_DIR/.env"
if [ ! -f "$DEP_ENV_FILE" ] && [ -f "$TARGET_DEP_DIR/.env.example" ]; then
    log_info "Creating $DEP_ENV_FILE from template..."
    cp "$TARGET_DEP_DIR/.env.example" "$DEP_ENV_FILE"
    chown "$REPOSITORY_OWNER:$REPOSITORY_OWNER" "$DEP_ENV_FILE" 2>/dev/null || true
fi

if [ ! -f "$DEP_ENV_FILE" ]; then
    log_error "Deployment environment file not found: $DEP_ENV_FILE"
    exit 1
fi

# Extract deployment configurations
EXTRACTED_ADDONS=$(grep "^ADDONS_PATH=" "$DEP_ENV_FILE" 2>/dev/null | cut -d "=" -f 2- | sed 's/^["'\''\\]*//; s/["'\''\\]*$//')
EXTRACTED_BASE_PATH=$(grep "^ODOO_BASE_PATH=" "$DEP_ENV_FILE" 2>/dev/null | cut -d "=" -f 2- | sed 's/^["'\''\\]*//; s/["'\''\\]*$//')
[ -z "$EXTRACTED_BASE_PATH" ] && EXTRACTED_BASE_PATH="odoo16"

# Automatically define DB user by service name and target deployment name
EXTRACTED_DB_USER="${SERVICE_NAME}_${TARGET_DEPLOYMENT}"

# Verify Odoo base path directory exists on the host
FULL_BASE_PATH="$PATH_TO_ODOO/odoo-base/$EXTRACTED_BASE_PATH"
if [ ! -d "$FULL_BASE_PATH" ]; then
    log_error "Target base directory does not exist: $FULL_BASE_PATH"
    exit 1
fi

# Sync deployment requirements.txt if present
if [ -f "$TARGET_DEP_DIR/requirements.txt" ]; then
    log_info "Syncing requirements.txt for '$TARGET_DEPLOYMENT'..."
    cp "$TARGET_DEP_DIR/requirements.txt" "$PATH_TO_ODOO/requirements.txt"
    chown "$REPOSITORY_OWNER:$REPOSITORY_OWNER" "$PATH_TO_ODOO/requirements.txt" 2>/dev/null || true
elif [ -f "$TARGET_DEP_DIR/requirements.txt.example" ] && [ ! -f "$PATH_TO_ODOO/requirements.txt" ]; then
    cp "$TARGET_DEP_DIR/requirements.txt.example" "$PATH_TO_ODOO/requirements.txt"
    chown "$REPOSITORY_OWNER:$REPOSITORY_OWNER" "$PATH_TO_ODOO/requirements.txt" 2>/dev/null || true
fi

# Sync deployment dockerfile if custom one exists in deployment directory
if [ -f "$TARGET_DEP_DIR/dockerfile" ]; then
    log_info "Syncing custom dockerfile for '$TARGET_DEPLOYMENT'..."
    cp "$TARGET_DEP_DIR/dockerfile" "$PATH_TO_ODOO/dockerfile"
    chown "$REPOSITORY_OWNER:$REPOSITORY_OWNER" "$PATH_TO_ODOO/dockerfile" 2>/dev/null || true
fi

# Verify docker-compose.yml exists, if not, copy it from example
if [ ! -f "$PATH_TO_ODOO/docker-compose.yml" ] && [ -f "$PATH_TO_ODOO/docker-compose.yml.example" ]; then
    log_info "docker-compose.yml not found. Copying from docker-compose.yml.example..."
    sudo -u "$REPOSITORY_OWNER" cp "$PATH_TO_ODOO/docker-compose.yml.example" "$PATH_TO_ODOO/docker-compose.yml"
fi

# Shut down the current container
log_info "Stopping current active container..."
if [ -f "$PATH_TO_ODOO/docker-compose.yml" ]; then
    sudo -u "$REPOSITORY_OWNER" docker compose -f "$PATH_TO_ODOO/docker-compose.yml" down || true
fi

# Function to update or append variable in .env
update_env_var() {
    local var_name="$1"
    local var_value="$2"
    local escaped_value
    escaped_value=$(echo "$var_value" | sed 's/[&\|]/\\&/g')
    if grep -q "^$var_name=" "$ENV_FILE_PATH"; then
        sed -i "s|^$var_name=.*|$var_name=$escaped_value|" "$ENV_FILE_PATH"
    else
        echo "$var_name=$var_value" >> "$ENV_FILE_PATH"
    fi
}

log_info "Stamping deployment variables in .env..."
update_env_var "ACTIVE_DEPLOYMENT" "$TARGET_DEPLOYMENT"
update_env_var "ACTIVE_SERVICE_NAME" "${SERVICE_NAME}-${TARGET_DEPLOYMENT}"
update_env_var "ACTIVE_DB_USER" "$EXTRACTED_DB_USER"
update_env_var "ACTIVE_ODOO_BASE_PATH" "$EXTRACTED_BASE_PATH"
update_env_var "ACTIVE_ODOO_BASE_CONTAINER_PATH" "/opt/odoo/odoo-base/active_odoo_base"
update_env_var "ODOO_LOG_DIR_SERVICE" "/var/log/odoo/${SERVICE_NAME}-${TARGET_DEPLOYMENT}"
update_env_var "ODOO_DATADIR_SERVICE" "/var/lib/odoo/${SERVICE_NAME}-${TARGET_DEPLOYMENT}"
update_env_var "ODOO_IMAGE_NAME" "${SERVICE_NAME}-${TARGET_DEPLOYMENT}"

# Sync all non-empty per-deployment variables into active root .env
while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    if [[ "$line" =~ ^([A-Za-z0-9_]+)=(.*)$ ]]; then
        var_key="${BASH_REMATCH[1]}"
        var_val="${BASH_REMATCH[2]}"
        var_val=$(echo "$var_val" | sed 's/^["'\''\\]*//; s/["'\''\\]*$//')
        # Do not override system active metadata variables dynamically
        if [[ "$var_key" != "ACTIVE_"* ]]; then
            update_env_var "$var_key" "$var_val"
        fi
    fi
done < <(tr -d '\r' < "$DEP_ENV_FILE")

# Sync deployment-specific secret files (.secrets/db_user_<dep> & .secrets/db_password_<dep>)
SECRETS_DIR="$PATH_TO_ODOO/.secrets"
DEP_DB_USER_FILE="$SECRETS_DIR/db_user_${TARGET_DEPLOYMENT}"
DEP_DB_PASS_FILE="$SECRETS_DIR/db_password_${TARGET_DEPLOYMENT}"
ACTIVE_DB_USER_FILE="$SECRETS_DIR/db_user"
ACTIVE_DB_PASS_FILE="$SECRETS_DIR/db_password"

if [ -d "$SECRETS_DIR" ]; then
    log_info "Syncing deployment secret files for $TARGET_DEPLOYMENT..."

    # User secret
    if [ -f "$DEP_DB_USER_FILE" ]; then
        cp "$DEP_DB_USER_FILE" "$ACTIVE_DB_USER_FILE"
    else
        echo "$EXTRACTED_DB_USER" > "$ACTIVE_DB_USER_FILE"
        cp "$ACTIVE_DB_USER_FILE" "$DEP_DB_USER_FILE"
    fi
    chown "$REPOSITORY_OWNER:$REPOSITORY_OWNER" "$ACTIVE_DB_USER_FILE" "$DEP_DB_USER_FILE" 2>/dev/null || true

    # Password secret
    if [ -f "$DEP_DB_PASS_FILE" ]; then
        cp "$DEP_DB_PASS_FILE" "$ACTIVE_DB_PASS_FILE"
    elif [ -f "$ACTIVE_DB_PASS_FILE" ]; then
        cp "$ACTIVE_DB_PASS_FILE" "$DEP_DB_PASS_FILE"
    fi
    [ -f "$ACTIVE_DB_PASS_FILE" ] && chown "$REPOSITORY_OWNER:$REPOSITORY_OWNER" "$ACTIVE_DB_PASS_FILE" 2>/dev/null || true
    [ -f "$DEP_DB_PASS_FILE" ] && chown "$REPOSITORY_OWNER:$REPOSITORY_OWNER" "$DEP_DB_PASS_FILE" 2>/dev/null || true
fi

# Re-read values for host directory creation
DATADIR="/var/lib/odoo/${SERVICE_NAME}-${TARGET_DEPLOYMENT}"
LOGDIR="/var/log/odoo/${SERVICE_NAME}-${TARGET_DEPLOYMENT}"
ODOO_LINUX_USER="odoo"

# Automatically create directories on the host
log_info "Provisioning directories on the host..."
mkdir -p "$DATADIR/filestore" "$LOGDIR"
chown -R "$ODOO_LINUX_USER":"$ODOO_LINUX_USER" "$DATADIR" "$LOGDIR"

# Run setup script to update configuration and trigger container deployment mode
"$PATH_TO_ODOO/setup.sh" auto

log_success "Deployment successfully switched to '$TARGET_DEPLOYMENT'."
