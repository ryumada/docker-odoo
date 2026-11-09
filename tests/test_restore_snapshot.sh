#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: scripts/restore-snapshot.sh against a throwaway PostgreSQL. Database part (restoreOdooData):
#              a broken, cut-short or empty dump must fail loudly instead of reporting success, harmless
#              permission errors only warn, and an open session (a running Odoo) no longer blocks the drop.
#              Data-only restore (restoreSnapshotDataOnly): bundled directories are extracted whole and
#              restored, configuration and custom directories are left out, and a snapshot missing a
#              bundled directory is refused before anything is changed.
# Usage: ./tests/test_restore_snapshot.sh   (PG_BIN=/path/to/postgres/bin to choose the server binaries)
# Dependencies: bash, python3, git, tar, zstd, PostgreSQL server binaries (initdb, pg_ctl, psql, pg_dump, pg_restore), runuser (root)
#
# Safe on a real machine: the server runs from one mktemp folder on 127.0.0.1 and a free port, the
# script's "sudo -u postgres psql" calls are sent to it by a stand-in sudo ("sudo -u <owner> git" runs git as
# you), the deployment is a folder in the test directory, and no snapshot contains a filestore, so nothing
# under /var/lib/odoo is touched. Nothing else on the machine is read or changed.

readonly C_RESET="\033[0m" C_PASS="\033[0;32m" C_FAIL="\033[0;31m" C_INFO="\033[0;34m"
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SCRIPT="$REPO/scripts/restore-snapshot.sh"
passed=0 failed=0

