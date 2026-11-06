#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: Shared setup, isolation, assertions and validator runner for the validate-snapshot test suites.
# Usage: source tests/validate_snapshot/lib.sh (from tests/test_validate_snapshot.sh)
# Dependencies: bash, python3, zstd, tar, git, curl, openssl, flock, PostgreSQL server binaries (PG_BIN), runuser (root)
#
# Isolation (the tests are safe to run on a real VPS or dev machine):
#   - everything lives in one mktemp folder ($T), removed at the end (TVS_KEEP=1 keeps it); TMPDIR points there
#   - the validator runs from a COPY of scripts/ outside any git checkout, with an empty .env and HOME=$T/home,
#     so it never reads the repository's real .env or the user's settings; remote/Drive variables are unset
#   - queue locks go to $T/locks (QUEUE_LOCK_DIR), never /tmp
#   - docker, df and gcloud are fakes (tests/validate_snapshot/bin); a "container" is a local Postgres server

readonly TVS_C_RESET="\033[0m"
readonly TVS_C_PASS="\033[0;32m"
readonly TVS_C_FAIL="\033[0;31m"
readonly TVS_C_SKIP="\033[1;33m"
readonly TVS_C_INFO="\033[0;34m"

TVS_PASSED=0
TVS_FAILED=0
TVS_SKIPPED=0
TVS_FAILURES=()
# shellcheck disable=SC2034  # TVS_SUITE is set by each suite and read by fail()
TVS_SUITE=""

# --- Reporting ---------------------------------------------------------------
tvs_section() { echo -e "\n${TVS_C_INFO}== $* ==${TVS_C_RESET}"; }
tvs_info() { echo -e "${TVS_C_INFO}  .. $*${TVS_C_RESET}"; }
pass() { echo -e "${TVS_C_PASS}  [PASS] $1${TVS_C_RESET}"; TVS_PASSED=$((TVS_PASSED + 1)); }
fail() {
  echo -e "${TVS_C_FAIL}  [FAIL] $1${2:+: $2}${TVS_C_RESET}"
  TVS_FAILED=$((TVS_FAILED + 1)); TVS_FAILURES+=("${TVS_SUITE:-?}: $1")
  [ -n "${VS_LOG:-}" ] && [ -f "$VS_LOG" ] && [ "${TVS_VERBOSE:-}" = 1 ] && tail -n 15 "$VS_LOG" | sed 's/^/         | /'
  return 0
}
skip() { echo -e "${TVS_C_SKIP}  [SKIP] $1${2:+: $2}${TVS_C_RESET}"; TVS_SKIPPED=$((TVS_SKIPPED + 1)); }

