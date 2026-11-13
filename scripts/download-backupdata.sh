#!/usr/bin/env bash
set -euo pipefail
# Category: Utility
# Description: Dumps an Odoo database + filestore into a standard Odoo ZIP and uploads it to Google Drive.
# Usage: ./scripts/download-backupdata.sh [--db NAME] [--neutralize] [--gdrive-folder-id ID] [--gdrive-token-stdin] [--share-email EMAIL] [--json]
# Dependencies: 7z/7za, pg_dump, psql, curl, python3, sudo, git, ssh, rsync

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$CURRENT_DIR")
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
ENV_FILE="$PATH_TO_ODOO/.env"

TARGET_DB=""
NEUTRALIZE=false
GDRIVE_FOLDER_ID=""
GDRIVE_TOKEN_STDIN=false
SHARE_EMAIL=""
JSON_MODE=false
GDRIVE_ACCESS_TOKEN="${GDRIVE_ACCESS_TOKEN:-}"

TEMP_WORK_DIR=""

log_msg() {
  local level="$1"
  local msg="$2"
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] [$level] $msg" >&2
}

json_error() {
  local msg="$1"
  if [ "$JSON_MODE" = true ]; then
    python3 -c 'import json, sys; print(json.dumps({"status": "error", "error": sys.argv[1]}))' "$msg"
  else
    log_msg "ERROR" "$msg"
  fi
  exit 1
}

cleanup() {
  if [ -n "$TEMP_WORK_DIR" ] && [ -d "$TEMP_WORK_DIR" ]; then
    rm -rf "$TEMP_WORK_DIR"
  fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)
      TARGET_DB="${2:-}"
      shift 2
      ;;
    --neutralize)
      NEUTRALIZE=true
      shift
      ;;
    --gdrive-folder-id)
      GDRIVE_FOLDER_ID="${2:-}"
      shift 2
      ;;
    --gdrive-token-stdin)
      GDRIVE_TOKEN_STDIN=true
      shift
      ;;
    --share-email)
      SHARE_EMAIL="${2:-}"
      shift 2
      ;;
    --json)
      JSON_MODE=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--db NAME] [--neutralize] [--gdrive-folder-id ID] [--gdrive-token-stdin] [--share-email EMAIL] [--json]"
      exit 0
      ;;
    *)
      json_error "Unknown argument: $1"
      ;;
  esac
done

# Read Bearer token from stdin before sudo re-exec if requested
if [ "$GDRIVE_TOKEN_STDIN" = true ] && [ -z "$GDRIVE_ACCESS_TOKEN" ]; then
  IFS= read -r GDRIVE_ACCESS_TOKEN || true
  export GDRIVE_ACCESS_TOKEN
fi

if [ "$(id -u)" -ne 0 ]; then
  exec sudo --preserve-env=GDRIVE_ACCESS_TOKEN "$0" \
    ${TARGET_DB:+--db "$TARGET_DB"} \
    $([ "$NEUTRALIZE" = true ] && echo "--neutralize") \
    ${GDRIVE_FOLDER_ID:+--gdrive-folder-id "$GDRIVE_FOLDER_ID"} \
    ${SHARE_EMAIL:+--share-email "$SHARE_EMAIL"} \
    $([ "$JSON_MODE" = true ] && echo "--json")
fi

read_env_val() {
  local key="$1"
  local file="${2:-$ENV_FILE}"
  [ -f "$file" ] || return 0
  grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1 | cut -d '=' -f 2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true
}

# 1. Storage backend guard: reject GCS
GCS_BUCKET_NAME=$(read_env_val "GCS_BUCKET_NAME")
STORAGE_BACKEND=$(read_env_val "SNAPSHOT_STORAGE_BACKEND")
if [ -n "$GCS_BUCKET_NAME" ] || [ "${STORAGE_BACKEND,,}" = "gcs" ]; then
  json_error "This feature currently only accepts deployments that use Google Drive. GCS is not supported yet."
fi

# 2. Resolve DB name and Google Drive config
if [ -z "$TARGET_DB" ]; then
  TARGET_DB=$(read_env_val "DB_NAME")
