#!/bin/bash

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

DOCKER_COMPOSE_FILE="docker-compose.yml"
GIT_PATH="./git"

# --- Logging Functions & Colors ---
# Define colors for log messages
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[0;33m"
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
  cd "$PATH_TO_ODOO" || { log_error "Can't change directory to $PATH_TO_ODOO"; exit 1; }

  log_info "Start checking git repositories"
  GIT_SUBDIRS=$(getSubDirectories "$GIT_PATH")

  if wc -l <<< "$GIT_SUBDIRS" | grep -q "0"; then
    log_error "No git repositories found in $GIT_PATH"
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
      log_warn "$subdir is not a git repository."
      log_warn "Please make sure you have added $subdir directory to your snapshot script to backup the addons manually."
    fi
  done

  if [ $pulledrepositories -gt 0 ]; then
    log_info "Rebuilding the docker containers"
    # sudo -u "$REPOSITORY_OWNER" docker compose -f $PATH_TO_ODOO/$DOCKER_COMPOSE_FILE up -d --build
    sudo -u "$REPOSITORY_OWNER" docker compose -f $PATH_TO_ODOO/$DOCKER_COMPOSE_FILE restart

    log_info "Cleaning Unused Docker caches..."
    sudo -u "$REPOSITORY_OWNER" docker container prune -f; sudo -u "$REPOSITORY_OWNER" docker image prune -f; sudo -u "$REPOSITORY_OWNER" docker system prune -f; sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches
  else
    log_success "No updates found"
  fi

  log_success "Finish checking updates for $SERVICE_NAME"
}

main "@"
