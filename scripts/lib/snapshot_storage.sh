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
#   validation record: snapshot-<service>-YYYYMMDD-HHMMSS.tar.zst.validated.json
#            written by the snapshot validator ONLY after a restore drill passed:
#            {"schema": 1, "result": "pass", "archive": "<name>", "sha256": "<hex>",
#             "validated_at": "<UTC ISO>", "validator_host": "...", ...extra fields}
#
# Retention counts archives only, per service, newest first by the timestamp in the name.
# On top of the newest N it also keeps the newest snapshot with a trusted validation record
# (result "pass" and sha256 equal to Drive's own sha256 of the archive), so a proven
# backup is never rotated out before a newer one is proven.
# Deleting an archive also deletes its .sha256 and .validated.json (archive first, so a
# failed delete never leaves an archive without them). Leftovers whose archive is gone
# are removed too.
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

snap_write_validation_record() {
  # Args: out_file archive_name sha256 [extra_json_object]
  # Writes a "pass" validation record. Only call this after a restore drill PASSED.
  python3 -c '
import json, socket, sys, datetime
out, name, sha = sys.argv[1], sys.argv[2], sys.argv[3]
extra = json.loads(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else {}
rec = {"schema": 1, "result": "pass", "archive": name, "sha256": sha,
       "validated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
       "validator_host": socket.gethostname()}
rec.update({k: v for k, v in extra.items() if k not in ("schema", "result", "archive", "sha256")})
with open(out, "w") as f:
    json.dump(rec, f, indent=2); f.write("\n")
' "$@"
}

snap_validation_record_ok() {
  # Args: record_file archive_name expected_sha256 (expected may be empty = not checked)
  # Returns 0 when the record says "pass" for this archive (and this sha256).
  python3 -c '
import json, sys
try:
    r = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
name, sha = sys.argv[2], sys.argv[3]
ok = r.get("result") == "pass" and r.get("archive") in (None, name) and (not sha or r.get("sha256") == sha)
sys.exit(0 if ok else 1)
' "$1" "$2" "$3"
}

# --- Google Drive ------------------------------------------------------------

gds_api_base() { echo "${GDS_API_BASE:-https://www.googleapis.com}"; }

gds_curl() {
  # Args: token curl-args... Runs curl with the bearer token read from a private (0600) header
  # file, so the token never appears on a command line where other users could see it in ps.
  local token="$1" hf rc
  shift
  hf=$(umask 077; mktemp) || return 1
  printf 'Authorization: Bearer %s\n' "$token" > "$hf"
  curl -H @"$hf" "$@"
  rc=$?
  rm -f "$hf"
  return $rc
}

gds_token_from_sa() {
  # Args: service account key (file path or JSON content). Prints a Drive access token.
  local sa_input="$1" sa_json_content=""
  if [ -f "$sa_input" ]; then
    sa_json_content=$(cat "$sa_input")
  elif [[ "$(printf '%s' "$sa_input" | tr -d '[:space:]' | head -c 1)" == "{" ]]; then
    sa_json_content="$sa_input"
  else
    # Never print the value: it may be a private key
    _ss_log error "Service Account key not found: GDRIVE_SERVICE_ACCOUNT_KEY is neither a readable file nor JSON content."
    return 1
  fi
  local client_email token_uri key_pem
  client_email=$(echo "$sa_json_content" | grep -o '"client_email": *"[^"]*"' | cut -d'"' -f4)
  token_uri=$(echo "$sa_json_content" | grep -o '"token_uri": *"[^"]*"' | cut -d'"' -f4)
  [ -z "$token_uri" ] && token_uri="https://oauth2.googleapis.com/token"
  key_pem=$(echo "$sa_json_content" | grep -o '"private_key": *"[^"]*"' | sed 's/^"private_key": *"//;s/"$//')
  if [ -z "$client_email" ] || [ -z "$key_pem" ]; then
    _ss_log error "Could not parse client_email or private_key from Service Account JSON."
    return 1
  fi
  local b64url_cmd='openssl base64 -e -A | tr "+/" "-_" | tr -d "="'
  local now exp header_b64 claims claims_b64 unsigned_jwt sig_b64
  now=$(date +%s); exp=$((now + 3600))
  header_b64=$(echo -n '{"alg":"RS256","typ":"JWT"}' | eval "$b64url_cmd")
  claims="{\"iss\":\"$client_email\",\"scope\":\"https://www.googleapis.com/auth/drive\",\"aud\":\"$token_uri\",\"exp\":$exp,\"iat\":$now}"
  claims_b64=$(echo -n "$claims" | eval "$b64url_cmd")
  unsigned_jwt="${header_b64}.${claims_b64}"
  sig_b64=$(printf "%s" "$unsigned_jwt" | openssl dgst -sha256 -sign <(printf '%b' "$key_pem") -binary 2>/dev/null | eval "$b64url_cmd")
  if [ -z "$sig_b64" ]; then
    _ss_log error "Failed to sign Service Account JWT with openssl."
    return 1
  fi
  # The signed assertion goes through a private file, not the command line
  local af
  af=$(umask 077; mktemp) || return 1
  printf '%s' "${unsigned_jwt}.${sig_b64}" > "$af"
  curl -s -X POST -d "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
    --data-urlencode "assertion@$af" "$token_uri" \
    | grep -o '"access_token": *"[^"]*"' | cut -d'"' -f4
  rm -f "$af"
}

gds_get_token() {
  # Args: raw_token (string or file) sa_key (file or JSON). Prints an access token;
  # the service account is preferred because its tokens can always be renewed.
  local raw="$1" sa="$2"
  if [ -n "$sa" ]; then
    gds_token_from_sa "$sa"
  elif [ -n "$raw" ] && [ -f "$raw" ]; then
    if grep -q '"type": *"service_account"' "$raw" 2>/dev/null; then gds_token_from_sa "$raw"; else tr -d '\r\n' < "$raw"; echo; fi
  else
    echo "$raw"
  fi
}

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
    local args=(-s -G
      --data-urlencode "q=$query"
      --data-urlencode "fields=nextPageToken, files(id, name, size, createdTime, sha256Checksum)"
      --data-urlencode "supportsAllDrives=true"
      --data-urlencode "includeItemsFromAllDrives=true"
      --data-urlencode "pageSize=1000")
    [ -n "$page_token" ] && args+=(--data-urlencode "pageToken=$page_token")
    if ! resp=$(gds_curl "$token" "${args[@]}" "$base/drive/v3/files"); then
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
  # Args: service ("*" = every service, each kept separately) keep (<=0 = keep all)
  #       [protected names, newline separated: archives kept even beyond <keep>]
  # Reads the JSON array from gds_fetch_files on stdin. Prints TSV lines:
  #   action  kind  id  name  size  createdTime  service  sidecar  validated
  #   action    = keep | delete
  #   kind      = archive | sidecar | validation | orphan (leftover whose archive is gone)
  #   sidecar   = yes | no             (archive rows only)
  #   validated = yes | protected | no (archive rows only; protected = kept because it is
  #               the newest snapshot that passed a restore drill)
  # Order: per service newest archive first; each deleted archive is followed by its
  # .sha256 / .validated.json; leftovers last. Files that do not match the naming are left out.
  python3 -c '
import json, re, sys
service, keep = sys.argv[1], int(sys.argv[2])
protected = set(n for n in (sys.argv[3] if len(sys.argv) > 3 else "").splitlines() if n)
files = json.load(sys.stdin)
arc_re = re.compile(r"^snapshot-(.+)-(\d{8}-\d{6})\.tar\.zst$")
side_re = re.compile(r"^(snapshot-(.+)-(\d{8}-\d{6})\.tar\.zst)\.sha256$")
val_re = re.compile(r"^(snapshot-(.+)-(\d{8}-\d{6})\.tar\.zst)\.validated\.json$")
archives, sidecars, records = [], {}, {}
for f in files:
    name = f.get("name", "")
    m = arc_re.match(name)
    if m:
        if service in ("*", m.group(1)):
            archives.append((m.group(1), m.group(2), f.get("createdTime", ""), f))
        continue
    for rx, bucket in ((side_re, sidecars), (val_re, records)):
        m = rx.match(name)
        if m:
            if service in ("*", m.group(2)):
                bucket.setdefault(m.group(1), []).append(f)
            break

def row(action, kind, f, svc, *extra):
    return "\t".join([action, kind, f.get("id", ""), f.get("name", ""), str(f.get("size", "") or ""),
                      f.get("createdTime", ""), svc] + list(extra))

by_service = {}
for a in archives:
    by_service.setdefault(a[0], []).append(a)
archive_names = {a[3].get("name") for a in archives}
for svc in sorted(by_service):
    items = sorted(by_service[svc], key=lambda a: (a[1], a[2]), reverse=True)
    decisions = []
    for idx, a in enumerate(items):
        name = a[3].get("name")
        if keep <= 0 or idx < keep:
            decisions.append(("keep", a[3], "yes" if name in records else "no"))
        elif name in protected:
            decisions.append(("keep", a[3], "protected"))
        else:
            decisions.append(("delete", a[3], "yes" if name in records else "no"))
    kept_names = {f.get("name") for action, f, _v in decisions if action == "keep"}
    for action, f, validated in decisions:
        name = f.get("name")
        print(row(action, "archive", f, svc, "yes" if name in sidecars else "no", validated))
        # Same-name duplicates: only drop the extra files when no kept archive still uses them
        if action == "delete" and name not in kept_names:
            for s in sidecars.get(name, []):
                print(row("delete", "sidecar", s, svc))
            for r in records.get(name, []):
                print(row("delete", "validation", r, svc))
for bucket, rx in ((sidecars, side_re), (records, val_re)):
    for name, lst in sorted(bucket.items()):
        if name not in archive_names:
            for x in lst:
                m = rx.match(x.get("name", ""))
                print(row("delete", "orphan", x, m.group(2) if m else ""))
' "$1" "$2" "${3:-}"
}

