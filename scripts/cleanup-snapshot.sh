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

if ! [[ "$MAX_BACKUPS" =~ ^[0-9]+$ ]] || [ "$MAX_BACKUPS" -lt 0 ]; then
  log_error "Invalid retention value '$MAX_BACKUPS'. It must be a positive integer."
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

function resolve_access_token() {
  if [ -n "$GDRIVE_ACCESS_TOKEN" ]; then
    if [ -f "$GDRIVE_ACCESS_TOKEN" ]; then
      if [[ "$GDRIVE_ACCESS_TOKEN" == *.json ]] || grep -q '"type": *"service_account"' "$GDRIVE_ACCESS_TOKEN" 2>/dev/null; then
        get_gdrive_access_token_from_sa "$GDRIVE_ACCESS_TOKEN"
      else
        tr -d '\r\n' < "$GDRIVE_ACCESS_TOKEN"
      fi
    else
      echo "$GDRIVE_ACCESS_TOKEN"
    fi
  elif [ -n "$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
    get_gdrive_access_token_from_sa "$GDRIVE_SERVICE_ACCOUNT_KEY"
  fi
}

ACCESS_TOKEN=$(resolve_access_token)
if [ -z "$ACCESS_TOKEN" ]; then
  log_error "Google Drive access token could not be obtained. Please set GDRIVE_SERVICE_ACCOUNT_KEY or GDRIVE_ACCESS_TOKEN in .env or pass via CLI."
  exit 1
fi

# Build query
QUERY="trashed = false"
if [ "$SHOW_ALL" = false ]; then
  QUERY="$QUERY and (name contains 'snapshot-${TARGET_SERVICE_NAME}' or name contains 'snapshot--')"
else
  QUERY="$QUERY and name contains 'snapshot-'"
fi

if [ -n "$GDRIVE_FOLDER_ID" ]; then
  QUERY="$QUERY and '$GDRIVE_FOLDER_ID' in parents"
fi

if [ "$LIST_ONLY" = true ]; then
  log_info "Fetching snapshots from Google Drive..."
else
  log_info "Fetching snapshots from Google Drive (retention policy: keep latest $MAX_BACKUPS)..."
fi

RESPONSE=$(curl -s -G \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  --data-urlencode "q=$QUERY" \
  --data-urlencode "orderBy=createdTime desc" \
  --data-urlencode "fields=files(id, name, size, createdTime)" \
  --data-urlencode "supportsAllDrives=true" \
  --data-urlencode "includeItemsFromAllDrives=true" \
  --data-urlencode "pageSize=100" \
  "https://www.googleapis.com/drive/v3/files")

if echo "$RESPONSE" | grep -q '"error":'; then
  ERROR_MSG=$(echo "$RESPONSE" | grep -o '"message": *"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
  log_error "Google Drive API error: ${ERROR_MSG:-$RESPONSE}"
  exit 1
fi

# Parse files count and list
python3 -c '
import sys, json

def format_size(bytes_val):
    if not bytes_val:
        return "N/A"
    try:
        b = float(bytes_val)
        for unit in ["B", "KB", "MB", "GB", "TB"]:
            if b < 1024.0:
                return f"{b:.1f} {unit}"
            b /= 1024.0
        return f"{b:.1f} PB"
    except Exception:
        return "N/A"

def format_date(iso_date):
    if not iso_date:
        return "N/A"
    try:
        return iso_date.replace("T", " ").split(".")[0]
    except Exception:
        return iso_date

try:
    data = json.load(sys.stdin)
    files = data.get("files", [])
    max_keep = int(sys.argv[1])
    is_list_only = (len(sys.argv) > 2 and sys.argv[2].lower() == "true")

    if not files:
        print("-" * 110)
        print(" No snapshot files found on Google Drive.")
        print("-" * 110)
        sys.exit(0)

    header_fmt = "{:<4} | {:<9} | {:<45} | {:<10} | {:<19}"
    row_fmt = "{:<4} | {:<18} | {:<45} | {:<10} | {:<19}"

    print("=" * 110)
    print(header_fmt.format("No", "Action", "Snapshot File Name", "Size", "Created At"))
    print("-" * 110)

    total_bytes = 0
    keep_bytes = 0
    delete_bytes = 0

    for idx, f in enumerate(files, 1):
        name = f.get("name", "")
        f_size_raw = f.get("size")
        size = format_size(f_size_raw)
        created = format_date(f.get("createdTime"))
        try:
            b_val = int(f_size_raw or 0)
        except Exception:
            b_val = 0
        total_bytes += b_val

        if idx <= max_keep:
            action = "\033[0;32m[KEEP]\033[0m"
            keep_bytes += b_val
        else:
            action = "\033[0;31m[DELETE]\033[0m"
            delete_bytes += b_val
        print(row_fmt.format(idx, action, name, size, created))

    print("=" * 110)
    total = len(files)
    to_delete = max(0, total - max_keep)
    if is_list_only:
        print(f"Total: {total} snapshot(s) found | Total Size: {format_size(total_bytes)}")
    else:
        print(f"Total: {total} snapshot(s) found ({format_size(total_bytes)}) | Keeping: {min(total, max_keep)} ({format_size(keep_bytes)}) | Scheduled to delete: {to_delete} ({format_size(delete_bytes)})")
except Exception as e:
    sys.stderr.write(f"Error parsing response: {e}\n")
    sys.exit(1)
' "$MAX_BACKUPS" "$LIST_ONLY" <<< "$RESPONSE"

if [ "$LIST_ONLY" = true ]; then
  exit 0
fi

FILE_IDS=$(echo "$RESPONSE" | grep -o '"id": *"[^"]*"' | cut -d'"' -f4)
TOTAL_FILES=$(echo "$FILE_IDS" | grep -c . || echo "0")

if [ "$TOTAL_FILES" -eq 0 ]; then
  exit 0
fi

if [ "$TOTAL_FILES" -le "$MAX_BACKUPS" ]; then
  echo ""
  log_success "All snapshots are within retention limit ($MAX_BACKUPS). No deletion needed."
  exit 0
fi

TO_DELETE_ITEMS=$(python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    files = data.get("files", [])
    max_keep = int(sys.argv[1])
    excess = files[max_keep:]
    for f in excess:
        fid = f.get("id", "")
        fname = f.get("name", "")
        if fid:
            print(f"{fid}\t{fname}")
except Exception:
    pass
' "$MAX_BACKUPS" <<< "$RESPONSE")

DELETE_COUNT=0
if [ -n "$TO_DELETE_ITEMS" ]; then
  DELETE_COUNT=$(echo "$TO_DELETE_ITEMS" | grep -c . || echo "0")
fi

echo ""
if [ "$DRY_RUN" = true ]; then
  log_warn "DRY-RUN mode enabled: No snapshots will actually be deleted."
  log_info "To execute actual deletion, run without --dry-run: ./scripts/cleanup-snapshot.sh --keep $MAX_BACKUPS"
  exit 0
fi

if [ "$FORCE" = false ]; then
  echo -ne "${COLOR_WARN}Are you sure you want to delete $DELETE_COUNT older snapshot(s) from Google Drive? [y/N]: ${COLOR_RESET}"
  read -r confirmation
  if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
    log_info "Cleanup operation aborted by user."
    exit 0
  fi
fi

log_info "Deleting $DELETE_COUNT old snapshot(s) from Google Drive..."
DELETED_COUNT=0
FAILED_COUNT=0

while IFS=$'\t' read -r fid fname; do
  [ -z "$fid" ] && continue

  # Strategy 1: Permanent DELETE (requires ownership or Admin)
  DEL_RESP=$(curl -s -w "\n%{http_code}" -X DELETE \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://www.googleapis.com/drive/v3/files/${fid}?supportsAllDrives=true")
  DEL_STATUS=$(echo "$DEL_RESP" | tail -n1)

  # Strategy 2: Fallback to Move to Trash (works for Editors / shared folders)
  if [ "$DEL_STATUS" != "204" ] && [ "$DEL_STATUS" != "200" ]; then
    TRASH_RESP=$(curl -s -w "\n%{http_code}" -X PATCH \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"trashed": true}' \
      "https://www.googleapis.com/drive/v3/files/${fid}?supportsAllDrives=true")
    TRASH_STATUS=$(echo "$TRASH_RESP" | tail -n1)
    if [ "$TRASH_STATUS" = "200" ]; then
      DEL_STATUS="200"
    fi
  fi

  # Strategy 3: Fallback to Unparenting from Folder
  if [ "$DEL_STATUS" != "204" ] && [ "$DEL_STATUS" != "200" ] && [ -n "$GDRIVE_FOLDER_ID" ]; then
    UNPARENT_RESP=$(curl -s -w "\n%{http_code}" -X PATCH \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      "https://www.googleapis.com/drive/v3/files/${fid}?removeParents=${GDRIVE_FOLDER_ID}&supportsAllDrives=true")
    UNPARENT_STATUS=$(echo "$UNPARENT_RESP" | tail -n1)
    if [ "$UNPARENT_STATUS" = "200" ]; then
      DEL_STATUS="200"
    fi
  fi

  if [ "$DEL_STATUS" = "204" ] || [ "$DEL_STATUS" = "200" ]; then
    log_success "Deleted snapshot: ${fname:-$fid}"
    DELETED_COUNT=$((DELETED_COUNT + 1))
  else
    log_warn "Failed to delete snapshot '${fname:-$fid}' (ID: $fid, HTTP status: $DEL_STATUS)"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
done <<< "$TO_DELETE_ITEMS"

echo ""
if [ "$FAILED_COUNT" -eq 0 ]; then
  log_success "Retention cleanup completed successfully. Deleted $DELETED_COUNT snapshot(s)."
else
  log_warn "Retention cleanup finished with warnings. Deleted: $DELETED_COUNT, Failed: $FAILED_COUNT."
  log_info "If deletions failed, please ensure the Service Account has Editor/Content Manager permissions on the Google Drive folder."
fi
