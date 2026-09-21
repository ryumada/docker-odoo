#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Uploads temporary Odoo snapshot archives to configured storage (Google Drive or GCS).
# Usage: ./scripts/upload-temp-snapshots.sh [OPTIONS]
# Dependencies: curl, openssl, sudo, git, gcloud

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
GCS_BUCKET_NAME=$(grep "^GCS_BUCKET_NAME=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
GDRIVE_ACCESS_TOKEN=$(grep "^GDRIVE_ACCESS_TOKEN=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
GDRIVE_SERVICE_ACCOUNT_KEY=$(grep "^GDRIVE_SERVICE_ACCOUNT_KEY=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
GDRIVE_FOLDER_ID=$(grep "^GDRIVE_FOLDER_ID=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
GDRIVE_CHUNK_SIZE=$(grep "^GDRIVE_CHUNK_SIZE=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
MAX_BACKUPS=$(grep "^GDRIVE_MAX_BACKUPS=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
[ -z "$MAX_BACKUPS" ] && MAX_BACKUPS=$(grep "^MAX_SNAPSHOT_BACKUPS=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
[ -z "$MAX_BACKUPS" ] && MAX_BACKUPS="7"

# Strip gs:// prefix from GCS_BUCKET_NAME if present
GCS_BUCKET_NAME="${GCS_BUCKET_NAME#gs://}"

TARGET_DIR="/tmp"
CUSTOM_SERVICE_NAME=""
PROCESS_ALL=false
DRY_RUN=false
KEEP_LOCAL=false

show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Uploads all temporary Odoo snapshot files and directories (typically left in /tmp
after upload failures or key errors) to the configured remote backup storage (Google Drive, GCS).
After successful upload, the temporary files/directories are cleaned up unless --keep-local is used.

Options:
  -s, --service <NAME>     Filter temporary snapshots for a specific service name (default: $SERVICE_NAME)
  -a, --all                Upload temporary snapshots for all services found
  -d, --dir <PATH>         Directory containing temporary snapshots (default: /tmp)
  -k, --keep-local         Do not remove local temporary files after successful upload
  --dry-run                Simulate upload and cleanup without making any changes
  --gcs-bucket <BUCKET>    Override Google Cloud Storage bucket name
  --folder-id <ID>         Override Google Drive Folder ID
  --sa-key <PATH>          Override Google Drive Service Account JSON key file
  --token <TOKEN>          Override Google Drive OAuth2 Access Token
  --chunk-size <BYTES>     Resumable upload chunk size (multiple of 256 KiB, default: 5242880)
  --max-backups <N>        Retention limit for Google Drive snapshots (default: $MAX_BACKUPS)
  -h, --help               Show this help message

Examples:
  ./scripts/upload-temp-snapshots.sh
  ./scripts/upload-temp-snapshots.sh --dry-run
  ./scripts/upload-temp-snapshots.sh --all
  ./scripts/upload-temp-snapshots.sh --service fluidco-16
  ./scripts/upload-temp-snapshots.sh --keep-local
EOF
}

# --- Parse CLI Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--service)
      CUSTOM_SERVICE_NAME="$2"
      shift 2
      ;;
    --service=*)
      CUSTOM_SERVICE_NAME="${1#*=}"
      shift
      ;;
    -a|--all)
      PROCESS_ALL=true
      shift
      ;;
    -d|--dir)
      TARGET_DIR="$2"
      shift 2
      ;;
    --dir=*)
      TARGET_DIR="${1#*=}"
      shift
      ;;
    -k|--keep-local|--no-delete)
      KEEP_LOCAL=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --gcs-bucket)
      GCS_BUCKET_NAME="${2#gs://}"
      shift 2
      ;;
    --gcs-bucket=*)
      GCS_BUCKET_NAME="${1#*=}"
      GCS_BUCKET_NAME="${GCS_BUCKET_NAME#gs://}"
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
    *)
      log_error "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

ACTIVE_SERVICE="${CUSTOM_SERVICE_NAME:-$SERVICE_NAME}"

