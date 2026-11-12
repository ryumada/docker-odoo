#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: Validator inbox hand-off on the Secondary VPS: snap_inbox_handoff (scripts/lib/snapshot_storage.sh)
#              and the snapshot tool's remote_inbox_handoff. A remote snapshot is moved (never copied) or
#              hard-linked into ~/.odoo-validator/inbox/<service>/<archive>/ with its checksum and job.json,
#              only the newest pending job per service stays, a job a worker already took is never touched,
#              and nothing is kept when the disk would go below the reserve.
# Usage: ./tests/test_validator_inbox.sh
# Dependencies: bash, python3, sha256sum, df
#
# Safe on a real machine: everything happens in one mktemp folder; "ssh to the Secondary VPS" is a local bash,
# and gcloud is a stand-in that only prints a generation number.

readonly C_RESET="\033[0m" C_PASS="\033[0;32m" C_FAIL="\033[0;31m" C_SKIP="\033[1;33m" C_INFO="\033[0;34m"
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
passed=0 failed=0 skipped=0
pass() { echo -e "${C_PASS}  [PASS] $1${C_RESET}"; passed=$((passed + 1)); }
fail() { echo -e "${C_FAIL}  [FAIL] $1${C_RESET}"; failed=$((failed + 1)); }
skip() { echo -e "${C_SKIP}  [SKIP] $1: $2${C_RESET}"; skipped=$((skipped + 1)); }
section() { echo -e "${C_INFO}== $1 ==${C_RESET}"; }
check_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi; }
for c in python3 sha256sum df; do command -v "$c" >/dev/null 2>&1 || { echo "Missing dependency: $c" >&2; exit 3; }; done

T=$(mktemp -d "${TMPDIR:-/tmp}/test_validator_inbox.XXXXXX") || exit 3
SHM=""
trap 'rm -rf "$T"; [ -n "$SHM" ] && rm -rf "$SHM"' EXIT
mkdir -p "$T/bin" "$T/home/.odoo-validator" "$T/stage" "$T/archives"
cat > "$T/bin/gcloud" <<'SHIM'
#!/usr/bin/env bash
[ "$1 $2 $3" = "storage objects describe" ] && { echo 1731100000123456; exit 0; }
exit 1
SHIM
chmod +x "$T/bin/gcloud"
export PATH="$T/bin:$PATH"
INBOX="$T/home/.odoo-validator/inbox"

new_archive() {
  # new_archive PATH: an archive with a correct .sha256 next to it (named as on the Secondary VPS)
  head -c 4096 /dev/urandom > "$1"
  printf '%s  %s\n' "$(sha256sum "$1" | cut -d' ' -f1)" "$(basename "$1")" > "$1.sha256"
}
handoff() {
  # handoff ARGS...: snap_inbox_handoff in a subshell, output in $T/out; sets RC
  ( log_info() { echo "INFO $1"; }; log_success() { echo "OK $1"; }; log_warn() { echo "WARN $1"; }; log_error() { echo "ERROR $1"; }
    source "$REPO/scripts/lib/snapshot_storage.sh"; snap_inbox_handoff "$@" ) > "$T/out" 2>&1
  RC=$?
}
jobs_of() { ls -A "$INBOX/$1" 2>/dev/null | grep -v '^\.' | tr '\n' ' ' | sed 's/ $//'; }
job() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=eval(sys.argv[2]); print("null" if v is None else v)' "$1" "$2" 2>&1; }
DRIVE_NAME=snapshot-svc-20261109-073000.tar.zst

# ---------------------------------------------------------------------------------------------------
section "uploaded snapshot: moved into the inbox"
new_archive "$T/stage/snapshot-svc.tar.zst"
HASH=$(cut -d' ' -f1 "$T/stage/snapshot-svc.tar.zst.sha256")
printf '%s\t%s\n' "$DRIVE_NAME" "1AbCdriveId" > "$T/stage/.drive-upload"
handoff "$T/stage/snapshot-svc.tar.zst" move "$INBOX" svc 0 prd-vps "$T/stage/.drive-upload" "gs://bucket/snapshot-svc.tar.zst" ""
J="$INBOX/svc/$DRIVE_NAME"
check_eq "handed off" 0 "$RC"
check_eq "one job, named as the snapshot is named on Drive" "$DRIVE_NAME" "$(jobs_of svc)"
check_eq "the archive was moved, not copied" "gone" "$([ -e "$T/stage/snapshot-svc.tar.zst" ] && echo still-there || echo gone)"
check_eq "its checksum file names the archive's new name and still matches" "$DRIVE_NAME: OK" "$(cd "$J" && sha256sum -c "$DRIVE_NAME.sha256" 2>&1)"
check_eq "job.json: service, archive and sha256" "svc $DRIVE_NAME $HASH" "$(job "$J/job.json" '" ".join([d["service"], d["archive"], d["sha256"]])')"
check_eq "job.json: the Drive copy (to record the drill next to it)" "$DRIVE_NAME 1AbCdriveId" "$(job "$J/job.json" 'd["drive"]["name"] + " " + d["drive"]["file_id"]')"
check_eq "job.json: the GCS object and its generation" "gs://bucket/snapshot-svc.tar.zst 1731100000123456" "$(job "$J/job.json" 'd["gcs"]["object"] + " " + str(d["gcs"]["generation"])')"
check_eq "job.json: the primary VPS, no extra kept copy" "prd-vps null" "$(job "$J/job.json" 'd["source_host"] + " " + str(d["kept_copy"] or "null")')"
check_eq "the inbox is private to the drill user" "700 700" "$(stat -c %a "$INBOX") $(stat -c %a "$INBOX/svc")"
check_eq "no half-written folders are left" "" "$(ls -A "$INBOX/svc" | grep '^\.' || true)"

