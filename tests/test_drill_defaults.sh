#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: scripts/lib/drill_defaults.sh, the automatic defaults of VALIDATOR_WORKER and
#              SNAPSHOT_VALIDATOR_INBOX (an empty value in .env): the worker is on when snapshots are on, the
#              inbox when SNAPSHOT_REMOTE_HOST is a real Secondary VPS (not this machine); an explicit true or
#              false always wins; anything else is refused. Also setup's decision (install-snapshot.sh) and the
#              template (.env.example leaves both empty).
# Usage: ./tests/test_drill_defaults.sh
# Dependencies: bash, hostname
#
# Safe on a real machine: only functions run, inside one mktemp folder. ssh aliases are read from a config file
# in that folder (DRILL_SSH_CONFIG), never from ~/.ssh; nothing is installed and no host is contacted.

readonly C_RESET="\033[0m" C_PASS="\033[0;32m" C_FAIL="\033[0;31m" C_SKIP="\033[1;33m" C_INFO="\033[0;34m"
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
passed=0 failed=0 skipped=0
pass() { echo -e "${C_PASS}  [PASS] $1${C_RESET}"; passed=$((passed + 1)); }
fail() { echo -e "${C_FAIL}  [FAIL] $1${C_RESET}"; failed=$((failed + 1)); }
skip() { echo -e "${C_SKIP}  [SKIP] $1: $2${C_RESET}"; skipped=$((skipped + 1)); }
section() { echo -e "${C_INFO}== $1 ==${C_RESET}"; }
check_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi; }
check_has() { if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1: '$2' not in '$3'"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/test_drill_defaults.XXXXXX") || exit 3
trap 'rm -rf "$T"' EXIT
# shellcheck source=/dev/null
source "$REPO/scripts/lib/drill_defaults.sh"
REMOTE=203.0.113.5            # TEST-NET-3: never one of this machine's addresses
local_or_remote() { if drill_host_is_local "$1"; then echo local; else echo remote; fi; }

# ---------------------------------------------------------------------------------------------------
section "is SNAPSHOT_REMOTE_HOST this machine?"
for h in "" localhost LOCALHOST localhost.localdomain 127.0.0.1 127.0.1.1 ::1 "[::1]" 0.0.0.0 user@127.0.0.1 ip6-localhost; do
  check_eq "local: '$h'" local "$(local_or_remote "$h")"
done
check_eq "local: this host's name ($(hostname))" local "$(local_or_remote "$(hostname)")"
check_eq "local: this host's name in capitals" local "$(local_or_remote "$(hostname | tr '[:lower:]' '[:upper:]')")"
own_ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | grep -v '^127\.' | head -n 1)
if [ -n "$own_ip" ]; then
  check_eq "local: this host's address ($own_ip)" local "$(local_or_remote "$own_ip")"
else
  skip "local: this host's address" "hostname -I lists none"
fi
check_eq "remote: a TEST-NET address" remote "$(local_or_remote "$REMOTE")"
check_eq "remote: user@TEST-NET address" remote "$(local_or_remote "backup@$REMOTE")"
check_eq "remote: a name that does not resolve" remote "$(local_or_remote "backup-vps.example.invalid")"
check_eq "local: an extra name of this machine (DRILL_LOCAL_EXTRA)" local "$(DRILL_LOCAL_EXTRA="vps1.internal" local_or_remote vps1.internal)"
if command -v ssh >/dev/null 2>&1; then
  printf 'Host loopback-alias\n  HostName 127.0.0.1\nHost backup-alias\n  HostName %s\n' "$REMOTE" > "$T/ssh_config"
  check_eq "local: an ssh_config alias of 127.0.0.1" local "$(DRILL_SSH_CONFIG="$T/ssh_config" local_or_remote loopback-alias)"
  check_eq "remote: an ssh_config alias of a remote address" remote "$(DRILL_SSH_CONFIG="$T/ssh_config" local_or_remote backup-alias)"
else
  skip "ssh_config aliases" "ssh is not installed"
fi

section "VALIDATOR_WORKER"
w() { drill_resolve_worker "$@"; RC=$?; echo "$RC $DRILL_VALUE $DRILL_AUTO"; }
check_eq "empty + snapshots on (Y), Secondary VPS: on, automatic" "0 true true" "$(w "" Y "$REMOTE")"
drill_resolve_worker "" Y "$REMOTE"
check_has "  says the drills run on the Secondary VPS" "drills run on the Secondary VPS $REMOTE" "$DRILL_REASON"
check_eq "empty + snapshots on, no Secondary VPS: on, automatic" "0 true true" "$(w "" Y "")"
drill_resolve_worker "" Y ""
check_has "  says the drills run on this host" "drills run on this host" "$DRILL_REASON"
check_eq "empty + snapshots on, SNAPSHOT_REMOTE_HOST=localhost: on" "0 true true" "$(w "" Y localhost)"
check_eq "empty + snapshots off (ENABLE_SNAPSHOT empty): off" "0 false true" "$(w "" "" "$REMOTE")"
for v in n N no false 0 off; do
  check_eq "empty + ENABLE_SNAPSHOT=$v: off" "0 false true" "$(w "" "$v" "")"
done
check_eq "true wins over snapshots off" "0 true false" "$(w true "" "")"
check_eq "false wins over snapshots on" "0 false false" "$(w false Y "$REMOTE")"
for v in yes TRUE 1 on " "; do
  check_eq "'$v' refused (exit 2, off)" "2 false false" "$(w "$v" Y "$REMOTE")"
