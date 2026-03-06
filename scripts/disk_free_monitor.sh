#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Monitors the disk free space and calculates the size of Odoo database and filestore.
# Usage: ./scripts/disk_free_monitor.sh [DB_NAME]
# Dependencies: sudo, psql, du, df, git

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

# Self-elevate to root if not already
if [ "$(id -u)" -ne 0 ]; then
    log_info "Elevating permissions to root..."
    exec sudo "$0" "$@"
    log_error "Failed to elevate to root. Please run with sudo."
    exit 1
fi

DB_USER_FILE="$PATH_TO_ODOO/.secrets/db_user"
if [ ! -f "$DB_USER_FILE" ]; then
    log_error "Database user secret file not found at $DB_USER_FILE"
    exit 1
fi
DB_USER=$(cat "$DB_USER_FILE" | tr -d '[:space:]')

TARGET_DB="$1"
if [ -z "$TARGET_DB" ]; then
    log_info "No database name provided. Fetching all databases for user '$DB_USER'..."
    DB_LIST=$(sudo -u postgres psql -tAc "SELECT datname FROM pg_database WHERE datdba = (SELECT usesysid FROM pg_user WHERE usename = '$DB_USER');")
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

for DB_NAME in $DB_LIST; do
    # Calculate DB size via PostgreSQL
    DB_BYTES=$(sudo -u postgres psql -tAc "SELECT pg_database_size('$DB_NAME');" 2>/dev/null || echo 0)
    
    # Calculate Filestore size via du
    FILESTORE_PATH="/var/lib/odoo/$SERVICE_NAME/filestore/$DB_NAME"
    FILESTORE_BYTES=0
    if [ -d "$FILESTORE_PATH" ]; then
        FILESTORE_BYTES=$(sudo du -sb "$FILESTORE_PATH" | cut -f1)
    fi

    TOTAL_DB_SIZE=$((TOTAL_DB_SIZE + DB_BYTES))
    TOTAL_FILESTORE=$((TOTAL_FILESTORE + FILESTORE_BYTES))

    DB_READABLE=$(numfmt --to=iec-i --suffix=B --format="%9.2f" "$DB_BYTES" 2>/dev/null || echo "$DB_BYTES B")
    FS_READABLE=$(numfmt --to=iec-i --suffix=B --format="%9.2f" "$FILESTORE_BYTES" 2>/dev/null || echo "$FILESTORE_BYTES B")
    
    echo -e "Database: \033[1;32m$DB_NAME\033[0m"
    echo "  - PostgreSQL Size : $DB_READABLE"
    echo "  - Filestore Size  : $FS_READABLE"
    echo ""
done

TOTAL_COMBINED=$((TOTAL_DB_SIZE + TOTAL_FILESTORE))
TOTAL_DB_READABLE=$(numfmt --to=iec-i --suffix=B --format="%.2f" "$TOTAL_DB_SIZE" 2>/dev/null || echo "$TOTAL_DB_SIZE B")
TOTAL_FS_READABLE=$(numfmt --to=iec-i --suffix=B --format="%.2f" "$TOTAL_FILESTORE" 2>/dev/null || echo "$TOTAL_FILESTORE B")
TOTAL_ALL_READABLE=$(numfmt --to=iec-i --suffix=B --format="%.2f" "$TOTAL_COMBINED" 2>/dev/null || echo "$TOTAL_COMBINED B")

echo "--------------------------------------------------------"
echo "Summary"
echo "--------------------------------------------------------"
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
