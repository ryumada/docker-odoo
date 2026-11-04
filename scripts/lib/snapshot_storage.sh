#!/usr/bin/env bash
# Category: Library
# Description: Snapshot storage helpers: sha256 sidecar files, Google Drive listing/retention/upload checks, GCS upload checks.
# Usage: source scripts/lib/snapshot_storage.sh
# Dependencies: curl, python3, sha256sum, gcloud (GCS checks only)
#
# Naming (matched exactly; any other file in the Drive folder is never counted or deleted):
#   archive: snapshot-<service>-YYYYMMDD-HHMMSS.tar.zst
#   sidecar: snapshot-<service>-YYYYMMDD-HHMMSS.tar.zst.sha256
#            content in sha256sum format: "<64 hex>  <archive name>"
#
# Retention counts archives only, per service, newest first by the timestamp in the name.
# Deleting an archive also deletes its sidecar (archive first, so a failed delete never
# leaves an archive without its hash). Sidecars whose archive is gone are removed too.
#
# Every gds_* / gcs_* / snap_* function receives what it needs as arguments and only uses
# curl, python3, sha256sum and gcloud, so they can be sent to the Secondary VPS with
# `declare -f $(compgen -A function gds_) ...`.
# GDS_API_BASE can point the Drive calls at another endpoint (used by the tests).

_ss_log() {
  # Always on stderr: several helpers print results on stdout that callers capture.
  local level="$1" msg="$2"
  if declare -f "log_$level" >/dev/null 2>&1; then
    "log_$level" "$msg" >&2
  else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [$level] $msg" >&2
  fi
}

# --- sha256 sidecar helpers ---------------------------------------------------

snap_sha256_of() {
  # Prints the sha256 of a file. Fails (prints nothing) if the file cannot be read.
  local out
  [ -f "$1" ] && [ -r "$1" ] || return 1
  out=$(sha256sum "$1") || return 1
  echo "${out%% *}"
}

snap_sidecar_hash() {
  # Prints the hash stored in a sidecar file (empty if the file is missing or malformed).
  local h
  h=$(awk 'NR==1 {print $1}' "$1" 2>/dev/null)
  [[ "$h" =~ ^[0-9a-f]{64}$ ]] && echo "$h"
}

snap_write_sidecar() {
  # Args: hash sidecar_path archive_name. Writes "<hash>  <archive_name>".
  printf '%s  %s\n' "$1" "$3" > "$2"
}

snap_ensure_sidecar() {
  # Args: archive_path. Creates <archive>.sha256 if it is missing or malformed. Prints the hash.
  local archive="$1" sidecar="$1.sha256" h
  h=$(snap_sidecar_hash "$sidecar")
  if [ -z "$h" ]; then
    h=$(snap_sha256_of "$archive") || return 1
    snap_write_sidecar "$h" "$sidecar" "$(basename "$archive")"
  fi
  echo "$h"
}

snap_check_or_create_sidecar() {
  # Args: archive_path. For archives about to be uploaded by hand or by a retry job:
  #   - sidecar present and valid -> the archive must still match it (catches local damage
  #     and stale sidecars before anything is uploaded)
  #   - sidecar missing/malformed -> create it
  # Returns 0 ready (sidecar matches), 1 archive does NOT match its sidecar.
  local archive="$1" sidecar="$1.sha256" expected actual
  if ! actual=$(snap_sha256_of "$archive"); then
    _ss_log error "Cannot read $archive to check its checksum."
    return 1
  fi
  expected=$(snap_sidecar_hash "$sidecar")
  if [ -z "$expected" ]; then
    snap_write_sidecar "$actual" "$sidecar" "$(basename "$archive")"
    _ss_log info "Created checksum file $(basename "$sidecar") (sha256 $actual)."
    return 0
  fi
  if [ "$expected" != "$actual" ]; then
    _ss_log error "$(basename "$archive") does not match its checksum file (expected $expected, file is $actual). The local snapshot is damaged or the .sha256 belongs to another file."
    return 1
  fi
  _ss_log info "Local snapshot matches its checksum file (sha256 $actual)."
  return 0
}