fi
[ -z "$TARGET_DB" ] && json_error "Target database name is not specified and DB_NAME is empty in .env."

if [ -z "$GDRIVE_FOLDER_ID" ]; then
  GDRIVE_FOLDER_ID=$(read_env_val "GDRIVE_FOLDER_ID")
fi
[ -z "$GDRIVE_FOLDER_ID" ] && json_error "Google Drive Folder ID is required."
[ -z "$GDRIVE_ACCESS_TOKEN" ] && json_error "Google Drive Bearer access token is required."

# 3. Database helpers (matching dataodoo-backupper.sh)
run_pg_dump() {
  local db_host
  db_host=$(read_env_val "DB_HOST")
  if [ -n "$db_host" ] && [ "$db_host" != "localhost" ]; then
    local db_port db_user db_pass docker_net net
    db_port=$(read_env_val "DB_PORT")
    db_user=$(cat "$PATH_TO_ODOO/.secrets/db_user" 2>/dev/null || true)
    db_pass=$(cat "$PATH_TO_ODOO/.secrets/db_password" 2>/dev/null || true)
    docker_net=$(read_env_val "DOCKER_NETWORK_MODE")
    [ -z "$db_port" ] && db_port="5432"
    [ -z "$docker_net" ] && docker_net="host"
    net=$(echo "$docker_net" | cut -d "," -f 1)
    PGPASSWORD="$db_pass" docker run -i --rm --network="$net" -e PGPASSWORD postgres pg_dump -h "$db_host" -p "$db_port" -U "$db_user" "$@"
  else
    sudo -u postgres pg_dump "$@"
  fi
}

run_psql() {
  local db_host
  db_host=$(read_env_val "DB_HOST")
  if [ -n "$db_host" ] && [ "$db_host" != "localhost" ]; then
    local db_port db_user db_pass docker_net net
    db_port=$(read_env_val "DB_PORT")
    db_user=$(cat "$PATH_TO_ODOO/.secrets/db_user" 2>/dev/null || true)
    db_pass=$(cat "$PATH_TO_ODOO/.secrets/db_password" 2>/dev/null || true)
    docker_net=$(read_env_val "DOCKER_NETWORK_MODE")
    [ -z "$db_port" ] && db_port="5432"
    [ -z "$docker_net" ] && docker_net="host"
    net=$(echo "$docker_net" | cut -d "," -f 1)
    PGPASSWORD="$db_pass" docker run -i --rm --network="$net" -e PGPASSWORD postgres psql -h "$db_host" -p "$db_port" -U "$db_user" "$@"
  else
    sudo -u postgres psql "$@"
  fi
}

generate_manifest() {
  local db_name="$1"
  local target_file="$2"
  local sql="
    WITH installed_modules AS (
        SELECT json_object_agg(name, latest_version) as modules
        FROM ir_module_module
        WHERE state = 'installed'
    ),
    pg_v AS (
        SELECT setting FROM pg_settings WHERE name = 'server_version_num'
    )
    SELECT json_build_object(
        'odoo_dump', '1',
        'db_name', '$db_name',
        'version', split_part(latest_version, '.', 1) || '.' || split_part(latest_version, '.', 2),
        'major_version', split_part(latest_version, '.', 1),
        'pg_version', (SELECT floor(setting::int / 10000) || '.' || floor((setting::int % 10000) / 100) FROM pg_v),
        'modules', (SELECT modules FROM installed_modules),
        'version_info', json_build_array(
            split_part(latest_version, '.', 1)::int,
            split_part(latest_version, '.', 2)::int,
            0, 'final', 0, ''
        )
    ) FROM ir_module_module WHERE name = 'base';
  "
  if ! run_psql -d "$db_name" -t -A -c "$sql" > "$target_file" 2>/dev/null || [ ! -s "$target_file" ]; then
    echo "{\"odoo_dump\": \"1\", \"db_name\": \"$db_name\"}" > "$target_file"
  fi
}

