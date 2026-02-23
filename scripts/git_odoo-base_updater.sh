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
    if isDirectoryGitRepository "$subdir"; then
      log_info "Fetch and pull $subdir"
      sudo -u "$REPOSITORY_OWNER" git -C "$subdir" fetch
      if sudo -u "$REPOSITORY_OWNER" git -C "$subdir" pull | grep -v "up to date" ;then
        pulledrepositories=$((pulledrepositories+1))
      fi
    else
      log_error "$subdir is not a git repository."
      log_error "Please make sure you have added $subdir directory to your snapshot script to backup the addons manually."
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