gds_find_protected() {
  # Args: token service ("*" allowed) keep. Reads the gds_fetch_files JSON on stdin.
  # For each service, finds the newest snapshot with a trusted validation record
  # (result "pass", same archive name, sha256 equal to Drive's sha256Checksum of the
  # archive). Prints its name only when it would otherwise fall outside the newest <keep>.
  local token="$1" service="$2" keep="$3" candidates svc idx name rec_id sha tmp done_svcs=" "
  [[ "$keep" =~ ^[0-9]+$ ]] && [ "$keep" -gt 0 ] || return 0
  candidates=$(python3 -c '
import json, re, sys
service = sys.argv[1]
files = json.load(sys.stdin)
arc_re = re.compile(r"^snapshot-(.+)-(\d{8}-\d{6})\.tar\.zst$")
records = {f["name"][:-len(".validated.json")]: f for f in files if f.get("name", "").endswith(".tar.zst.validated.json")}
by = {}
for f in files:
    m = arc_re.match(f.get("name", ""))
    if m and service in ("*", m.group(1)):
        by.setdefault(m.group(1), []).append((m.group(2), f.get("createdTime", ""), f))
for svc in sorted(by):
    items = sorted(by[svc], key=lambda a: (a[0], a[1]), reverse=True)
    for idx, (_ts, _ct, f) in enumerate(items):
        r = records.get(f["name"])
        if r:
            print("\t".join([svc, str(idx), f["name"], r["id"], f.get("sha256Checksum", "")]))
' "$service")
  [ -n "$candidates" ] || return 0
  tmp=$(mktemp) || return 0
  while IFS=$'\t' read -r svc idx name rec_id sha; do
    [[ "$done_svcs" == *" $svc "* ]] && continue
    if gds_download "$token" "$rec_id" "$tmp" && snap_validation_record_ok "$tmp" "$name" "$sha"; then
      done_svcs="$done_svcs$svc "
      [ "$idx" -ge "$keep" ] && echo "$name"
    else
      _ss_log warn "Ignoring $name.validated.json: it does not prove this exact snapshot passed a restore drill."
    fi
  done <<< "$candidates"
  rm -f "$tmp"
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
  status=$(gds_curl "$token" -s -o /dev/null -w "%{http_code}" -X DELETE \
    "$base/drive/v3/files/${fid}?supportsAllDrives=true")
  if [ "$status" = "204" ] || [ "$status" = "200" ]; then return 0; fi
  status=$(gds_curl "$token" -s -o /dev/null -w "%{http_code}" -X PATCH \
    -H "Content-Type: application/json" -d '{"trashed": true}' \
    "$base/drive/v3/files/${fid}?supportsAllDrives=true")
  [ "$status" = "200" ] && return 0
  if [ -n "$folder" ]; then
    status=$(gds_curl "$token" -s -o /dev/null -w "%{http_code}" -X PATCH \
      -H "Content-Type: application/json" -d '{}' \
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
    if [ "$kind" = "sidecar" ] || [ "$kind" = "validation" ]; then
      local base_name="${name%.sha256}"
      base_name="${base_name%.validated.json}"
      if [[ "$failed_names" == *" $base_name "* ]]; then
        _ss_log warn "Keeping $name because its snapshot could not be deleted."
        continue
      fi
    fi
    if status=$(gds_delete_file "$token" "$fid" "$folder"); then
      case "$kind" in
        archive) del_a=$((del_a + 1)); _ss_log info "Deleted old snapshot: $name" ;;
        sidecar)    del_s=$((del_s + 1)); _ss_log info "Deleted its checksum file: $name" ;;
        validation) del_s=$((del_s + 1)); _ss_log info "Deleted its validation record: $name" ;;
        orphan)     del_s=$((del_s + 1)); _ss_log info "Deleted leftover file whose snapshot is gone: $name" ;;
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
  # Args: token folder_id service keep. Fetch -> find protected -> plan -> delete, for one service.
  local token="$1" folder="$2" service="$3" keep="$4" files plan summary total kept protected
  [[ "$keep" =~ ^[0-9]+$ ]] && [ "$keep" -gt 0 ] || return 0
  _ss_log info "Running Google Drive retention for $service (keeping latest $keep snapshot(s), each with its .sha256)..."
  files=$(gds_fetch_files "$token" "$folder" "snapshot-${service}-") || return 1
  protected=$(printf '%s' "$files" | gds_find_protected "$token" "$service" "$keep")
  if [ -n "$protected" ]; then
    _ss_log info "Also keeping $protected: it is the newest snapshot that passed a restore drill."
  fi
  plan=$(printf '%s' "$files" | gds_plan "$service" "$keep" "$protected") || return 1
  total=$(printf '%s\n' "$plan" | awk -F'\t' '$2=="archive"' | grep -c . || true)
  kept=$(printf '%s\n' "$plan" | awk -F'\t' '$1=="keep" && $2=="archive"' | grep -c . || true)
  if ! printf '%s\n' "$plan" | awk -F'\t' '$1=="delete"' | grep -q .; then
    _ss_log info "Google Drive has $total snapshot(s) for $service, within the limit of $keep. Nothing to delete."
    return 0
  fi
  summary=$(printf '%s\n' "$plan" | gds_apply_plan "$token" "$folder")
  read -r d_a d_s d_f <<< "$summary"
  if [ "${d_f:-0}" -eq 0 ]; then
    _ss_log info "Retention done for $service: kept $kept, deleted $d_a snapshot(s) and $d_s related file(s)."
  else
    _ss_log warn "Retention for $service finished with $d_f failed deletion(s): deleted $d_a snapshot(s) and $d_s related file(s)."
  fi
  return 0
}

