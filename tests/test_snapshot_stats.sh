#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: Snapshot disk statistics on the Secondary VPS (scripts/lib/snapshot_storage.sh): stats.json
#              written after each remote snapshot (snap_write_stats, and the snapshot tool's
#              remote_write_stats), and the disk reserve read from it (snap_stats_reserve,
#              snap_disk_reserve_bytes) by the validator and the validator inbox hand-off.
# Usage: ./tests/test_snapshot_stats.sh
# Dependencies: bash, python3, sha256sum, df, stat, find
#
# Safe on a real machine: everything happens in one mktemp folder (plus one in /dev/shm for the
# other-disk case, when it is a separate filesystem); "ssh to the Secondary VPS" is a local bash.

readonly C_RESET="\033[0m" C_PASS="\033[0;32m" C_FAIL="\033[0;31m" C_SKIP="\033[1;33m" C_INFO="\033[0;34m"
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
passed=0 failed=0 skipped=0
pass() { echo -e "${C_PASS}  [PASS] $1${C_RESET}"; passed=$((passed + 1)); }
fail() { echo -e "${C_FAIL}  [FAIL] $1${C_RESET}"; failed=$((failed + 1)); }
skip() { echo -e "${C_SKIP}  [SKIP] $1: $2${C_RESET}"; skipped=$((skipped + 1)); }
section() { echo -e "${C_INFO}== $1 ==${C_RESET}"; }
check_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi; }
for c in python3 sha256sum df stat find; do command -v "$c" >/dev/null 2>&1 || { echo "Missing dependency: $c" >&2; exit 3; }; done

T=$(mktemp -d "${TMPDIR:-/tmp}/test_snapshot_stats.XXXXXX") || exit 3
SHM=""
trap 'rm -rf "$T"; [ -n "$SHM" ] && rm -rf "$SHM"' EXIT
GB=$((1024 * 1024 * 1024))

lib() {  # lib FUNCTION ARGS...: one library function in a subshell (log output in $T/out)
  ( log_info() { echo "INFO $1"; }; log_success() { echo "OK $1"; }; log_warn() { echo "WARN $1"; }; log_error() { echo "ERROR $1"; }
    source "$REPO/scripts/lib/snapshot_storage.sh"; "$@" ) 2>"$T/err"
}
j() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=eval(sys.argv[2]); print("null" if v is None else v)' "$1" "$2" 2>&1; }
stats() {  # stats ROOT SERVICE NEED [AGE_DAYS]: a stats.json as the snapshot tool writes it
  mkdir -p "$1/$2"
  lib snap_write_stats "$1/$2/stats.json" "$2" prd-vps "$3" 0 "" ""
  [ -n "${4:-}" ] && touch -d "$4 days ago" "$1/$2/stats.json"
  return 0
}

# ---------------------------------------------------------------------------------------------------------
section "stats.json after a snapshot"
S="$T/home/.odoo-snapshots"; mkdir -p "$S/svc"
F="$S/svc/stats.json"
lib snap_write_stats "$F" svc prd-vps 3000 1000 10000000 9990000
check_eq "written" 0 "$?"
check_eq "valid JSON with the sizes" "1 svc prd-vps 3000 1000" "$(j "$F" '" ".join(str(x) for x in [d["schema"], d["service"], d["source_host"], d["dump_bytes"], d["archive_bytes"]])')"
check_eq "peak = free space before minus free space at the fullest point" 10000 "$(j "$F" 'd["peak_bytes"]')"
check_eq "need = the larger of the peak and dump + archive" 10000 "$(j "$F" 'd["need_bytes"]')"
check_eq "updated_at is UTC" yes "$(j "$F" 'd["updated_at"]' | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' && echo yes || echo no)"
check_eq "private to the snapshot user" 600 "$(stat -c %a "$F")"
check_eq "no temporary file left" "" "$(ls -A "$S/svc" | grep -v '^stats.json$' || true)"
lib snap_write_stats "$F" svc prd-vps 3000 1000 9990000 10000000
check_eq "free space grew meanwhile (a drill ended): no peak, need = dump + archive" "null 4000" "$(j "$F" 'd["peak_bytes"]') $(j "$F" 'd["need_bytes"]')"
lib snap_write_stats "$F" svc prd-vps "" "x" "" ""
check_eq "nothing measured: zeros and null, still valid JSON" "0 0 None 0" "$(j "$F" '" ".join(str(x) for x in [d["dump_bytes"], d["archive_bytes"], d["peak_bytes"], d["need_bytes"]])')"
lib snap_write_stats "$F" 'sv"c\' 'host"x' 1 1 "" ""
check_eq "quotes in names cannot break the JSON" "svc hostx" "$(j "$F" 'd["service"] + " " + d["source_host"]')"

