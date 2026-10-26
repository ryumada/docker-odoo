#!/usr/bin/env bash
set -e
# Category: Configuration
# Description: Safely writes configuration files (.env, requirements.txt) as repository owner.
# Usage: ./scripts/save-config-file.sh <file_name> [b64_content]
# Dependencies: sudo, stat, base64

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$CURRENT_DIR/.." && pwd))
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

TARGET_FILE="$1"
B64_DATA="$2"

if [ -z "$TARGET_FILE" ]; then
    echo "Error: Target file name is required." >&2
    exit 1
fi

# Security: prevent path traversal; restrict to allowed config files within PATH_TO_ODOO
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

# Write content (from argument or stdin)
TEMP_FILE=$(mktemp)
if [ -n "$B64_DATA" ]; then
    echo "$B64_DATA" | base64 -d > "$TEMP_FILE"
else
    cat > "$TEMP_FILE"
fi

# Move file into place and set ownership and permissions
if [ -n "$REPOSITORY_OWNER" ] && [ "$REPOSITORY_OWNER" != "$(whoami)" ]; then
    sudo -H -u "$REPOSITORY_OWNER" cp "$TEMP_FILE" "$FULL_PATH"
    sudo -H -u "$REPOSITORY_OWNER" chmod 644 "$FULL_PATH"
else
    cp "$TEMP_FILE" "$FULL_PATH"
    chmod 644 "$FULL_PATH"
fi
rm -f "$TEMP_FILE"

echo "Successfully saved $TARGET_FILE"
