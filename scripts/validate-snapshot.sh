#!/usr/bin/env bash
set -o pipefail
# Category: Utility
# Description: Restore drill for an Odoo snapshot in throwaway containers, proving it can be recovered (checksum, archive, manifest, git, database restore, filestore, then Odoo itself boots on the restored copy).
# Usage: ./scripts/validate-snapshot.sh (--file PATH | --drive SERVICE [--name FILE] | --gcs gs://BUCKET/OBJECT | --inbox SERVICE) [--publish] [options]
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
#   8. code       odoo-base and every repository checked out at its recorded commit (bundled
#                 folders from the archive)
#   9. image      the deployment's Odoo image: pulled from its registry (ODOO_IMAGE_NAME in the
#                 snapshot's .env, with its pull key) or built from dockerfile.example + the
#                 snapshot's requirements.txt (else odoo-base's), cached by the hash of its inputs
#  10. boot       the restored database is neutralized, then Odoo starts on it (no cron, no
#                 workers, no queue_job runner, still no outbound network): the registry loads,
#                 every installed module is found and loads, and /web/login answers 200.
#                 Other ERROR/CRITICAL lines are warnings (VALIDATOR_BOOT_STRICT=true: failures).
#                 --no-boot (or VALIDATOR_BOOT=false) stops after the filestore stage.
# The result is written as a JSON report. With --publish, a passed drill uploads
# <archive>.validated.json next to the snapshot (retention then protects that snapshot), and a
# FAILED drill removes an existing one.
# --inbox drills the snapshot the snapshot tool handed to the validator inbox on the drill host
# (SNAPSHOT_VALIDATOR_INBOX), without downloading it, and records the result next to its uploaded
# copy. The drill worker (validate-snapshot-worker.sh) uses it, and --unless-checksum to skip a
# snapshot the last drill already proved.
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
#   5          nothing to drill: no snapshot waiting in the inbox (--inbox), or the snapshot is the
#              one --unless-checksum names. No report is written.

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
VALIDATOR_BOOT=$(cfg VALIDATOR_BOOT true)
VALIDATOR_BOOT_STRICT=$(cfg VALIDATOR_BOOT_STRICT false)
VALIDATOR_BOOT_TIMEOUT=$(cfg VALIDATOR_BOOT_TIMEOUT 900)
VALIDATOR_BUILD_TIMEOUT=$(cfg VALIDATOR_BUILD_TIMEOUT 3600)
VALIDATOR_ODOO_MEMORY=$(cfg VALIDATOR_ODOO_MEMORY 2g)
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
UNLESS_SHA=""

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
  --inbox <SERVICE>        The snapshot of SERVICE waiting in the validator inbox on the drill
                           host (~/.odoo-validator/inbox, SNAPSHOT_VALIDATOR_INBOX); --publish
                           records the result next to its copy on Drive, GCS or the drill host

Options:
  --publish                On pass, upload <archive>.validated.json next to the snapshot
                           (Drive/GCS) or write it next to a local --file; on fail, remove it
  --report <PATH>          Where to write the JSON report (default: $VALIDATOR_DIR/reports/)
  --keep-workdir           Keep the work folder for inspection (containers are always removed)
  --no-git-check           Skip the git repository check (the boot check needs it, so it is skipped too)
  --no-boot                Stop after the filestore stage: do not start Odoo (VALIDATOR_BOOT=false)
  --unless-checksum <SHA>  Do nothing (exit 5) when the snapshot's .sha256 file names this sha256,
                           i.e. it is the snapshot an earlier drill already proved (read before
                           anything is downloaded; not with --inbox)
  --local                  Drill on this host even when SNAPSHOT_REMOTE_HOST is set
  --folder-id <ID>         Google Drive folder ID (default: GDRIVE_FOLDER_ID)
  --sa-key <PATH>          Google Drive service account key (default: GDRIVE_SERVICE_ACCOUNT_KEY)
  --token <TOKEN>          Google Drive access token (default: GDRIVE_ACCESS_TOKEN)
  -h, --help               Show this help

Settings (environment or .env): VALIDATOR_WORK_DIR, VALIDATOR_DISK_RESERVE_GB,
VALIDATOR_WATCHDOG_INTERVAL, VALIDATOR_POSTGRES_IMAGE, VALIDATOR_PG_CPUS, VALIDATOR_PG_MEMORY,
VALIDATOR_FILESTORE_MAX_MISSING_PCT, VALIDATOR_QUEUE_TIMEOUT, VALIDATOR_GIT_TIMEOUT,
VALIDATOR_GIT_ALLOW_PROTOCOL, VALIDATOR_PULL_POLICY, VALIDATOR_REMOTE_WORK_DIR, VALIDATOR_BOOT,
VALIDATOR_BOOT_STRICT, VALIDATOR_BOOT_TIMEOUT, VALIDATOR_BUILD_TIMEOUT, VALIDATOR_ODOO_MEMORY.
Prefer GDRIVE_SERVICE_ACCOUNT_KEY in .env over --token: command-line arguments are visible to
other users of this host.

Exit codes: 0 passed, 1 snapshot broken, 2 could not finish (nothing proven),
3 usage or configuration error, 4 passed but the --publish record could not be written,
5 nothing to drill (empty inbox, or --unless-checksum matched; no report).
EOF
}

need_value() { if [ -z "${2:-}" ] || [[ "$2" == --* ]]; then log_error "$1 needs a value."; exit 3; fi; }
while [ $# -gt 0 ]; do
  case "$1" in
    --file) need_value "$1" "${2:-}"; SOURCE_KIND=file; SOURCE_REF="$2"; shift 2 ;;
    --drive) need_value "$1" "${2:-}"; SOURCE_KIND=drive; SOURCE_REF="$2"; shift 2 ;;
    --name) need_value "$1" "${2:-}"; DRIVE_NAME="$2"; shift 2 ;;
    --gcs) need_value "$1" "${2:-}"; SOURCE_KIND=gcs; SOURCE_REF="$2"; shift 2 ;;
    --inbox) need_value "$1" "${2:-}"; SOURCE_KIND=inbox; SOURCE_REF="$2"; shift 2 ;;
    --unless-checksum) need_value "$1" "${2:-}"; UNLESS_SHA="$2"; shift 2 ;;
    --publish) PUBLISH=true; shift ;;
    --report) need_value "$1" "${2:-}"; REPORT_PATH="$2"; shift 2 ;;
    --keep-workdir) KEEP_WORKDIR=true; shift ;;
    --no-git-check) GIT_CHECK=false; shift ;;
    --no-boot) VALIDATOR_BOOT=false; shift ;;
    --local) LOCAL_ONLY=true; shift ;;
    --folder-id) need_value "$1" "${2:-}"; GDRIVE_FOLDER_ID="$2"; shift 2 ;;
    --sa-key) need_value "$1" "${2:-}"; GDRIVE_SERVICE_ACCOUNT_KEY="$2"; shift 2 ;;
    --token) need_value "$1" "${2:-}"; GDRIVE_ACCESS_TOKEN="$2"; shift 2 ;;
    -h|--help) show_help; exit 0 ;;
    *) log_error "Unknown option: $1"; show_help; exit 3 ;;
  esac
done

if [ -z "$SOURCE_KIND" ] || [ -z "$SOURCE_REF" ]; then
  log_error "Choose a snapshot with --file, --drive, --gcs or --inbox."
  show_help
  exit 3