append_neutralization_sql() {
  local dump_file="$1"
  cat <<'EOSQL' >> "$dump_file"

-- SudoDevOps Database Neutralization (safe for downloaded backups)
DO $$
BEGIN
    UPDATE ir_cron SET active = false WHERE active = true;
EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
END $$;
DO $$
BEGIN
    UPDATE ir_mail_server SET active = false WHERE active = true;
EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
END $$;
DO $$
BEGIN
    UPDATE fetchmail_server SET active = false WHERE active = true;
EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
END $$;
DO $$
BEGIN
    UPDATE payment_provider SET state = 'disabled' WHERE state != 'disabled';
EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
END $$;
DO $$
BEGIN
    UPDATE payment_acquirer SET state = 'disabled' WHERE state != 'disabled';
EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
END $$;
DO $$
BEGIN
    INSERT INTO ir_config_parameter (key, value)
    VALUES ('database.is_neutralized', 'True')
    ON CONFLICT (key) DO UPDATE SET value = 'True';
EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
END $$;
EOSQL
}

upload_to_gdrive() {
  local file_path="$1"
  local file_name="$2"
  local folder_id="$3"
  local token="$4"
  local share_email="$5"

  python3 - "$file_path" "$file_name" "$folder_id" "$share_email" "$token" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

file_path, file_name, folder_id, share_email, token = sys.argv[1:6]
file_size = os.path.getsize(file_path)

# 1. Initiate resumable upload
init_url = "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true"
metadata = json.dumps({"name": file_name, "parents": [folder_id]}).encode("utf-8")
req = urllib.request.Request(
    init_url,
    data=metadata,
    method="POST",
    headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json; charset=UTF-8",
        "X-Upload-Content-Type": "application/zip",
        "X-Upload-Content-Length": str(file_size),
    },
)
with urllib.request.urlopen(req, timeout=60) as resp:
    upload_uri = resp.headers.get("Location")
if not upload_uri:
    raise RuntimeError("Google Drive did not return a resumable upload Location header.")

# 2. Stream file in 8MB chunks
chunk_size = 8 * 1024 * 1024
offset = 0
uploaded_info = None
with open(file_path, "rb") as fh:
    while offset < file_size:
        chunk = fh.read(chunk_size)
        if not chunk:
            break
        end = offset + len(chunk) - 1
        put_req = urllib.request.Request(
            upload_uri,
            data=chunk,
            method="PUT",
            headers={
                "Content-Length": str(len(chunk)),
                "Content-Range": f"bytes {offset}-{end}/{file_size}",
            },
        )
        try:
            with urllib.request.urlopen(put_req, timeout=300) as put_resp:
                uploaded_info = json.loads(put_resp.read().decode("utf-8"))
        except urllib.error.HTTPError as err:
            if err.code == 308:
                offset = end + 1
                continue
            body = err.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Drive upload failed ({err.code}): {body}")
        offset = end + 1

if not uploaded_info or not uploaded_info.get("id"):
    raise RuntimeError("Google Drive upload completed without returning a file ID.")

file_id = uploaded_info["id"]

# 3. Grant reader permission (requester email or anyoneWithLink)
perm_payload = (
    {"type": "user", "role": "reader", "emailAddress": share_email}
    if share_email
    else {"type": "anyone", "role": "reader"}
)
perm_url = f"https://www.googleapis.com/drive/v3/files/{file_id}/permissions?supportsAllDrives=true"
perm_req = urllib.request.Request(
    perm_url,
    data=json.dumps(perm_payload).encode("utf-8"),
    method="POST",
    headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    },
)
try:
    with urllib.request.urlopen(perm_req, timeout=30):
        pass
except urllib.error.HTTPError:
    # Fallback to anyoneWithLink if user email is not a Google account
    if share_email:
        fallback_req = urllib.request.Request(
            perm_url,
            data=json.dumps({"type": "anyone", "role": "reader"}).encode("utf-8"),
            method="POST",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(fallback_req, timeout=30):
            pass

# 4. Fetch webViewLink & webContentLink
meta_url = f"https://www.googleapis.com/drive/v3/files/{file_id}?fields=id,name,size,webViewLink,webContentLink&supportsAllDrives=true"
meta_req = urllib.request.Request(meta_url, headers={"Authorization": f"Bearer {token}"})
with urllib.request.urlopen(meta_req, timeout=30) as meta_resp:
    meta = json.loads(meta_resp.read().decode("utf-8"))

print(json.dumps(meta))
PY
}

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
ZIP_NAME="${TARGET_DB}-${TIMESTAMP}.zip"
TEMP_WORK_DIR=$(mktemp -d -t "depcon_dl_XXXXXX")
ZIP_PATH="$TEMP_WORK_DIR/$ZIP_NAME"

