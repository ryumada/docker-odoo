#!/usr/bin/env bash
set -o pipefail
# Category: Utility
# Description: Drill worker for one deployment: when a drill is due (VALIDATOR_MIN_INTERVAL_HOURS), runs validate-snapshot.sh --publish on the newest snapshot: the one waiting in the validator inbox on the Secondary VPS, else the newest on Google Drive, GCS or in the local archives, unless the last drill already proved it.
# Usage: ./scripts/validate-snapshot-worker.sh [--status] [--force] [-h]   (cron: /etc/cron.d/validate-snapshot-<service>, every hour)
# Dependencies: scripts/validate-snapshot.sh (and its dependencies), python3, flock
#
# When a drill is due (the clock starts at the start of the last drill of this deployment, manual
# drills included, from the reports in ~<owner>/.odoo-validator/reports):
#   - after a pass or a fail ("snapshot broken"): VALIDATOR_MIN_INTERVAL_HOURS (default 24)
#   - after an error (nothing proven: Docker, network, build, ...): a quarter of that, at least 1 hour
#   - never drilled: now
# What it drills, in order:
#   1. --inbox: the snapshot waiting in the validator inbox on the Secondary VPS (SNAPSHOT_REMOTE_HOST
#      and SNAPSHOT_VALIDATOR_INBOX=true). No download; always a new snapshot.
#   2. Otherwise the newest snapshot where the snapshot tool stores them: Google Drive (--drive), GCS
#      (--gcs), the copy kept on the Secondary VPS, or the newest folder in this host's local archives,
#      skipped (--unless-checksum) when it is the snapshot the last pass or fail already proved.
# Nothing to drill is not an error: the worker exits 0 and tries again at the next tick.
# VALIDATOR_LOCAL_SNAPSHOTS_DIR (default ~<owner>/.odoo-snapshots) says where local snapshots are looked for (tests).
# Exit codes: the drill's (0 passed or nothing to do, 1 broken, 2 error, 3 configuration, 4 passed
# without a record); 0 when the worker is off, not due, or the previous run is still going.

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
PATH_TO_ODOO=$(git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$CURRENT_DIR")
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
VALIDATOR="$CURRENT_DIR/validate-snapshot.sh"
umask 077

readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[0;31m"
log() { echo -e "${1}[$(date +"%Y-%m-%d %H:%M:%S")] ${2} [worker] ${3}${COLOR_RESET}" >&2; }
log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_warn() { log "${COLOR_WARN}" "⚠️" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }

show_help() {
  cat << EOF
Usage: $(basename "$0") [--status] [--force]

Drill worker for this deployment ($SERVICE_NAME). Run every hour by
/etc/cron.d/validate-snapshot-$SERVICE_NAME when VALIDATOR_WORKER=true in .env
(installed by ./setup.sh). Each run drills the newest snapshot with --publish when a
drill is due, and does nothing otherwise.

  --status   Show the last drills, when the next one is due and what it would drill (nothing runs)
  --force    Drill now, even when VALIDATOR_WORKER is off or no drill is due yet
             (a snapshot the last drill already proved is still skipped)
  -h, --help Show this help

Settings (.env): VALIDATOR_WORKER (true/false, default false), VALIDATOR_MIN_INTERVAL_HOURS
(default 24: after a pass or fail, the next drill waits this long; after an error a quarter of it,
at least 1 hour). The drill itself uses validate-snapshot.sh's settings.
EOF
}

STATUS=false FORCE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --status) STATUS=true; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help) show_help; exit 0 ;;
    *) log_error "Unknown option: $1"; show_help; exit 3 ;;
  esac
done

env_get() {
  [ -f "$PATH_TO_ODOO/.env" ] || return 0
  grep "^$1=" "$PATH_TO_ODOO/.env" 2>/dev/null | tail -n1 | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//'
}
cfg() { local v="${!1:-}"; [ -n "$v" ] || v=$(env_get "$1"); [ -n "$v" ] || v="$2"; echo "$v"; }

