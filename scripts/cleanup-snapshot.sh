#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Checks and deletes old Odoo snapshots on Google Drive based on retention policy.
# Usage: ./scripts/cleanup-snapshot.sh [-l|--list] [--keep N] [--dry-run] [--force] [--all]
# Dependencies: curl, openssl, sudo, git, python3

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

# Snapshot storage helpers: sha256 sidecars, exact-name Drive retention (scripts/lib/snapshot_storage.sh)
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
MAX_BACKUPS=$(grep "^GDRIVE_MAX_BACKUPS=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
[ -z "$MAX_BACKUPS" ] && MAX_BACKUPS=$(grep "^MAX_SNAPSHOT_BACKUPS=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
[ -z "$MAX_BACKUPS" ] && MAX_BACKUPS="7"

DRY_RUN=false
FORCE=false
SHOW_ALL=false
LIST_ONLY=false
CUSTOM_SERVICE_NAME=""

show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Checks and deletes oldest Odoo snapshot files stored on Google Drive.

Options:
  -l, --list                     List snapshot files on Google Drive with sizes and exit
  -k, --keep, --max-backups <N>  Number of latest snapshots to retain (default from .env: $MAX_BACKUPS)
  -d, --dry-run                  Simulate deletion without actually deleting files
  -y, --force                    Skip interactive confirmation prompt
  --folder-id <ID>               Override Google Drive Folder ID
  --sa-key <PATH>                Override Google Drive Service Account JSON key file
  --token <TOKEN>                Override Google Drive OAuth2 Access Token
  --service <NAME>               Target specific service name (default: $SERVICE_NAME)
  --all                          Check all snapshot files without filtering by service name
  -h, --help                     Show this help message

Examples:
  ./scripts/cleanup-snapshot.sh -l
  ./scripts/cleanup-snapshot.sh --list --all
  ./scripts/cleanup-snapshot.sh --dry-run
  ./scripts/cleanup-snapshot.sh --keep 24
  ./scripts/cleanup-snapshot.sh --keep 24 --force
  ./scripts/cleanup-snapshot.sh --all --keep 10
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l|--list)
      LIST_ONLY=true
      shift
      ;;
    -k|--keep|--max-backups)
      MAX_BACKUPS="$2"
      shift 2
      ;;
    --keep=*|--max-backups=*)
      MAX_BACKUPS="${1#*=}"
      shift
      ;;
    -d|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -y|--force)
      FORCE=true
      shift
      ;;
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

if ! [[ "$MAX_BACKUPS" =~ ^[0-9]+$ ]] || [ "$MAX_BACKUPS" -lt 1 ]; then
  log_error "Invalid retention value '$MAX_BACKUPS'. It must be at least 1 (retention never deletes every snapshot)."
  exit 1
fi

TARGET_SERVICE_NAME="${CUSTOM_SERVICE_NAME:-$SERVICE_NAME}"

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
    --data-urlencode "assertion=$jwt" \
    "$token_uri")

  echo "$token_response" | grep -o '"access_token": *"[^"]*"' | cut -d'"' -f4
}

