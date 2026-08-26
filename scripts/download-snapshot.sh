#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Downloads an Odoo snapshot from Google Drive by URL, File ID, filename, or 'latest'.
# Usage: ./scripts/download-snapshot.sh [FILE_ID|URL|FILENAME|latest] [-o OUTPUT_PATH] [--sa-key PATH]
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

# --- Load Default Configuration from .env ---
ENV_FILE="$PATH_TO_ODOO/.env"
GDRIVE_ACCESS_TOKEN=$(grep "^GDRIVE_ACCESS_TOKEN=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
GDRIVE_SERVICE_ACCOUNT_KEY=$(grep "^GDRIVE_SERVICE_ACCOUNT_KEY=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
GDRIVE_FOLDER_ID=$(grep "^GDRIVE_FOLDER_ID=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)

TARGET_INPUT=""
OUTPUT_PATH=""
LINK_AS_DEFAULT=true
CUSTOM_SERVICE_NAME=""

# --- Help Message ---
show_help() {
  cat << EOF
Usage: $(basename "$0") [FILE_ID | URL | FILENAME | latest] [OPTIONS]

Downloads an Odoo snapshot from Google Drive.

Arguments:
  FILE_ID | URL | FILENAME | latest
                       Google Drive File ID, full sharing URL, exact file name,
                       or keyword 'latest' to fetch the newest snapshot.
                       If omitted, an interactive snapshot picker will be displayed.

Options:
  -o, --output <PATH>  Destination file path or directory (default: /tmp/<filename>)
  --sa-key <PATH>      Override Google Drive Service Account JSON key file
  --token <TOKEN>      Override Google Drive OAuth2 Access Token
  --folder-id <ID>     Override Google Drive Folder ID
  --service <NAME>     Service name to filter when using 'latest' (default: $SERVICE_NAME)
  --no-link            Do not create /tmp/snapshot-<service>.tar.zst symlink
  -h, --help           Show this help message

Examples:
  ./scripts/download-snapshot.sh latest
  ./scripts/download-snapshot.sh 1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OIvE2up0Y
  ./scripts/download-snapshot.sh "https://drive.google.com/file/d/1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OIvE2up0Y/view"
  ./scripts/download-snapshot.sh snapshot-myproject-20260826-101500.tar.zst -o /tmp/
EOF
}

# --- Parse CLI Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --output=*)
      OUTPUT_PATH="${1#*=}"
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
    --folder-id)
      GDRIVE_FOLDER_ID="$2"
      shift 2
      ;;
    --folder-id=*)
      GDRIVE_FOLDER_ID="${1#*=}"
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
    --no-link)
      LINK_AS_DEFAULT=false
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    -*)
      log_error "Unknown option: $1"
      show_help
      exit 1
      ;;
    *)
      if [ -z "$TARGET_INPUT" ]; then
        TARGET_INPUT="$1"
      else
        log_error "Unexpected argument: $1"
        show_help
        exit 1
      fi
      shift
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

# --- Helper to Extract File ID from Google Drive URL ---
extract_gdrive_id_from_url() {
  local url="$1"
  local file_id=""
  local re_file="/file/d/([a-zA-Z0-9_-]+)"
  local re_id='[?&]id=([a-zA-Z0-9_-]+)'
  local re_folders="/folders/([a-zA-Z0-9_-]+)"

  # Matches /file/d/<id>
  if [[ "$url" =~ $re_file ]]; then
    file_id="${BASH_REMATCH[1]}"
  # Matches id=<id>
  elif [[ "$url" =~ $re_id ]]; then
    file_id="${BASH_REMATCH[1]}"
  # Matches /folders/<id>
  elif [[ "$url" =~ $re_folders ]]; then
    file_id="${BASH_REMATCH[1]}"
  fi

  echo "$file_id"
}

# --- Resolve File ID ---
FILE_ID=""