section "a newer snapshot replaces the pending one"
new_archive "$T/stage/snapshot-svc.tar.zst"
printf '%s\t%s\n' "snapshot-svc-20261110-073000.tar.zst" "2NextId" > "$T/stage/.drive-upload"
handoff "$T/stage/snapshot-svc.tar.zst" move "$INBOX" svc 0 prd-vps "$T/stage/.drive-upload" "" ""
check_eq "handed off" 0 "$RC"
check_eq "only the newest pending job stays" "snapshot-svc-20261110-073000.tar.zst" "$(jobs_of svc)"
check_eq "and the log says so" yes "$(grep -q "replaced the older pending snapshot $DRIVE_NAME" "$T/out" && echo yes || echo no)"
check_eq "not on GCS: no gcs block" null "$(job "$INBOX/svc/snapshot-svc-20261110-073000.tar.zst/job.json" 'd["gcs"]')"

section "a job the worker already took is never touched"
mkdir -p "$T/processing"
mv "$INBOX/svc/snapshot-svc-20261110-073000.tar.zst" "$T/processing/"
new_archive "$T/stage/snapshot-svc.tar.zst"
printf '%s\t%s\n' "snapshot-svc-20261111-073000.tar.zst" "3Id" > "$T/stage/.drive-upload"
handoff "$T/stage/snapshot-svc.tar.zst" move "$INBOX" svc 0 prd-vps "$T/stage/.drive-upload" "" ""
check_eq "the taken job is still complete" "3" "$(ls "$T/processing/snapshot-svc-20261110-073000.tar.zst" | wc -l)"
check_eq "the new one is pending" "snapshot-svc-20261111-073000.tar.zst" "$(jobs_of svc)"

section "a copy kept on the Secondary VPS: hard-linked, never copied"
new_archive "$T/archives/snapshot-svc.tar.zst"
: > "$T/stage/.drive-upload"
handoff "$T/archives/snapshot-svc.tar.zst" link "$INBOX" svc 0 prd-vps "$T/stage/.drive-upload" "" "$T/archives/snapshot-svc.tar.zst"
NAME=$(jobs_of svc)
check_eq "handed off" 0 "$RC"
check_eq "named with the hand-off time when it is not on Drive" yes "$([[ "$NAME" =~ ^snapshot-svc-[0-9]{8}-[0-9]{6}\.tar\.zst$ ]] && echo yes || echo "no ($NAME)")"
check_eq "the kept copy stays where it is" yes "$([ -f "$T/archives/snapshot-svc.tar.zst" ] && [ -f "$T/archives/snapshot-svc.tar.zst.sha256" ] && echo yes || echo no)"
check_eq "the inbox entry is the same file (hard link, no extra disk)" "2" "$(stat -c %h "$T/archives/snapshot-svc.tar.zst")"
check_eq "job.json: the kept copy and no Drive copy" "$T/archives/snapshot-svc.tar.zst null" "$(job "$INBOX/svc/$NAME/job.json" 'd["kept_copy"] + " " + str(d["drive"] or "null")')"

section "other deployments are separate"
new_archive "$T/stage/snapshot-other.tar.zst"
: > "$T/stage/.drive-upload"
handoff "$T/stage/snapshot-other.tar.zst" move "$INBOX" other 0 prd-vps "$T/stage/.drive-upload" "" ""
check_eq "the other deployment gets its own pending job" 1 "$(jobs_of other | wc -w)"
check_eq "and this one keeps its own" "$NAME" "$(jobs_of svc)"

section "not enough disk: nothing kept, nothing changed"
new_archive "$T/stage/snapshot-svc.tar.zst"
handoff "$T/stage/snapshot-svc.tar.zst" move "$INBOX" svc 999999 prd-vps "" "" ""
check_eq "skipped (code 2)" 2 "$RC"
check_eq "says why" yes "$(grep -q 'not kept for a drill' "$T/out" && echo yes || echo no)"
check_eq "the archive is where it was" yes "$([ -f "$T/stage/snapshot-svc.tar.zst" ] && echo yes || echo no)"
check_eq "the pending job is untouched" "$NAME" "$(jobs_of svc)"