fi
if [ "$SOURCE_KIND" = gcs ] && [[ "$SOURCE_REF" != gs://* ]]; then
  log_error "--gcs needs a gs://BUCKET/OBJECT URL."
  exit 3
fi
if [ "$SOURCE_KIND" = inbox ] && ! [[ "$SOURCE_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  log_error "--inbox needs a service name (letters, digits, '.', '_' and '-')."
  exit 3
fi
if [ -n "$UNLESS_SHA" ]; then
  if ! [[ "$UNLESS_SHA" =~ ^[0-9a-f]{64}$ ]]; then
    log_error "--unless-checksum needs a sha256 (64 lowercase hex characters)."
    exit 3
  fi
  if [ "$SOURCE_KIND" = inbox ]; then
    log_error "--unless-checksum does not apply to --inbox (an inbox snapshot is always a new one)."
    exit 3
  fi
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
[[ "$VALIDATOR_BOOT" =~ ^(true|false)$ ]] || bad_settings+=("VALIDATOR_BOOT='$VALIDATOR_BOOT' (true or false)")
[[ "$VALIDATOR_BOOT_STRICT" =~ ^(true|false)$ ]] || bad_settings+=("VALIDATOR_BOOT_STRICT='$VALIDATOR_BOOT_STRICT' (true or false)")
[[ "$VALIDATOR_BOOT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || bad_settings+=("VALIDATOR_BOOT_TIMEOUT='$VALIDATOR_BOOT_TIMEOUT' (seconds)")
[[ "$VALIDATOR_BUILD_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || bad_settings+=("VALIDATOR_BUILD_TIMEOUT='$VALIDATOR_BUILD_TIMEOUT' (seconds)")
[[ "$VALIDATOR_ODOO_MEMORY" =~ ^[0-9]+[bkmgBKMG]?$ ]] || bad_settings+=("VALIDATOR_ODOO_MEMORY='$VALIDATOR_ODOO_MEMORY' (e.g. 2g)")
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
  [ "$SOURCE_KIND" = drive ] || [ "$SOURCE_KIND" = inbox ] || svc=$(sed -E 's/^snapshot-(.+)-[0-9]{8}-[0-9]{6}\.tar\.zst$/\1/; s/^snapshot-(.+)\.tar\.zst$/\1/' <<< "${SOURCE_REF##*/}")
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
  # An inbox snapshot uploaded to Drive gets its record there too
  if [ "$SOURCE_KIND" = drive ] || { [ "$SOURCE_KIND" = inbox ] && [ "$PUBLISH" = true ]; }; then
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
    inbox) fwd+=(--inbox "$SOURCE_REF") ;;
  esac
  [ -n "$UNLESS_SHA" ] && fwd+=(--unless-checksum "$UNLESS_SHA")
  [ "$PUBLISH" = true ] && fwd+=(--publish)
  [ "$KEEP_WORKDIR" = true ] && fwd+=(--keep-workdir)
  [ "$GIT_CHECK" = true ] || fwd+=(--no-git-check)
  [ "$VALIDATOR_BOOT" = true ] || fwd+=(--no-boot)

  local exports="" v
  # Settings as configured here (auto values such as VALIDATOR_PG_CPUS are worked out on the Secondary VPS)
  for v in VALIDATOR_DISK_RESERVE_GB VALIDATOR_WATCHDOG_INTERVAL VALIDATOR_POSTGRES_IMAGE VALIDATOR_PG_CPUS \
           VALIDATOR_PG_MEMORY VALIDATOR_FILESTORE_MAX_MISSING_PCT VALIDATOR_QUEUE_TIMEOUT VALIDATOR_GIT_TIMEOUT \
           VALIDATOR_GIT_ALLOW_PROTOCOL VALIDATOR_PULL_POLICY VALIDATOR_BOOT_STRICT VALIDATOR_BOOT_TIMEOUT \
           VALIDATOR_BUILD_TIMEOUT VALIDATOR_ODOO_MEMORY GDRIVE_FOLDER_ID; do
    exports+="export $v=$(printf '%q' "${!v}")"$'\n'
  done
  for v in QUEUE_LOCK_STALE_AFTER QUEUE_LOCK_POLL_INTERVAL GDS_API_BASE; do
    [ -n "${!v:-}" ] && exports+="export $v=$(printf '%q' "${!v}")"$'\n'
  done

  local payload bootf bfd out rc
  # dockerfile.example travels as lib/dockerfile.example: the boot check builds the drill's Odoo image from it
  local dockerfile_src="$PATH_TO_ODOO/dockerfile.example"
  [ -f "$dockerfile_src" ] || dockerfile_src="$CURRENT_DIR/lib/dockerfile.example"
  local tar_args=(-C "$CURRENT_DIR" -cf - validate-snapshot.sh lib/queue_lock.sh lib/snapshot_storage.sh)
  [ -f "$dockerfile_src" ] && tar_args+=(-C "$(dirname "$dockerfile_src")" '--transform=s|^dockerfile\.example$|lib/dockerfile.example|' dockerfile.example)
  payload=$(tar "${tar_args[@]}" | base64 -w0) \
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
    5) exit 5 ;;   # nothing to drill (the reason is in the log above); not a drill, so no report
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
ODOO_CONTAINER="$DRILL_NAME-odoo"
NEUTRALIZE_CONTAINER="$DRILL_NAME-neutralize"
BOOT_DIR="$WORK/boot"
DRILL_LEVEL="database"   # "boot" once Odoo itself started on the restored copy
BOOT_IMAGE=""
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
ODOO_VERSION="" MANIFEST_ODOO_VERSION="" PG_IMAGE="" WATCHDOG_PID="" CHILD_PID="" ABORT_REASON="" RESULT=""
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
  docker rm -fv "$ODOO_CONTAINER" "$NEUTRALIZE_CONTAINER" >/dev/null 2>&1
  docker rm -fv "$PG_CONTAINER" >/dev/null 2>&1
  docker network rm "$DRILL_NET" >/dev/null 2>&1
  # (a plain "exec ... 2>/dev/null" would send every later line of the log to /dev/null)
  [ -n "$ARCHIVE_FD" ] && { exec {ARCHIVE_FD}<&-; } 2>/dev/null
  declare -f inbox_dispose >/dev/null && inbox_dispose
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
 duration, odoo_version, pg_image, db_stats, gcs_gen, published, level, odoo_image) = sys.argv[1:19]
stages = [json.loads(l) for l in open(stages_file) if l.strip()]
try:
    db = json.loads(db_stats or "{}")
except Exception:
    db = {}
report = {"schema": 1, "level": level, "result": result, "service": service,
          "archive": archive, "source": {"kind": source_kind, "ref": source_ref, "gcs_generation": gcs_gen or None},
          "sha256": sha or None, "started_at": started, "finished_at": finished,
          "duration_seconds": int(float(duration)), "odoo_version": odoo_version or None,
          "postgres_image": pg_image or None, "odoo_image": odoo_image or None, "database": db,
          "record_published": published or None,
          "stages": stages}
with open(out, "w") as f:
    json.dump(report, f, indent=2); f.write("\n")
' "$STAGES_FILE" "$REPORT_PATH" "$RESULT" "$SERVICE" "$ARCHIVE_NAME" "$SOURCE_KIND" "$(redact "$SOURCE_REF")" \
    "$ARCHIVE_SHA" "$STARTED_AT" "$finished" "$(( $(date +%s) - START_EPOCH ))" "$ODOO_VERSION" "$PG_IMAGE" "$DB_STATS" \
    "$GCS_GENERATION" "$PUBLISHED" "$DRILL_LEVEL" "$BOOT_IMAGE"
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
    inbox)
      # Only records that belong to this very snapshot: never those of a newer one that replaced a copy
      if [ -n "$JOB_DRIVE_ID" ]; then
        DRIVE_TOKEN=$(gds_get_token "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_SERVICE_ACCOUNT_KEY")
        while id=$(gds_find_by_name "$DRIVE_TOKEN" "$GDRIVE_FOLDER_ID" "${JOB_DRIVE_NAME:-$ARCHIVE_NAME}.validated.json") && [ -n "$id" ]; do
          gds_delete_file "$DRIVE_TOKEN" "$id" "$GDRIVE_FOLDER_ID" >/dev/null || { record_stage "revoke" "error" "$(since "$t0")" "Could not remove the old ${JOB_DRIVE_NAME:-$ARCHIVE_NAME}.validated.json from Google Drive. Delete it by hand."; return; }
          ids="yes"
        done
      fi
      if [ -n "$JOB_GCS_OBJECT" ] && [ -n "$JOB_GCS_GEN" ] \
         && [ "$(gcloud storage objects describe "$JOB_GCS_OBJECT" --format='value(generation)' 2>/dev/null)" = "$JOB_GCS_GEN" ] \
         && gcloud storage ls "$JOB_GCS_OBJECT.validated.json" >/dev/null 2>&1; then
        gcloud storage rm "$JOB_GCS_OBJECT.validated.json" >/dev/null 2>&1 && ids="yes" \
          || { record_stage "revoke" "error" "$(since "$t0")" "Could not remove the old $(redact "$JOB_GCS_OBJECT").validated.json. Delete it by hand."; return; }
      fi
      if [ -n "$JOB_KEPT" ] && [ -f "$JOB_KEPT.validated.json" ] \
         && [ "$(stat -L -c '%d:%i' "$JOB_KEPT" 2>/dev/null)" = "$(stat -L -c '%d:%i' "$AR" 2>/dev/null)" ]; then
        rm -f "$JOB_KEPT.validated.json" && ids="yes"
      fi ;;
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
DOCKER_ROOT=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)
[ -d "$DOCKER_ROOT" ] || DOCKER_ROOT="/var/lib/docker"
# The reserve keeps room for snapshots: VALIDATOR_DISK_RESERVE_GB, or more when a remote snapshot staged on
# this disk recently needed more (its ~/.odoo-snapshots/<service>/stats.json, written by the snapshot tool)
RESERVE_INFO=$(snap_disk_reserve_bytes "$VALIDATOR_DISK_RESERVE_GB" "$HOME/.odoo-snapshots" "$VALIDATOR_DIR" "$DOCKER_ROOT")
RESERVE_BYTES=${RESERVE_INFO%% *}
RESERVE_FROM=${RESERVE_INFO#* }
case "$RESERVE_FROM" in
  stats:*) RESERVE_FROM="snapshot stats of ${RESERVE_FROM#stats:}"
           log_info "Disk reserve: $(human "$RESERVE_BYTES"), the room the last snapshot of ${RESERVE_FROM#snapshot stats of } took on this disk (+25%, from its stats.json), more than VALIDATOR_DISK_RESERVE_GB=$VALIDATOR_DISK_RESERVE_GB." ;;
  off) RESERVE_FROM="off (VALIDATOR_DISK_RESERVE_GB=0)" ;;
  *) RESERVE_FROM="VALIDATOR_DISK_RESERVE_GB" ;;
esac

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
          docker rm -fv "$ODOO_CONTAINER" "$NEUTRALIZE_CONTAINER" >/dev/null 2>&1
          docker rm -fv "$PG_CONTAINER" >/dev/null 2>&1
          kill -TERM "$main_pid" 2>/dev/null
          exit 0
        fi
      done
    done
  ) </dev/null >/dev/null 2>&1 &
  WATCHDOG_PID=$!
}

# --- Validator inbox (--inbox): the snapshot the snapshot tool left for a drill on this host ---
# Layout and hand-off: snap_inbox_handoff in scripts/lib/snapshot_storage.sh. A drill takes a job by renaming
# its folder to .taken-<archive>-<pid> in the same folder (one rename on the same disk; the snapshot tool never
# touches a folder starting with "."). After a pass or a fail the job is deleted. After an error it goes back
# to the inbox for the next try, unless a newer snapshot is waiting by then. A job whose drill was killed is
# handled the same way by the next drill of that service.
INBOX_DIR="" INBOX_TAKEN="" INBOX_NAME="" INBOX_BROKEN=""
JOB_DRIVE_NAME="" JOB_DRIVE_ID="" JOB_GCS_OBJECT="" JOB_GCS_GEN="" JOB_KEPT=""
[ "$SOURCE_KIND" = inbox ] && INBOX_DIR="$HOME/.odoo-validator/inbox/$SOURCE_REF"

