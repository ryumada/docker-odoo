#!/usr/bin/env bash
set -e
# Category: Maintenance
# Description: Switches Odoo performance limits and restart cron jobs between normal and 48-hour long process modes.
# Usage: ./scripts/long-process-mode.sh [enable|disable|status]
# Dependencies: git, sed, sudo

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

# Paths
ENV_FILE="$PATH_TO_ODOO/.env"
BAK_ENV_FILE="$PATH_TO_ODOO/.env.long-process.bak"
UPDATE_CONFIG_SCRIPT="$PATH_TO_ODOO/scripts/update-odoo-config.sh"
CRON_DIR="/etc/cron.d"
CRON_DISABLED_DIR="/etc/cron.d/.disabled-by-long-process"

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

# Helper: set or update key=value in .env file
set_env_param() {
  local param="$1"
  local val="$2"
  if grep -q "^${param}=" "$ENV_FILE"; then
    sed -i "s|^${param}=.*|${param}=${val}|" "$ENV_FILE"
  else
    echo "${param}=${val}" >> "$ENV_FILE"
  fi
}

# Helper: read key value from a file
get_env_param() {
  local param="$1"
  local file="${2:-$ENV_FILE}"
  if [ -f "$file" ]; then
    grep "^${param}=" "$file" | cut -d'=' -f2- || true
  fi
}