snap_verify_file() {
  # Args: archive_path [sidecar_path]. Returns 0 match, 1 mismatch, 2 no usable sidecar.
  local archive="$1" sidecar="${2:-$1.sha256}" expected actual
  expected=$(snap_sidecar_hash "$sidecar")
  [ -n "$expected" ] || return 2
  actual=$(snap_sha256_of "$archive") || return 1
  [ "$expected" = "$actual" ]
}

# --- Google Drive ------------------------------------------------------------

gds_api_base() { echo "${GDS_API_BASE:-https://www.googleapis.com}"; }

gds_fetch_files() {
  # Args: token folder_id name_prefix. Prints one JSON array of
  # {id, name, size, createdTime, sha256Checksum} for every non-trashed file whose
  # name starts with the prefix (Drive prefix match; exact filtering happens in gds_plan).
  local token="$1" folder="$2" prefix="$3"
  local base query page_token="" resp tmpdir n=0
  base=$(gds_api_base)
  query="name contains '${prefix}' and trashed = false"
  [ -n "$folder" ] && query="$query and '$folder' in parents"
  tmpdir=$(mktemp -d) || return 1

  while :; do
    local args=(-s -G -H "Authorization: Bearer $token"
      --data-urlencode "q=$query"
      --data-urlencode "fields=nextPageToken, files(id, name, size, createdTime, sha256Checksum)"
      --data-urlencode "supportsAllDrives=true"
      --data-urlencode "includeItemsFromAllDrives=true"
      --data-urlencode "pageSize=1000")
    [ -n "$page_token" ] && args+=(--data-urlencode "pageToken=$page_token")
    if ! resp=$(curl "${args[@]}" "$base/drive/v3/files"); then
      rm -rf "$tmpdir"; echo "Google Drive request failed (curl)" >&2; return 1
    fi
    n=$((n + 1))
    printf '%s' "$resp" > "$tmpdir/page_$n.json"
    if ! page_token=$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write("Unreadable Google Drive response: %s\n" % e); sys.exit(1)
if "error" in d:
    err = d["error"]
    sys.stderr.write("Google Drive API error: %s\n" % (err.get("message") if isinstance(err, dict) else err)); sys.exit(1)
print(d.get("nextPageToken", ""))
' < "$tmpdir/page_$n.json"); then
      rm -rf "$tmpdir"; return 1
    fi
    [ -z "$page_token" ] && break
  done

  python3 -c '
import json, sys, glob
files = []
for p in sorted(glob.glob(sys.argv[1] + "/page_*.json")):
    with open(p) as f:
        files.extend(json.load(f).get("files", []))
print(json.dumps(files))
' "$tmpdir"
  local rc=$?
  rm -rf "$tmpdir"
  return $rc
}

gds_plan() {
  # Args: service ("*" = every service, each kept separately) keep (<=0 = keep all).
  # Reads the JSON array from gds_fetch_files on stdin. Prints TSV lines:
  #   action  kind     id  name  size  createdTime  service  sidecar
  #   keep|delete  archive|sidecar|orphan               (sidecar = yes/no for archives)
  # Order: per service newest archive first; each deleted archive is followed by its
  # sidecar(s); orphan sidecars last. Files that do not match the naming are left out.
  python3 -c '
import json, re, sys
service, keep = sys.argv[1], int(sys.argv[2])
files = json.load(sys.stdin)
arc_re = re.compile(r"^snapshot-(.+)-(\d{8}-\d{6})\.tar\.zst$")
side_re = re.compile(r"^(snapshot-(.+)-(\d{8}-\d{6})\.tar\.zst)\.sha256$")
archives, sidecars = [], {}
for f in files:
    name = f.get("name", "")
    m = arc_re.match(name)
    if m:
        if service in ("*", m.group(1)):
            archives.append((m.group(1), m.group(2), f.get("createdTime", ""), f))
        continue
    m = side_re.match(name)
    if m and service in ("*", m.group(2)):
        sidecars.setdefault(m.group(1), []).append(f)

def row(action, kind, f, svc, extra=""):
    return "\t".join([action, kind, f.get("id", ""), f.get("name", ""), str(f.get("size", "") or ""),
                      f.get("createdTime", ""), svc, extra])

by_service = {}
for a in archives:
    by_service.setdefault(a[0], []).append(a)
archive_names = {a[3].get("name") for a in archives}
for svc in sorted(by_service):
    items = sorted(by_service[svc], key=lambda a: (a[1], a[2]), reverse=True)
    decisions = [("keep" if keep <= 0 or idx < keep else "delete", a[3]) for idx, a in enumerate(items)]
    kept_names = {f.get("name") for action, f in decisions if action == "keep"}
    for action, f in decisions:
        name = f.get("name")
        print(row(action, "archive", f, svc, "yes" if name in sidecars else "no"))
        # Same-name duplicates: only drop the sidecar when no kept archive still uses it
        if action == "delete" and name not in kept_names:
            for s in sidecars.get(name, []):
                print(row("delete", "sidecar", s, svc))
for name, lst in sorted(sidecars.items()):
    if name not in archive_names:
        m = side_re.match(name + ".sha256")
        for s in lst:
            print(row("delete", "orphan", s, m.group(2) if m else ""))
' "$1" "$2"
}

