#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: Retention for the snapshots kept on this host (~/.odoo-snapshots/<service>/archives):
#              snap_local_plan / snap_local_apply / snap_local_retention (scripts/lib/snapshot_storage.sh),
#              the snapshot tool's use of them (SNAPSHOT_LOCAL_MAX_BACKUPS) and cleanup-snapshot.sh --local.
# Usage: ./tests/test_local_retention.sh
# Dependencies: bash, python3, sha256sum, find, numfmt
#
# Safe on a real machine: everything happens in one mktemp folder. cleanup-snapshot.sh runs from a copy of
# scripts/ with its own .env and SNAPSHOT_OWNER_HOME pointing into that folder, so the real home folder
# and its ~/.odoo-snapshots are never read or changed.

readonly C_RESET="\033[0m" C_PASS="\033[0;32m" C_FAIL="\033[0;31m" C_SKIP="\033[1;33m" C_INFO="\033[0;34m"
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
passed=0 failed=0 skipped=0
pass() { echo -e "${C_PASS}  [PASS] $1${C_RESET}"; passed=$((passed + 1)); }
fail() { echo -e "${C_FAIL}  [FAIL] $1${C_RESET}"; failed=$((failed + 1)); }
skip() { echo -e "${C_SKIP}  [SKIP] $1: $2${C_RESET}"; skipped=$((skipped + 1)); }
section() { echo -e "${C_INFO}== $1 ==${C_RESET}"; }
check_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi; }
for c in python3 sha256sum find; do command -v "$c" >/dev/null 2>&1 || { echo "Missing dependency: $c" >&2; exit 3; }; done

T=$(mktemp -d "${TMPDIR:-/tmp}/test_local_retention.XXXXXX") || exit 3
HOLDER=""
trap '[ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null; rm -rf "$T"' EXIT

lib() { ( source "$REPO/scripts/lib/snapshot_storage.sh"; "$@" ) 2>"$T/err"; }
A="$T/home/.odoo-snapshots/svc/archives"
snap() {  # snap DIR SERVICE TIMESTAMP: a kept snapshot folder as the snapshot tool makes it
  local d="$1/snapshot-$2.tar.zst-$3"
  mkdir -p "$d"
  head -c 2048 /dev/urandom > "$d/snapshot-$2.tar.zst"
  printf '%s  %s\n' "$(sha256sum "$d/snapshot-$2.tar.zst" | cut -d' ' -f1)" "snapshot-$2.tar.zst" > "$d/snapshot-$2.tar.zst.sha256"
}
record() {  # record FOLDER RESULT [SHA]: a validation record next to the archive
  local f="$1/snapshot-svc.tar.zst" sha="${3:-$(cut -d' ' -f1 "$1/snapshot-svc.tar.zst.sha256")}"
  lib snap_write_validation_record "$f.validated.json" snapshot-svc.tar.zst "$sha"
  [ "$2" = pass ] || sed -i 's/"result": "pass"/"result": "'"$2"'"/' "$f.validated.json"
}
plan_of() { awk -F'\t' -v n="$2" '$2 ~ n {print $1 ":" $4}' <<< "$1"; }
left() { ls "$A" 2>/dev/null | sed 's/^snapshot-svc.tar.zst-//' | tr '\n' ' ' | sed 's/ $//'; }

