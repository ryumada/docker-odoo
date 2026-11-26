#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Non-interactive CLI wrapper to check or provision cross-VPS SSH keys from .env.
# Usage: ./scripts/provision-cross-vps-ssh.sh --target <deploy_rc|cloner|snapshot> [--check-only | --auth <admin|password> [--admin-user <user>]]
# Dependencies: git, ssh, ssh-keygen, sudo

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel)
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")
OWNER_HOME=$(eval echo "~$REPOSITORY_OWNER")
ENV_FILE="$PATH_TO_ODOO/.env"

if [ -f "$PATH_TO_ODOO/scripts/lib/ssh_utils.sh" ]; then
  # shellcheck source=scripts/lib/ssh_utils.sh
  source "$PATH_TO_ODOO/scripts/lib/ssh_utils.sh"
fi

log_info() { echo -e "\033[0;34m[$(date +"%Y-%m-%d %H:%M:%S")] ℹ️ $1\033[0m"; }
log_success() { echo -e "\033[0;32m[$(date +"%Y-%m-%d %H:%M:%S")] ✅ $1\033[0m"; }
log_error() { echo -e "\033[0;31m[$(date +"%Y-%m-%d %H:%M:%S")] ❌ $1\033[0m" >&2; }

read_env_var() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | head -n 1 | cut -d "=" -f 2- | sed 's/[[:space:]]*#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true
}

TARGET=""
AUTH_METHOD=""
ADMIN_USER=""
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --auth)
      AUTH_METHOD="${2:-}"
      shift 2
      ;;
    --admin-user)
      ADMIN_USER="${2:-}"
      shift 2
      ;;
    --check-only)
      CHECK_ONLY=true
      shift
      ;;
    *)
      log_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [ -z "$TARGET" ]; then
  log_error "--target <deploy_rc|cloner|snapshot> is required."
  exit 1
fi

HOST=""
USER_NAME=""
PORT=""
KEY_PATH=""
DEST_PATH=""
TOOL_TYPE=""
KEY_PREFIX=""
KEY_ENV_VAR=""

case "$TARGET" in
  deploy_rc)
    HOST=$(read_env_var "PRD_SSH_HOST")
    USER_NAME=$(read_env_var "PRD_SSH_USER")
    PORT=$(read_env_var "PRD_SSH_PORT")
    KEY_PATH=$(read_env_var "PRD_SSH_KEY")
    DEST_PATH=$(read_env_var "PRD_SSH_PATH")
    TOOL_TYPE="deploy_rc"
    KEY_PREFIX="deploy_rc"
    KEY_ENV_VAR="PRD_SSH_KEY"
    ;;
  cloner)
    HOST=$(read_env_var "CLONER_SSH_HOST")
    USER_NAME=$(read_env_var "CLONER_SSH_USER")
    PORT=$(read_env_var "CLONER_SSH_PORT")
    KEY_PATH=$(read_env_var "CLONER_SSH_KEY")
    DEST_PATH=$(read_env_var "CLONER_SSH_DEST_PATH")
    TOOL_TYPE="cloner"
    KEY_PREFIX="cloner"
    KEY_ENV_VAR="CLONER_SSH_KEY"
    ;;
  snapshot)
    HOST=$(read_env_var "SNAPSHOT_REMOTE_HOST")
    USER_NAME=$(read_env_var "SNAPSHOT_REMOTE_USER")
    PORT=$(read_env_var "SNAPSHOT_REMOTE_PORT")
    KEY_PATH=$(read_env_var "SNAPSHOT_REMOTE_KEY")
    TOOL_TYPE="snapshot"
    KEY_PREFIX="snapshot"
    KEY_ENV_VAR="SNAPSHOT_REMOTE_KEY"
    ;;
  *)
    log_error "Invalid --target '$TARGET'. Expected deploy_rc, cloner, or snapshot."
    exit 1
    ;;
esac

[ -z "$PORT" ] && PORT="22"
[ -z "$USER_NAME" ] && USER_NAME="$REPOSITORY_OWNER"

THIS_VPS_HOSTNAME=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "vps-source")
CLEAN_TARGET_HOSTNAME=$(echo "$HOST" | sed -e 's|^.*://||' -e 's|^.*@||' -e 's|:.*$||' -e 's|/.*$||' -e 's|[^a-zA-Z0-9._-]|_|g')

if [ -z "$KEY_PATH" ] && [ -n "$HOST" ]; then
  KEY_PATH="$OWNER_HOME/.ssh/${KEY_PREFIX}-${THIS_VPS_HOSTNAME}-${CLEAN_TARGET_HOSTNAME}"
fi
KEY_PATH="${KEY_PATH/#\~/$OWNER_HOME}"

if [ "$CHECK_ONLY" = true ]; then
  configured=false
  key_exists=false
  verified=false
  if [ -n "$HOST" ]; then
    configured=true
    if [ -n "$KEY_PATH" ] && [ -f "${KEY_PATH}.pub" ]; then
      key_exists=true
      if ssh -i "$KEY_PATH" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$USER_NAME@$HOST" "true" 2>/dev/null; then
        verified=true
      fi
    fi
  fi
  python3 -c 'import json, sys; print(json.dumps({
    "configured": sys.argv[1] == "true",
    "host": sys.argv[2],
    "user": sys.argv[3],
    "port": sys.argv[4],
    "key_path": sys.argv[5],
    "dest_path": sys.argv[6],
    "key_exists": sys.argv[7] == "true",
    "verified": sys.argv[8] == "true",
  }))' "$configured" "$HOST" "$USER_NAME" "$PORT" "$KEY_PATH" "$DEST_PATH" "$key_exists" "$verified"
  exit 0
