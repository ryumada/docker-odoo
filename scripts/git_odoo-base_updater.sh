#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Updates Odoo base git repositories and restarts containers.
# Usage: ./scripts/git_odoo-base_updater.sh
# Dependencies: git, docker, sudo

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

# Configuration
ENV_FILE=".env"
UPDATE_SCRIPT="./scripts/update-env-file.sh"
MAX_BACKUPS=3

# --- Logging Functions & Colors ---
# Define colors for log messages
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[0;31m"

# Function to log messages with a specific color and emoji
log() {
  local color="$1"
  local emoji="$2"
  local message="$3"
  echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}"
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_warn() { log "${COLOR_WARN}" "⚠️" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }
# ------------------------------------

error_handler() {
  local exit_code=$1
  local line_no=$2
  local command_name=$3
  log_error "An error occurred on line $line_no."
  log_error "Exit Code: $exit_code"
  log_error "Command: $command_name"
  log_error "Note: The specific error message should be printed in the lines above this error."
  exit "$exit_code"
}

trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR

DOCKER_COMPOSE_FILE="docker-compose.yml"
GIT_PATH="./odoo-base"

function isDirectoryGitRepository() {
  dir=$1

  if [ -d "$dir/.git" ]; then
    if sudo -u "$REPOSITORY_OWNER" git -C "$dir" rev-parse --is-inside-work-tree &>/dev/null; then
      return 0
    else
      return 1
    fi
  else
    return 1
  fi
}

function getSubDirectories() {
  dir=$1
  subdirs="$(ls -d "$dir"/*/)"
  echo "$subdirs"
}



function process_repo() {
    local subdir=$1
    local repo_name
    repo_name=$(basename "$subdir")
    local repo_updated=1 # false

    if isDirectoryGitRepository "$subdir"; then
        local current_branch
        current_branch=$(sudo -u "$REPOSITORY_OWNER" git -C "$subdir" branch --show-current 2>/dev/null || true)
        if [ -z "$current_branch" ]; then
            current_branch="HEAD"
        fi

        log_info "Attempting to update $repo_name (Branch: $current_branch)..."

        local old_commit
        old_commit=$(sudo -u "$REPOSITORY_OWNER" git -C "$subdir" rev-parse "$current_branch" 2>/dev/null || true)

        log_info "Fetching $repo_name..."
        local fetch_output=""
        local fetch_exit_code=0
        fetch_output=$(sudo -u "$REPOSITORY_OWNER" git -C "$subdir" fetch --prune --tags -q 2>&1) || fetch_exit_code=$?

        if [ $fetch_exit_code -ne 0 ]; then
            if echo "$fetch_output" | grep -q "fatal: cannot lock ref"; then
                local conflicting_branch
                conflicting_branch=$(echo "$fetch_output" | sed -n "s/.*fatal: cannot lock ref '[^']*': '\([^']*\)' exists.*/\1/p" | head -n 1)
                log_warn "Detected git ref conflict in $repo_name: ${conflicting_branch:-$current_branch}"
                log_info "Switching branch and deleting conflicting ref..."
                if [ "$current_branch" != "main" ] && sudo -u "$REPOSITORY_OWNER" git -C "$subdir" checkout main -q 2>/dev/null; then
                    :
                elif [ "$current_branch" != "master" ] && sudo -u "$REPOSITORY_OWNER" git -C "$subdir" checkout master -q 2>/dev/null; then
                    :
                else
                    sudo -u "$REPOSITORY_OWNER" git -C "$subdir" checkout --detach -q 2>/dev/null || true
                fi
                if [ -n "$conflicting_branch" ]; then
                    sudo -u "$REPOSITORY_OWNER" git -C "$subdir" branch -D "$conflicting_branch" 2>/dev/null || true
                fi
                sudo -u "$REPOSITORY_OWNER" git -C "$subdir" branch -D "$current_branch" 2>/dev/null || true
                if sudo -u "$REPOSITORY_OWNER" git -C "$subdir" fetch --prune --tags -q 2>/dev/null; then
                    log_info "Ref conflict resolved for $repo_name."
                    sudo -u "$REPOSITORY_OWNER" git -C "$subdir" checkout "$current_branch" -q 2>/dev/null || true
                    fetch_exit_code=0
                fi
            fi
        fi

        if [ $fetch_exit_code -ne 0 ]; then
            log_warn "Failed to fetch $repo_name"
        elif ! sudo -u "$REPOSITORY_OWNER" git -C "$subdir" symbolic-ref -q HEAD >/dev/null; then
            log_info "Skipping pull for $repo_name: HEAD is detached (on a tag or commit)."
        else
            log_info "Pulling updates for $repo_name..."
            local pull_output=""
            local pull_exit_code=0
            pull_output=$(sudo -u "$REPOSITORY_OWNER" git -C "$subdir" pull -q 2>&1) || pull_exit_code=$?
            if [ $pull_exit_code -ne 0 ]; then
                log_warn "Pull failed for $repo_name ($current_branch). Attempting auto-recovery for divergent branch/conflict..."
                sudo -u "$REPOSITORY_OWNER" git -C "$subdir" merge --abort 2>/dev/null || true
                sudo -u "$REPOSITORY_OWNER" git -C "$subdir" reset --hard 2>/dev/null || true

                if [ "$current_branch" != "main" ] && sudo -u "$REPOSITORY_OWNER" git -C "$subdir" checkout main -q 2>/dev/null; then
                    :
                elif [ "$current_branch" != "master" ] && sudo -u "$REPOSITORY_OWNER" git -C "$subdir" checkout master -q 2>/dev/null; then
                    :
                else
                    sudo -u "$REPOSITORY_OWNER" git -C "$subdir" checkout --detach -q 2>/dev/null || true
                fi

                sudo -u "$REPOSITORY_OWNER" git -C "$subdir" branch -D "$current_branch" 2>/dev/null || true
                sudo -u "$REPOSITORY_OWNER" git -C "$subdir" fetch --prune --tags -q 2>/dev/null || true

                if sudo -u "$REPOSITORY_OWNER" git -C "$subdir" checkout "$current_branch" -q 2>/dev/null; then
                    sudo -u "$REPOSITORY_OWNER" git -C "$subdir" pull -q 2>/dev/null || true
                    local recovered_commit
                    recovered_commit=$(sudo -u "$REPOSITORY_OWNER" git -C "$subdir" rev-parse "$current_branch" 2>/dev/null || true)
                    if [ -n "$old_commit" ] && [ -n "$recovered_commit" ] && [ "$old_commit" != "$recovered_commit" ]; then
                        log_success "Updated $repo_name successfully after auto-recovery."
                        repo_updated=0 # true
                    else
                        log_success "$repo_name recovered and is up to date."
                    fi
                else
                    log_warn "Failed to pull $repo_name even after auto-recovery"
                fi
            else
                local new_commit
                new_commit=$(sudo -u "$REPOSITORY_OWNER" git -C "$subdir" rev-parse "$current_branch" 2>/dev/null || true)

                if [ -n "$old_commit" ] && [ -n "$new_commit" ] && [ "$old_commit" != "$new_commit" ]; then
                    log_success "Updated $repo_name successfully."
                    repo_updated=0 # true
                else
                    log_info "$repo_name is already up to date."
                fi
            fi
        fi
    else
        log_error "$subdir is not a git repository."
        log_error "Please make sure you have added $subdir directory to your snapshot script to backup the addons manually."
    fi

    return $repo_updated
}

function main() {
  # Self-elevate to root if not already
  if [ "$(id -u)" -ne 0 ]; then
      log_info "Elevating permissions to root..."
      # shellcheck disable=SC2093
      exec sudo "$0" "$@" # Re-run the script with sudo
      log_error "Failed to elevate to root. Please run with sudo." # This will only run if exec fails
      exit 1
  fi

  log_info "Change Directory to $PATH_TO_ODOO"
  if ! cd "$PATH_TO_ODOO"; then
    log_error "Can't change directory to $PATH_TO_ODOO"
    exit 1
  fi

  log_info "Start checking git repositories"
  GIT_SUBDIRS=$(getSubDirectories "$GIT_PATH")

  if wc -l <<< "$GIT_SUBDIRS" | grep -q "0"; then
    log_error "No git repositories found in $GIT_PATH"
    exit 1
  fi

  if ! wc -l <<< "$GIT_SUBDIRS" | grep -q "1"; then
    log_warn "Please make sure there is only one git repository in $GIT_PATH"
    exit 1
  fi

  pulledrepositories=0
  for subdir in $GIT_SUBDIRS; do
    if process_repo "$subdir"; then
      pulledrepositories=$((pulledrepositories+1))
    fi
  done

  if [ $pulledrepositories -gt 0 ]; then
    # log_info "Rebuilding the docker containers"
    # sudo -u "$REPOSITORY_OWNER" docker compose -f "$PATH_TO_ODOO/$DOCKER_COMPOSE_FILE" up -d --build
    log_info "Restarting the docker containers"
    sudo -u "$REPOSITORY_OWNER" docker compose -f "$PATH_TO_ODOO/$DOCKER_COMPOSE_FILE" restart

    log_info "Cleaning Unused Docker caches..."
    sudo -u "$REPOSITORY_OWNER" docker container prune -f; sudo -u "$REPOSITORY_OWNER" docker image prune -f; sudo -u "$REPOSITORY_OWNER" docker system prune -f; sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches
  else
    log_success "No updates found"
  fi

  log_success "Finish checking updates for $SERVICE_NAME"
}

main "$@"