function is_gdrive_token_valid() {
  local token="$1"
  [ -z "$token" ] && return 1

  local resp http_code exp
  resp=$(curl -s --connect-timeout 5 --max-time 10 -w "\n%{http_code}" "https://oauth2.googleapis.com/tokeninfo?access_token=${token}" 2>/dev/null || true)
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

# --- Fetch, plan and delete. Each snapshot is kept or deleted together with its .sha256 file. ---
if [ "$SHOW_ALL" = true ]; then
  NAME_PREFIX="snapshot-"
  PLAN_SERVICE="*"
else
  NAME_PREFIX="snapshot-${TARGET_SERVICE_NAME}-"
  PLAN_SERVICE="$TARGET_SERVICE_NAME"
fi

if [ "$LIST_ONLY" = true ]; then
  log_info "Fetching snapshots from Google Drive..."
  PLAN_KEEP=0
else
  log_info "Fetching snapshots from Google Drive (retention policy: keep latest $MAX_BACKUPS per service)..."
  PLAN_KEEP="$MAX_BACKUPS"
fi

ACCESS_TOKEN=$(resolve_access_token "$ACCESS_TOKEN")
if ! FILES_JSON=$(gds_fetch_files "$ACCESS_TOKEN" "$GDRIVE_FOLDER_ID" "$NAME_PREFIX"); then
  log_error "Could not list snapshots on Google Drive."
  exit 1
fi
PLAN=$(printf '%s' "$FILES_JSON" | gds_plan "$PLAN_SERVICE" "$PLAN_KEEP")

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
def fmt_date(d):
    return d.replace("T", " ").split(".")[0] if d else "N/A"
list_only = sys.argv[1] == "true"
rows = [l.split("\t") for l in sys.stdin.read().splitlines() if l.strip()]
archives = [r for r in rows if r[1] == "archive"]
orphans = [r for r in rows if r[1] == "orphan"]
if not archives and not orphans:
    print("-" * 118); print(" No snapshot files found on Google Drive."); print("-" * 118); sys.exit(0)
fmt = "{:<4} | {:<18} | {:<52} | {:<7} | {:<10} | {:<19}"
print("=" * 118)
print(fmt.format("No", "Action", "Snapshot File Name", "SHA256", "Size", "Created At").replace("{:<18}".format("Action"), "{:<9}".format("Action")))
print("-" * 118)
tot = keep_b = del_b = 0
for i, r in enumerate(archives, 1):
    try: b = int(r[4] or 0)
    except Exception: b = 0
    tot += b
    if r[0] == "keep":
        action = "\033[0;32m[KEEP]\033[0m"; keep_b += b
    else:
        action = "\033[0;31m[DELETE]\033[0m"; del_b += b
    print(fmt.format(i, action, r[3], "yes" if r[7] == "yes" else "missing", fmt_size(r[4]), fmt_date(r[5])))
for r in orphans:
    print(fmt.format("-", "\033[0;31m[DELETE]\033[0m", r[3], "orphan", fmt_size(r[4]), fmt_date(r[5])))
print("=" * 118)
kept = sum(1 for r in archives if r[0] == "keep")
dele = len(archives) - kept
side = sum(1 for r in rows if r[1] == "sidecar")
missing = sum(1 for r in archives if r[7] != "yes")
if list_only:
    print("Total: %d snapshot(s) | Total Size: %s | Without checksum file: %d" % (len(archives), fmt_size(tot), missing))
else:
    print("Total: %d snapshot(s) (%s) | Keeping: %d (%s) | Scheduled to delete: %d (%s) + %d checksum file(s) + %d orphan checksum file(s)"
          % (len(archives), fmt_size(tot), kept, fmt_size(keep_b), dele, fmt_size(del_b), side, len(orphans)))
' "$LIST_ONLY" <<< "$PLAN"

if [ "$LIST_ONLY" = true ]; then
  exit 0
fi

DELETE_ARCHIVES=$(printf '%s\n' "$PLAN" | awk -F'\t' '$1=="delete" && $2=="archive"' | grep -c . || true)
DELETE_OTHERS=$(printf '%s\n' "$PLAN" | awk -F'\t' '$1=="delete" && $2!="archive"' | grep -c . || true)

if [ "$DELETE_ARCHIVES" -eq 0 ] && [ "$DELETE_OTHERS" -eq 0 ]; then
  echo ""
  log_success "All snapshots are within retention limit ($MAX_BACKUPS). No deletion needed."
  exit 0
fi

echo ""
if [ "$DRY_RUN" = true ]; then
  log_warn "DRY-RUN mode enabled: No snapshots will actually be deleted."
  log_info "To execute actual deletion, run without --dry-run: ./scripts/cleanup-snapshot.sh --keep $MAX_BACKUPS"
  exit 0
fi

if [ "$FORCE" = false ]; then
  echo -ne "${COLOR_WARN}Are you sure you want to delete $DELETE_ARCHIVES older snapshot(s) and $DELETE_OTHERS checksum file(s) from Google Drive? [y/N]: ${COLOR_RESET}"
  read -r confirmation
  if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
    log_info "Cleanup operation aborted by user."
    exit 0
  fi
fi

log_info "Deleting $DELETE_ARCHIVES old snapshot(s) and $DELETE_OTHERS checksum file(s) from Google Drive..."
ACCESS_TOKEN=$(resolve_access_token "$ACCESS_TOKEN")
SUMMARY=$(printf '%s\n' "$PLAN" | gds_apply_plan "$ACCESS_TOKEN" "$GDRIVE_FOLDER_ID")
read -r DELETED_ARCHIVES DELETED_SIDECARS FAILED_COUNT <<< "$SUMMARY"

echo ""
if [ "${FAILED_COUNT:-0}" -eq 0 ]; then
  log_success "Retention cleanup completed successfully. Deleted $DELETED_ARCHIVES snapshot(s) and $DELETED_SIDECARS checksum file(s)."
else
  log_warn "Retention cleanup finished with warnings. Deleted: $DELETED_ARCHIVES snapshot(s), $DELETED_SIDECARS checksum file(s). Failed: $FAILED_COUNT."
  log_info "If deletions failed, please ensure the Service Account has Editor/Content Manager permissions on the Google Drive folder."
fi