inbox_jobs() {
  # Pending jobs of this service, newest first (archive names end in -YYYYMMDD-HHMMSS.tar.zst)
  local d n
  for d in "$INBOX_DIR"/*/; do
    d="${d%/}"; n="${d##*/}"
    [[ "$n" =~ ^snapshot-.+-[0-9]{8}-[0-9]{6}\.tar\.zst$ ]] && [ ! -L "$d" ] && [ -f "$d/job.json" ] && echo "$n"
  done | sort -r
}

inbox_sweep() {
  # Jobs taken by drills that are gone (killed, out of memory, reboot): back to the inbox when nothing
  # newer is waiting, otherwise removed
  local d n pid orig
  for d in "$INBOX_DIR"/.taken-*; do
    [ -d "$d" ] || continue
    n="${d##*/}"; pid="${n##*-}"; orig="${n#.taken-}"; orig="${orig%-*}"
    [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" != $$ ] && [ -d "/proc/$pid" ] && continue
    if [ -z "$(inbox_jobs)" ] && [[ "$orig" =~ ^snapshot-.+-[0-9]{8}-[0-9]{6}\.tar\.zst$ ]] && mv "$d" "$INBOX_DIR/$orig" 2>/dev/null; then
      log_info "Validator inbox: $orig was taken by a drill that did not finish; it is waiting again."
    elif rm -rf "$d"; then
      log_info "Validator inbox: removed $orig, left by a drill that did not finish (a newer snapshot is waiting)."
    fi
  done
  return 0
}

inbox_take() {
  # Takes the newest pending job and removes older ones. Returns 1 when there is none.
  local n older tries=0
  inbox_sweep
  while n=$(inbox_jobs | head -n 1) && [ -n "$n" ] && [ "$tries" -lt 5 ]; do
    if mv "$INBOX_DIR/$n" "$INBOX_DIR/.taken-$n-$$" 2>/dev/null; then
      INBOX_TAKEN="$INBOX_DIR/.taken-$n-$$"; INBOX_NAME="$n"
      for older in $(inbox_jobs); do
        if mv "$INBOX_DIR/$older" "$INBOX_DIR/.removing-$older-$$" 2>/dev/null; then
          rm -rf "$INBOX_DIR/.removing-$older-$$"
          log_info "Validator inbox: removed the older pending snapshot $older."
        fi
      done
      return 0
    fi
    tries=$((tries + 1)); sleep 1   # another drill took it at the same moment, or it was just replaced
  done
  return 1
}

inbox_dispose() {
  # Called on exit: pass/fail -> the job is done; error (or a job that cannot be used) -> see above
  [ -n "$INBOX_TAKEN" ] && [ -d "$INBOX_TAKEN" ] || return 0
  case "$RESULT" in
    pass|fail) rm -rf "$INBOX_TAKEN" ;;
    *)
      if [ -z "$INBOX_BROKEN" ] && [ -z "$(inbox_jobs)" ] && mv "$INBOX_TAKEN" "$INBOX_DIR/$INBOX_NAME" 2>/dev/null; then
        log_info "Validator inbox: $INBOX_NAME is waiting again, for the next try."
      else
        rm -rf "$INBOX_TAKEN"
        if [ -n "$INBOX_BROKEN" ]; then log_warn "Validator inbox: removed $INBOX_NAME (the job cannot be drilled: $INBOX_BROKEN)."
        else log_info "Validator inbox: a newer snapshot is waiting, so $INBOX_NAME was removed."; fi
      fi ;;
  esac
  INBOX_TAKEN=""
}

pre_check() {
  # Before waiting in the queue: is there anything to drill? Exit 5 (no report) when there is not.
  if [ "$SOURCE_KIND" = inbox ]; then
    inbox_sweep
    if [ -z "$(inbox_jobs)" ]; then
      log_info "No snapshot of $SOURCE_REF is waiting in the validator inbox ($INBOX_DIR); nothing to drill."
      exit 5
    fi
    return 0
  fi
  [ -n "$UNLESS_SHA" ] || return 0
  local f="$WORK/precheck.sha256" name="" row sid hash
  case "$SOURCE_KIND" in
    file)
      name=$(basename "$SOURCE_REF")
      [ -f "$SOURCE_REF.sha256" ] && cp "$SOURCE_REF.sha256" "$f" 2>/dev/null ;;
    drive)
      DRIVE_TOKEN=$(gds_get_token "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_SERVICE_ACCOUNT_KEY")
      if [ -n "$DRIVE_TOKEN" ]; then
        if [ -n "$DRIVE_NAME" ]; then name="$DRIVE_NAME"
        else row=$(gds_list_archives "$DRIVE_TOKEN" "$GDRIVE_FOLDER_ID" "$SOURCE_REF" 1); name=$(cut -f4 <<< "$row"); fi
        if [ -n "$name" ]; then
          sid=$(gds_find_by_name "$DRIVE_TOKEN" "$GDRIVE_FOLDER_ID" "$name.sha256")
          [ -n "$sid" ] && gds_download "$DRIVE_TOKEN" "$sid" "$f"
        fi
      fi ;;
    gcs)
      name=$(basename "$SOURCE_REF")
      gcloud storage cp "$SOURCE_REF.sha256" "$f" >/dev/null 2>&1 ;;
  esac
  hash=$(snap_sidecar_hash "$f")
  rm -f "$f"
  if [ -n "$hash" ] && [ "$hash" = "$UNLESS_SHA" ]; then
    log_info "${name:-The snapshot} is the snapshot the last drill already proved (sha256 ${hash:0:12}...); nothing new to drill."
    exit 5
  fi
  [ -n "$hash" ] || log_info "The .sha256 of ${name:-the snapshot} cannot be read beforehand; drilling it to find out."
  return 0
}
pre_check

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
        record_stage "fetch" "error" "$(since "$t0")" "Not enough disk to download $ARCHIVE_NAME ($(human "$size") + reserve $(human "$RESERVE_BYTES") [$RESERVE_FROM] needed, $(human "$free") free)"
        finish error
      fi
      log_info "Downloading $ARCHIVE_NAME ($(human "${size:-0}")) from Google Drive..."
      ARCHIVE="$WORK/$ARCHIVE_NAME"
      run_bg gds_download "$DRIVE_TOKEN" "$REMOTE_ARCHIVE_ID" "$ARCHIVE" || { record_stage "fetch" "error" "$(since "$t0")" "Download of $ARCHIVE_NAME failed"; finish error; }
      local sid
      sid=$(gds_find_by_name "$DRIVE_TOKEN" "$GDRIVE_FOLDER_ID" "$ARCHIVE_NAME.sha256")
      if [ -n "$sid" ] && gds_download "$DRIVE_TOKEN" "$sid" "$ARCHIVE.sha256"; then SIDECAR="$ARCHIVE.sha256"; fi
      ;;
    inbox)
      inbox_take || { log_info "No snapshot of $SOURCE_REF is waiting in the validator inbox ($INBOX_DIR) any more; nothing to drill."; exit 5; }
      ARCHIVE="$INBOX_TAKEN/$INBOX_NAME"; ARCHIVE_NAME="$INBOX_NAME"
      local job
      job=$(python3 - "$INBOX_TAKEN/job.json" "$SOURCE_REF" "$INBOX_NAME" <<'PY'
import json, sys
j = json.load(open(sys.argv[1]))
if j.get("schema") != 1 or j.get("service") != sys.argv[2] or j.get("archive") != sys.argv[3]:
    sys.exit(1)
d, g, k = j.get("drive") or {}, j.get("gcs") or {}, j.get("kept_copy") or ""
if k and not k.startswith("/"):
    sys.exit(1)
gen = str(g.get("generation") or "")
print("\x1f".join([d.get("name") or "", d.get("file_id") or "", g.get("object") or "", gen if gen.isdigit() else "", k]))
PY
) || { INBOX_BROKEN="its job.json is missing, unreadable or names another snapshot"; record_stage "fetch" "error" "$(since "$t0")" "Validator inbox: $INBOX_NAME cannot be drilled ($INBOX_BROKEN)"; finish error; }
      IFS=$'\x1f' read -r JOB_DRIVE_NAME JOB_DRIVE_ID JOB_GCS_OBJECT JOB_GCS_GEN JOB_KEPT <<< "$job"
      if [ ! -f "$ARCHIVE" ] || [ -L "$ARCHIVE" ]; then
        INBOX_BROKEN="its archive is missing"
        record_stage "fetch" "error" "$(since "$t0")" "Validator inbox: $INBOX_NAME cannot be drilled ($INBOX_BROKEN)"; finish error
      fi
      [ -f "$ARCHIVE.sha256" ] && SIDECAR="$ARCHIVE.sha256"
      GCS_GENERATION="$JOB_GCS_GEN"
      log_info "Drilling $INBOX_NAME from the validator inbox (no download)."
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
        record_stage "fetch" "error" "$(since "$t0")" "Not enough disk to download $ARCHIVE_NAME ($(human "$size") + reserve $(human "$RESERVE_BYTES") [$RESERVE_FROM] needed, $(human "$free") free)"
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
  { [ "$SOURCE_KIND" = drive ] || [ "$SOURCE_KIND" = inbox ]; } && SERVICE="$SOURCE_REF"
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
    record_stage "structure" "error" "$(since "$1")" "Not enough disk to unpack $INNER_ZIP_MEMBER ($(human "$zbytes") + reserve $(human "$RESERVE_BYTES") [$RESERVE_FROM] needed, $(human "$free") free)"
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
  local t0 out status
  t0=$(now_s)
  cat_member "$MANIFEST_MEMBER" "$CORE_SRC" > "$WORK/manifest.json" 2>/dev/null
  # The Odoo series ("18.0") comes from version_info first: it is the only field Odoo's release.py
  # holds literally, and snapshot tools before the version fix wrote "version": "16.0" for every
  # deployment while version_info was right. stage_database compares it with the restored database.
  if ! out=$(python3 - "$WORK/manifest.json" <<'PY' 2>/dev/null
import json, re, sys
m = json.load(open(sys.argv[1]))
if not isinstance(m, dict):
    raise SystemExit(1)
def series_of(v):
    hit = re.match(r"^((?:saas~)?\d+\.\d+)", str(v or "").strip())
    return hit.group(1) if hit else ""
vi = m.get("version_info")
from_vi = "%s.%s" % (vi[0], vi[1]) if isinstance(vi, list) and len(vi) >= 2 and None not in vi[:2] else ""
from_vi = series_of(from_vi)
from_version = series_of(m.get("version"))
version = from_vi or from_version or series_of(m.get("major_version"))
details = {"odoo_version": version or None}
status = "pass"
if not version:
    status = "warn"
    details["message"] = "manifest.json has no Odoo version (the restored database tells it instead)"
elif from_vi and from_version and from_vi != from_version:
    status = "warn"
    details["manifest_version"] = str(m.get("version"))
    details["message"] = ("manifest.json disagrees with itself: version_info says %s but version says %s "
                          "(written by a snapshot tool from before the Odoo version fix: update docker-odoo on that "
                          "deployment and re-run ./setup.sh, which installs the fixed snapshot tool)" % (from_vi, m.get("version")))
print(status + "\x1f" + version + "\x1f" + json.dumps(details))
PY
); then
    record_stage "manifest" "fail" "$(since "$t0")" "manifest.json is unreadable"
    finish fail
  fi
  IFS=$'\x1f' read -r status ODOO_VERSION out <<< "$out"
  record_stage "manifest" "$status" "$(since "$t0")" "$out"
}

