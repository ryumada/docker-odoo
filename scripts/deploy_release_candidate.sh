#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- Logging Functions & Colors ---
# Define colors for log messages
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[0;33m"
readonly COLOR_ERROR="\033[0;31m"
readonly COLOR_CYAN="\033[0;36m"

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
log_stage() { log "${COLOR_CYAN}" "📋" "$1"; }
# ------------------------------------

# Self-elevate to root if not already
if [ "$(id -u)" -ne 0 ]; then
    log_info "Elevating permissions to root..."
    # shellcheck disable=SC2093
    exec sudo "$0" "$@" # Re-run the script with sudo
    log_error "Failed to elevate to root. Please run with sudo." # This will only run if exec fails
    exit 1
fi

# --- Usage / Help Function ---
display_usage() {
    echo -e "${COLOR_INFO}Usage:${COLOR_RESET} sudo $0 <REPO_NAME> <BRANCH> <RENEW_DB> [MODULES]"
    echo ""
    echo -e "${COLOR_CYAN}Arguments:${COLOR_RESET}"
    echo -e "  ${COLOR_SUCCESS}1. REPO_NAME${COLOR_RESET}       : The directory name of the git repository (inside stg/git/)."
    echo -e "  ${COLOR_SUCCESS}2. BRANCH${COLOR_RESET}          : The target Git branch to checkout (e.g., 'staging', 'main')."
    echo -e "  ${COLOR_SUCCESS}3. RENEW_DB${COLOR_RESET}        : Set to 'true' or '1' to drop Staging DB and clone from Production."
    echo -e "                       Set to 'false' or '0' to keep existing Staging data."
    echo -e "  ${COLOR_SUCCESS}4. MODULES${COLOR_RESET}         : (Optional) Comma-separated list of modules to update (e.g., 'sale,stock')."
    echo ""
    echo -e "${COLOR_CYAN}Examples:${COLOR_RESET}"
    echo "  # 1. Update code only (Fastest):"
    echo "  sudo $0 odoo-custom release/feature_a false"
    echo ""
    echo "  # 2. Update code and refresh Database from Prod (Full Reset):"
    echo "  sudo $0 odoo-custom release/feature_a true"
    echo ""
    echo "  # 3. Update code and specific modules without DB reset:"
    echo "  sudo $0 odoo-custom release/feature_a false sale,inventory,account"
    echo ""
}

# --- Check for Help Flag ---
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    display_usage
    exit 0
fi

# --- Inputs ---
GIT_REPO_NAME=$1
RELEASE_BRANCH=$2
IS_RENEW_DB=$3
MODULES_TO_UPDATE=$4

# --- Validation ---
MISSING_ARGS=false
if [ -z "$GIT_REPO_NAME" ]; then
    log_error "Missing Argument 1: Git Repo Name"
    MISSING_ARGS=true
fi

if [ -z "$RELEASE_BRANCH" ]; then
    log_error "Missing Argument 2: Release Branch"
    MISSING_ARGS=true
fi

if [ -z "$IS_RENEW_DB" ]; then
    log_error "Missing Argument 3: Renew DB Flag (true/false)"
    MISSING_ARGS=true
fi

if [ "$MISSING_ARGS" == "true" ]; then
    echo ""
    display_usage
    exit 1
fi

# --- Dynamic Path Definition ---
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
STG_PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$STG_PATH_TO_ODOO")
SERVICE_NAME_PRD=${SERVICE_NAME%%-*}

# Try to grab this automatically from your .env file
STG_ENV_FILE="$STG_PATH_TO_ODOO/.env"
STG_DB_NAME_FROM_ENV=$(grep "^DB_NAME=" "$STG_ENV_FILE" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')
STG_DB_NAME="$STG_DB_NAME_FROM_ENV"

if [ -z "$STG_DB_NAME" ]; then
    # Fallback if .env is empty
    STG_DB_NAME="$SERVICE_NAME-$(date +"%Y%m%d-%H%M%S")"
fi

PRD_PATH_TO_ODOO="$STG_PATH_TO_ODOO/../$SERVICE_NAME_PRD"
PRD_ENV_FILE="$PRD_PATH_TO_ODOO/.env"

if [ ! -f "$PRD_ENV_FILE" ]; then
    log_error "Production .env file not found at: $PRD_ENV_FILE"
    exit 1
fi

PRD_DB_NAME=$(grep "^DB_NAME=" "$PRD_ENV_FILE" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')

if [ -z "$PRD_DB_NAME" ]; then
    log_error "DB_NAME is not set in the production environment. Please set it at: $PRD_ENV_FILE"
    exit 1
fi

case "${IS_RENEW_DB}" in
    1|true|True|TRUE)
        IS_RENEW_DB=true
    ;;
    *)
        IS_RENEW_DB=false
    ;;
esac

# --- Validation ---
if [ -z "$GIT_REPO_NAME" ]; then
    log_error "You must specify the Git Repo Name"
    echo "Usage: sudo $0 <git_repo_name> <branch_name> <is_renew_db> [modules_to_update]"
    exit 1
fi

if [ -z "$RELEASE_BRANCH" ]; then
    log_error "You must specify a release branch."
    echo "Usage: sudo $0 <git_repo_name> <branch_name> <is_renew_db> [modules_to_update]"
    exit 1
fi

STG_GIT_PATH="$STG_PATH_TO_ODOO/git/$GIT_REPO_NAME"

# Verify Git path exists
if [ ! -d "$STG_GIT_PATH" ]; then
    log_error "Git path not found at: $STG_GIT_PATH"
    exit 1
fi

log_info "🚀 Starting Deployment for Service: $SERVICE_NAME"
log_info "   Git Repo Name: $GIT_REPO_NAME"
log_info "   Branch: $RELEASE_BRANCH"
if [ "$IS_RENEW_DB" == "true" ]; then
    log_info "   Target DB: $STG_DB_NAME"
fi
log_info "   Renew DB: $IS_RENEW_DB"


# 1. SWITCH BRANCH (Code Update)
# ---------------------------------------------------------
log_stage "[1/4] Switching Git Branch..."

# Fetch updates
if sudo -u "$CURRENT_DIR_USER" git -C "$STG_GIT_PATH" fetch; then
    log_info "Fetch success."
else
    log_error "Failed to fetch."
    exit 1
fi

# Force checkout clean (discard local changes in staging)
if sudo -u "$CURRENT_DIR_USER" git -C "$STG_GIT_PATH" reset --hard; then
    log_info "Local changes discarded (Reset Hard)."
else
    log_warn "Could not reset git changes. Proceeding..."
fi

if sudo -u "$CURRENT_DIR_USER" git -C "$STG_GIT_PATH" checkout "$RELEASE_BRANCH"; then
    log_success "Checked out branch: $RELEASE_BRANCH"
else
    log_error "Failed to checkout branch $RELEASE_BRANCH. Does it exist?"
    exit 1
fi

if sudo -u "$CURRENT_DIR_USER" git -C "$STG_GIT_PATH" pull; then
    log_success "Code is up to date."
else
    log_error "Failed to pull latest code."
    exit 1
fi


# 2. CLONE DATABASE (Data Reset)
# ---------------------------------------------------------
if [ "$IS_RENEW_DB" == "true" ]; then
    log_stage "[2/4] Cloning Production Database to Staging..."

    # if the DB_NAME variable is set in Staging Environment file, drop it first
    STG_PORT=$(grep "^PORT=" "$STG_ENV_FILE" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')
    STG_ADMIN_PASSWD=$(grep "^ADMIN_PASSWD=" "$STG_ENV_FILE" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')

    if [ -n "$STG_DB_NAME_FROM_ENV" ]; then
        log_info "Dropping old database '$STG_DB_NAME_FROM_ENV' if it exists..."

        drop_response=$(curl -s -X POST \
            -d "master_pwd=$STG_ADMIN_PASSWD" \
            -d "name=$STG_DB_NAME_FROM_ENV" \
            "http://localhost:$STG_PORT/web/database/drop")

        if [[ "$drop_response" == *"error"* ]] && [[ "$drop_response" != *"does not exist"* ]]; then
            log_warn "Could not drop database '$STG_DB_NAME_FROM_ENV'. It might not exist or another error occurred. Response: $drop_response"
        else
            log_success "Drop database command completed for '$STG_DB_NAME_FROM_ENV'."
        fi
    fi

    # backup the database from production environment
    TEMP_BACKUP_FILE="/tmp/temp_backup_db-$SERVICE_NAME_PRD-$(date +"%Y%m%d_%H%M%S").zip"
    PRD_PORT=$(grep "^PORT=" "$PRD_ENV_FILE" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')
    PRD_ADMIN_PASSWD=$(grep "^ADMIN_PASSWD=" "$PRD_ENV_FILE" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g')

    log_info "Requesting backup from production $SERVICE_NAME_PRD instance..."
    curl -s -X POST \
        -F "master_pwd=$PRD_ADMIN_PASSWD" \
        -F "name=$PRD_DB_NAME" \
        -F "backup_format=zip" \
        -o "$TEMP_BACKUP_FILE" \
        "http://localhost:$PRD_PORT/web/database/backup"

    if [ ! -s "$TEMP_BACKUP_FILE" ]; then
        log_error "Backup failed for production $SERVICE_NAME_PRD instance. The output file is empty or was not created. Check source Odoo logs."
        exit 1
    fi

    # check if the zip backup file actually an html file
    if grep -q -i "<html" "$TEMP_BACKUP_FILE"; then
        ODOO_ERROR_MSG=$(grep -oP '<div class="alert alert-danger">\K.*(?=</div)' "$TEMP_BACKUP_FILE")

        if [ -z "$ODOO_ERROR_MSG" ]; then
            ODOO_ERROR_MSG="Unknown error (The response was an HTML page, but the specific error message could not be parsed)."
        fi

        log_error "Backup failed! Odoo returned an HTML error page instead of a ZIP file."
        log_error "Odoo Message: $ODOO_ERROR_MSG"

        rm -f "$TEMP_BACKUP_FILE"
        exit 1
    fi

    log_success "Backup of '$PRD_DB_NAME' completed successfully to $TEMP_BACKUP_FILE"

    # restore the database
    log_info "Requesting restore to destination Odoo instance..."
    response=$(curl -s -X POST \
        -F "master_pwd=$STG_ADMIN_PASSWD" \
        -F "name=$STG_DB_NAME" \
        -F "backup_file=@$TEMP_BACKUP_FILE" \
        -F "copy=true" \
        -F "neutralize_database=true" \
        "http://localhost:$STG_PORT/web/database/restore")

    if [[ "$response" == *"error"* ]] || [[ "$response" == *"incorrect master password"* ]]; then
        log_error "Failed to restore database to staging environment. Response: $response"
        rm -f "$TEMP_BACKUP_FILE"
        exit 1
    fi

    log_success "Database restore command sent successfully to destination."
else
    log_stage "[2/4] Skipping Database Clone (IS_RENEW_DB is false)."
fi


# 3. RESTART CONTAINER
# ---------------------------------------------------------
log_stage "[3/4] Restarting Staging Container..."

# Change directory to the dynamic STG_PATH_TO_ODOO
if cd "$STG_PATH_TO_ODOO"; then
    if docker compose restart odoo; then
        log_success "Container restarted."
    else
        log_error "Failed to restart docker container."
        exit 1
    fi
else
    log_error "Could not find directory $STG_PATH_TO_ODOO"
    exit 1
fi


# 4. UPDATE MODULES
# ---------------------------------------------------------
if [ -z "$MODULES_TO_UPDATE" ]; then
    log_stage "[4/4] Update module skipped..."
    log_warn "No specific modules listed."
    log_info "Tip: You can pass modules as the fourth argument: $0 $RELEASE_BRANCH $IS_RENEW_DB 'sale,inventory'"
else
    log_stage "[4/4] Updating Odoo Modules..."
    log_info "Waiting 10 seconds for Odoo to initialize..."
    sleep 10
    log_info "Updating modules: $MODULES_TO_UPDATE"
    # Using the 'odoo-module-upgrade' utility embedded in your image
    if docker compose exec odoo odoo-module-upgrade "$STG_DB_NAME" --update="$MODULES_TO_UPDATE"; then
        log_success "Modules updated successfully."
    else
        log_error "Failed to update modules."
        exit 1
    fi
fi

echo ""
echo "=================================================="
log_success "Deployment Complete!"
echo "   Service:     $SERVICE_NAME"
if [ "$IS_RENEW_DB" == "true" ]; then
    echo "   Database:    $STG_DB_NAME"
fi
echo "   Branch:      $RELEASE_BRANCH"
echo "=================================================="
