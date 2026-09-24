#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Shared SSH utilities for cross-VPS key generation and management.
# Usage: source scripts/lib/ssh_utils.sh
# Dependencies: ssh-keygen, git, sed

readonly SSH_COLOR_RESET="\033[0m"
readonly SSH_COLOR_INFO="\033[0;34m"
readonly SSH_COLOR_SUCCESS="\033[0;32m"
readonly SSH_COLOR_WARN="\033[1;33m"
readonly SSH_COLOR_ERROR="\033[0;31m"
readonly SSH_COLOR_CYAN="\033[0;36m"
readonly SSH_COLOR_BOLD="\033[1m"

_ssh_log() {
  local color="$1"
  local emoji="$2"
  local message="$3"
  echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${SSH_COLOR_RESET}" >&2
}

_ssh_log_info() {
  if declare -f log_info >/dev/null 2>&1; then
    log_info "$1" >&2
  else
    _ssh_log "${SSH_COLOR_INFO}" "ℹ️" "$1"
  fi
}

_ssh_log_success() {
  if declare -f log_success >/dev/null 2>&1; then
    log_success "$1" >&2
  else
    _ssh_log "${SSH_COLOR_SUCCESS}" "✅" "$1"
  fi
}

_ssh_log_warn() {
  if declare -f log_warn >/dev/null 2>&1; then
    log_warn "$1" >&2
  else
    _ssh_log "${SSH_COLOR_WARN}" "⚠️" "$1"
  fi
}

_ssh_log_error() {
  if declare -f log_error >/dev/null 2>&1; then
    log_error "$1" >&2
  else
    _ssh_log "${SSH_COLOR_ERROR}" "❌" "$1"
  fi
}

_ssh_display_banner() {
  local tool_type="$1"
  local clean_target_hostname="$2"
  local target_user="$3"
  local target_host="$4"
  local key_path="$5"
  local pub_key_content="$6"

  echo "" >&2
  echo -e "${SSH_COLOR_BOLD}================================================================================${SSH_COLOR_RESET}" >&2
  echo -e "${SSH_COLOR_SUCCESS}${SSH_COLOR_BOLD}🔑 ${tool_type^^} ED25519 PUBLIC KEY FOR TARGET VPS (${clean_target_hostname})${SSH_COLOR_RESET}" >&2
  echo -e "${SSH_COLOR_BOLD}================================================================================${SSH_COLOR_RESET}" >&2
  echo "" >&2
  echo -e "${SSH_COLOR_CYAN}${pub_key_content}${SSH_COLOR_RESET}" >&2
  echo "" >&2
  echo -e "${SSH_COLOR_BOLD}--------------------------------------------------------------------------------${SSH_COLOR_RESET}" >&2
  echo -e "${SSH_COLOR_INFO}Instructions to authorize this key on Target VPS (${target_user}@${target_host}):${SSH_COLOR_RESET}" >&2
  echo -e "1. Copy the public key string above." >&2
  echo -e "2. Run this command on the Target VPS (${target_host}):" >&2
  echo "" >&2
  echo -e "   ${SSH_COLOR_BOLD}mkdir -p ~/.ssh && chmod 700 ~/.ssh${SSH_COLOR_RESET}" >&2
  echo -e "   ${SSH_COLOR_BOLD}echo '${pub_key_content}' >> ~/.ssh/authorized_keys${SSH_COLOR_RESET}" >&2
  echo -e "   ${SSH_COLOR_BOLD}chmod 600 ~/.ssh/authorized_keys${SSH_COLOR_RESET}" >&2
  echo "" >&2
  echo -e "3. Verify connection from this VPS:" >&2
  echo -e "   ${SSH_COLOR_BOLD}ssh -i $key_path -o BatchMode=yes ${target_user}@${target_host} 'echo Connection successful'${SSH_COLOR_RESET}" >&2
  echo -e "${SSH_COLOR_BOLD}================================================================================${SSH_COLOR_RESET}" >&2
  echo "" >&2
}

