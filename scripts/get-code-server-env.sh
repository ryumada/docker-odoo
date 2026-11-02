#!/usr/bin/env bash
set -e
# Category: Configuration
# Description: Reads VSCode Server configuration variables from .env and retrieves active token/status.
# Usage: ./scripts/get-code-server-env.sh [--json]
# Dependencies: grep, sed, sudo, stat
# Maintainer: ryumada

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$CURRENT_DIR/.." && pwd))
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")
OWNER_HOME=$(eval echo "~$REPOSITORY_OWNER" 2>/dev/null || echo "$HOME")

# --- Logging Functions & Colors ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_ERROR="\033[0;31m"

log() {
    local color="$1"
    local emoji="$2"
    local message="$3"
    echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}" >&2
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }

FORMAT_JSON=false
for arg in "$@"; do
    if [[ "$arg" == "--json" || "$arg" == "json" ]]; then
        FORMAT_JSON=true
    fi
done

ENV_FILE="${PATH_TO_ODOO}/.env"

# Extract configuration variables from .env safely
get_env_val() {
    local key="$1"
    local default_val="$2"
    if [ ! -f "$ENV_FILE" ]; then
        echo "$default_val"
        return
    fi
    local val
    val=$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d "=" -f 2- | sed -e 's/^[[:space:]\t]*//' -e 's/[[:space:]\t]*$//' -e 's/^["'\''\\]*//' -e 's/["'\''\\]*$//' || true)
    if [ -z "$val" ]; then
        echo "$default_val"
    else
        echo "$val"
    fi
}

ENABLE_VSCODE_SERVER=$(get_env_val "ENABLE_VSCODE_SERVER" "")
VSCODE_SERVER_PORT=$(get_env_val "VSCODE_SERVER_PORT" "8000")
VSCODE_SERVER_DOMAIN=$(get_env_val "VSCODE_SERVER_DOMAIN" "")
VSCODE_SERVER_SSL_DOMAIN=$(get_env_val "VSCODE_SERVER_SSL_DOMAIN" "")
VSCODE_SERVER_WORKING_DIR=$(get_env_val "VSCODE_SERVER_WORKING_DIR" "")
VSCODE_DIRECT_DOWNLOAD_URL=$(get_env_val "VSCODE_DIRECT_DOWNLOAD_URL" "")

# Retrieve token if token file or journalctl exists
TOKEN=""
TOKEN_URL=""

for cand_file in "${TOKEN_FILE:-}" "${OWNER_HOME}/vscode-server-token.txt" "$HOME/vscode-server-token.txt" "/root/vscode-server-token.txt"; do
    if [ -n "$cand_file" ] && [ -f "$cand_file" ]; then
        RAW_TOKEN_CONTENT=$(cat "$cand_file" 2>/dev/null || true)
        if [[ "$RAW_TOKEN_CONTENT" =~ \?tkn=([a-zA-Z0-9\-]+) ]]; then
            TOKEN="${BASH_REMATCH[1]}"
            TOKEN_URL=$(echo "$RAW_TOKEN_CONTENT" | grep -E -o 'http[s]?://[^[:space:]]+' | head -n 1 || true)
            break
        elif [[ "$RAW_TOKEN_CONTENT" =~ ^[a-zA-Z0-9\-]+$ ]]; then
            TOKEN="$RAW_TOKEN_CONTENT"
            break
        fi
    fi
done

if [ -z "$TOKEN" ] && command -v journalctl >/dev/null 2>&1; then
    JOURNAL_LINE=$(journalctl -u code-server.service -n 100 --no-pager 2>/dev/null | grep -E -o 'http[s]?://[^[:space:]]+\?tkn=[^[:space:]]+' | tail -n 1 || true)
    if [[ "$JOURNAL_LINE" =~ \?tkn=([a-zA-Z0-9\-]+) ]]; then
        TOKEN="${BASH_REMATCH[1]}"
        TOKEN_URL="$JOURNAL_LINE"
    fi
fi

# Detect systemd service status
SERVICE_STATUS="unknown"
if command -v systemctl >/dev/null 2>&1; then
    SERVICE_STATUS=$(systemctl is-active code-server.service 2>/dev/null || echo "inactive")
fi

# Construct recommended external access URL
ACCESS_URL=""
if [ -n "$TOKEN" ]; then
    if [ -n "$VSCODE_SERVER_DOMAIN" ]; then
        ACCESS_URL="https://${VSCODE_SERVER_DOMAIN}/?tkn=${TOKEN}&folder=${PATH_TO_ODOO}"
    else
        ACCESS_URL="http://127.0.0.1:${VSCODE_SERVER_PORT}/?tkn=${TOKEN}&folder=${PATH_TO_ODOO}"
    fi
fi

if [ "$FORMAT_JSON" = true ]; then
    python3 -c '
import json, sys

data = {
    "enable_vscode_server": sys.argv[1],
    "vscode_server_port": sys.argv[2],
    "vscode_server_domain": sys.argv[3],
    "vscode_server_ssl_domain": sys.argv[4],
    "vscode_server_working_dir": sys.argv[5],
    "vscode_direct_download_url": sys.argv[6],
    "token": sys.argv[7],
    "token_url": sys.argv[8],
    "access_url": sys.argv[9],
    "service_status": sys.argv[10],
    "deployment_path": sys.argv[11],
}
print(json.dumps(data, indent=2))
' "$ENABLE_VSCODE_SERVER" \
  "$VSCODE_SERVER_PORT" \
  "$VSCODE_SERVER_DOMAIN" \
  "$VSCODE_SERVER_SSL_DOMAIN" \
  "$VSCODE_SERVER_WORKING_DIR" \
  "$VSCODE_DIRECT_DOWNLOAD_URL" \
  "$TOKEN" \
  "$TOKEN_URL" \
  "$ACCESS_URL" \
  "$SERVICE_STATUS" \
  "$PATH_TO_ODOO"
else
    echo "ENABLE_VSCODE_SERVER=${ENABLE_VSCODE_SERVER}"
    echo "VSCODE_SERVER_PORT=${VSCODE_SERVER_PORT}"
    echo "VSCODE_SERVER_DOMAIN=${VSCODE_SERVER_DOMAIN}"
    echo "VSCODE_SERVER_SSL_DOMAIN=${VSCODE_SERVER_SSL_DOMAIN}"
    echo "VSCODE_SERVER_WORKING_DIR=${VSCODE_SERVER_WORKING_DIR}"
    echo "VSCODE_DIRECT_DOWNLOAD_URL=${VSCODE_DIRECT_DOWNLOAD_URL}"
    echo "SERVICE_STATUS=${SERVICE_STATUS}"
    echo "TOKEN=${TOKEN}"
    if [ -n "$ACCESS_URL" ]; then
        echo "ACCESS_URL=${ACCESS_URL}"
    fi
fi