# Build dump + manifest + filestore
DB_WORK_DIR="$TEMP_WORK_DIR/payload"
mkdir -p "$DB_WORK_DIR"

log_msg "INFO" "Dumping PostgreSQL database '$TARGET_DB'..."
if ! run_pg_dump --no-owner "$TARGET_DB" > "$DB_WORK_DIR/dump.sql"; then
  json_error "pg_dump failed for database '$TARGET_DB'."
fi

if [ "$NEUTRALIZE" = true ]; then
  log_msg "INFO" "Appending database neutralization SQL..."
  append_neutralization_sql "$DB_WORK_DIR/dump.sql"
fi

generate_manifest "$TARGET_DB" "$DB_WORK_DIR/manifest.json"

FILESTORE_SRC="/var/lib/odoo/$SERVICE_NAME/filestore/$TARGET_DB"
if [ -d "$FILESTORE_SRC" ]; then
  log_msg "INFO" "Packaging filestore from $FILESTORE_SRC..."
  cp -al "$FILESTORE_SRC" "$DB_WORK_DIR/filestore" 2>/dev/null || cp -r "$FILESTORE_SRC" "$DB_WORK_DIR/filestore"
fi

ZIP_CMD="7z"
command -v 7z >/dev/null 2>&1 || ZIP_CMD="7za"
if ! command -v "$ZIP_CMD" >/dev/null 2>&1; then
  json_error "7z/7za is not installed on the server."
fi

log_msg "INFO" "Compressing backup archive $ZIP_NAME..."
(cd "$DB_WORK_DIR" && "$ZIP_CMD" a -tzip -mmt=on "$ZIP_PATH" dump.sql manifest.json >/dev/null)
if [ -d "$DB_WORK_DIR/filestore" ]; then
  (cd "$DB_WORK_DIR" && "$ZIP_CMD" a -tzip -mx=0 "$ZIP_PATH" filestore >/dev/null)
fi
rm -rf "$DB_WORK_DIR"

SIZE_BYTES=$(stat -c %s "$ZIP_PATH")
SNAPSHOT_REMOTE_HOST=$(read_env_val "SNAPSHOT_REMOTE_HOST")