if [ -z "$TARGET_INPUT" ]; then
  # Interactive mode: list snapshots and prompt user
  log_info "No snapshot specified. Fetching available snapshots from Google Drive..."
  QUERY="trashed = false and name contains 'snapshot-'"
  [ -n "$GDRIVE_FOLDER_ID" ] && QUERY="$QUERY and '$GDRIVE_FOLDER_ID' in parents"

  RESPONSE=$(curl -s -G \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    --data-urlencode "q=$QUERY" \
    --data-urlencode "orderBy=createdTime desc" \
    --data-urlencode "fields=files(id, name, size, createdTime)" \
    --data-urlencode "supportsAllDrives=true" \
    --data-urlencode "includeItemsFromAllDrives=true" \
    --data-urlencode "pageSize=20" \
    "https://www.googleapis.com/drive/v3/files")

  MAP_DATA=$(python3 -c '
import sys, json

try:
    data = json.load(sys.stdin)
    files = data.get("files", [])
    if not files:
        sys.exit(2)
    for idx, f in enumerate(files, 1):
        print(f"{idx}\t{f.get(\"id\")}\t{f.get(\"name\")}\t{f.get(\"size\", 0)}\t{f.get(\"createdTime\", \"\")}")
except Exception:
    sys.exit(1)
' <<< "$RESPONSE" || true)

  if [ -z "$MAP_DATA" ]; then
    log_error "No snapshot files found on Google Drive."
    exit 1
  fi

  echo "========================================================================================================"
  printf "%-4s | %-45s | %-12s | %-19s\n" "No" "Snapshot File Name" "Size" "Created At"
  echo "--------------------------------------------------------------------------------------------------------"
  while IFS=$'\t' read -r idx fid fname fsize ftime; do
    fsize_mb="N/A"
    if [ "$fsize" -gt 0 ] 2>/dev/null; then
      fsize_mb="$(python3 -c "print(f'{$fsize / (1024*1024):.1f} MB')")"
    fi
    ftime_fmt=$(echo "$ftime" | tr 'T' ' ' | cut -d'.' -f1)
    printf "%-4s | %-45s | %-12s | %-19s\n" "$idx" "$fname" "$fsize_mb" "$ftime_fmt"
  done <<< "$MAP_DATA"
  echo "========================================================================================================"

  read -rp "Select snapshot number to download [1]: " SELECTION
  SELECTION="${SELECTION:-1}"

  SELECTED_LINE=$(echo "$MAP_DATA" | awk -F'\t' -v sel="$SELECTION" '$1 == sel {print $0}')
  if [ -z "$SELECTED_LINE" ]; then
    log_error "Invalid selection: $SELECTION"
    exit 1
  fi

  FILE_ID=$(echo "$SELECTED_LINE" | cut -f2)
elif [ "$TARGET_INPUT" = "latest" ]; then
  log_info "Searching for the latest snapshot for service '$TARGET_SERVICE_NAME'..."
  QUERY="trashed = false and name contains 'snapshot-${TARGET_SERVICE_NAME}'"
  [ -n "$GDRIVE_FOLDER_ID" ] && QUERY="$QUERY and '$GDRIVE_FOLDER_ID' in parents"

  RESPONSE=$(curl -s -G \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    --data-urlencode "q=$QUERY" \
    --data-urlencode "orderBy=createdTime desc" \
    --data-urlencode "fields=files(id, name, size, createdTime)" \
    --data-urlencode "supportsAllDrives=true" \
    --data-urlencode "includeItemsFromAllDrives=true" \
    --data-urlencode "pageSize=1" \
    "https://www.googleapis.com/drive/v3/files")

  FILE_ID=$(python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    files = data.get("files", [])
    if files:
        print(files[0].get("id", ""))
except Exception:
    pass
' <<< "$RESPONSE")

  if [ -z "$FILE_ID" ]; then
    log_warn "No snapshot found specifically for 'snapshot-${TARGET_SERVICE_NAME}'. Searching latest generic snapshot..."
    QUERY="trashed = false and name contains 'snapshot-'"
    [ -n "$GDRIVE_FOLDER_ID" ] && QUERY="$QUERY and '$GDRIVE_FOLDER_ID' in parents"
    RESPONSE=$(curl -s -G \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      --data-urlencode "q=$QUERY" \
      --data-urlencode "orderBy=createdTime desc" \
      --data-urlencode "fields=files(id, name, size, createdTime)" \
      --data-urlencode "supportsAllDrives=true" \
      --data-urlencode "includeItemsFromAllDrives=true" \
      --data-urlencode "pageSize=1" \
      "https://www.googleapis.com/drive/v3/files")
    FILE_ID=$(python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    files = data.get("files", [])
    if files:
        print(files[0].get("id", ""))
except Exception:
    pass
' <<< "$RESPONSE")
  fi

  if [ -z "$FILE_ID" ]; then
    log_error "No snapshots found on Google Drive."
    exit 1
  fi
elif [[ "$TARGET_INPUT" =~ ^https?:// ]]; then
  FILE_ID=$(extract_gdrive_id_from_url "$TARGET_INPUT")
  if [ -z "$FILE_ID" ]; then
    log_error "Could not extract Google Drive File ID from URL: $TARGET_INPUT"
    exit 1
  fi
elif [[ "$TARGET_INPUT" == *.tar.zst ]] || [[ "$TARGET_INPUT" == snapshot-* ]]; then
  # Filename search
  log_info "Searching for snapshot with filename '$TARGET_INPUT'..."
  QUERY="trashed = false and name = '$TARGET_INPUT'"
  [ -n "$GDRIVE_FOLDER_ID" ] && QUERY="$QUERY and '$GDRIVE_FOLDER_ID' in parents"

  RESPONSE=$(curl -s -G \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    --data-urlencode "q=$QUERY" \
    --data-urlencode "fields=files(id, name, size, createdTime)" \
    --data-urlencode "supportsAllDrives=true" \
    --data-urlencode "includeItemsFromAllDrives=true" \
    "https://www.googleapis.com/drive/v3/files")

  FILE_ID=$(python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    files = data.get("files", [])
    if files:
        print(files[0].get("id", ""))
except Exception:
    pass
' <<< "$RESPONSE")

  if [ -z "$FILE_ID" ]; then
    log_error "File '$TARGET_INPUT' not found on Google Drive."
    exit 1
  fi
else
  # Assumed direct File ID
  FILE_ID="$TARGET_INPUT"
fi

# --- Retrieve File Metadata ---
log_info "Fetching file details for ID: $FILE_ID..."
META_RESPONSE=$(curl -s -G \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  --data-urlencode "fields=id,name,size,mimeType,createdTime" \
  --data-urlencode "supportsAllDrives=true" \
  "https://www.googleapis.com/drive/v3/files/$FILE_ID")

ERROR_MSG=$(echo "$META_RESPONSE" | grep -o '"message": *"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
if [ -n "$ERROR_MSG" ]; then
  log_error "Google Drive API error: $ERROR_MSG"
  exit 1
fi

REMOTE_FILE_NAME=$(python3 -c 'import sys, json; print(json.load(sys.stdin).get("name", ""))' <<< "$META_RESPONSE" 2>/dev/null || true)
REMOTE_FILE_SIZE=$(python3 -c 'import sys, json; print(json.load(sys.stdin).get("size", "0"))' <<< "$META_RESPONSE" 2>/dev/null || true)

if [ -z "$REMOTE_FILE_NAME" ]; then
  REMOTE_FILE_NAME="snapshot-${SERVICE_NAME}-downloaded.tar.zst"
fi

HUMAN_SIZE="N/A"
if [ "$REMOTE_FILE_SIZE" -gt 0 ] 2>/dev/null; then
  HUMAN_SIZE=$(python3 -c "b = float($REMOTE_FILE_SIZE); print(f'{b / (1024*1024):.2f} MB')")
fi

log_info "Target File: $REMOTE_FILE_NAME ($HUMAN_SIZE)"

# --- Determine Destination Path ---
DEST_FILE=""
if [ -z "$OUTPUT_PATH" ]; then
  DEST_FILE="/tmp/$REMOTE_FILE_NAME"
elif [ -d "$OUTPUT_PATH" ]; then
  DEST_FILE="${OUTPUT_PATH%/}/$REMOTE_FILE_NAME"
else
  DEST_FILE="$OUTPUT_PATH"
fi

mkdir -p "$(dirname "$DEST_FILE")"

log_info "Downloading to: $DEST_FILE..."

# --- Execute Download ---
HTTP_STATUS=$(curl -# -L -w "%{http_code}" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://www.googleapis.com/drive/v3/files/${FILE_ID}?alt=media&supportsAllDrives=true" \
  -o "$DEST_FILE")

if [ "$HTTP_STATUS" != "200" ]; then
  log_error "Download failed with HTTP status: $HTTP_STATUS"
  if [ -f "$DEST_FILE" ]; then
    cat "$DEST_FILE" >&2
    rm -f "$DEST_FILE"
  fi
  exit 1
fi

if [ ! -s "$DEST_FILE" ]; then
  log_error "Downloaded file is empty: $DEST_FILE"
  rm -f "$DEST_FILE"
  exit 1
fi

DOWNLOADED_BYTES=$(wc -c < "$DEST_FILE" | tr -d ' ')
log_success "Download complete! ($DOWNLOADED_BYTES bytes)"

# Set permissions
chmod 644 "$DEST_FILE" 2>/dev/null || true
chown "$REPOSITORY_OWNER": "$DEST_FILE" 2>/dev/null || true

# --- Create default restore symlink if requested ---
STANDARD_RESTORE_PATH="/tmp/snapshot-${SERVICE_NAME}.tar.zst"
if [ "$LINK_AS_DEFAULT" = true ] && [ "$DEST_FILE" != "$STANDARD_RESTORE_PATH" ]; then
  ln -sf "$DEST_FILE" "$STANDARD_RESTORE_PATH" 2>/dev/null || cp -f "$DEST_FILE" "$STANDARD_RESTORE_PATH"
  chown "$REPOSITORY_OWNER": "$STANDARD_RESTORE_PATH" 2>/dev/null || true
  log_info "Created restore link at: $STANDARD_RESTORE_PATH"
fi

echo ""
echo "Snapshot is ready. You can restore it anytime with:"
echo "  ./scripts/restore-snapshot.sh"