# ---------------------------------------------------------------------------------------------------------
section "the plan: newest N, plus the newest that passed a drill"
for d in 01 02 03 04 05 06 07 08; do snap "$A" svc "202611${d}-010000"; done
record "$A/snapshot-svc.tar.zst-20261103-010000" pass
record "$A/snapshot-svc.tar.zst-20261102-010000" pass
record "$A/snapshot-svc.tar.zst-20261105-010000" fail
record "$A/snapshot-svc.tar.zst-20261104-010000" pass 0000000000000000000000000000000000000000000000000000000000000000
P=$(lib snap_local_plan "$A" svc 3)
check_eq "one line per snapshot, newest first" "20261108 20261107 20261106 20261105 20261104 20261103 20261102 20261101" "$(cut -f2 <<< "$P" | sed 's/.*-\([0-9]\{8\}\)-.*/\1/' | tr '\n' ' ' | sed 's/ $//')"
check_eq "the newest 3 are kept" "keep:newest keep:newest keep:newest" "$(cut -f1,4 <<< "$P" | head -n 3 | tr '\t' : | tr '\n' ' ' | sed 's/ $//')"
check_eq "a failed drill record does not protect" "delete:old" "$(plan_of "$P" 20261105)"
check_eq "a record for other bytes (sha256 differs) does not protect" "delete:old" "$(plan_of "$P" 20261104)"
check_eq "the newest snapshot that passed a drill is kept beyond the limit" "keep:drill" "$(plan_of "$P" 20261103)"
check_eq "only the newest one: an older passed drill goes" "delete:old" "$(plan_of "$P" 20261102)"
check_eq "sizes are reported" 2048 "$(awk -F'\t' 'NR==1 {print $3}' <<< "$P")"

section "what retention never touches"
echo "notes" > "$A/snapshot-svc.tar.zst-20261101-010000/README.txt"
mkdir -p "$A/snapshot-svc.tar.zst-20261020-010000"; ln -s /etc/hostname "$A/snapshot-svc.tar.zst-20261020-010000/snapshot-svc.tar.zst"
snap "$A" svc-staging 20261001-010000
mkdir -p "$A/backup-by-hand" "$A/snapshot-svc.tar.zst-20261001-010000-copy"
touch "$A/backup-by-hand/x" "$A/snapshot-svc.tar.zst-20261001-010000-copy/snapshot-svc.tar.zst"
snap "$A" svc 20261015-010000
( exec 9<"$A/snapshot-svc.tar.zst-20261015-010000/snapshot-svc.tar.zst"; exec sleep 300 ) &
HOLDER=$!
for _ in $(seq 1 50); do lib snap_file_in_use "$A/snapshot-svc.tar.zst-20261015-010000/snapshot-svc.tar.zst" && break; sleep 0.1; done
P=$(lib snap_local_plan "$A" svc 3)
check_eq "a folder holding other files is left alone" "skip:other-files" "$(plan_of "$P" 20261101)"
check_eq "an archive a process has open (a drill, an upload) is left alone" "skip:in-use" "$(plan_of "$P" 20261015)"
check_eq "a symlinked archive is not a snapshot folder" "" "$(plan_of "$P" 20261020)"
check_eq "another deployment's snapshot (svc-staging) is not counted" "" "$(plan_of "$P" 20261001)"
check_eq "folders not named as the snapshot tool names them are not counted" 0 "$(grep -c 'backup-by-hand\|-copy' <<< "$P")"
check_eq "keep must be at least 1" 1 "$(lib snap_local_plan "$A" svc 0 >/dev/null; echo $?)"

