#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Initializes deployment directory under /opt with correct permissions
# Usage: ./scripts/create-deployment-dir.sh <directory_path> <owner>
# Dependencies: mkdir, chown

TARGET_DIR="$1"
TARGET_OWNER="$2"

if [ -z "$TARGET_DIR" ] || [ -z "$TARGET_OWNER" ]; then
    echo "Usage: $0 <directory_path> <owner>" >&2
    exit 1
fi

# Security: Restrict strictly to /opt/* (no directory traversal)
case "$TARGET_DIR" in
    /opt/[a-zA-Z0-9_-]*)
        ;;
    *)
        echo "Error: Directory '$TARGET_DIR' must be located directly under /opt/ and use valid characters." >&2
        exit 1
        ;;
esac

if ! id "$TARGET_OWNER" &>/dev/null; then
    echo "Error: User '$TARGET_OWNER' does not exist." >&2
    exit 1
fi

mkdir -p "$TARGET_DIR"
chown "$TARGET_OWNER":"$TARGET_OWNER" "$TARGET_DIR"
chmod 755 "$TARGET_DIR"
echo "Successfully initialized deployment directory: $TARGET_DIR (owner: $TARGET_OWNER)"
