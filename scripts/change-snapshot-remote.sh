#!/usr/bin/env bash
set -e
# Category: Management
# Description: Switches secondary snapshot VPS by cleaning up remote data (retaining archives unless purged), revoking old SSH key, and configuring new host.
# Usage: ./scripts/change-snapshot-remote.sh --new-host HOST [--new-user USER] [--new-port PORT] [--admin-user ADMIN] [--from IP|--no-from] [--purge] [--yes]
# Dependencies: ssh, git, sed, grep, flock, base64

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

ENV_FILE="$PATH_TO_ODOO/.env"
NEW_HOST=""
NEW_USER=""
NEW_PORT=""
ADMIN_USER=""
SOURCE_IP="auto"
PURGE_ARCHIVES=false
ASSUME_YES=false

show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Safely migrates or updates the secondary snapshot VPS:
1. Acquires snapshot flock to prevent collision with running snapshot cron.
2. Connects to existing secondary VPS using current key (if configured and reachable).
3. Cleans up ~/.odoo-snapshots/\$SERVICE_NAME on old server (retaining archives/ by default).
   If --purge is passed, also deletes archives/ after explicit confirmation.
4. Revokes old public key from old server's authorized_keys.
5. Removes old local private/public key files and updates .env.
6. Provisions and configures new secondary host (optionally via sudo admin account).

Options:
  --new-host <HOST>          Hostname or IP of the new Secondary VPS (required)
  --new-user <USER>          SSH username on new Secondary VPS (default: current or odoo-backup)
  --new-port <PORT>          SSH port on new Secondary VPS (default: 22)
  -a, --admin-user <ADMIN>   Remote sudo administrator on new Secondary VPS for automated provisioning
  --from <IP>                Restrict new SSH key to source IP (default: auto-detected from connection)
  --no-from                  Do not restrict new SSH key by source IP
  --purge                    Purge stored archives/ directory on old secondary VPS as well (defaults to keeping archives/)
  -y, --yes                  Assume yes for standard cleanup confirmations
  -h, --help                 Show this help message

Examples:
  ./scripts/change-snapshot-remote.sh --new-host new-vps.example.com -a sysadmin
  ./scripts/change-snapshot-remote.sh --new-host new-vps.example.com --purge
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --new-host)
      NEW_HOST="$2"
      shift 2
      ;;
    --new-host=*)
      NEW_HOST="${1#*=}"
      shift
      ;;
    --new-user)
      NEW_USER="$2"
      shift 2
      ;;
    --new-user=*)
      NEW_USER="${1#*=}"
      shift
      ;;
    --new-port)
      NEW_PORT="$2"
      shift 2
      ;;
    --new-port=*)
      NEW_PORT="${1#*=}"
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
    --purge)
      PURGE_ARCHIVES=true
      shift
      ;;
    -y|--yes)
      ASSUME_YES=true
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

if [ -z "$NEW_HOST" ]; then
  echo -ne "${COLOR_CYAN}Enter new Secondary VPS Hostname or IP: ${COLOR_RESET}"
  read -r NEW_HOST
fi

if [ -z "$NEW_HOST" ]; then
  log_error "New Secondary VPS Hostname is required."
  exit 1
fi

if [ -z "$NEW_PORT" ]; then
  echo -ne "${COLOR_CYAN}Enter new Secondary VPS SSH Port [${OLD_PORT:-22}]: ${COLOR_RESET}"
  read -r input_port
  NEW_PORT="${input_port:-${OLD_PORT:-22}}"
fi

if [ -z "$ADMIN_USER" ]; then
  echo -ne "${COLOR_CYAN}Enter remote sudo administrator username (e.g. devopsadmin, ubuntu): ${COLOR_RESET}"
  read -r ADMIN_USER
fi