section "applying it"
ln -s "$A/snapshot-svc.tar.zst-20261108-010000/snapshot-svc.tar.zst" "$T/home/snapshot-svc.tar.zst"
lib snap_local_retention "$A" svc 3 "$T/home/snapshot-svc.tar.zst"
check_eq "done without errors" 0 "$?"
check_eq "kept: newest 3, the drill one, and what is left alone" "20261001-010000-copy 20261015-010000 20261020-010000 20261101-010000 20261103-010000 20261106-010000 20261107-010000 20261108-010000 backup-by-hand" "$(ls "$A" | grep -v '^snapshot-svc-staging' | sed 's/^snapshot-svc.tar.zst-//' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
check_eq "the other deployment's folder is still there" yes "$([ -f "$A/snapshot-svc-staging.tar.zst-20261001-010000/snapshot-svc-staging.tar.zst" ] && echo yes || echo no)"
check_eq "deleted folders are gone with their .sha256 and .validated.json" "" "$(ls -d "$A"/snapshot-svc.tar.zst-2026110[245]-* 2>/dev/null)"
check_eq "the drill-protected snapshot keeps its record" yes "$([ -f "$A/snapshot-svc.tar.zst-20261103-010000/snapshot-svc.tar.zst.validated.json" ] && echo yes || echo no)"
check_eq "the log names the protected snapshot" yes "$(grep -q 'also keeping snapshot-svc.tar.zst-20261103-010000' "$T/err" && echo yes || echo no)"
check_eq "and what it left alone" yes "$(grep 'left alone although over the limit of 3: ' "$T/err" | grep -F '20261015-010000 (in-use)' | grep -qF '20261101-010000 (other-files)' && echo yes || echo "no: $(cat "$T/err")")"
check_eq "the home link to the newest snapshot stays" yes "$([ -e "$T/home/snapshot-svc.tar.zst" ] && echo yes || echo no)"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""
lib snap_local_retention "$A" svc 3 "$T/home/snapshot-svc.tar.zst"
check_eq "once the archive is closed, the next run removes it" "" "$(ls -d "$A"/snapshot-svc.tar.zst-20261015-* 2>/dev/null)"
rm -rf "$A/snapshot-svc.tar.zst-20261101-010000/README.txt" "$A/snapshot-svc.tar.zst-20261106-010000" "$A/snapshot-svc.tar.zst-20261107-010000"
rm -f "$T/home/snapshot-svc.tar.zst"; ln -s "$A/snapshot-svc.tar.zst-20261101-010000/snapshot-svc.tar.zst" "$T/home/snapshot-svc.tar.zst"
lib snap_local_retention "$A" svc 1 "$T/home/snapshot-svc.tar.zst"
check_eq "a home link left pointing at a deleted snapshot is removed" no "$([ -L "$T/home/snapshot-svc.tar.zst" ] && echo yes || echo no)"
before=$(left)
lib snap_local_retention "$A" svc "" ""
check_eq "SNAPSHOT_LOCAL_MAX_BACKUPS empty: keeps everything" "$before" "$(left)"
lib snap_local_retention "$A" svc 0 ""
check_eq "0 is refused (it would delete every copy): keeps everything" "$before" "$(left)"
check_eq "and says so" yes "$(grep -q 'is not a number of at least 1; keeping every local snapshot' "$T/err" && echo yes || echo no)"

# ---------------------------------------------------------------------------------------------------------
section "snapshot tool: each kept snapshot, then retention"
SNAP="$REPO/scripts/example/snapshot.sh.example"
FN=$(python3 - "$SNAP" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
for i, l in enumerate(lines):
    if re.match(r"^function moveSnapshotFileToTempDir\(\) \{", l):
        j = next(k for k in range(i, len(lines)) if lines[k].rstrip() == "}")
        print("\n".join(lines[i:j + 1])); break
else:
    sys.exit(1)
PY
) || { fail "moveSnapshotFileToTempDir not found in the snapshot tool"; FN=""; }
if [ -n "$FN" ]; then
  H="$T/owner"; mkdir -p "$H" "$T/tmp"
  ( log_info() { :; }; log_success() { :; }; log_warn() { :; }; log_error() { echo "ERROR $1"; }
    source "$REPO/scripts/lib/snapshot_storage.sh"
    eval "$FN"
    OWNER_HOME="$H" SERVICE_NAME=svc REPOSITORY_OWNER="$(id -un)"
    for n in 1 2 3 4; do
      head -c 1024 /dev/urandom > "$T/tmp/snapshot-svc.tar.zst"
      printf '%s  snapshot-svc.tar.zst\n' "$(sha256sum "$T/tmp/snapshot-svc.tar.zst" | cut -d' ' -f1)" > "$T/tmp/snapshot-svc.tar.zst.sha256"
      moveSnapshotFileToTempDir "$T/tmp/snapshot-svc.tar.zst" snapshot-svc.tar.zst
      snap_local_retention "$H/.odoo-snapshots/svc/archives" svc 2 "$H/snapshot-svc.tar.zst"
      [ "$n" = 4 ] || sleep 1.05   # the folder name has the time to the second
    done
  ) > "$T/out" 2>&1
  check_eq "four snapshots kept on this host, retention 2: two folders stay" 2 "$(ls "$H/.odoo-snapshots/svc/archives" | wc -l)"
  check_eq "each with its checksum file" "2" "$(ls "$H"/.odoo-snapshots/svc/archives/*/snapshot-svc.tar.zst.sha256 | wc -l)"
  check_eq "the home link points at the newest" "$(ls -d "$H"/.odoo-snapshots/svc/archives/* | sort | tail -n 1)/snapshot-svc.tar.zst" "$(readlink "$H/snapshot-svc.tar.zst")"
  check_eq "no errors" "" "$(grep ERROR "$T/out")"
