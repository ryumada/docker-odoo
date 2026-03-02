#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Automatically increments the ODOO_IMAGE_VERSION integer in the .env file.
# Usage: ./scripts/bump_image_version.sh
# Dependencies: awk, sed, stat, git

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

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
# ------------------------------------

ENV_FILE="$PATH_TO_ODOO/.env"

if [ ! -f "$ENV_FILE" ]; then
    log_error "The .env file does not exist. Please copy .env.example or run update-env-file.sh first."
    exit 1
fi

# Extract the current version, defaulting to 0 if it's empty or unset
CURRENT_VERSION=$(awk -F '=' '/^ODOO_IMAGE_VERSION=/ {print $2; exit}' "$ENV_FILE" | tr -d ' "''' )
if [ -z "$CURRENT_VERSION" ]; then
    CURRENT_VERSION=0
fi

# Validate that the current version is actually an integer
if ! [[ "$CURRENT_VERSION" =~ ^[0-9]+$ ]]; then
    log_error "Current ODOO_IMAGE_VERSION ('$CURRENT_VERSION') is not an integer. Cannot automatically increment."
    exit 1
fi

# Increment the version
NEW_VERSION=$(( CURRENT_VERSION + 1 ))

log_info "Bumping ODOO_IMAGE_VERSION from ${CURRENT_VERSION} to ${NEW_VERSION}..."

# Update the .env file in place
sed -i "s/^ODOO_IMAGE_VERSION=.*/ODOO_IMAGE_VERSION=$NEW_VERSION/" "$ENV_FILE"

log_success "Successfully updated ODOO_IMAGE_VERSION to $NEW_VERSION"