gds_list_archives() {
  # Args: token folder_id service ("*" = all) [limit]. Prints gds_plan-style TSV rows for
  # snapshot archives only (never their .sha256 files), newest first by the name timestamp.
  local token="$1" folder="$2" service="$3" limit="${4:-0}" prefix files
  if [ "$service" = "*" ]; then prefix="snapshot-"; else prefix="snapshot-${service}-"; fi
  files=$(gds_fetch_files "$token" "$folder" "$prefix") || return 1
  printf '%s' "$files" | gds_plan "$service" 0 | awk -F'\t' '$2=="archive"' | python3 -c '
import re, sys
rows = [l.split("\t") for l in sys.stdin.read().splitlines() if l.strip()]
ts = lambda r: re.search(r"-(\d{8}-\d{6})\.tar\.zst$", r[3]).group(1)
rows.sort(key=lambda r: (ts(r), r[5]), reverse=True)
limit = int(sys.argv[1]) if sys.argv[1].isdigit() and int(sys.argv[1]) > 0 else len(rows)
for r in rows[:limit]:
    print("\t".join(r))
' "$limit"
}

gds_delete_file() {
  # Args: token file_id folder_id. Tries delete, then trash, then removing it from the folder.
  local token="$1" fid="$2" folder="$3" base status
  base=$(gds_api_base)
  status=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
    -H "Authorization: Bearer $token" "$base/drive/v3/files/${fid}?supportsAllDrives=true")
  if [ "$status" = "204" ] || [ "$status" = "200" ]; then return 0; fi
  status=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d '{"trashed": true}' \
    "$base/drive/v3/files/${fid}?supportsAllDrives=true")
  [ "$status" = "200" ] && return 0
  if [ -n "$folder" ]; then
    status=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH \
      -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d '{}' \
      "$base/drive/v3/files/${fid}?removeParents=${folder}&supportsAllDrives=true")
    [ "$status" = "200" ] && return 0
  fi
  echo "$status"
  return 1
}

gds_apply_plan() {
  # Args: token folder_id. Reads gds_plan TSV on stdin and deletes the "delete" rows.
  # If an archive cannot be deleted, its sidecar is kept too. Prints a summary line:
  #   "<deleted archives> <deleted sidecars> <failed>"
  local token="$1" folder="$2"
  local action kind fid name size created svc extra status
  local del_a=0 del_s=0 failed=0
  local failed_names=" "
  while IFS=$'\t' read -r action kind fid name size created svc extra; do
    [ "$action" = "delete" ] || continue
    if [ "$kind" = "sidecar" ] && [[ "$failed_names" == *" ${name%.sha256} "* ]]; then
      _ss_log warn "Keeping sidecar $name because its archive could not be deleted."
      continue
    fi
    if status=$(gds_delete_file "$token" "$fid" "$folder"); then
      case "$kind" in
        archive) del_a=$((del_a + 1)); _ss_log info "Deleted old snapshot: $name" ;;
        sidecar) del_s=$((del_s + 1)); _ss_log info "Deleted its checksum file: $name" ;;
        orphan)  del_s=$((del_s + 1)); _ss_log info "Deleted checksum file without snapshot: $name" ;;
      esac
    else
      failed=$((failed + 1))
      [ "$kind" = "archive" ] && failed_names="$failed_names$name "
      _ss_log warn "Failed to delete $name (ID: $fid, HTTP ${status:-?}). The Service Account needs Editor/Content Manager on the Drive folder."
    fi
  done
  echo "$del_a $del_s $failed"
}