fi
check_eq "the snapshot tool reads SNAPSHOT_LOCAL_MAX_BACKUPS from .env" 1 "$(grep -c '^  SNAPSHOT_LOCAL_MAX_BACKUPS=$(grep "^SNAPSHOT_LOCAL_MAX_BACKUPS="' "$SNAP")"
check_eq "and applies it after a snapshot is kept in local mode" yes "$(python3 - "$SNAP" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.rindex('moveSnapshotFileToTempDir "$TAR_FILE_PATH" "$TAR_FILE_NAME"')
b = s.index('snap_local_retention "$OWNER_HOME/.odoo-snapshots/$SERVICE_NAME/archives" "$SERVICE_NAME" "$SNAPSHOT_LOCAL_MAX_BACKUPS" "$OWNER_HOME/$TAR_FILE_NAME" || true')
print("yes" if a < b else "no")
PY
)"
check_eq ".env.example: 5 by default" "SNAPSHOT_LOCAL_MAX_BACKUPS=5" "$(grep '^SNAPSHOT_LOCAL_MAX_BACKUPS=' "$REPO/.env.example")"

# ---------------------------------------------------------------------------------------------------------
section "cleanup-snapshot.sh --local"
R="$T/repo"; mkdir -p "$R"; cp -a "$REPO/scripts" "$R/"
CH="$T/chome"; CA="$CH/.odoo-snapshots/repo/archives"
for d in 01 02 03 04 05; do snap "$CA" repo "202611${d}-010000"; done
snap "$CH/.odoo-snapshots/other/archives" other 20261101-010000
snap "$CH/.odoo-snapshots/other/archives" other 20261102-010000
cleanup() { SNAPSHOT_OWNER_HOME="$CH" bash "$R/scripts/cleanup-snapshot.sh" "$@" </dev/null > "$T/out" 2>&1; }
printf 'SNAPSHOT_LOCAL_MAX_BACKUPS=\n' > "$R/.env"
cleanup --local
check_eq "SNAPSHOT_LOCAL_MAX_BACKUPS empty: refuses to clean up without --keep" 1 "$?"
cleanup --local --list
check_eq "--list works without a limit" 0 "$?"
check_eq "and lists this deployment's 5 snapshots" 5 "$(grep -c '| repo/snapshot-repo.tar.zst-' "$T/out")"
printf 'SNAPSHOT_LOCAL_MAX_BACKUPS=2\n' > "$R/.env"
cleanup --local --dry-run
check_eq "--dry-run" 0 "$?"
check_eq "plans 3 deletions" 3 "$(grep -c '\[DELETE\]' "$T/out")"
check_eq "and deletes nothing" 5 "$(ls "$CA" | wc -l)"
cleanup --local
check_eq "without --force it asks, and no answer means no" 5 "$(ls "$CA" | wc -l)"
cleanup --local --force
check_eq "--force applies .env's limit" "20261104-010000 20261105-010000" "$(ls "$CA" | sed 's/^snapshot-repo.tar.zst-//' | tr '\n' ' ' | sed 's/ $//')"
check_eq "another deployment is not touched without --all" 2 "$(ls "$CH/.odoo-snapshots/other/archives" | wc -l)"
cleanup --local --all --keep 1 --force
check_eq "--all --keep 1: every deployment down to its newest" "1 1" "$(ls "$CA" | wc -l) $(ls "$CH/.odoo-snapshots/other/archives" | wc -l)"
cleanup --local --keep 0 --force
check_eq "--keep 0 is refused" 1 "$?"

echo
echo -e "Results: ${C_PASS}$passed passed${C_RESET}, ${C_FAIL}$failed failed${C_RESET}, ${C_SKIP}$skipped skipped${C_RESET}"
[ "$failed" -eq 0 ]
