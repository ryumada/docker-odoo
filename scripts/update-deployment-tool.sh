#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Updates the docker-odoo repository via git fetch and pull as repository owner. Supports JSON output.
# Usage: ./scripts/update-deployment-tool.sh [branch] [json]
# Dependencies: git, sudo, bash

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$CURRENT_DIR/.." && pwd))
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

# Parse arguments
TARGET_BRANCH=""
JSON_MODE="false"

for arg in "$@"; do
    if [ "$arg" = "json" ] || [ "$arg" = "--json" ]; then
        JSON_MODE="true"
    elif [ -z "$TARGET_BRANCH" ]; then
        TARGET_BRANCH="$arg"
    fi
done

# Setup git runner command
if [ -n "$REPOSITORY_OWNER" ] && [ "$REPOSITORY_OWNER" != "$(whoami)" ]; then
    GIT_CMD=(sudo -H -u "$REPOSITORY_OWNER" git -C "$PATH_TO_ODOO")
else
    GIT_CMD=(git -C "$PATH_TO_ODOO")
fi

# Detect current branch if not provided
if [ -z "$TARGET_BRANCH" ]; then
    TARGET_BRANCH=$("${GIT_CMD[@]}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
fi

# Logging functions
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_ERROR="\033[0;31m"

log() {
    local color="$1"
    local emoji="$2"
    local message="$3"
    if [ "$JSON_MODE" = "true" ]; then
        echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}" >&2
    else
        echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}"
    fi
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }

OLD_COMMIT=$("${GIT_CMD[@]}" rev-parse HEAD 2>/dev/null || echo "unknown")

log_info "Fetching latest updates for branch '$TARGET_BRANCH' as '$REPOSITORY_OWNER'..."
FETCH_OUTPUT=$("${GIT_CMD[@]}" fetch origin "$TARGET_BRANCH" 2>&1) || {
    FETCH_ERR=$?
    log_error "Git fetch failed for branch '$TARGET_BRANCH': $FETCH_OUTPUT"
    if [ "$JSON_MODE" = "true" ]; then
        echo "{\"status\": \"error\", \"stage\": \"fetch\", \"error\": \"$FETCH_OUTPUT\"}"
    fi
    exit $FETCH_ERR
}

log_info "Pulling changes for branch '$TARGET_BRANCH'..."
PULL_OUTPUT=$("${GIT_CMD[@]}" pull origin "$TARGET_BRANCH" 2>&1) || {
    PULL_ERR=$?
    log_error "Git pull failed for branch '$TARGET_BRANCH': $PULL_OUTPUT"
    if [ "$JSON_MODE" = "true" ]; then
        echo "{\"status\": \"error\", \"stage\": \"pull\", \"error\": \"$PULL_OUTPUT\"}"
    fi
    exit $PULL_ERR
}

NEW_COMMIT=$("${GIT_CMD[@]}" rev-parse HEAD 2>/dev/null || echo "unknown")

if [ "$OLD_COMMIT" = "$NEW_COMMIT" ]; then
    log_success "Deployment tool is already up-to-date at commit $NEW_COMMIT."
else
    log_success "Deployment tool successfully updated: $OLD_COMMIT -> $NEW_COMMIT"
fi

if [ "$JSON_MODE" = "true" ]; then
    echo "{\"status\": \"success\", \"branch\": \"$TARGET_BRANCH\", \"old_commit\": \"$OLD_COMMIT\", \"new_commit\": \"$NEW_COMMIT\", \"output\": \"$PULL_OUTPUT\"}"
else
    echo "$PULL_OUTPUT"
fi