# git_hashes.json comes from the archive: never let its values reach git as options, and only
# allow the transports production uses (VALIDATOR_GIT_ALLOW_PROTOCOL, default https:ssh).
VALIDATOR_GIT_USER=""
if [ "$(id -u)" = 0 ] && [ -n "$SNAPSHOT_REMOTE_USER" ] && [ "$SNAPSHOT_REMOTE_USER" != root ] && id "$SNAPSHOT_REMOTE_USER" >/dev/null 2>&1; then
  VALIDATOR_GIT_USER="$SNAPSHOT_REMOTE_USER"
fi
valid_commit() { [[ "$1" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; }
valid_remote() { [ -n "$1" ] && [[ "$1" != -* ]] && [[ "$1" != *[[:space:][:cntrl:]]* ]]; }
git_safe() {
  if [ -n "$VALIDATOR_GIT_USER" ]; then
    ( cd /tmp && sudo -u "$VALIDATOR_GIT_USER" -H env \
      GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL="$VALIDATOR_GIT_ALLOW_PROTOCOL" GIT_CONFIG_NOSYSTEM=1 \
      GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15" \
      timeout "$VALIDATOR_GIT_TIMEOUT" git "$@" )
  else
    GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL="$VALIDATOR_GIT_ALLOW_PROTOCOL" GIT_CONFIG_NOSYSTEM=1 \
    GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15" \
      timeout "$VALIDATOR_GIT_TIMEOUT" git "$@"
  fi
}
git_check_commit() {
  # Args: remote commit. Prints found:by-id | found:history | missing | unreachable
  local remote="$1" commit="$2" tmp
  if [ -n "$VALIDATOR_GIT_USER" ]; then
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/odoo-drill-git.XXXXXX") || { echo unreachable; return; }
    chmod 700 "$tmp" && chown -R "$VALIDATOR_GIT_USER": "$tmp"
    ( cd /tmp && sudo -u "$VALIDATOR_GIT_USER" -H git init -q --bare "$tmp" ) >/dev/null 2>&1
  else
    tmp=$(mktemp -d "$WORK/git.XXXXXX") || { echo unreachable; return; }
    git init -q --bare "$tmp" >/dev/null 2>&1
  fi
  git_cat() {
    if [ -n "$VALIDATOR_GIT_USER" ]; then
      ( cd /tmp && sudo -u "$VALIDATOR_GIT_USER" -H git -C "$tmp" cat-file -e "$1" ) 2>/dev/null
    else
      git -C "$tmp" cat-file -e "$1" 2>/dev/null
    fi
  }
  if ! git_safe ls-remote -q --heads -- "$remote" >/dev/null 2>&1 \
     && ! git_safe ls-remote -q -- "$remote" >/dev/null 2>&1; then
    echo unreachable
  # Fast path: fetch just that commit object, no trees or files (GitHub/GitLab allow fetching
  # reachable commits by id; a server without partial clone ignores the filter and sends the files)
  elif git_safe -C "$tmp" fetch -q --depth=1 --filter=tree:0 -- "$remote" "$commit" >/dev/null 2>&1 \
       && git_cat "$commit^{commit}"; then
    echo found:by-id
  # Slow path: history without file contents, then look for the commit
  elif git_safe -C "$tmp" fetch -q --filter=tree:0 -- "$remote" "+refs/heads/*:refs/heads/*" "+refs/tags/*:refs/tags/*" >/dev/null 2>&1 \
       && git_cat "$commit^{commit}"; then
    echo found:history
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

  local kind rel remote commit shown state t_repo ok=0 bad=0 unreachable=0 problems=() checked=()
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
    t_repo=$(now_s)
    run_bg git_check_commit "$remote" "$commit" > "$WORK/git_state" 2>/dev/null
    state=$(cat "$WORK/git_state" 2>/dev/null)
    case "$state" in
      found:*) ok=$((ok + 1)); checked+=("$rel: ${commit:0:8} found on remote (${state#found:}, $(since "$t_repo")s)") ;;
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
    record_stage "disk" "error" "$(since "$t0")" "{\"message\": \"Not enough disk for the restored database: need $(human "$need_db") ($how) + reserve $(human "$RESERVE_BYTES") [$RESERVE_FROM], $(human "$free_db") free in $DOCKER_ROOT\"}"
    finish error
  fi
  record_stage "disk" "pass" "$(since "$t0")" "{\"estimated_db_bytes\": $need_db, \"estimate\": $(jstr "$how"), \"free_bytes\": ${free_db:-0}, \"reserve_bytes\": $RESERVE_BYTES, \"reserve_from\": $(jstr "$RESERVE_FROM"), \"path\": $(jstr "$DOCKER_ROOT")}"
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
  # The restored database is the truth about the Odoo version: base 18.0.1.3 is series 18.0
  local db_series version_warning=""
  db_series=$(python3 -c 'import json,sys
v = str(json.loads(sys.argv[1]).get("base_version") or "")
parts = v.split(".")
print(".".join(parts[:-2]) if len(parts) >= 4 else "")' "$stats" 2>/dev/null)
  if [ -n "$db_series" ]; then
    if [ -n "$ODOO_VERSION" ] && [ "$ODOO_VERSION" != "$db_series" ]; then
      version_warning="manifest.json says Odoo $ODOO_VERSION but the database is Odoo $db_series; the snapshot tool recorded the wrong version (update docker-odoo on that deployment and re-run ./setup.sh)"
    fi
    MANIFEST_ODOO_VERSION="$ODOO_VERSION"
    ODOO_VERSION="$db_series"
  fi
  local db_message
  db_message=$(printf '%s\n' "$PULL_WARNING" "$version_warning" | sed '/^$/d' | paste -sd ';' - | sed 's/;/; /g')
  record_stage "database" "$([ -n "$db_message" ] && echo warn || echo pass)" "$(since "$t0")" "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d["image"]=sys.argv[2]; d["restore_warnings"]=int(sys.argv[3] or 0)
if sys.argv[5]: d["odoo_version"]=sys.argv[5]
if sys.argv[6] and sys.argv[6] != sys.argv[5]: d["manifest_odoo_version"]=sys.argv[6]
if sys.argv[4]: d["message"]=sys.argv[4]
print(json.dumps(d))' "$stats" "$PG_IMAGE" "$(grep -a -c 'WARNING' "$WORK/restore.log" || true)" "$db_message" "$db_series" "$MANIFEST_ODOO_VERSION")"
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
  # mkrec OUT NAME: the record for the archive called NAME where it is stored (an inbox snapshot's copies
  # can have other names: the GCS object, the copy kept on the drill host)
  mkrec() {
    snap_write_validation_record "$1" "$2" "$ARCHIVE_SHA" \
      "{\"level\": \"$DRILL_LEVEL\", \"run_id\": \"$RUN_ID\", \"checks\": $checks, \"odoo_version\": $(jstr "$ODOO_VERSION"), \"postgres_image\": $(jstr "$PG_IMAGE"), \"drill_seconds\": $(( $(date +%s) - START_EPOCH ))$([ -n "$GCS_GENERATION" ] && echo ", \"gcs_generation\": \"$GCS_GENERATION\""), \"database\": $DB_STATS}" \
      && chmod 644 "$1" 2>/dev/null
  }
  if ! mkrec "$rec" "$ARCHIVE_NAME"; then
    record_stage "publish" "error" "$(since "$t0")" "Could not write the validation record"
    return
  fi
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
    inbox) publish_inbox "$t0" "$rec" ;;
  esac
}

publish_inbox() {
  # Args: t0 record. Records the result next to every copy the snapshot tool uploaded (job.json), or next
  # to the copy it kept on this host when there is no upload. Never next to a copy that was replaced since.
  local t0="$1" rec="$2" ok=() bad=() cur name obj
  if [ -n "$JOB_DRIVE_ID" ]; then
    name="${JOB_DRIVE_NAME:-$ARCHIVE_NAME}"
    DRIVE_TOKEN=$(gds_get_token "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_SERVICE_ACCOUNT_KEY")
    if [ -z "$DRIVE_TOKEN" ]; then
      bad+=("no Google Drive token for $name.validated.json (set GDRIVE_SERVICE_ACCOUNT_KEY or GDRIVE_ACCESS_TOKEN)")
    elif mkrec "$WORK/validated-drive.json" "$name" && gds_publish_validation "$DRIVE_TOKEN" "$GDRIVE_FOLDER_ID" "$name" "$WORK/validated-drive.json" >/dev/null; then
      ok+=("Google Drive ($name.validated.json)")
    else
      bad+=("$name.validated.json could not be uploaded to Google Drive")
    fi
  fi
  if [ -n "$JOB_GCS_OBJECT" ]; then
    obj=$(redact "$JOB_GCS_OBJECT")
    cur=$(gcloud storage objects describe "$JOB_GCS_OBJECT" --format='value(generation)' 2>/dev/null)
    if [ -z "$JOB_GCS_GEN" ]; then
      bad+=("$obj: the hand-off did not record its generation, so it cannot be told whether it still holds this snapshot")
    elif [ "$cur" != "$JOB_GCS_GEN" ]; then
      bad+=("$obj now holds a newer snapshot (generation $JOB_GCS_GEN -> ${cur:-gone}); no record for it")
    elif mkrec "$WORK/validated-gcs.json" "$(basename "$JOB_GCS_OBJECT")" && gcs_publish_validation "$JOB_GCS_OBJECT" "$WORK/validated-gcs.json"; then
      ok+=("$obj.validated.json (generation $JOB_GCS_GEN)")
    else
      bad+=("$obj.validated.json could not be uploaded")
    fi
  fi
  if [ -z "$JOB_DRIVE_ID" ] && [ -z "$JOB_GCS_OBJECT" ]; then
    if [ -z "$JOB_KEPT" ]; then
      bad+=("the snapshot tool recorded no uploaded or kept copy of $ARCHIVE_NAME to put the record next to")
    elif [ "$(stat -L -c '%d:%i' "$JOB_KEPT" 2>/dev/null)" != "$(stat -L -c '%d:%i' "$AR" 2>/dev/null)" ]; then
      bad+=("$JOB_KEPT is no longer this snapshot (a newer one replaced it); no record for it")
    elif mkrec "$WORK/validated-kept.json" "$(basename "$JOB_KEPT")" && cp "$WORK/validated-kept.json" "$JOB_KEPT.validated.json" 2>/dev/null; then
      ok+=("$JOB_KEPT.validated.json")
    else
      bad+=("could not write $JOB_KEPT.validated.json")
    fi
  fi
  if [ ${#bad[@]} -eq 0 ]; then
    PUBLISHED=yes
    record_stage "publish" "pass" "$(since "$t0")" "Recorded the drill next to: $(printf '%s; ' "${ok[@]}" | sed 's/; $//')"
  else
    record_stage "publish" "error" "$(since "$t0")" "Drill passed, but $(printf '%s; ' "${bad[@]}" | sed 's/; $//')$([ ${#ok[@]} -gt 0 ] && printf ' (recorded: %s)' "$(printf '%s; ' "${ok[@]}" | sed 's/; $//')")"
  fi
}

# --- Phase 2: Odoo boots on the restored copy (image, code, boot) ---
# Odoo's code is not in the image (deployments mount odoo-base/ and git/), so the drill checks the
# code out at the snapshot's commits and runs it in the deployment's own image, on the drill's
# internal network: nothing it does can reach production or the internet.

snap_member_exact() {
  # Args: relative path. Prints the archive member for it (as stored: "x" or "./x"), regular files only
  awk -F'\t' -v a="$1" -v b="./$1" '$3 == "-" && ($2 == a || $2 == b) {print $2; exit}' "$WORK/members.tsv"
}
snap_file() {
  # Args: relative path, destination. Copies that file out of the snapshot; fails when it is not there
  local m
  m=$(snap_member_exact "$1")
  [ -n "$m" ] && tar -xOf "$AR" -I zstd --occurrence=1 "$m" > "$2" 2>/dev/null
}
envfile_get() {
  # Args: file key. A value from a .env file, the way the deployment scripts read it
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -n1 | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//'
}
registry_of() {
  # The registry host of an image name (empty: Docker Hub)
  local first="${1%%/*}"
  if [[ "$1" == */* ]] && { [[ "$first" == *.* ]] || [[ "$first" == *:* ]] || [ "$first" = localhost ]; }; then
    echo "$first"
  fi
}
image_exists() { docker image inspect "$1" >/dev/null 2>&1; }

BOOT_SNAP_ENV_KEYS=(ODOO_IMAGE_NAME CURRENT_IMAGE_VERSION DOCKER_BUILD_MODE DOCKER_PUSHPULL_USERNAME DOCKER_PULL_KEY
  PYTHON_VERSION APT_ADDITIONAL_PACKAGES PIP_ADDITIONAL_PACKAGES POSTGRESQL_VERSION APT_RESOURCE_URL
  POSTGRESQL_CUSTOM_REPO_URL ADDONS_PATH ODOO_ADDITIONAL_CONF DEPCON_ENCRYPTION_SECRET CUSTOM_SECRETS_FILES)
declare -A SNAP_ENV=()

boot_prepare() {
  # Reads what the boot check needs from the snapshot's .env, then deletes the copy (it holds secrets)
  mkdir -p "$BOOT_DIR" && chmod 700 "$BOOT_DIR" || return 1
  local k
  if snap_file .env "$BOOT_DIR/snapshot.env"; then
    for k in "${BOOT_SNAP_ENV_KEYS[@]}"; do SNAP_ENV[$k]=$(envfile_get "$BOOT_DIR/snapshot.env" "$k"); done
  fi
  rm -f "$BOOT_DIR/snapshot.env"
  return 0
}

image_repo() {
  local r
  r=$(tr 'A-Z' 'a-z' <<< "${SERVICE:-unknown}" | tr -c 'a-z0-9._\n-' '-' | sed 's/^[-._]*//' | cut -c1-60)
  echo "odoo-drill/${r:-unknown}"
}

drill_dockerfile() {
  # Args: source dockerfile.example, output. The dependency part of the deployment's dockerfile (system
  # packages, the odoo user, pip requirements); entrypoint, utilities and fonts are left out (the drill
  # runs odoo-bin itself and renders no PDF). Fails when the expected layout is not there.
  python3 - "$1" "$2" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
out, seen_pip = [], False
for line in lines:
    s = line.strip()
    if s.startswith("# Switch back to root for further setup") or (seen_pip and s == "USER root"):
        break
    if s.startswith("COPY fonts/") or s.startswith("RUN fc-cache"):
        continue
    if "pip install -r ./requirements.txt" in s:
        seen_pip = True
    out.append(line)
if not seen_pip or not any(l.strip().startswith("FROM ") for l in out):
    sys.exit(1)
out += ["USER odoo", "WORKDIR /opt/odoo", ""]
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out))
PY
}

stage_image() {
  local t0 repo name ver mode ref tag key reg how="" note="" dockerfile ctx args=() a prev
  t0=$(now_s)
  repo=$(image_repo)
  name="${SNAP_ENV[ODOO_IMAGE_NAME]:-}"; ver="${SNAP_ENV[CURRENT_IMAGE_VERSION]:-}"; mode="${SNAP_ENV[DOCKER_BUILD_MODE]:-}"

  # 1. The deployment's own image, when it is pushed to a registry (builder / production mode)
  if [ -n "$name" ] && { [ "$mode" = 2 ] || [ "$mode" = 3 ]; }; then
    ref="$name${ver:+:$ver}"
    tag="$repo:pull-$(printf '%s' "$ref" | sha256sum | cut -c1-12)"
    if [ "$VALIDATOR_PULL_POLICY" = missing ] && image_exists "$tag"; then
      BOOT_IMAGE="$tag"; how="cached (pulled earlier from $ref)"
    else
      log_info "[image] Pulling $ref (the deployment's image)..."
      reg=$(registry_of "$name")
      if (
           # Credentials from the snapshot's .env go to a throwaway Docker config, on stdin only
           export DOCKER_CONFIG="$BOOT_DIR/docker-config"
           mkdir -p "$DOCKER_CONFIG" && chmod 700 "$DOCKER_CONFIG" || exit 1
           if [ -n "${SNAP_ENV[DOCKER_PULL_KEY]:-}" ]; then
             printf '%s' "${SNAP_ENV[DOCKER_PULL_KEY]}" | docker login --username "${SNAP_ENV[DOCKER_PUSHPULL_USERNAME]:-}" --password-stdin $reg >/dev/null 2>"$BOOT_DIR/login.err" || exit 2
           fi
           timeout "$VALIDATOR_BUILD_TIMEOUT" docker pull -q "$ref" >/dev/null 2>"$BOOT_DIR/pull.err" || exit 3
         ); then
        docker tag "$ref" "$tag" >/dev/null 2>&1 && docker rmi "$ref" >/dev/null 2>&1
        image_exists "$tag" && { BOOT_IMAGE="$tag"; how="pulled $ref"; }
      else
        case $? in
          2) note="could not log in to ${reg:-Docker Hub} with the snapshot's DOCKER_PULL_KEY: $(head -c 300 "$BOOT_DIR/login.err" | tr '\n' ' ')" ;;
          *) note="could not pull $ref: $(head -c 300 "$BOOT_DIR/pull.err" 2>/dev/null | tr '\n' ' ')" ;;
        esac
        log_warn "[image] ${note}; building the image instead."
      fi
      rm -rf "$BOOT_DIR/docker-config" "$BOOT_DIR/login.err"
    fi
  fi

  # 2. Built here from dockerfile.example and the snapshot's requirements.txt, cached by their hash
  if [ -z "$BOOT_IMAGE" ]; then
    dockerfile="$PATH_TO_ODOO/dockerfile.example"
    [ -f "$dockerfile" ] || dockerfile="$CURRENT_DIR/lib/dockerfile.example"
    ctx="$BOOT_DIR/build"
    mkdir -p "$ctx" || { record_stage "image" "error" "$(since "$t0")" "Cannot create $ctx"; return 1; }
    if [ ! -f "$dockerfile" ] || ! drill_dockerfile "$dockerfile" "$ctx/Dockerfile"; then
      record_stage "image" "error" "$(since "$t0")" "${note:+$note; }cannot build the Odoo image: dockerfile.example is missing or no longer has the expected layout (update docker-odoo)"
      return 1
    fi
    if ! snap_file requirements.txt "$ctx/requirements.txt"; then
      # Like setup.sh: the deployment's requirements.txt is a copy of odoo-base's
      local base_req
      base_req=$(ls "$BOOT_DIR"/code/odoo-base/*/requirements.txt "$BOOT_DIR"/code/odoo-base/requirements.txt 2>/dev/null | head -n 1)
      if [ -n "$base_req" ] && cp "$base_req" "$ctx/requirements.txt"; then
        note="${note:+$note; }the snapshot has no requirements.txt: built with odoo-base's ${base_req#"$BOOT_DIR"/code/}"
      else
        : > "$ctx/requirements.txt"
        note="${note:+$note; }neither the snapshot nor its odoo-base has a requirements.txt: the image has no Python packages for Odoo"
      fi
    fi
    args=(--build-arg "PYTHON_VERSION=${SNAP_ENV[PYTHON_VERSION]:-3.11-bookworm}")
    for a in APT_ADDITIONAL_PACKAGES PIP_ADDITIONAL_PACKAGES POSTGRESQL_VERSION APT_RESOURCE_URL POSTGRESQL_CUSTOM_REPO_URL; do
      args+=(--build-arg "$a=${SNAP_ENV[$a]:-}")
    done
    key=$( { cat "$ctx/Dockerfile" "$ctx/requirements.txt"; printf '%s\n' "${args[@]}"; } | sha256sum | cut -c1-16)
    tag="$repo:build-$key"
    if image_exists "$tag"; then
      BOOT_IMAGE="$tag"; how="cached build"
    else
      log_info "[image] Building the drill's Odoo image (first drill with these dependencies: this takes a few minutes)..."
      if run_bg timeout "$VALIDATOR_BUILD_TIMEOUT" docker build --label "odoo-drill-image=$repo" -t "$tag" "${args[@]}" "$ctx" > "$BOOT_DIR/build.log" 2>&1 \
         && image_exists "$tag"; then
        BOOT_IMAGE="$tag"; how="built"
      else
        record_stage "image" "error" "$(since "$t0")" "{\"message\": $(jstr "${note:+$note; }the Odoo image could not be built (network, a package that no longer installs, or VALIDATOR_BUILD_TIMEOUT=${VALIDATOR_BUILD_TIMEOUT}s)"), \"build_log_tail\": $(jstr "$(tail -n 15 "$BOOT_DIR/build.log" 2>/dev/null | cut -c1-300)")}"
        return 1
      fi
    fi
  fi

  # Keep this image and the one the previous drill of this deployment used; remove older ones
  mkdir -p "$VALIDATOR_DIR/cache" 2>/dev/null
  local last_file="$VALIDATOR_DIR/cache/image-$(basename "$repo")"
  prev=$(cat "$last_file" 2>/dev/null)
  if [ "$prev" != "$BOOT_IMAGE" ]; then
    while read -r a; do
      [ -n "$a" ] && [ "$a" != "$BOOT_IMAGE" ] && [ "$a" != "$prev" ] && docker rmi "$a" >/dev/null 2>&1
    done < <(docker image ls "$repo" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)
    printf '%s\n' "$BOOT_IMAGE" > "$last_file"
  fi
  record_stage "image" "$([ -n "$note" ] && echo warn || echo pass)" "$(since "$t0")" \
    "{\"image\": $(jstr "$BOOT_IMAGE"), \"source\": $(jstr "$how")$([ -n "$note" ] && echo ", \"message\": $(jstr "$note")")}"
}

safe_rel() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] && [[ "$1" != *..* ]] && [[ "$1" != */ ]]; }

