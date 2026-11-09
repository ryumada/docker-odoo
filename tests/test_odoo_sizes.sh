#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: scripts/lib/odoo_sizes.sh (database and filestore sizes for manifest.json), the snapshot tool's
#              manifest "sudodevops" block, and scripts/disk_free_monitor.sh, against a throwaway PostgreSQL:
#              local and remote (DB_HOST, through the docker client) databases, unknown values are null and
#              never 0, and the remote password never appears on a command line.
# Usage: ./tests/test_odoo_sizes.sh   (PG_BIN=/path/to/postgres/bin to choose the server binaries)
# Dependencies: bash, python3, git, PostgreSQL server binaries (initdb, pg_ctl, psql), runuser (root)
#
# Safe on a real machine: the server runs from one mktemp folder (unix socket there, TCP on 127.0.0.1),
# "sudo -u postgres psql" and "docker run ... postgres psql" are sent to it by stand-ins, the filestore is
# a folder in the test directory (ODOO_FILESTORE_ROOT), and nothing outside the test folder is changed.

readonly C_RESET="\033[0m" C_PASS="\033[0;32m" C_FAIL="\033[0;31m" C_SKIP="\033[1;33m" C_INFO="\033[0;34m"
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
passed=0 failed=0 skipped=0
pass() { echo -e "${C_PASS}  [PASS] $1${C_RESET}"; passed=$((passed + 1)); }
fail() { echo -e "${C_FAIL}  [FAIL] $1${C_RESET}"; failed=$((failed + 1)); }
skip() { echo -e "${C_SKIP}  [SKIP] $1: $2${C_RESET}"; skipped=$((skipped + 1)); }
section() { echo -e "${C_INFO}== $1 ==${C_RESET}"; }
check_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi; }
check_grep() { if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1: '$3' not found"; sed 's/^/         /' "$2" | tail -n 12; fi; }

find_pg_bin() {
  local d
  if [ -n "${PG_BIN:-}" ]; then [ -x "$PG_BIN/initdb" ] && { echo "$PG_BIN"; return 0; }; return 1; fi
  for d in $(ls -d /usr/lib/postgresql/*/bin /usr/pgsql-*/bin /usr/local/pgsql/bin 2>/dev/null | sort -V -r); do
    [ -x "$d/initdb" ] && [ -x "$d/pg_ctl" ] && { echo "$d"; return 0; }
  done
  d=$(dirname "$(command -v initdb 2>/dev/null)" 2>/dev/null); [ -x "$d/initdb" ] && { echo "$d"; return 0; }
  return 1
}
PGB=$(find_pg_bin) || { echo "Missing dependency: PostgreSQL server binaries (set PG_BIN)" >&2; exit 3; }
for c in python3 git; do command -v "$c" >/dev/null 2>&1 || { echo "Missing dependency: $c" >&2; exit 3; }; done
PG_USER=""
if [ "$(id -u)" = 0 ]; then
  command -v runuser >/dev/null 2>&1 || { echo "Missing dependency: runuser" >&2; exit 3; }
  if id postgres >/dev/null 2>&1; then PG_USER=postgres; else PG_USER=nobody; fi
fi
as_pg() { if [ -n "$PG_USER" ]; then runuser -u "$PG_USER" -- "$@"; else "$@"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/test_odoo_sizes.XXXXXX") || exit 3
chmod 711 "$T"
cleanup() {
  chmod -R u+rwX "$T" 2>/dev/null
  [ -d "$T/pg" ] && as_pg "$PGB/pg_ctl" -D "$T/pg/data" -m immediate stop >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT

# --- Throwaway server: trust on its own socket, password (scram) over TCP --------------------------
mkdir -p "$T/pg" "$T/bin" "$T/fs/svc/filestore/prod/ab" "$T/fs/svc/filestore/prod/cd"
[ -n "$PG_USER" ] && chown "$PG_USER" "$T/pg"
as_pg "$PGB/initdb" -D "$T/pg/data" -U postgres --auth-local=trust --auth-host=scram-sha-256 -E UTF8 --no-sync \
  > "$T/initdb.log" 2>&1 || { echo "initdb failed:"; cat "$T/initdb.log"; exit 3; }
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
as_pg "$PGB/pg_ctl" -D "$T/pg/data" -l "$T/pg/server.log" -w -t 30 \
  -o "-c listen_addresses=127.0.0.1 -p $PORT -k $T/pg -c unix_socket_permissions=0777 -c fsync=off" start >/dev/null \
  || { echo "PostgreSQL did not start:"; cat "$T/pg/server.log"; exit 3; }
q() { "$PGB/psql" -X -q -h "$T/pg" -p "$PORT" -U postgres -v ON_ERROR_STOP=1 "$@"; }
DB_PASSWORD='s3cr;et "pw" $(id)'
q -d postgres -v pw="$DB_PASSWORD" <<'SQL'
CREATE ROLE odoo_s LOGIN PASSWORD :'pw';
CREATE DATABASE prod OWNER odoo_s;
CREATE DATABASE bare OWNER odoo_s;
SQL
q -d prod <<'SQL'
CREATE TABLE ir_attachment (id serial PRIMARY KEY, store_fname varchar);
INSERT INTO ir_attachment (store_fname) VALUES ('ab/1'), ('cd/2'), ('cd/3'), (NULL);
ALTER TABLE ir_attachment OWNER TO odoo_s;  -- in an Odoo database the deployment's user owns its tables
SQL
head -c 100 /dev/zero > "$T/fs/svc/filestore/prod/ab/1"
head -c 250 /dev/zero > "$T/fs/svc/filestore/prod/cd/2"
SERVER_VERSION=$(q -d postgres -tA -c "SHOW server_version" | grep -oE '^[0-9]+(\.[0-9]+)*')
PROD_SIZE=$(q -d postgres -tA -c "SELECT pg_database_size('prod')")

# Stand-ins: "sudo -u postgres psql" -> the server's socket; "sudo -u X git" -> git; "docker run ... postgres psql"
# -> psql over TCP with the password from the environment (as the postgres image would get it); "id -u" -> 0
# for disk_free_monitor.sh, which elevates itself otherwise
cat > "$T/bin/sudo" <<SHIM
#!/usr/bin/env bash
[ "\$1" = -u ] && shift 2
cmd="\$1"; shift
case "\$cmd" in
  psql) exec "$PGB/psql" -h "$T/pg" -p "$PORT" -U postgres "\$@" ;;
  git) exec git "\$@" ;;
esac
echo "test sudo: unexpected command \$cmd" >&2; exit 99
SHIM
cat > "$T/bin/docker" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$T/docker_argv.log"
[ "\$1" = run ] || { echo "test docker: unexpected \$1" >&2; exit 99; }
shift
while [ \$# -gt 0 ]; do case "\$1" in -i|--rm|--network=*) shift ;; -e) shift 2 ;; postgres) shift; break ;; *) echo "test docker: unexpected \$1" >&2; exit 99 ;; esac; done
cmd="\$1"; shift
[ "\$cmd" = psql ] || exit 99
exec "$PGB/psql" "\$@"
SHIM
cat > "$T/bin/id" <<SHIM
#!/usr/bin/env bash
[ "\$1" = -u ] && [ \$# -eq 1 ] && { echo 0; exit 0; }
exec /usr/bin/env -u PATH "\$(PATH=/usr/bin:/bin command -v id)" "\$@"
SHIM
chmod +x "$T/bin/sudo" "$T/bin/docker" "$T/bin/id"

mkdir -p "$T/local/.secrets" "$T/remote/.secrets"
: > "$T/local/.env"
printf 'DB_HOST=127.0.0.1\nDB_PORT=%s\nDOCKER_NETWORK_MODE=host\n' "$PORT" > "$T/remote/.env"
printf 'odoo_s' > "$T/remote/.secrets/db_user"
printf '%s' "$DB_PASSWORD" > "$T/remote/.secrets/db_password"

sizes() {
  # sizes ENV_DIR DB FILESTORE_DIR -> the JSON line (lib run in a clean subshell with the stand-ins first on PATH)
  ( export PATH="$T/bin:$PATH"; source "$REPO/scripts/lib/odoo_sizes.sh"; odoo_sizes_json "$1/.env" "$2" "$3" )
}
field() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); v=eval(sys.argv[2]); print("null" if v is None else v)' "$1" "$2" 2>/dev/null || echo "invalid-json"; }

# ---------------------------------------------------------------------------------------------------
section "local database"
J=$(sizes "$T/local" prod "$T/fs/svc/filestore/prod")
check_eq "valid JSON" ok "$(python3 -c 'import json,sys; json.loads(sys.argv[1]); print("ok")' "$J" 2>/dev/null)"
check_eq "server version" "$SERVER_VERSION" "$(field "$J" 'd["postgres"]["server_version"]')"
check_eq "database size (pg_database_size)" "$PROD_SIZE" "$(field "$J" 'd["postgres"]["db_size_bytes"]')"
check_eq "stored attachments (rows with a store_fname)" 3 "$(field "$J" 'd["attachments"]["stored"]')"
check_eq "filestore bytes" 350 "$(field "$J" 'd["filestore"]["bytes"]')"
check_eq "filestore files" 2 "$(field "$J" 'd["filestore"]["files"]')"

J=$(sizes "$T/local" bare "$T/fs/svc/filestore/bare")
check_eq "database without Odoo: size still measured" yes "$(field "$J" '"yes" if d["postgres"]["db_size_bytes"] > 0 else "no"')"
check_eq "database without Odoo: attachments unknown (null, not 0)" null "$(field "$J" 'd["attachments"]["stored"]')"
check_eq "filestore folder not created yet: empty, not unknown" "0 0" "$(field "$J" '"%s %s" % (d["filestore"]["bytes"], d["filestore"]["files"])')"

J=$(sizes "$T/local" no_such_db "$T/fs/svc/filestore/prod")
check_eq "database that cannot be reached: version, size and attachments are null" "null null null" \
  "$(field "$J" '" ".join("null" if v is None else str(v) for v in (d["postgres"]["server_version"], d["postgres"]["db_size_bytes"], d["attachments"]["stored"]))')"
check_eq "and still valid JSON with the filestore measured" 350 "$(field "$J" 'd["filestore"]["bytes"]')"

if [ "$(id -u)" = 0 ]; then
  skip "unreadable filestore" "root can read every folder"
else
  chmod 000 "$T/fs/svc/filestore/prod/cd"
  J=$(sizes "$T/local" prod "$T/fs/svc/filestore/prod")
  check_eq "unreadable filestore folder: size unknown (null), not the part that could be read" "null null" \
    "$(field "$J" '"%s %s" % ("null" if d["filestore"]["bytes"] is None else d["filestore"]["bytes"], "null" if d["filestore"]["files"] is None else d["filestore"]["files"])')"
  chmod 755 "$T/fs/svc/filestore/prod/cd"
fi

# ---------------------------------------------------------------------------------------------------
section "database on another host (DB_HOST, through the docker client)"
: > "$T/docker_argv.log"
J=$(sizes "$T/remote" prod "$T/fs/svc/filestore/prod")
check_eq "remote: database size (the password reached PostgreSQL)" "$PROD_SIZE" "$(field "$J" 'd["postgres"]["db_size_bytes"]')"
check_eq "remote: stored attachments" 3 "$(field "$J" 'd["attachments"]["stored"]')"
check_eq "remote: connects as the deployment's database user" yes "$(grep -qx odoo_s "$T/docker_argv.log" && echo yes || echo no)"
check_eq "remote: the password is not on docker's command line" no "$(grep -qF 's3cr;et' "$T/docker_argv.log" && echo yes || echo no)"
printf 'wrong' > "$T/remote/.secrets/db_password"
J=$(sizes "$T/remote" prod "$T/fs/svc/filestore/prod")
check_eq "remote with a wrong password: null, not 0" null "$(field "$J" 'd["postgres"]["db_size_bytes"]')"
printf '%s' "$DB_PASSWORD" > "$T/remote/.secrets/db_password"

# ---------------------------------------------------------------------------------------------------
section "snapshot tool: manifest.json carries the sizes"
SNAP="$REPO/scripts/example/snapshot.sh.example"
check_grep "the snapshot tool loads the size library" "$SNAP" 'source "$PATH_TO_ODOO/scripts/lib/odoo_sizes.sh"'
SUDODEVOPS_JSON=$(sizes "$T/local" prod "$T/fs/svc/filestore/prod")
python3 - "$SNAP" "$T/local_manifest.sh" "$T/remote_manifest.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
i = s.index('cat <<EOF > "$DATA_STAGING_DIR/manifest.json"'); j = s.index("\nEOF\n", i) + 5
open(sys.argv[2], "w").write(s[i:j])
i = s.index('''remote_exec "cat <<'MANIFEST_EOF' > '$remote_staging/manifest.json'"''') if False else s.index('remote_exec "cat <<\'MANIFEST_EOF\'')
j = s.index('MANIFEST_EOF"', i + 20) + len('MANIFEST_EOF"')
open(sys.argv[3], "w").write(s[i:j] + "\n")
PY
mkdir -p "$T/staging" "$T/rstaging"
manifest_vars() {
  DATA_STAGING_DIR="$T/staging" remote_staging="$T/rstaging" ODOO_DATABASE_NAME_PRD=prod
  MANIFEST_VERSION=16.0 MANIFEST_MAJOR_VERSION=16.0 MANIFEST_VERSION_INFO='[16, 0, 0, "final", 0, ""]'
}
( manifest_vars; source "$T/local_manifest.sh" )
( manifest_vars; remote_exec() { bash -c "$1"; }; source "$T/remote_manifest.sh" )
for m in staging rstaging; do
  name=$([ "$m" = staging ] && echo "local snapshot" || echo "Secondary VPS snapshot")
  check_eq "$name: manifest.json is valid JSON with the database size" "$PROD_SIZE" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sudodevops"]["postgres"]["db_size_bytes"])' "$T/$m/manifest.json" 2>&1)"
  check_eq "$name: the Odoo version fields are unchanged" "16.0 16" \
    "$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["version"], m["version_info"][0])' "$T/$m/manifest.json" 2>&1)"
done

# ---------------------------------------------------------------------------------------------------
section "disk_free_monitor.sh"
APP="$T/apps/svc"
mkdir -p "$APP/scripts/lib" "$APP/.secrets"
cp "$REPO/scripts/disk_free_monitor.sh" "$APP/scripts/"; cp "$REPO/scripts/lib/odoo_sizes.sh" "$APP/scripts/lib/"
git -C "$APP" init -q . 2>/dev/null
printf 'ACTIVE_DB_USER=odoo_s\n' > "$APP/.env"
monitor() { ( export PATH="$T/bin:$PATH" ODOO_FILESTORE_ROOT="$T/fs"; bash "$APP/scripts/disk_free_monitor.sh" "$@" ) > "$T/monitor.out" 2>&1; echo $?; }
check_eq "local: runs" 0 "$(monitor)"
check_grep "local: lists the user's databases" "$T/monitor.out" "Database: "
check_grep "local: filestore with file and attachment counts" "$T/monitor.out" "(2 files, 3 stored attachments)"
check_grep "local: a database without Odoo shows its attachments as unknown" "$T/monitor.out" "unknown stored attachments"
printf 'ACTIVE_DB_USER=odoo_s\nDB_HOST=127.0.0.1\nDB_PORT=%s\nDOCKER_NETWORK_MODE=host\n' "$PORT" > "$APP/.env"
cp "$T/remote/.secrets/"* "$APP/.secrets/"
check_eq "remote database: runs" 0 "$(monitor prod)"
check_grep "remote database: measured (before, only a local PostgreSQL was supported)" "$T/monitor.out" "(2 files, 3 stored attachments)"
printf 'wrong' > "$APP/.secrets/db_password"
monitor prod >/dev/null
check_grep "remote database unreachable: size shows as unknown, not 0" "$T/monitor.out" "PostgreSQL Size :   unknown"
check_grep "and the summary says totals are incomplete" "$T/monitor.out" "could not be measured"

echo
echo -e "Results: ${C_PASS}$passed passed${C_RESET}, ${C_FAIL}$failed failed${C_RESET}, ${C_SKIP}$skipped skipped${C_RESET}"
[ "$failed" -eq 0 ]