done

section "SNAPSHOT_VALIDATOR_INBOX"
i() { drill_resolve_inbox "$@"; RC=$?; echo "$RC $DRILL_VALUE $DRILL_AUTO"; }
check_eq "empty + Secondary VPS: on, automatic" "0 true true" "$(i "" "$REMOTE")"
check_eq "empty + no Secondary VPS: off" "0 false true" "$(i "" "")"
for h in localhost 127.0.0.1 "$(hostname)"; do
  check_eq "empty + SNAPSHOT_REMOTE_HOST=$h (this machine): off" "0 false true" "$(i "" "$h")"
done
drill_resolve_inbox "" localhost
check_has "  says why" "is this machine" "$DRILL_REASON"
check_eq "true wins (even for this machine)" "0 true false" "$(i true localhost)"
check_eq "false wins over a Secondary VPS" "0 false false" "$(i false "$REMOTE")"
check_eq "'yes' refused (exit 2, off)" "2 false false" "$(i yes "$REMOTE")"

section "setup (install-snapshot.sh) decides with the same rules"
(
  log_info() { echo "INFO $1"; }; log_warn() { echo "WARN $1"; }
  eval "$(sed -n '/^function resolveDrillDefaults()/,/^}/p' "$REPO/scripts/installer/install-snapshot.sh")"
  SERVICE_NAME=app
  VALIDATOR_WORKER="" SNAPSHOT_VALIDATOR_INBOX="" ENABLE_SNAPSHOT=Y SNAPSHOT_REMOTE_HOST=""
  resolveDrillDefaults; echo "EFFECTIVE $VALIDATOR_WORKER_EFFECTIVE"
) > "$T/setup1" 2>&1
check_has "worker installed when empty and snapshots on" "EFFECTIVE true" "$(cat "$T/setup1")"
check_has "warns that the drills run on this host" "WARN Drills of app will run on this host" "$(cat "$T/setup1")"
check_has "says the inbox is off (no Secondary VPS)" "INFO Validator inbox: automatic (SNAPSHOT_VALIDATOR_INBOX empty): off" "$(cat "$T/setup1")"
(
  log_info() { echo "INFO $1"; }; log_warn() { echo "WARN $1"; }
  eval "$(sed -n '/^function resolveDrillDefaults()/,/^}/p' "$REPO/scripts/installer/install-snapshot.sh")"
  SERVICE_NAME=app VALIDATOR_WORKER="" SNAPSHOT_VALIDATOR_INBOX="" ENABLE_SNAPSHOT=Y SNAPSHOT_REMOTE_HOST="$REMOTE"
  resolveDrillDefaults; echo "EFFECTIVE $VALIDATOR_WORKER_EFFECTIVE"
) > "$T/setup2" 2>&1
check_has "with a Secondary VPS: worker on" "EFFECTIVE true" "$(cat "$T/setup2")"
if grep -q "will run on this host" "$T/setup2"; then fail "no 'this host' warning with a Secondary VPS"; else pass "no 'this host' warning with a Secondary VPS"; fi
check_has "and the inbox on" "INFO Validator inbox: automatic (SNAPSHOT_VALIDATOR_INBOX empty): on" "$(cat "$T/setup2")"
(
  log_info() { echo "INFO $1"; }; log_warn() { echo "WARN $1"; }
  eval "$(sed -n '/^function resolveDrillDefaults()/,/^}/p' "$REPO/scripts/installer/install-snapshot.sh")"
  SERVICE_NAME=app VALIDATOR_WORKER=false SNAPSHOT_VALIDATOR_INBOX=false ENABLE_SNAPSHOT=Y SNAPSHOT_REMOTE_HOST="$REMOTE"
  resolveDrillDefaults; echo "EFFECTIVE $VALIDATOR_WORKER_EFFECTIVE"
) > "$T/setup3" 2>&1
check_has "an existing explicit false stays off" "EFFECTIVE false" "$(cat "$T/setup3")"
(
  log_info() { echo "INFO $1"; }; log_warn() { echo "WARN $1"; }
  eval "$(sed -n '/^function resolveDrillDefaults()/,/^}/p' "$REPO/scripts/installer/install-snapshot.sh")"
  SERVICE_NAME=app VALIDATOR_WORKER=yes SNAPSHOT_VALIDATOR_INBOX="" ENABLE_SNAPSHOT=Y SNAPSHOT_REMOTE_HOST=""
  resolveDrillDefaults; echo "EFFECTIVE $VALIDATOR_WORKER_EFFECTIVE"
) > "$T/setup4" 2>&1
check_has "an invalid value: off, with a warning" "EFFECTIVE false" "$(cat "$T/setup4")"
check_has "  naming the value" "VALIDATOR_WORKER='yes'" "$(cat "$T/setup4")"

section "the template leaves both empty (automatic)"
check_eq ".env.example: VALIDATOR_WORKER=" "VALIDATOR_WORKER=" "$(grep '^VALIDATOR_WORKER=' "$REPO/.env.example")"
check_eq ".env.example: SNAPSHOT_VALIDATOR_INBOX=" "SNAPSHOT_VALIDATOR_INBOX=" "$(grep '^SNAPSHOT_VALIDATOR_INBOX=' "$REPO/.env.example")"

echo
echo -e "Results: ${C_PASS}$passed passed${C_RESET}, ${C_FAIL}$failed failed${C_RESET}, ${C_SKIP}$skipped skipped${C_RESET}"
[ "$failed" -eq 0 ]
