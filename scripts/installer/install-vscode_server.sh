#!/usr/bin/env bash
set -e
# Category: Installer
# Description: Installs and configures global VSCode Server systemd service and restart utility for Odoo debugging.
# Usage: ./scripts/installer/install-vscode_server.sh
# Dependencies: code, systemctl, sudo
# Maintainer: ryumada

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

# Configuration
ENV_FILE="$PATH_TO_ODOO/.env"

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

  if [ ! -f "$ENV_FILE" ]; then
    log_error ".env file not found at $ENV_FILE"
    exit 1
  fi

  VSCODE_DIRECT_DOWNLOAD_URL=$(grep "^VSCODE_DIRECT_DOWNLOAD_URL=" "$ENV_FILE" 2>/dev/null | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g; s/[[:space:]\n]*$//g' || true)

  CODE_BIN=$(command -v code 2>/dev/null || true)
  if [ -z "$CODE_BIN" ]; then
    if [ -n "$VSCODE_DIRECT_DOWNLOAD_URL" ] && { [ "$VSCODE_DIRECT_DOWNLOAD_URL" != "${VSCODE_DIRECT_DOWNLOAD_URL#[http://]}" ] || [ "$VSCODE_DIRECT_DOWNLOAD_URL" != "${VSCODE_DIRECT_DOWNLOAD_URL#[https://]}" ]; }; then
      log_info "VSCode CLI ('code') binary not found in PATH. Downloading from VSCODE_DIRECT_DOWNLOAD_URL..."
      TEMP_DEB="/tmp/vscode_installer.deb"
      if command -v wget >/dev/null 2>&1; then
        wget -O "$TEMP_DEB" "$VSCODE_DIRECT_DOWNLOAD_URL"
      elif command -v curl >/dev/null 2>&1; then
        curl -fsSL "$VSCODE_DIRECT_DOWNLOAD_URL" -o "$TEMP_DEB"
      else
        log_error "Neither wget nor curl is installed on the host system."
        exit 1
      fi

      log_info "Installing VSCode package on host system..."
      apt-get update -qq && apt-get install -y "$TEMP_DEB"
      rm -f "$TEMP_DEB"
      CODE_BIN=$(command -v code 2>/dev/null || true)
    fi
  fi

  if [ -z "$CODE_BIN" ]; then
    log_error "VSCode CLI ('code') binary was not found in PATH."
    log_warn "Please install VSCode CLI first, or set VSCODE_DIRECT_DOWNLOAD_URL in your .env file to auto-install it on the host server."
    exit 1
  fi

  VSCODE_PORT=$(grep "^VSCODE_SERVER_PORT=" "$ENV_FILE" 2>/dev/null | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g; s/[[:space:]\n]*$//g' || true)
  if [ -z "$VSCODE_PORT" ]; then
    VSCODE_PORT="8000"
  fi

  OWNER_GROUP=$(id -gn "$REPOSITORY_OWNER")
  OWNER_HOME=$(eval echo "~$REPOSITORY_OWNER")

  VSCODE_WORKDIR=$(grep "^VSCODE_SERVER_WORKING_DIR=" "$ENV_FILE" 2>/dev/null | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g; s/[[:space:]\n]*$//g' || true)
  if [ -z "$VSCODE_WORKDIR" ]; then
    VSCODE_WORKDIR="${OWNER_HOME}"
  fi

  SERVICE_UNIT_NAME="code-server.service"
  SERVICE_UNIT_PATH="/lib/systemd/system/${SERVICE_UNIT_NAME}"
  RESTART_SCRIPT_PATH="/usr/local/sbin/restart_code-server"
  TOKEN_FILE_PATH="${OWNER_HOME}/vscode-server-token.txt"

  log_info "Creating global systemd unit file for VSCode Server: ${SERVICE_UNIT_PATH}"

  cat << EOF > "$SERVICE_UNIT_PATH"
[Unit]
Description=Visual Studio Code Web Server
Documentation=https://code.visualstudio.com/docs/remote/vscode-server
After=network.target

[Service]
User=${REPOSITORY_OWNER}
Group=${OWNER_GROUP}
Environment="HOME=${OWNER_HOME}"
WorkingDirectory=${VSCODE_WORKDIR}
ExecStart=${CODE_BIN} serve-web --host 127.0.0.1 --port ${VSCODE_PORT}

Type=simple
Restart=always
RestartSec=10

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "$SERVICE_UNIT_PATH"
  systemctl daemon-reload

  CRON_FILE_PATH="/etc/cron.d/vscode-server-stop"
  log_info "Creating cron job to stop VSCode Server daily at 8:00 PM (20:00): ${CRON_FILE_PATH}"
  cat << EOF > "$CRON_FILE_PATH"
# Automatically stop VSCode Server every day at 8:00 PM (20:00)
0 20 * * * root /bin/systemctl stop ${SERVICE_UNIT_NAME} >/dev/null 2>&1
EOF
  chmod 644 "$CRON_FILE_PATH"

  log_info "Creating global restart script at: ${RESTART_SCRIPT_PATH}"
  cat << EOF > "$RESTART_SCRIPT_PATH"
#!/usr/bin/env bash
set -e
# Description: Restarts global VSCode Server service and extracts access token.

SERVICE_UNIT_NAME="${SERVICE_UNIT_NAME}"
TOKEN_FILE="${TOKEN_FILE_PATH}"
REPO_OWNER="${REPOSITORY_OWNER}"

if [ "\$(id -u)" -ne 0 ]; then
  exec sudo "\$0" "\$@"
fi

echo "[$(date +"%Y-%m-%d %H:%M:%S")] ℹ️ Restarting \${SERVICE_UNIT_NAME}..."
systemctl restart "\${SERVICE_UNIT_NAME}"
sleep 2

TOKEN_URL=\$(journalctl -u "\${SERVICE_UNIT_NAME}" -n 50 --no-pager 2>/dev/null | grep -o 'http://127\.0\.0\.1:[0-9]*\?tkn=[^[:space:]]*' | tail -n 1 || true)

if [ -n "\$TOKEN_URL" ]; then
  echo "\$TOKEN_URL" > "\$TOKEN_FILE"
  chown "\${REPO_OWNER}:" "\$TOKEN_FILE" 2>/dev/null || true
  chmod 600 "\$TOKEN_FILE" 2>/dev/null || true
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ VSCode Server restarted successfully."
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] 🔑 Token URL: \$TOKEN_URL"
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] 💾 Saved token to: \$TOKEN_FILE"
else
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ⚠️ VSCode Server restarted, but token URL was not captured in journalctl yet."
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] ℹ️ Run 'sudo journalctl -u \${SERVICE_UNIT_NAME} -f' to inspect logs."
fi
EOF

  chmod 755 "$RESTART_SCRIPT_PATH"

  log_info "Executing restart script to initialize service and save token..."
  "$RESTART_SCRIPT_PATH"
}

main "$@"
