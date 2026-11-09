#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Monitors the disk free space and calculates the size of Odoo database and filestore.
# Usage: ./scripts/disk_free_monitor.sh [DB_NAME]   (ODOO_FILESTORE_ROOT overrides /var/lib/odoo)
# Dependencies: sudo, psql (local database) or docker (database on another host), find, df, git, python3
#
# Sizes come from scripts/lib/odoo_sizes.sh, shared with the snapshot tool, so a database on another
# host (DB_HOST in .env) is measured too. A size that cannot be measured shows as "unknown", never 0.

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
PATH_TO_ODOO=$(sudo -u "$(stat -c '%U' "$CURRENT_DIR")" git -C "$CURRENT_DIR" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")

# --- Logging Functions & Colors ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_ERROR="\033[0;31m"

log() {
  local color="$1"
  local emoji="$2"
  local message="$3"
  echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}"
}
log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }
log_warn() { log "\033[0;33m" "⚠️" "$1"; }

if [ -f "$CURRENT_DIR/lib/odoo_sizes.sh" ]; then
  # shellcheck source=/dev/null
  source "$CURRENT_DIR/lib/odoo_sizes.sh"
else
  log_error "scripts/lib/odoo_sizes.sh not found. Update docker-odoo (git pull)."
  exit 1
fi
ENV_FILE="$PATH_TO_ODOO/.env"
FILESTORE_ROOT="${ODOO_FILESTORE_ROOT:-/var/lib/odoo}/$SERVICE_NAME/filestore"

# Self-elevate to root if not already
if [ "$(id -u)" -ne 0 ]; then
    log_info "Elevating permissions to root..."
    exec sudo "$0" "$@"
    log_error "Failed to elevate to root. Please run with sudo."
    exit 1
fi

DB_USER=$(grep "^ACTIVE_DB_USER=" "$PATH_TO_ODOO/.env" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
if [ -z "$DB_USER" ]; then
    DB_USER_FILE="$PATH_TO_ODOO/.secrets/db_user"
    if [ ! -f "$DB_USER_FILE" ]; then
        log_error "Database user secret file not found at $DB_USER_FILE"
        exit 1
    fi
    DB_USER=$(cat "$DB_USER_FILE" | tr -d '[:space:]')
fi

TARGET_DB="$1"
if [ -z "$TARGET_DB" ]; then
    log_info "No database name provided. Fetching all databases for user '$DB_USER'..."
    # The query goes through stdin so psql quotes the user name itself (:'owner'); -c does not substitute
    DB_LIST=$(echo "SELECT datname FROM pg_database WHERE datdba = (SELECT usesysid FROM pg_user WHERE usename = :'owner') ORDER BY datname" \
      | odoo_sizes_psql "$ENV_FILE" -X -q -tA -d postgres -v owner="$DB_USER" 2>/dev/null || true)
    if [ -z "$DB_LIST" ]; then
        log_error "No databases found for user '$DB_USER'."
        exit 1
    fi
else
    DB_LIST="$TARGET_DB"
fi

echo "--------------------------------------------------------"
echo -e "\033[1;36mOdoo Database and Filestore Sizes\033[0m"
echo -e "Service: $SERVICE_NAME"
echo "--------------------------------------------------------"

TOTAL_DB_SIZE=0
TOTAL_FILESTORE=0
UNKNOWN=0

readable() {
  # Args: bytes or empty. Prints a human size, or "unknown".
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    numfmt --to=iec-i --suffix=B --format="%9.2f" "$1" 2>/dev/null || echo "$1 B"
  else
    echo "  unknown"
  fi
}

for DB_NAME in $DB_LIST; do
    SIZES=$(odoo_sizes_json "$ENV_FILE" "$DB_NAME" "$FILESTORE_ROOT/$DB_NAME")
    read -r DB_BYTES FILESTORE_BYTES FILESTORE_FILES ATTACHMENTS < <(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
v = lambda x: "" if x is None else str(x)
print(v(d["postgres"]["db_size_bytes"]) or "-", v(d["filestore"]["bytes"]) or "-",
      v(d["filestore"]["files"]) or "-", v(d["attachments"]["stored"]) or "-")' "$SIZES")
    [ "$DB_BYTES" = "-" ] && DB_BYTES=""
    [ "$FILESTORE_BYTES" = "-" ] && FILESTORE_BYTES=""

    if [ -n "$DB_BYTES" ]; then TOTAL_DB_SIZE=$((TOTAL_DB_SIZE + DB_BYTES)); else UNKNOWN=$((UNKNOWN + 1)); fi
    if [ -n "$FILESTORE_BYTES" ]; then TOTAL_FILESTORE=$((TOTAL_FILESTORE + FILESTORE_BYTES)); else UNKNOWN=$((UNKNOWN + 1)); fi

    echo -e "Database: \033[1;32m$DB_NAME\033[0m"
    echo "  - PostgreSQL Size : $(readable "$DB_BYTES")"
    echo "  - Filestore Size  : $(readable "$FILESTORE_BYTES") (${FILESTORE_FILES/-/unknown} files, ${ATTACHMENTS/-/unknown} stored attachments)"
    echo ""
done

TOTAL_COMBINED=$((TOTAL_DB_SIZE + TOTAL_FILESTORE))
TOTAL_DB_READABLE=$(numfmt --to=iec-i --suffix=B --format="%.2f" "$TOTAL_DB_SIZE" 2>/dev/null || echo "$TOTAL_DB_SIZE B")
TOTAL_FS_READABLE=$(numfmt --to=iec-i --suffix=B --format="%.2f" "$TOTAL_FILESTORE" 2>/dev/null || echo "$TOTAL_FILESTORE B")
TOTAL_ALL_READABLE=$(numfmt --to=iec-i --suffix=B --format="%.2f" "$TOTAL_COMBINED" 2>/dev/null || echo "$TOTAL_COMBINED B")

echo "--------------------------------------------------------"
echo "Summary"
echo "--------------------------------------------------------"
[ "$UNKNOWN" -gt 0 ] && log_warn "$UNKNOWN size(s) could not be measured: the totals below leave them out."
echo "Total PostgreSQL : $TOTAL_DB_READABLE"
echo "Total Filestore  : $TOTAL_FS_READABLE"
echo -e "Total Combined   : \033[1;33m$TOTAL_ALL_READABLE\033[0m"
echo "--------------------------------------------------------"
echo ""

echo -e "\033[1;36mRoot Filesystem Disk Space (df -h /)\033[0m"
echo "--------------------------------------------------------"
df -h /
echo "--------------------------------------------------------"

log_success "Disk space report completed successfully."