VALIDATOR_WORKER=$(cfg VALIDATOR_WORKER false)
VALIDATOR_MIN_INTERVAL_HOURS=$(cfg VALIDATOR_MIN_INTERVAL_HOURS 24)
SNAPSHOT_REMOTE_HOST=$(cfg SNAPSHOT_REMOTE_HOST "")
SNAPSHOT_VALIDATOR_INBOX=$(cfg SNAPSHOT_VALIDATOR_INBOX false)
GDRIVE_ACCESS_TOKEN=$(cfg GDRIVE_ACCESS_TOKEN "")
GDRIVE_SERVICE_ACCOUNT_KEY=$(cfg GDRIVE_SERVICE_ACCOUNT_KEY "")
GCS_BUCKET_NAME=$(cfg GCS_BUCKET_NAME "")

bad=()
[[ "$VALIDATOR_WORKER" =~ ^(true|false)$ ]] || bad+=("VALIDATOR_WORKER='$VALIDATOR_WORKER' (true or false)")
if ! [[ "$VALIDATOR_MIN_INTERVAL_HOURS" =~ ^[1-9][0-9]{0,3}$ ]] || [ "$VALIDATOR_MIN_INTERVAL_HOURS" -gt 8760 ]; then
  bad+=("VALIDATOR_MIN_INTERVAL_HOURS='$VALIDATOR_MIN_INTERVAL_HOURS' (whole hours, 1 to 8760)")
