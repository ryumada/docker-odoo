#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: scripts/read-drill-reports.sh, the read-only helper Deployment Control runs (with sudo) to collect a
#              deployment's drill reports: one JSON document (schema 1), only the drill keys of the .env, only
#              this deployment's reports, what is in effect for the settings left empty ("effective", from
#              scripts/lib/drill_defaults.sh), no arguments accepted, and (when run as root) read as the
#              deployment owner, never as root.
# Usage: ./tests/test_read_drill_reports.sh
# Dependencies: bash, python3
#
# Safe on a real machine: a copy of the script runs inside one mktemp folder; the real .env, ~/.odoo-validator
# and /etc are never read for this test's answers. As root, the copy's folder is given to 'nobody' (only inside
# the mktemp folder) to check the owner switch.

readonly C_RESET="\033[0m" C_PASS="\033[0;32m" C_FAIL="\033[0;31m" C_SKIP="\033[1;33m" C_INFO="\033[0;34m"
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
passed=0 failed=0 skipped=0
pass() { echo -e "${C_PASS}  [PASS] $1${C_RESET}"; passed=$((passed + 1)); }
fail() { echo -e "${C_FAIL}  [FAIL] $1${C_RESET}"; failed=$((failed + 1)); }
skip() { echo -e "${C_SKIP}  [SKIP] $1: $2${C_RESET}"; skipped=$((skipped + 1)); }
section() { echo -e "${C_INFO}== $1 ==${C_RESET}"; }
check_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi; }
command -v python3 >/dev/null 2>&1 || { echo "Missing dependency: python3" >&2; exit 3; }

T=$(mktemp -d "${TMPDIR:-/tmp}/test_read_drill_reports.XXXXXX") || exit 3
trap 'rm -rf "$T"' EXIT
DEP="$T/opt/my-dep"
HOME_DIR="$T/home"
REPORTS="$HOME_DIR/.odoo-validator/reports"
mkdir -p "$DEP/scripts" "$REPORTS"
cp "$REPO/scripts/read-drill-reports.sh" "$DEP/scripts/"
chmod 755 "$DEP/scripts/read-drill-reports.sh"
touch "$DEP/scripts/validate-snapshot-worker.sh"
cat > "$DEP/.env" <<'ENV'
DB_NAME=prod
ADMIN_PASSWD=top-secret-admin
DB_PASSWORD=top-secret-db
VALIDATOR_WORKER=true # on
VALIDATOR_MIN_INTERVAL_HOURS='12'
SNAPSHOT_REMOTE_HOST="10.0.0.2"
ENV
report() {
  # report FILE SERVICE RESULT STARTED [STAGES_JSON]
  printf '{"schema":1,"service":"%s","result":"%s","level":"boot","archive":"snapshot-%s.tar.zst","sha256":"%s","started_at":"%s","source":{"kind":"inbox"},"stages":%s}\n' \
    "$2" "$3" "$2" "$(printf 'a%.0s' $(seq 64))" "$4" "${5:-[]}" > "$REPORTS/$1"
}
report my-dep-1.json my-dep pass 2026-11-09T01:00:00Z
report my-dep-2.json my-dep fail 2026-11-08T01:00:00Z '[{"name":"database","status":"fail","details":{"message":"2 SQL errors"}},{"name":"boot","status":"warn","details":{"message":"ERROR line"}}]'
report other-1.json other pass 2026-11-09T02:00:00Z
ln -s "$REPORTS/my-dep-1.json" "$REPORTS/latest-my-dep.json"
echo '{nope' > "$REPORTS/garbage.json"
get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$T/out" "$1" 2>&1; }

