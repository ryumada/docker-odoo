#!/usr/bin/env bash
set -o pipefail
# Category: Utility
# Description: Restore drill for an Odoo snapshot in throwaway containers, proving it can be recovered (phase 1: checksum, archive, manifest, git, database restore, filestore).
# Usage: ./scripts/validate-snapshot.sh (--file PATH | --drive SERVICE [--name FILE] | --gcs gs://BUCKET/OBJECT) [--publish] [options]
# Dependencies: docker (rootless recommended on the drill host), zstd, tar, git, python3, curl, flock, sha256sum, openssl (Drive service account), gcloud (--gcs)
#
# What a drill does (nothing touches the production server or its database):
#   1. checksum   archive matches its .sha256 sidecar (skipped, with a warning, if there is none)
#   2. archive    the whole .tar.zst decompresses and lists cleanly
#   3. structure  dump.sql, manifest.json, git_hashes.json and filestore are present
#   4. manifest   manifest.json is readable and names the Odoo version
#   5. git        every repository can be re-cloned at its recorded commit, or is bundled
#   6. database   dump.sql restores completely into a throwaway Postgres container with zero
#                 SQL errors (ON_ERROR_STOP + end-of-dump marker), on an internal Docker network
#                 with no outbound access, and looks like a usable Odoo database
#   7. filestore  every stored attachment exists in the archive with the right size
# The result is written as a JSON report. With --publish, a passed drill uploads
# <archive>.validated.json next to the snapshot (retention then protects that snapshot), and a
# FAILED drill removes an existing one.
#
# Where it runs: on the Secondary VPS when SNAPSHOT_REMOTE_HOST is set (over SSH, like the snapshot
# tool; nothing is installed there), otherwise on this host. --local forces this host.
#
# Results / exit codes:
#   0 pass     the snapshot is recoverable (and, with --publish, the record was written)
#   1 fail     the snapshot itself is broken
#   2 error    the drill could not finish for reasons outside the snapshot (Docker, network,
#              Drive/GCS, unreachable git remote, not enough disk, interrupted). Nothing proven.
#   3          usage or configuration error
#   4 pass     the snapshot is recoverable, but --publish could not write the record

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
PATH_TO_ODOO=$(git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$CURRENT_DIR")
umask 077

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

for lib in queue_lock.sh snapshot_storage.sh; do
  if [ -f "$CURRENT_DIR/lib/$lib" ]; then
    # shellcheck source=/dev/null
    source "$CURRENT_DIR/lib/$lib"
  else
    log_error "scripts/lib/$lib not found. Update docker-odoo (git pull)."
    exit 3
  fi
done

# --- Configuration (.env of this checkout, then environment, then flags) ---
env_get() {
  [ -f "$PATH_TO_ODOO/.env" ] || return 0
  grep "^$1=" "$PATH_TO_ODOO/.env" 2>/dev/null | tail -n1 | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//'
}
cfg() { local v="${!1:-}"; [ -n "$v" ] || v=$(env_get "$1"); [ -n "$v" ] || v="$2"; echo "$v"; }

# Reports and work files go to the deployment owner's home (like the snapshot tool), whoever runs
# the validator: as root (sudo) or as the owner. Anyone else falls back to their own home.
DEPLOY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO" 2>/dev/null)
OWNER_HOME=$(getent passwd "$DEPLOY_OWNER" 2>/dev/null | cut -d: -f6)
DIR_FALLBACK=""
if [ -n "$OWNER_HOME" ] && [ -d "$OWNER_HOME" ] && { [ "$(id -u)" = 0 ] || [ "$(id -un)" = "$DEPLOY_OWNER" ]; }; then
  default_dir="$OWNER_HOME/.odoo-validator"
else
  default_dir="$HOME/.odoo-validator"; [ -n "$OWNER_HOME" ] && [ "$OWNER_HOME" != "$HOME" ] && DIR_FALLBACK=yes
fi
VALIDATOR_DIR=$(cfg VALIDATOR_WORK_DIR "$default_dir")
[ -n "$(cfg VALIDATOR_WORK_DIR "")" ] && DIR_FALLBACK=""
# Root writes into the owner's home: hand the files to the owner so they stay readable and removable
own_path() {
  [ "$(id -u)" = 0 ] && [ -n "$DEPLOY_OWNER" ] && [ "$DEPLOY_OWNER" != root ] && [ -n "$OWNER_HOME" ] || return 0
  local f; for f in "$@"; do [[ "$f" == "$OWNER_HOME"/* ]] && chown -h "$DEPLOY_OWNER": "$f" 2>/dev/null; done; return 0
}
prepare_dirs() {
  mkdir -p "$VALIDATOR_DIR/reports" "$@" || return 1
  chmod 700 "$VALIDATOR_DIR" 2>/dev/null
  own_path "$VALIDATOR_DIR" "$VALIDATOR_DIR/reports" "$VALIDATOR_DIR/runs"
  [ -z "$DIR_FALLBACK" ] || log_warn "Reports go to $VALIDATOR_DIR because $(id -un) is not $DEPLOY_OWNER (the owner of this deployment). Run as $DEPLOY_OWNER or with sudo to keep them in $OWNER_HOME/.odoo-validator."
  DIR_FALLBACK=""
}
VALIDATOR_DISK_RESERVE_GB=$(cfg VALIDATOR_DISK_RESERVE_GB 5)
VALIDATOR_WATCHDOG_INTERVAL=$(cfg VALIDATOR_WATCHDOG_INTERVAL 15)
VALIDATOR_POSTGRES_IMAGE=$(cfg VALIDATOR_POSTGRES_IMAGE "")
VALIDATOR_PG_CPUS=$(cfg VALIDATOR_PG_CPUS auto)
VALIDATOR_PG_MEMORY=$(cfg VALIDATOR_PG_MEMORY 2g)
VALIDATOR_FILESTORE_MAX_MISSING_PCT=$(cfg VALIDATOR_FILESTORE_MAX_MISSING_PCT 1)
VALIDATOR_QUEUE_TIMEOUT=$(cfg VALIDATOR_QUEUE_TIMEOUT 43200)
VALIDATOR_GIT_TIMEOUT=$(cfg VALIDATOR_GIT_TIMEOUT 300)
VALIDATOR_GIT_ALLOW_PROTOCOL=$(cfg VALIDATOR_GIT_ALLOW_PROTOCOL "https:ssh")
VALIDATOR_PULL_POLICY=$(cfg VALIDATOR_PULL_POLICY always)
GDRIVE_ACCESS_TOKEN=$(cfg GDRIVE_ACCESS_TOKEN "")
GDRIVE_SERVICE_ACCOUNT_KEY=$(cfg GDRIVE_SERVICE_ACCOUNT_KEY "")
GDRIVE_FOLDER_ID=$(cfg GDRIVE_FOLDER_ID "")

SOURCE_KIND=""      # file | drive | gcs
SOURCE_REF=""       # path | service | gs:// url
DRIVE_NAME=""
PUBLISH=false
KEEP_WORKDIR=false
GIT_CHECK=true
LOCAL_ONLY=false
REPORT_PATH=""

show_help() {
  cat << EOF
Usage: $(basename "$0") SOURCE [OPTIONS]

Restore drill for an Odoo snapshot in throwaway containers (phase 1: checksum, archive,
manifest, git, database restore and filestore checks). Production is never touched.

Where the drill runs: on the Secondary VPS (SNAPSHOT_REMOTE_HOST, same SSH settings as the
snapshot tool) when one is set, otherwise on this host. With a Secondary VPS, --file is a path
on that VPS (relative to its home folder), and the report is copied back to this host.

Source (one of):
  --file <PATH>            A local snapshot .tar.zst (its .sha256 next to it is used if present)
  --drive <SERVICE>        Newest snapshot of SERVICE on Google Drive (with its .sha256)
    --name <FILE>          ...or this exact snapshot file name on Google Drive
  --gcs <gs://BUCKET/OBJ>  A snapshot object in Google Cloud Storage (with its .sha256)

Options:
  --publish                On pass, upload <archive>.validated.json next to the snapshot
                           (Drive/GCS) or write it next to a local --file; on fail, remove it
  --report <PATH>          Where to write the JSON report (default: $VALIDATOR_DIR/reports/)
  --keep-workdir           Keep the work folder for inspection (containers are always removed)
  --no-git-check           Skip the git repository check
  --local                  Drill on this host even when SNAPSHOT_REMOTE_HOST is set
  --folder-id <ID>         Google Drive folder ID (default: GDRIVE_FOLDER_ID)
  --sa-key <PATH>          Google Drive service account key (default: GDRIVE_SERVICE_ACCOUNT_KEY)
  --token <TOKEN>          Google Drive access token (default: GDRIVE_ACCESS_TOKEN)
  -h, --help               Show this help

Settings (environment or .env): VALIDATOR_WORK_DIR, VALIDATOR_DISK_RESERVE_GB,
VALIDATOR_WATCHDOG_INTERVAL, VALIDATOR_POSTGRES_IMAGE, VALIDATOR_PG_CPUS, VALIDATOR_PG_MEMORY,
VALIDATOR_FILESTORE_MAX_MISSING_PCT, VALIDATOR_QUEUE_TIMEOUT, VALIDATOR_GIT_TIMEOUT,
VALIDATOR_GIT_ALLOW_PROTOCOL, VALIDATOR_PULL_POLICY, VALIDATOR_REMOTE_WORK_DIR.
Prefer GDRIVE_SERVICE_ACCOUNT_KEY in .env over --token: command-line arguments are visible to
other users of this host.

Exit codes: 0 passed, 1 snapshot broken, 2 could not finish (nothing proven),
3 usage or configuration error, 4 passed but the --publish record could not be written.
EOF
}

need_value() { if [ -z "${2:-}" ] || [[ "$2" == --* ]]; then log_error "$1 needs a value."; exit 3; fi; }
while [ $# -gt 0 ]; do
  case "$1" in
    --file) need_value "$1" "${2:-}"; SOURCE_KIND=file; SOURCE_REF="$2"; shift 2 ;;
    --drive) need_value "$1" "${2:-}"; SOURCE_KIND=drive; SOURCE_REF="$2"; shift 2 ;;
    --name) need_value "$1" "${2:-}"; DRIVE_NAME="$2"; shift 2 ;;
    --gcs) need_value "$1" "${2:-}"; SOURCE_KIND=gcs; SOURCE_REF="$2"; shift 2 ;;
    --publish) PUBLISH=true; shift ;;
    --report) need_value "$1" "${2:-}"; REPORT_PATH="$2"; shift 2 ;;
    --keep-workdir) KEEP_WORKDIR=true; shift ;;
    --no-git-check) GIT_CHECK=false; shift ;;
    --local) LOCAL_ONLY=true; shift ;;
    --folder-id) need_value "$1" "${2:-}"; GDRIVE_FOLDER_ID="$2"; shift 2 ;;
    --sa-key) need_value "$1" "${2:-}"; GDRIVE_SERVICE_ACCOUNT_KEY="$2"; shift 2 ;;
    --token) need_value "$1" "${2:-}"; GDRIVE_ACCESS_TOKEN="$2"; shift 2 ;;
    -h|--help) show_help; exit 0 ;;
    *) log_error "Unknown option: $1"; show_help; exit 3 ;;
  esac
done

if [ -z "$SOURCE_KIND" ] || [ -z "$SOURCE_REF" ]; then
  log_error "Choose a snapshot with --file, --drive or --gcs."
  show_help
  exit 3
fi
if [ "$SOURCE_KIND" = gcs ] && [[ "$SOURCE_REF" != gs://* ]]; then
  log_error "--gcs needs a gs://BUCKET/OBJECT URL."
  exit 3
fi
if [ -n "$REPORT_PATH" ]; then
  REPORT_PATH=$(readlink -m "$REPORT_PATH")
fi
if [ -n "$GDRIVE_SERVICE_ACCOUNT_KEY" ] && [[ "$GDRIVE_SERVICE_ACCOUNT_KEY" != /* ]] && [ ! -f "$GDRIVE_SERVICE_ACCOUNT_KEY" ] && [ -f "$PATH_TO_ODOO/$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
  GDRIVE_SERVICE_ACCOUNT_KEY="$PATH_TO_ODOO/$GDRIVE_SERVICE_ACCOUNT_KEY"
fi

# A typo in a setting must never quietly switch a check off
bad_settings=()
[[ "$VALIDATOR_DISK_RESERVE_GB" =~ ^[0-9]+$ ]] || bad_settings+=("VALIDATOR_DISK_RESERVE_GB='$VALIDATOR_DISK_RESERVE_GB' (whole GB, e.g. 5)")
[[ "$VALIDATOR_WATCHDOG_INTERVAL" =~ ^[1-9][0-9]*$ ]] || bad_settings+=("VALIDATOR_WATCHDOG_INTERVAL='$VALIDATOR_WATCHDOG_INTERVAL' (seconds, at least 1)")
[[ "$VALIDATOR_PG_CPUS" =~ ^(auto|[0-9]+(\.[0-9]+)?)$ ]] || bad_settings+=("VALIDATOR_PG_CPUS='$VALIDATOR_PG_CPUS' (auto, or e.g. 2 or 1.5)")
[[ "$VALIDATOR_PULL_POLICY" =~ ^(always|missing)$ ]] || bad_settings+=("VALIDATOR_PULL_POLICY='$VALIDATOR_PULL_POLICY' (always or missing)")
[[ "$VALIDATOR_PG_MEMORY" =~ ^[0-9]+[bkmgBKMG]?$ ]] || bad_settings+=("VALIDATOR_PG_MEMORY='$VALIDATOR_PG_MEMORY' (e.g. 2g)")
[[ "$VALIDATOR_FILESTORE_MAX_MISSING_PCT" =~ ^[0-9]+(\.[0-9]+)?$ ]] || bad_settings+=("VALIDATOR_FILESTORE_MAX_MISSING_PCT='$VALIDATOR_FILESTORE_MAX_MISSING_PCT' (a number, e.g. 1 or 0.5)")
[[ "$VALIDATOR_QUEUE_TIMEOUT" =~ ^[0-9]+$ ]] || bad_settings+=("VALIDATOR_QUEUE_TIMEOUT='$VALIDATOR_QUEUE_TIMEOUT' (seconds)")
[[ "$VALIDATOR_GIT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || bad_settings+=("VALIDATOR_GIT_TIMEOUT='$VALIDATOR_GIT_TIMEOUT' (seconds)")
[[ "$VALIDATOR_GIT_ALLOW_PROTOCOL" =~ ^[a-z0-9+]+(:[a-z0-9+]+)*$ ]] || bad_settings+=("VALIDATOR_GIT_ALLOW_PROTOCOL='$VALIDATOR_GIT_ALLOW_PROTOCOL' (e.g. https:ssh)")
if [ ${#bad_settings[@]} -gt 0 ]; then
  for b in "${bad_settings[@]}"; do log_error "Invalid setting: $b"; done
  exit 3
fi
# --- Remote mode: the drill runs on the Secondary VPS (SNAPSHOT_REMOTE_HOST) ---
# Same SSH settings as the snapshot tool. This host only sends the validator (script + libs) and
# the storage credentials over SSH stdin, shows the drill's log live and keeps its report; Docker,
# the download and the restore all happen on the Secondary VPS. --local drills on this host instead.
SNAPSHOT_REMOTE_HOST=$(cfg SNAPSHOT_REMOTE_HOST "")
SNAPSHOT_REMOTE_USER=$(cfg SNAPSHOT_REMOTE_USER "")
SNAPSHOT_REMOTE_PORT=$(cfg SNAPSHOT_REMOTE_PORT 22)
SNAPSHOT_REMOTE_KEY=$(cfg SNAPSHOT_REMOTE_KEY "")
VALIDATOR_REMOTE_WORK_DIR=$(cfg VALIDATOR_REMOTE_WORK_DIR "")

remote_fail() {
  # Args: exit_code message. Writes a report on this host for a drill that never got a result.
  local code="$1" msg="$2" svc
  svc="$SOURCE_REF"
  [ "$SOURCE_KIND" = drive ] || svc=$(sed -E 's/^snapshot-(.+)-[0-9]{8}-[0-9]{6}\.tar\.zst$/\1/; s/^snapshot-(.+)\.tar\.zst$/\1/' <<< "${SOURCE_REF##*/}")
  [ -n "$REPORT_PATH" ] || REPORT_PATH="$VALIDATOR_DIR/reports/${svc:-unknown}-$(date +%Y%m%d-%H%M%S)-$$.json"
  python3 -c '
import json, sys
kind, ref, svc, host, msg, out, now = sys.argv[1:8]
json.dump({"schema": 1, "level": "database", "result": "error", "service": svc or None, "archive": None,
           "source": {"kind": kind, "ref": ref}, "started_at": now, "finished_at": now,
           "remote": {"host": host}, "stages": [{"name": "remote", "status": "error", "seconds": 0, "details": {"message": msg}}]},
          open(out, "w"), indent=2)
' "$SOURCE_KIND" "$(sed -E 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@[:space:]]+@#\1***@#g' <<< "$SOURCE_REF")" "$svc" \
    "$SNAPSHOT_REMOTE_USER@$SNAPSHOT_REMOTE_HOST" "$msg" "$REPORT_PATH" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" 2>/dev/null
  chmod 600 "$REPORT_PATH" 2>/dev/null
  ln -sf "$REPORT_PATH" "$VALIDATOR_DIR/reports/latest-${svc:-unknown}.json" 2>/dev/null
  own_path "$REPORT_PATH" "$VALIDATOR_DIR/reports/latest-${svc:-unknown}.json"
  log_error "$msg"
  log_info "Report: $REPORT_PATH"
  exit "$code"
}

run_remote_drill() {
  local host="$SNAPSHOT_REMOTE_HOST" user="$SNAPSHOT_REMOTE_USER" port="$SNAPSHOT_REMOTE_PORT" key="$SNAPSHOT_REMOTE_KEY"
  local owner owner_home this_vps clean_tgt cmd missing=()
  for cmd in ssh tar base64 python3; do command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd"); done
  if [ ${#missing[@]} -gt 0 ]; then log_error "Missing required tools: ${missing[*]}"; exit 3; fi
  if [ -z "$user" ]; then log_error "SNAPSHOT_REMOTE_USER is required when SNAPSHOT_REMOTE_HOST is set (or use --local)."; exit 3; fi
  # Never let a setting reach ssh as an option
  if [[ "$host" == -* || "$host" =~ [[:space:][:cntrl:]@] || "$user" == -* || "$user" =~ [[:space:][:cntrl:]@] ]] || ! [[ "$port" =~ ^[0-9]{1,5}$ ]]; then
    log_error "Invalid SNAPSHOT_REMOTE_HOST/USER/PORT ('$user@$host:$port')."; exit 3
  fi
  prepare_dirs || { log_error "Cannot create $VALIDATOR_DIR/reports"; exit 3; }

  # The SSH key: SNAPSHOT_REMOTE_KEY, else the snapshot tool's default key names
  owner=$(stat -c '%U' "$PATH_TO_ODOO" 2>/dev/null)
  owner_home=$(getent passwd "$owner" 2>/dev/null | cut -d: -f6)
  [ -d "$owner_home" ] || owner_home="$HOME"
  if [ -z "$key" ]; then
    this_vps=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "vps-source")
    clean_tgt=$(echo "$host" | sed -e 's|^.*://||' -e 's|:.*$||' -e 's|/.*$||' -e 's|[^a-zA-Z0-9._-]|_|g')
    for cand in "$owner_home/.ssh/snapshot-${this_vps}-${clean_tgt}" "$owner_home/.ssh/id_ed25519-snapshot-$(basename "$PATH_TO_ODOO")" "$owner_home/.ssh/id_ed25519_snapshot"; do
      [ -f "$cand" ] && { key="$cand"; break; }
    done
  fi
  key="${key/#\~/$owner_home}"
  local ssh_opts=(-p "$port" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=20)
  [ -n "$key" ] && [ -f "$key" ] && ssh_opts+=(-i "$key")

  log_info "Connecting to the Secondary VPS ($user@$host:$port)..."
  if ! ssh "${ssh_opts[@]}" "$user@$host" true </dev/null 2>/dev/null; then
    remote_fail 2 "Cannot connect to the Secondary VPS at $user@$host:$port over SSH (the same connection the snapshot tool uses). Nothing was proven."
  fi

  # Storage credentials go over SSH stdin and into 0600 files there, never onto a command line
  local sa_b64="" tok_b64=""
  if [ "$SOURCE_KIND" = drive ]; then
    if [ -n "$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
      if [ -f "$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
        sa_b64=$(base64 -w0 < "$GDRIVE_SERVICE_ACCOUNT_KEY") || { log_error "Cannot read GDRIVE_SERVICE_ACCOUNT_KEY."; exit 3; }
      elif [[ "$(printf '%s' "$GDRIVE_SERVICE_ACCOUNT_KEY" | tr -d '[:space:]' | head -c 1)" == "{" ]]; then
        sa_b64=$(printf '%s' "$GDRIVE_SERVICE_ACCOUNT_KEY" | base64 -w0)
      else
        log_error "GDRIVE_SERVICE_ACCOUNT_KEY is neither a readable file nor JSON content."; exit 3
      fi
    fi
    if [ -n "$GDRIVE_ACCESS_TOKEN" ]; then
      if [ -f "$GDRIVE_ACCESS_TOKEN" ]; then tok_b64=$(base64 -w0 < "$GDRIVE_ACCESS_TOKEN")
      else tok_b64=$(printf '%s' "$GDRIVE_ACCESS_TOKEN" | base64 -w0); fi
    fi
  fi

  local fwd=(--local)
  case "$SOURCE_KIND" in
    file) fwd+=(--file "$SOURCE_REF") ;;
    drive) fwd+=(--drive "$SOURCE_REF"); [ -n "$DRIVE_NAME" ] && fwd+=(--name "$DRIVE_NAME") ;;
    gcs) fwd+=(--gcs "$SOURCE_REF") ;;
  esac
  [ "$PUBLISH" = true ] && fwd+=(--publish)
  [ "$KEEP_WORKDIR" = true ] && fwd+=(--keep-workdir)
  [ "$GIT_CHECK" = true ] || fwd+=(--no-git-check)

  local exports="" v
  # Settings as configured here (auto values such as VALIDATOR_PG_CPUS are worked out on the Secondary VPS)
  for v in VALIDATOR_DISK_RESERVE_GB VALIDATOR_WATCHDOG_INTERVAL VALIDATOR_POSTGRES_IMAGE VALIDATOR_PG_CPUS \
           VALIDATOR_PG_MEMORY VALIDATOR_FILESTORE_MAX_MISSING_PCT VALIDATOR_QUEUE_TIMEOUT VALIDATOR_GIT_TIMEOUT \
           VALIDATOR_GIT_ALLOW_PROTOCOL VALIDATOR_PULL_POLICY GDRIVE_FOLDER_ID; do
    exports+="export $v=$(printf '%q' "${!v}")"$'\n'
  done
  for v in QUEUE_LOCK_STALE_AFTER QUEUE_LOCK_POLL_INTERVAL GDS_API_BASE; do
    [ -n "${!v:-}" ] && exports+="export $v=$(printf '%q' "${!v}")"$'\n'
  done

  local payload bootf bfd out rc
  payload=$(tar -C "$CURRENT_DIR" -cf - validate-snapshot.sh lib/queue_lock.sh lib/snapshot_storage.sh | base64 -w0) \
    || { log_error "Cannot package the validator."; exit 3; }
  bootf=$(mktemp) && out=$(mktemp) || { log_error "Cannot create temporary files."; exit 3; }
  chmod 600 "$bootf" "$out"
  {
    cat <<'BOOT_HEAD'
set -o pipefail
umask 077
trap 'exit 141' PIPE
BOOT_HEAD
    printf 'RWD=%q\n' "$VALIDATOR_REMOTE_WORK_DIR"
    cat <<'BOOT_SETUP'
[ -n "$RWD" ] || RWD="$HOME/.odoo-validator"
case "$RWD" in "~/"*) RWD="$HOME/${RWD#\~/}" ;; esac
mkdir -p "$RWD/remote" || { echo "Cannot create $RWD/remote on the Secondary VPS" >&2; exit 92; }
chmod 700 "$RWD" "$RWD/remote" 2>/dev/null
# Bundles of earlier drills whose session died (they may hold credentials)
for d in "$RWD"/remote/*; do
  [ -d "$d" ] || continue
  p="${d##*-}"; [[ "$p" =~ ^[0-9]+$ ]] && [ -d "/proc/$p" ] && continue
  rm -rf "$d"
done
B="$RWD/remote/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$B/scripts" || { echo "Cannot create $B on the Secondary VPS" >&2; exit 92; }
trap 'rm -rf "$B"' EXIT
BOOT_SETUP
    printf "printf '%%s' '%s' | base64 -d | tar -xf - -C \"\$B/scripts\" || { echo 'Cannot unpack the validator on the Secondary VPS (base64/tar missing?)' >&2; exit 92; }\n" "$payload"
    if [ -n "$sa_b64" ]; then
      printf "printf '%%s' '%s' | base64 -d > \"\$B/sa.json\" || exit 92\nexport GDRIVE_SERVICE_ACCOUNT_KEY=\"\$B/sa.json\"\n" "$sa_b64"
    else
      printf 'export GDRIVE_SERVICE_ACCOUNT_KEY=""\n'
    fi
    if [ -n "$tok_b64" ]; then
      printf "printf '%%s' '%s' | base64 -d > \"\$B/token\" || exit 92\nexport GDRIVE_ACCESS_TOKEN=\"\$B/token\"\n" "$tok_b64"
    else
      printf 'export GDRIVE_ACCESS_TOKEN=""\n'
    fi
    printf '%s' "$exports"
    printf 'export VALIDATOR_WORK_DIR="$RWD" VALIDATOR_REMOTE_CHILD=1\n'
    printf 'ARGS=(%s)\n' "$(printf '%q ' "${fwd[@]}")"
    cat <<'BOOT_RUN'
cd "$HOME" 2>/dev/null || cd /
# The drill's log is relayed to this SSH session; if the session is gone, writes just fail
# (the relay ignores SIGPIPE, so the drill itself is never killed by a lost connection)
"$B/scripts/validate-snapshot.sh" "${ARGS[@]}" --report "$B/report.json" </dev/null \
  2> >(trap '' PIPE; while IFS= read -r l; do printf '%s\n' "$l" >&2; done) &
vp=$!
# If the main VPS disconnects (Ctrl-C, killed, network), stop the drill: it cleans up after itself
( trap '' PIPE; exec </dev/null
  while kill -0 "$vp" 2>/dev/null; do
    sleep 5
    if ! printf '\n' 2>/dev/null; then kill -TERM "$vp" 2>/dev/null; break; fi
  done ) &
wp=$!
wait "$vp"; rc=$?
kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
sleep 0.2
if [ -f "$B/report.json" ]; then
  printf '\n@@VALIDATOR-REPORT-BEGIN@@\n'; base64 -w0 < "$B/report.json"; printf '\n@@VALIDATOR-REPORT-END@@\n'
fi
exit "$rc"
BOOT_RUN
  } > "$bootf"

  log_info "Running the drill on the Secondary VPS ($host); its log follows."
  exec {bfd}<"$bootf"; rm -f "$bootf"
  ssh "${ssh_opts[@]}" "$user@$host" "bash -s" <&"$bfd" > "$out" &
  REMOTE_SSH_PID=$!
  exec {bfd}<&-
  trap 'kill -TERM "$REMOTE_SSH_PID" 2>/dev/null; rm -f "$out"; remote_fail 2 "Interrupted. The drill on the Secondary VPS stops by itself within a few seconds and removes its containers."' INT TERM
  wait "$REMOTE_SSH_PID"; rc=$?
  trap - INT TERM

  local rep
  rep=$(sed -n '/^@@VALIDATOR-REPORT-BEGIN@@$/,/^@@VALIDATOR-REPORT-END@@$/p' "$out" | sed '1d;$d' | tr -d '\n')
  rm -f "$out"
  if [ -n "$rep" ] && printf '%s' "$rep" | base64 -d > "$VALIDATOR_DIR/reports/.incoming.$$" 2>/dev/null \
     && python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
r["remote"] = {"host": sys.argv[2], "via": "ssh"}
print(r.get("service") or "unknown")
json.dump(r, open(sys.argv[1], "w"), indent=2)
' "$VALIDATOR_DIR/reports/.incoming.$$" "$user@$host" > "$VALIDATOR_DIR/reports/.svc.$$" 2>/dev/null; then
    local svc
    svc=$(cat "$VALIDATOR_DIR/reports/.svc.$$"); rm -f "$VALIDATOR_DIR/reports/.svc.$$"
    [ -n "$REPORT_PATH" ] || REPORT_PATH="$VALIDATOR_DIR/reports/$svc-$(date +%Y%m%d-%H%M%S)-$$.json"
    mv "$VALIDATOR_DIR/reports/.incoming.$$" "$REPORT_PATH" && chmod 600 "$REPORT_PATH"
    ln -sf "$REPORT_PATH" "$VALIDATOR_DIR/reports/latest-$svc.json" 2>/dev/null
    own_path "$REPORT_PATH" "$VALIDATOR_DIR/reports/latest-$svc.json"
    log_info "Report (from the Secondary VPS): $REPORT_PATH"
    case "$rc" in 0|1|2|3|4) exit "$rc" ;; esac
    log_warn "The drill on the Secondary VPS ended unexpectedly (exit $rc)."
    exit 2
  fi
  rm -f "$VALIDATOR_DIR/reports/.incoming.$$" "$VALIDATOR_DIR/reports/.svc.$$"
  case "$rc" in
    3) remote_fail 3 "The Secondary VPS cannot run the drill (missing tools, Docker access or settings: see the log above)." ;;
    255) remote_fail 2 "The SSH connection to the Secondary VPS failed or was lost during the drill. Nothing was proven." ;;
    92) remote_fail 2 "Could not prepare the drill on the Secondary VPS (see the log above). Nothing was proven." ;;
    *) remote_fail 2 "The drill on the Secondary VPS returned no report (exit $rc). Nothing was proven." ;;
  esac
}

if [ -n "$SNAPSHOT_REMOTE_HOST" ] && [ "$LOCAL_ONLY" != true ]; then
  run_remote_drill
fi

if [ "$VALIDATOR_PG_CPUS" = auto ]; then
  # Half of this host's cores (at least 1), so a drill never takes every CPU from snapshots
  VALIDATOR_PG_CPUS=$(( $(nproc 2>/dev/null || echo 2) / 2 ))
  [ "$VALIDATOR_PG_CPUS" -ge 1 ] || VALIDATOR_PG_CPUS=1
fi

missing=()
for cmd in docker zstd tar git python3 curl flock sha256sum timeout; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
[ "$SOURCE_KIND" = gcs ] && ! command -v gcloud >/dev/null 2>&1 && missing+=("gcloud")
if [ ${#missing[@]} -gt 0 ]; then
  log_error "Missing required tools: ${missing[*]}"
  exit 3
fi
# --- Docker on the drill host ---
# Recommended: rootless Docker for the drill user (its own daemon, so the account never gets root).
# The docker group also works but is root-equivalent, so it only gets a warning. The checks below say
# exactly which setup step is missing (scripts/README.md, "Secondary VPS setup").
docker_setup_help() {
  local me="$1"
  cat >&2 << HELP
  Set up rootless Docker for $me once (every step is done for you, and repeating it is safe):
    on the main VPS:   ./scripts/setup-validator-docker.sh -a <sudo-admin of this host>
    or on this host:   sudo ./scripts/setup-validator-docker.sh --local -u $me
  Details: scripts/README.md, Validate Snapshot > Secondary VPS setup.
HELP
}
docker_preflight() {
  local me uid rt sock i ctlfile ctls c missing_ctl=() sec
  me=$(id -un); uid=$(id -u)
  rt="${XDG_RUNTIME_DIR:-/run/user/$uid}"; sock="$rt/docker.sock"
  if [ -z "${DOCKER_HOST:-}" ] && [ "$uid" != 0 ]; then
    if [ -S "$sock" ]; then
      export DOCKER_HOST="unix://$sock"
    elif ! docker info >/dev/null 2>&1; then
      # Neither this user's rootless daemon nor the system daemon: say which step is missing
      if [ ! -f "$HOME/.config/systemd/user/docker.service" ]; then
        if command -v dockerd-rootless.sh >/dev/null 2>&1 || command -v rootlesskit >/dev/null 2>&1; then
          log_error "Rootless Docker is installed on this host but not set up for $me."
        else
          log_error "Docker is not usable by $me, and rootless Docker is not installed on this host."
        fi
        docker_setup_help "$me"; exit 3
      fi
      # Set up: its daemon may still be starting after this login
      for i in $(seq "${VALIDATOR_DOCKER_START_WAIT:-20}"); do [ -S "$sock" ] && break; sleep 1; done
      if [ ! -S "$sock" ]; then
        log_error "Rootless Docker is set up for $me but not running ($sock is missing)."
        echo "  As $me: systemctl --user enable --now docker" >&2
        docker_setup_help "$me"; exit 3
      fi
      export DOCKER_HOST="unix://$sock"
    fi
  fi
  if ! docker info >/dev/null 2>&1; then
    if [ -n "${DOCKER_HOST:-}" ]; then
      log_error "Docker at $DOCKER_HOST is not answering for $me. Check: systemctl --user status docker (rootless) or the DOCKER_HOST setting."
    elif [ "$uid" = 0 ]; then
      log_error "Docker is not running on this host (systemctl status docker)."
    else
      log_error "Docker is not usable by $me."
      docker_setup_help "$me"
    fi
    exit 3
  fi
  sec=$(docker info -f '{{json .SecurityOptions}}' 2>/dev/null)
  if [[ "$sec" == *"name=rootless"* ]]; then
    # The drill's limits (--cpus, --memory, --pids-limit) need these cgroup controllers delegated
    # to the user's systemd; without the limits a drill could starve the snapshots on this host.
    ctlfile="${VALIDATOR_TEST_CGROUP_FILE:-/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers}"
    ctls=$(cat "$ctlfile" 2>/dev/null)
    for c in cpu memory pids; do [[ " $ctls " == *" $c "* ]] || missing_ctl+=("$c"); done
    if [ ${#missing_ctl[@]} -gt 0 ]; then
      log_error "Rootless Docker for $me cannot limit ${missing_ctl[*]} (cgroup controllers not delegated), so a drill could take resources from snapshots."
      docker_setup_help "$me"; exit 3
    fi
    [ -e "/var/lib/systemd/linger/$me" ] || log_warn "Lingering is off for $me: rootless Docker stops when no session is open, so every drill starts it again. Fix: ./scripts/setup-validator-docker.sh -a <sudo-admin> (on the main VPS)"
  elif [ "$uid" != 0 ]; then
    log_warn "$me uses the system Docker daemon (docker group). That membership is equivalent to root on this host; rootless Docker is safer: ./scripts/setup-validator-docker.sh -a <sudo-admin> --remove-docker-group (on the main VPS)."
  fi
}
docker_preflight

# --- Run state ---
RUN_ID="$(date +"%Y%m%d-%H%M%S")-$$"
WORK="$VALIDATOR_DIR/runs/$RUN_ID"
DRILL_NAME="odoo-drill-$RUN_ID"
PG_CONTAINER="$DRILL_NAME-pg"
DRILL_NET="$DRILL_NAME-net"
STAGES_FILE="$WORK/stages.jsonl"
STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_EPOCH=$(date +%s)
ARCHIVE="" ARCHIVE_FD="" AR="" SIDECAR="" ARCHIVE_NAME="" ARCHIVE_SHA="" SERVICE="" REMOTE_ARCHIVE_ID=""
DRIVE_TOKEN="" GCS_GENERATION=""
DUMP_MEMBER="" MANIFEST_MEMBER="" GIT_HASHES_MEMBER="" SECRETS_USER_MEMBER="" FILESTORE_PREFIX=""
# Where dump.sql, manifest.json and the filestore are: "tar" (the snapshot itself) or "zip" (the
# Odoo backup zip inside older snapshots, until docker-odoo's 2026-10 snapshot refactor)
CORE_SRC="tar" CORE_MEMBERS="" INNER_ZIP="" INNER_ZIP_MEMBER=""
ODOO_VERSION="" PG_IMAGE="" WATCHDOG_PID="" CHILD_PID="" ABORT_REASON="" RESULT=""
FAILED=0 ERRORS=0 WARNED=0 PUBLISHED="" DB_STATS="{}" PULL_WARNING=""

prepare_dirs "$VALIDATOR_DIR/runs" && mkdir -p "$WORK" || { log_error "Cannot create $WORK"; exit 3; }
chmod 700 "$VALIDATOR_DIR" "$VALIDATOR_DIR/runs" "$WORK" 2>/dev/null || true
: > "$STAGES_FILE"

redact() {
  # Hide credentials embedded in URLs (https://user:token@host/...)
  sed -E 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@[:space:]]+@#\1***@#g' <<< "$1"
}
msg_of() {
  python3 -c 'import json,sys
try: d=json.loads(sys.argv[1]); print(d.get("message", sys.argv[1]) if isinstance(d, dict) else sys.argv[1])
except Exception: print(sys.argv[1])' "$1"
}

record_stage() {
  # Args: name status(pass|warn|skip|fail|error) seconds details(JSON object or plain text)
  # Anything that is not a known status counts as a failure: a check that crashed must
  # never look like a check that passed.
  local name="$1" status="$2" secs="$3" details="$4"
  case "$status" in
    pass|warn|skip|fail|error) ;;
    *) details="{\"message\": $(jstr "The $name check did not produce a result (it crashed or was misconfigured)"), \"raw_status\": $(jstr "$status")}"
       status="fail" ;;
  esac
  python3 -c '
import json, sys
name, status, secs, details = sys.argv[1], sys.argv[2], float(sys.argv[3] or 0), sys.argv[4]
try:
    d = json.loads(details)
except Exception:
    d = {"message": details}
print(json.dumps({"name": name, "status": status, "seconds": round(secs, 1), "details": d}))
' "$name" "$status" "$secs" "$details" >> "$STAGES_FILE"
  case "$status" in
    pass)  log_success "[$name] passed" ;;
    warn)  WARNED=$((WARNED + 1)); log_warn "[$name] passed with warnings: $(msg_of "$details")" ;;
    skip)  log_warn "[$name] skipped: $(msg_of "$details")" ;;
    fail)  FAILED=$((FAILED + 1)); log_error "[$name] FAILED: $(msg_of "$details")" ;;
    error) ERRORS=$((ERRORS + 1)); log_error "[$name] could not be checked: $(msg_of "$details")" ;;
  esac
}
now_s() { date +%s.%N; }
since() { python3 -c "print(round($(now_s) - $1, 1))"; }
jstr() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

run_bg() {
  # Runs a long step in the background and waits for it, so INT/TERM and the disk watchdog
  # take effect immediately (bash only runs traps between commands, never inside a pipeline).
  # The child never keeps the queue lock open.
  ( [ -n "${QUEUE_LOCK_HELD_FD:-}" ] && exec {QUEUE_LOCK_HELD_FD}<&-; "$@" ) &
  CHILD_PID=$!
  wait "$CHILD_PID"
  local rc=$?
  CHILD_PID=""
  return $rc
}
kill_child() {
  if [ -n "$CHILD_PID" ]; then
    pkill -TERM -P "$CHILD_PID" 2>/dev/null
    kill -TERM "$CHILD_PID" 2>/dev/null
    CHILD_PID=""
  fi
}

# --- Cleanup: containers, network, work folder, watchdog, queue slot ---
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null
  kill_child
  docker rm -fv "$PG_CONTAINER" >/dev/null 2>&1
  docker network rm "$DRILL_NET" >/dev/null 2>&1
  [ -n "$ARCHIVE_FD" ] && exec {ARCHIVE_FD}<&- 2>/dev/null
  if [ "$KEEP_WORKDIR" = true ]; then
    touch "$WORK/.keep" 2>/dev/null
    log_info "Work folder kept: $WORK"
  else
    rm -rf "$WORK" 2>/dev/null
  fi
  queue_lock_release_all
  exit $rc
}
on_signal() {
  trap '' INT TERM
  kill_child
  if [ -f "$WORK/abort_low_disk" ]; then ABORT_REASON="free disk space fell below the reserve during the drill"; else ABORT_REASON="interrupted"; fi
  record_stage "aborted" "error" 0 "$ABORT_REASON"
  finish error
}
trap cleanup EXIT
trap on_signal INT TERM

write_report() {
  local finished
  finished=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  [ -n "$REPORT_PATH" ] || REPORT_PATH="$VALIDATOR_DIR/reports/${SERVICE:-unknown}-$RUN_ID.json"
  python3 -c '
import json, sys
(stages_file, out, result, service, archive, source_kind, source_ref, sha, started, finished,
 duration, odoo_version, pg_image, db_stats, gcs_gen, published) = sys.argv[1:17]
stages = [json.loads(l) for l in open(stages_file) if l.strip()]
try:
    db = json.loads(db_stats or "{}")
except Exception:
    db = {}
report = {"schema": 1, "level": "database", "result": result, "service": service,
          "archive": archive, "source": {"kind": source_kind, "ref": source_ref, "gcs_generation": gcs_gen or None},
          "sha256": sha or None, "started_at": started, "finished_at": finished,
          "duration_seconds": int(float(duration)), "odoo_version": odoo_version or None,
          "postgres_image": pg_image or None, "database": db, "record_published": published or None,
          "stages": stages}
with open(out, "w") as f:
    json.dump(report, f, indent=2); f.write("\n")
' "$STAGES_FILE" "$REPORT_PATH" "$RESULT" "$SERVICE" "$ARCHIVE_NAME" "$SOURCE_KIND" "$(redact "$SOURCE_REF")" \
    "$ARCHIVE_SHA" "$STARTED_AT" "$finished" "$(( $(date +%s) - START_EPOCH ))" "$ODOO_VERSION" "$PG_IMAGE" "$DB_STATS" \
    "$GCS_GENERATION" "$PUBLISHED"
  chmod 600 "$REPORT_PATH" 2>/dev/null || true
  ln -sf "$REPORT_PATH" "$VALIDATOR_DIR/reports/latest-${SERVICE:-unknown}.json" 2>/dev/null || true
  own_path "$REPORT_PATH" "$VALIDATOR_DIR/reports/latest-${SERVICE:-unknown}.json"
  # On the Secondary VPS this copy is temporary: the main VPS keeps the report and says where
  [ -n "${VALIDATOR_REMOTE_CHILD:-}" ] || log_info "Report: $REPORT_PATH"
}

revoke_record() {
  # A FAILED drill must not leave an older "pass" record behind for this snapshot.
  local t0 ids id
  t0=$(now_s)
  case "$SOURCE_KIND" in
    drive)
      DRIVE_TOKEN=$(gds_get_token "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_SERVICE_ACCOUNT_KEY")
      while id=$(gds_find_by_name "$DRIVE_TOKEN" "$GDRIVE_FOLDER_ID" "$ARCHIVE_NAME.validated.json") && [ -n "$id" ]; do
        gds_delete_file "$DRIVE_TOKEN" "$id" "$GDRIVE_FOLDER_ID" >/dev/null || { record_stage "revoke" "error" "$(since "$t0")" "Could not remove the old $ARCHIVE_NAME.validated.json from Google Drive. Delete it by hand."; return; }
        ids="yes"
      done ;;
    gcs)
      if gcloud storage ls "$SOURCE_REF.validated.json" >/dev/null 2>&1; then
        gcloud storage rm "$SOURCE_REF.validated.json" >/dev/null 2>&1 && ids="yes" \
          || { record_stage "revoke" "error" "$(since "$t0")" "Could not remove the old $(redact "$SOURCE_REF").validated.json. Delete it by hand."; return; }
      fi ;;
    file)
      [ -f "$ARCHIVE.validated.json" ] && rm -f "$ARCHIVE.validated.json" && ids="yes" ;;
  esac
  [ -n "${ids:-}" ] && record_stage "revoke" "pass" "$(since "$t0")" "Removed the old validation record: this snapshot no longer counts as proven"
}

finish() {
  # Args: pass | fail | error. Writes the report and exits with the matching code.
  RESULT="$1"
  trap '' INT TERM
  [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null && WATCHDOG_PID=""
  if [ "$RESULT" = fail ] && [ "$PUBLISH" = true ] && [ -n "$ARCHIVE_NAME" ]; then
    revoke_record
  fi
  write_report
  echo >&2
  case "$RESULT" in
    pass)
      if [ "$PUBLISH" = true ] && [ "$PUBLISHED" != yes ]; then
        log_warn "DRILL PASSED for $ARCHIVE_NAME, but the validation record was NOT written, so retention will not protect it."
        exit 4
      fi
      log_success "DRILL PASSED for $ARCHIVE_NAME ($(( $(date +%s) - START_EPOCH ))s)$([ "$WARNED" -gt 0 ] && echo ", $WARNED warning(s)")."
      exit 0 ;;
    fail)
      log_error "DRILL FAILED for ${ARCHIVE_NAME:-the snapshot}: the snapshot is not recoverable as it is. See the report."
      exit 1 ;;
    *)
      log_warn "Drill could not finish for ${ARCHIVE_NAME:-the snapshot}; nothing was proven either way. See the report."
      exit 2 ;;
  esac
}

free_bytes() { df -PB1 "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }
human() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1 B"; }
RESERVE_BYTES=$(( VALIDATOR_DISK_RESERVE_GB * 1024 * 1024 * 1024 ))
DOCKER_ROOT=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)
[ -d "$DOCKER_ROOT" ] || DOCKER_ROOT="/var/lib/docker"

start_watchdog() {
  # Gives the disk back to snapshots if it runs low while the drill is running: removes the
  # drill's Postgres container (freeing its data at once) and stops the drill. Exits by itself
  # if the drill process is gone, and never holds the queue lock.
  [ "$RESERVE_BYTES" -gt 0 ] || return 0
  local main_pid=$$
  (
    [ -n "${QUEUE_LOCK_HELD_FD:-}" ] && exec {QUEUE_LOCK_HELD_FD}<&-
    [ -n "$ARCHIVE_FD" ] && exec {ARCHIVE_FD}<&-
    while sleep "$VALIDATOR_WATCHDOG_INTERVAL"; do
      kill -0 "$main_pid" 2>/dev/null || exit 0
      for p in "$WORK" "$DOCKER_ROOT"; do
        f=$(free_bytes "$p")
        if [ -n "$f" ] && [ "$f" -lt "$RESERVE_BYTES" ]; then
          touch "$WORK/abort_low_disk" 2>/dev/null
          docker rm -fv "$PG_CONTAINER" >/dev/null 2>&1
          kill -TERM "$main_pid" 2>/dev/null
          exit 0
        fi
      done
    done
  ) </dev/null >/dev/null 2>&1 &
  WATCHDOG_PID=$!
}

# --- Queue: one drill at a time on this host (snapshots use their own queue) ---
QUEUE_LOCK_LEGACY_STALE_AFTER="$VALIDATOR_QUEUE_TIMEOUT"
if ! queue_lock_acquire_local "odoo-snapshot-validator" "$(_ql_sanitize "${SOURCE_REF##*/}")" \
    "validator: $SOURCE_KIND $(redact "${SOURCE_REF##*/}") (pid $$)" "$VALIDATOR_QUEUE_TIMEOUT"; then
  exit 2
fi
# Drills always give way to snapshots and production work
ionice -c3 -p $$ >/dev/null 2>&1 || true
renice -n 19 -p $$ >/dev/null 2>&1 || true

sweep_leftovers() {
  # Only one drill runs per host (queue above), so drill containers, networks and work folders
  # still present now belong to a drill that was killed (kill -9, out of memory, reboot).
  # Remove them so they stop holding disk. Run ids end with the drill's PID.
  local name run pid n=0 d
  owner_alive() { pid="${1##*-}"; [[ "$pid" =~ ^[0-9]+$ ]] && [ -d "/proc/$pid" ]; }
  while read -r name run; do
    [ -n "$name" ] && [ "$run" != "$RUN_ID" ] || continue
    owner_alive "$run" && continue
    docker rm -fv "$name" >/dev/null 2>&1 && n=$((n + 1))
  done < <(docker ps -a --filter label=odoo-drill --format '{{.Names}} {{.Label "odoo-drill"}}' 2>/dev/null)
  while read -r name run; do
    [ -n "$name" ] && [ "$run" != "$RUN_ID" ] || continue
    owner_alive "$run" && continue
    docker network rm "$name" >/dev/null 2>&1
  done < <(docker network ls --filter label=odoo-drill --format '{{.Name}} {{.Label "odoo-drill"}}' 2>/dev/null)
  for d in "$VALIDATOR_DIR"/runs/*; do
    [ -d "$d" ] && [ "$d" != "$WORK" ] && [ ! -e "$d/.keep" ] || continue
    owner_alive "$(basename "$d")" && continue
    rm -rf "$d" 2>/dev/null
  done
  [ "$n" -gt 0 ] && log_info "Removed the leftovers of $n earlier drill(s) that did not finish."
  return 0
}

log_info "Drill $RUN_ID started (work folder: $WORK)"
sweep_leftovers
start_watchdog

# --- Fetch the snapshot ---
fetch_snapshot() {
  local t0 size free
  t0=$(now_s)
  case "$SOURCE_KIND" in
    file)
      ARCHIVE=$(readlink -f "$SOURCE_REF")
      [ -f "$ARCHIVE" ] || { record_stage "fetch" "error" "$(since "$t0")" "File not found: $SOURCE_REF"; finish error; }
      ARCHIVE_NAME=$(basename "$ARCHIVE")
      [ -f "$ARCHIVE.sha256" ] && SIDECAR="$ARCHIVE.sha256"
      ;;
    drive)
      DRIVE_TOKEN=$(gds_get_token "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_SERVICE_ACCOUNT_KEY")
      [ -n "$DRIVE_TOKEN" ] || { record_stage "fetch" "error" "$(since "$t0")" "No Google Drive token (set GDRIVE_SERVICE_ACCOUNT_KEY or GDRIVE_ACCESS_TOKEN)"; finish error; }
      local row
      if [ -n "$DRIVE_NAME" ]; then
        row=$(gds_list_archives "$DRIVE_TOKEN" "$GDRIVE_FOLDER_ID" "$SOURCE_REF" | awk -F'\t' -v n="$DRIVE_NAME" '$4==n' | head -n1)
      else
        row=$(gds_list_archives "$DRIVE_TOKEN" "$GDRIVE_FOLDER_ID" "$SOURCE_REF" 1)
      fi
      [ -n "$row" ] || { record_stage "fetch" "error" "$(since "$t0")" "No snapshot for service '$SOURCE_REF' on Google Drive (or the listing failed)"; finish error; }
      REMOTE_ARCHIVE_ID=$(cut -f3 <<< "$row"); ARCHIVE_NAME=$(cut -f4 <<< "$row"); size=$(cut -f5 <<< "$row")
      free=$(free_bytes "$WORK")
      if [ -n "$size" ] && [ -n "$free" ] && [ $((size + RESERVE_BYTES)) -gt "$free" ]; then
        record_stage "fetch" "error" "$(since "$t0")" "Not enough disk to download $ARCHIVE_NAME ($(human "$size") + reserve $(human "$RESERVE_BYTES") needed, $(human "$free") free)"
        finish error
      fi
      log_info "Downloading $ARCHIVE_NAME ($(human "${size:-0}")) from Google Drive..."
      ARCHIVE="$WORK/$ARCHIVE_NAME"
      run_bg gds_download "$DRIVE_TOKEN" "$REMOTE_ARCHIVE_ID" "$ARCHIVE" || { record_stage "fetch" "error" "$(since "$t0")" "Download of $ARCHIVE_NAME failed"; finish error; }
      local sid
      sid=$(gds_find_by_name "$DRIVE_TOKEN" "$GDRIVE_FOLDER_ID" "$ARCHIVE_NAME.sha256")
      if [ -n "$sid" ] && gds_download "$DRIVE_TOKEN" "$sid" "$ARCHIVE.sha256"; then SIDECAR="$ARCHIVE.sha256"; fi
      ;;
    gcs)
      # Pin the object generation: the GCS snapshot object is overwritten on every run, and the
      # record must only ever describe the exact bytes that were drilled.
      GCS_GENERATION=$(gcloud storage objects describe "$SOURCE_REF" --format='value(generation)' 2>/dev/null)
      [[ "$GCS_GENERATION" =~ ^[0-9]+$ ]] || { record_stage "fetch" "error" "$(since "$t0")" "Could not read $(redact "$SOURCE_REF") from Google Cloud Storage"; finish error; }
      ARCHIVE_NAME=$(basename "$SOURCE_REF"); ARCHIVE="$WORK/$ARCHIVE_NAME"
      size=$(gcloud storage objects describe "$SOURCE_REF#$GCS_GENERATION" --format='value(size)' 2>/dev/null)
      free=$(free_bytes "$WORK")
      if [[ "$size" =~ ^[0-9]+$ ]] && [ -n "$free" ] && [ $((size + RESERVE_BYTES)) -gt "$free" ]; then
        record_stage "fetch" "error" "$(since "$t0")" "Not enough disk to download $ARCHIVE_NAME ($(human "$size") + reserve $(human "$RESERVE_BYTES") needed, $(human "$free") free)"
        finish error
      fi
      log_info "Downloading $(redact "$SOURCE_REF") (generation $GCS_GENERATION)..."
      run_bg gcloud storage cp "$SOURCE_REF#$GCS_GENERATION" "$ARCHIVE" >/dev/null 2>&1 \
        || { record_stage "fetch" "error" "$(since "$t0")" "Download of $(redact "$SOURCE_REF")#$GCS_GENERATION failed"; finish error; }
      gcloud storage cp "$SOURCE_REF.sha256" "$ARCHIVE.sha256" >/dev/null 2>&1 && SIDECAR="$ARCHIVE.sha256"
      ;;
  esac
  # Hold the archive open: every later step reads this exact file, even if a new snapshot is
  # moved onto the same path while the drill runs.
  if ! exec {ARCHIVE_FD}<"$ARCHIVE"; then
    record_stage "fetch" "error" "$(since "$t0")" "Cannot open $ARCHIVE"
    finish error
  fi
  AR="/proc/$$/fd/$ARCHIVE_FD"
  SERVICE=$(sed -E 's/^snapshot-(.+)-[0-9]{8}-[0-9]{6}\.tar\.zst$/\1/; s/^snapshot-(.+)\.tar\.zst$/\1/' <<< "$ARCHIVE_NAME")
  [ "$SOURCE_KIND" = drive ] && SERVICE="$SOURCE_REF"
  record_stage "fetch" "pass" "$(since "$t0")" "{\"archive\": $(jstr "$ARCHIVE_NAME"), \"bytes\": $(stat -L -c %s "$AR"), \"sha256_file\": $([ -n "$SIDECAR" ] && echo true || echo false)$([ -n "$GCS_GENERATION" ] && echo ", \"gcs_generation\": \"$GCS_GENERATION\"")}"
}

stage_checksum() {
  local t0 expected
  t0=$(now_s)
  log_info "[checksum] Hashing $ARCHIVE_NAME..."
  hash_archive() { snap_sha256_of "$AR" > "$WORK/sha256"; }
  if ! run_bg hash_archive || ! ARCHIVE_SHA=$(cat "$WORK/sha256") || ! [[ "$ARCHIVE_SHA" =~ ^[0-9a-f]{64}$ ]]; then
    record_stage "checksum" "error" "$(since "$t0")" "Cannot read $ARCHIVE"
    finish error
  fi
  if [ -z "$SIDECAR" ]; then
    record_stage "checksum" "skip" "$(since "$t0")" "{\"message\": \"No .sha256 file for this snapshot; integrity is still checked by the archive stage\", \"sha256\": \"$ARCHIVE_SHA\"}"
    return
  fi
  expected=$(snap_sidecar_hash "$SIDECAR")
  if [ -z "$expected" ]; then
    record_stage "checksum" "warn" "$(since "$t0")" "{\"message\": \"The .sha256 file is not valid\", \"sha256\": \"$ARCHIVE_SHA\"}"
  elif [ "$expected" != "$ARCHIVE_SHA" ]; then
    record_stage "checksum" "fail" "$(since "$t0")" "{\"message\": \"Archive does not match its .sha256 file\", \"expected\": \"$expected\", \"actual\": \"$ARCHIVE_SHA\"}"
    finish fail
  else
    record_stage "checksum" "pass" "$(since "$t0")" "{\"sha256\": \"$ARCHIVE_SHA\"}"
  fi
}

stage_archive() {
  local t0 err
  t0=$(now_s)
  log_info "[archive] Decompressing and listing the whole archive..."
  list_archive() { tar -tvf "$AR" -I zstd > "$WORK/listing.txt" 2> "$WORK/listing.err"; }
  if ! run_bg list_archive; then
    err=$(tail -n 3 "$WORK/listing.err" | tr '\n' ' ')
    record_stage "archive" "fail" "$(since "$t0")" "{\"message\": \"The archive is corrupted or truncated\", \"error\": $(jstr "$err")}"
    finish fail
  fi
  # members.tsv: size<TAB>path<TAB>type  (type "-" = regular file or a hardlink to one, "l" = symlink, "o" = other)
  if ! python3 -c '
import sys
rows, sizes = [], {}
for line in open(sys.argv[1], errors="replace"):
    parts = line.rstrip("\n").split(None, 5)
    if len(parts) < 6:
        continue
    t, name, target = parts[0][:1], parts[5], ""
    if t == "d":
        continue
    if t == "h":
        name, _, target = name.partition(" link to ")
    elif t == "l":
        name = name.split(" -> ")[0]
    try:
        size = int(parts[2])
    except ValueError:
        size = -1
    if t == "-":
        sizes[name] = size
    rows.append([t, size, name, target])
with open(sys.argv[2], "w") as out:
    for t, size, name, target in rows:
        if t == "h":
            t, size = ("-", sizes[target]) if target in sizes else ("o", -1)
        elif t not in ("-", "l"):
            t = "o"
        out.write("%d\t%s\t%s\n" % (size, name, t))
' "$WORK/listing.txt" "$WORK/members.tsv"; then
    record_stage "archive" "error" "$(since "$t0")" "Could not read the archive listing"
    finish error
  fi
  local files bytes
  files=$(wc -l < "$WORK/members.tsv"); bytes=$(awk -F'\t' '$1 > 0 {s+=$1} END {print s+0}' "$WORK/members.tsv")
  record_stage "archive" "pass" "$(since "$t0")" "{\"files\": $files, \"uncompressed_bytes\": $bytes}"
}

# One member of the snapshot to stdout, from the tar or from the backup zip inside it
cat_member() {
  if [ "${2:-tar}" = zip ]; then
    python3 -c '
import shutil, sys, zipfile
try:
    with zipfile.ZipFile(sys.argv[1]) as z, z.open(sys.argv[2]) as f:
        shutil.copyfileobj(f, sys.stdout.buffer, 1 << 20)
except BrokenPipeError:
    sys.exit(141)
' "$INNER_ZIP" "$1" 2>/dev/null
  else
    tar -xOf "$AR" -I zstd --occurrence=1 "$1"
  fi
}

# Older snapshots keep dump.sql, manifest.json and filestore/ in backupdata-<service>.zip (Odoo's
# backup format). Copy that zip out of the archive, check every file in it (CRC) and list it.
open_inner_zip() {
  local zbytes free err
  INNER_ZIP_MEMBER=$(awk -F'\t' '$3 == "-" && $2 ~ /(^|\/)backupdata-[^\/]*\.zip$/ {print $2; exit}' "$WORK/members.tsv")
  [ -n "$INNER_ZIP_MEMBER" ] || INNER_ZIP_MEMBER=$(awk -F'\t' '$3 == "-" && $2 ~ /^[^\/]*\.zip$/ {print $2; exit}' "$WORK/members.tsv")
  [ -n "$INNER_ZIP_MEMBER" ] || return 1
  zbytes=$(awk -F'\t' -v n="$INNER_ZIP_MEMBER" '$2 == n {print $1; exit}' "$WORK/members.tsv")
  free=$(free_bytes "$WORK")
  if [[ "$zbytes" =~ ^[0-9]+$ ]] && [ -n "$free" ] && [ $((zbytes + RESERVE_BYTES)) -gt "$free" ]; then
    record_stage "structure" "error" "$(since "$1")" "Not enough disk to unpack $INNER_ZIP_MEMBER ($(human "$zbytes") + reserve $(human "$RESERVE_BYTES") needed, $(human "$free") free)"
    finish error
  fi
  log_info "[structure] Older snapshot format: checking $INNER_ZIP_MEMBER ($(human "${zbytes:-0}")) inside the archive..."
  INNER_ZIP="$WORK/inner.zip"
  copy_zip() { tar -xOf "$AR" -I zstd --occurrence=1 "$INNER_ZIP_MEMBER" > "$INNER_ZIP"; }
  run_bg copy_zip || { record_stage "structure" "fail" "$(since "$1")" "Cannot extract $INNER_ZIP_MEMBER from the archive"; finish fail; }
  # members of the zip, same columns as members.tsv; every file is read once to check its CRC
  check_zip() {
    python3 -c '
import stat, sys, zipfile
try:
    z = zipfile.ZipFile(sys.argv[1])
except Exception as e:
    print("not a valid zip file: %s" % e, file=sys.stderr); sys.exit(2)
with z, open(sys.argv[2], "w") as out:
    for i in z.infolist():
        if i.is_dir():
            continue
        mode = i.external_attr >> 16
        kind = "l" if stat.S_ISLNK(mode) else ("-" if not mode or stat.S_ISREG(mode) else "o")
        out.write("%d\t%s\t%s\n" % (i.file_size, i.filename, kind))
    bad = z.testzip()
    if bad:
        print("corrupted file in the zip: %s" % bad, file=sys.stderr); sys.exit(3)
' "$INNER_ZIP" "$WORK/zip-members.tsv" 2> "$WORK/zip.err"
  }
  if ! run_bg check_zip; then
    err=$(tail -n 2 "$WORK/zip.err" | tr '\n' ' ')
    record_stage "structure" "fail" "$(since "$1")" "{\"message\": $(jstr "$INNER_ZIP_MEMBER is corrupted: ${err:-unreadable}"), \"zip\": $(jstr "$INNER_ZIP_MEMBER")}"
    finish fail
  fi
  CORE_SRC="zip"; CORE_MEMBERS="$WORK/zip-members.tsv"
}

stage_structure() {
  local t0 fs_files fs_bytes missing=()
  t0=$(now_s)
  CORE_MEMBERS="$WORK/members.tsv"
  member() { awk -F'\t' -v n="$1" '$2==n || substr($2, length($2)-length(n)) == "/" n {print $2; exit}' "${2:-$WORK/members.tsv}"; }
  DUMP_MEMBER=$(member dump.sql)
  [ -n "$DUMP_MEMBER" ] || open_inner_zip "$t0" || true
  DUMP_MEMBER=$(member dump.sql "$CORE_MEMBERS")
  MANIFEST_MEMBER=$(member manifest.json "$CORE_MEMBERS")
  GIT_HASHES_MEMBER=$(member git_hashes.json)
  SECRETS_USER_MEMBER=$(member .secrets/db_user)
  FILESTORE_PREFIX=$(awk -F'\t' 'match($2, /(^|\/)filestore\//) {print substr($2, 1, RSTART + RLENGTH - 1); exit}' "$CORE_MEMBERS")
  [ -n "$DUMP_MEMBER" ] || missing+=("dump.sql")
  [ -n "$MANIFEST_MEMBER" ] || missing+=("manifest.json")
  fs_files=0; fs_bytes=0
  if [ -n "$FILESTORE_PREFIX" ]; then
    fs_files=$(awk -F'\t' -v p="$FILESTORE_PREFIX" 'index($2, p) == 1' "$CORE_MEMBERS" | wc -l)
    fs_bytes=$(awk -F'\t' -v p="$FILESTORE_PREFIX" 'index($2, p) == 1 && $1 > 0 {s+=$1} END {print s+0}' "$CORE_MEMBERS")
  fi
  local details="{\"format\": $([ "$CORE_SRC" = zip ] && jstr "older: $INNER_ZIP_MEMBER inside the archive" || jstr "current"), \"dump_sql\": $(jstr "$DUMP_MEMBER"), \"manifest\": $(jstr "$MANIFEST_MEMBER"), \"git_hashes\": $(jstr "$GIT_HASHES_MEMBER"), \"filestore_files\": $fs_files, \"filestore_bytes\": $fs_bytes"
  if [ ${#missing[@]} -gt 0 ]; then
    record_stage "structure" "fail" "$(since "$t0")" "$details, \"message\": $(jstr "Missing from the archive$([ "$CORE_SRC" = zip ] && echo " (and from $INNER_ZIP_MEMBER)"): ${missing[*]}")}"
    finish fail
  fi
  if [ -z "$GIT_HASHES_MEMBER" ] || [ -z "$FILESTORE_PREFIX" ]; then
    record_stage "structure" "warn" "$(since "$t0")" "$details, \"message\": $(jstr "$([ -z "$GIT_HASHES_MEMBER" ] && echo 'no git_hashes.json (repositories cannot be checked)') $([ -z "$FILESTORE_PREFIX" ] && echo 'no filestore in the archive')")}"
  else
    record_stage "structure" "pass" "$(since "$t0")" "$details}"
  fi
}

stage_manifest() {
  local t0 info
  t0=$(now_s)
  cat_member "$MANIFEST_MEMBER" "$CORE_SRC" > "$WORK/manifest.json" 2>/dev/null
  if ! info=$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(m.get("version") or m.get("major_version") or "")
' "$WORK/manifest.json" 2>/dev/null) || [ -z "$info" ]; then
    record_stage "manifest" "fail" "$(since "$t0")" "manifest.json is unreadable or has no Odoo version"
    finish fail
  fi
  ODOO_VERSION="$info"
  record_stage "manifest" "pass" "$(since "$t0")" "{\"odoo_version\": $(jstr "$ODOO_VERSION")}"
}

# git_hashes.json comes from the archive: never let its values reach git as options, and only
# allow the transports production uses (VALIDATOR_GIT_ALLOW_PROTOCOL, default https:ssh).
valid_commit() { [[ "$1" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; }
valid_remote() { [ -n "$1" ] && [[ "$1" != -* ]] && [[ "$1" != *[[:space:][:cntrl:]]* ]]; }
git_safe() {
  GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL="$VALIDATOR_GIT_ALLOW_PROTOCOL" GIT_CONFIG_NOSYSTEM=1 \
  GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15" \
    timeout "$VALIDATOR_GIT_TIMEOUT" git "$@"
}
git_check_commit() {
  # Args: remote commit. Prints found | missing | unreachable
  local remote="$1" commit="$2" tmp
  tmp=$(mktemp -d "$WORK/git.XXXXXX") || { echo unreachable; return; }
  git init -q --bare "$tmp" >/dev/null 2>&1
  if ! git_safe ls-remote -q --heads -- "$remote" >/dev/null 2>&1 \
     && ! git_safe ls-remote -q -- "$remote" >/dev/null 2>&1; then
    echo unreachable
  # Fast path: fetch just that commit (GitHub/GitLab allow fetching reachable commits by id)
  elif git_safe -C "$tmp" fetch -q --depth=1 -- "$remote" "$commit" >/dev/null 2>&1; then
    echo found
  # Slow path: history without file contents, then look for the commit
  elif git_safe -C "$tmp" fetch -q --filter=tree:0 -- "$remote" "+refs/heads/*:refs/heads/*" "+refs/tags/*:refs/tags/*" >/dev/null 2>&1 \
       && git -C "$tmp" cat-file -e "$commit^{commit}" 2>/dev/null; then
    echo found
  else
    echo missing
  fi
  rm -rf "$tmp"
}

stage_git() {
  local t0
  t0=$(now_s)
  if [ "$GIT_CHECK" != true ]; then record_stage "git" "skip" 0 "Disabled with --no-git-check"; return; fi
  if [ -z "$GIT_HASHES_MEMBER" ]; then record_stage "git" "skip" 0 "No git_hashes.json in the archive"; return; fi
  tar -xOf "$AR" -I zstd --occurrence=1 "$GIT_HASHES_MEMBER" > "$WORK/git_hashes.json" 2>/dev/null
  if ! python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
clean = lambda v: str(v or "").replace("\t", " ").replace("\n", " ")
bundled = {b.get("relative_path") for b in d.get("bundled_directories", [])}
for r in d.get("git_repositories", []):
    if r.get("relative_path") in bundled:
        continue
    print("repo\t%s\t%s\t%s" % (clean(r.get("relative_path")), clean(r.get("remote")), clean(r.get("commit"))))
for b in d.get("bundled_directories", []):
    print("bundled\t%s\t%s\t%s" % (clean(b.get("relative_path")), clean(b.get("remote")), clean(b.get("commit"))))
' "$WORK/git_hashes.json" > "$WORK/repos.tsv" 2>/dev/null; then
    record_stage "git" "fail" "$(since "$t0")" "git_hashes.json is unreadable"
    return
  fi

  local kind rel remote commit shown state ok=0 bad=0 unreachable=0 problems=() checked=()
  while IFS=$'\t' read -r kind rel remote commit; do
    [ -n "$rel" ] || continue
    if [ "$kind" = "bundled" ]; then
      if awk -F'\t' -v p="$rel/" 'index($2, p) == 1 || index($2, "/" p) > 0 {found=1; exit} END {exit !found}' "$WORK/members.tsv"; then
        ok=$((ok + 1)); checked+=("$rel: bundled in the snapshot")
      else
        bad=$((bad + 1)); problems+=("$rel: marked as bundled but missing from the archive")
      fi
      continue
    fi
    shown=$(redact "$remote")
    if [ -z "$remote" ] || [ "$remote" = "N/A" ]; then
      bad=$((bad + 1)); problems+=("$rel: no remote and not bundled"); continue
    fi
    if ! valid_remote "$remote"; then
      bad=$((bad + 1)); problems+=("$rel: invalid remote '$shown'"); continue
    fi
    if ! valid_commit "$commit"; then
      bad=$((bad + 1)); problems+=("$rel: invalid or missing commit id '$(printf '%.80s' "$commit")'"); continue
    fi
    log_info "[git] $rel: checking ${commit:0:8} on $shown..."
    run_bg git_check_commit "$remote" "$commit" > "$WORK/git_state" 2>/dev/null
    state=$(cat "$WORK/git_state" 2>/dev/null)
    case "$state" in
      found) ok=$((ok + 1)); checked+=("$rel: ${commit:0:8} found on remote") ;;
      missing) bad=$((bad + 1)); problems+=("$rel: commit ${commit:0:8} is not on $shown") ;;
      *) unreachable=$((unreachable + 1)); problems+=("$rel: cannot reach $shown (network, credentials or VALIDATOR_GIT_ALLOW_PROTOCOL)") ;;
    esac
  done < "$WORK/repos.tsv"

  local details status
  details=$(python3 -c 'import json,sys; p=[x for x in sys.argv[3].split("\n") if x]; print(json.dumps({"message": "; ".join(p) if p else "all repositories recoverable", "ok": int(sys.argv[1]), "problems": p, "checked": [c for c in sys.argv[2].split("\n") if c]}))' \
    "$ok" "$(printf '%s\n' "${checked[@]}")" "$(printf '%s\n' "${problems[@]}")")
  if [ "$bad" -gt 0 ]; then status=fail
  elif [ "$unreachable" -gt 0 ]; then status=error
  else status=pass; fi
  record_stage "git" "$status" "$(since "$t0")" "$details"
}

check_disk() {
  # The restored database lives in a Docker volume; the archive in the work folder.
  # Estimate: the production database size from the manifest (newer snapshots), else a factor of
  # the dump size: a plain SQL dump restores to about 2.5x its size with Odoo's indexes, a
  # compressed custom-format dump to several times more.
  local t0 dump_bytes need_db free_db man_size head5 how
  t0=$(now_s)
  dump_bytes=$(awk -F'\t' -v n="$DUMP_MEMBER" '$2==n {print $1; exit}' "$CORE_MEMBERS")
  [[ "$dump_bytes" =~ ^[0-9]+$ ]] || dump_bytes=0
  man_size=$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
v = ((m.get("sudodevops") or {}).get("postgres") or {}).get("db_size_bytes")
print(int(v) if isinstance(v, (int, float)) and v > 0 else "")
' "$WORK/manifest.json" 2>/dev/null)
  head5=$( { cat_member "$DUMP_MEMBER" "$CORE_SRC" 2>/dev/null || true; } | head -c 5)
  if [ -n "$man_size" ]; then
    need_db=$(( man_size * 6 / 5 )); how="manifest database size x1.2"
  elif [ "$head5" = "PGDMP" ]; then
    need_db=$(( dump_bytes * 6 )); how="custom-format dump x6"
  else
    need_db=$(( dump_bytes * 5 / 2 )); how="plain dump x2.5"
  fi
  free_db=$(free_bytes "$DOCKER_ROOT")
  if [ -n "$free_db" ] && [ $((need_db + RESERVE_BYTES)) -gt "$free_db" ]; then
    record_stage "disk" "error" "$(since "$t0")" "{\"message\": \"Not enough disk for the restored database: need $(human "$need_db") ($how) + reserve $(human "$RESERVE_BYTES"), $(human "$free_db") free in $DOCKER_ROOT\"}"
    finish error
  fi
  record_stage "disk" "pass" "$(since "$t0")" "{\"estimated_db_bytes\": $need_db, \"estimate\": $(jstr "$how"), \"free_bytes\": ${free_db:-0}, \"reserve_bytes\": $RESERVE_BYTES, \"path\": $(jstr "$DOCKER_ROOT")}"
}

pg_major_of_dump() {
  # The throwaway server must understand everything in dump.sql: use the newer of the version
  # the database ran ("Dumped from") and the pg_dump that wrote it ("Dumped by"), which can be
  # newer and emit newer syntax. The manifest (newer snapshots) can raise it further.
  local head v_from v_by v_man best=0 v
  head=$( { cat_member "$DUMP_MEMBER" "$CORE_SRC" 2>/dev/null || true; } | head -c 65536 | tr -d '\0')
  v_from=$(grep -a -m1 -o 'Dumped from database version [0-9.]*' <<< "$head" | awk '{print $NF}')
  v_by=$(grep -a -m1 -o 'Dumped by pg_dump version [0-9.]*' <<< "$head" | awk '{print $NF}')
  v_man=$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(((m.get("sudodevops") or {}).get("postgres") or {}).get("server_version", ""))
' "$WORK/manifest.json" 2>/dev/null)
  for v in "$v_from" "$v_by" "$v_man"; do
    v="${v%%.*}"
    [[ "$v" =~ ^[0-9]{1,3}$ ]] && [ "$v" -gt "$best" ] && best="$v"
  done
  [ "$best" -gt 0 ] && echo "$best"
}

pg_exec() { docker exec -i "$PG_CONTAINER" psql -U postgres -X -v ON_ERROR_STOP=1 "$@"; }
pg_query() { docker exec "$PG_CONTAINER" psql -U postgres -X -tA -F $'\t' -d "$1" -c "$2" 2>/dev/null; }
# Over TCP: the image's temporary init server only listens on the socket, so a socket check
# can succeed just before that server shuts down again.
pg_alive() { docker exec "$PG_CONTAINER" pg_isready -h 127.0.0.1 -U postgres -q >/dev/null 2>&1; }

restore_plain() {
  # Streams dump.sql into psql (stops at the first SQL error) and keeps its last 8 KiB, so the
  # end-of-dump marker can prove the dump is complete.
  cat_member "$DUMP_MEMBER" "$CORE_SRC" \
    | tee >(tail -c 8192 > "$WORK/dump.tail") \
    | docker exec -i "$PG_CONTAINER" psql -U postgres -X -v ON_ERROR_STOP=1 -q -d "$1" -o /dev/null > /dev/null 2> "$WORK/restore.log"
  local rc=$?
  wait $! 2>/dev/null
  return $rc
}
restore_custom() {
  cat_member "$DUMP_MEMBER" "$CORE_SRC" \
    | docker exec -i "$PG_CONTAINER" pg_restore -U postgres -d "$1" --no-owner --exit-on-error > /dev/null 2> "$WORK/restore.log"
}

stage_database() {
  local t0 major pg_pass db_user dbname head5 rc stats verdict
  t0=$(now_s)
  major=$(pg_major_of_dump)
  PG_IMAGE="${VALIDATOR_POSTGRES_IMAGE:-postgres:${major:-16}}"
  # Refresh the tag on every drill: an old cached postgres:N can be too old for newer dumps
  if [ "$VALIDATOR_PULL_POLICY" = always ] || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
    log_info "[database] Pulling $PG_IMAGE..."
    if ! run_bg docker pull -q "$PG_IMAGE" >/dev/null 2>&1; then
      if docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
        log_warn "[database] Could not refresh $PG_IMAGE; using the copy already on this host."
        PULL_WARNING="could not refresh $PG_IMAGE, used the cached copy"
      else
        record_stage "database" "error" "$(since "$t0")" "Could not pull $PG_IMAGE"
        finish error
      fi
    fi
  fi

  # Internal network: the drill containers cannot reach anything outside the host
  docker network create --internal --label odoo-drill="$RUN_ID" "$DRILL_NET" >/dev/null 2>&1 \
    || { record_stage "database" "error" "$(since "$t0")" "Could not create Docker network $DRILL_NET"; finish error; }
  pg_pass=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
  log_info "[database] Starting throwaway $PG_IMAGE container..."
  # The drill's database is thrown away, so durability is switched off to spare the disk, and the
  # container is the first thing the kernel kills under memory pressure (never a snapshot job).
  if ! docker run -d --name "$PG_CONTAINER" --label odoo-drill="$RUN_ID" --network "$DRILL_NET" \
       --cpus "$VALIDATOR_PG_CPUS" --memory "$VALIDATOR_PG_MEMORY" --memory-swap "$VALIDATOR_PG_MEMORY" \
       --oom-score-adj 1000 --pids-limit 512 \
       -e POSTGRES_PASSWORD="$pg_pass" -e PGDATA=/var/lib/postgresql/data/pgdata \
       --mount type=volume,dst=/var/lib/postgresql/data "$PG_IMAGE" \
       -c fsync=off -c synchronous_commit=off -c full_page_writes=off \
       -c wal_level=minimal -c max_wal_senders=0 -c max_wal_size=4GB -c checkpoint_timeout=30min \
       -c autovacuum=off >/dev/null 2>&1; then
    record_stage "database" "error" "$(since "$t0")" "Could not start $PG_IMAGE"
    finish error
  fi
  local i
  for i in $(seq 120); do pg_alive && break; sleep 1; done
  pg_alive || { record_stage "database" "error" "$(since "$t0")" "Postgres did not become ready"; finish error; }

  # Same role name as production, so GRANTs in the dump apply (the dump has no owners)
  db_user=""
  [ -n "$SECRETS_USER_MEMBER" ] && db_user=$(tar -xOf "$AR" -I zstd --occurrence=1 "$SECRETS_USER_MEMBER" 2>/dev/null | tr -d '[:space:]')
  db_user="${db_user:-odoo}"
  dbname="drill_$(tr -c 'a-zA-Z0-9_\n' '_' <<< "$SERVICE" | head -c 40)"
  local role_sql
  role_sql=$(python3 -c '
import sys
q = "\"" + sys.argv[1].replace("\"", "\"\"") + "\""
sq = chr(39)
lit = sq + sys.argv[1].replace(sq, sq + sq) + sq
print("DO $do$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = %s) THEN CREATE ROLE %s NOLOGIN; END IF; END $do$;" % (lit, q))
' "$db_user")
  if ! pg_exec -q -d postgres -c "$role_sql" >/dev/null 2>"$WORK/role.err"; then
    record_stage "database" "error" "$(since "$t0")" "Could not create role $db_user: $(tr '\n' ' ' < "$WORK/role.err")"
    finish error
  fi
  pg_exec -q -d postgres -c "CREATE DATABASE \"$dbname\";" >/dev/null 2>"$WORK/createdb.err" \
    || { record_stage "database" "error" "$(since "$t0")" "CREATE DATABASE failed: $(tr '\n' ' ' < "$WORK/createdb.err")"; finish error; }

  log_info "[database] Restoring $DUMP_MEMBER (stops at the first SQL error)..."
  head5=$( { cat_member "$DUMP_MEMBER" "$CORE_SRC" 2>/dev/null || true; } | head -c 5)
  if [ "$head5" = "PGDMP" ]; then
    run_bg restore_custom "$dbname"; rc=$?
  else
    run_bg restore_plain "$dbname"; rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    if ! pg_alive; then
      # The server went away (out of memory, killed): that says nothing about the snapshot
      record_stage "database" "error" "$(since "$t0")" "{\"message\": \"The drill's Postgres stopped during the restore (exit $rc); the snapshot was not judged\", \"error\": $(jstr "$(grep -a -m5 -E 'ERROR|FATAL|terminat' "$WORK/restore.log" | tr '\n' ' ' | cut -c1-1500)")}"
      finish error
    fi
    record_stage "database" "fail" "$(since "$t0")" "{\"message\": \"dump.sql did not restore cleanly (exit $rc)\", \"error\": $(jstr "$(grep -a -m5 -E 'ERROR|FATAL' "$WORK/restore.log" | tr '\n' ' ' | cut -c1-1500)")}"
    finish fail
  fi
  if [ "$head5" != "PGDMP" ] && ! grep -aq -- '-- PostgreSQL database dump complete' "$WORK/dump.tail" 2>/dev/null; then
    record_stage "database" "fail" "$(since "$t0")" "dump.sql is incomplete: it restored without errors but its end-of-dump marker is missing (the dump was cut off)"
    finish fail
  fi

  stats=$(python3 -c '
import json, sys
keys = ["tables", "modules_installed", "base_version", "users", "partners", "attachments_stored",
        "indexes", "constraints", "missing_core_tables"]
out = {}
for k, v in zip(keys, sys.argv[1:]):
    v = v.strip()
    out[k] = int(v) if v.isdigit() else (v or None)
print(json.dumps(out))
' "$(pg_query "$dbname" "SELECT count(*) FROM pg_tables WHERE schemaname='public'")" \
  "$(pg_query "$dbname" "SELECT count(*) FROM ir_module_module WHERE state='installed'")" \
  "$(pg_query "$dbname" "SELECT latest_version FROM ir_module_module WHERE name='base' AND state='installed'")" \
  "$(pg_query "$dbname" "SELECT count(*) FROM res_users")" \
  "$(pg_query "$dbname" "SELECT count(*) FROM res_partner")" \
  "$(pg_query "$dbname" "SELECT count(*) FROM ir_attachment WHERE store_fname IS NOT NULL AND store_fname <> ''")" \
  "$(pg_query "$dbname" "SELECT count(*) FROM pg_indexes WHERE schemaname='public'")" \
  "$(pg_query "$dbname" "SELECT count(*) FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace WHERE n.nspname='public' AND c.contype IN ('p','f','u')")" \
  "$(pg_query "$dbname" "SELECT string_agg(t, ',') FROM unnest(ARRAY['ir_module_module','ir_model','res_users','res_partner','res_company','ir_attachment']) t WHERE to_regclass('public.' || t) IS NULL")")
  [ -n "$stats" ] && DB_STATS="$stats"
  verdict=$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("Could not read the restored database"); sys.exit()
problems = []
if d.get("missing_core_tables"): problems.append("core Odoo tables missing: %s" % d["missing_core_tables"])
if not d.get("base_version"): problems.append("module base is not installed")
for k, label in (("modules_installed", "installed modules"), ("users", "users"), ("partners", "partners"),
                 ("indexes", "indexes"), ("constraints", "primary/foreign/unique keys")):
    if not isinstance(d.get(k), int) or d[k] <= 0:
        problems.append("no %s" % label)
print("; ".join(problems) if problems else "ok")
' "$stats")
  if [ "$verdict" != "ok" ]; then
    record_stage "database" "fail" "$(since "$t0")" "$(python3 -c 'import json,sys
try: d=json.loads(sys.argv[1])
except Exception: d={}
d["message"]="Restored, but not a usable Odoo database: " + sys.argv[2]; print(json.dumps(d))' "$stats" "${verdict:-unknown}")"
    finish fail
  fi
  record_stage "database" "$([ -n "$PULL_WARNING" ] && echo warn || echo pass)" "$(since "$t0")" "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d["image"]=sys.argv[2]; d["restore_warnings"]=int(sys.argv[3] or 0)
if sys.argv[4]: d["message"]=sys.argv[4]
print(json.dumps(d))' "$stats" "$PG_IMAGE" "$(grep -a -c 'WARNING' "$WORK/restore.log" || true)" "$PULL_WARNING")"
  echo "$dbname" > "$WORK/dbname"
}

stage_filestore() {
  local t0 dbname result status
  t0=$(now_s)
  dbname=$(cat "$WORK/dbname")
  if ! docker exec "$PG_CONTAINER" psql -U postgres -X -tA -F $'\t' -d "$dbname" \
       -c "SELECT store_fname, COALESCE(file_size, -1) FROM ir_attachment WHERE store_fname IS NOT NULL AND store_fname <> '' GROUP BY store_fname, file_size" \
       > "$WORK/expected.tsv" 2>/dev/null; then
    record_stage "filestore" "error" "$(since "$t0")" "Could not read ir_attachment"
    finish error
  fi
  if ! result=$(python3 -c '
import json, sys
expected_file, members_file, prefix, max_pct = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
present, not_regular = {}, set()
if prefix:
    for line in open(members_file, errors="replace"):
        size, path, kind = (line.rstrip("\n").split("\t") + ["", "", ""])[:3]
        if not path.startswith(prefix):
            continue
        rel = path[len(prefix):]
        if kind == "-":
            present[rel] = int(size)
        else:
            not_regular.add(rel)
expected = {}
for line in open(expected_file, errors="replace"):
    if not line.strip():
        continue
    fname, _, size = line.rstrip("\n").partition("\t")
    expected[fname] = int(size) if size.lstrip("-").isdigit() else -1
missing = sorted(f for f in expected if f not in present)
wrong_size = sorted(f for f, s in expected.items() if f in present and s >= 0 and present[f] != s)
total = len(expected)
bad = len(missing) + len(wrong_size)
pct = (100.0 * bad / total) if total else 0.0
status = "fail" if pct > max_pct else ("warn" if bad else "pass")
msg = "%d of %d stored attachments missing and %d with the wrong size (%.2f%% bad, limit %s%%)" % (
    len(missing), total, len(wrong_size), pct, sys.argv[4])
print(status)
print(json.dumps({"message": msg, "attachments": total, "files_in_archive": len(present), "missing": len(missing),
                  "wrong_size": len(wrong_size), "not_regular_files": len(not_regular), "bad_pct": round(pct, 2),
                  "examples_missing": missing[:20], "examples_wrong_size": wrong_size[:20], "max_bad_pct": max_pct}))
' "$WORK/expected.tsv" "$CORE_MEMBERS" "$FILESTORE_PREFIX" "$VALIDATOR_FILESTORE_MAX_MISSING_PCT"); then
    record_stage "filestore" "fail" "$(since "$t0")" "The filestore check crashed; the filestore was not verified"
    finish fail
  fi
  status=$(head -n1 <<< "$result")
  record_stage "filestore" "$status" "$(since "$t0")" "$(tail -n +2 <<< "$result")"
  [ "$status" = "pass" ] || [ "$status" = "warn" ] || finish fail
}

publish_result() {
  local t0 rec current checks git_status
  t0=$(now_s)
  rec="$WORK/validated.json"
  # A record must say what was really proven. The git check is mandatory for a record: without it,
  # nobody knows whether the code this database needs can still be restored.
  checks=$(python3 -c '
import json, sys
print(json.dumps({s["name"]: s["status"] for s in map(json.loads, filter(str.strip, open(sys.argv[1])))
                  if s["name"] not in ("publish", "revoke", "fetch", "disk")}))' "$STAGES_FILE")
  git_status=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("git", ""))' "$checks")
  if [ "$git_status" != pass ]; then
    record_stage "publish" "error" "$(since "$t0")" "Not publishing: the git check did not run (status '${git_status:-none}'), so this drill does not prove the snapshot's code can be restored"
    return
  fi
  if ! snap_write_validation_record "$rec" "$ARCHIVE_NAME" "$ARCHIVE_SHA" \
      "{\"level\": \"database\", \"run_id\": \"$RUN_ID\", \"checks\": $checks, \"odoo_version\": $(jstr "$ODOO_VERSION"), \"postgres_image\": $(jstr "$PG_IMAGE"), \"drill_seconds\": $(( $(date +%s) - START_EPOCH ))$([ -n "$GCS_GENERATION" ] && echo ", \"gcs_generation\": \"$GCS_GENERATION\""), \"database\": $DB_STATS}"; then
    record_stage "publish" "error" "$(since "$t0")" "Could not write the validation record"
    return
  fi
  chmod 644 "$rec" 2>/dev/null
  case "$SOURCE_KIND" in
    drive)
      DRIVE_TOKEN=$(gds_get_token "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_SERVICE_ACCOUNT_KEY")
      if gds_publish_validation "$DRIVE_TOKEN" "$GDRIVE_FOLDER_ID" "$ARCHIVE_NAME" "$rec" >/dev/null; then
        PUBLISHED=yes; record_stage "publish" "pass" "$(since "$t0")" "Uploaded $ARCHIVE_NAME.validated.json to Google Drive"
      else
        record_stage "publish" "error" "$(since "$t0")" "Drill passed but $ARCHIVE_NAME.validated.json could not be uploaded"
      fi ;;
    gcs)
      current=$(gcloud storage objects describe "$SOURCE_REF" --format='value(generation)' 2>/dev/null)
      if [ "$current" != "$GCS_GENERATION" ]; then
        record_stage "publish" "error" "$(since "$t0")" "$(redact "$SOURCE_REF") was replaced during the drill (generation $GCS_GENERATION -> ${current:-gone}); not publishing a record for bytes that are no longer there"
      elif gcs_publish_validation "$SOURCE_REF" "$rec"; then
        PUBLISHED=yes; record_stage "publish" "pass" "$(since "$t0")" "Uploaded $(redact "$SOURCE_REF").validated.json (generation $GCS_GENERATION)"
      else
        record_stage "publish" "error" "$(since "$t0")" "Drill passed but $(redact "$SOURCE_REF").validated.json could not be uploaded"
      fi ;;
    file)
      if [ "$(stat -L -c '%d:%i' "$ARCHIVE" 2>/dev/null)" != "$(stat -L -c '%d:%i' "$AR" 2>/dev/null)" ]; then
        record_stage "publish" "error" "$(since "$t0")" "$ARCHIVE was replaced during the drill; not publishing a record for a file that was not drilled"
      elif cp "$rec" "$ARCHIVE.validated.json" 2>/dev/null; then
        PUBLISHED=yes; record_stage "publish" "pass" "$(since "$t0")" "Wrote $ARCHIVE.validated.json"
      else
        record_stage "publish" "error" "$(since "$t0")" "Could not write $ARCHIVE.validated.json"
      fi ;;
  esac
}

# --- Drill ---
fetch_snapshot
stage_checksum
stage_archive
stage_structure
stage_manifest
stage_git
check_disk
stage_database
stage_filestore

if [ "$FAILED" -gt 0 ]; then
  finish fail
fi
if [ "$ERRORS" -gt 0 ]; then
  finish error
fi
if [ "$PUBLISH" = true ]; then
  publish_result
fi
finish pass
