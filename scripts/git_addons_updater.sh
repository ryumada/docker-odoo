#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Updates git repositories in the ./git directory and restarts Docker containers if changes are pulled. Supports JSON output.
# Usage: ./scripts/git_addons_updater.sh [json]
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

# Global JSON Mode flag (Defaults to false)
JSON_MODE="false"

# Function to log messages with a specific color and emoji
log() {
  local color="$1"
  local emoji="$2"
  local message="$3"
  # If in JSON mode, redirect all logs to stderr to keep stdout clean for JSON
  if [ "$JSON_MODE" = "true" ]; then
      echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}" >&2
  else
      echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}"
  fi
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_warn() { log "${COLOR_WARN}" "⚠️" "$1"; }
log_error() {
  if [ "$JSON_MODE" = "true" ]; then
      echo "{\"error\": \"$1\"}"
  fi
  log "${COLOR_ERROR}" "❌" "$1"
}
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
GIT_PATH="./git"

function isDirectoryGitRepository() {
  local dir=$1

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
  local dir=$1
  subdirs="$(ls -d "$dir"/*/)"
  echo "$subdirs"
}

function process_repo() {
    local subdir=$1
    local repo_name
    repo_name=$(basename "$subdir")
    local status="clean"
    local changed_files=""
    local ret_updated=0

    if isDirectoryGitRepository "$subdir"; then
        log_info "Fetching $repo_name..."
        # Fetch updates silently
        if ! sudo -u "$REPOSITORY_OWNER" git -C "$subdir" fetch -q 2>/dev/null; then
             log_warn "Failed to fetch $repo_name"
             status="fetch_failed"
        else
             # Check for changes
             # @{u} refers to upstream
             changed_files=$(sudo -u "$REPOSITORY_OWNER" git -C "$subdir" diff --name-only HEAD..@{u} 2>/dev/null)

             if [ -n "$changed_files" ]; then
                 log_info "Pulling updates for $repo_name..."
                 if sudo -u "$REPOSITORY_OWNER" git -C "$subdir" pull -q; then
                     status="success"
                     ret_updated=1
                 else
                     status="clean_failed"
                 fi
             fi
        fi
    else
        log_warn "$subdir is not a git repository."
        status="not_git"
    fi

    # Output Handling
    if [ "$JSON_MODE" = "true" ]; then
        # If not the first repo, print comma
        if [ "$FIRST_JSON_REPO" -eq 0 ]; then
            echo ","
        fi
        FIRST_JSON_REPO=0

        echo '    {'
        echo "      \"name\": \"$repo_name\","
        echo "      \"status\": \"$status\","
        echo '      "files": ['

        local first_file=1
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            if [ $first_file -eq 0 ]; then echo ","; fi
            # Escape quotes
            local clean_line=$(echo "$line" | sed 's/"/\\"/g')
            echo -n "        \"$clean_line\""
            first_file=0
        done <<< "$changed_files"
        echo ""
        echo '      ]'
        echo -n '    }'
    else
        # Normal Mode
        if [ "$status" == "success" ] && [ -n "$changed_files" ]; then
             log_success "Updated $repo_name with the following changes:"
             echo "$changed_files" | while read -r line; do
                 echo "  - $line"
             done
        elif [ "$status" == "clean_failed" ]; then
             log_error "Failed to update $repo_name"
        elif [ "$status" == "not_git" ]; then
             : # Already warned
        fi
    fi

    return $ret_updated
}

function main() {
  # Self-elevate to root if not already
  if [ "$(id -u)" -ne 0 ]; then
      log_info "Elevating permissions to root..."
      # shellcheck disable=SC2093
      exec sudo "$0" "$@" # Re-run the script with sudo
      log_error "Failed to elevate to root. Please run with sudo."
      exit 1
  fi

  local args="$@"
  if [[ " $args " =~ " json " ]] || [ "$1" == "json" ]; then
      JSON_MODE="true"
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
    if [ "$JSON_MODE" = "true" ]; then echo '{"error": "No git directory found"}'; fi
    exit 1
  fi

  # Start JSON output
  if [ "$JSON_MODE" = "true" ]; then
      echo "{"
      echo '  "repositories": ['
  fi

  FIRST_JSON_REPO=1
  pulledrepositories=0

  for subdir in $GIT_SUBDIRS; do
      if process_repo "$subdir"; then
          pulledrepositories=$((pulledrepositories+1))
      fi
  done

  # End JSON output
  if [ "$JSON_MODE" = "true" ]; then
      echo "" # Newline after last item
      echo '  ]'
      echo "}"
  fi

  if [ $pulledrepositories -gt 0 ]; then
    log_info "Restarting the docker containers"
    # shellcheck disable=SC2086
    if [ "$JSON_MODE" = "true" ]; then
        sudo -u "$REPOSITORY_OWNER" docker compose -f "$PATH_TO_ODOO/$DOCKER_COMPOSE_FILE" restart >&2
    else
        sudo -u "$REPOSITORY_OWNER" docker compose -f "$PATH_TO_ODOO/$DOCKER_COMPOSE_FILE" restart
    fi

    log_info "Cleaning Unused Docker caches..."
    # shellcheck disable=SC2086
    if [ "$JSON_MODE" = "true" ]; then
        {
            sudo -u "$REPOSITORY_OWNER" docker container prune -f
            sudo -u "$REPOSITORY_OWNER" docker image prune -f
            sudo -u "$REPOSITORY_OWNER" docker system prune -f
            sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches
        } >&2
    else
        sudo -u "$REPOSITORY_OWNER" docker container prune -f
        sudo -u "$REPOSITORY_OWNER" docker image prune -f
        sudo -u "$REPOSITORY_OWNER" docker system prune -f
        sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches
    fi
  else
    log_success "No updates found"
  fi

  log_success "Finish checking updates for $SERVICE_NAME"
}

main "$@"
