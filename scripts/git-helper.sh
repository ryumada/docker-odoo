#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Safely performs git operations (branches, fetch, info, clone) within the deployment as repository owner.
# Usage: ./scripts/git-helper.sh <action> [args...]
# Dependencies: git, sudo, bash

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$CURRENT_DIR/.." && pwd))
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

ACTION="$1"
shift || true

if [ -n "$REPOSITORY_OWNER" ] && [ "$REPOSITORY_OWNER" != "$(whoami)" ]; then
    GIT_RUN=(sudo -H -u "$REPOSITORY_OWNER" git)
else
    GIT_RUN=(git)
fi

require_git_repo() {
    local repo_path="$1"
    [[ -n "$repo_path" && -d "$repo_path" ]] || { echo "Directory not found: $repo_path" >&2; exit 1; }
    [[ -d "$repo_path/.git" || -f "$repo_path/.git" ]] || { echo "Not a git repository (missing .git): $repo_path" >&2; exit 1; }
}

case "$ACTION" in
    branches)
        REPO_PATH="$1"
        require_git_repo "$REPO_PATH"
        "${GIT_RUN[@]}" -C "$REPO_PATH" branch -a
        ;;

    fetch)
        REPO_PATH="$1"
        require_git_repo "$REPO_PATH"
        "${GIT_RUN[@]}" -C "$REPO_PATH" fetch --prune
        ;;

    info)
        REPO_PATH="$1"
        require_git_repo "$REPO_PATH"
        URL=$("${GIT_RUN[@]}" -C "$REPO_PATH" config --get remote.origin.url 2>/dev/null || true)
        BRANCH=$("${GIT_RUN[@]}" -C "$REPO_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
        echo "URL: $URL"
        echo "BRANCH: $BRANCH"
        ;;

    clone)
        URL="$1"
        BRANCH="$2"
        TARGET_PATH="$3"
        if [ -d "$TARGET_PATH" ]; then
            echo "Directory already exists: $TARGET_PATH"
            exit 0
        fi
        "${GIT_RUN[@]}" clone -q --depth 1 -b "$BRANCH" "$URL" "$TARGET_PATH"
        ;;

    status)
        REPO_PATH="$1"
        require_git_repo "$REPO_PATH"
        "${GIT_RUN[@]}" -c safe.directory='*' -C "$REPO_PATH" status --porcelain
        ;;

    restore)
        REPO_PATH="$1"
        require_git_repo "$REPO_PATH"
        "${GIT_RUN[@]}" -c safe.directory='*' -C "$REPO_PATH" diff --name-only
        "${GIT_RUN[@]}" -c safe.directory='*' -C "$REPO_PATH" diff --cached --name-only
        "${GIT_RUN[@]}" -c safe.directory='*' -C "$REPO_PATH" restore --worktree --staged . 2>/dev/null \
            || "${GIT_RUN[@]}" -c safe.directory='*' -C "$REPO_PATH" restore . 2>/dev/null \
            || "${GIT_RUN[@]}" -c safe.directory='*' -C "$REPO_PATH" checkout -- .
        ;;

    *)
        echo "Usage: $0 {branches <path>|fetch <path>|info <path>|clone <url> <branch> <path>|status <path>|restore <path>}" >&2
        exit 1
        ;;
esac