stage_code() {
  # Every repository at its recorded commit (a cache of fetched objects per remote keeps later drills
  # small), every bundled folder from the archive; all readable by the container's odoo user.
  local t0 kind rel remote commit cache n=0 dest problems=() done_list=()
  t0=$(now_s)
  dest="$BOOT_DIR/code"
  ( umask 022; mkdir -p "$dest" ) || { record_stage "code" "error" "$(since "$t0")" "Cannot create $dest"; return 1; }
  chmod 755 "$dest"
  mkdir -p "$VALIDATOR_DIR/cache/git" && chmod 700 "$VALIDATOR_DIR/cache" "$VALIDATOR_DIR/cache/git" 2>/dev/null
  while IFS=$'\t' read -r kind rel remote commit; do
    [ -n "$rel" ] || continue
    if ! safe_rel "$rel"; then problems+=("$rel: not a safe relative path, skipped"); continue; fi
    n=$((n + 1))
    if [ "$kind" = bundled ]; then
      awk -F'\t' -v p="$rel/" -v q="./$rel/" 'index($2, p) == 1 || index($2, q) == 1 {print $2}' "$WORK/members.tsv" > "$BOOT_DIR/members.$n"
      if [ -s "$BOOT_DIR/members.$n" ] && ( umask 022; tar -xf "$AR" -I zstd -C "$dest" --no-same-owner --no-same-permissions -T "$BOOT_DIR/members.$n" ) 2>/dev/null; then
        done_list+=("$rel: from the archive")
      else
        problems+=("$rel: could not be taken out of the archive")
      fi
      continue
    fi
    valid_remote "$remote" && valid_commit "$commit" || { problems+=("$rel: no usable remote or commit"); continue; }
    cache="$VALIDATOR_DIR/cache/git/$(printf '%s' "$remote" | sha256sum | cut -c1-24).git"
    [ -d "$cache" ] || git init -q --bare "$cache" >/dev/null 2>&1
    log_info "[code] $rel: checking out ${commit:0:8}..."
    if ! git -C "$cache" cat-file -e "$commit^{tree}" 2>/dev/null; then
      if [ -n "$VALIDATOR_GIT_USER" ]; then
        local fetch_tmp
        fetch_tmp=$(mktemp -d "${TMPDIR:-/tmp}/odoo-drill-fetch.XXXXXX")
        chmod 700 "$fetch_tmp" && chown -R "$VALIDATOR_GIT_USER": "$fetch_tmp"
        ( cd /tmp && sudo -u "$VALIDATOR_GIT_USER" -H git init -q --bare "$fetch_tmp" ) >/dev/null 2>&1
        if ! run_bg git_safe -C "$fetch_tmp" fetch -q --depth=1 -- "$remote" "$commit" >/dev/null 2>"$BOOT_DIR/fetch.err" \
           || ! git -c safe.directory="$fetch_tmp" -C "$cache" fetch -q "$fetch_tmp" "$commit" >/dev/null 2>>"$BOOT_DIR/fetch.err"; then
          rm -rf "$fetch_tmp"
          problems+=("$rel: could not fetch ${commit:0:8} from $(redact "$remote"): $(head -c 200 "$BOOT_DIR/fetch.err" | tr '\n' ' ')")
          continue
        fi
        rm -rf "$fetch_tmp"
      elif ! run_bg git_safe -C "$cache" fetch -q --depth=1 -- "$remote" "$commit" >/dev/null 2>"$BOOT_DIR/fetch.err"; then
        problems+=("$rel: could not fetch ${commit:0:8} from $(redact "$remote"): $(head -c 200 "$BOOT_DIR/fetch.err" | tr '\n' ' ')")
        continue
      fi
    fi
    git -C "$cache" update-ref "refs/drill/$(printf '%s' "$rel" | tr '/' '_')" "$commit" 2>/dev/null
    if ( umask 022; mkdir -p "$dest/$rel" && GIT_INDEX_FILE="$BOOT_DIR/index.$n" git --git-dir="$cache" --work-tree="$dest/$rel" read-tree "$commit" \
         && GIT_INDEX_FILE="$BOOT_DIR/index.$n" git --git-dir="$cache" --work-tree="$dest/$rel" checkout-index -a -f ) >/dev/null 2>"$BOOT_DIR/checkout.err"; then
      done_list+=("$rel: ${commit:0:8}")
    else
      problems+=("$rel: checkout of ${commit:0:8} failed: $(head -c 200 "$BOOT_DIR/checkout.err" | tr '\n' ' ')")
    fi
    rm -f "$BOOT_DIR/index.$n"
    git -C "$cache" gc --auto -q >/dev/null 2>&1
  done < "$WORK/repos.tsv"
  chmod -R a+rX "$dest" 2>/dev/null
  local details
  details=$(python3 -c 'import json,sys; p=[x for x in sys.argv[2].split("\n") if x]; print(json.dumps({"message": "; ".join(p) if p else "code ready", "checked_out": [x for x in sys.argv[1].split("\n") if x], "problems": p}))' \
    "$(printf '%s\n' "${done_list[@]}")" "$(printf '%s\n' "${problems[@]}")")
  if [ ${#problems[@]} -gt 0 ]; then
    record_stage "code" "error" "$(since "$t0")" "$details"
    return 1
  fi
  record_stage "code" "pass" "$(since "$t0")" "$details"
}

boot_layout() {
  # Sets ODOO_BIN (path in the container), ADDONS (addons_path in the container), MOUNTS (docker args)
  # and LAYOUT_NOTES. Containers see the snapshot's folders where production has them (/opt/odoo/...).
  local dest="$BOOT_DIR/code" d top p conf_addons="" kept=() dropped=()
  ODOO_BIN="" ADDONS="" MOUNTS=() LAYOUT_NOTES=()
  for d in "$dest"/odoo-base/*/; do
    [ -f "$d/odoo-bin" ] && { ODOO_BIN="/opt/odoo/odoo-base/$(basename "$d")/odoo-bin"; break; }
  done
  [ -n "$ODOO_BIN" ] || { [ -f "$dest/odoo-base/odoo-bin" ] && ODOO_BIN="/opt/odoo/odoo-base/odoo-bin"; }
  for top in "$dest"/*; do
    [ -d "$top" ] && MOUNTS+=(--mount "type=bind,src=$top,dst=/opt/odoo/$(basename "$top"),readonly")
  done
  if [ -n "${SNAP_ENV[CUSTOM_SECRETS_FILES]:-}" ]; then
    local sec_raw sec_name sec_out
    mkdir -p "$BOOT_DIR/secrets" && chmod 711 "$BOOT_DIR/secrets"
    IFS=',' read -ra sec_raw <<< "${SNAP_ENV[CUSTOM_SECRETS_FILES]}"
    for sec_name in "${sec_raw[@]}"; do
      sec_name=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<< "$sec_name")
      [ -n "$sec_name" ] || continue
      if ! [[ "$sec_name" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$sec_name" == *..* ]]; then
        LAYOUT_NOTES+=("custom secret '$sec_name' skipped (invalid name)"); continue
      fi
      sec_out="$BOOT_DIR/secrets/$sec_name"
      if snap_file ".secrets/$sec_name" "$sec_out" || { [ -f "$PATH_TO_ODOO/.secrets/$sec_name" ] && cp "$PATH_TO_ODOO/.secrets/$sec_name" "$sec_out" 2>/dev/null; }; then
        chmod 644 "$sec_out"
        MOUNTS+=(--mount "type=bind,src=$sec_out,dst=/run/secrets/$sec_name,readonly")
      else
        rm -f "$sec_out"
        LAYOUT_NOTES+=("custom secret '.secrets/$sec_name' not found in snapshot or host")
      fi
    done
  fi
  # addons_path as production has it: conf/odoo.conf, then ADDONS_PATH in .env, then the usual layout
  if snap_file conf/odoo.conf "$BOOT_DIR/prod.conf"; then
    conf_addons=$(python3 -c 'import configparser,sys
c = configparser.ConfigParser(strict=False, interpolation=None)
try:
    c.read(sys.argv[1]); print(c.get("options", "addons_path", fallback="").strip())
except Exception:
    pass' "$BOOT_DIR/prod.conf" 2>/dev/null)
    rm -f "$BOOT_DIR/prod.conf"
  fi
  case "$conf_addons" in enter_*) conf_addons="" ;; esac
  ADDONS="${conf_addons:-${SNAP_ENV[ADDONS_PATH]:-}}"
  if [ -z "$ADDONS" ] && [ -n "$ODOO_BIN" ]; then
    ADDONS="$(dirname "$ODOO_BIN")/odoo/addons,$(dirname "$ODOO_BIN")/addons"
    for d in "$dest"/git/*/; do [ -d "$d" ] && ADDONS+=",/opt/odoo/git/$(basename "$d")"; done
    LAYOUT_NOTES+=("no addons_path in the snapshot's conf/odoo.conf or .env: used odoo-base and every folder under git/")
  fi
  IFS=',' read -ra p <<< "$ADDONS"
  for d in "${p[@]}"; do
    d=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<< "$d"); d="${d%/}"
    [ -n "$d" ] || continue
    if [[ "$d" == /opt/odoo/* ]] && [ -d "$dest/${d#/opt/odoo/}" ]; then kept+=("$d"); else dropped+=("$d"); fi
  done
  ADDONS=$(IFS=,; echo "${kept[*]}")
  [ ${#dropped[@]} -gt 0 ] && LAYOUT_NOTES+=("addons_path entries not in the snapshot, left out: ${dropped[*]}")
  return 0
}

boot_classify() {
  # Args: log_file strict(true|false) http_status final_path registry(loaded|failed|timeout|exited)
  # Prints the status (pass|warn|fail) on the first line and the details JSON on the second.
  python3 - "$@" <<'PY'
import json, re, sys
log_file, strict, http, path, registry = sys.argv[1:6]
strict = strict == "true"
LINE = re.compile(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d,\d+ \d+ (DEBUG|INFO|WARNING|ERROR|CRITICAL) (\S+) ([\w.]+): (.*)$")
FATAL = [
    (re.compile(r"Failed to initialize database|Failed to load registry"), "the registry did not load"),
    (re.compile(r"Some modules are not loaded, some dependencies or manifest may be missing"), "installed modules are missing their code"),
    (re.compile(r"Couldn't load module"), "a module's Python code does not import"),
    (re.compile(r"(?i)module \S+: not installable, skipped"), "an installed module is not installable"),
]
try:
    raw = open(log_file, errors="replace").read().splitlines()
except OSError:
    raw = []
fatal, errors, entry = [], [], None
for i, line in enumerate(raw):
    m = LINE.match(line)
    if not m:
        if entry is not None and len(entry["detail"]) < 6:
            entry["detail"].append(line[:300])
        continue
    entry = None
    level, logger, msg = m.group(1), m.group(3), m.group(4)
    reason = next((r for rx, r in FATAL if rx.search(msg)), None)
    if reason or level in ("ERROR", "CRITICAL"):
        entry = {"level": level, "logger": logger, "message": msg[:500], "detail": []}
        if reason:
            entry["reason"] = reason
            fatal.append(entry)
        else:
            errors.append(entry)
problems = sorted({e["reason"] for e in fatal})
if registry == "neutralize":
    for e in fatal + errors:
        e["detail"] = "\n".join(e["detail"])[:1500]
    print("fail" if problems else "error")
    print(json.dumps({"message": "odoo-bin neutralize failed: " + ("; ".join(problems) if problems else "see the log"),
                      "fatal": fatal[:20], "errors": errors[:20]}))
    sys.exit(0)
if registry != "loaded":
    problems.insert(0, {"failed": "the registry did not load", "timeout": "Odoo did not finish loading in time",
                        "exited": "Odoo stopped before it was ready"}.get(registry, "the registry did not load"))
if http != "200" or path != "/web/login":
    problems.append("/web/login answered %s%s" % (http, "" if path in ("", "/web/login") else " (ended at %s)" % path))
if strict and errors:
    problems.append("%d other ERROR/CRITICAL line(s) (VALIDATOR_BOOT_STRICT=true)" % len(errors))
status = "fail" if problems else ("warn" if errors else "pass")
if problems:
    msg = "Odoo does not run on this snapshot: " + "; ".join(problems)
elif errors:
    msg = "Odoo runs on this snapshot; %d ERROR/CRITICAL line(s) in its log (warnings; VALIDATOR_BOOT_STRICT=true makes them failures)" % len(errors)
else:
    msg = "Odoo runs on this snapshot: registry loaded, every installed module loaded, /web/login answers 200"
for e in fatal + errors:
    e["detail"] = "\n".join(e["detail"])[:1500]
print(status)
print(json.dumps({"message": msg, "registry": registry, "http_status": http, "strict": strict,
                  "fatal": fatal[:20], "errors": errors[:20], "error_lines": len(errors) + len(fatal)}))
PY
}

boot_run() {
  # Args: container name, then odoo-bin's arguments. Starts a drill Odoo container (detached).
  local name="$1"; shift
  docker run -d --name "$name" --label odoo-drill="$RUN_ID" --network "$DRILL_NET" \
    --cpus "$VALIDATOR_PG_CPUS" --memory "$VALIDATOR_ODOO_MEMORY" --memory-swap "$VALIDATOR_ODOO_MEMORY" \
    --oom-score-adj 1000 --pids-limit 512 \
    --tmpfs /var/lib/odoo-drill:rw,size=2g,mode=1777 --tmpfs /tmp:rw,size=512m,mode=1777 \
    --mount "type=bind,src=$BOOT_DIR/drill.conf,dst=/etc/odoo-drill/drill.conf,readonly" "${MOUNTS[@]}" \
    --entrypoint python3 "$BOOT_IMAGE" "$ODOO_BIN" "$@" >/dev/null 2>"$BOOT_DIR/run.err"
}
container_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

stage_boot() {
  local t0 dbname major pass role_sql i registry=timeout http="" path="" result status details neutralized=""
  t0=$(now_s)
  dbname=$(cat "$WORK/dbname")
  boot_layout
  if [ -z "$ODOO_BIN" ]; then
    record_stage "boot" "fail" "$(since "$t0")" "No odoo-bin in the snapshot's odoo-base (the code checked out at its commit has no Odoo)"
    return 0
  fi

  # The drill's own login role (Odoo refuses to run as postgres) and its own configuration: no
  # production settings (mail, database host, admin password, proxy) are used
  pass=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
  if ! pg_exec -q -d postgres -c "CREATE ROLE odoo_drill LOGIN SUPERUSER PASSWORD '$pass';" >/dev/null 2>"$BOOT_DIR/role.err"; then
    record_stage "boot" "error" "$(since "$t0")" "Could not create the drill's database role: $(tr '\n' ' ' < "$BOOT_DIR/role.err")"
    return 1
  fi
  ( umask 022; cat > "$BOOT_DIR/drill.conf" <<EOF
[options]
addons_path = $ADDONS
data_dir = /var/lib/odoo-drill
db_host = $PG_CONTAINER
db_port = 5432
db_user = odoo_drill
db_password = $pass
db_name = $dbname
dbfilter = ^$dbname\$
list_db = False
admin_passwd = $(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
http_interface = 0.0.0.0
http_port = 8069
workers = 0
max_cron_threads = 0
server_wide_modules = base,web
proxy_mode = False
without_demo = all
smtp_server = localhost
limit_time_real = $VALIDATOR_BOOT_TIMEOUT
limit_time_cpu = $VALIDATOR_BOOT_TIMEOUT
log_level = info
EOF
    if [ -n "${SNAP_ENV[ODOO_ADDITIONAL_CONF]:-}" ] || [ -n "${SNAP_ENV[DEPCON_ENCRYPTION_SECRET]:-}" ]; then
      python3 - "${SNAP_ENV[ODOO_ADDITIONAL_CONF]:-}" "${SNAP_ENV[DEPCON_ENCRYPTION_SECRET]:-}" >> "$BOOT_DIR/drill.conf" <<'PY'
import re, sys
add_conf, depcon_secret = sys.argv[1], sys.argv[2]
PROTECTED = {
    "addons_path", "data_dir", "db_host", "db_port", "db_user", "db_password",
    "db_name", "dbfilter", "list_db", "admin_passwd", "http_interface", "http_port",
    "workers", "max_cron_threads", "server_wide_modules", "proxy_mode", "without_demo",
    "smtp_server", "limit_time_real", "limit_time_cpu", "log_level",
}
seen_depcon = False
for item in add_conf.split(";"):
    item = item.strip()
    if not item or "=" not in item:
        continue
    k, v = item.split("=", 1)
    k = k.strip()
    v = v.strip().replace("\r", "").replace("\n", "")
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_.-]*$", k) or k.lower() in PROTECTED:
        continue
    if k.lower() == "depcon_encryption_secret":
        seen_depcon = True
    print(f"{k} = {v}")
if depcon_secret and not seen_depcon:
    depcon_secret = depcon_secret.strip().replace("\r", "").replace("\n", "")
    if depcon_secret:
        print(f"depcon_encryption_secret = {depcon_secret}")
PY
    fi
  ) || { record_stage "boot" "error" "$(since "$t0")" "Cannot write the drill's Odoo configuration"; return 1; }

  # Neutralize first: crons, mail servers, payment providers... off (odoo-bin neutralize, Odoo 16+)
  major="${ODOO_VERSION%%.*}"
  if [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge 16 ]; then
    log_info "[boot] Neutralizing the restored database (odoo-bin neutralize)..."
    if boot_run "$NEUTRALIZE_CONTAINER" neutralize -c /etc/odoo-drill/drill.conf -d "$dbname"; then
      for i in $(seq "$VALIDATOR_BOOT_TIMEOUT"); do container_running "$NEUTRALIZE_CONTAINER" || break; sleep 1; done
      docker logs "$NEUTRALIZE_CONTAINER" > "$BOOT_DIR/neutralize.log" 2>&1
      if [ "$(docker inspect -f '{{.State.ExitCode}}' "$NEUTRALIZE_CONTAINER" 2>/dev/null)" = 0 ] && ! container_running "$NEUTRALIZE_CONTAINER"; then
        neutralized="odoo-bin neutralize"
      fi
      docker rm -fv "$NEUTRALIZE_CONTAINER" >/dev/null 2>&1
    fi
    if [ -z "$neutralized" ]; then
      result=$(boot_classify "$BOOT_DIR/neutralize.log" "$VALIDATOR_BOOT_STRICT" "-" "" "neutralize")
      if [ "$(head -n 1 <<< "$result")" = fail ]; then
        record_stage "boot" "fail" "$(since "$t0")" "$(tail -n +2 <<< "$result")"
        return 0
      fi
      record_stage "boot" "error" "$(since "$t0")" "{\"message\": \"odoo-bin neutralize did not finish, so Odoo was not started on the restored copy\", \"log_tail\": $(jstr "$(tail -n 15 "$BOOT_DIR/neutralize.log" 2>/dev/null; cat "$BOOT_DIR/run.err" 2>/dev/null)")}"
      return 1
    fi
  else
    log_info "[boot] Neutralizing the restored database (Odoo ${ODOO_VERSION:-?}: crons and mail servers off)..."
    if pg_exec -q -d "$dbname" >/dev/null 2>"$BOOT_DIR/neutralize.err" <<'SQL'
DO $do$ BEGIN
  IF to_regclass('public.ir_cron') IS NOT NULL THEN UPDATE ir_cron SET active = false; END IF;
  IF to_regclass('public.ir_mail_server') IS NOT NULL THEN UPDATE ir_mail_server SET active = false; END IF;
  IF to_regclass('public.fetchmail_server') IS NOT NULL THEN UPDATE fetchmail_server SET active = false; END IF;
END $do$;
SQL
    then neutralized="SQL (crons, outgoing and incoming mail servers off)"
    else
      record_stage "boot" "error" "$(since "$t0")" "Could not neutralize the restored database: $(tr '\n' ' ' < "$BOOT_DIR/neutralize.err")"
      return 1
    fi
  fi

  log_info "[boot] Starting Odoo on the restored copy (no cron, no workers, no outbound network)..."
  if ! boot_run "$ODOO_CONTAINER" -c /etc/odoo-drill/drill.conf -d "$dbname"; then
    record_stage "boot" "error" "$(since "$t0")" "Could not start the Odoo container: $(head -c 400 "$BOOT_DIR/run.err" | tr '\n' ' ')"
    return 1
  fi
  for i in $(seq "$VALIDATOR_BOOT_TIMEOUT"); do
    docker logs "$ODOO_CONTAINER" > "$BOOT_DIR/odoo.log" 2>&1
    if grep -qE 'Failed to initialize database|Failed to load registry' "$BOOT_DIR/odoo.log"; then registry=failed; break; fi
    if grep -q 'Registry loaded in' "$BOOT_DIR/odoo.log"; then registry=loaded; break; fi
    container_running "$ODOO_CONTAINER" || { registry=exited; break; }
    sleep 1
  done
  if [ "$registry" = loaded ] || [ "$registry" = failed ]; then
    # From inside the container, so nothing has to be published on the host
    result=$(docker exec "$ODOO_CONTAINER" python3 -c '
import configparser, sys, urllib.parse, urllib.request, urllib.error
c = configparser.ConfigParser(interpolation=None); c.read(sys.argv[1])
port = c.get("options", "http_port", fallback="8069")
try:
    r = urllib.request.urlopen("http://127.0.0.1:%s/web/login" % port, timeout=float(sys.argv[2]))
    print(r.status, urllib.parse.urlparse(r.geturl()).path)
except urllib.error.HTTPError as e:
    print(e.code, urllib.parse.urlparse(e.geturl() or "").path)
except Exception as e:
    print("no-answer", "")
' /etc/odoo-drill/drill.conf "$VALIDATOR_BOOT_TIMEOUT" 2>/dev/null | tail -n 1)
    http="${result%% *}"; path="${result#* }"; [ "$path" = "$result" ] && path=""
    sleep 1
    docker logs "$ODOO_CONTAINER" > "$BOOT_DIR/odoo.log" 2>&1
  fi
  docker rm -fv "$ODOO_CONTAINER" >/dev/null 2>&1
  result=$(boot_classify "$BOOT_DIR/odoo.log" "$VALIDATOR_BOOT_STRICT" "${http:-none}" "$path" "$registry")
  status=$(head -n 1 <<< "$result")
  details=$(python3 -c 'import json,sys
d = json.loads(sys.argv[1]); d.update({"odoo_bin": sys.argv[2], "addons_path": sys.argv[3].split(",") if sys.argv[3] else [],
  "neutralized": sys.argv[4], "image": sys.argv[5]})
notes = [n for n in sys.argv[6].split("\n") if n]
if notes: d["notes"] = notes
print(json.dumps(d))' "$(tail -n +2 <<< "$result")" "$ODOO_BIN" "$ADDONS" "$neutralized" "$BOOT_IMAGE" "$(printf '%s\n' "${LAYOUT_NOTES[@]}")")
  record_stage "boot" "$status" "$(since "$t0")" "$details"
  case "$status" in pass|warn) DRILL_LEVEL="boot" ;; esac
  return 0
}

phase2() {
  local t0
  t0=$(now_s)
  if [ "$VALIDATOR_BOOT" != true ]; then
    record_stage "boot" "skip" 0 "Disabled with --no-boot (VALIDATOR_BOOT=false): the drill stopped at the database level"
    return
  fi
  if [ "$(python3 -c 'import json,sys; print(next((s["status"] for s in map(json.loads, filter(str.strip, open(sys.argv[1]))) if s["name"] == "git"), ""))' "$STAGES_FILE")" != pass ]; then
    record_stage "boot" "skip" 0 "Needs the git check to pass (the code is checked out at the commits it proved), so Odoo was not started"
    return
  fi
  boot_prepare || { record_stage "boot" "error" "$(since "$t0")" "Cannot create $BOOT_DIR"; return; }
  stage_code || return
  stage_image || return
  stage_boot
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
phase2

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