generate_ssh_key_pair() {
  local tool_type="${1:-snapshot}"
  local target_host="$2"
  local target_user="${3:-root}"
  local repo_owner="${4:-$USER}"
  local force="${5:-false}"
  local env_var_key="$6"
  local env_file="$7"

  if [ -z "$target_host" ]; then
    _ssh_log_error "Target VPS Hostname or IP is required."
    return 1
  fi

  local this_vps_hostname
  this_vps_hostname=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "vps-source")

  local clean_target_hostname
  clean_target_hostname=$(echo "$target_host" | sed -e 's|^.*://||' -e 's|^.*@||' -e 's|:.*$||' -e 's|/.*$||' -e 's|[^a-zA-Z0-9._-]|_|g')

  local key_name="${tool_type}-${this_vps_hostname}-${clean_target_hostname}"
  local owner_home
  owner_home=$(eval echo "~$repo_owner" 2>/dev/null || echo "$HOME")
  [ -z "$owner_home" ] && owner_home="$HOME"

  local ssh_dir="$owner_home/.ssh"
  local key_path="$ssh_dir/$key_name"
  local pub_key_path="${key_path}.pub"

  _ssh_log_info "Source VPS Hostname : $this_vps_hostname"
  _ssh_log_info "Target VPS Hostname : $clean_target_hostname"
  _ssh_log_info "SSH Key Destination : $key_path"

  if [ ! -d "$ssh_dir" ]; then
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    chown "$repo_owner": "$ssh_dir" 2>/dev/null || true
  fi

  if [ -f "$key_path" ]; then
    if [ "$force" = "true" ]; then
      _ssh_log_warn "Overwriting existing SSH key pair at $key_path..."
      rm -f "$key_path" "$pub_key_path"
    else
      _ssh_log_info "SSH key already exists at $key_path. Using existing key."
    fi
  fi

  if [ ! -f "$key_path" ]; then
    _ssh_log_info "Generating ed25519 SSH key pair..."
    ssh-keygen -q -t ed25519 -N "" -f "$key_path" -C "${key_name}@${this_vps_hostname}"
    chmod 600 "$key_path"
    chmod 644 "$pub_key_path"
    chown "$repo_owner": "$key_path" "$pub_key_path" 2>/dev/null || true
    _ssh_log_success "Generated new ed25519 SSH key pair: $key_path"
  fi

  if [ -n "$env_file" ] && [ -f "$env_file" ] && [ -n "$env_var_key" ]; then
    if grep -q "^${env_var_key}=" "$env_file"; then
      sed -i "s|^${env_var_key}=.*|${env_var_key}=$key_path|" "$env_file"
      _ssh_log_success "Updated ${env_var_key} in $env_file ➡️ $key_path"
    else
      echo "${env_var_key}=$key_path" >> "$env_file"
      _ssh_log_success "Added ${env_var_key} to $env_file ➡️ $key_path"
    fi
  fi

  local pub_key_content=""
  if [ -f "$pub_key_path" ]; then
    pub_key_content=$(cat "$pub_key_path")
  fi

  _ssh_display_banner "$tool_type" "$clean_target_hostname" "$target_user" "$target_host" "$key_path" "$pub_key_content"

  echo "$key_path"
}

ensure_ssh_key_for_remote() {
  local tool_type="${1:-remote}"
  local target_host="$2"
  local target_user="${3:-root}"
  local configured_key="$4"
  local repo_owner="${5:-$USER}"
  local env_var_key="$6"
  local env_file="$7"

  local owner_home
  owner_home=$(eval echo "~$repo_owner" 2>/dev/null || echo "$HOME")
  [ -z "$owner_home" ] && owner_home="$HOME"

  local key_path=""
  if [ -n "$configured_key" ]; then
    key_path="${configured_key/#\~/$owner_home}"
  fi

  if [ -n "$key_path" ] && [ -f "$key_path" ]; then
    echo "$key_path"
    return 0
  fi

  generate_ssh_key_pair "$tool_type" "$target_host" "$target_user" "$repo_owner" "false" "$env_var_key" "$env_file"
}
