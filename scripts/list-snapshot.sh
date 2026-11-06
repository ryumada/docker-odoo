#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Lists Odoo snapshots available on Google Drive.
# Usage: ./scripts/list-snapshot.sh [--folder-id ID] [--sa-key PATH] [--token TOKEN] [--all] [--limit N] [--json]
# Dependencies: curl, openssl, sudo, git

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$CURRENT_DIR")
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO" 2>/dev/null || echo "$USER")

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
  echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}" >&2
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_warn() { log "${COLOR_WARN}" "⚠️" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }

# Snapshot storage helpers: sha256 sidecars, exact-name matching (scripts/lib/snapshot_storage.sh)
if [ -f "$CURRENT_DIR/lib/snapshot_storage.sh" ]; then
  # shellcheck source=/dev/null
  source "$CURRENT_DIR/lib/snapshot_storage.sh"
elif [ -f "$PATH_TO_ODOO/scripts/lib/snapshot_storage.sh" ]; then
  # shellcheck source=/dev/null
  source "$PATH_TO_ODOO/scripts/lib/snapshot_storage.sh"
else
  log_error "scripts/lib/snapshot_storage.sh not found. Update docker-odoo (git pull)."
  exit 1
fi

# --- Load Default Configuration from .env ---
ENV_FILE="$PATH_TO_ODOO/.env"
GDRIVE_ACCESS_TOKEN=$(grep "^GDRIVE_ACCESS_TOKEN=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
GDRIVE_SERVICE_ACCOUNT_KEY=$(grep "^GDRIVE_SERVICE_ACCOUNT_KEY=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
GDRIVE_FOLDER_ID=$(grep "^GDRIVE_FOLDER_ID=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)

SHOW_ALL=false
FORMAT_JSON=false
LIMIT=30
CUSTOM_SERVICE_NAME=""

# --- Parse CLI Arguments ---
show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Lists Odoo snapshot files stored in Google Drive.

Options:
  --folder-id <ID>     Override Google Drive Folder ID
  --sa-key <PATH>      Override Google Drive Service Account JSON key file
  --token <TOKEN>      Override Google Drive OAuth2 Access Token
  --service <NAME>     Filter snapshots for a specific service name (default: $SERVICE_NAME)
  --all                Show all snapshot files without filtering by service name
  --limit <N>          Maximum number of snapshots to list (default: $LIMIT)
  --json               Output listing in JSON format
  -h, --help           Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --folder-id)
      GDRIVE_FOLDER_ID="$2"
      shift 2
      ;;
    --folder-id=*)
      GDRIVE_FOLDER_ID="${1#*=}"
      shift
      ;;
    --sa-key)
      GDRIVE_SERVICE_ACCOUNT_KEY="$2"
      shift 2
      ;;
    --sa-key=*)
      GDRIVE_SERVICE_ACCOUNT_KEY="${1#*=}"
      shift
      ;;
    --token)
      GDRIVE_ACCESS_TOKEN="$2"
      shift 2
      ;;
    --token=*)
      GDRIVE_ACCESS_TOKEN="${1#*=}"
      shift
      ;;
    --service)
      CUSTOM_SERVICE_NAME="$2"
      shift 2
      ;;
    --service=*)
      CUSTOM_SERVICE_NAME="${1#*=}"
      shift
      ;;
    --all)
      SHOW_ALL=true
      shift
      ;;
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    --limit=*)
      LIMIT="${1#*=}"
      shift
      ;;
    --json)
      FORMAT_JSON=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      log_error "Unknown argument: $1"
      show_help
      exit 1
      ;;
  esac
done

[ -n "$CUSTOM_SERVICE_NAME" ] && TARGET_SERVICE_NAME="$CUSTOM_SERVICE_NAME" || TARGET_SERVICE_NAME="$SERVICE_NAME"

