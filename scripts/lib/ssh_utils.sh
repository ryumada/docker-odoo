#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Shared SSH utilities for cross-VPS key generation and management.
# Usage: source scripts/lib/ssh_utils.sh
# Dependencies: ssh-keygen, git, sed, base64, ssh

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
    chown "$repo_owner":"$repo_owner" "$ssh_dir" 2>/dev/null || true
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
    chown "$repo_owner":"$repo_owner" "$key_path" "$pub_key_path" 2>/dev/null || true
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

install_pubkey_via_admin() {
  local target_host="$1"
  local target_port="${2:-22}"
  local admin_user="$3"
  local target_user="$4"
  local pub_key_path="$5"
  local source_ip="$6"
  local tool_type="${7:-snapshot}"
  local dest_service_name="$8"
  local dest_path="$9"

  if [ -z "$target_host" ] || [ -z "$admin_user" ] || [ -z "$target_user" ] || [ -z "$pub_key_path" ]; then
    _ssh_log_error "install_pubkey_via_admin: target_host, admin_user, target_user, and pub_key_path are required."
    return 1
  fi

  if ! [[ "$target_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    _ssh_log_error "Invalid target username: '$target_user'. Must match ^[a-z_][a-z0-9_-]{0,31}$"
    return 1
  fi

  if ! [[ "$admin_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    _ssh_log_error "Invalid admin username: '$admin_user'. Must match ^[a-z_][a-z0-9_-]{0,31}$"
    return 1
  fi

  if [ ! -f "$pub_key_path" ]; then
    _ssh_log_error "Public key file not found: $pub_key_path"
    return 1
  fi

  if ! ssh-keygen -l -f "$pub_key_path" >/dev/null 2>&1; then
    _ssh_log_error "Invalid public key file format: $pub_key_path"
    return 1
  fi

  local raw_pub_key
  raw_pub_key=$(cat "$pub_key_path" | tr -d '\r\n')
  if [ -z "$raw_pub_key" ]; then
    _ssh_log_error "Public key is empty."
    return 1
  fi

  local b64_pub_key
  b64_pub_key=$(printf "%s" "$raw_pub_key" | base64 | tr -d '\r\n')

  local ip_mode="auto"
  if [ "$source_ip" = "none" ] || [ "$source_ip" = "no" ] || [ "$source_ip" = "disabled" ]; then
    ip_mode="none"
  elif [ -n "$source_ip" ] && [ "$source_ip" != "auto" ]; then
    if ! [[ "$source_ip" =~ ^[0-9a-fA-F.:]+$ ]]; then
      _ssh_log_error "Invalid source IP specified: '$source_ip'"
      return 1
    fi
    ip_mode="$source_ip"
  fi

  _ssh_log_info "Connecting via admin user '${admin_user}@${target_host}:${target_port}' with sudo to provision '${target_user}'..."

  # Remote bash script executed via sudo bash
  local remote_cmd
  remote_cmd=$(cat << 'EOF'
set -e
target_user="$1"
b64_pub="$2"
ip_param="$3"
tool_type="$4"
dest_svc="$5"
dest_path="$6"

pub_key=$(echo "$b64_pub" | base64 -d | tr -d '\r\n')
if [ -z "$pub_key" ]; then
  echo "[-] Decoded public key is empty." >&2
  exit 1
fi

# Detect caller IP from SSH_CLIENT if ip_param is auto
effective_ip=""
if [ "$ip_param" = "auto" ]; then
  effective_ip=$(echo "${SSH_CLIENT:-}" | awk '{print $1}')
elif [ "$ip_param" != "none" ] && [ -n "$ip_param" ]; then
  effective_ip="$ip_param"
fi

# Ensure target user exists or create them with locked password
if ! id "$target_user" >/dev/null 2>&1; then
  echo "[+] User '$target_user' does not exist. Creating system account..." >&2
  sudo useradd -m -s /bin/bash "$target_user"
  sudo passwd -l "$target_user" >/dev/null 2>&1 || true
  echo "[+] Created account '$target_user' (password locked)." >&2
else
  echo "[i] User '$target_user' exists." >&2
fi

target_home=$(eval echo "~$target_user")
if [ -z "$target_home" ] || [ ! -d "$target_home" ]; then
  target_home=$(getent passwd "$target_user" | cut -d: -f6)
fi

if [ -z "$target_home" ] || [ ! -d "$target_home" ]; then
  echo "[-] Could not determine home directory for '$target_user'." >&2
  exit 1
fi

ssh_dir="$target_home/.ssh"
auth_keys="$ssh_dir/authorized_keys"

sudo install -d -m 700 -o "$target_user" -g "$target_user" "$ssh_dir"

# Format key entry with optional restrictions
key_entry="$pub_key"
if [ -n "$effective_ip" ]; then
  key_entry="from=\"${effective_ip}\",no-agent-forwarding,no-X11-forwarding,no-port-forwarding ${pub_key}"
  echo "[+] Bound SSH key to source IP: ${effective_ip}" >&2
else
  echo "[i] IP restriction disabled or unavailable." >&2
fi

# Check if base key already exists in authorized_keys
key_payload=$(echo "$pub_key" | awk '{print $2}')
if [ -f "$auth_keys" ] && sudo grep -qF "$key_payload" "$auth_keys"; then
  echo "[i] SSH key already authorized in $auth_keys." >&2
else
  echo "$key_entry" | sudo tee -a "$auth_keys" >/dev/null
  echo "[+] Appended SSH key to $auth_keys." >&2
fi

sudo chmod 600 "$auth_keys"
sudo chown "$target_user":"$target_user" "$auth_keys"

# Optional sudoers configuration for cloner / deploy_rc tools
if [ "$tool_type" = "cloner" ] && [ -n "$dest_svc" ]; then
  echo "[+] Configuring targeted passwordless sudoers rules for cloner service '$dest_svc'..." >&2
  sudoers_file="/etc/sudoers.d/01-cloner-${dest_svc//./_}-${target_user}"
  tmp_sudoers=$(mktemp)

  cat << SUDO_EOF > "$tmp_sudoers"
# Dedicated passwordless rules for cross-VPS cloner
$target_user ALL=(root) NOPASSWD: /usr/local/sbin/restore_backupdata-${dest_svc}
$target_user ALL=(root) NOPASSWD: /usr/bin/docker compose *
$target_user ALL=(root) NOPASSWD: /usr/bin/docker compose
$target_user ALL=(root) NOPASSWD: /usr/bin/sed -i * ${dest_path}/.env
SUDO_EOF

  if [ -n "$dest_path" ]; then
    echo "$target_user ALL=(root) NOPASSWD: ${dest_path}/scripts/restore_backupdata-${dest_svc}.sh" >> "$tmp_sudoers"
    echo "$target_user ALL=(root) NOPASSWD: ${dest_path}/scripts/restore_backupdata.sh" >> "$tmp_sudoers"
  fi

  chmod 0440 "$tmp_sudoers"
  chown root:root "$tmp_sudoers"

  if visudo -c -f "$tmp_sudoers" >/dev/null 2>&1; then
    sudo mv "$tmp_sudoers" "$sudoers_file"
    echo "[+] Installed validated sudoers rule: $sudoers_file" >&2
  else
    echo "[-] Sudoers validation failed for $tmp_sudoers. Skipping." >&2
    rm -f "$tmp_sudoers"
  fi
fi

if command -v logger >/dev/null 2>&1; then
  logger -t docker-odoo "${tool_type^^} public key installed for $target_user by sudo admin" 2>/dev/null || true
fi

echo "[SUCCESS] Public key installed for $target_user."
EOF
)

  local exec_res=0
  if ssh -t -p "$target_port" -o StrictHostKeyChecking=ask "${admin_user}@${target_host}" \
    "sudo bash -c $(printf '%q' "$remote_cmd") -- $(printf '%q' "$target_user") $(printf '%q' "$b64_pub_key") $(printf '%q' "$ip_mode") $(printf '%q' "$tool_type") $(printf '%q' "${dest_service_name:-}") $(printf '%q' "${dest_path:-}")"; then
    exec_res=0
  else
    exec_res=$?
  fi

  if [ $exec_res -eq 0 ]; then
    _ssh_log_success "Remote SSH key provisioning completed via admin user."
    return 0
  else
    _ssh_log_error "Failed to provision remote SSH key via admin user."
    return 1
  fi
}