pass() { echo -e "${C_PASS}  [PASS] $1${C_RESET}"; passed=$((passed + 1)); }
fail() { echo -e "${C_FAIL}  [FAIL] $1${C_RESET}"; failed=$((failed + 1)); }
section() { echo -e "${C_INFO}== $1 ==${C_RESET}"; }
check_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi; }
check_grep() { if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1: '$3' not in output"; sed 's/^/         /' "$2" | tail -n 8; fi; }

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
for c in python3 git tar zstd; do command -v "$c" >/dev/null 2>&1 || { echo "Missing dependency: $c" >&2; exit 3; }; done
PG_USER=""
if [ "$(id -u)" = 0 ]; then
  command -v runuser >/dev/null 2>&1 || { echo "Missing dependency: runuser" >&2; exit 3; }
  if id postgres >/dev/null 2>&1; then PG_USER=postgres; else PG_USER=nobody; fi
fi
as_pg() { if [ -n "$PG_USER" ]; then runuser -u "$PG_USER" -- "$@"; else "$@"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/test_restore_snapshot.XXXXXX") || exit 3
chmod 711 "$T"
SESSION_PID=""
cleanup() {
  [ -n "$SESSION_PID" ] && kill "$SESSION_PID" 2>/dev/null
  [ -d "$T/pg" ] && as_pg "$PGB/pg_ctl" -D "$T/pg/data" -m immediate stop >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT

# --- Throwaway server ---------------------------------------------------------------------------
mkdir -p "$T/pg" "$T/bin" "$T/app/.secrets" "$T/tmpdir" "$T/x"
[ -n "$PG_USER" ] && chown "$PG_USER" "$T/pg"
as_pg "$PGB/initdb" -D "$T/pg/data" -U postgres --auth=trust -E UTF8 --no-sync > "$T/initdb.log" 2>&1 \
  || { echo "initdb failed:"; cat "$T/initdb.log"; exit 3; }
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
as_pg "$PGB/pg_ctl" -D "$T/pg/data" -l "$T/pg/server.log" -w -t 30 \
  -o "-c listen_addresses=127.0.0.1 -p $PORT -k $T/pg -c unix_socket_permissions=0700 -c fsync=off" start >/dev/null \
  || { echo "PostgreSQL did not start:"; cat "$T/pg/server.log"; exit 3; }
q() { "$PGB/psql" -X -q -h 127.0.0.1 -p "$PORT" -U postgres -v ON_ERROR_STOP=1 "$@"; }

# The script runs "sudo -u postgres psql|pg_restore ..." for a local database: send those to the test server
cat > "$T/bin/sudo" <<SHIM
#!/usr/bin/env bash
[ "\$1" = -u ] && shift 2
cmd="\$1"; shift
case "\$cmd" in
  psql|pg_restore) exec "$PGB/\$cmd" -h 127.0.0.1 -p "$PORT" -U postgres "\$@" ;;
  git) exec git "\$@" ;;
esac
echo "test sudo: unexpected command \$cmd" >&2; exit 99
SHIM
chmod +x "$T/bin/sudo"

# --- Source database and dumps -------------------------------------------------------------------
q -d postgres -c "CREATE ROLE odoo_t LOGIN" -c "CREATE ROLE temp_grantee" -c "CREATE DATABASE src"
q -d src <<'SQL'
CREATE TABLE ir_module_module (id serial PRIMARY KEY, name varchar NOT NULL, state varchar);
INSERT INTO ir_module_module (name, state) VALUES ('base', 'installed'), ('web', 'installed'), ('crm', 'uninstalled');
CREATE TABLE res_partner (id serial PRIMARY KEY, name varchar NOT NULL);
INSERT INTO res_partner (name) SELECT 'partner ' || g FROM generate_series(1, 500) g;
SQL
"$PGB/pg_dump" -h 127.0.0.1 -p "$PORT" -U postgres --no-owner src > "$T/good.sql"
"$PGB/pg_dump" -h 127.0.0.1 -p "$PORT" -U postgres --no-owner -Fc src > "$T/good.custom"
# A custom dump that grants to a role the target server does not have: pg_restore reports errors (exit 1)
q -d src -c "GRANT SELECT ON res_partner TO temp_grantee"
"$PGB/pg_dump" -h 127.0.0.1 -p "$PORT" -U postgres --no-owner -Fc src > "$T/badgrant.custom"
q -d src -c "REVOKE SELECT ON res_partner FROM temp_grantee"
q -d postgres -c "DROP ROLE temp_grantee"
# Broken in the middle: a statement that fails after the first table
python3 - "$T/good.sql" "$T/broken.sql" <<'PY'
import sys
s = open(sys.argv[1]).read()
i = s.index("CREATE TABLE public.res_partner")
open(sys.argv[2], "w").write(s[:i] + "INSERT INTO public.table_that_does_not_exist VALUES (1);\n" + s[i:])
PY
head -c "$(( $(wc -c < "$T/good.sql") * 6 / 10 ))" "$T/good.sql" > "$T/truncated.sql"
python3 - "$T/good.sql" "$T/harmless.sql" <<'PY'
import sys
s = open(sys.argv[1]).read()
i = s.index("CREATE TABLE public.ir_module_module")
open(sys.argv[2], "w").write(s[:i] + "COMMENT ON EXTENSION plpgsql IS 'PL/pgSQL procedural language';\n" + s[i:])
PY
q -d postgres -c "CREATE DATABASE notodoo"
q -d notodoo -c "CREATE TABLE something (id int)"
"$PGB/pg_dump" -h 127.0.0.1 -p "$PORT" -U postgres --no-owner notodoo > "$T/notodoo.sql"

# --- Harness: the script's own functions --------------------------------------------------------
FUNCS=$(python3 - "$SCRIPT" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
out = []
for name in ("restoreOdooData", "recreate_database", "check_restore_errors", "run_psql", "run_pg_restore",
             "restoreSnapshotDataOnly", "extractForDataOnly", "check_bundled_directories_present",
             "list_bundled_git_repositories", "prepare_bundled_git_targets", "verify_bundled_git_repositories",
             "display_git_metadata_summary", "restore_git_repositories"):
    for i, line in enumerate(lines):
        if re.match(r"^(function\s+)?%s\s*\(\)\s*\{" % name, line):
            j = next(k for k in range(i, len(lines)) if lines[k].rstrip() == "}")
            out += lines[i:j + 1]
            break
    else:
        sys.exit("function %s not found" % name)
out += [l for l in lines if l.startswith("RESTORE_HARMLESS_ERRORS=")]
print("\n".join(out))
PY
) || { echo "Could not read the functions from $SCRIPT"; exit 1; }

run_script() {
  # run_script CASE ENTRY: runs one of the script's functions with the test deployment. Output in $T/x/CASE.out; sets RC.
  local case="$1" entry="$2"
  (
    set -e
    trap 'exit $?' ERR
    export PATH="$T/bin:$PATH"
    log_info() { echo "INFO $1"; }; log_success() { echo "OK $1"; }
    log_warn() { echo "WARN $1"; }; log_error() { echo "ERROR $1" >&2; }
    areYouReallySure() { :; }; isZstdInstalled() { :; }; isSnapshotFileExist() { :; }; trigger_registry_reload() { :; }
    eval "$FUNCS"
    PATH_TO_ODOO="$T/app" SERVICE_NAME=svc TEMP_DIR="$T/x/$case" ODOO_TMP_DIR="$T/tmpdir" TARGET_DB_NAME=restored
    TAR_PROJECT_ROOT="srv/deploy/svc" AUTO_CLONE_GIT=false REPOSITORY_OWNER="$(id -un)" OWNER_HOME="$T/home"
    SNAPSHOT_FILE_PATH="${ARCHIVE:-}"
    "$entry"
  ) > "$T/x/$case.out" 2>&1
  RC=$?
}

restore() {
  # restore CASE DUMP_FILE [DB_USER]: runs restoreOdooData on a snapshot holding only DUMP_FILE as dump.sql.
  local case="$1" dump="$2" user="${3:-odoo_t}"
  rm -rf "$T/x/$case"; mkdir -p "$T/x/$case"
  cp "$dump" "$T/x/$case/dump.sql"
  printf '%s' "$user" > "$T/app/.secrets/db_user"
  : > "$T/app/.env"
  run_script "$case" restoreOdooData
}
partners() { q -d restored -tA -c "SELECT count(*) FROM res_partner" 2>/dev/null; }
logs_kept() { ls "$T/tmpdir" | grep -c '^restore-restored-' ; }

# --- Cases ---------------------------------------------------------------------------------------
section "a good dump restores, and the old database is replaced"
q -d postgres -c "CREATE DATABASE restored"
q -d restored -c "CREATE TABLE stale_marker (id int)"
# A session left open on the database, as a running Odoo keeps in data-only mode
"$PGB/psql" -X -q -h 127.0.0.1 -p "$PORT" -U postgres -d restored -c "SELECT pg_sleep(120)" >/dev/null 2>&1 &
SESSION_PID=$!
for _ in $(seq 50); do
  [ "$(q -d postgres -tA -c "SELECT count(*) FROM pg_stat_activity WHERE datname = 'restored'")" -ge 1 ] && break; sleep 0.1
done
restore good "$T/good.sql"
check_eq "good dump: success" 0 "$RC"
check_grep "good dump: says so, with the installed module count" "$T/x/good.out" "restored successfully (2 installed modules)"
check_eq "good dump: all data is there" 500 "$(partners)"
check_eq "good dump: the old database is gone (stale table dropped)" "" "$(q -d restored -tA -c "SELECT to_regclass('stale_marker')")"
check_eq "good dump: the open session did not block the restore" 0 "$(q -d postgres -tA -c "SELECT count(*) FROM pg_stat_activity WHERE datname = 'restored' AND query LIKE '%pg_sleep%'")"
check_eq "good dump: objects belong to the deployment's database user" odoo_t "$(q -d restored -tA -c "SELECT tableowner FROM pg_tables WHERE tablename = 'res_partner'")"
check_eq "good dump: no log left behind when nothing went wrong" 0 "$(logs_kept)"
wait "$SESSION_PID" 2>/dev/null; SESSION_PID=""

section "a dump that breaks in the middle fails, with PostgreSQL's error"
restore broken "$T/broken.sql"
check_eq "broken dump: failure" 1 "$RC"
check_grep "broken dump: says the restore failed" "$T/x/broken.out" "Database restore failed"
check_grep "broken dump: shows PostgreSQL's own error" "$T/x/broken.out" 'relation "public.table_that_does_not_exist" does not exist'
check_grep "broken dump: points to the full log" "$T/x/broken.out" "Full log: $T/tmpdir/restore-restored-"
check_eq "broken dump: the log is kept" 1 "$(logs_kept)"
rm -f "$T"/tmpdir/restore-*

section "a dump cut short is refused before anything is touched"
restore good "$T/good.sql"
q -d restored -c "CREATE TABLE still_here (id int)"
restore truncated "$T/truncated.sql"
check_eq "truncated dump: failure" 1 "$RC"
check_grep "truncated dump: says the dump is incomplete" "$T/x/truncated.out" "is incomplete"
check_eq "truncated dump: the current database was not dropped" still_here "$(q -d restored -tA -c "SELECT to_regclass('still_here')")"
rm -f "$T"/tmpdir/restore-*

section "errors that are normal for a non-superuser only warn"
restore harmless "$T/harmless.sql"
check_eq "harmless error: success" 0 "$RC"
check_grep "harmless error: reported as a warning" "$T/x/harmless.out" "1 harmless restore error(s) ignored"
check_eq "harmless error: all data is there" 500 "$(partners)"
rm -f "$T"/tmpdir/restore-*

section "a dump without Odoo in it fails"
restore notodoo "$T/notodoo.sql"
check_eq "non-Odoo dump: failure" 1 "$RC"
check_grep "non-Odoo dump: says why" "$T/x/notodoo.out" "has no installed Odoo modules"
rm -f "$T"/tmpdir/restore-*

section "a database that cannot be created stops the restore"
restore norole "$T/good.sql" ghost_user
check_eq "missing owner role: failure" 1 "$RC"
check_grep "missing owner role: shows why" "$T/x/norole.out" 'Can'"'"'t create database restored: ERROR:  role "ghost_user" does not exist'
rm -f "$T"/tmpdir/restore-*

section "custom-format dumps (pg_restore)"
restore custom "$T/good.custom"
check_eq "custom dump: success" 0 "$RC"
check_eq "custom dump: all data is there" 500 "$(partners)"
restore badgrant "$T/badgrant.custom"
check_eq "custom dump with errors (pg_restore exit 1): failure, no longer reported as success" 1 "$RC"
check_grep "custom dump with errors: shows the error" "$T/x/badgrant.out" 'role "temp_grantee" does not exist'

# --- Data-only restore with bundled directories ------------------------------------------------
# A snapshot as the snapshot tool lays it out: core files and bundled directories at the top
SNAP="$T/snapsrc"
mkdir -p "$SNAP/git/plain_dir" "$SNAP/conf" "$SNAP/bigcustom" "$T/home"
cp "$T/good.sql" "$SNAP/dump.sql"
echo '{"odoo_dump": "1", "db_name": "restored", "version": "16.0", "version_info": [16, 0, 0, "final", 0, ""]}' > "$SNAP/manifest.json"
( export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null HOME="$T/home"
  mkdir -p "$SNAP/git/local_addon/data" "$SNAP/git/local_addon/filestore_tools"
  cd "$SNAP/git/local_addon" && git init -q -b main . \
    && echo "{'name': 'Local addon'}" > __manifest__.py \
    && echo "INSERT INTO x VALUES (1);" > data/init.sql \
    && echo "print('tools')" > filestore_tools/helper.py \
    && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -q -m "local work" ) || { echo "git setup failed"; exit 3; }
ADDON_COMMIT=$(git -C "$SNAP/git/local_addon" rev-parse HEAD)
echo "plain folder" > "$SNAP/git/plain_dir/readme.txt"
echo "SHOULD_NOT_BE_EXTRACTED=1" > "$SNAP/.env"
echo "[options]" > "$SNAP/conf/odoo.conf"
head -c 100000 /dev/urandom > "$SNAP/bigcustom/data.bin"
write_hashes() {
  # write_hashes EXTRA_BUNDLED_PATH...: git_hashes.json listing the two bundled directories (and any extra)
  python3 - "$SNAP/git_hashes.json" "$ADDON_COMMIT" "$@" <<'PY'
import json, sys
bundled = [{"name": "local_addon", "relative_path": "git/local_addon", "is_git": True, "commit": sys.argv[2],
            "bundled_reasons": ["no_remote"]},
           {"name": "plain_dir", "relative_path": "git/plain_dir", "is_git": False}]
bundled += [{"name": p.split("/")[-1], "relative_path": p, "is_git": False} for p in sys.argv[3:]]
json.dump({"git_repositories": [], "bundled_directories": bundled}, open(sys.argv[1], "w"))
PY
}
make_archive() {
  # make_archive OUT [abs]: tar.zst of $SNAP with relative names; "abs" adds the copy under the source's
  # absolute path that Secondary-VPS snapshots also hold
  local out="$1" names
  rm -rf "$T/abs"
  if [ "${2:-}" = abs ]; then mkdir -p "$T/abs/srv/deploy"; cp -a "$SNAP" "$T/abs/srv/deploy/svc"; fi
  ( cd "$SNAP" && tar -cf - $(ls -A) $( [ "${2:-}" = abs ] && echo "-C $T/abs srv" ) ) | zstd -q -c > "$out"
}
write_hashes
make_archive "$T/snap.tar.zst"
make_archive "$T/snap-abs.tar.zst" abs
write_hashes git/ghost_addon
make_archive "$T/snap-missing.tar.zst"
write_hashes

reset_deployment() {
  rm -rf "$T/app/git" "$T/app/.pre-restore-backups"
  mkdir -p "$T/app/git/local_addon"
  echo "old copy" > "$T/app/git/local_addon/OLD_FILE"
  printf 'odoo_t' > "$T/app/.secrets/db_user"; : > "$T/app/.env"
}

section "data-only: what is extracted"
ARCHIVE="$T/snap.tar.zst"
rm -rf "$T/x/extract"; mkdir -p "$T/x/extract"
run_script extract extractForDataOnly
check_eq "extraction: success" 0 "$RC"
check_eq "extraction: the bundled addon comes out whole (files the old name patterns half-matched)" "3" \
  "$(ls "$T/x/extract/git/local_addon/__manifest__.py" "$T/x/extract/git/local_addon/data/init.sql" "$T/x/extract/git/local_addon/filestore_tools/helper.py" 2>/dev/null | wc -l)"
check_eq "extraction: with its git history" "$ADDON_COMMIT" "$(git -C "$T/x/extract/git/local_addon" rev-parse HEAD 2>/dev/null)"
check_eq "extraction: the plain bundled folder too" "plain folder" "$(cat "$T/x/extract/git/plain_dir/readme.txt" 2>/dev/null)"
check_eq "extraction: dump, manifest and git metadata" 3 "$(ls "$T/x/extract/dump.sql" "$T/x/extract/manifest.json" "$T/x/extract/git_hashes.json" 2>/dev/null | wc -l)"
check_eq "extraction: configuration and custom folders are left out" 0 "$(ls -A "$T/x/extract" | grep -cE '^(\.env|conf|bigcustom)$')"

section "data-only: bundled directories are restored"
reset_deployment
ARCHIVE="$T/snap.tar.zst"
run_script dataonly restoreSnapshotDataOnly
check_eq "data-only: success" 0 "$RC"
check_eq "data-only: the database is restored" 500 "$(partners)"
check_eq "data-only: the bundled addon is restored whole" "3" \
  "$(ls "$T/app/git/local_addon/__manifest__.py" "$T/app/git/local_addon/data/init.sql" "$T/app/git/local_addon/filestore_tools/helper.py" 2>/dev/null | wc -l)"
check_grep "data-only: at the commit the snapshot recorded" "$T/x/dataonly.out" "Bundled repository git/local_addon restored at commit ${ADDON_COMMIT:0:8}"
check_eq "data-only: the old copy was moved aside, not merged in" "no|yes" \
  "$([ -e "$T/app/git/local_addon/OLD_FILE" ] && echo yes || echo no)|$(ls "$T"/app/.pre-restore-backups/*/git/local_addon/OLD_FILE >/dev/null 2>&1 && echo yes || echo no)"
check_eq "data-only: the plain bundled folder is restored" "plain folder" "$(cat "$T/app/git/plain_dir/readme.txt" 2>/dev/null)"
check_eq "data-only: .env is not touched" "" "$(cat "$T/app/.env")"

section "data-only: snapshots from the Secondary VPS (second copy under the absolute path)"
reset_deployment
ARCHIVE="$T/snap-abs.tar.zst"
run_script dataonly-abs restoreSnapshotDataOnly
check_eq "absolute-path layout: success" 0 "$RC"
check_eq "absolute-path layout: the bundled addon is restored" "$ADDON_COMMIT" "$(git -C "$T/app/git/local_addon" rev-parse HEAD 2>/dev/null)"

section "data-only: a snapshot missing a bundled directory is refused"
reset_deployment
q -d restored -c "CREATE TABLE untouched_marker (id int)"
ARCHIVE="$T/snap-missing.tar.zst"
run_script dataonly-missing restoreSnapshotDataOnly
check_eq "missing bundled directory: failure" 1 "$RC"
check_grep "missing bundled directory: names it" "$T/x/dataonly-missing.out" "not in the archive: git/ghost_addon"
check_eq "missing bundled directory: the database was not touched" untouched_marker "$(q -d restored -tA -c "SELECT to_regclass('untouched_marker')")"
check_eq "missing bundled directory: the deployment's git/ was not touched" "old copy" "$(cat "$T/app/git/local_addon/OLD_FILE" 2>/dev/null)"

echo
echo -e "Results: ${C_PASS}$passed passed${C_RESET}, ${C_FAIL}$failed failed${C_RESET}"
[ "$failed" -eq 0 ]
