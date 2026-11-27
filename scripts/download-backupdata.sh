#!/usr/bin/env bash
set -euo pipefail
# Category: Utility
# Description: Dumps an Odoo database + filestore into a standard Odoo ZIP and uploads it to Google Drive.
# Usage: ./scripts/download-backupdata.sh [--db NAME] [--neutralize] [--exclude-chatter] [--exclude-assets] [--no-filestore] [--gdrive-folder-id ID] [--gdrive-token-stdin] [--share-email EMAIL] [--json]
# Dependencies: 7z/7za, pg_dump, psql, curl, python3, sudo, git, ssh, rsync

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$CURRENT_DIR")
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
ENV_FILE="$PATH_TO_ODOO/.env"

TARGET_DB=""
NEUTRALIZE=false
EXCLUDE_CHATTER=false
EXCLUDE_ASSETS=false
NO_FILESTORE=false
GDRIVE_FOLDER_ID=""
GDRIVE_TOKEN_STDIN=false
SHARE_EMAIL=""
JSON_MODE=false
GDRIVE_ACCESS_TOKEN="${GDRIVE_ACCESS_TOKEN:-}"

TEMP_WORK_DIR=""
REMOTE_CLEANUP_TARGET=""
REMOTE_CLEANUP_PATH=""
REMOTE_SSH_OPTS=()

log_msg() {
  local level="$1"
  local msg="$2"
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] [$level] $msg" >&2
}

log_info() { log_msg "INFO" "$1"; }
log_warn() { log_msg "WARN" "$1"; }
log_error() { log_msg "ERROR" "$1"; }
log_success() { log_msg "SUCCESS" "$1"; }

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
  if declare -F queue_lock_release_all >/dev/null 2>&1; then
    queue_lock_release_all
  fi
  if [ -n "$TEMP_WORK_DIR" ] && [ -d "$TEMP_WORK_DIR" ]; then
    rm -rf "$TEMP_WORK_DIR"
  fi
  if [ -n "$REMOTE_CLEANUP_TARGET" ] && [ -n "$REMOTE_CLEANUP_PATH" ]; then
    ssh "${REMOTE_SSH_OPTS[@]}" "$REMOTE_CLEANUP_TARGET" "rm -rf $(printf '%q' "$REMOTE_CLEANUP_PATH")" >/dev/null 2>&1 || true
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
    --exclude-chatter)
      EXCLUDE_CHATTER=true
      shift
      ;;
    --exclude-assets)
      EXCLUDE_ASSETS=true
      shift
      ;;
    --no-filestore)
      NO_FILESTORE=true
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
      echo "Usage: $0 [--db NAME] [--neutralize] [--exclude-chatter] [--exclude-assets] [--no-filestore] [--gdrive-folder-id ID] [--gdrive-token-stdin] [--share-email EMAIL] [--json]"
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
    $([ "$EXCLUDE_CHATTER" = true ] && echo "--exclude-chatter") \
    $([ "$EXCLUDE_ASSETS" = true ] && echo "--exclude-assets") \
    $([ "$NO_FILESTORE" = true ] && echo "--no-filestore") \
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
  local target_file="${2:-}"
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
  local manifest_out
  if ! manifest_out=$(run_psql -d "$db_name" -t -A -c "$sql" 2>/dev/null) || [ -z "$manifest_out" ]; then
    manifest_out="{\"odoo_dump\": \"1\", \"db_name\": \"$db_name\"}"
  fi
  if [ -n "$target_file" ]; then
    printf '%s\n' "$manifest_out" > "$target_file"
  else
    printf '%s\n' "$manifest_out"
  fi
}