# Resolve relative path for service account key if needed
if [ -n "$GDRIVE_SERVICE_ACCOUNT_KEY" ] && [[ "$GDRIVE_SERVICE_ACCOUNT_KEY" != /* ]] && [ ! -f "$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
  if [ -f "$PATH_TO_ODOO/$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
    GDRIVE_SERVICE_ACCOUNT_KEY="$PATH_TO_ODOO/$GDRIVE_SERVICE_ACCOUNT_KEY"
  fi
fi

# Determine configured storage backends
HAVE_GDRIVE=false
if [ -n "$GDRIVE_ACCESS_TOKEN" ] || [ -n "$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
  HAVE_GDRIVE=true
fi

HAVE_GCS=false
if [ -n "$GCS_BUCKET_NAME" ]; then
  HAVE_GCS=true
fi

if [ "$HAVE_GDRIVE" = false ] && [ "$HAVE_GCS" = false ]; then
  log_error "No backup storage is configured in $ENV_FILE."
  log_error "Please configure either Google Cloud Storage (GCS_BUCKET_NAME) or Google Drive (GDRIVE_ACCESS_TOKEN / GDRIVE_SERVICE_ACCOUNT_KEY)."
  exit 1
fi

# Helper to run gcloud as REPOSITORY_OWNER if running as root
run_gcloud() {
  if [ "$(id -u)" -eq 0 ]; then
    sudo -u "$REPOSITORY_OWNER" gcloud "$@"
  else
    gcloud "$@"
  fi
}

# --- Google Drive Functions ---
get_gdrive_access_token_from_sa() {
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

is_gdrive_token_valid() {
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

resolve_gdrive_access_token() {
  local current_token="$1"
  local raw_access_token="$2"
  local sa_input="$3"

  if is_gdrive_token_valid "$current_token"; then
    echo "$current_token"
    return 0
  fi

  if [ -n "$sa_input" ]; then
    get_gdrive_access_token_from_sa "$sa_input"
  elif [ -n "$raw_access_token" ]; then
    if [ -f "$raw_access_token" ]; then
      if [[ "$raw_access_token" == *.json ]] || grep -q '"type": *"service_account"' "$raw_access_token" 2>/dev/null; then
        get_gdrive_access_token_from_sa "$raw_access_token"
      else
        local file_tok
        file_tok=$(tr -d '\r\n' < "$raw_access_token")
        if is_gdrive_token_valid "$file_tok"; then
          echo "$file_tok"
        elif [ -n "$sa_input" ]; then
          get_gdrive_access_token_from_sa "$sa_input"
        else
          echo "$file_tok"
        fi
      fi
    elif [[ "$raw_access_token" =~ ^\{.*\}$ ]]; then
      get_gdrive_access_token_from_sa "$raw_access_token"
    else
      echo "$raw_access_token"
    fi
  fi
}

cleanup_gdrive_old_snapshots() {
  local access_token="$1"
  local folder_id="$2"
  local srv_name="$3"
  local max_backups="$4"
  local raw_access_token="${5:-$access_token}"
  local sa_input="$6"

  if [ -z "$max_backups" ] || ! [[ "$max_backups" =~ ^[0-9]+$ ]] || [ "$max_backups" -le 0 ]; then
    return 0
  fi

  local valid_token
  valid_token=$(resolve_gdrive_access_token "$access_token" "$raw_access_token" "$sa_input")
  [ -n "$valid_token" ] && access_token="$valid_token"

  log_info "Running Google Drive lifecycle retention (keeping latest $max_backups for $srv_name)..."

  local query="(name contains 'snapshot-${srv_name}' or name contains 'snapshot--') and trashed = false"
  if [ -n "$folder_id" ]; then
    query="$query and '$folder_id' in parents"
  fi

  local response
  response=$(curl -s -G \
    -H "Authorization: Bearer $access_token" \
    --data-urlencode "q=$query" \
    --data-urlencode "orderBy=createdTime desc" \
    --data-urlencode "fields=files(id, name, createdTime)" \
    --data-urlencode "supportsAllDrives=true" \
    --data-urlencode "includeItemsFromAllDrives=true" \
    --data-urlencode "pageSize=100" \
    "https://www.googleapis.com/drive/v3/files")

  if echo "$response" | grep -q '"error":'; then
    log_warn "Google Drive retention cleanup encountered an error (skipping cleanup): $(echo "$response" | tr -d '\n')"
    return 0
  fi

  local file_ids
  file_ids=$(echo "$response" | grep -o '"id": *"[^"]*"' | cut -d'"' -f4)

  local total_count=0
  if [ -n "$file_ids" ]; then
    total_count=$(echo "$file_ids" | grep -c . || echo "0")
  fi

  if [ "$total_count" -le "$max_backups" ]; then
    log_info "Total snapshots found on Google Drive ($total_count) is within limit ($max_backups)."
    return 0
  fi

  local delete_count=$((total_count - max_backups))
  log_info "Found $total_count remote snapshots. Deleting $delete_count older snapshot(s)..."

  local to_delete
  to_delete=$(echo "$file_ids" | tail -n +$((max_backups + 1)))

  for file_id in $to_delete; do
    if [ -n "$file_id" ]; then
      local del_token
      del_token=$(resolve_gdrive_access_token "$access_token" "$raw_access_token" "$sa_input")
      [ -n "$del_token" ] && access_token="$del_token"

      local del_resp del_status
      del_resp=$(curl -s -w "\n%{http_code}" -X DELETE \
        -H "Authorization: Bearer $access_token" \
        "https://www.googleapis.com/drive/v3/files/${file_id}?supportsAllDrives=true")
      del_status=$(echo "$del_resp" | tail -n1)

      if [ "$del_status" != "204" ] && [ "$del_status" != "200" ]; then
        local trash_resp trash_status
        trash_resp=$(curl -s -w "\n%{http_code}" -X PATCH \
          -H "Authorization: Bearer $access_token" \
          -H "Content-Type: application/json" \
          -d '{"trashed": true}' \
          "https://www.googleapis.com/drive/v3/files/${file_id}?supportsAllDrives=true")
        trash_status=$(echo "$trash_resp" | tail -n1)
        [ "$trash_status" = "200" ] && del_status="200"
      fi

      if [ "$del_status" = "204" ] || [ "$del_status" = "200" ]; then
        log_info "Deleted old remote snapshot (ID: $file_id)"
      else
        log_warn "Could not delete old remote snapshot ID $file_id (HTTP $del_status)."
      fi
    fi
  done
}

upload_to_gdrive_file() {
  local file_path="$1"
  local target_filename="$2"
  local raw_access_token="$3"
  local sa_key_path="$4"
  local folder_id="$5"
  local chunk_size_cfg="$6"
  local max_backups_cfg="$7"
  local srv_name="$8"

  local access_token
  access_token=$(resolve_gdrive_access_token "$raw_access_token" "$raw_access_token" "$sa_key_path")

  if [ -z "$access_token" ]; then
    log_error "Google Drive access token could not be obtained."
    return 1
  fi

  local chunk_size=5242880
  if [ -n "$chunk_size_cfg" ]; then
    if [[ "$chunk_size_cfg" =~ ^[0-9]+$ ]] && [ "$chunk_size_cfg" -gt 0 ] && [ "$((chunk_size_cfg % 262144))" -eq 0 ]; then
      chunk_size="$chunk_size_cfg"
    fi
  fi

  local file_size mime_type
  file_size=$(wc -c < "$file_path" | tr -d ' ')
  mime_type="application/octet-stream"

  log_info "Initiating Google Drive resumable upload for $target_filename ($file_size bytes)..."

  local metadata="{\"name\": \"$target_filename\""
  if [ -n "$folder_id" ]; then
    metadata="$metadata, \"parents\": [\"$folder_id\"]"
  fi
  metadata="$metadata}"

  local init_response session_uri
  init_response=$(curl -s -i -X POST \
    -H "Authorization: Bearer $access_token" \
    -H "X-Upload-Content-Type: $mime_type" \
    -H "X-Upload-Content-Length: $file_size" \
    -H "Content-Type: application/json; charset=UTF-8" \
    -d "$metadata" \
    "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true")

  session_uri=$(echo "$init_response" | grep -i "^location:" | tr -d '\r' | awk '{print $2}')

  if [ -z "$session_uri" ]; then
    log_error "Failed to initiate Google Drive upload session."
    log_error "Response: $init_response"
    return 1
  fi

  local start_byte=0
  local chunk_index=0
  local max_retries=3
  local retry_count=0

  while [ "$start_byte" -lt "$file_size" ]; do
    local end_byte=$((start_byte + chunk_size - 1))
    [ "$end_byte" -ge "$file_size" ] && end_byte=$((file_size - 1))

    local current_chunk_len=$((end_byte - start_byte + 1))
    local pct=$(( (end_byte + 1) * 100 / file_size ))

    log_info "Uploading ${pct}% (${start_byte}-${end_byte}/${file_size} bytes) to Google Drive..."

    local http_response http_status response_body
    http_response=$( (dd if="$file_path" bs="$chunk_size" skip="$chunk_index" count=1 status=none | \
      curl -s -w "\n%{http_code}" -X PUT \
        -H "Content-Length: $current_chunk_len" \
        -H "Content-Range: bytes ${start_byte}-${end_byte}/${file_size}" \
        --data-binary @- \
        "$session_uri") 2>/dev/null || true )

    http_status=$(echo "$http_response" | tail -n1)
    response_body=$(echo "$http_response" | sed '$d')

    if [ "$http_status" = "308" ]; then
      start_byte=$((end_byte + 1))
      chunk_index=$((chunk_index + 1))
      retry_count=0
    elif [ "$http_status" = "200" ] || [ "$http_status" = "201" ]; then
      log_success "Google Drive upload completed: $target_filename"
      if [ -n "$max_backups_cfg" ]; then
        cleanup_gdrive_old_snapshots "$access_token" "$folder_id" "$srv_name" "$max_backups_cfg" "$raw_access_token" "$sa_key_path"
      fi
      return 0
    else
      log_warn "Chunk upload failed with HTTP status: $http_status. Response: $response_body"
      retry_count=$((retry_count + 1))
      if [ "$retry_count" -gt "$max_retries" ]; then
        log_error "Max retries reached for Google Drive chunk upload."
        return 1
      fi

      sleep 2
      local status_response query_status last_byte
      status_response=$(curl -s -i -X PUT \
        -H "Content-Length: 0" \
        -H "Content-Range: bytes */$file_size" \
        "$session_uri")

      query_status=$(echo "$status_response" | grep "^HTTP" | awk '{print $2}')
      if [ "$query_status" = "308" ]; then
        last_byte=$(echo "$status_response" | grep -i "^range:" | tr -d '\r' | awk -F'-' '{print $2}')
        if [ -n "$last_byte" ]; then
          start_byte=$((last_byte + 1))
          chunk_index=$((start_byte / chunk_size))
        fi
      elif [ "$query_status" = "200" ] || [ "$query_status" = "201" ]; then
        log_success "Google Drive upload completed during status check: $target_filename"
        return 0
      fi
    fi
  done

  return 0
}

# --- Scan and Collect Temporary Snapshots ---
log_info "Scanning '$TARGET_DIR' for temporary Odoo snapshot archives..."

# We will collect list of candidate items:
# Format per item: <ITEM_TYPE>|<CONTAINER_PATH>|<FILE_TO_UPLOAD>|<SERVICE>|<TIMESTAMP>|<REMOTE_NAME>
ITEMS=()

# 1. Look for directories created by moveSnapshotFileToTempDir:
# e.g., snapshot-fluidco-16.tar.zst-20260918-062918 or snapshot-SERVICE.tar.zst-*
while IFS= read -r dir_path; do
  [ -z "$dir_path" ] && continue
  dir_base=$(basename "$dir_path")

  # Extract service name from directory name: snapshot-<service>.tar.zst-<timestamp>
  if [[ "$dir_base" =~ ^snapshot-(.*)\.tar\.zst-([0-9]{8}-[0-9]{6})$ ]]; then
    extracted_srv="${BASH_REMATCH[1]}"
    extracted_ts="${BASH_REMATCH[2]}"
  elif [[ "$dir_base" =~ ^snapshot-(.*)\.tar\.zst-(.*)$ ]]; then
    extracted_srv="${BASH_REMATCH[1]}"
    extracted_ts="${BASH_REMATCH[2]}"
  else
    continue
  fi

  # Filter by service unless --all is specified
  if [ "$PROCESS_ALL" = false ] && [ "$extracted_srv" != "$ACTIVE_SERVICE" ]; then
    continue
  fi

  # Find actual archive file inside the directory
  archive_file=""
  if [ -f "$dir_path/snapshot-$extracted_srv.tar.zst" ]; then
    archive_file="$dir_path/snapshot-$extracted_srv.tar.zst"
  else
    # Fallback: any .tar.zst file inside
    archive_file=$(find "$dir_path" -maxdepth 1 -name "*.tar.zst" -print -quit 2>/dev/null || true)
  fi

  if [ -n "$archive_file" ] && [ -f "$archive_file" ]; then
    remote_name="snapshot-${extracted_srv}-${extracted_ts}.tar.zst"
    ITEMS+=("dir|${dir_path}|${archive_file}|${extracted_srv}|${extracted_ts}|${remote_name}")
  fi
done < <(find "$TARGET_DIR" -maxdepth 1 -mindepth 1 -type d -name "snapshot-*.tar.zst-*" 2>/dev/null | sort)

# 2. Look for standalone temporary snapshot files in TARGET_DIR:
# e.g., snapshot-fluidco-16-20260918-062918.tar.zst or snapshot-fluidco-16.tar.zst
while IFS= read -r file_path; do
  [ -z "$file_path" ] && continue
  file_base=$(basename "$file_path")

  # Ignore lock files or non-tar.zst
  [[ "$file_base" != *.tar.zst ]] && continue

  extracted_srv=""
  extracted_ts=""
  remote_name=""

  if [[ "$file_base" =~ ^snapshot-(.*)-([0-9]{8}-[0-9]{6})\.tar\.zst$ ]]; then
    extracted_srv="${BASH_REMATCH[1]}"
    extracted_ts="${BASH_REMATCH[2]}"
    remote_name="$file_base"
  elif [[ "$file_base" =~ ^snapshot-(.*)\.tar\.zst$ ]]; then
    extracted_srv="${BASH_REMATCH[1]}"
    extracted_ts=$(date -r "$file_path" +"%Y%m%d-%H%M%S" 2>/dev/null || date +"%Y%m%d-%H%M%S")
    remote_name="snapshot-${extracted_srv}-${extracted_ts}.tar.zst"
  else
    continue
  fi

  # Filter by service unless --all
  if [ "$PROCESS_ALL" = false ] && [ "$extracted_srv" != "$ACTIVE_SERVICE" ]; then
    continue
  fi

  # Skip active snapshot file if snapshot lock is active
  if [ -f "/var/run/snapshot-$extracted_srv.lock" ]; then
    log_warn "Active snapshot in progress for $extracted_srv (lockfile /var/run/snapshot-$extracted_srv.lock detected). Skipping $file_path."
    continue
  fi

  ITEMS+=("file|${file_path}|${file_path}|${extracted_srv}|${extracted_ts}|${remote_name}")
done < <(find "$TARGET_DIR" -maxdepth 1 -type f -name "snapshot-*.tar.zst" 2>/dev/null | sort)

TOTAL_ITEMS=${#ITEMS[@]}

if [ "$TOTAL_ITEMS" -eq 0 ]; then
  log_info "No temporary snapshots found in $TARGET_DIR matching criteria."
  [ "$PROCESS_ALL" = false ] && log_info "(Filter: service='$ACTIVE_SERVICE'. Use --all to check all services)."
  exit 0
fi

echo "==============================================================================="
log_info "Found $TOTAL_ITEMS temporary snapshot(s) to upload:"
for entry in "${ITEMS[@]}"; do
  IFS='|' read -r itype cpath afile isrv its rname <<< "$entry"
  fsize_h=$(ls -lh "$afile" 2>/dev/null | awk '{print $5}' || echo "unknown")
  echo "  - [$itype] $cpath ($fsize_h) -> $rname"
done
echo "==============================================================================="

# Display target storage
log_info "Configured Backup Storage Targets:"
[ "$HAVE_GCS" = true ] && echo "  - Google Cloud Storage: gs://$GCS_BUCKET_NAME"
[ "$HAVE_GDRIVE" = true ] && echo "  - Google Drive: Folder ID '${GDRIVE_FOLDER_ID:-root}'"
echo

if [ "$DRY_RUN" = true ]; then
  log_warn "DRY RUN MODE: No files will be uploaded or deleted."
  exit 0
fi

# Check prerequisites
if [ "$HAVE_GCS" = true ]; then
  if ! command -v gcloud >/dev/null 2>&1; then
    log_error "gcloud CLI is not installed, but GCS_BUCKET_NAME is set in .env."
    exit 1
  fi
  # Disable parallel composite upload check to avoid permission errors
  if [ "$(run_gcloud config get-value storage/parallel_composite_upload_compatibility_check 2>/dev/null)" != "false" ]; then
    run_gcloud config set storage/parallel_composite_upload_compatibility_check false 2>/dev/null || true
  fi
  if ! run_gcloud storage ls "gs://$GCS_BUCKET_NAME" >/dev/null 2>&1; then
    log_error "Cannot access Google Cloud Storage bucket: gs://$GCS_BUCKET_NAME"
    exit 1
  fi
  log_success "Verified Google Cloud Storage bucket access: gs://$GCS_BUCKET_NAME"
fi

if [ "$HAVE_GDRIVE" = true ]; then
  if ! command -v curl >/dev/null 2>&1 || ! command -v dd >/dev/null 2>&1; then
    log_error "curl and dd are required for Google Drive upload."
    exit 1
  fi
  if [ -n "$GDRIVE_SERVICE_ACCOUNT_KEY" ] && ! command -v openssl >/dev/null 2>&1; then
    log_error "openssl is required for Service Account authentication."
    exit 1
  fi
  log_info "Verifying Google Drive authentication..."
  test_tok=$(resolve_gdrive_access_token "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_SERVICE_ACCOUNT_KEY")
  if [ -z "$test_tok" ]; then
    log_error "Google Drive authentication failed. Check GDRIVE_ACCESS_TOKEN or GDRIVE_SERVICE_ACCOUNT_KEY in .env."
    exit 1
  fi
  log_success "Verified Google Drive authentication."
fi

# Process uploads
SUCCESS_COUNT=0
FAIL_COUNT=0
CLEANUP_COUNT=0

for entry in "${ITEMS[@]}"; do
  IFS='|' read -r itype cpath afile isrv its rname <<< "$entry"

  echo "-------------------------------------------------------------------------------"
  log_info "Processing ($((SUCCESS_COUNT + FAIL_COUNT + 1))/$TOTAL_ITEMS): $rname"
  echo "-------------------------------------------------------------------------------"

  item_success=true

  # 1. Upload to GCS if configured
  if [ "$HAVE_GCS" = true ]; then
    log_info "Uploading to Google Cloud Storage: gs://$GCS_BUCKET_NAME/$rname..."
    if run_gcloud storage cp "$afile" "gs://$GCS_BUCKET_NAME/$rname"; then
      log_success "Uploaded to gs://$GCS_BUCKET_NAME/$rname"
    else
      log_error "Failed to upload to GCS: gs://$GCS_BUCKET_NAME/$rname"
      item_success=false
    fi
  fi

  # 2. Upload to Google Drive if configured
  if [ "$HAVE_GDRIVE" = true ] && [ "$item_success" = true ]; then
    log_info "Uploading to Google Drive: $rname..."
    if upload_to_gdrive_file "$afile" "$rname" "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_SERVICE_ACCOUNT_KEY" "$GDRIVE_FOLDER_ID" "$GDRIVE_CHUNK_SIZE" "$MAX_BACKUPS" "$isrv"; then
      log_success "Uploaded to Google Drive: $rname"
    else
      log_error "Failed to upload to Google Drive: $rname"
      item_success=false
    fi
  fi

  # 3. Cleanup local temporary file/directory if successful
  if [ "$item_success" = true ]; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    if [ "$KEEP_LOCAL" = false ]; then
      log_info "Cleaning up temporary local path: $cpath..."
      if [ "$itype" = "dir" ]; then
        rm -rf "$cpath"
      else
        rm -f "$cpath"
      fi
      CLEANUP_COUNT=$((CLEANUP_COUNT + 1))
      log_success "Deleted local temporary snapshot: $cpath"
    else
      log_info "Preserving local file (--keep-local is enabled): $cpath"
    fi
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    log_warn "Keeping temporary files locally for retry: $cpath"
  fi
done

echo
echo "==============================================================================="
log_info "Summary:"
echo "  - Total found:     $TOTAL_ITEMS"
echo "  - Upload success:  $SUCCESS_COUNT"
echo "  - Upload failed:   $FAIL_COUNT"
echo "  - Local cleaned:   $CLEANUP_COUNT"
echo "==============================================================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi

exit 0
