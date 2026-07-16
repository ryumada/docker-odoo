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

# Read AVAILABLE_DEPLOYMENTS from .env
AVAILABLE_DEPLOYMENTS=$(grep "^AVAILABLE_DEPLOYMENTS=" "$ENV_FILE_PATH" | cut -d "=" -f 2- | sed 's/^[[:space:]\n]*//g; s/[[:space:]\n]*$//g')

if [ -z "$AVAILABLE_DEPLOYMENTS" ]; then
    log_warn "Multi-deployment is not configured (AVAILABLE_DEPLOYMENTS is empty)."
    log_info "Single-deployment mode remains active. Bypassing switch."
    exit 0
fi

TARGET_DEPLOYMENT="$1"
# Verify target deployment argument is provided
if [ -z "$TARGET_DEPLOYMENT" ]; then
    log_error "Target deployment name is required."
    echo "Usage: $0 <deployment_name>"
    echo "Available deployments: $(echo "$AVAILABLE_DEPLOYMENTS" | tr ';' ' ')"
    exit 1
fi

# Check if target deployment is in the available deployments registry
IFS=';' read -ra DEPLOYMENTS_ARR <<< "$AVAILABLE_DEPLOYMENTS"
IS_VALID=false
for dep in "${DEPLOYMENTS_ARR[@]}"; do
    if [ "$dep" = "$TARGET_DEPLOYMENT" ]; then
        IS_VALID=true
        break
    fi
done

if [ "$IS_VALID" = false ]; then
    log_error "Deployment '$TARGET_DEPLOYMENT' is not registered in AVAILABLE_DEPLOYMENTS."
    echo "Available deployments: $(echo "$AVAILABLE_DEPLOYMENTS" | tr ';' ' ')"
    exit 1
fi

# Extract target's specific addons path
AVAILABLE_ADDONS_PATHS=$(grep "^AVAILABLE_ADDONS_PATHS=" "$ENV_FILE_PATH" | cut -d "=" -f 2- | sed 's/^["'\''\\]*//; s/["'\''\\]*$//')
IFS=';' read -ra ADDONS_ARR <<< "$AVAILABLE_ADDONS_PATHS"
EXTRACTED_ADDONS=""
for item in "${ADDONS_ARR[@]}"; do
    if [[ "$item" =~ ^${TARGET_DEPLOYMENT}:(.*) ]]; then
        EXTRACTED_ADDONS="${BASH_REMATCH[1]}"
        break
    fi
done

if [ -z "$EXTRACTED_ADDONS" ]; then
    log_error "No addons path configured for deployment '$TARGET_DEPLOYMENT' in AVAILABLE_ADDONS_PATHS."
    exit 1
fi

# Extract target's specific Odoo base path
AVAILABLE_ODOO_BASE=$(grep "^AVAILABLE_ODOO_BASE=" "$ENV_FILE_PATH" | cut -d "=" -f 2- | sed 's/^["'\''\\]*//; s/["'\''\\]*$//')
IFS=';' read -ra BASE_ARR <<< "$AVAILABLE_ODOO_BASE"
EXTRACTED_BASE_PATH=""
for item in "${BASE_ARR[@]}"; do
    if [[ "$item" =~ ^${TARGET_DEPLOYMENT}:(.*) ]]; then
        EXTRACTED_BASE_PATH="${BASH_REMATCH[1]}"
        break
    fi
done

if [ -z "$EXTRACTED_BASE_PATH" ]; then
    log_error "No base path configured for deployment '$TARGET_DEPLOYMENT' in AVAILABLE_ODOO_BASE."
    exit 1
fi

# Verify Odoo base path directory exists on the host
FULL_BASE_PATH="$PATH_TO_ODOO/$EXTRACTED_BASE_PATH"
if [ ! -d "$FULL_BASE_PATH" ]; then
    log_error "Target base directory does not exist: $FULL_BASE_PATH"
    exit 1
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
update_env_var "ACTIVE_ODOO_BASE_PATH" "$EXTRACTED_BASE_PATH"
update_env_var "ACTIVE_ODOO_BASE_CONTAINER_PATH" "/opt/odoo/odoo-base/active_odoo_base"
update_env_var "ODOO_LOG_DIR_SERVICE" "/var/log/odoo/${SERVICE_NAME}-${TARGET_DEPLOYMENT}"
update_env_var "ODOO_DATADIR_SERVICE" "/var/lib/odoo/${SERVICE_NAME}-${TARGET_DEPLOYMENT}"

# Re-read values for host directory creation
DATADIR="/var/lib/odoo/${SERVICE_NAME}-${TARGET_DEPLOYMENT}"
LOGDIR="/var/log/odoo/${SERVICE_NAME}-${TARGET_DEPLOYMENT}"
ODOO_LINUX_USER="odoo"

# Automatically create directories on the host
log_info "Provisioning directories on the host..."
if [ ! -d "/var/lib/odoo" ]; then
    mkdir -p "/var/lib/odoo"
    chown "$ODOO_LINUX_USER":"$ODOO_LINUX_USER" "/var/lib/odoo"
fi

if [ ! -d "$DATADIR" ]; then
    log_info "Creating data directory: $DATADIR"
    mkdir -p "$DATADIR"
fi
chown -R "$ODOO_LINUX_USER":"$ODOO_LINUX_USER" "$DATADIR"

if [ ! -d "$DATADIR/filestore" ]; then
    mkdir -p "$DATADIR/filestore"
    chown -R "$ODOO_LINUX_USER":"$ODOO_LINUX_USER" "$DATADIR/filestore"
fi

if [ ! -d "/var/log/odoo" ]; then
    mkdir -p "/var/log/odoo"
    chown "$ODOO_LINUX_USER":"$ODOO_LINUX_USER" "/var/log/odoo"
fi

if [ ! -d "$LOGDIR" ]; then
    log_info "Creating log directory: $LOGDIR"
    mkdir -p "$LOGDIR"
fi
chown -R "$ODOO_LINUX_USER":"$ODOO_LINUX_USER" "$LOGDIR"

# Run odoo configuration update with target addons
log_info "Injecting Odoo configuration for addons..."
"$PATH_TO_ODOO/scripts/update-odoo-config.sh" "$EXTRACTED_ADDONS"

# Re-read values to sync env file
if [ -f "$PATH_TO_ODOO/scripts/update-env-file.sh" ]; then
    log_info "Syncing environment variables..."
    "$PATH_TO_ODOO/scripts/update-env-file.sh" "$ENV_FILE_PATH"
fi

# Boot up the new deployment container
log_info "Booting up deployment container for '$TARGET_DEPLOYMENT'..."
sudo -u "$REPOSITORY_OWNER" docker compose -f "$PATH_TO_ODOO/docker-compose.yml" up -d

log_success "Deployment successfully switched to '$TARGET_DEPLOYMENT'."
