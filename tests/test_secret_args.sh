#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: Checks that no script passes a secret (Odoo master password, database password, Google Drive token or
#              service-account assertion) as a command-line argument, where any user could read it with ps, and that
#              the safe forms still deliver the exact value (real curl and docker clients against local stand-ins).
# Usage: ./tests/test_secret_args.sh
# Dependencies: bash, python3, curl, openssl; docker client optional (its checks are skipped without it)
#
# Safe on a real machine: everything runs in a temporary folder, servers listen on 127.0.0.1 only,
# no daemon is contacted (docker talks to a stand-in API that runs nothing), and no .env is read.

readonly C_RESET="\033[0m" C_PASS="\033[0;32m" C_FAIL="\033[0;31m" C_SKIP="\033[1;33m" C_INFO="\033[0;34m"
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
HERE="$REPO/tests/secret_args"
passed=0 failed=0 skipped=0

pass() { echo -e "${C_PASS}  [PASS] $1${C_RESET}"; passed=$((passed + 1)); }
fail() { echo -e "${C_FAIL}  [FAIL] $1${C_RESET}"; failed=$((failed + 1)); }
skip() { echo -e "${C_SKIP}  [SKIP] $1: $2${C_RESET}"; skipped=$((skipped + 1)); }
section() { echo -e "${C_INFO}== $1 ==${C_RESET}"; }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
check_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi; }
not_in_file() { ! grep -qF -- "$1" "$2" 2>/dev/null; }

for cmd in python3 curl openssl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing dependency: $cmd" >&2; exit 3; }
done

T=$(mktemp -d "${TMPDIR:-/tmp}/test_secret_args.XXXXXX") || exit 3
PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/bin" "$T/home"

# A password with everything that broke the old -F "master_pwd=$X" form, and a token / assertion to look for
SECRET_PW='@pw;type=text/x <sec"ret\ $(id) é'
TOKEN="ya29.test-$RANDOM$RANDOM-token"

start_server() {
  # start_server NAME script args... ; sets ${NAME}_PORT
  local name="$1" i; shift
  python3 "$@" &
  PIDS+=("$!")
  for i in $(seq 50); do [ -s "$T/$name.port" ] && break; sleep 0.1; done
  [ -s "$T/$name.port" ] || { echo "Could not start the $name stand-in" >&2; exit 3; }
  printf -v "${name}_PORT" '%s' "$(cat "$T/$name.port")"
}
start_server http "$HERE/mock_http.py" "$T/http.port" "$T/http.log" "$TOKEN"
U="http://127.0.0.1:$http_PORT"

# curl shim: records each argument (what ps would show), sends Google URLs to the stand-in, runs the real curl
REAL_CURL=$(command -v curl)
cat > "$T/bin/curl" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$T/curl_argv.log"
args=()
for a in "\$@"; do
  a="\${a/https:\/\/oauth2.googleapis.com/$U}"
  a="\${a/https:\/\/www.googleapis.com/$U}"
  args+=("\$a")
done
exec "$REAL_CURL" "\${args[@]}"
SHIM
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH" HOME="$T/home"