# ---------------------------------------------------------------------------------------------------
section "as the deployment owner"
HOME="$HOME_DIR" "$DEP/scripts/read-drill-reports.sh" > "$T/out" 2> "$T/err"
check_eq "exit 0" 0 "$?"
check_eq "schema 1, service from the folder name" "1 my-dep" "$(get "d['schema'], d['service']" | tr -d "(),'")"
check_eq "only this deployment's reports, oldest first, no symlink or garbage" "['my-dep-2.json', 'my-dep-1.json']" "$(get "[r['name'] for r in d['runs']]")"
check_eq "failed stage and warning summarised" "database 2 SQL errors 1" "$(get "d['runs'][0]['failed_stage'], d['runs'][0]['failed_message'], d['runs'][0]['warning_count']" | tr -d "(),'")"
check_eq "drill settings read like env_get" "{'VALIDATOR_WORKER': 'true', 'VALIDATOR_MIN_INTERVAL_HOURS': '12', 'SNAPSHOT_REMOTE_HOST': '10.0.0.2'}" "$(get "d['settings']")"
if grep -q 'top-secret\|DB_NAME\|prod' "$T/out"; then fail "no other .env value in the output"; else pass "no other .env value in the output"; fi
check_eq "worker script seen" "True" "$(get "d['worker_script']")"
check_eq "nothing on stderr" "" "$(cat "$T/err")"
check_eq "older docker-odoo (no drill_defaults.sh): effective is null" "None" "$(get "d['effective']")"

section "what is in effect for the settings left empty (scripts/lib/drill_defaults.sh)"
mkdir -p "$DEP/scripts/lib"; cp "$REPO/scripts/lib/drill_defaults.sh" "$DEP/scripts/lib/"
cp "$DEP/.env" "$T/env.saved"
printf 'ENABLE_SNAPSHOT=Y\nVALIDATOR_WORKER=\nSNAPSHOT_VALIDATOR_INBOX=\nSNAPSHOT_REMOTE_HOST=203.0.113.5\nDB_PASSWORD=top-secret-db\n' > "$DEP/.env"
HOME="$HOME_DIR" "$DEP/scripts/read-drill-reports.sh" > "$T/out" 2>/dev/null
check_eq "empty worker + snapshots on: on, automatic" "True True" "$(get "d['effective']['VALIDATOR_WORKER']['value'], d['effective']['VALIDATOR_WORKER']['auto']" | tr -d "(),")"
check_eq "empty inbox + Secondary VPS: on, automatic" "True True" "$(get "d['effective']['SNAPSHOT_VALIDATOR_INBOX']['value'], d['effective']['SNAPSHOT_VALIDATOR_INBOX']['auto']" | tr -d "(),")"
check_eq "with the reason" "True" "$(get "'Secondary VPS 203.0.113.5' in d['effective']['VALIDATOR_WORKER']['reason']")"
check_eq "and what empty would do (same here)" "True" "$(get "d['effective']['VALIDATOR_WORKER']['auto_value']")"
check_eq "ENABLE_SNAPSHOT is read (not a secret), the rest is not" "Y" "$(get "d['settings']['ENABLE_SNAPSHOT']")"
if grep -q 'top-secret' "$T/out"; then fail "still no other .env value in the output"; else pass "still no other .env value in the output"; fi
printf 'ENABLE_SNAPSHOT=Y\nVALIDATOR_WORKER=false\nSNAPSHOT_VALIDATOR_INBOX=\nSNAPSHOT_REMOTE_HOST=localhost\n' > "$DEP/.env"
HOME="$HOME_DIR" "$DEP/scripts/read-drill-reports.sh" > "$T/out" 2>/dev/null
check_eq "explicit false: off, not automatic" "False False" "$(get "d['effective']['VALIDATOR_WORKER']['value'], d['effective']['VALIDATOR_WORKER']['auto']" | tr -d "(),")"
check_eq "  while empty would be on (snapshots on)" "True" "$(get "d['effective']['VALIDATOR_WORKER']['auto_value']")"
check_eq "SNAPSHOT_REMOTE_HOST=localhost: inbox off" "False True" "$(get "d['effective']['SNAPSHOT_VALIDATOR_INBOX']['value'], d['effective']['SNAPSHOT_VALIDATOR_INBOX']['auto']" | tr -d "(),")"
cp "$T/env.saved" "$DEP/.env"