enable_long_process_mode() {
  if [ -f "$BAK_ENV_FILE" ]; then
    log_warn "Long Process Mode is already ENABLED (backup file $BAK_ENV_FILE exists)."
    return 0
  fi

  if [ ! -f "$ENV_FILE" ]; then
    log_error "$ENV_FILE does not exist. Run setup.sh first."
    exit 1
  fi

  log_info "Enabling 48-Hour Long Process Mode for $SERVICE_NAME..."

  # 1. Backup current limit parameters
  log_info "Backing up current performance limit settings to $BAK_ENV_FILE..."
  {
    echo "LIMIT_TIME_CPU=$(get_env_param LIMIT_TIME_CPU)"
    echo "LIMIT_TIME_REAL=$(get_env_param LIMIT_TIME_REAL)"
    echo "LIMIT_TIME_REAL_CRON=$(get_env_param LIMIT_TIME_REAL_CRON)"
    echo "LIMIT_MEMORY_SOFT=$(get_env_param LIMIT_MEMORY_SOFT)"
    echo "LIMIT_MEMORY_HARD=$(get_env_param LIMIT_MEMORY_HARD)"
    echo "LIMIT_REQUEST=$(get_env_param LIMIT_REQUEST)"
    echo "TRANSIENT_AGE_LIMIT=$(get_env_param TRANSIENT_AGE_LIMIT)"
  } > "$BAK_ENV_FILE"
  chown "$REPOSITORY_OWNER:" "$BAK_ENV_FILE"

  # 2. Update .env with 48-hour mode limits
  log_info "Setting 48-hour performance limits in .env..."
  set_env_param "LIMIT_TIME_CPU" "172800"
  set_env_param "LIMIT_TIME_REAL" "172800"
  set_env_param "LIMIT_TIME_REAL_CRON" "0"
  set_env_param "LIMIT_MEMORY_SOFT" "0"
  set_env_param "LIMIT_MEMORY_HARD" "0"
  set_env_param "LIMIT_REQUEST" "99999999"
  set_env_param "TRANSIENT_AGE_LIMIT" "48.0"

  # 3. Update odoo.conf via update-odoo-config.sh
  if [ -f "$UPDATE_CONFIG_SCRIPT" ]; then
    log_info "Regenerating conf/odoo.conf..."
    "$UPDATE_CONFIG_SCRIPT"
  fi

  # 4. Disable restart cron scripts in /etc/cron.d/
  log_info "Disabling auto-restart cron files under $CRON_DIR..."
  sudo mkdir -p "$CRON_DISABLED_DIR"
  local cron_count=0
  for cron_file in "$CRON_DIR"/*"$SERVICE_NAME"*restart* "$CRON_DIR"/*odoo*restart*; do
    if [ -f "$cron_file" ]; then
      log_info "Moving $cron_file to $CRON_DISABLED_DIR/"
      sudo mv "$cron_file" "$CRON_DISABLED_DIR/"
      cron_count=$((cron_count + 1))
    fi
  done

  if [ "$cron_count" -eq 0 ]; then
    log_info "No matching restart cron files found in $CRON_DIR."
  else
    log_success "Disabled $cron_count restart cron file(s)."
  fi

  log_success "48-Hour Long Process Mode is now ENABLED."
  log_info "Remember to run './scripts/long-process-mode.sh disable' when finished."
}

disable_long_process_mode() {
  if [ ! -f "$BAK_ENV_FILE" ]; then
    log_warn "Long Process Mode is NOT enabled (backup file $BAK_ENV_FILE not found)."
    return 0
  fi

  log_info "Disabling Long Process Mode and restoring standard configuration for $SERVICE_NAME..."

  # 1. Restore performance limits from backup file
  log_info "Restoring performance limit settings from $BAK_ENV_FILE..."
  set_env_param "LIMIT_TIME_CPU" "$(get_env_param LIMIT_TIME_CPU "$BAK_ENV_FILE")"
  set_env_param "LIMIT_TIME_REAL" "$(get_env_param LIMIT_TIME_REAL "$BAK_ENV_FILE")"
  set_env_param "LIMIT_TIME_REAL_CRON" "$(get_env_param LIMIT_TIME_REAL_CRON "$BAK_ENV_FILE")"
  set_env_param "LIMIT_MEMORY_SOFT" "$(get_env_param LIMIT_MEMORY_SOFT "$BAK_ENV_FILE")"
  set_env_param "LIMIT_MEMORY_HARD" "$(get_env_param LIMIT_MEMORY_HARD "$BAK_ENV_FILE")"
  set_env_param "LIMIT_REQUEST" "$(get_env_param LIMIT_REQUEST "$BAK_ENV_FILE")"
  set_env_param "TRANSIENT_AGE_LIMIT" "$(get_env_param TRANSIENT_AGE_LIMIT "$BAK_ENV_FILE")"

  rm -f "$BAK_ENV_FILE"

  # 2. Update odoo.conf via update-odoo-config.sh
  if [ -f "$UPDATE_CONFIG_SCRIPT" ]; then
    log_info "Regenerating conf/odoo.conf with restored limits..."
    "$UPDATE_CONFIG_SCRIPT"
  fi

  # 3. Restore restart cron scripts to /etc/cron.d/
  if [ -d "$CRON_DISABLED_DIR" ]; then
    log_info "Restoring restart cron files to $CRON_DIR..."
    local cron_count=0
    for cron_file in "$CRON_DISABLED_DIR"/*; do
      if [ -f "$cron_file" ]; then
        log_info "Restoring $cron_file to $CRON_DIR/"
        sudo mv "$cron_file" "$CRON_DIR/"
        cron_count=$((cron_count + 1))
      fi
    done
    sudo rmdir "$CRON_DISABLED_DIR" 2>/dev/null || true
    log_success "Restored $cron_count restart cron file(s)."
  fi

  log_success "Long Process Mode has been DISABLED. Standard configuration restored."
}

show_status() {
  echo "==============================================================================="
  echo " LONG PROCESS MODE STATUS FOR $SERVICE_NAME"
  echo "==============================================================================="

  if [ -f "$BAK_ENV_FILE" ]; then
    echo -e " Mode State      : ${COLOR_WARN}ENABLED (48-Hour Long Process Mode active)${COLOR_RESET}"
    echo -e " State File      : $BAK_ENV_FILE"
  else
    echo -e " Mode State      : ${COLOR_SUCCESS}DISABLED (Standard Production Limits active)${COLOR_RESET}"
  fi

  echo ""
  echo " Current Performance Limits (.env):"
  echo "  - LIMIT_TIME_CPU        : $(get_env_param LIMIT_TIME_CPU)"
  echo "  - LIMIT_TIME_REAL       : $(get_env_param LIMIT_TIME_REAL)"
  echo "  - LIMIT_TIME_REAL_CRON  : $(get_env_param LIMIT_TIME_REAL_CRON)"
  echo "  - LIMIT_MEMORY_SOFT     : $(get_env_param LIMIT_MEMORY_SOFT)"
  echo "  - LIMIT_MEMORY_HARD     : $(get_env_param LIMIT_MEMORY_HARD)"
  echo "  - LIMIT_REQUEST         : $(get_env_param LIMIT_REQUEST)"
  echo "  - TRANSIENT_AGE_LIMIT   : $(get_env_param TRANSIENT_AGE_LIMIT)"

  echo ""
  echo " Disabled Restart Cron Directory:"
  if [ -d "$CRON_DISABLED_DIR" ] && [ "$(ls -A "$CRON_DISABLED_DIR" 2>/dev/null)" ]; then
    ls -l "$CRON_DISABLED_DIR"
  else
    echo "  (No disabled cron files)"
  fi
  echo "==============================================================================="
}

ACTION="${1:-status}"

case "$ACTION" in
  enable)
    enable_long_process_mode
    ;;
  disable)
    disable_long_process_mode
    ;;
  status)
    show_status
    ;;
  *)
    echo "Usage: $0 {enable|disable|status}"
    exit 1
    ;;
esac