last_request() { python3 -c 'import json,sys; print(json.dumps(json.loads(open(sys.argv[1]).read().splitlines()[-1])))' "$T/http.log"; }
req_field() { python3 -c 'import json,sys; r=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"; }

extract_function() {
  # extract_function FILE NAME: prints that top-level function's source
  python3 - "$1" "$2" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
for i, line in enumerate(lines):
    if re.match(r"^(function\s+)?%s\s*\(\)\s*\{" % re.escape(sys.argv[2]), line):
        for j in range(i, len(lines)):
            if lines[j].rstrip() == "}":
                print("\n".join(lines[i:j + 1]))
                sys.exit(0)
sys.exit(1)
PY
}

# ---------------------------------------------------------------------------------------------------
section "scripts: no secret is passed as a command-line argument"
if out=$(python3 "$HERE/scan_scripts.py" "$REPO"); then
  pass "no master password, database password, token or assertion in any argument"
else
  fail "secrets on command lines:"
  printf '         %s\n' "$out"
fi

# ---------------------------------------------------------------------------------------------------
section "Google Drive: the scripts' own token functions (service account key and token check)"
openssl genrsa -out "$T/sa.pem" 2048 2>/dev/null
python3 - "$T/sa.pem" "$T/sa.json" <<'PY'
import json, sys
json.dump({"type": "service_account", "client_email": "test@secret-args.iam.gserviceaccount.com",
           "token_uri": "https://oauth2.googleapis.com/token", "private_key": open(sys.argv[1]).read()},
          open(sys.argv[2], "w"))
PY
for script in scripts/download-snapshot.sh scripts/upload-snapshot.sh scripts/cleanup-snapshot.sh \
              scripts/list-snapshot.sh scripts/upload-temp-snapshots.sh scripts/example/snapshot.sh.example; do
  : > "$T/curl_argv.log"; : > "$T/http.log"
  if ! fns="$(extract_function "$REPO/$script" get_gdrive_access_token_from_sa)
$(extract_function "$REPO/$script" is_gdrive_token_valid)"; then
    fail "$script: token functions not found"; continue
  fi
  got=$( log_error() { echo "ERROR $1" >&2; }; log_warn() { :; }; log_info() { :; }
         eval "$fns"; get_gdrive_access_token_from_sa "$T/sa.json" )
  check_eq "$script: service account key gives a token" "$TOKEN" "$got"
  grant=$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["path"] == "/token": print(r["form"].get("grant_type"), r["form"].get("assertion", "").count("."))' "$T/http.log")
  check_eq "$script: the signed assertion arrived" "urn:ietf:params:oauth:grant-type:jwt-bearer 2" "$grant"
  assertion=$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["path"] == "/token": print(r["form"].get("assertion", "").split(".")[-1])' "$T/http.log")
  check "$script: the assertion is not on curl's command line" not_in_file "${assertion:-none}" "$T/curl_argv.log"

  ( eval "$fns"; is_gdrive_token_valid "$TOKEN" ); rc=$?
  check_eq "$script: a valid token passes the check" 0 "$rc"
  r=$(last_request)
  check_eq "$script: the token check sends the token in the POST body, not the URL" "POST||$TOKEN" \
    "$(req_field "$r" 'r["method"] + "|" + r["query"] + "|" + r["form"].get("access_token", "")')"
  ( eval "$fns"; is_gdrive_token_valid "not-$TOKEN" ); rc=$?
  check_eq "$script: an invalid token fails the check" 1 "$rc"
  check "$script: the token is not on curl's command line" not_in_file "$TOKEN" "$T/curl_argv.log"
done

# ---------------------------------------------------------------------------------------------------
section "Google Drive: bearer header from a pipe (as the scripts call the Drive API)"
: > "$T/curl_argv.log"
ACCESS_TOKEN="$TOKEN"
curl -s -G -H @<(printf 'Authorization: Bearer %s\n' "$ACCESS_TOKEN") \
  --data-urlencode "q=trashed = false" "https://www.googleapis.com/drive/v3/files" >/dev/null
r=$(last_request)
check_eq "the Drive API receives the bearer token" "Bearer $TOKEN" "$(req_field "$r" 'r["auth"]')"
check "the token is not on curl's command line" not_in_file "$TOKEN" "$T/curl_argv.log"

# ---------------------------------------------------------------------------------------------------
section "Odoo database manager: master password from curl's stdin / a pipe"
: > "$T/curl_argv.log"
ADMIN_PASSWD="$SECRET_PW"
printf '%s' "$ADMIN_PASSWD" | curl -s -X POST \
  -F "master_pwd=<-" \
  -F "name=prod_db" \
  -F "backup_format=zip" \
  -o "$T/backup.out" \
  "$U/web/database/backup"
r=$(last_request)
check_eq "backup: the exact master password arrives (;type= < @ quotes \$(...) and UTF-8 kept)" "$SECRET_PW" \
  "$(req_field "$r" 'r["form"].get("master_pwd")')"
check_eq "backup: the other fields are unchanged" "prod_db zip" "$(req_field "$r" 'r["form"]["name"] + " " + r["form"]["backup_format"]')"
check_eq "backup: a normal request body (not chunked, which Odoo may refuse)" False "$(req_field "$r" 'r["chunked"]')"

echo "fake dump" > "$T/backup.zip"
STG_ADMIN_PASSWD="$SECRET_PW"
CURL_RESTORE_ARGS=(
  -sS -X POST
  -F "master_pwd=<-"
  -F "name=stg_db"
  -F "backup_file=@$T/backup.zip"
  -F "copy=true"
)
printf '%s' "$STG_ADMIN_PASSWD" | curl "${CURL_RESTORE_ARGS[@]}" --connect-timeout 10 "$U/web/database/restore" >/dev/null
r=$(last_request)
check_eq "restore (argument array): the password and the uploaded file both arrive" "$SECRET_PW|fake dump" \
  "$(req_field "$r" 'r["form"].get("master_pwd") + "|" + r["form"].get("backup_file", "").strip()')"

DEST_ADMIN_PASSWD="$SECRET_PW&x=1%20"
curl -s -X POST \
  --data-urlencode "master_pwd@"<(printf '%s' "$DEST_ADMIN_PASSWD") \
  -d "name=old_db" \
  "$U/web/database/drop" >/dev/null
r=$(last_request)
check_eq "drop (urlencoded): the exact password arrives, & and % included" "$DEST_ADMIN_PASSWD|old_db" \
  "$(req_field "$r" 'r["form"].get("master_pwd") + "|" + r["form"].get("name")')"
check "the master password is never on curl's command line" not_in_file "pw;type=" "$T/curl_argv.log"

# ---------------------------------------------------------------------------------------------------
section "PostgreSQL password: docker takes it from the environment (-e PGPASSWORD)"
if ! command -v docker >/dev/null 2>&1; then
  skip "docker -e PGPASSWORD" "no docker client"
else
  start_server docker "$HERE/mock_docker_api.py" "$T/docker.port" "$T/docker.log"
  REAL_DOCKER=$(command -v docker)
  cat > "$T/bin/docker" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$T/docker_argv.log"
exec "$REAL_DOCKER" "\$@"
SHIM
  chmod +x "$T/bin/docker"
  db_pass="$SECRET_PW"
  ( export DOCKER_HOST="tcp://127.0.0.1:$docker_PORT" DOCKER_CONFIG="$T/docker-config"
    PGPASSWORD="$db_pass" docker run -i --rm --network="host" -e PGPASSWORD postgres psql -h db -p 5432 -U odoo -d postgres </dev/null
    PGPASSWORD="$db_pass" docker exec -i -e PGPASSWORD "c0ffee" psql -h db -p 5432 -U odoo </dev/null
  ) >/dev/null 2>&1
  envs=$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    print(("exec" if "/exec" in r["path"] else "run") + ":" + "|".join(e for e in r["env"] if e.startswith("PGPASSWORD")))' "$T/docker.log" 2>/dev/null)
  check_eq "docker run sends the container the exact password" "run:PGPASSWORD=$SECRET_PW" "$(echo "$envs" | grep '^run:')"
  check_eq "docker exec sends the container the exact password" "exec:PGPASSWORD=$SECRET_PW" "$(echo "$envs" | grep '^exec:')"
  check "the password is not on docker's command line" not_in_file "pw;type=" "$T/docker_argv.log"
fi

echo
echo -e "Results: ${C_PASS}$passed passed${C_RESET}, ${C_FAIL}$failed failed${C_RESET}, ${C_SKIP}$skipped skipped${C_RESET}"
[ "$failed" -eq 0 ]