section "a kept copy on another disk is not copied"
if [ -d /dev/shm ] && [ -w /dev/shm ] && [ "$(stat -c %d /dev/shm)" != "$(stat -c %d "$T")" ]; then
  SHM=$(mktemp -d /dev/shm/test_validator_inbox.XXXXXX)
  new_archive "$SHM/snapshot-svc.tar.zst"
  handoff "$SHM/snapshot-svc.tar.zst" link "$INBOX" svc 0 prd-vps "" "" "$SHM/snapshot-svc.tar.zst"
  check_eq "skipped (code 2)" 2 "$RC"
  check_eq "the pending job is untouched" "$NAME" "$(jobs_of svc)"
else
  skip "kept copy on another disk" "no second filesystem (/dev/shm) to try it on"
fi

# ---------------------------------------------------------------------------------------------------
section "snapshot tool: remote_inbox_handoff (what is sent to the Secondary VPS)"
SNAP="$REPO/scripts/example/snapshot.sh.example"
FN=$(python3 - "$SNAP" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
for i, l in enumerate(lines):
    if re.match(r"^function remote_inbox_handoff\(\) \{", l):
        j = next(k for k in range(i, len(lines)) if lines[k].rstrip() == "}")
        print("\n".join(lines[i:j + 1])); break
else:
    sys.exit(1)
PY
) || { fail "remote_inbox_handoff not found in the snapshot tool"; FN=""; }
if [ -n "$FN" ]; then
  RHOME="$T/rhome"; mkdir -p "$RHOME" "$T/rstage"
  new_archive "$T/rstage/snapshot-svc.tar.zst"
  printf '%s\t%s\n' "snapshot-svc-20261112-010203.tar.zst" "4Id" > "$T/rstage/.drive-upload"
  ( COLOR_RESET="" COLOR_INFO="" COLOR_SUCCESS="" COLOR_WARN="" COLOR_ERROR=""
    log() { echo "$3"; }; log_info() { log "" "" "$1"; }; log_success() { log "" "" "$1"; }
    log_warn() { log "" "" "$1"; }; log_error() { log "" "" "$1"; }
    source "$REPO/scripts/lib/snapshot_storage.sh"
    remote_exec() { bash -c "$1"; }   # "ssh <secondary> bash -s" reading the script from stdin
    eval "$FN"
    remote_home="$RHOME" remote_staging="$T/rstage" SERVICE_NAME=svc VALIDATOR_DISK_RESERVE_GB=0
    remote_inbox_handoff move "$T/rstage/snapshot-svc.tar.zst" "" "gs://bucket/snapshot-svc.tar.zst"
  ) > "$T/out" 2>&1
  RC=$?
  check_eq "the remote script runs and hands off" 0 "$RC"
  check_eq "into ~/.odoo-validator/inbox on the Secondary VPS" "snapshot-svc-20261112-010203.tar.zst" "$(ls "$RHOME/.odoo-validator/inbox/svc" 2>/dev/null)"
  check_eq "job.json names this host as the source" "$(hostname -f 2>/dev/null || hostname)" \
    "$(job "$RHOME/.odoo-validator/inbox/svc/snapshot-svc-20261112-010203.tar.zst/job.json" 'd["source_host"]')"
fi
check_eq "the uploaded archive is handed off (moved) when the upload succeeded" 1 "$(grep -c 'remote_inbox_handoff move "$remote_staging/snapshot-$SERVICE_NAME.tar.zst"' "$SNAP")"
check_eq "the kept archive is handed off (linked) when it stays on the Secondary VPS" 2 "$(grep -c 'remote_inbox_handoff link "$remote_archives/snapshot-$SERVICE_NAME.tar.zst"' "$SNAP")"
check_eq "only when SNAPSHOT_VALIDATOR_INBOX is true" 3 "$(grep -cF 'if [ "$SNAPSHOT_VALIDATOR_INBOX" = true ]' "$SNAP")"
check_eq "the Drive upload records the name and id it used" 1 "$(grep -cF "printf '%s\\t%s\\n' \"\$file_name\" \"\$uploaded_id\" > \"\$SNAP_UPLOAD_RESULT\"" "$SNAP")"
check_eq ".env.example: empty (automatic: on with a Secondary VPS)" "SNAPSHOT_VALIDATOR_INBOX=" "$(grep '^SNAPSHOT_VALIDATOR_INBOX=' "$REPO/.env.example")"
check_eq "the snapshot tool decides an empty value like the worker (drill_resolve_inbox)" 1 "$(grep -c 'drill_resolve_inbox "$SNAPSHOT_VALIDATOR_INBOX" "$SNAPSHOT_REMOTE_HOST"' "$SNAP")"

echo
echo -e "Results: ${C_PASS}$passed passed${C_RESET}, ${C_FAIL}$failed failed${C_RESET}, ${C_SKIP}$skipped skipped${C_RESET}"
[ "$failed" -eq 0 ]