gds_publish_validation() {
  # Args: token folder_id archive_name record_file
  # Uploads <archive_name>.validated.json, replacing an older record with the same name.
  local token="$1" folder="$2" name="$3" file="$4" old id
  while old=$(gds_find_by_name "$token" "$folder" "$name.validated.json") && [ -n "$old" ]; do
    gds_delete_file "$token" "$old" "$folder" >/dev/null || break
  done
  if ! id=$(gds_upload_small "$token" "$folder" "$name.validated.json" "$file" 2>/dev/null); then
    _ss_log error "Could not upload $name.validated.json to Google Drive."
    return 1
  fi
  _ss_log success "Recorded on Google Drive that $name passed a restore drill ($name.validated.json)."
  echo "$id"
}

gds_find_by_name() {
  # Args: token folder_id exact_name. Prints the id of the newest non-trashed file with that name.
  local token="$1" folder="$2" name="$3" base query esc
  base=$(gds_api_base)
  esc=${name//\\/\\\\}; esc=${esc//\'/\\\'}
  query="name = '$esc' and trashed = false"
  [ -n "$folder" ] && query="$query and '$folder' in parents"
  gds_curl "$token" -s -G \
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
  status=$(gds_curl "$1" -s -L -w "%{http_code}" \
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
          gds_curl "$token" -s -X POST \
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
  gds_curl "$1" -s -G --data-urlencode "fields=sha256Checksum" \
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

gcs_publish_validation() {
  # Args: gs_archive_url record_file. Uploads <archive>.validated.json next to the object.
  local gc="${GCS_GCLOUD:-gcloud}"
  # shellcheck disable=SC2086
  if $gc storage cp "$2" "$1.validated.json" >/dev/null 2>&1; then
    _ss_log success "Recorded that $1 passed a restore drill ($1.validated.json)."
    return 0
  fi
  _ss_log error "Could not upload $1.validated.json."
  return 1
}

gcs_invalidate_validation() {
  # Args: gs_archive_url. The GCS snapshot object is overwritten on every run, so a
  # validation record from the previous object must go as soon as a new one is uploaded.
  local gc="${GCS_GCLOUD:-gcloud}"
  # shellcheck disable=SC2086
  if $gc storage ls "$1.validated.json" >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    $gc storage rm "$1.validated.json" >/dev/null 2>&1 \
      && _ss_log info "Removed the previous snapshot's validation record ($1.validated.json)." \
      || _ss_log warn "Could not remove the old $1.validated.json; it no longer matches the new snapshot."
  fi
  return 0
}

# --- Validator inbox (Secondary VPS) -------------------------------------------
# A remote snapshot can be handed to the snapshot validator instead of being deleted, so the
# drill restores the archive already on the Secondary VPS instead of downloading it again.
#   <inbox>/<service>/<archive name>/            one pending job; the folder appears complete,
#     <archive name>                             by rename from .incoming-*, never half-written
#     <archive name>.sha256
#     job.json                                   what the drill needs to record its result next
#                                                to the uploaded copy (Drive name and id, GCS object)
# Only the newest job per service stays pending. A worker takes a job by renaming its folder
# out of the inbox; a job already taken is never touched here. Folders starting with "." are
# not jobs.

snap_inbox_handoff() {
  # Args: archive mode(move|link) inbox_root service reserve_gb source_host drive_result_file gcs_object kept_copy
  #       [snapshots_root]
  #   archive            the archive on this host (its .sha256 next to it)
  #   mode               move: the archive leaves its place (only used when it would be deleted
  #                      otherwise, so a failed hand-off loses nothing that was going to be kept);
  #                      link: a hard link (the archive is also kept where it is); never a copy
  #   reserve_gb         free space that must remain on the inbox's disk afterwards, or no hand-off
  #                      (raised to what the next snapshot needs there, from snapshots_root/*/stats.json)
  #   drive_result_file  "<name>\t<file id>" written by upload_to_gdrive (empty: not on Drive)
  #   gcs_object         gs://bucket/object the archive was uploaded to (empty: not on GCS)
  #   kept_copy          path of the copy kept on this host besides the inbox (empty: none)
  # Returns 0 when handed off, 2 when skipped (disk below the reserve, nothing changed), 1 on error.
  local archive="$1" mode="$2" inbox="$3" service="$4" reserve_gb="${5:-5}" source_host="$6"
  local drive_result="$7" gcs_object="$8" kept="$9" stats_root="${10:-}"
  local dir="$inbox/$service" name="" drive_name="" drive_id="" hash free need why incoming target old trash generation=""
  [ -f "$archive" ] || { _ss_log error "Validator inbox: $archive not found."; return 1; }
  [[ "$reserve_gb" =~ ^[0-9]+$ ]] || reserve_gb=5
  mkdir -p "$dir" && chmod 700 "$inbox" "$dir" 2>/dev/null || { _ss_log error "Validator inbox: cannot create $dir."; return 1; }

  # Moving frees nothing and linking takes no space, but either keeps the archive on this disk
  free=$(df -PB1 "$dir" 2>/dev/null | awk 'NR == 2 {print $4}')
  need=$(snap_disk_reserve_bytes "$reserve_gb" "$stats_root" "$dir")
  why=${need#* }; need=${need%% *}
  case "$why" in
    stats:*) why="what the next snapshot of ${why#stats:} needs there, from its stats.json" ;;
    *) why="VALIDATOR_DISK_RESERVE_GB=${reserve_gb}" ;;
  esac
  if ! [[ "$free" =~ ^[0-9]+$ ]] || [ "$free" -lt "$need" ]; then
    _ss_log warn "Validator inbox: only ${free:-unknown} bytes free on $dir (reserve $need bytes: $why); this snapshot is not kept for a drill."
    return 2
  fi

  if [ -n "$drive_result" ] && [ -s "$drive_result" ]; then
    IFS=$'\t' read -r drive_name drive_id < "$drive_result" || true
  fi
  if [[ "$drive_name" =~ ^snapshot-.+-[0-9]{8}-[0-9]{6}\.tar\.zst$ ]]; then
    name="$drive_name"
  else
    name="snapshot-$service-$(date -u +%Y%m%d-%H%M%S).tar.zst"
  fi
  hash=$(snap_sidecar_hash "$archive.sha256")
  [ -n "$hash" ] || hash=$(snap_sha256_of "$archive") || { _ss_log error "Validator inbox: cannot read $archive."; return 1; }
  if [ -n "$gcs_object" ] && command -v gcloud >/dev/null 2>&1; then
    generation=$(gcloud storage objects describe "$gcs_object" --format='value(generation)' 2>/dev/null | head -n 1 || true)
  fi

  incoming="$dir/.incoming-$name-$$"
  rm -rf "$incoming"; mkdir -p "$incoming" || return 1
  if [ "$mode" = move ]; then
    mv "$archive" "$incoming/$name" || { rm -rf "$incoming"; _ss_log error "Validator inbox: could not move $archive."; return 1; }
  elif ! ln "$archive" "$incoming/$name" 2>/dev/null; then
    rm -rf "$incoming"
    _ss_log warn "Validator inbox: $archive cannot be hard-linked into $dir (another disk); not copying it, so this snapshot is not kept for a drill."
    return 2
  fi
  snap_write_sidecar "$hash" "$incoming/$name.sha256" "$name"
  [ "$mode" = move ] && rm -f "$archive.sha256"
  python3 - "$incoming/job.json" "$service" "$name" "$hash" "$source_host" "$drive_name" "$drive_id" "$gcs_object" "$generation" "$kept" <<'PY' || { rm -rf "$incoming"; _ss_log error "Validator inbox: could not write job.json."; return 1; }
import datetime, json, sys
out, service, name, sha, host, drive_name, drive_id, gcs, generation, kept = sys.argv[1:11]
json.dump({
    "schema": 1,
    "service": service,
    "archive": name,
    "sha256": sha,
    "handed_off_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "source_host": host or None,
    "drive": {"name": drive_name, "file_id": drive_id} if drive_id else None,
    "gcs": {"object": gcs, "generation": generation or None} if gcs else None,
    "kept_copy": kept or None,
}, open(out, "w"), indent=2)
PY

  # Older pending jobs of this service go; a job a worker already took is no longer here
  for old in "$dir"/*/; do
    old="${old%/}"
    [ -d "$old" ] || continue
    trash="$dir/.removing-$(basename "$old")-$$"
    if mv "$old" "$trash" 2>/dev/null; then
      rm -rf "$trash"
      _ss_log info "Validator inbox: replaced the older pending snapshot $(basename "$old")."
    fi
  done
  target="$dir/$name"
  if ! mv "$incoming" "$target"; then
    rm -rf "$incoming"; _ss_log error "Validator inbox: could not publish $target."; return 1
  fi
  _ss_log success "Validator inbox: $name is waiting for a drill in $target."
  return 0
}

# --- Snapshot disk statistics (Secondary VPS) ----------------------------------
# After each remote snapshot, the snapshot tool writes <snapshots root>/<service>/stats.json on the
# Secondary VPS (~/.odoo-snapshots/<service>/stats.json):
#   {"schema": 1, "service", "updated_at" (UTC), "source_host",
#    "dump_bytes", "archive_bytes",
#    "peak_bytes"   free space the snapshot took on that disk at its peak (staged dump, new filestore
#                   files, bundled folders and the archive), or null when it could not be measured,
#    "need_bytes"   the larger of peak_bytes and dump_bytes + archive_bytes}
# The validator and the inbox hand-off keep need_bytes (+25%) free on that disk when it is more than
# VALIDATOR_DISK_RESERVE_GB, so a drill never takes the room the next snapshot needs. Only files
# updated in the last SNAP_STATS_MAX_AGE_DAYS days count (a deployment that stopped sending
# snapshots stops reserving disk).
SNAP_STATS_MAX_AGE_DAYS="${SNAP_STATS_MAX_AGE_DAYS:-30}"

snap_write_stats() {
  # Args: file service source_host dump_bytes archive_bytes free_before free_at_peak
  local file="$1" service="$2" host="$3" dump="$4" archive="$5" before="$6" at_peak="$7" peak=null need tmp
  [[ "$dump" =~ ^[0-9]+$ ]] || dump=0
  [[ "$archive" =~ ^[0-9]+$ ]] || archive=0
  if [[ "$before" =~ ^[0-9]+$ ]] && [[ "$at_peak" =~ ^[0-9]+$ ]] && [ "$before" -gt "$at_peak" ]; then
    peak=$((before - at_peak))
  fi
  need=$((dump + archive))
  [ "$peak" != null ] && [ "$peak" -gt "$need" ] && need=$peak
  service=${service//[\"\\]/}; host=${host//[\"\\]/}
  tmp="$file.tmp.$$"
  printf '{\n  "schema": 1,\n  "service": "%s",\n  "updated_at": "%s",\n  "source_host": "%s",\n  "dump_bytes": %s,\n  "archive_bytes": %s,\n  "peak_bytes": %s,\n  "need_bytes": %s\n}\n' \
    "$service" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$host" "$dump" "$archive" "$peak" "$need" > "$tmp" \
    && chmod 600 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

snap_stats_reserve() {
  # Args: snapshots_root path...
  # Prints "<need_bytes> <service>" for the largest need_bytes among the recent stats.json files,
  # only when the snapshots root is on the same disk as one of the paths; prints nothing otherwise.
  local root="$1" root_dev p same=false f n best=0 best_svc=""
  shift
  [ -d "$root" ] || return 0
  root_dev=$(stat -c %d "$root" 2>/dev/null) || return 0
  for p in "$@"; do
    [ -n "$p" ] && [ "$(stat -c %d "$p" 2>/dev/null)" = "$root_dev" ] && { same=true; break; }
  done
  [ "$same" = true ] || return 0
  while IFS= read -r f; do
    n=$(sed -n 's/.*"need_bytes": *\([0-9][0-9]*\).*/\1/p' "$f" 2>/dev/null | head -n 1)
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    if [ "$n" -gt "$best" ]; then best=$n; best_svc=$(basename "$(dirname "$f")"); fi
  done < <(find "$root" -mindepth 2 -maxdepth 2 -name stats.json -type f -mtime "-${SNAP_STATS_MAX_AGE_DAYS}" 2>/dev/null)
  [ "$best" -gt 0 ] && echo "$best $best_svc"
  return 0
}

snap_disk_reserve_bytes() {
  # Args: reserve_gb snapshots_root path...
  # Prints "<bytes> <reason>": reason "fixed" (reserve_gb), "stats:<service>" (the room the largest recent
  # snapshot on that disk needed, +25%, when that is more), or "off" (reserve_gb is 0: no reserve at all).
  local gb="$1" root="$2" fixed line n
  shift 2
  [[ "$gb" =~ ^[0-9]+$ ]] || gb=5
  fixed=$((gb * 1024 * 1024 * 1024))
  [ "$fixed" -gt 0 ] || { echo "0 off"; return 0; }
  line=$(snap_stats_reserve "$root" "$@")
  if [ -n "$line" ]; then
    n=${line%% *}; n=$((n + n / 4))
    if [ "$n" -gt "$fixed" ]; then echo "$n stats:${line#* }"; return 0; fi
  fi
  echo "$fixed fixed"
}

# --- Local archive retention (this host) ---------------------------------------
# A snapshot that is not uploaded (no cloud storage set, or the upload failed) stays on this host in
#   <archives dir>/snapshot-<service>.tar.zst-YYYYMMDD-HHMMSS/   (~/.odoo-snapshots/<service>/archives)
#     snapshot-<service>.tar.zst  [.sha256]  [.validated.json]
# Retention keeps the newest <keep> of these folders, plus the newest one with a trusted validation
# record (it passed a restore drill), and never touches:
#   - a folder holding any other file (someone put it there: it is reported, not deleted),
#   - an archive some process has open (a drill, an upload or a copy in progress).
# These are the only copies of those snapshots, so <keep> is at least 1 and empty means keep all.

snap_file_in_use() {
  # Args: path. Returns 0 when a process has the file open (checked through /proc; as root, every
  # process). Best effort: returns 1 when nothing it can see has it open.
  local target pattern
  target=$(readlink -f "$1" 2>/dev/null) || return 1
  pattern=$(printf '%s' "$target" | sed 's/[][*?\\]/\\&/g')   # find -lname takes a glob
  # (no pipe: under pipefail, find's complaint about a process that just ended would hide the match)
  [ -n "$(find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -lname "$pattern" -print -quit 2>/dev/null)" ]
}

snap_local_plan() {
  # Args: archives_dir service keep
  # Prints one line per snapshot folder, newest first: action<TAB>folder<TAB>archive_bytes<TAB>reason
  #   action: keep | delete | skip (left alone although over the limit)
  #   reason: newest (within <keep>) | drill (newest that passed a drill) | old | other-files | in-use
  local dir="$1" service="$2" keep="$3" archive="snapshot-$2.tar.zst" f name n=0 drill="" bytes extra sha
  [ -d "$dir" ] || return 0
  [[ "$keep" =~ ^[0-9]+$ ]] && [ "$keep" -ge 1 ] || return 1
  local folders=()
  while IFS= read -r name; do folders+=("$name"); done < <(
    for f in "$dir"/*/; do
      name=$(basename "$f")
      [[ "$name" =~ ^snapshot-.+\.tar\.zst-[0-9]{8}-[0-9]{6}$ ]] || continue
      [ "${name%-????????-??????}" = "$archive" ] && [ -f "$f$archive" ] && [ ! -L "$f$archive" ] && echo "$name"
    done | sort -r)
  # The newest folder whose archive passed a restore drill (record "pass" with the archive's sha256)
  for name in "${folders[@]}"; do
    f="$dir/$name/$archive"
    [ -f "$f.validated.json" ] || continue
    sha=$(snap_sidecar_hash "$f.sha256")
    [ -n "$sha" ] || continue
    if snap_validation_record_ok "$f.validated.json" "$archive" "$sha"; then drill="$name"; break; fi
  done
  for name in "${folders[@]}"; do
    n=$((n + 1))
    f="$dir/$name/$archive"
    bytes=$(stat -c %s "$f" 2>/dev/null || echo 0)
    if [ "$n" -le "$keep" ]; then printf 'keep\t%s\t%s\tnewest\n' "$name" "$bytes"; continue; fi
    if [ "$name" = "$drill" ]; then printf 'keep\t%s\t%s\tdrill\n' "$name" "$bytes"; continue; fi
    extra=$(find "$dir/$name" -mindepth 1 -maxdepth 1 ! -name "$archive" ! -name "$archive.sha256" ! -name "$archive.validated.json" -print -quit 2>/dev/null)
    if [ -n "$extra" ]; then printf 'skip\t%s\t%s\tother-files\n' "$name" "$bytes"; continue; fi
    if snap_file_in_use "$f"; then printf 'skip\t%s\t%s\tin-use\n' "$name" "$bytes"; continue; fi
    printf 'delete\t%s\t%s\told\n' "$name" "$bytes"
  done
}

snap_local_apply() {
  # Args: archives_dir service. Reads a snap_local_plan on stdin and deletes its "delete" folders:
  # the archive first, then its .sha256 and .validated.json, then the folder. Prints "<deleted> <failed>".
  local dir="$1" archive="snapshot-$2.tar.zst" action name bytes reason deleted=0 failed=0 d
  while IFS=$'\t' read -r action name bytes reason; do
    [ "$action" = delete ] || continue
    d="$dir/$name"
    if rm -f "$d/$archive" && rm -f "$d/$archive.sha256" "$d/$archive.validated.json" && rmdir "$d" 2>/dev/null; then
      deleted=$((deleted + 1))
    else
      failed=$((failed + 1)); _ss_log warn "Local retention: could not remove $d completely."
    fi
  done
  echo "$deleted $failed"
}

snap_local_retention() {
  # Args: archives_dir service keep [home_link]
  # Applies local retention (see above) and logs what it did; home_link is the convenience link to the
  # newest snapshot (e.g. ~/snapshot-<service>.tar.zst), removed when it points to a deleted folder.
  local dir="$1" service="$2" keep="$3" link="${4:-}" plan del skip res
  [ -n "$keep" ] || return 0
  if ! [[ "$keep" =~ ^[0-9]+$ ]] || [ "$keep" -lt 1 ]; then
    _ss_log warn "Local retention: SNAPSHOT_LOCAL_MAX_BACKUPS='$keep' is not a number of at least 1; keeping every local snapshot."
    return 0
  fi
  plan=$(snap_local_plan "$dir" "$service" "$keep") || return 0
  del=$(printf '%s\n' "$plan" | grep -c '^delete' || true)
  skip=$(printf '%s\n' "$plan" | awk -F'\t' '$1 == "skip" {print $2 " (" $4 ")"}')
  [ -n "$skip" ] && _ss_log warn "Local retention: left alone although over the limit of $keep: $(echo "$skip" | tr '\n' ' ')"
  printf '%s\n' "$plan" | awk -F'\t' '$4 == "drill" {print $2}' | while read -r n; do
    _ss_log info "Local retention: also keeping $n, the newest local snapshot that passed a restore drill."
  done
  [ "$del" -gt 0 ] || return 0
  res=$(printf '%s\n' "$plan" | snap_local_apply "$dir" "$service")
  _ss_log info "Local retention: removed ${res%% *} local snapshot(s) older than the newest $keep in $dir."
  if [ -n "$link" ] && [ -L "$link" ] && [ ! -e "$link" ]; then rm -f "$link"; fi
  [ "${res##* }" = 0 ] || { _ss_log warn "Local retention: ${res##* } old local snapshot(s) could not be removed."; return 1; }
}