# Resolve relative path for service account key if needed
if [ -n "$GDRIVE_SERVICE_ACCOUNT_KEY" ] && [[ "$GDRIVE_SERVICE_ACCOUNT_KEY" != /* ]] && [ ! -f "$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
  if [ -f "$PATH_TO_ODOO/$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
    GDRIVE_SERVICE_ACCOUNT_KEY="$PATH_TO_ODOO/$GDRIVE_SERVICE_ACCOUNT_KEY"
  fi
fi

# --- Authentication ---
function get_gdrive_access_token_from_sa() {
  local sa_input="$1"
  local sa_json_content=""

  if [ -f "$sa_input" ]; then
    sa_json_content=$(cat "$sa_input")
  elif [[ "$sa_input" =~ ^\{.*\}$ ]]; then
    sa_json_content="$sa_input"
  else
    log_error "Service Account JSON key file or content '$sa_input' not found."
    return 1
  fi

  local client_email token_uri key_pem
  client_email=$(echo "$sa_json_content" | grep -o '"client_email": *"[^"]*"' | cut -d'"' -f4)
  token_uri=$(echo "$sa_json_content" | grep -o '"token_uri": *"[^"]*"' | cut -d'"' -f4)
  [ -z "$token_uri" ] && token_uri="https://oauth2.googleapis.com/token"

  key_pem=$(echo "$sa_json_content" | grep -o '"private_key": *"[^"]*"' | sed 's/^"private_key": *"//;s/"$//')

  if [ -z "$client_email" ] || [ -z "$key_pem" ]; then
    log_error "Could not parse client_email or private_key from Service Account JSON."
    return 1
  fi

  local b64url_cmd='openssl base64 -e -A | tr "+/" "-_" | tr -d "="'
  local now exp header_b64 claims claims_b64 unsigned_jwt sig_b64 jwt
  now=$(date +%s)
  exp=$((now + 3600))

  header_b64=$(echo -n '{"alg":"RS256","typ":"JWT"}' | eval "$b64url_cmd")
  claims="{\"iss\":\"$client_email\",\"scope\":\"https://www.googleapis.com/auth/drive\",\"aud\":\"$token_uri\",\"exp\":$exp,\"iat\":$now}"
  claims_b64=$(echo -n "$claims" | eval "$b64url_cmd")

  unsigned_jwt="${header_b64}.${claims_b64}"
  sig_b64=$(printf "%s" "$unsigned_jwt" | openssl dgst -sha256 -sign <(printf '%b' "$key_pem") -binary 2>/dev/null | eval "$b64url_cmd")

  if [ -z "$sig_b64" ]; then
    log_error "Failed to sign Service Account JWT with openssl."
    return 1
  fi

  jwt="${unsigned_jwt}.${sig_b64}"

  local token_response
  token_response=$(curl -s -X POST \
    -d "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
    --data-urlencode "assertion@"<(printf '%s' "$jwt") \
    "$token_uri")

  echo "$token_response" | grep -o '"access_token": *"[^"]*"' | cut -d'"' -f4
}

function is_gdrive_token_valid() {
  local token="$1"
  [ -z "$token" ] && return 1

  local resp http_code exp
  resp=$(curl -s --connect-timeout 5 --max-time 10 -w "\n%{http_code}" --data-urlencode "access_token@"<(printf '%s' "${token}") "https://oauth2.googleapis.com/tokeninfo" 2>/dev/null || true)
  http_code=$(echo "$resp" | tail -n1)

  if [ "$http_code" = "200" ]; then
    exp=$(echo "$resp" | sed '$d' | grep -o '"expires_in": *"[^"]*"' | cut -d'"' -f4)
    [ -z "$exp" ] && exp=$(echo "$resp" | sed '$d' | grep -o '"expires_in": *[0-9]*' | awk '{print $2}')
    if [ -n "$exp" ] && [ "$exp" -gt 60 ] 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

function resolve_access_token() {
  local current_token="$1"
  if is_gdrive_token_valid "$current_token"; then
    echo "$current_token"
    return 0
  fi

  if [ -n "$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
    get_gdrive_access_token_from_sa "$GDRIVE_SERVICE_ACCOUNT_KEY"
  elif [ -n "$GDRIVE_ACCESS_TOKEN" ]; then
    if [ -f "$GDRIVE_ACCESS_TOKEN" ]; then
      if [[ "$GDRIVE_ACCESS_TOKEN" == *.json ]] || grep -q '"type": *"service_account"' "$GDRIVE_ACCESS_TOKEN" 2>/dev/null; then
        get_gdrive_access_token_from_sa "$GDRIVE_ACCESS_TOKEN"
      else
        local file_tok
        file_tok=$(tr -d '\r\n' < "$GDRIVE_ACCESS_TOKEN")
        if is_gdrive_token_valid "$file_tok"; then
          echo "$file_tok"
        elif [ -n "$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
          get_gdrive_access_token_from_sa "$GDRIVE_SERVICE_ACCOUNT_KEY"
        else
          echo "$file_tok"
        fi
      fi
    elif [[ "$GDRIVE_ACCESS_TOKEN" =~ ^\{.*\}$ ]]; then
      get_gdrive_access_token_from_sa "$GDRIVE_ACCESS_TOKEN"
    else
      echo "$GDRIVE_ACCESS_TOKEN"
    fi
  fi
}

ACCESS_TOKEN=$(resolve_access_token)
if [ -z "$ACCESS_TOKEN" ]; then
  log_error "Google Drive access token could not be obtained. Please set GDRIVE_SERVICE_ACCOUNT_KEY or GDRIVE_ACCESS_TOKEN in .env or pass via CLI."
  exit 1
fi

# --- Fetch snapshots (archives only; their .sha256 files are shown as a column) ---
if [ "$SHOW_ALL" = false ]; then
  PLAN_SERVICE="$TARGET_SERVICE_NAME"
else
  PLAN_SERVICE="*"
fi

if [ "$FORMAT_JSON" = false ]; then
  log_info "Fetching snapshots from Google Drive..."
fi

if ! ROWS=$(gds_list_archives "$ACCESS_TOKEN" "$GDRIVE_FOLDER_ID" "$PLAN_SERVICE" "$LIMIT"); then
  log_error "Could not list snapshots on Google Drive."
  exit 1
fi

if [ "$FORMAT_JSON" = true ]; then
  python3 -c '
import json, sys
rows = [l.split("\t") for l in sys.stdin.read().splitlines() if l.strip()]
print(json.dumps([{"id": r[2], "name": r[3], "size": r[4], "createdTime": r[5], "service": r[6],
                   "sha256_file": r[7] == "yes", "drill_passed": len(r) > 8 and r[8] in ("yes", "protected")} for r in rows], indent=2))
' <<< "$ROWS"
  exit 0
fi

FILES_COUNT=$(printf '%s\n' "$ROWS" | grep -c . || true)
if [ "$FILES_COUNT" -eq 0 ]; then
  echo "--------------------------------------------------------------------------------------------------------------------"
  echo " No snapshot files found on Google Drive."
  [ -n "$GDRIVE_FOLDER_ID" ] && echo " Folder ID: $GDRIVE_FOLDER_ID"
  [ "$SHOW_ALL" = false ] && echo " Service filter: $TARGET_SERVICE_NAME (use --all to see all snapshots)"
  echo "--------------------------------------------------------------------------------------------------------------------"
  exit 0
fi

echo "==============================================================================================================================="
printf "%-4s | %-52s | %-33s | %-7s | %-7s | %-10s | %-19s\n" "No" "Snapshot File Name" "File ID" "SHA256" "Drill" "Size" "Created At"
echo "-------------------------------------------------------------------------------------------------------------------------------"
python3 -c '
import sys
def fmt_size(v):
    try:
        b = float(v)
    except Exception:
        return "N/A"
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if b < 1024.0:
            return "%.1f %s" % (b, unit)
        b /= 1024.0
    return "%.1f PB" % b
for i, l in enumerate([l for l in sys.stdin.read().splitlines() if l.strip()], 1):
    r = l.split("\t")
    created = r[5].replace("T", " ").split(".")[0] if r[5] else "N/A"
    drill = "passed" if len(r) > 8 and r[8] in ("yes", "protected") else "-"
    print("%-4s | %-52s | %-33s | %-7s | %-7s | %-10s | %-19s" % (i, r[3], r[2], "yes" if r[7] == "yes" else "missing", drill, fmt_size(r[4]), created))
' <<< "$ROWS"
echo "==============================================================================================================================="
echo "Total: $FILES_COUNT snapshot(s) found."
echo ""
echo "To download a snapshot, run:"
echo "  ./scripts/download-snapshot.sh <FILE_ID or URL>"
echo "  ./scripts/download-snapshot.sh latest"
