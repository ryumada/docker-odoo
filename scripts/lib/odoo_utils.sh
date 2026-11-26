#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Common Odoo operation utilities.
# Usage: source scripts/lib/odoo_utils.sh
# Dependencies: docker

# Function to reload the Odoo registry for a given database
function trigger_registry_reload() {
  local db_name="$1"
  local workdir="$2"

  log_info "Reloading Odoo registry for database '$db_name'..."

  # Store current directory to return later
  local original_dir="$PWD"

  # Change to the repository root to ensure docker compose works
  log_info "Changing to repository root: $workdir"
  cd "$workdir" || { log_error "Failed to change to repository root. Cannot reload registry."; return 1; }

  # Execute the utility inside the container
  if ! docker compose exec -T odoo odoo-registry-reload "$db_name"; then
    printf "\r\n"
    log_error "Failed to reload registry. The application might not work correctly until a restart or module upgrade. You might need to rebuild your Odoo image for the 'odoo-registry-reload' script to be available."
    cd "$original_dir" || true # Attempt to return to original directory
    return 1
  else
    printf "\r\n"
    log_success "Registry reloaded successfully."
    cd "$original_dir" || true # Attempt to return to original directory
    return 0
  fi
}

# Parse a single variable from .env without executing arbitrary shell code
_read_env_var() {
  local env_file="$1"
  local key="$2"
  local raw
  raw=$(grep -E "^${key}=" "$env_file" 2>/dev/null | tail -n 1 | cut -d '=' -f2- || true)
  raw=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [[ "$raw" =~ ^\"(.*)\"$ ]]; then
    raw="${BASH_REMATCH[1]}"
    raw="${raw//\\\"/\"}"
    raw="${raw//\\\\/\\}"
    raw="${raw//\\\$/\$}"
    raw="${raw//\\\`/\`}"
  elif [[ "$raw" =~ ^\'(.*)\'$ ]]; then
    raw="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$raw"
}

# Abort with a clear message (and JSON error if JSON_MODE=true) when DEPLOYMENT_LOCKED=Y
check_deployment_lock() {
  local env_file="${1:-${ENV_FILE:-.env}}"
  if [ ! -f "$env_file" ] && [ -n "${PATH_TO_ODOO:-}" ] && [ -f "$PATH_TO_ODOO/.env" ]; then
    env_file="$PATH_TO_ODOO/.env"
  fi
  [ -f "$env_file" ] || return 0

  local locked_raw locked_lower
  locked_raw=$(_read_env_var "$env_file" "DEPLOYMENT_LOCKED")
  locked_lower=$(printf '%s' "$locked_raw" | tr '[:upper:]' '[:lower:]')
  case "$locked_lower" in
    y|yes|true|1|on)
      local reason by at msg
      reason=$(_read_env_var "$env_file" "DEPLOYMENT_LOCK_REASON")
      by=$(_read_env_var "$env_file" "DEPLOYMENT_LOCKED_BY")
      at=$(_read_env_var "$env_file" "DEPLOYMENT_LOCKED_AT")
      msg="Deployment is locked (DEPLOYMENT_LOCKED=Y)."
      [ -n "$by" ] && msg="$msg Locked by: $by."
      [ -n "$reason" ] && msg="$msg Reason: $reason."
      [ -n "$at" ] && msg="$msg Locked at: $at."
      if declare -F log_error >/dev/null 2>&1; then
        log_error "$msg"
      else
        echo "ERROR: $msg" >&2
      fi
      exit 1
      ;;
  esac
  return 0
}
