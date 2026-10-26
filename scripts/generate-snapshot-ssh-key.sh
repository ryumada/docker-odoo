#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Generates ed25519 SSH key pair for cross-VPS operations (snapshot, cloner, deploy_rc) and displays authorization snippet.
# Usage: ./scripts/generate-snapshot-ssh-key.sh [--tool snapshot|cloner|deploy_rc] [--target-host HOST] [--target-user USER] [--admin-user ADMIN] [--port PORT] [--from IP|--no-from] [--force]
# Dependencies: ssh-keygen, git, sudo, ssh, base64

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$CURRENT_DIR")
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO" 2>/dev/null || echo "$USER")
OWNER_HOME=$(eval echo "~$REPOSITORY_OWNER")

# Source shared SSH utilities
if [ -f "$CURRENT_DIR/lib/ssh_utils.sh" ]; then
  source "$CURRENT_DIR/lib/ssh_utils.sh"
elif [ -f "$PATH_TO_ODOO/scripts/lib/ssh_utils.sh" ]; then
  source "$PATH_TO_ODOO/scripts/lib/ssh_utils.sh"
fi

# --- Logging Functions & Colors ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[0;31m"
readonly COLOR_CYAN="\033[0;36m"
readonly COLOR_BOLD="\033[1m"

log() {
  local color="$1"
  local emoji="$2"
  local message="$3"
  echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}" >&2
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_warn() { log "${COLOR_WARN}" "⚠️" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }

# --- Load Default Configuration from .env ---
ENV_FILE="$PATH_TO_ODOO/.env"
TOOL_TYPE="snapshot"
TARGET_HOST=""
TARGET_USER=""
ADMIN_USER=""
TARGET_PORT=""
SOURCE_IP="auto"
FORCE=false

show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Generates a dedicated ed25519 SSH key pair for cross-VPS remote operations (snapshot, databasecloner, deploy_rc),
saves it to ~/.ssh/<tool>-\$THIS_VPS_HOSTNAME-\$TARGET_VPS_HOSTNAME, updates .env, and outputs the public key.
Optionally provisions the key automatically onto the remote VPS via a sudo administrator account.

Options:
  --tool <TOOL>              Tool name: 'snapshot' (default), 'cloner', or 'deploy_rc'
  -t, --target-host <HOST>   Hostname or IP of the Remote VPS
  -u, --target-user <USER>   SSH username on Remote VPS (default: from .env or root)
  -a, --admin-user <ADMIN>   Remote sudo admin account to install public key automatically
  -p, --port <PORT>          SSH port on Remote VPS (default: from .env or 22)
  --from <IP>                Restrict SSH key to source IP (default: auto-detected from connection)
  --no-from                  Do not restrict SSH key by source IP
  -f, --force                Overwrite existing SSH key if it already exists
  -h, --help                 Show this help message

Examples:
  ./scripts/generate-snapshot-ssh-key.sh
  ./scripts/generate-snapshot-ssh-key.sh -a sysadmin
  ./scripts/generate-snapshot-ssh-key.sh --tool cloner --target-host dev-vps.example.com --target-user devops -a sysadmin
  ./scripts/generate-snapshot-ssh-key.sh --tool deploy_rc --target-host prd-vps.example.com -f
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool)
      TOOL_TYPE="$2"
      shift 2
      ;;
    --tool=*)
      TOOL_TYPE="${1#*=}"
      shift
      ;;
    -t|--target-host)
      TARGET_HOST="$2"
      shift 2
      ;;
    --target-host=*)
      TARGET_HOST="${1#*=}"
      shift
      ;;
    -u|--target-user)
      TARGET_USER="$2"
      shift 2
      ;;
    --target-user=*)
      TARGET_USER="${1#*=}"
      shift
      ;;
    -a|--admin-user)
      ADMIN_USER="$2"
      shift 2
      ;;
    --admin-user=*)
      ADMIN_USER="${1#*=}"
      shift
      ;;
    -p|--port)
      TARGET_PORT="$2"
      shift 2
      ;;
    --port=*)
      TARGET_PORT="${1#*=}"
      shift
      ;;
    --from)
      SOURCE_IP="$2"
      shift 2
      ;;
    --from=*)
      SOURCE_IP="${1#*=}"
      shift
      ;;
    --no-from)
      SOURCE_IP="none"
      shift
      ;;
    -f|--force)
      FORCE=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

# Resolve default host/user and env variable name based on tool
ENV_VAR_KEY=""
ENV_VAR_HOST=""
ENV_VAR_USER=""
ENV_VAR_PORT=""