section "VALIDATOR_WORK_DIR moves the reports"
mkdir -p "$T/vwork/reports"
cp "$REPORTS/my-dep-1.json" "$T/vwork/reports/x.json"
echo "VALIDATOR_WORK_DIR=$T/vwork" >> "$DEP/.env"
HOME="$HOME_DIR" "$DEP/scripts/read-drill-reports.sh" > "$T/out" 2>/dev/null
check_eq "reports read from VALIDATOR_WORK_DIR/reports" "['x.json']" "$(get "[r['name'] for r in d['runs']]")"
sed -i '/^VALIDATOR_WORK_DIR=/d' "$DEP/.env"

section "called through a symlink (as sudo would see /opt/<svc>/scripts/...)"
mkdir -p "$T/bin"
ln -s "$DEP/scripts/read-drill-reports.sh" "$T/bin/read-drill-reports"
HOME="$HOME_DIR" "$T/bin/read-drill-reports" > "$T/out" 2>/dev/null
check_eq "still finds its deployment" "my-dep" "$(get "d['service']")"

section "arguments are refused (sudo allows it without arguments only)"
for args in "/etc" "--path /root" ""; do
  [ -z "$args" ] && args="''"
  out=$(HOME="$HOME_DIR" eval "\"$DEP/scripts/read-drill-reports.sh\" $args" 2>&1)
  rc=$?
  if [ "$rc" -eq 1 ] && [[ "$out" == *"takes no arguments"* ]] && [[ "$out" != *schema* ]]; then pass "refused: $args"; else fail "refused: $args (rc $rc: $out)"; fi
done

section "no .env, no reports yet"
mv "$DEP/.env" "$DEP/.env.moved"
HOME="$T/empty-home" "$DEP/scripts/read-drill-reports.sh" > "$T/out" 2>/dev/null
check_eq "env not readable, no runs, exit 0" "False 0 False" "$(get "d['env_readable'], len(d['runs']), d['reports_dir_exists']" | tr -d "(),'")"
mv "$DEP/.env.moved" "$DEP/.env"

section "run as root for another owner: reads as that owner"
if [ "$(id -u)" -ne 0 ]; then
  skip "owner switch" "needs root (run the test with sudo)"
elif ! command -v sudo >/dev/null 2>&1 || ! id nobody >/dev/null 2>&1; then
  skip "owner switch" "needs sudo and the 'nobody' user"
else
  chmod 755 "$T" "$T/opt" "$T/home" "$HOME_DIR/.odoo-validator"
  mkdir -p "$T/vwork2/reports"; cp "$REPORTS/my-dep-1.json" "$T/vwork2/reports/as-owner.json"
  echo "VALIDATOR_WORK_DIR=$T/vwork2" >> "$DEP/.env"
  chown -R nobody "$DEP" "$T/vwork2"
  chmod 600 "$DEP/.env"
  chmod 700 "$T/vwork2"
  "$DEP/scripts/read-drill-reports.sh" > "$T/out" 2> "$T/err"
  check_eq "exit 0" 0 "$?"
  check_eq "nobody could read its own .env and reports" "True ['as-owner.json']" "$(get "d['env_readable'], [r['name'] for r in d['runs']]" | tr -d "(),")"
  # a report only root can read is not read (the collector runs as the owner, not as root)
  install -m 600 -o root "$REPORTS/my-dep-1.json" "$T/vwork2/reports/root-only.json"
  "$DEP/scripts/read-drill-reports.sh" > "$T/out" 2>/dev/null
  check_eq "a root-only file is not read" "['as-owner.json']" "$(get "[r['name'] for r in d['runs']]")"
  chown -R "$(id -u)" "$DEP" "$T/vwork2"
fi

echo
echo "Passed: $passed  Failed: $failed  Skipped: $skipped"
[ "$failed" -eq 0 ]