# ---------------------------------------------------------------------------------------------------------
section "the reserve read from stats.json"
rm -rf "$S"; mkdir -p "$S"
check_eq "no stats: the fixed reserve" "$((5 * GB)) fixed" "$(lib snap_disk_reserve_bytes 5 "$S" "$T")"
check_eq "no snapshots folder at all: the fixed reserve" "$((5 * GB)) fixed" "$(lib snap_disk_reserve_bytes 5 "$T/nowhere" "$T")"
stats "$S" small 1000000
check_eq "a smaller snapshot keeps the fixed reserve" "$((5 * GB)) fixed" "$(lib snap_disk_reserve_bytes 5 "$S" "$T")"
stats "$S" big $((8 * GB))
stats "$S" medium $((6 * GB))
check_eq "the largest recent snapshot is named" "$((8 * GB)) big" "$(lib snap_stats_reserve "$S" "$T")"
check_eq "a larger snapshot raises the reserve to its need +25%" "$((10 * GB)) stats:big" "$(lib snap_disk_reserve_bytes 5 "$S" "$T")"
stats "$S" gone $((50 * GB)) 40
check_eq "a deployment that stopped sending snapshots (older than 30 days) does not count" "$((10 * GB)) stats:big" "$(lib snap_disk_reserve_bytes 5 "$S" "$T")"
check_eq "the age limit can be changed" "$((50 * GB + 50 * GB / 4)) stats:gone" "$(SNAP_STATS_MAX_AGE_DAYS=60 lib snap_disk_reserve_bytes 5 "$S" "$T")"
check_eq "VALIDATOR_DISK_RESERVE_GB=0 turns the reserve off, stats included" "0 off" "$(lib snap_disk_reserve_bytes 0 "$S" "$T")"
check_eq "a bad reserve setting falls back to 5 GB" "$((10 * GB)) stats:big" "$(lib snap_disk_reserve_bytes 5GB "$S" "$T")"
printf 'not json' > "$S/small/stats.json"
check_eq "an unreadable stats.json is ignored" "$((8 * GB)) big" "$(lib snap_stats_reserve "$S" "$T")"
if [ -d /dev/shm ] && [ -w /dev/shm ] && [ "$(stat -c %d /dev/shm)" != "$(stat -c %d "$T")" ]; then
  SHM=$(mktemp -d /dev/shm/test_snapshot_stats.XXXXXX)
  check_eq "snapshots on another disk do not raise the reserve there" "$((5 * GB)) fixed" "$(lib snap_disk_reserve_bytes 5 "$S" "$SHM")"
  check_eq "but do when one of the paths is on their disk" "$((10 * GB)) stats:big" "$(lib snap_disk_reserve_bytes 5 "$S" "$SHM" "$T")"
else
  skip "snapshots on another disk" "no second filesystem (/dev/shm) to try it on"
fi

# ---------------------------------------------------------------------------------------------------------
section "the validator inbox hand-off keeps the room the next snapshot needs"
new_archive() {
  head -c 4096 /dev/urandom > "$1"
  printf '%s  %s\n' "$(sha256sum "$1" | cut -d' ' -f1)" "$(basename "$1")" > "$1.sha256"
}
FREE=$(df -PB1 "$T" | awk 'NR == 2 {print $4}')
rm -rf "$S"; mkdir -p "$S" "$T/stage"
stats "$S" svc "$FREE"   # needs more than is free (+25%)
new_archive "$T/stage/snapshot-svc.tar.zst"
lib snap_inbox_handoff "$T/stage/snapshot-svc.tar.zst" move "$T/home/.odoo-validator/inbox" svc 0 prd-vps "" "" "" "$S" > "$T/out"
check_eq "VALIDATOR_DISK_RESERVE_GB=0: handed off whatever the stats say" 0 "$?"
new_archive "$T/stage/snapshot-svc.tar.zst"
lib snap_inbox_handoff "$T/stage/snapshot-svc.tar.zst" move "$T/home/.odoo-validator/inbox" svc 1 prd-vps "" "" "" "$S" > "$T/out"
check_eq "not handed off when the next snapshot would not fit (code 2)" 2 "$?"
check_eq "and the log says which snapshot needs the room" yes "$(cat "$T/out" "$T/err" | grep -q 'what the next snapshot of svc needs there, from its stats.json' && echo yes || echo "no: $(cat "$T/out" "$T/err")")"
check_eq "the archive stays where it was" yes "$([ -f "$T/stage/snapshot-svc.tar.zst" ] && echo yes || echo no)"
lib snap_inbox_handoff "$T/stage/snapshot-svc.tar.zst" move "$T/home/.odoo-validator/inbox" svc 1 prd-vps "" "" "" "" > "$T/out"
check_eq "without a snapshots folder, the fixed reserve as before" 0 "$?"