emit_neutralization_sql() {
  cat <<'EOSQL'

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

append_neutralization_sql() {
  local dump_file="$1"
  emit_neutralization_sql >> "$dump_file"
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

generate_attachment_exclusions() {
  local db="$1"
  local exclude_txt="$2"
  local ex_chatter="$3"
  local ex_assets="$4"

  local excluded_cats=()
  [ "$ex_chatter" = true ] && excluded_cats+=("'chatter'")
  [ "$ex_assets" = true ] && excluded_cats+=("'asset'")

  if [ "${#excluded_cats[@]}" -eq 0 ]; then
    touch "$exclude_txt"
    return 0
  fi

  local cat_in
  cat_in=$(IFS=,; echo "${excluded_cats[*]}")

  local has_chatter
  has_chatter=$(run_psql -d "$db" -t -A -c "SELECT count(*) FROM information_schema.tables WHERE table_name = 'message_attachment_rel';" 2>/dev/null || echo "0")

  local cte
  if [ "$has_chatter" = "1" ]; then
    cte="
WITH chatter_ids AS (
  SELECT DISTINCT attachment_id FROM message_attachment_rel
),
classified AS (
  SELECT
    store_fname,
    CASE
      WHEN id IN (SELECT attachment_id FROM chatter_ids) THEN 'chatter'
      WHEN res_model = 'ir.ui.view' AND (url LIKE '/web/assets/%' OR name LIKE '%.assets_%') THEN 'asset'
      WHEN res_field IS NOT NULL AND res_field != '' THEN 'field'
      WHEN res_model IS NOT NULL AND res_model != '' THEN 'record'
      ELSE 'standalone'
    END AS category
  FROM ir_attachment
  WHERE store_fname IS NOT NULL
)"
  else
    cte="
WITH classified AS (
  SELECT
    store_fname,
    CASE
      WHEN res_model = 'mail.message' THEN 'chatter'
      WHEN res_model = 'ir.ui.view' AND (url LIKE '/web/assets/%' OR name LIKE '%.assets_%') THEN 'asset'
      WHEN res_field IS NOT NULL AND res_field != '' THEN 'field'
      WHEN res_model IS NOT NULL AND res_model != '' THEN 'record'
      ELSE 'standalone'
    END AS category
  FROM ir_attachment
  WHERE store_fname IS NOT NULL
)"
  fi

  # Dedup rule: A store_fname is ONLY excluded if ALL references to it belong to excluded categories
  local sql_exclude="
$cte,
excludable_fnames AS (
  SELECT store_fname
  FROM classified
  GROUP BY store_fname
  HAVING bool_and(category IN ($cat_in))
)
SELECT store_fname FROM excludable_fnames;
"
  run_psql -d "$db" -t -A -c "$sql_exclude" 2>/dev/null | sed '/^[[:space:]]*$/d' > "$exclude_txt" || touch "$exclude_txt"
  local count
  count=$(wc -l < "$exclude_txt")
  log_msg "INFO" "Identified $count unique filestore files to exclude (dedup-safe: $cat_in)."
}

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
if [ "$NO_FILESTORE" = true ]; then
  ZIP_NAME="${TARGET_DB}-${TIMESTAMP}-nofilestore.zip"
  FILESTORE_MODE="none"
elif [ "$EXCLUDE_CHATTER" = true ] || [ "$EXCLUDE_ASSETS" = true ]; then
  ZIP_NAME="${TARGET_DB}-${TIMESTAMP}-lite.zip"
  FILESTORE_MODE="lightweight"
else
  ZIP_NAME="${TARGET_DB}-${TIMESTAMP}.zip"
  FILESTORE_MODE="full"
fi
OWNER_HOME=$(getent passwd "$CURRENT_DIR_USER" 2>/dev/null | cut -d: -f6 || true)
if [ -n "$OWNER_HOME" ] && [ -d "$OWNER_HOME" ]; then
  TEMP_WORK_DIR=$(mktemp -d "$OWNER_HOME/.depcon_dl_XXXXXX")
else
  TEMP_WORK_DIR=$(mktemp -d -t "depcon_dl_XXXXXX")
fi

# Shared queue lock (odoo-backup-system): coordinate I/O & mirror/filestore with snapshot.sh
SNAPSHOT_QUEUE_NAME="odoo-backup-system"
DEFAULT_SNAPSHOT_QUEUE_TIMEOUT=43200
SNAPSHOT_QUEUE_TIMEOUT=$(read_env_val "SNAPSHOT_QUEUE_TIMEOUT")
if ! [[ "$SNAPSHOT_QUEUE_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$SNAPSHOT_QUEUE_TIMEOUT" -le 0 ]; then
  SNAPSHOT_QUEUE_TIMEOUT="$DEFAULT_SNAPSHOT_QUEUE_TIMEOUT"
fi
SNAPSHOT_QUEUE_POLL_INTERVAL=$(read_env_val "SNAPSHOT_QUEUE_POLL_INTERVAL")
[[ "$SNAPSHOT_QUEUE_POLL_INTERVAL" =~ ^[0-9]+$ ]] && [ "$SNAPSHOT_QUEUE_POLL_INTERVAL" -gt 0 ] || SNAPSHOT_QUEUE_POLL_INTERVAL=60
SNAPSHOT_QUEUE_STALE_AFTER=$(read_env_val "SNAPSHOT_QUEUE_STALE_AFTER")
[[ "$SNAPSHOT_QUEUE_STALE_AFTER" =~ ^[0-9]+$ ]] && [ "$SNAPSHOT_QUEUE_STALE_AFTER" -gt 0 ] || SNAPSHOT_QUEUE_STALE_AFTER=600

QUEUE_LOCK_LIB=""
if [ -f "$CURRENT_DIR/lib/queue_lock.sh" ]; then
  QUEUE_LOCK_LIB="$CURRENT_DIR/lib/queue_lock.sh"
elif [ -f "$PATH_TO_ODOO/scripts/lib/queue_lock.sh" ]; then
  QUEUE_LOCK_LIB="$PATH_TO_ODOO/scripts/lib/queue_lock.sh"
fi
if [ -n "$QUEUE_LOCK_LIB" ]; then
  # shellcheck source=/dev/null
  source "$QUEUE_LOCK_LIB"
  QUEUE_LOCK_POLL_INTERVAL="$SNAPSHOT_QUEUE_POLL_INTERVAL"
  QUEUE_LOCK_STALE_AFTER="$SNAPSHOT_QUEUE_STALE_AFTER"
  QUEUE_LOCK_LEGACY_STALE_AFTER="$SNAPSHOT_QUEUE_TIMEOUT"
  if ! queue_lock_acquire_local "$SNAPSHOT_QUEUE_NAME" "$SERVICE_NAME" \
      "$SERVICE_NAME (download-backupdata on $(hostname -s 2>/dev/null || hostname))" "$SNAPSHOT_QUEUE_TIMEOUT"; then
    json_error "Timed out waiting for local '$SNAPSHOT_QUEUE_NAME' queue."
  fi
fi

# Lower local I/O and CPU scheduling priority
if command -v ionice >/dev/null 2>&1; then
  ionice -c2 -n7 -p $$ 2>/dev/null || true
fi
renice -n 19 -p $$ >/dev/null 2>&1 || true

FILESTORE_SRC="/var/lib/odoo/$SERVICE_NAME/filestore/$TARGET_DB"
ENV_DB_NAME=$(read_env_val "DB_NAME")
SNAPSHOT_REMOTE_HOST=$(read_env_val "SNAPSHOT_REMOTE_HOST")

if [ -n "$SNAPSHOT_REMOTE_HOST" ]; then
  SNAPSHOT_REMOTE_USER=$(read_env_val "SNAPSHOT_REMOTE_USER")
  SNAPSHOT_REMOTE_PORT=$(read_env_val "SNAPSHOT_REMOTE_PORT")
  SNAPSHOT_REMOTE_KEY=$(read_env_val "SNAPSHOT_REMOTE_KEY")
  [ -z "$SNAPSHOT_REMOTE_PORT" ] && SNAPSHOT_REMOTE_PORT="22"
  [ -z "$SNAPSHOT_REMOTE_USER" ] && json_error "SNAPSHOT_REMOTE_USER is required when SNAPSHOT_REMOTE_HOST is set."

  if [ -z "$SNAPSHOT_REMOTE_KEY" ] && [ -n "$OWNER_HOME" ]; then
    THIS_VPS=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "vps-source")
    CLEAN_TGT=$(echo "$SNAPSHOT_REMOTE_HOST" | sed -e 's|^.*://||' -e 's|^.*@||' -e 's|:.*$||' -e 's|/.*$||' -e 's|[^a-zA-Z0-9._-]|_|g')
    if [ -f "$OWNER_HOME/.ssh/snapshot-${THIS_VPS}-${CLEAN_TGT}" ]; then
      SNAPSHOT_REMOTE_KEY="$OWNER_HOME/.ssh/snapshot-${THIS_VPS}-${CLEAN_TGT}"
    elif [ -f "$OWNER_HOME/.ssh/id_ed25519-snapshot-$SERVICE_NAME" ]; then
      SNAPSHOT_REMOTE_KEY="$OWNER_HOME/.ssh/id_ed25519-snapshot-$SERVICE_NAME"
    elif [ -f "$OWNER_HOME/.ssh/id_ed25519_snapshot" ]; then
      SNAPSHOT_REMOTE_KEY="$OWNER_HOME/.ssh/id_ed25519_snapshot"
    fi
  elif [ -n "$SNAPSHOT_REMOTE_KEY" ] && [ -n "$OWNER_HOME" ]; then
    SNAPSHOT_REMOTE_KEY="${SNAPSHOT_REMOTE_KEY/#\~/$OWNER_HOME}"
  fi

  SSH_OPTS=(-p "$SNAPSHOT_REMOTE_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=5)
  [ -n "$SNAPSHOT_REMOTE_KEY" ] && [ -f "$SNAPSHOT_REMOTE_KEY" ] && SSH_OPTS+=(-i "$SNAPSHOT_REMOTE_KEY")
  REMOTE_SSH_OPTS=("${SSH_OPTS[@]}")
  RSYNC_SSH="ssh"
  for _opt in "${SSH_OPTS[@]}"; do
    RSYNC_SSH+=" $(printf '%q' "$_opt")"
  done

  dl_remote_exec() {
    ssh "${SSH_OPTS[@]}" "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST" "$@"
  }

  log_msg "INFO" "Connecting to Secondary VPS ($SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST:$SNAPSHOT_REMOTE_PORT)..."
  if ! dl_remote_exec "true" 2>/dev/null; then
    json_error "Failed to establish SSH connection with Secondary VPS ($SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST:$SNAPSHOT_REMOTE_PORT)."
  fi

  if declare -F queue_lock_acquire_remote >/dev/null 2>&1; then
    if ! queue_lock_acquire_remote "$SNAPSHOT_QUEUE_NAME" "$SERVICE_NAME" \
        "$SERVICE_NAME (download-backupdata from $(hostname -s 2>/dev/null || hostname))" "$SNAPSHOT_QUEUE_TIMEOUT" dl_remote_exec; then
      json_error "Timed out waiting for remote '$SNAPSHOT_QUEUE_NAME' queue on Secondary VPS."
    fi
  fi

  REMOTE_ZIP_CMD=$(dl_remote_exec "command -v 7z 2>/dev/null || command -v 7za 2>/dev/null || true" | tr -d '\r\n')
  [ -z "$REMOTE_ZIP_CMD" ] && json_error "7z/7za is not installed on Secondary VPS ($SNAPSHOT_REMOTE_HOST)."

  REMOTE_HOME=$(dl_remote_exec 'echo "$HOME"' 2>/dev/null | tr -d '\r\n' || true)
  [ -z "$REMOTE_HOME" ] && json_error "Could not determine HOME directory on Secondary VPS."

  REMOTE_BASE="$REMOTE_HOME/.odoo-snapshots/$SERVICE_NAME"
  REMOTE_MIRROR="$REMOTE_BASE/mirror/filestore"
  REMOTE_DL_DIR="$REMOTE_BASE/dl_${TIMESTAMP}_$$"
  REMOTE_PAYLOAD_DIR="$REMOTE_DL_DIR/payload"
  REMOTE_ZIP_PATH="$REMOTE_DL_DIR/$ZIP_NAME"

  REMOTE_CLEANUP_TARGET="$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST"
  REMOTE_CLEANUP_PATH="$REMOTE_DL_DIR"

  dl_remote_exec "mkdir -p $(printf '%q' "$REMOTE_MIRROR") $(printf '%q' "$REMOTE_PAYLOAD_DIR") && chmod 700 $(printf '%q' "$REMOTE_HOME/.odoo-snapshots")"

  log_msg "INFO" "Streaming PostgreSQL dump of '$TARGET_DB' directly to Secondary VPS..."
  if ! run_pg_dump --no-owner "$TARGET_DB" | dl_remote_exec "cat > $(printf '%q' "$REMOTE_PAYLOAD_DIR/dump.sql")"; then
    json_error "pg_dump stream to Secondary VPS failed for database '$TARGET_DB'."
  fi

  if [ "$NEUTRALIZE" = true ]; then
    log_msg "INFO" "Appending database neutralization SQL on Secondary VPS..."
    emit_neutralization_sql | dl_remote_exec "cat >> $(printf '%q' "$REMOTE_PAYLOAD_DIR/dump.sql")"
  fi

  log_msg "INFO" "Writing manifest.json on Secondary VPS..."
  generate_manifest "$TARGET_DB" | dl_remote_exec "cat > $(printf '%q' "$REMOTE_PAYLOAD_DIR/manifest.json")"

  if [ "$NO_FILESTORE" = true ]; then
    log_msg "INFO" "Skipping filestore (--no-filestore)."
  elif [ -d "$FILESTORE_SRC" ]; then
    EXCLUDE_LIST=""
    if [ "$EXCLUDE_CHATTER" = true ] || [ "$EXCLUDE_ASSETS" = true ]; then
      EXCLUDE_LIST="$TEMP_WORK_DIR/exclude_store_fnames.txt"
      generate_attachment_exclusions "$TARGET_DB" "$EXCLUDE_LIST" "$EXCLUDE_CHATTER" "$EXCLUDE_ASSETS"
    fi

    if [ -z "$ENV_DB_NAME" ] || [ "$TARGET_DB" = "$ENV_DB_NAME" ]; then
      log_msg "INFO" "Syncing filestore incrementally to Secondary VPS snapshot mirror ($REMOTE_MIRROR)..."
      rsync -e "$RSYNC_SSH" -az --delete "$FILESTORE_SRC/" "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST:$REMOTE_MIRROR/"
      if [ -n "$EXCLUDE_LIST" ] && [ -s "$EXCLUDE_LIST" ]; then
        log_msg "INFO" "Building lightweight filestore on Secondary VPS via hardlinks (preserving snapshot mirror)..."
        rsync -e "$RSYNC_SSH" -az "$EXCLUDE_LIST" "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST:$REMOTE_DL_DIR/exclude_store_fnames.txt"
        dl_remote_exec "mkdir -p $(printf '%q' "$REMOTE_PAYLOAD_DIR/filestore") && rsync -a --link-dest=$(printf '%q' "$REMOTE_MIRROR/") --exclude-from=$(printf '%q' "$REMOTE_DL_DIR/exclude_store_fnames.txt") $(printf '%q' "$REMOTE_MIRROR/") $(printf '%q' "$REMOTE_PAYLOAD_DIR/filestore/")"
      else
        log_msg "INFO" "Linking filestore from Secondary VPS snapshot mirror..."
        dl_remote_exec "cp -al $(printf '%q' "$REMOTE_MIRROR") $(printf '%q' "$REMOTE_PAYLOAD_DIR/filestore") 2>/dev/null || cp -r $(printf '%q' "$REMOTE_MIRROR") $(printf '%q' "$REMOTE_PAYLOAD_DIR/filestore")"
      fi
    else
      log_msg "INFO" "Syncing non-active DB '$TARGET_DB' filestore to Secondary VPS staging (leaving snapshot mirror untouched)..."
      if [ -n "$EXCLUDE_LIST" ] && [ -s "$EXCLUDE_LIST" ]; then
        rsync -e "$RSYNC_SSH" -az --exclude-from="$EXCLUDE_LIST" "$FILESTORE_SRC/" "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST:$REMOTE_PAYLOAD_DIR/filestore/"
      else
        rsync -e "$RSYNC_SSH" -az "$FILESTORE_SRC/" "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST:$REMOTE_PAYLOAD_DIR/filestore/"
      fi
    fi
  fi

  log_msg "INFO" "Compressing backup archive $ZIP_NAME on Secondary VPS ($SNAPSHOT_REMOTE_HOST)..."
  SIZE_BYTES=$(dl_remote_exec "
    set -e
    if command -v ionice >/dev/null 2>&1; then ionice -c2 -n7 -p \$\$ 2>/dev/null || true; fi
    renice -n 19 -p \$\$ >/dev/null 2>&1 || true
    cd $(printf '%q' "$REMOTE_PAYLOAD_DIR")
    $(printf '%q' "$REMOTE_ZIP_CMD") a -tzip -mmt=on $(printf '%q' "$REMOTE_ZIP_PATH") dump.sql manifest.json >/dev/null
    if [ -d $(printf '%q' "$REMOTE_PAYLOAD_DIR/filestore") ]; then
      $(printf '%q' "$REMOTE_ZIP_CMD") a -tzip -mx=0 $(printf '%q' "$REMOTE_ZIP_PATH") filestore >/dev/null
    fi
    rm -rf $(printf '%q' "$REMOTE_PAYLOAD_DIR")
    stat -c %s $(printf '%q' "$REMOTE_ZIP_PATH")
  " | tr -d '\r\n')

  # Upload from Secondary VPS using only the short-lived Bearer token via stdin
  REMOTE_PY_CODE=$(cat <<'REMOTE_PY'
import json, os, sys, urllib.error, urllib.request
file_path, file_name, folder_id, share_email = sys.argv[1:5]
token = sys.stdin.readline().strip()
if not token:
    raise RuntimeError("GDRIVE_ACCESS_TOKEN was not received on stdin")
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
  log_msg "INFO" "Uploading archive to Google Drive from Secondary VPS ($SNAPSHOT_REMOTE_HOST)..."
  UPLOAD_JSON=$(printf '%s\n' "$GDRIVE_ACCESS_TOKEN" | dl_remote_exec \
    "python3 -c $(printf '%q' "$REMOTE_PY_CODE") $(printf '%q' "$REMOTE_ZIP_PATH") $(printf '%q' "$ZIP_NAME") $(printf '%q' "$GDRIVE_FOLDER_ID") $(printf '%q' "$SHARE_EMAIL")")
else
  ZIP_CMD="7z"
  command -v 7z >/dev/null 2>&1 || ZIP_CMD="7za"
  if ! command -v "$ZIP_CMD" >/dev/null 2>&1; then
    json_error "7z/7za is not installed on the server."
  fi

  ZIP_PATH="$TEMP_WORK_DIR/$ZIP_NAME"
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

  if [ "$NO_FILESTORE" = true ]; then
    log_msg "INFO" "Skipping filestore (--no-filestore)."
  elif [ -d "$FILESTORE_SRC" ]; then
    if [ "$EXCLUDE_CHATTER" = true ] || [ "$EXCLUDE_ASSETS" = true ]; then
      EXCLUDE_LIST="$TEMP_WORK_DIR/exclude_store_fnames.txt"
      generate_attachment_exclusions "$TARGET_DB" "$EXCLUDE_LIST" "$EXCLUDE_CHATTER" "$EXCLUDE_ASSETS"
      if [ -s "$EXCLUDE_LIST" ]; then
        log_msg "INFO" "Packaging lightweight filestore from $FILESTORE_SRC (excluding chatter/assets via hardlinks)..."
        mkdir -p "$DB_WORK_DIR/filestore"
        rsync -a --link-dest="$FILESTORE_SRC/" --exclude-from="$EXCLUDE_LIST" "$FILESTORE_SRC/" "$DB_WORK_DIR/filestore/"
      else
        log_msg "INFO" "Packaging filestore from $FILESTORE_SRC..."
        cp -al "$FILESTORE_SRC" "$DB_WORK_DIR/filestore" 2>/dev/null || cp -r "$FILESTORE_SRC" "$DB_WORK_DIR/filestore"
      fi
    else
      log_msg "INFO" "Packaging filestore from $FILESTORE_SRC..."
      cp -al "$FILESTORE_SRC" "$DB_WORK_DIR/filestore" 2>/dev/null || cp -r "$FILESTORE_SRC" "$DB_WORK_DIR/filestore"
    fi
  fi

  log_msg "INFO" "Compressing backup archive $ZIP_NAME..."
  (cd "$DB_WORK_DIR" && "$ZIP_CMD" a -tzip -mmt=on "$ZIP_PATH" dump.sql manifest.json >/dev/null)
  if [ -d "$DB_WORK_DIR/filestore" ]; then
    (cd "$DB_WORK_DIR" && "$ZIP_CMD" a -tzip -mx=0 "$ZIP_PATH" filestore >/dev/null)
  fi
  rm -rf "$DB_WORK_DIR"

  SIZE_BYTES=$(stat -c %s "$ZIP_PATH")
  log_msg "INFO" "Uploading archive to Google Drive..."
  UPLOAD_JSON=$(upload_to_gdrive "$ZIP_PATH" "$ZIP_NAME" "$GDRIVE_FOLDER_ID" "$GDRIVE_ACCESS_TOKEN" "$SHARE_EMAIL")
  rm -f "$ZIP_PATH"
fi

python3 - "$UPLOAD_JSON" "$TARGET_DB" "$ZIP_NAME" "$SIZE_BYTES" "$NEUTRALIZE" "$FILESTORE_MODE" <<'PY'
import json, sys
meta = json.loads(sys.argv[1])
db_name, file_name, size_bytes, neutralized, filestore_mode = sys.argv[2:7]
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
    "filestore_mode": filestore_mode,
}))
PY
