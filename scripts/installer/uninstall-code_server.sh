#!/usr/bin/env bash
set -e
# Category: Installer
# Description: Uninstalls and removes VSCode Server systemd service and restart script.
# Usage: ./scripts/installer/uninstall-code_server.sh
# Dependencies: systemctl, sudo
# Maintainer: ryumada

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")
OWNER_HOME=$(eval echo "~$REPOSITORY_OWNER")

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

function main() {
  if [ "$(id -u)" -ne 0 ]; then
    log_info "Elevating permissions to root..."
    # shellcheck disable=SC2093
    exec sudo "$0" "$@"
    log_error "Failed to elevate to root."
    exit 1
  fi

  SERVICE_UNIT_NAME="code-server.service"
  UNIT_LIB_PATH="/lib/systemd/system/${SERVICE_UNIT_NAME}"
  UNIT_ETC_PATH="/etc/systemd/system/${SERVICE_UNIT_NAME}"
  RESTART_SCRIPT_PATH="/usr/local/sbin/restart-code_server"
  SUDOERS_FILE_PATH="/etc/sudoers.d/restart_code_server"
  TOKEN_FILE_PATH="${OWNER_HOME}/vscode-server-token.txt"
  CRON_FILE_PATH="/etc/cron.d/stop_code_server"

  log_info "Uninstalling global VSCode Server systemd service (${SERVICE_UNIT_NAME})..."

  if systemctl is-active --quiet "$SERVICE_UNIT_NAME" 2>/dev/null; then
    log_info "Stopping ${SERVICE_UNIT_NAME}..."
    systemctl stop "$SERVICE_UNIT_NAME" || true
  fi

  if systemctl is-enabled --quiet "$SERVICE_UNIT_NAME" 2>/dev/null; then
    log_info "Disabling ${SERVICE_UNIT_NAME}..."
    systemctl disable "$SERVICE_UNIT_NAME" || true
  fi

  if [ -f "$UNIT_LIB_PATH" ] || [ -f "$UNIT_ETC_PATH" ]; then
    log_info "Removing unit file(s)..."
    rm -f "$UNIT_LIB_PATH" "$UNIT_ETC_PATH" 2>/dev/null || true
    systemctl daemon-reload
    log_success "VSCode Server systemd unit file removed."
  else
    log_info "VSCode Server systemd unit file was not installed."
  fi

  log_info "Removing restart script, token file, and cron job if present..."
  rm -f "$RESTART_SCRIPT_PATH" "$TOKEN_FILE_PATH" "$CRON_FILE_PATH" 2>/dev/null || true

  log_info "Removing the sudoers file of restart code_server..."
  rm -f "$SUDOERS_FILE_PATH" 2>/dev/null || true

  ENV_FILE="$PATH_TO_ODOO/.env"
  if [ -f "$ENV_FILE" ]; then
    VSCODE_DOMAIN=$(grep "^VSCODE_SERVER_DOMAIN=" "$ENV_FILE" 2>/dev/null | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g; s/[[:space:]\n]*$//g' || true)
    if [ -n "$VSCODE_DOMAIN" ]; then
      NGINX_CONF_AVAILABLE="/etc/nginx/sites-available/${VSCODE_DOMAIN}"
      NGINX_CONF_ENABLED="/etc/nginx/sites-enabled/${VSCODE_DOMAIN}"
      if [ -f "$NGINX_CONF_AVAILABLE" ] || [ -f "$NGINX_CONF_ENABLED" ]; then
        log_info "Removing Nginx site configuration for VSCode Server (${VSCODE_DOMAIN})..."
        rm -f "$NGINX_CONF_AVAILABLE" "$NGINX_CONF_ENABLED" 2>/dev/null || true
        if nginx -t >/dev/null 2>&1; then
          systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null || true
        fi
      fi
    fi
  fi
}

main "$@"