fi

if [ -z "$HOST" ]; then
  log_error "Target '$TARGET' is not configured in $ENV_FILE (host is empty)."
  exit 1
fi

if [ "$AUTH_METHOD" != "admin" ] && [ "$AUTH_METHOD" != "password" ]; then
  log_error "--auth must be 'admin' or 'password'."
  exit 1
fi

if [ "$AUTH_METHOD" = "admin" ]; then
  if [ -z "$ADMIN_USER" ] || [[ ! "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    log_error "Valid --admin-user is required when --auth=admin."
    exit 1
  fi
fi

# Read password from stdin without echoing
INPUT_PASSWORD=""
if [ ! -t 0 ]; then
  IFS= read -r INPUT_PASSWORD || true
fi
if [ -z "$INPUT_PASSWORD" ]; then
  log_error "Password must be provided on stdin."
  exit 1
fi

# Persist default key path to .env if it was empty
if [ -n "$KEY_ENV_VAR" ] && [ -f "$ENV_FILE" ]; then
  if [ -z "$(read_env_var "$KEY_ENV_VAR")" ]; then
    if grep -q "^${KEY_ENV_VAR}=" "$ENV_FILE"; then
      sed -i "s|^${KEY_ENV_VAR}=.*|${KEY_ENV_VAR}=${KEY_PATH}|" "$ENV_FILE"
    else
      echo "${KEY_ENV_VAR}=${KEY_PATH}" >> "$ENV_FILE"
    fi
  fi
fi

# Ensure SSH key pair exists
if [ ! -f "$KEY_PATH" ] || [ ! -f "${KEY_PATH}.pub" ]; then
  log_info "Generating SSH key pair at $KEY_PATH..."
  mkdir -p "$(dirname "$KEY_PATH")"
  chown "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$(dirname "$KEY_PATH")"
  chmod 700 "$(dirname "$KEY_PATH")"
  ssh-keygen -t ed25519 -N "" -f "$KEY_PATH" -C "${KEY_PREFIX}-${THIS_VPS_HOSTNAME}-${CLEAN_TARGET_HOSTNAME}@${THIS_VPS_HOSTNAME}"
  chown "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$KEY_PATH" "${KEY_PATH}.pub"
  chmod 600 "$KEY_PATH"
  chmod 644 "${KEY_PATH}.pub"
  log_success "Generated SSH key pair: $KEY_PATH"
fi

if [ "$AUTH_METHOD" = "admin" ]; then
  if ! declare -f install_pubkey_via_admin >/dev/null 2>&1; then
    log_error "install_pubkey_via_admin function not available (missing scripts/lib/ssh_utils.sh)."
    exit 1
  fi
  DEST_SVC_PARAM=""
  [ -n "$DEST_PATH" ] && DEST_SVC_PARAM=$(basename "$DEST_PATH")
  install_pubkey_via_admin "$HOST" "$PORT" "$ADMIN_USER" "$USER_NAME" "${KEY_PATH}.pub" "auto" "$TOOL_TYPE" "$DEST_SVC_PARAM" "$DEST_PATH" "$INPUT_PASSWORD"
else
  log_info "Copying public SSH key to $USER_NAME@$HOST:$PORT via password authentication..."
  ASKPASS_SCRIPT=$(mktemp)
  trap 'rm -f "$ASKPASS_SCRIPT"' EXIT
  chmod 700 "$ASKPASS_SCRIPT"
  cat << 'ASKPASS_EOF' > "$ASKPASS_SCRIPT"
#!/usr/bin/env bash
printf '%s\n' "$CROSS_VPS_SSH_PASS"
ASKPASS_EOF
  PUBKEY_CONTENT=$(tr -d '\r\n' < "${KEY_PATH}.pub")
  if [ -z "$PUBKEY_CONTENT" ]; then
    log_error "Public key is empty: ${KEY_PATH}.pub"
    exit 1
  fi
  CROSS_VPS_SSH_PASS="$INPUT_PASSWORD" SSH_ASKPASS="$ASKPASS_SCRIPT" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" \
    setsid ssh -p "$PORT" -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no "$USER_NAME@$HOST" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF $(printf '%q' "$PUBKEY_CONTENT") ~/.ssh/authorized_keys || printf '%s\n' $(printf '%q' "$PUBKEY_CONTENT") >> ~/.ssh/authorized_keys" </dev/null
fi

log_info "Verifying passwordless SSH key authentication with $USER_NAME@$HOST:$PORT..."
if ssh -i "$KEY_PATH" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$USER_NAME@$HOST" "true" 2>/dev/null; then
  log_success "Passwordless SSH key verified for $USER_NAME@$HOST:$PORT."
  exit 0
else
  log_error "Passwordless SSH verification failed for $USER_NAME@$HOST:$PORT."
  exit 1
fi
