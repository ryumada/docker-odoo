#!/bin/bash

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

function amIRoot() {
  if [ "$EUID" -ne 0 ]; then
    log_error "Please run this script using sudo."
    exit 1
  fi
}

function installLogrotator() {
  containers=$(docker ps --format '{{.ID}}')
  container_ids=$(docker inspect --format '{{.Id}}' $containers)

  for container_id in $container_ids; do
    log_info "Create logrotate file for container: $container_id"
    
    cat << EOF > ~/docker_$container_id
/var/lib/docker/containers/$container_id/$container_id-json.log {
    rotate 14
    olddir /var/lib/docker/containers/$container_id/$container_id-json.log-old
    daily
    missingok
    #notifempty
    nocreate
    copytruncate
    compress
    compresscmd /usr/bin/zstd
    compressoptions -7T0
    createolddir 750 root root
    delaycompress
    dateext
    dateformat -%Y%m%d-%H%M%S
}

EOF

    sudo chown root: ~/docker_$container_id
    sudo chmod 644 ~/docker_$container_id
    sudo mv ~/docker_$container_id /etc/logrotate.d/docker_$container_id

    log_success "Created the logrotate file: /etc/logrotate.d/docker_$container_id"
  done

}

function main() {
  amIRoot

  logrotate --version > /dev/null 2>&1 && {
    log_success "logrotate is already installed"
  } || {
    log_error "Logrotate is not available. Please install it first to use this utility"
    exit 1
  }

  if zstd --version > /dev/null 2>&1; then
    log_success "zstd is already installed"
    installLogrotator
  else
    log_info "Install zstd"
    sudo apt install zstd -y && {
      log_success "zstd is installed"
      installLogrotator
    } || {
      log_error "Failed to install zstd"
      exit 1
    }
  fi
}

main
