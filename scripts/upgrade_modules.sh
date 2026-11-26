#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Upgrades specified Odoo modules on a target database inside the running Odoo container without restarting the container.
# Usage: ./scripts/upgrade_modules.sh <DB_NAME> <MODULES> [json|--json]
# Dependencies: bash, docker, sudo, git

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel)
COMPOSE_FILE="$PATH_TO_ODOO/docker-compose.yml"

if [ -f "$CURRENT_DIR/lib/odoo_utils.sh" ]; then
    source "$CURRENT_DIR/lib/odoo_utils.sh"
elif [ -f "$PATH_TO_ODOO/scripts/lib/odoo_utils.sh" ]; then
    source "$PATH_TO_ODOO/scripts/lib/odoo_utils.sh"
fi

JSON_MODE="${JSON_MODE:-false}"

readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[0;31m"

log() {
    local color="$1"
    local emoji="$2"
    local message="$3"
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
        local escaped_msg
        escaped_msg=$(echo -n "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/' | tr -d '\n' | sed 's/\\n$//')
        echo "{\"error\": \"$escaped_msg\"}"
    fi
    log "${COLOR_ERROR}" "❌" "$1"
}

fail_with_json() {
    local message="$1"
    log_error "$message"
    exit 1
}

display_usage() {
    echo "Usage: sudo $0 <DB_NAME> <MODULES> [json|--json]"
    echo "  DB_NAME : Target Odoo database name"
    echo "  MODULES : Comma-separated technical module names (e.g. sale,stock). 'all' is not allowed."
}

ARGS=()
for arg in "$@"; do
    case "$arg" in
        json|--json)
            JSON_MODE="true"
            ;;
        -h|--help)
            display_usage
            exit 0
            ;;
        *)
            ARGS+=("$arg")
            ;;
    esac
done
set -- "${ARGS[@]}"

if declare -F check_deployment_lock >/dev/null 2>&1; then
    check_deployment_lock "$PATH_TO_ODOO/.env"
fi

TARGET_DB="${1:-}"
RAW_MODULES="${2:-}"

if [ -z "$TARGET_DB" ]; then
    fail_with_json "Missing Argument 1: Target Database Name."
fi
if [[ ! "$TARGET_DB" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || [[ "$TARGET_DB" == *".."* ]]; then
    fail_with_json "Invalid database name format: '$TARGET_DB'."
fi

if [ -z "$RAW_MODULES" ]; then
    fail_with_json "Missing Argument 2: Modules to Upgrade (comma-separated)."
fi

CLEAN_MODULES=()
IFS=',' read -ra RAW_MODULE_ARRAY <<< "$RAW_MODULES"
for mod in "${RAW_MODULE_ARRAY[@]}"; do
    mod=$(echo "$mod" | xargs)
    [ -z "$mod" ] && continue
    if [ "${mod,,}" = "all" ]; then
        fail_with_json "Upgrading 'all' modules is not allowed. Please specify explicit technical module names."
    fi
    if [[ ! "$mod" =~ ^[a-zA-Z0-9_]+$ ]]; then
        fail_with_json "Invalid module technical name: '$mod'. Only alphanumeric characters and underscores are allowed."
    fi
    CLEAN_MODULES+=("$mod")
done

if [ "${#CLEAN_MODULES[@]}" -eq 0 ]; then
    fail_with_json "No valid module names were provided."
fi

MODULES_TO_UPDATE=$(IFS=','; echo "${CLEAN_MODULES[*]}")

if [ ! -f "$COMPOSE_FILE" ]; then
    fail_with_json "docker-compose.yml not found at $COMPOSE_FILE."
fi

RUNNING_SERVICES=$(sudo -u "$CURRENT_DIR_USER" docker compose -f "$COMPOSE_FILE" ps --status running --services 2>/dev/null || true)
if ! echo "$RUNNING_SERVICES" | grep -qx "odoo"; then
    fail_with_json "The 'odoo' container is not running. Start the deployment before upgrading modules."
fi

log_info "Upgrading Odoo modules '$MODULES_TO_UPDATE' on database '$TARGET_DB'..."

TEMP_UPDATE_LOG=$(mktemp)
cleanup_temp_files() {
    rm -f "$TEMP_UPDATE_LOG" 2>/dev/null || true
}
trap cleanup_temp_files EXIT

MODULE_UPDATE_ERROR=false
set +e
if [ "$JSON_MODE" = "true" ]; then
    sudo -u "$CURRENT_DIR_USER" docker compose -f "$COMPOSE_FILE" exec -T odoo odoo-module-upgrade "$TARGET_DB" --update="$MODULES_TO_UPDATE" 2>&1 | tee "$TEMP_UPDATE_LOG" >&2
    UPDATE_EXIT=${PIPESTATUS[0]}
else
    sudo -u "$CURRENT_DIR_USER" docker compose -f "$COMPOSE_FILE" exec -T odoo odoo-module-upgrade "$TARGET_DB" --update="$MODULES_TO_UPDATE" 2>&1 | tee "$TEMP_UPDATE_LOG"
    UPDATE_EXIT=${PIPESTATUS[0]}
fi
set -e

if [ "$UPDATE_EXIT" -ne 0 ]; then
    MODULE_UPDATE_ERROR=true
    log_warn "Module upgrade finished with exit code $UPDATE_EXIT."
else
    log_success "Modules '$MODULES_TO_UPDATE' upgraded successfully on '$TARGET_DB'."
fi

UPDATE_OUTPUT=$(cat "$TEMP_UPDATE_LOG")

if [ "$MODULE_UPDATE_ERROR" = "false" ] && declare -f trigger_registry_reload >/dev/null 2>&1; then
    trigger_registry_reload "$TARGET_DB" "$PATH_TO_ODOO" >/dev/null 2>&1 || log_warn "Registry reload skipped or failed."
fi

if [ "$JSON_MODE" = "true" ]; then
    echo "{"
    echo "  \"database_name\": \"$TARGET_DB\","
    echo '  "modules_to_upgrade": ['
    FIRST_MODULE=1
    for module in "${CLEAN_MODULES[@]}"; do
        if [ $FIRST_MODULE -eq 0 ]; then echo ","; fi
        echo -n "    \"$module\""
        FIRST_MODULE=0
    done
    echo ""
    if [ "$MODULE_UPDATE_ERROR" = "true" ]; then
        echo "  ],"
        echo "  \"error\": true,"
        if command -v python3 >/dev/null 2>&1; then
            JSON_SAFE_LOG=$(python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))' <<< "$UPDATE_OUTPUT")
        else
            ESCAPED=$(echo "$UPDATE_OUTPUT" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')
            JSON_SAFE_LOG="\"$ESCAPED\""
        fi
        echo "  \"module_upgrade_log\": $JSON_SAFE_LOG"
    else
        echo "  ]"
    fi
    echo "}"
fi
