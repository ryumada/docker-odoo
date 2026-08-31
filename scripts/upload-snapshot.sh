#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Uploads local Odoo snapshot archive to Google Drive.
# Usage: ./scripts/upload-snapshot.sh [SNAPSHOT_FILE] [--folder-id ID] [--sa-key PATH] [--token TOKEN]
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
GDRIVE_CHUNK_SIZE=$(grep "^GDRIVE_CHUNK_SIZE=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
MAX_BACKUPS=$(grep "^MAX_SNAPSHOT_BACKUPS=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
[ -z "$MAX_BACKUPS" ] && MAX_BACKUPS=$(grep "^MAX_BACKUPS=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)

SNAPSHOT_FILE_PATH=""
REMOTE_FILENAME=""

show_help() {
  cat << EOF
Usage: $(basename "$0") [SNAPSHOT_FILE] [OPTIONS]

Uploads an Odoo snapshot archive to Google Drive using credentials configured in .env or via CLI.

Options:
  -f, --file <PATH>            Path to snapshot .tar.zst file to upload
  --folder-id <ID>             Override Google Drive Folder ID
  --sa-key <PATH>              Override Google Drive Service Account JSON key file
  --token <TOKEN>              Override Google Drive OAuth2 Access Token
  --chunk-size <BYTES>         Resumable upload chunk size (must be multiple of 256 KiB, default: 5242880 / 5 MiB)
  --name <FILENAME>            Custom remote filename on Google Drive
  --max-backups <N>            Apply retention lifecycle (keep latest N snapshots)
  -h, --help                   Show this help message

Arguments:
  SNAPSHOT_FILE                Optional path to snapshot file (default: auto-detect latest snapshot)

Examples:
  ./scripts/upload-snapshot.sh
  ./scripts/upload-snapshot.sh /tmp/snapshot-$SERVICE_NAME-20260826.tar.zst
  ./scripts/upload-snapshot.sh --folder-id "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OIvE2up0Y"
EOF
}

# --- Parse CLI Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)
      SNAPSHOT_FILE_PATH="$2"
      shift 2
      ;;
    --file=*)
      SNAPSHOT_FILE_PATH="${1#*=}"
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
    --chunk-size)
      GDRIVE_CHUNK_SIZE="$2"
      shift 2
      ;;
    --chunk-size=*)
      GDRIVE_CHUNK_SIZE="${1#*=}"
      shift
      ;;
    --name)
      REMOTE_FILENAME="$2"
      shift 2
      ;;
    --name=*)
      REMOTE_FILENAME="${1#*=}"
      shift
      ;;
    --max-backups)
      MAX_BACKUPS="$2"
      shift 2
      ;;
    --max-backups=*)
      MAX_BACKUPS="${1#*=}"
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
      if [ -z "$SNAPSHOT_FILE_PATH" ]; then
        SNAPSHOT_FILE_PATH="$1"
      else
        log_error "Unexpected argument: $1"
        show_help
        exit 1
      fi
      shift
      ;;
  esac
done

