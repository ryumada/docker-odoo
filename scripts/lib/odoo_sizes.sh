#!/usr/bin/env bash
# Category: Library
# Description: Measures a deployment's database and filestore (PostgreSQL version, database size, stored
#              attachments, filestore bytes and files) for manifest.json and disk_free_monitor.sh.
# Usage: source scripts/lib/odoo_sizes.sh
#          odoo_sizes_psql ENV_FILE psql-args...        psql against the deployment's PostgreSQL
#          odoo_sizes_json ENV_FILE DB_NAME FILESTORE_DIR one line of JSON: the manifest's "sudodevops" block
# Dependencies: psql (local PostgreSQL via sudo -u postgres) or docker (database on another host), find, awk, date
#
# Connection rules are the snapshot tool's: DB_HOST in .env other than localhost means a database on
# another host, reached with the postgres image through the Docker client (the password goes through
# the environment, never the command line); otherwise the local server as the postgres user.
# Anything that cannot be measured is null, never 0: a 0 looks like a real size and nothing flags it.

_odoo_sizes_env() {
  # Args: env_file key. Prints the value without quotes or trailing comment.
  grep "^$2=" "$1" 2>/dev/null | head -n 1 | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true
}

odoo_sizes_psql() {
  # Args: env_file psql-args...
  local env_file="$1" db_host db_port db_user db_pass net
  shift
  db_host=$(_odoo_sizes_env "$env_file" DB_HOST)
  if [ -n "$db_host" ] && [ "$db_host" != "localhost" ]; then
    db_port=$(_odoo_sizes_env "$env_file" DB_PORT)
    db_user=$(_odoo_sizes_env "$env_file" ACTIVE_DB_USER)
    # Read as the snapshot tool's run_pg_dump reads them: only the trailing newline is dropped
    [ -z "$db_user" ] && db_user=$(cat "$(dirname "$env_file")/.secrets/db_user" 2>/dev/null || true)
    db_pass=$(cat "$(dirname "$env_file")/.secrets/db_password" 2>/dev/null || true)
    net=$(_odoo_sizes_env "$env_file" DOCKER_NETWORK_MODE)
    net="${net%%,*}"
    PGPASSWORD="$db_pass" docker run -i --rm --network="${net:-host}" -e PGPASSWORD postgres \
      psql -h "$db_host" -p "${db_port:-5432}" -U "$db_user" "$@"
  else
    sudo -u postgres psql "$@"
  fi
}

odoo_sizes_json() {
  # Args: env_file database filestore_dir. Never fails; prints e.g.
  # {"postgres": {"server_version": "16.4", "db_size_bytes": 123}, "attachments": {"stored": 9},
  #  "filestore": {"bytes": 456, "files": 9}, "measured_at": "2026-11-09T03:00:00Z"}
  local env_file="$1" db="$2" fs_dir="$3" out line1 line2 version="" db_bytes="" stored="" fs_bytes="" fs_files="" fs
  # One session, two statements: the attachment count may fail on a database without Odoo,
  # the version and size must still come back
  out=$(odoo_sizes_psql "$env_file" -X -q -tA -F '|' -d "$db" \
          -c "SELECT current_setting('server_version'), pg_database_size(current_database())" \
          -c "SELECT count(*) FROM ir_attachment WHERE store_fname IS NOT NULL" 2>/dev/null || true)
  line1=$(printf '%s\n' "$out" | sed -n 1p)
  line2=$(printf '%s\n' "$out" | sed -n 2p)
  version=$(printf '%s' "${line1%%|*}" | grep -oE '^[0-9]+(\.[0-9]+)*' || true)
  db_bytes="${line1##*|}"; [[ "$db_bytes" =~ ^[0-9]+$ ]] && [ "$line1" != "$db_bytes" ] || db_bytes=""
  [[ "$line2" =~ ^[0-9]+$ ]] && stored="$line2"

  if [ ! -e "$fs_dir" ]; then
    fs_bytes=0; fs_files=0   # Odoo creates the folder on the first stored attachment
  # An unreadable folder or file makes find fail: then the size is unknown, not the part it could read
  elif fs=$(set -o pipefail; find "$fs_dir" -type f -printf '%s\n' 2>/dev/null | awk '{s += $1; n++} END {printf "%d %d", s, n}'); then
    fs_bytes="${fs% *}"; fs_files="${fs#* }"
  fi

  printf '{"postgres": {"server_version": %s, "db_size_bytes": %s}, "attachments": {"stored": %s}, "filestore": {"bytes": %s, "files": %s}, "measured_at": "%s"}\n' \
    "$( [ -n "$version" ] && printf '"%s"' "$version" || echo null )" "${db_bytes:-null}" "${stored:-null}" \
    "${fs_bytes:-null}" "${fs_files:-null}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