gds_retention() {
  # Args: token folder_id service keep. Fetch -> plan -> delete for one service.
  local token="$1" folder="$2" service="$3" keep="$4" files plan summary total kept
  [[ "$keep" =~ ^[0-9]+$ ]] && [ "$keep" -gt 0 ] || return 0
  _ss_log info "Running Google Drive retention for $service (keeping latest $keep snapshot(s), each with its .sha256)..."
  files=$(gds_fetch_files "$token" "$folder" "snapshot-${service}-") || return 1
  plan=$(printf '%s' "$files" | gds_plan "$service" "$keep") || return 1
  total=$(printf '%s\n' "$plan" | awk -F'\t' '$2=="archive"' | grep -c . || true)
  kept=$(printf '%s\n' "$plan" | awk -F'\t' '$1=="keep" && $2=="archive"' | grep -c . || true)
  if ! printf '%s\n' "$plan" | awk -F'\t' '$1=="delete"' | grep -q .; then
    _ss_log info "Google Drive has $total snapshot(s) for $service, within the limit of $keep. Nothing to delete."
    return 0
  fi
  summary=$(printf '%s\n' "$plan" | gds_apply_plan "$token" "$folder")
  read -r d_a d_s d_f <<< "$summary"
  if [ "${d_f:-0}" -eq 0 ]; then
    _ss_log info "Retention done for $service: kept $kept, deleted $d_a snapshot(s) and $d_s checksum file(s)."
  else
    _ss_log warn "Retention for $service finished with $d_f failed deletion(s): deleted $d_a snapshot(s) and $d_s checksum file(s)."
  fi
  return 0
}

gds_find_by_name() {
  # Args: token folder_id exact_name. Prints the id of the newest non-trashed file with that name.
  local token="$1" folder="$2" name="$3" base query esc
  base=$(gds_api_base)
  esc=${name//\\/\\\\}; esc=${esc//\'/\\\'}
  query="name = '$esc' and trashed = false"
  [ -n "$folder" ] && query="$query and '$folder' in parents"
  curl -s -G -H "Authorization: Bearer $token" \
    --data-urlencode "q=$query" --data-urlencode "orderBy=createdTime desc" \
    --data-urlencode "fields=files(id)" --data-urlencode "supportsAllDrives=true" \
    --data-urlencode "includeItemsFromAllDrives=true" --data-urlencode "pageSize=1" \
    "$base/drive/v3/files" | python3 -c '
import json, sys
try:
    f = json.load(sys.stdin).get("files", [])
    print(f[0]["id"] if f else "")
except Exception:
    print("")
'
}

gds_download() {
  # Args: token file_id dest_path. Returns 0 on HTTP 200.
  local base status
  base=$(gds_api_base)
  status=$(curl -s -L -w "%{http_code}" -H "Authorization: Bearer $1" \
    "$base/drive/v3/files/${2}?alt=media&supportsAllDrives=true" -o "$3")
  [ "$status" = "200" ]
}

gds_upload_small() {
  # Args: token folder_id name local_file. Simple multipart upload for small files. Prints the id.
  local token="$1" folder="$2" name="$3" file="$4" base boundary meta resp id
  base=$(gds_api_base)
  boundary="snapshot_sidecar_$$_${RANDOM}${RANDOM}"
  meta="{\"name\": \"$name\""
  [ -n "$folder" ] && meta="$meta, \"parents\": [\"$folder\"]"
  meta="$meta}"
  resp=$( { printf -- '--%s\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n%s\r\n--%s\r\nContent-Type: text/plain\r\n\r\n' \
              "$boundary" "$meta" "$boundary"
            cat "$file"
            printf '\r\n--%s--\r\n' "$boundary"; } | \
          curl -s -X POST -H "Authorization: Bearer $token" \
            -H "Content-Type: multipart/related; boundary=$boundary" --data-binary @- \
            "$base/upload/drive/v3/files?uploadType=multipart&supportsAllDrives=true&fields=id,name" )
  id=$(printf '%s' "$resp" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("id",""))
except Exception: print("")')
  if [ -z "$id" ]; then
    echo "$resp" >&2
    return 1
  fi
  echo "$id"
}

gds_remote_sha256() {
  # Args: token file_id. Prints Drive's sha256Checksum for the file (empty if not available yet).
  local base
  base=$(gds_api_base)
  curl -s -G -H "Authorization: Bearer $1" --data-urlencode "fields=sha256Checksum" \
    --data-urlencode "supportsAllDrives=true" "$base/drive/v3/files/$2" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("sha256Checksum", ""))
except Exception:
    print("")
'
}

