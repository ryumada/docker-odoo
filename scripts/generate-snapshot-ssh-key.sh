#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Generates ed25519 SSH key pair for remote snapshot backup and displays the public key.
# Usage: ./scripts/generate-snapshot-ssh-key.sh [--target-host HOST] [--target-user USER] [--force]
# Dependencies: ssh-keygen, git, sudo

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$CURRENT_DIR")
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO" 2>/dev/null || echo "$USER")
OWNER_HOME=$(eval echo "~$REPOSITORY_OWNER")

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
ENV_REMOTE_HOST=$(grep "^SNAPSHOT_REMOTE_HOST=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
ENV_REMOTE_USER=$(grep "^SNAPSHOT_REMOTE_USER=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)

TARGET_HOST=""
TARGET_USER=""
FORCE=false

show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Generates a dedicated ed25519 SSH key pair for Secondary VPS remote snapshot backup,
saves it to ~/.ssh/snapshot-\$THIS_VPS_HOSTNAME-\$TARGET_VPS_HOSTNAME, updates .env,
and outputs the public key for manual copying.

Options:
  -t, --target-host <HOST>   Hostname or IP of the Secondary VPS (default from .env: ${ENV_REMOTE_HOST:-none})
  -u, --target-user <USER>   SSH username on Secondary VPS (default from .env: ${ENV_REMOTE_USER:-none})
  -f, --force                Overwrite existing SSH key if it already exists
  -h, --help                 Show this help message

Examples:
  ./scripts/generate-snapshot-ssh-key.sh
  ./scripts/generate-snapshot-ssh-key.sh --target-host backup-vps.example.com
  ./scripts/generate-snapshot-ssh-key.sh -t 192.168.1.50 -u odoo-backup --force
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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

THIS_VPS_HOSTNAME=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "vps-source")

if [ -z "$TARGET_HOST" ]; then
  TARGET_HOST="$ENV_REMOTE_HOST"
fi

if [ -z "$TARGET_HOST" ]; then
  echo -ne "${COLOR_CYAN}Enter Target VPS Hostname or IP: ${COLOR_RESET}"
  read -r TARGET_HOST
fi

if [ -z "$TARGET_HOST" ]; then
  log_error "Target VPS Hostname or IP is required."
  exit 1
fi

if [ -z "$TARGET_USER" ]; then
  TARGET_USER="${ENV_REMOTE_USER:-root}"
fi

# Sanitize hostname for filename (remove port, protocol, user@, and slashes)
CLEAN_TARGET_HOSTNAME=$(echo "$TARGET_HOST" | sed -e 's|^.*://||' -e 's|^.*@||' -e 's|:.*$||' -e 's|/.*$||' -e 's|[^a-zA-Z0-9._-]|_|g')

KEY_NAME="snapshot-${THIS_VPS_HOSTNAME}-${CLEAN_TARGET_HOSTNAME}"
SSH_DIR="$OWNER_HOME/.ssh"
KEY_PATH="$SSH_DIR/$KEY_NAME"
PUB_KEY_PATH="${KEY_PATH}.pub"

log_info "Source VPS Hostname : $THIS_VPS_HOSTNAME"
log_info "Target VPS Hostname : $CLEAN_TARGET_HOSTNAME"
log_info "SSH Key Destination : $KEY_PATH"

# Ensure .ssh directory exists with proper permissions
if [ ! -d "$SSH_DIR" ]; then
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  chown "$REPOSITORY_OWNER": "$SSH_DIR" 2>/dev/null || true
fi

# Key generation
if [ -f "$KEY_PATH" ]; then
  if [ "$FORCE" = true ]; then
    log_warn "Overwriting existing SSH key pair at $KEY_PATH..."
    rm -f "$KEY_PATH" "$PUB_KEY_PATH"
  else
    log_info "SSH key already exists at $KEY_PATH. Using existing key."
  fi
fi

if [ ! -f "$KEY_PATH" ]; then
  log_info "Generating ed25519 SSH key pair..."
  ssh-keygen -t ed25519 -N "" -f "$KEY_PATH" -C "${KEY_NAME}@${THIS_VPS_HOSTNAME}"
  chmod 600 "$KEY_PATH"
  chmod 644 "$PUB_KEY_PATH"
  chown "$REPOSITORY_OWNER": "$KEY_PATH" "$PUB_KEY_PATH" 2>/dev/null || true
  log_success "Generated new ed25519 SSH key pair: $KEY_PATH"
fi

# Update SNAPSHOT_REMOTE_KEY in .env if .env exists
if [ -f "$ENV_FILE" ]; then
  if grep -q "^SNAPSHOT_REMOTE_KEY=" "$ENV_FILE"; then
    sed -i "s|^SNAPSHOT_REMOTE_KEY=.*|SNAPSHOT_REMOTE_KEY=$KEY_PATH|" "$ENV_FILE"
    log_success "Updated SNAPSHOT_REMOTE_KEY in $ENV_FILE ➡️ $KEY_PATH"
  else
    echo "SNAPSHOT_REMOTE_KEY=$KEY_PATH" >> "$ENV_FILE"
    log_success "Added SNAPSHOT_REMOTE_KEY to $ENV_FILE ➡️ $KEY_PATH"
  fi
  if [ -n "$TARGET_HOST" ] && ! grep -q "^SNAPSHOT_REMOTE_HOST=" "$ENV_FILE"; then
    echo "SNAPSHOT_REMOTE_HOST=$TARGET_HOST" >> "$ENV_FILE"
  fi
  if [ -n "$TARGET_USER" ] && ! grep -q "^SNAPSHOT_REMOTE_USER=" "$ENV_FILE"; then
    echo "SNAPSHOT_REMOTE_USER=$TARGET_USER" >> "$ENV_FILE"
  fi
fi

PUB_KEY_CONTENT=$(cat "$PUB_KEY_PATH")

echo ""
echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
echo -e "${COLOR_SUCCESS}${COLOR_BOLD}🔑 SNAPSHOT ED25519 PUBLIC KEY FOR TARGET VPS (${CLEAN_TARGET_HOSTNAME})${COLOR_RESET}"
echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
echo ""
echo -e "${COLOR_CYAN}${PUB_KEY_CONTENT}${COLOR_RESET}"
echo ""
echo -e "${COLOR_BOLD}--------------------------------------------------------------------------------${COLOR_RESET}"
echo -e "${COLOR_INFO}Instructions to authorize this key on Target VPS (${TARGET_USER}@${TARGET_HOST}):${COLOR_RESET}"
echo -e "1. Copy the public key string above."
echo -e "2. Run this command on the Target VPS (${TARGET_HOST}):"
echo ""
echo -e "   ${COLOR_BOLD}mkdir -p ~/.ssh && chmod 700 ~/.ssh${COLOR_RESET}"
echo -e "   ${COLOR_BOLD}echo '${PUB_KEY_CONTENT}' >> ~/.ssh/authorized_keys${COLOR_RESET}"
echo -e "   ${COLOR_BOLD}chmod 600 ~/.ssh/authorized_keys${COLOR_RESET}"
echo ""
echo -e "3. Verify connection from this VPS:"
echo -e "   ${COLOR_BOLD}ssh -i $KEY_PATH -o BatchMode=yes ${TARGET_USER}@${TARGET_HOST} 'echo Connection successful'${COLOR_RESET}"
echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
echo ""