case "$TOOL_TYPE" in
  snapshot)
    ENV_VAR_KEY="SNAPSHOT_REMOTE_KEY"
    ENV_VAR_HOST="SNAPSHOT_REMOTE_HOST"
    ENV_VAR_USER="SNAPSHOT_REMOTE_USER"
    ENV_VAR_PORT="SNAPSHOT_REMOTE_PORT"
    ;;
  cloner|databasecloner)
    TOOL_TYPE="cloner"
    ENV_VAR_KEY="CLONER_SSH_KEY"
    ENV_VAR_HOST="CLONER_SSH_HOST"
    ENV_VAR_USER="CLONER_SSH_USER"
    ENV_VAR_PORT="CLONER_SSH_PORT"
    ;;
  deploy_rc|deploy|deploy_release_candidate)
    TOOL_TYPE="deploy_rc"
    ENV_VAR_KEY="PRD_SSH_KEY"
    ENV_VAR_HOST="PRD_SSH_HOST"
    ENV_VAR_USER="PRD_SSH_USER"
    ENV_VAR_PORT="PRD_SSH_PORT"
    ;;
  *)
    ENV_VAR_KEY="${TOOL_TYPE^^}_SSH_KEY"
    ENV_VAR_HOST="${TOOL_TYPE^^}_SSH_HOST"
    ENV_VAR_USER="${TOOL_TYPE^^}_SSH_USER"
    ENV_VAR_PORT="${TOOL_TYPE^^}_SSH_PORT"
    ;;
esac

ENV_REMOTE_HOST=$(grep "^${ENV_VAR_HOST}=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
ENV_REMOTE_USER=$(grep "^${ENV_VAR_USER}=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
ENV_REMOTE_PORT=$(grep "^${ENV_VAR_PORT}=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)

if [ -z "$TARGET_PORT" ]; then
  TARGET_PORT="${ENV_REMOTE_PORT:-22}"
fi

if [ -z "$TARGET_HOST" ]; then
  TARGET_HOST="$ENV_REMOTE_HOST"
fi

if [ -z "$TARGET_HOST" ]; then
  echo -ne "${COLOR_CYAN}Enter Target VPS Hostname or IP (for ${TOOL_TYPE}): ${COLOR_RESET}"
  read -r TARGET_HOST
fi

if [ -z "$TARGET_HOST" ]; then
  log_error "Target VPS Hostname or IP is required."
  exit 1
fi

if [ -z "$TARGET_USER" ]; then
  TARGET_USER="${ENV_REMOTE_USER:-root}"
fi

KEY_PATH=$(generate_ssh_key_pair "$TOOL_TYPE" "$TARGET_HOST" "$TARGET_USER" "$REPOSITORY_OWNER" "$FORCE" "$ENV_VAR_KEY" "$ENV_FILE")

if [ -f "$ENV_FILE" ]; then
  if [ -n "$TARGET_HOST" ] && ! grep -q "^${ENV_VAR_HOST}=" "$ENV_FILE"; then
    echo "${ENV_VAR_HOST}=$TARGET_HOST" >> "$ENV_FILE"
  fi
  if [ -n "$TARGET_USER" ] && ! grep -q "^${ENV_VAR_USER}=" "$ENV_FILE"; then
    echo "${ENV_VAR_USER}=$TARGET_USER" >> "$ENV_FILE"
  fi
  if [ -n "$TARGET_PORT" ] && [ -n "$ENV_VAR_PORT" ] && ! grep -q "^${ENV_VAR_PORT}=" "$ENV_FILE"; then
    echo "${ENV_VAR_PORT}=$TARGET_PORT" >> "$ENV_FILE"
  fi
fi

# Optional remote provisioning via admin account
if [ -n "$ADMIN_USER" ]; then
  log_info "Attempting remote provisioning onto $TARGET_HOST using admin user '$ADMIN_USER'..."
  PUB_KEY_PATH="${KEY_PATH}.pub"
  if install_pubkey_via_admin "$TARGET_HOST" "$TARGET_PORT" "$ADMIN_USER" "$TARGET_USER" "$PUB_KEY_PATH" "$SOURCE_IP"; then
    log_info "Testing SSH connectivity to $TARGET_USER@$TARGET_HOST:$TARGET_PORT with newly installed key..."
    if ssh -i "$KEY_PATH" -p "$TARGET_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET_USER@$TARGET_HOST" "true" 2>/dev/null; then
      log_success "Passwordless SSH connectivity verified for $TARGET_USER@$TARGET_HOST."
    else
      log_warn "Connection verification failed. Please check host connectivity or authorized_keys on $TARGET_HOST."
    fi
  else
    log_error "Admin-based key provisioning was not successful."
    exit 1
  fi
fi