# ---------------------------------------------------------------------------------------------------------
section "snapshot tool: remote_write_stats (sent to the Secondary VPS)"
SNAP="$REPO/scripts/example/snapshot.sh.example"
FN=$(python3 - "$SNAP" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
for i, l in enumerate(lines):
    if re.match(r"^function remote_write_stats\(\) \{", l):
        j = next(k for k in range(i, len(lines)) if lines[k].rstrip() == "}")
        print("\n".join(lines[i:j + 1])); break
else:
    sys.exit(1)
PY
) || { fail "remote_write_stats not found in the snapshot tool"; FN=""; }
if [ -n "$FN" ]; then
  RB="$T/rhome/.odoo-snapshots/svc"; mkdir -p "$RB"
  ( log_info() { echo "INFO $1"; }; log_warn() { echo "WARN $1"; }
    source "$REPO/scripts/lib/snapshot_storage.sh"
    remote_exec() { bash -c "$1"; }   # "ssh <secondary> bash -s" reading the script from stdin
    eval "$FN"
    remote_base="$RB" SERVICE_NAME=svc
    remote_write_stats 50000 20000 12000 8000 30000
  ) > "$T/out" 2>&1
  check_eq "the remote script runs" yes "$(grep -q 'Recorded snapshot sizes' "$T/out" && echo yes || echo "no: $(cat "$T/out")")"
  check_eq "stats.json on the Secondary VPS" "12000 8000 30000 30000" "$(j "$RB/stats.json" '" ".join(str(x) for x in [d["dump_bytes"], d["archive_bytes"], d["peak_bytes"], d["need_bytes"]])')"
  check_eq "names this host as the source" "$(hostname -f 2>/dev/null || hostname)" "$(j "$RB/stats.json" 'd["source_host"]')"
  ( log_info() { echo "INFO $1"; }; log_warn() { echo "WARN $1"; }
    source "$REPO/scripts/lib/snapshot_storage.sh"
    remote_exec() { return 255; }   # the SSH connection is gone
    eval "$FN"
    remote_base="$RB" SERVICE_NAME=svc
    remote_write_stats 1 1 1 1 ""
  ) > "$T/out" 2>&1
  check_eq "a failed write is a warning, not an error" 0 "$?"
  check_eq "and says what it means" yes "$(grep -q 'drills there keep only VALIDATOR_DISK_RESERVE_GB free' "$T/out" && echo yes || echo no)"
fi
check_eq "free space is measured before anything is staged" 1 "$(grep -c '^  remote_free_before=\$(remote_exec "df -PB1' "$SNAP")"
check_eq "and again at the fullest point, after the archive is verified" 1 "$(grep -c '^  read -r remote_free_peak remote_dump_bytes remote_archive_bytes' "$SNAP")"
check_eq "measured before the staged files are removed" yes "$(python3 - "$SNAP" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index("read -r remote_free_peak"); b = s.index("Clean up uncompressed staged data files on Secondary VPS"); c = s.index('log_success "Snapshot archive verified successfully on Secondary VPS."')
print("yes" if c < a < b else "no")
PY
)"
check_eq "the inbox hand-off gets the snapshots folder for the reserve" 1 "$(grep -c "'\$kept' '\$remote_home/.odoo-snapshots'\$" "$SNAP")"
check_eq "and the reserve functions are sent with it" 1 "$(grep -c 'snap_inbox_handoff snap_stats_reserve snap_disk_reserve_bytes)' "$SNAP")"
check_eq "the validator uses the same reserve" 1 "$(grep -c 'RESERVE_INFO=$(snap_disk_reserve_bytes "$VALIDATOR_DISK_RESERVE_GB" "$HOME/.odoo-snapshots"' "$REPO/scripts/validate-snapshot.sh")"

echo
echo -e "Results: ${C_PASS}$passed passed${C_RESET}, ${C_FAIL}$failed failed${C_RESET}, ${C_SKIP}$skipped skipped${C_RESET}"
[ "$failed" -eq 0 ]