if [ -n "$SNAPSHOT_REMOTE_HOST" ]; then
  SNAPSHOT_REMOTE_USER=$(read_env_val "SNAPSHOT_REMOTE_USER")
  SNAPSHOT_REMOTE_PORT=$(read_env_val "SNAPSHOT_REMOTE_PORT")
  SNAPSHOT_REMOTE_KEY=$(read_env_val "SNAPSHOT_REMOTE_KEY")
  [ -z "$SNAPSHOT_REMOTE_PORT" ] && SNAPSHOT_REMOTE_PORT="22"
  [ -z "$SNAPSHOT_REMOTE_USER" ] && json_error "SNAPSHOT_REMOTE_USER is required when SNAPSHOT_REMOTE_HOST is set."

  SSH_OPTS=(-p "$SNAPSHOT_REMOTE_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
  [ -n "$SNAPSHOT_REMOTE_KEY" ] && SSH_OPTS+=(-i "$SNAPSHOT_REMOTE_KEY")

  REMOTE_TMP="/tmp/depcon_dl_${TIMESTAMP}_${ZIP_NAME}"
  log_msg "INFO" "Transferring archive to Secondary VPS ($SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST) for Google Drive upload..."
  rsync -e "ssh ${SSH_OPTS[*]}" -az "$ZIP_PATH" "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST:$REMOTE_TMP"
  rm -f "$ZIP_PATH"

  # Upload from Secondary VPS using only the short-lived Bearer token via stdin
  UPLOAD_JSON=$(printf '%s\n' "$GDRIVE_ACCESS_TOKEN" | ssh "${SSH_OPTS[@]}" "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST" \
    "python3 - '$REMOTE_TMP' '$ZIP_NAME' '$GDRIVE_FOLDER_ID' '$SHARE_EMAIL'" <<'REMOTE_PY'
import json, os, sys, urllib.error, urllib.request
file_path, file_name, folder_id, share_email = sys.argv[1:5]
token = sys.stdin.readline().strip()
try:
    file_size = os.path.getsize(file_path)
    init_url = "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true"
    metadata = json.dumps({"name": file_name, "parents": [folder_id]}).encode("utf-8")
    req = urllib.request.Request(init_url, data=metadata, method="POST", headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json; charset=UTF-8",
        "X-Upload-Content-Type": "application/zip",
        "X-Upload-Content-Length": str(file_size),
    })
    with urllib.request.urlopen(req, timeout=60) as resp:
        upload_uri = resp.headers.get("Location")
    chunk_size = 8 * 1024 * 1024
    offset = 0
    uploaded_info = None
    with open(file_path, "rb") as fh:
        while offset < file_size:
            chunk = fh.read(chunk_size)
            if not chunk:
                break
            end = offset + len(chunk) - 1
            put_req = urllib.request.Request(upload_uri, data=chunk, method="PUT", headers={
                "Content-Length": str(len(chunk)),
                "Content-Range": f"bytes {offset}-{end}/{file_size}",
            })
            try:
                with urllib.request.urlopen(put_req, timeout=300) as put_resp:
                    uploaded_info = json.loads(put_resp.read().decode("utf-8"))
            except urllib.error.HTTPError as err:
                if err.code == 308:
                    offset = end + 1
                    continue
                raise
            offset = end + 1
    file_id = uploaded_info["id"]
    perm_payload = {"type": "user", "role": "reader", "emailAddress": share_email} if share_email else {"type": "anyone", "role": "reader"}
    perm_url = f"https://www.googleapis.com/drive/v3/files/{file_id}/permissions?supportsAllDrives=true"
    try:
        urllib.request.urlopen(urllib.request.Request(perm_url, data=json.dumps(perm_payload).encode("utf-8"), method="POST", headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"}), timeout=30).close()
    except urllib.error.HTTPError:
        if share_email:
            urllib.request.urlopen(urllib.request.Request(perm_url, data=json.dumps({"type": "anyone", "role": "reader"}).encode("utf-8"), method="POST", headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"}), timeout=30).close()
    meta_url = f"https://www.googleapis.com/drive/v3/files/{file_id}?fields=id,name,size,webViewLink,webContentLink&supportsAllDrives=true"
    with urllib.request.urlopen(urllib.request.Request(meta_url, headers={"Authorization": f"Bearer {token}"}), timeout=30) as mr:
        print(mr.read().decode("utf-8"))
finally:
    if os.path.exists(file_path):
        os.remove(file_path)
REMOTE_PY
  )
else
  log_msg "INFO" "Uploading archive to Google Drive..."
  UPLOAD_JSON=$(upload_to_gdrive "$ZIP_PATH" "$ZIP_NAME" "$GDRIVE_FOLDER_ID" "$GDRIVE_ACCESS_TOKEN" "$SHARE_EMAIL")
  rm -f "$ZIP_PATH"
fi

python3 - "$UPLOAD_JSON" "$TARGET_DB" "$ZIP_NAME" "$SIZE_BYTES" "$NEUTRALIZE" <<'PY'
import json, sys
meta = json.loads(sys.argv[1])
db_name, file_name, size_bytes, neutralized = sys.argv[2:6]
fid = meta.get("id", "")
print(json.dumps({
    "status": "ok",
    "database_name": db_name,
    "file_name": file_name,
    "size_bytes": int(size_bytes),
    "gdrive_file_id": fid,
    "gdrive_web_view_link": meta.get("webViewLink") or f"https://drive.google.com/file/d/{fid}/view",
    "gdrive_download_link": meta.get("webContentLink") or f"https://drive.google.com/uc?id={fid}&export=download",
    "neutralized": neutralized == "true",
}))
PY