gds_publish_sidecar() {
  # Args: token folder_id archive_id archive_name local_sidecar
  # Uploads "<archive_name>.sha256" next to the archive, then checks Drive's own sha256 of
  # the uploaded archive against it.
  # Returns 0 = verified (or Drive has no checksum yet; warned), 1 = MISMATCH (broken upload),
  #         2 = sidecar could not be uploaded (archive is fine but unverifiable).
  local token="$1" folder="$2" archive_id="$3" archive_name="$4" local_sidecar="$5"
  local expected tmp sidecar_id="" attempt remote
  expected=$(snap_sidecar_hash "$local_sidecar")
  if [ -z "$expected" ]; then
    _ss_log warn "No valid local checksum file for $archive_name; skipping .sha256 upload."
    return 2
  fi

  # 1) Ask Drive for its sha256 of the archive (it can take a few seconds to appear)
  remote=""
  for attempt in 1 2 3 4 5 6; do
    remote=$(gds_remote_sha256 "$token" "$archive_id")
    [ -n "$remote" ] && break
    sleep "${GDS_VERIFY_SLEEP:-5}"
  done
  if [ -n "$remote" ] && [ "$remote" != "$expected" ]; then
    _ss_log error "CHECKSUM MISMATCH for $archive_name on Google Drive: expected $expected, Drive has $remote. The uploaded copy is broken."
    return 1
  fi
  if [ -z "$remote" ]; then
    _ss_log warn "Google Drive did not report a sha256 for $archive_name yet; the upload could not be cross-checked."
  else
    _ss_log success "Google Drive sha256 matches the local snapshot ($archive_name)."
  fi

  # 2) Upload the sidecar with the archive's remote name inside it
  tmp=$(mktemp) || return 2
  snap_write_sidecar "$expected" "$tmp" "$archive_name"
  for attempt in 1 2 3; do
    if sidecar_id=$(gds_upload_small "$token" "$folder" "$archive_name.sha256" "$tmp" 2>/dev/null); then
      break
    fi
    sidecar_id=""
    sleep "${GDS_VERIFY_SLEEP:-5}"
  done
  rm -f "$tmp"
  if [ -z "$sidecar_id" ]; then
    _ss_log error "Could not upload $archive_name.sha256 to Google Drive after 3 attempts. The snapshot is uploaded but has no checksum file."
    return 2
  fi
  _ss_log success "Uploaded checksum file $archive_name.sha256 (ID: $sidecar_id)."
  return 0
}

# --- Google Cloud Storage ------------------------------------------------------

gcs_crc32c_field() {
  # Reads gcloud YAML output on stdin and prints the crc32c_hash value.
  awk -F': *' '/crc32c_hash:/ {gsub(/["'\'' ]/, "", $2); print $2; exit}'
}

gcs_verify_upload() {
  # Args: local_file gs_url. Uses ${GCS_GCLOUD:-gcloud} (e.g. "sudo -u owner gcloud").
  # Compares the object's crc32c (always present, also for composite uploads) with the
  # local file. Returns 0 match, 1 mismatch, 2 could not check.
  local file="$1" url="$2" gc="${GCS_GCLOUD:-gcloud}" local_crc remote_crc
  # shellcheck disable=SC2086
  remote_crc=$($gc storage objects describe "$url" 2>/dev/null | gcs_crc32c_field)
  # shellcheck disable=SC2086
  local_crc=$($gc storage hash --skip-md5 "$file" 2>/dev/null | gcs_crc32c_field)
  if [ -z "$remote_crc" ] || [ -z "$local_crc" ]; then
    _ss_log warn "Could not compare crc32c for $url (gcloud storage hash/describe unavailable). Relying on gcloud's own upload validation."
    return 2
  fi
  if [ "$remote_crc" != "$local_crc" ]; then
    _ss_log error "CHECKSUM MISMATCH for $url: local crc32c $local_crc, GCS has $remote_crc. The uploaded copy is broken."
    return 1
  fi
  _ss_log success "GCS crc32c matches the local snapshot ($url)."
  return 0
}
