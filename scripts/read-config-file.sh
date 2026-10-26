#!/usr/bin/env bash
set -e
# Category: Configuration
# Description: Safely reads configuration files (.env, requirements.txt) as repository owner.
# Usage: ./scripts/read-config-file.sh <file_name>
# Dependencies: sudo, stat, cat

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$CURRENT_DIR/.." && pwd))
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

TARGET_FILE="$1"
if [ -z "$TARGET_FILE" ]; then
    echo "Error: Target file name is required." >&2
    exit 1
fi

CLEAN_NAME=$(basename "$TARGET_FILE")
case "$CLEAN_NAME" in
    .env|.env.*|requirements.txt|odoo.conf)
        ;;
    *)
        echo "Error: Forbidden file name '$CLEAN_NAME'. Only config files (.env, requirements.txt, odoo.conf) are allowed." >&2
        exit 1
        ;;
esac

FULL_PATH="$PATH_TO_ODOO/$TARGET_FILE"

if [ ! -f "$FULL_PATH" ]; then
    exit 0
fi

if [ -n "$REPOSITORY_OWNER" ] && [ "$REPOSITORY_OWNER" != "$(whoami)" ]; then
    sudo -H -u "$REPOSITORY_OWNER" cat "$FULL_PATH"
else
    cat "$FULL_PATH"
fi