if ! [[ "$SERVICE_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  log_error "Invalid SERVICE_NAME: '$SERVICE_NAME'"
  exit 1
fi

# Acquire snapshot flock to ensure snapshot cron isn't running concurrently
LOCK_FILE="/var/run/snapshot-$SERVICE_NAME.lock"
if [ ! -f "$LOCK_FILE" ]; then
  touch "$LOCK_FILE" 2>/dev/null || LOCK_FILE="/tmp/snapshot-$SERVICE_NAME.lock"
  touch "$LOCK_FILE" 2>/dev/null || true
fi

if [ -f "$LOCK_FILE" ]; then
  exec 200<>"$LOCK_FILE"
  if ! flock -n 200; then
    running_pid=$(head -n 1 "$LOCK_FILE" 2>/dev/null | tr -d '[:space:]')
    [ -z "$running_pid" ] && running_pid="unknown"
    log_error "Snapshot or backup process for $SERVICE_NAME is currently running (PID: $running_pid). Please retry after it completes."
    exit 1
  fi
  echo "$$" >&200
fi

# Load current remote settings from .env
OLD_HOST=$(grep "^SNAPSHOT_REMOTE_HOST=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
OLD_USER=$(grep "^SNAPSHOT_REMOTE_USER=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
OLD_PORT=$(grep "^SNAPSHOT_REMOTE_PORT=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
OLD_KEY=$(grep "^SNAPSHOT_REMOTE_KEY=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
[ -z "$OLD_PORT" ] && OLD_PORT="22"

if [ -n "$OLD_KEY" ]; then
  OLD_KEY="${OLD_KEY/#\~/$OWNER_HOME}"
fi

[ -z "$NEW_USER" ] && NEW_USER="${OLD_USER:-odoo-backup}"
[ -z "$NEW_PORT" ] && NEW_PORT="${OLD_PORT:-22}"

log_info "Active Secondary Host : ${OLD_HOST:-none}"
log_info "New Secondary Host    : ${NEW_HOST} (User: ${NEW_USER}, Port: ${NEW_PORT})"

# Step 1: Attempt cleanup and key revocation on old server if configured
if [ -n "$OLD_HOST" ] && [ -n "$OLD_KEY" ] && [ -f "$OLD_KEY" ]; then
  log_info "Testing SSH connectivity to old secondary server ($OLD_USER@$OLD_HOST:$OLD_PORT)..."
  if ssh -i "$OLD_KEY" -p "$OLD_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$OLD_USER@$OLD_HOST" "true" 2>/dev/null; then
    log_success "Connected successfully to old secondary host ($OLD_HOST)."

    echo ""
    echo -e "${COLOR_WARN}${COLOR_BOLD}=== CLEANUP ON OLD SECONDARY SERVER (${OLD_HOST}) ===${COLOR_RESET}"
    if [ "$PURGE_ARCHIVES" = true ]; then
      echo -e "${COLOR_ERROR}MODE: Full purge enabled (--purge). Both cache/staging AND stored archives/ will be permanently removed!${COLOR_RESET}"
    else
      echo -e "${COLOR_INFO}MODE: Standard cleanup. archives/ will be KEPT intact. Only mirror, cache, and staging will be removed.${COLOR_RESET}"
    fi

    proceed_cleanup=false
    if [ "$ASSUME_YES" = true ] && [ "$PURGE_ARCHIVES" = false ]; then
      proceed_cleanup=true
    else
      if [ "$PURGE_ARCHIVES" = true ]; then
        echo -ne "${COLOR_ERROR}Are you ABSOLUTELY sure you want to permanently delete stored archives on $OLD_HOST? [y/N]: ${COLOR_RESET}"
      else
        echo -ne "${COLOR_CYAN}Proceed with removing temporary/mirror data on $OLD_HOST? [Y/n]: ${COLOR_RESET}"
      fi
      read -r confirm_clean
      if [ "$PURGE_ARCHIVES" = true ]; then
        [[ "$confirm_clean" =~ ^[Yy]$ ]] && proceed_cleanup=true
      else
        [[ ! "$confirm_clean" =~ ^[Nn]$ ]] && proceed_cleanup=true
      fi
    fi

    if [ "$proceed_cleanup" = true ]; then
      log_info "Cleaning up remote snapshot directory for $SERVICE_NAME on old server..."
      old_pub_payload=""
      if [ -f "${OLD_KEY}.pub" ]; then
        old_pub_payload=$(awk '{print $2}' "${OLD_KEY}.pub" 2>/dev/null || true)
      fi

      ssh -i "$OLD_KEY" -p "$OLD_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$OLD_USER@$OLD_HOST" \
        "bash -s" -- "$SERVICE_NAME" "$PURGE_ARCHIVES" "$old_pub_payload" << 'REMOTE_CLEANUP_SCRIPT'
set -e
svc="$1"
purge="$2"
old_pub_key="$3"

base_dir="$HOME/.odoo-snapshots/$svc"
if [ -d "$base_dir" ]; then
  if [ "$purge" = "true" ]; then
    echo "[+] Purging entire directory: $base_dir (including archives)"
    rm -rf -- "$base_dir"
  else
    echo "[+] Cleaning temporary files in $base_dir (preserving archives/)"
    find "$base_dir" -mindepth 1 -maxdepth 1 ! -name archives -exec rm -rf -- {} + 2>/dev/null || true
  fi
else
  echo "[i] Remote snapshot directory $base_dir does not exist."
fi

# Revoke old public key from authorized_keys
auth_keys="$HOME/.ssh/authorized_keys"
if [ -n "$old_pub_key" ] && [ -f "$auth_keys" ]; then
  if grep -qF "$old_pub_key" "$auth_keys"; then
    tmp_keys=$(mktemp)
    grep -vF "$old_pub_key" "$auth_keys" > "$tmp_keys" || true
    chmod 600 "$tmp_keys"
    mv "$tmp_keys" "$auth_keys"
    echo "[+] Revoked old SSH key from $auth_keys"
  fi
fi
echo "[SUCCESS] Cleanup completed on old host."
REMOTE_CLEANUP_SCRIPT

      log_success "Cleanup and key revocation completed on old host ($OLD_HOST)."
    else
      log_warn "Skipped remote cleanup on old secondary host ($OLD_HOST)."
    fi
  else
    log_warn "Old secondary host ($OLD_HOST) is unreachable with key $OLD_KEY. Skipping remote cleanup."
    log_info "You may manually clean ~/.odoo-snapshots/$SERVICE_NAME and ~/.ssh/authorized_keys on $OLD_HOST when available."
  fi

  # Delete local old private & public keys
  log_info "Removing old local SSH key pair: $OLD_KEY"
  rm -f "$OLD_KEY" "${OLD_KEY}.pub"
fi

# Step 2: Update .env configuration
log_info "Updating .env configuration for new host..."
if [ -f "$ENV_FILE" ]; then
  sed -i "s|^SNAPSHOT_REMOTE_HOST=.*|SNAPSHOT_REMOTE_HOST=$NEW_HOST|" "$ENV_FILE"
  sed -i "s|^SNAPSHOT_REMOTE_USER=.*|SNAPSHOT_REMOTE_USER=$NEW_USER|" "$ENV_FILE"
  sed -i "s|^SNAPSHOT_REMOTE_PORT=.*|SNAPSHOT_REMOTE_PORT=$NEW_PORT|" "$ENV_FILE"
  sed -i "s|^SNAPSHOT_REMOTE_KEY=.*|SNAPSHOT_REMOTE_KEY=|" "$ENV_FILE"
fi

# Step 3: Run keygen and provision new secondary VPS
log_info "Generating new SSH key pair for $NEW_HOST..."
KEYGEN_ARGS=(--tool snapshot --target-host "$NEW_HOST" --target-user "$NEW_USER" --port "$NEW_PORT" --force)
if [ -n "$ADMIN_USER" ]; then
  KEYGEN_ARGS+=(--admin-user "$ADMIN_USER")
fi
if [ "$SOURCE_IP" = "none" ]; then
  KEYGEN_ARGS+=(--no-from)
elif [ -n "$SOURCE_IP" ] && [ "$SOURCE_IP" != "auto" ]; then
  KEYGEN_ARGS+=(--from "$SOURCE_IP")
fi

"$PATH_TO_ODOO/scripts/generate-snapshot-ssh-key.sh" "${KEYGEN_ARGS[@]}"

log_success "Successfully switched snapshot secondary host to $NEW_HOST."