fi
[[ "$SNAPSHOT_VALIDATOR_INBOX" =~ ^(true|false)$ ]] || bad+=("SNAPSHOT_VALIDATOR_INBOX='$SNAPSHOT_VALIDATOR_INBOX' (true or false)")
if [ ${#bad[@]} -gt 0 ]; then
  for b in "${bad[@]}"; do log_error "Invalid setting: $b"; done
  exit 3
fi
[ -f "$VALIDATOR" ] || { log_error "$VALIDATOR not found. Update docker-odoo (git pull)."; exit 3; }

if [ "$VALIDATOR_WORKER" != true ] && [ "$FORCE" != true ] && [ "$STATUS" != true ]; then
  log_info "VALIDATOR_WORKER is not true in .env: automatic drills of $SERVICE_NAME are off."
  exit 0
fi

# Reports live where validate-snapshot.sh writes them: the deployment owner's home (or VALIDATOR_WORK_DIR)
DEPLOY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO" 2>/dev/null)
OWNER_HOME=$(getent passwd "$DEPLOY_OWNER" 2>/dev/null | cut -d: -f6)
if [ -n "$OWNER_HOME" ] && [ -d "$OWNER_HOME" ] && { [ "$(id -u)" = 0 ] || [ "$(id -un)" = "$DEPLOY_OWNER" ]; }; then
  default_dir="$OWNER_HOME/.odoo-validator"; snapshots_home="$OWNER_HOME"
else
  default_dir="$HOME/.odoo-validator"; snapshots_home="$HOME"
fi
VALIDATOR_DIR=$(cfg VALIDATOR_WORK_DIR "$default_dir")
# Local snapshots (no Secondary VPS): the snapshot tool keeps them in ~<owner>/.odoo-snapshots/<service>/archives
LOCAL_SNAPSHOTS_DIR=$(cfg VALIDATOR_LOCAL_SNAPSHOTS_DIR "$snapshots_home/.odoo-snapshots")

# --- One worker run per deployment at a time (a drill can wait hours in the drill queue) ---
LOCK_FILE="${QUEUE_LOCK_DIR:-/tmp}/odoo-snapshot-validator-worker.$(printf '%s' "$SERVICE_NAME" | sed 's|[^a-zA-Z0-9._-]|_|g').lock"
if [ "$STATUS" != true ]; then
  # Opened read-only (fs.protected_regular never blocks it, whoever created it first), like the queue lock
  [ -e "$LOCK_FILE" ] || ( umask 022; : >> "$LOCK_FILE" ) 2>/dev/null
  if ! exec {LOCK_FD}<"$LOCK_FILE"; then
    log_error "Cannot open the worker lock $LOCK_FILE."
    exit 2
  fi
  if ! flock -n "$LOCK_FD"; then
    log_info "The previous worker run for $SERVICE_NAME is still going (its drill may be waiting in the drill queue); nothing to do."
    exit 0
  fi
fi

# --- When is the next drill due? ---
# Prints: due(yes|no) due_epoch last_pf_result last_pf_started last_pf_sha last_err_started (each "-" when unknown)
STATE=$(python3 - "$VALIDATOR_DIR/reports" "$SERVICE_NAME" "$VALIDATOR_MIN_INTERVAL_HOURS" "$(date +%s)" <<'PY'
import calendar, glob, json, os, sys, time
reports, service, hours, now = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
runs = []
for p in glob.glob(os.path.join(reports, "*.json")):
    if os.path.basename(p).startswith("latest-") or os.path.islink(p):
        continue
    try:
        r = json.load(open(p))
        if r.get("service") != service or r.get("result") not in ("pass", "fail", "error"):
            continue
        t = calendar.timegm(time.strptime(r["started_at"], "%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        continue
    runs.append((t, r["result"], r.get("sha256") or ""))
runs.sort()
pf = [x for x in runs if x[1] in ("pass", "fail")]
last_pf = pf[-1] if pf else None
errs = [x for x in runs if x[1] == "error" and (not last_pf or x[0] > last_pf[0])]
last_err = errs[-1] if errs else None
slack = 600   # a drill starts a little after the cron tick: never wait a whole extra hour for that
due_at = 0
if last_pf:
    due_at = last_pf[0] + hours * 3600 - slack
if last_err:
    due_at = max(due_at, last_err[0] + max(3600, hours * 900) - slack)
print("yes" if now >= due_at else "no", due_at,
      last_pf[1] if last_pf else "-", last_pf[0] if last_pf else "-", (last_pf[2] or "-") if last_pf else "-",
      last_err[0] if last_err else "-")
PY
) || { log_error "Cannot read the drill reports in $VALIDATOR_DIR/reports."; exit 2; }
read -r DUE DUE_AT LAST_PF LAST_PF_AT PROVEN_SHA LAST_ERR_AT <<< "$STATE"
[ "$PROVEN_SHA" = "-" ] && PROVEN_SHA=""
when() { [ "$1" = "-" ] && echo "never" || date -d "@$1" +"%Y-%m-%d %H:%M:%S %Z"; }

# --- What would be drilled ---
FALLBACK=() FALLBACK_DESC=""
if [ -n "$GDRIVE_SERVICE_ACCOUNT_KEY" ] || [ -n "$GDRIVE_ACCESS_TOKEN" ]; then
  FALLBACK=(--drive "$SERVICE_NAME"); FALLBACK_DESC="the newest snapshot on Google Drive"
elif [ -n "$GCS_BUCKET_NAME" ]; then
  FALLBACK=(--gcs "gs://$GCS_BUCKET_NAME/snapshot-$SERVICE_NAME.tar.zst"); FALLBACK_DESC="gs://$GCS_BUCKET_NAME/snapshot-$SERVICE_NAME.tar.zst"
elif [ -n "$SNAPSHOT_REMOTE_HOST" ]; then
  # The snapshot tool keeps one copy per deployment on the Secondary VPS when there is no upload (path relative to its home)
  FALLBACK=(--file ".odoo-snapshots/$SERVICE_NAME/archives/snapshot-$SERVICE_NAME.tar.zst")
  FALLBACK_DESC="the copy kept on the Secondary VPS (~/.odoo-snapshots/$SERVICE_NAME/archives)"
else
  newest=$(for d in "$LOCAL_SNAPSHOTS_DIR/$SERVICE_NAME/archives/snapshot-$SERVICE_NAME.tar.zst-"*/; do
             d="${d%/}"
             [[ "${d##*/}" =~ ^snapshot-.+\.tar\.zst-[0-9]{8}-[0-9]{6}$ ]] && [ -f "$d/snapshot-$SERVICE_NAME.tar.zst" ] && echo "$d"
           done | sort -r | head -n 1)
  if [ -n "$newest" ]; then
    FALLBACK=(--file "$newest/snapshot-$SERVICE_NAME.tar.zst"); FALLBACK_DESC="$newest/snapshot-$SERVICE_NAME.tar.zst (newest local archive)"
  fi
fi
USE_INBOX=false
[ -n "$SNAPSHOT_REMOTE_HOST" ] && [ "$SNAPSHOT_VALIDATOR_INBOX" = true ] && USE_INBOX=true

if [ "$STATUS" = true ]; then
  echo "Deployment:        $SERVICE_NAME"
  echo "Worker:            $([ "$VALIDATOR_WORKER" = true ] && echo on || echo "off (VALIDATOR_WORKER=$VALIDATOR_WORKER)")"
  echo "Interval:          ${VALIDATOR_MIN_INTERVAL_HOURS}h after a pass or fail, $(python3 -c "print('%g' % max(1, $VALIDATOR_MIN_INTERVAL_HOURS / 4))")h after an error"
  echo "Last pass/fail:    $([ "$LAST_PF" = "-" ] && echo never || echo "$LAST_PF, started $(when "$LAST_PF_AT")")"
  echo "Last error since:  $(when "$LAST_ERR_AT")"
  echo "Due:               $DUE$([ "$DUE" = no ] && echo " (at $(when "$DUE_AT"))")"
  echo "Drills (in order): $([ "$USE_INBOX" = true ] && echo "the validator inbox on $SNAPSHOT_REMOTE_HOST, then ")${FALLBACK_DESC:-nothing found}"
  [ -n "$PROVEN_SHA" ] && echo "Already proved:    sha256 $PROVEN_SHA (skipped)"
  exit 0
fi

if [ "$DUE" != yes ] && [ "$FORCE" != true ]; then
  log_info "No drill of $SERVICE_NAME is due before $(when "$DUE_AT") (last pass/fail: $([ "$LAST_PF" = "-" ] && echo never || echo "$LAST_PF, $(when "$LAST_PF_AT")")$([ "$LAST_ERR_AT" != "-" ] && echo "; error since: $(when "$LAST_ERR_AT")"))."
  exit 0
fi
[ -n "$SNAPSHOT_REMOTE_HOST" ] || log_warn "SNAPSHOT_REMOTE_HOST is not set: the drill runs on this host (Docker here, at the lowest priority)."

# The drill never inherits the worker lock: only this process holds it, so it ends with this run
rc=5
if [ "$USE_INBOX" = true ]; then
  log_info "A drill of $SERVICE_NAME is due: looking in the validator inbox on $SNAPSHOT_REMOTE_HOST."
  "$VALIDATOR" --inbox "$SERVICE_NAME" --publish </dev/null {LOCK_FD}<&-
  rc=$?
fi
if [ "$rc" = 5 ]; then
  if [ ${#FALLBACK[@]} -eq 0 ]; then
    log_info "No snapshot of $SERVICE_NAME found to drill (no upload configured and no local archive in $LOCAL_SNAPSHOTS_DIR/$SERVICE_NAME/archives)."
    exit 0
  fi
  log_info "A drill of $SERVICE_NAME is due: drilling $FALLBACK_DESC$([ -n "$PROVEN_SHA" ] && echo ", unless it is the one already proved")."
  "$VALIDATOR" "${FALLBACK[@]}" --publish ${PROVEN_SHA:+--unless-checksum "$PROVEN_SHA"} </dev/null {LOCK_FD}<&-
  rc=$?
fi
case "$rc" in
  0) log_success "Drill of $SERVICE_NAME passed." ;;
  1) log_error "Drill of $SERVICE_NAME FAILED: the snapshot is not recoverable as it is (see the report). Next drill in ${VALIDATOR_MIN_INTERVAL_HOURS}h, or as soon as a new snapshot is there after that." ;;
  2) log_warn "Drill of $SERVICE_NAME could not finish (nothing proven); it is tried again in $(python3 -c "print('%g' % max(1, $VALIDATOR_MIN_INTERVAL_HOURS / 4))")h." ;;
  3) log_error "Drill of $SERVICE_NAME could not start: configuration problem (see above)." ;;
  4) log_warn "Drill of $SERVICE_NAME passed, but its validation record could not be written (see the report)." ;;
  5) log_info "Nothing new to drill for $SERVICE_NAME: the newest snapshot is the one the last drill already proved."; rc=0 ;;
esac
exit "$rc"
