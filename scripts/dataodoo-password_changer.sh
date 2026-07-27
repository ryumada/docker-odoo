#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Changes the password of an Odoo user in a specified database.
# Usage: NEW_PASSWORD="new_pass" ./scripts/dataodoo-password_changer.sh [DB_NAME] [USER]
# Dependencies: sudo, git, psql / docker

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel)

# --- Logging Functions & Colors ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[0;31m"

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

error_handler() {
  local exit_code=$1
  local line_no=$2
  local command_name=$3
  log_error "An error occurred on line $line_no."
  log_error "Exit Code: $exit_code"
  log_error "Command: $command_name"
  exit "$exit_code"
}

trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR

show_help() {
  cat << EOF
Usage: [NEW_PASSWORD="password"] $0 [DB_NAME] [USER]

Description:
  Changes the password of an Odoo user in a specified database.
  Supports both host PostgreSQL and containerized PostgreSQL deployments.

Arguments:
  DB_NAME       Target Odoo database name
  USER          Odoo username / login name

Environment Variables:
  NEW_PASSWORD  (Optional) New password for the user. If omitted, the script prompts securely.

Options:
  -h, --help    Show this help message and exit

Examples:
  NEW_PASSWORD="SecretPassword123" $0 odoo_production admin
  $0 odoo_production admin  # Prompts interactively
EOF
  exit 0
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  show_help
fi

# Check positional parameters
DB_NAME="${1:-}"
USER_NAME="${2:-}"

if [ -z "$DB_NAME" ] || [ -z "$USER_NAME" ]; then
  log_error "Usage: NEW_PASSWORD=\"password\" $0 [DB_NAME] [USER]"
  log_info "Run '$0 --help' for more details."
  exit 1
fi

# Securely acquire NEW_PASSWORD if not provided via environment variable
if [ -z "${NEW_PASSWORD:-}" ]; then
  read -rsp "Enter new password for user '$USER_NAME': " NEW_PASSWORD
  echo
  if [ -z "$NEW_PASSWORD" ]; then
    log_error "Password cannot be empty."
    exit 1
  fi
fi

function run_psql() {
  local env_file="${PSQL_ENV_FILE:-$PATH_TO_ODOO/.env}"
  local db_host
  db_host=$(grep "^DB_HOST=" "$env_file" 2>/dev/null | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
  local has_db=false
  for arg in "$@"; do
    if [[ "$arg" == "-d" || "$arg" == -d* || "$arg" == "--dbname="* || "$arg" == "--dbname" ]]; then
      has_db=true
      break
    fi
  done
  local db_default=()
  if [ "$has_db" = false ]; then
    db_default=(-d postgres)
  fi

  if [ -n "$db_host" ] && [ "$db_host" != "localhost" ]; then
    local db_port db_user db_pass docker_net net
    db_port=$(grep "^DB_PORT=" "$env_file" 2>/dev/null | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
    db_user=$(cat "$(dirname "$env_file")/.secrets/db_user" 2>/dev/null || echo "postgres")
    db_pass=$(cat "$(dirname "$env_file")/.secrets/db_password" 2>/dev/null || true)
    docker_net=$(grep "^DOCKER_NETWORK_MODE=" "$env_file" 2>/dev/null | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
    [ -z "$db_port" ] && db_port="5432"
    [ -z "$docker_net" ] && docker_net="host"
    net=$(echo "$docker_net" | cut -d "," -f 1)
    docker run -i --rm --network="$net" -e PGPASSWORD="$db_pass" postgres psql -h "$db_host" -p "$db_port" -U "$db_user" "${db_default[@]}" "$@"
  elif command -v docker >/dev/null 2>&1 && docker compose -f "$PATH_TO_ODOO/docker-compose.yml" ps db --format json 2>/dev/null | grep -q '"State":"running"' 2>/dev/null; then
    local db_user db_pass
    db_user=$(cat "$PATH_TO_ODOO/.secrets/db_user" 2>/dev/null || echo "postgres")
    db_pass=$(cat "$PATH_TO_ODOO/.secrets/db_password" 2>/dev/null || true)
    docker compose -f "$PATH_TO_ODOO/docker-compose.yml" exec -T -e PGPASSWORD="$db_pass" db psql -U "$db_user" "${db_default[@]}" "$@"
  else
    sudo -u postgres psql "${db_default[@]}" "$@"
  fi
}

# Escape single quotes in inputs for SQL safety
SQL_LOGIN="${USER_NAME//\'/\'\'}"
SQL_PASS="${NEW_PASSWORD//\'/\'\'}"

log_info "Updating password for user '$USER_NAME' on database '$DB_NAME'..."

SQL_QUERY="UPDATE res_users SET password='${SQL_PASS}' WHERE login='${SQL_LOGIN}';"
RESULT=$(run_psql -d "$DB_NAME" -t -c "$SQL_QUERY")

if echo "$RESULT" | grep -q "UPDATE 1"; then
  log_success "Password for user '$USER_NAME' on database '$DB_NAME' updated successfully."
else
  log_warn "Query executed: $RESULT"
  log_warn "If count was 0, please check if user '$USER_NAME' exists in database '$DB_NAME'."
fi