check() {
  # check "description" command args...   passes when the command succeeds
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
check_not() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi
}
check_eq() {
  # check_eq "description" expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}
check_rc() {
  # check_rc "description" expected_exit_code   (uses VS_RC from the last validator run)
  if [ "${VS_RC:-x}" = "$2" ]; then pass "$1 (exit $2)"; else fail "$1" "expected exit $2, got ${VS_RC:-none} (log: ${VS_LOG:-?})"; fi
}
check_grep() {
  # check_grep "description" file fixed-string
  if grep -qF -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1" "'$3' not found in $(basename "$2")"; fi
}
check_no_grep() {
  if [ -e "$2" ] && grep -qF -- "$3" "$2" 2>/dev/null; then fail "$1" "'$3' found in $(basename "$2")"; else pass "$1"; fi
}

# --- JSON helpers ------------------------------------------------------------
rj() {
  # rj FILE PYTHON_EXPR   evaluates EXPR with r = the parsed JSON; prints the value ("" on any error)
  python3 -c '
import json, sys
try:
    r = json.load(open(sys.argv[1]))
    v = eval(sys.argv[2])
except Exception:
    v = ""
print("" if v is None else (json.dumps(v) if isinstance(v, (dict, list, bool)) else v))
' "$1" "$2" 2>/dev/null
}
stage_of() {
  # stage_of REPORT NAME [field]   status of a stage (or one of its details fields)
  if [ -n "${3:-}" ]; then
    rj "$1" "[s for s in r['stages'] if s['name']=='$2'][-1]['details'].get('$3')"
  else
    rj "$1" "[s for s in r['stages'] if s['name']=='$2'][-1]['status']"
  fi
}

# --- Waiting -----------------------------------------------------------------
wait_until() {
  # wait_until TIMEOUT_S command args...   polls every 0.2s
  local t="$1" end; shift
  end=$(( $(date +%s%N) + t * 1000000000 ))
  while [ "$(date +%s%N)" -lt "$end" ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  "$@" >/dev/null 2>&1
}
log_has() { grep -qF -- "$2" "$1" 2>/dev/null; }
wait_for_log() { wait_until "${3:-60}" log_has "$1" "$2"; }
pid_gone() { ! kill -0 "$1" 2>/dev/null; }

# --- Setup / teardown --------------------------------------------------------
tvs_find_pg_bin() {
  local d
  if [ -n "${PG_BIN:-}" ]; then [ -x "$PG_BIN/initdb" ] && { echo "$PG_BIN"; return 0; }; return 1; fi
  for d in $(ls -d /usr/lib/postgresql/*/bin /usr/pgsql-*/bin /usr/local/pgsql/bin 2>/dev/null | sort -V -r); do
    [ -x "$d/initdb" ] && [ -x "$d/pg_ctl" ] && { echo "$d"; return 0; }
  done
  d=$(pg_config --bindir 2>/dev/null); [ -n "$d" ] && [ -x "$d/initdb" ] && { echo "$d"; return 0; }
  d=$(dirname "$(command -v initdb 2>/dev/null)" 2>/dev/null); [ -x "$d/initdb" ] && { echo "$d"; return 0; }
  return 1
}

tvs_setup() {
  # Args: repo_root. Exits 3 when a dependency is missing.
  TVS_REPO="$1"
  TVS_DIR="$TVS_REPO/tests/validate_snapshot"
  local missing=() c
  [ "$(uname -s)" = Linux ] || { echo "These tests need Linux (GNU stat, /proc, flock)." >&2; exit 3; }
  for c in python3 zstd tar git curl openssl flock sha256sum timeout base64 truncate setsid; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  TVS_PG_BIN=$(tvs_find_pg_bin) || missing+=("PostgreSQL server binaries (initdb, pg_ctl; set PG_BIN)")
  if [ "$(id -u)" = 0 ]; then
    command -v runuser >/dev/null 2>&1 || missing+=("runuser")
    if id postgres >/dev/null 2>&1; then TVS_PG_USER=postgres; else TVS_PG_USER=nobody; fi
  else
    TVS_PG_USER=""
  fi
  if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing dependencies: ${missing[*]}" >&2
    exit 3
  fi

  T=$(mktemp -d "${TMPDIR:-/tmp}/test_validate_snapshot_XXXXXX") || { echo "mktemp failed" >&2; exit 3; }
  chmod 711 "$T"
  TVS_ORIG_PATH="$PATH"
  export TMPDIR="$T/tmp"
  mkdir -p "$T"/{tmp,home,locks,vwork,reports,logs,fx,dl,gcs,git,app,fakebin,cbin} || exit 3
  chmod 711 "$T/dl"
  cp "$TVS_DIR"/bin/docker "$TVS_DIR"/bin/df "$TVS_DIR"/bin/gcloud "$T/fakebin/" && chmod 755 "$T"/fakebin/* || exit 3

  # The validator runs from a copy of scripts/, outside any git checkout, with an empty .env
  cp -a "$TVS_REPO/scripts" "$T/app/scripts" || exit 3
  : > "$T/app/.env"
  VALIDATOR="$T/app/scripts/validate-snapshot.sh"
  if git -C "$T/app/scripts" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "The test folder $T is inside a git checkout; set TMPDIR to another folder." >&2
    exit 3
  fi

  # A git remote for the fixtures' recorded commit
  local wt="$T/git/wt"
  mkdir -p "$wt" && echo "odoo" > "$wt/README"
  ( export HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
    cd "$wt" && git init -q -b main . && git add README \
      && git -c user.name=test -c user.email=test@example.invalid commit -q -m init \
      && git clone -q --bare "$wt" "$T/git/odoo-base.git" ) || { echo "Cannot create the fixture git repository" >&2; exit 3; }
  export FIXTURE_GIT_COMMIT
  FIXTURE_GIT_COMMIT=$(git -C "$wt" rev-parse HEAD)
  export FIXTURE_GIT_REMOTE="file://$T/git/odoo-base.git"
  export FIXTURE_PWNED_DIR="$T"
  rm -rf "$wt"
  echo -e "${TVS_C_INFO}Test folder: $T  (Postgres: $TVS_PG_BIN${TVS_PG_USER:+, running as $TVS_PG_USER})${TVS_C_RESET}"
}

tvs_kill_leftovers() {
  # Stops anything still running from the test folder (validator subshells, Postgres, sshd, mock Drive)
  local pid pids=() me=$$ anc p
  anc=" $me "; p=$me
  while [ "$p" -gt 1 ] 2>/dev/null; do p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null) || break; anc="$anc$p "; done
  for f in "$T"/dl/slow_restore.pid "$T"/dr/slow_restore.pid; do
    [ -f "$f" ] || continue
    pid=$(cat "$f"); [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = sleep ] && kill "$pid" 2>/dev/null
  done
  [ -f "$T/ssh/sshd.pid" ] && kill "$(cat "$T/ssh/sshd.pid")" 2>/dev/null
  for p in /proc/[0-9]*; do
    pid="${p#/proc/}"
    [[ "$anc" == *" $pid "* ]] && continue
    tr '\0' ' ' 2>/dev/null < "$p/cmdline" | grep -qF -- "$T" && pids+=("$pid")
  done
  [ ${#pids[@]} -gt 0 ] || return 0
  kill -TERM "${pids[@]}" 2>/dev/null
  sleep 0.5
  kill -KILL "${pids[@]}" 2>/dev/null
  return 0
}

tvs_cleanup() {
  [ -n "${T:-}" ] && [ -d "$T" ] || return 0
  tvs_kill_leftovers
  if [ "${TVS_KEEP:-}" = 1 ]; then
    echo -e "${TVS_C_INFO}Test folder kept (TVS_KEEP=1): $T${TVS_C_RESET}"
  else
    rm -rf "$T" 2>/dev/null || { sleep 1; rm -rf "$T"; }
  fi
}

# --- Fixtures ----------------------------------------------------------------
fx() {
  # fx VARIANT [SERVICE] [TIMESTAMP] [DIR]   builds a fresh fixture and prints its archive path
  local dir="${4:-$T/fx/$1-$RANDOM$RANDOM}"
  bash "$TVS_DIR/mkfixture.sh" "$dir" "$1" "${2:-svc}" "${3:-20260101-000000}"
}

# --- Running the validator ---------------------------------------------------
tvs_env() {
  # Prints the environment for a validator run on the main side (as NAME=value lines for env -i style use)
  printf '%s\n' \
    "PATH=$T/fakebin:$T/cbin:$TVS_ORIG_PATH" "HOME=$T/home" "TMPDIR=$T/tmp" "USER=$(id -un)" "LOGNAME=$(id -un)" \
    "LANG=C.UTF-8" "TERM=dumb" \
    "QUEUE_LOCK_DIR=$T/locks" "QUEUE_LOCK_HEARTBEAT=1" "QUEUE_LOCK_POLL_INTERVAL=1" \
    "VALIDATOR_WORK_DIR=$T/vwork" "VALIDATOR_DISK_RESERVE_GB=1" "VALIDATOR_WATCHDOG_INTERVAL=1" \
    "VALIDATOR_GIT_ALLOW_PROTOCOL=file" "VALIDATOR_GIT_TIMEOUT=30" "VALIDATOR_QUEUE_TIMEOUT=120" \
    "FAKE_DOCKER_STATE=$T/dl" "FAKE_GCS_ROOT=$T/gcs" "PG_BIN=$TVS_PG_BIN" "FAKE_PG_USER=$TVS_PG_USER" \
    "NO_PROXY=127.0.0.1,localhost" "no_proxy=127.0.0.1,localhost"
}

vs_prepare() {
  # vs_prepare NAME [VAR=value ...] [-- validator args...]  -> VS_CMD (env + command), VS_LOG, VS_REPORT
  VS_NAME="$1"; shift
  VS_LOG="$T/logs/$VS_NAME.log"
  VS_REPORT="$T/reports/$VS_NAME.json"
  rm -f "$VS_LOG" "$VS_REPORT"
  local envs=() line
  while IFS= read -r line; do envs+=("$line"); done < <(tvs_env)
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  VS_CMD=(env -i "${envs[@]}" bash "$VALIDATOR" "$@")
  [ "${VS_NO_REPORT:-}" = 1 ] || VS_CMD+=(--report "$VS_REPORT")
}

vs() {
  # vs NAME [VAR=value ...] -- validator args...   runs and waits; sets VS_RC
  vs_prepare "$@"
  "${VS_CMD[@]}" </dev/null >"$VS_LOG.out" 2>"$VS_LOG"
  VS_RC=$?
  return 0
}

vs_bg() {
  # Same as vs, in the background (own session, SIGINT at its default); sets VS_PID
  vs_prepare "$@"
  python3 "$TVS_DIR/launch.py" "${VS_CMD[@]}" </dev/null >"$VS_LOG.out" 2>"$VS_LOG" &
  VS_PID=$!
  VS_RC=""
}

vs_wait() {
  # vs_wait [TIMEOUT_S]: waits for the background run; kills it after the timeout (VS_RC=timeout)
  local t="${1:-180}"
  if ! wait_until "$t" pid_gone "$VS_PID"; then
    kill -KILL -- "-$VS_PID" 2>/dev/null; kill -KILL "$VS_PID" 2>/dev/null
    wait "$VS_PID" 2>/dev/null
    VS_RC=timeout
    return 1
  fi
  wait "$VS_PID" 2>/dev/null
  VS_RC=$?
}

kill_slow_restore() {
  # Lets a FAKE_SLOW_RESTORE drill continue: kills the recorded sleep (state dir, default $T/dl)
  local f="${1:-$T/dl}/slow_restore.pid" pid
  wait_until 20 test -s "$f" || return 1
  pid=$(cat "$f")
  [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = sleep ] && kill "$pid" 2>/dev/null
  rm -f "$f"
}

containers_in() { local d n=0; for d in "${1:-$T/dl}"/c/*; do [ -e "$d" ] && n=$((n + 1)); done; echo "$n"; }
no_containers() { [ "$(containers_in "${1:-$T/dl}")" = 0 ]; }
no_networks() { [ -z "$(ls "${1:-$T/dl}/net" 2>/dev/null)" ]; }
no_postgres_under() {
  # No Postgres server process running from this folder
  local p
  for p in /proc/[0-9]*; do
    tr '\0' ' ' 2>/dev/null < "$p/cmdline" | grep -q "postgres.*-D $1" && return 1
  done
  return 0
}
lock_free() {
  # lock_free LOCKDIR: the validator queue's flock can be taken and no fresh marker remains
  local dir="${1:-$T/locks}" f
  for f in "$dir"/odoo-snapshot-validator.queue.active.*; do [ -e "$f" ] && return 1; done
  [ -e "$dir/odoo-snapshot-validator.queue.lock" ] || return 0
  flock -n "$dir/odoo-snapshot-validator.queue.lock" true
}
runs_empty() { [ -z "$(ls -A "${1:-$T/vwork}/runs" 2>/dev/null)" ]; }

# --- Mock Google Drive -------------------------------------------------------
drive_start() {
  # Starts a fresh mock Drive: TVS_DRIVE (its folder), TVS_DRIVE_URL, TVS_TOKEN, TVS_FOLDER
  [ -n "${TVS_DRIVE_PID:-}" ] && drive_stop
  TVS_DRIVE="$T/drive-$RANDOM$RANDOM"
  TVS_FOLDER="folder$RANDOM"
  TVS_TOKEN="ya29.mock-$(openssl rand -hex 20)"
  mkdir -p "$TVS_DRIVE"
  MOCK_TOKEN="$TVS_TOKEN" python3 "$TVS_DIR/mock_drive.py" serve --root "$TVS_DRIVE" >"$TVS_DRIVE/server.log" 2>&1 &
  TVS_DRIVE_PID=$!
  wait_until 15 test -s "$TVS_DRIVE/port" || { fail "mock Drive started" "$(cat "$TVS_DRIVE/server.log")"; return 1; }
  TVS_DRIVE_URL="http://127.0.0.1:$(cat "$TVS_DRIVE/port")"
}
drive_stop() { [ -n "${TVS_DRIVE_PID:-}" ] && kill "$TVS_DRIVE_PID" 2>/dev/null && wait "$TVS_DRIVE_PID" 2>/dev/null; TVS_DRIVE_PID=""; }
drive_seed() {
  # drive_seed FILE [NAME] [CREATED]   uploads FILE (and FILE.sha256 when present) into TVS_FOLDER
  local f="$1" n="${2:-$(basename "$1")}" c="${3:-}"
  python3 "$TVS_DIR/mock_drive.py" seed --root "$TVS_DRIVE" --folder "$TVS_FOLDER" --name "$n" ${c:+--created "$c"} --file "$f" >/dev/null || return 1
  [ -f "$f.sha256" ] && python3 "$TVS_DIR/mock_drive.py" seed --root "$TVS_DRIVE" --folder "$TVS_FOLDER" --name "$n.sha256" ${c:+--created "$c"} --file "$f.sha256" >/dev/null
  return 0
}
drive_count() {
  # drive_count NAME   number of non-trashed files with that name
  python3 -c '
import glob, json, sys
print(sum(1 for p in glob.glob(sys.argv[1] + "/files/*.json")
          for m in [json.load(open(p))] if m["name"] == sys.argv[2] and not m.get("trashed")))' "$TVS_DRIVE" "$1"
}
drive_content() {
  # drive_content NAME   prints the content of the (newest) file with that name
  python3 -c '
import glob, json, sys
ms = sorted((json.load(open(p)) for p in glob.glob(sys.argv[1] + "/files/*.json")), key=lambda m: m["createdTime"])
ms = [m for m in ms if m["name"] == sys.argv[2] and not m.get("trashed")]
sys.stdout.write(open(sys.argv[1] + "/files/" + ms[-1]["id"] + ".bin").read() if ms else "")' "$TVS_DRIVE" "$1"
}
drive_env() { echo "GDS_API_BASE=$TVS_DRIVE_URL" "GDRIVE_FOLDER_ID=$TVS_FOLDER"; }

make_sa() {
  # make_sa OUT_JSON   service-account key (pretty-printed JSON) whose token_uri is the mock Drive;
  # also writes OUT_JSON.pub (public key) for checking signatures
  local out="$1"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$out.key" 2>/dev/null || return 1
  openssl pkey -in "$out.key" -pubout -out "$out.pub" 2>/dev/null || return 1
  python3 -c '
import json, sys
key = open(sys.argv[2]).read()
json.dump({"type": "service_account", "project_id": "tvs-test", "private_key_id": "0123abcd",
           "private_key": key, "client_email": "drill@tvs-test.iam.gserviceaccount.com",
           "client_id": "1234567890", "token_uri": sys.argv[3] + "/token"}, open(sys.argv[1], "w"), indent=2)
' "$out" "$out.key" "$TVS_DRIVE_URL" || return 1
  rm -f "$out.key"
  chmod 600 "$out"
}