# Resolve relative path for service account key if needed
if [ -n "$GDRIVE_SERVICE_ACCOUNT_KEY" ] && [[ "$GDRIVE_SERVICE_ACCOUNT_KEY" != /* ]] && [ ! -f "$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
  if [ -f "$PATH_TO_ODOO/$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
    GDRIVE_SERVICE_ACCOUNT_KEY="$PATH_TO_ODOO/$GDRIVE_SERVICE_ACCOUNT_KEY"
  fi
fi

# Auto-detect snapshot file if not provided
if [ -z "$SNAPSHOT_FILE_PATH" ]; then
  if [ -f "/tmp/snapshot-$SERVICE_NAME.tar.zst" ]; then
    SNAPSHOT_FILE_PATH="/tmp/snapshot-$SERVICE_NAME.tar.zst"
  else
    # Find latest in /tmp
    LATEST_TMP=$(find /tmp -maxdepth 1 -name "snapshot-${SERVICE_NAME}*.tar.zst" -printf '%T@ %p\n' 2>/dev/null | sort -k1 -nr | head -n1 | cut -d' ' -f2- || true)
    if [ -n "$LATEST_TMP" ] && [ -f "$LATEST_TMP" ]; then
      SNAPSHOT_FILE_PATH="$LATEST_TMP"
    else
      # Find in current project root
      LATEST_LOCAL=$(find "$PATH_TO_ODOO" -maxdepth 1 -name "snapshot-${SERVICE_NAME}*.tar.zst" -printf '%T@ %p\n' 2>/dev/null | sort -k1 -nr | head -n1 | cut -d' ' -f2- || true)
      if [ -n "$LATEST_LOCAL" ] && [ -f "$LATEST_LOCAL" ]; then
        SNAPSHOT_FILE_PATH="$LATEST_LOCAL"
      fi
    fi
  fi
fi

if [ -z "$SNAPSHOT_FILE_PATH" ] || [ ! -f "$SNAPSHOT_FILE_PATH" ]; then
  log_error "Snapshot file '${SNAPSHOT_FILE_PATH:-<none>}' not found."
  log_info "Please specify a valid snapshot file with -f <PATH> or create one using ./scripts/snapshot-$SERVICE_NAME"
  exit 1
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

function cleanup_gdrive_old_snapshots() {
  local token="$1"
  local folder="$2"
  local service="$3"
  local max_keep="$4"

  if [ -z "$max_keep" ] || ! [[ "$max_keep" =~ ^[0-9]+$ ]] || [ "$max_keep" -le 0 ]; then
    return 0
  fi

  log_info "Running Google Drive retention lifecycle (keeping latest $max_keep snapshots for $service)..."

  local query="(name contains 'snapshot-${service}' or name contains 'snapshot--') and trashed = false"
  if [ -n "$folder" ]; then
    query="$query and '$folder' in parents"
  fi

  local response
  response=$(curl -s -G \
    -H "Authorization: Bearer $token" \
    --data-urlencode "q=$query" \
    --data-urlencode "orderBy=createdTime desc" \
    --data-urlencode "fields=files(id, name, createdTime)" \
    --data-urlencode "supportsAllDrives=true" \
    --data-urlencode "includeItemsFromAllDrives=true" \
    --data-urlencode "pageSize=100" \
    "https://www.googleapis.com/drive/v3/files")

  if echo "$response" | grep -q '"error":'; then
    log_error "Google Drive API returned an error during retention cleanup:"
    log_error "$response"
    return 1
  fi

  local file_ids
  file_ids=$(echo "$response" | grep -o '"id": *"[^"]*"' | cut -d'"' -f4)

  local total_count=0
  if [ -n "$file_ids" ]; then
    total_count=$(echo "$file_ids" | grep -c . || echo "0")
  fi

  if [ "$total_count" -le "$max_keep" ]; then
    log_info "Total snapshots found on Google Drive ($total_count) is within retention limit ($max_keep). Nothing to delete."
    return 0
  fi

  local delete_count=$((total_count - max_keep))
  log_info "Found $total_count remote snapshots. Deleting $delete_count older snapshot(s)..."

  local to_delete
  to_delete=$(echo "$file_ids" | tail -n +$((max_keep + 1)))

  for fid in $to_delete; do
    if [ -n "$fid" ]; then
      local del_status
      del_status=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        -H "Authorization: Bearer $token" \
        "https://www.googleapis.com/drive/v3/files/${fid}?supportsAllDrives=true")
      if [ "$del_status" = "204" ] || [ "$del_status" = "200" ]; then
        log_info "Deleted old remote snapshot (ID: $fid)"
      else
        log_warn "Failed to delete remote snapshot ID $fid (HTTP $del_status). Check Service Account permissions (requires Editor/Manager on Google Drive folder)."
      fi
    fi
  done
}

function upload_snapshot() {
  local file_path="$1"
  local token="$2"
  local folder="$3"
  local chunk_size_cfg="$4"
  local max_keep="$5"
  local custom_name="$6"

  local chunk_size=5242880 # 5 MiB default
  if [ -n "$chunk_size_cfg" ]; then
    if [[ "$chunk_size_cfg" =~ ^[0-9]+$ ]] && [ "$chunk_size_cfg" -gt 0 ] && [ "$((chunk_size_cfg % 262144))" -eq 0 ]; then
      chunk_size="$chunk_size_cfg"
    else
      log_warn "Invalid chunk size '$chunk_size_cfg'. It must be a multiple of 262144 bytes. Using default 5242880 (5 MiB)."
    fi
  fi

  local upload_name
  if [ -n "$custom_name" ]; then
    upload_name="$custom_name"
  else
    local base_file
    base_file=$(basename "$file_path")
    if [[ "$base_file" =~ ^snapshot-.*-[0-9]{8}-[0-9]{6}\.tar\.zst$ ]]; then
      upload_name="$base_file"
    else
      upload_name="snapshot-${SERVICE_NAME}-$(date +"%Y%m%d-%H%M%S").tar.zst"
    fi
  fi

  local file_size
  file_size=$(wc -c < "$file_path" | tr -d ' ')
  local mime_type="application/octet-stream"

  log_info "Preparing upload for '$upload_name' ($file_size bytes)..."
  [ -n "$folder" ] && log_info "Target Google Drive Folder ID: $folder"

  # Build JSON metadata
  local metadata="{\"name\": \"$upload_name\""
  if [ -n "$folder" ]; then
    metadata="$metadata, \"parents\": [\"$folder\"]"
  fi
  metadata="$metadata}"

  log_info "Initiating resumable upload session..."
  local init_response
  init_response=$(curl -s -i -X POST \
    -H "Authorization: Bearer $token" \
    -H "X-Upload-Content-Type: $mime_type" \
    -H "X-Upload-Content-Length: $file_size" \
    -H "Content-Type: application/json; charset=UTF-8" \
    -d "$metadata" \
    "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true")

  local session_uri
  session_uri=$(echo "$init_response" | grep -i "^location:" | tr -d '\r' | awk '{print $2}')

  if [ -z "$session_uri" ]; then
    log_error "Failed to initiate Google Drive upload session."
    log_error "Response: $init_response"
    exit 1
  fi

  local start_byte=0
  local chunk_index=0
  local max_retries=3
  local retry_count=0
  local uploaded_file_id=""

  while [ "$start_byte" -lt "$file_size" ]; do
    local end_byte=$((start_byte + chunk_size - 1))
    if [ "$end_byte" -ge "$file_size" ]; then
      end_byte=$((file_size - 1))
    fi

    local current_chunk_len=$((end_byte - start_byte + 1))
    local pct=$(( (end_byte + 1) * 100 / file_size ))

    log_info "Uploading bytes ${start_byte}-${end_byte}/${file_size} (${pct}%)..."

    local http_response http_status response_body
    http_response=$( (dd if="$file_path" bs="$chunk_size" skip="$chunk_index" count=1 status=none | \
      curl -s -w "\n%{http_code}" -X PUT \
        -H "Content-Length: $current_chunk_len" \
        -H "Content-Range: bytes ${start_byte}-${end_byte}/${file_size}" \
        --data-binary @- \
        "$session_uri") 2>/dev/null || true )

    http_status=$(echo "$http_response" | tail -n1)
    response_body=$(echo "$http_response" | sed '$d')

    if [ "$http_status" -eq 308 ]; then
      # Chunk uploaded successfully, advance to next chunk
      start_byte=$((end_byte + 1))
      chunk_index=$((chunk_index + 1))
      retry_count=0
    elif [ "$http_status" -eq 200 ] || [ "$http_status" -eq 201 ]; then
      uploaded_file_id=$(echo "$response_body" | grep -o '"id": *"[^"]*"' | cut -d'"' -f4)
      break
    else
      retry_count=$((retry_count + 1))
      log_warn "Chunk upload failed (HTTP $http_status). Retry $retry_count of $max_retries in 5s..."
      if [ "$retry_count" -ge "$max_retries" ]; then
        log_error "Max retries reached. Upload aborted."
        exit 1
      fi
      sleep 5

      # Query session for current uploaded byte offset
      local status_check
      status_check=$(curl -s -i -X PUT \
        -H "Content-Range: bytes */$file_size" \
        "$session_uri" || true)

      local range_header
      range_header=$(echo "$status_check" | grep -i "^range:" | tr -d '\r')
      if [ -n "$range_header" ]; then
        local last_byte
        last_byte=$(echo "$range_header" | awk -F'-' '{print $2}')
        if [ -n "$last_byte" ] && [[ "$last_byte" =~ ^[0-9]+$ ]]; then
          start_byte=$((last_byte + 1))
          chunk_index=$((start_byte / chunk_size))
        fi
      fi
    fi
  done

  echo ""
  log_success "Snapshot '$upload_name' uploaded successfully to Google Drive!"
  if [ -n "$uploaded_file_id" ]; then
    log_info "File ID: $uploaded_file_id"
    log_info "Google Drive Link: https://drive.google.com/file/d/$uploaded_file_id/view"
  fi

  if [ -n "$max_keep" ]; then
    cleanup_gdrive_old_snapshots "$token" "$folder" "$SERVICE_NAME" "$max_keep"
  fi
}

upload_snapshot "$SNAPSHOT_FILE_PATH" "$ACCESS_TOKEN" "$GDRIVE_FOLDER_ID" "$GDRIVE_CHUNK_SIZE" "$MAX_BACKUPS" "$REMOTE_FILENAME"

