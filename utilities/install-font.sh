#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Downloads a TTF font file and installs it for the current user.
# Usage: ./utilities/install-font.sh <URL_TO_TTF_FILE>
# Dependencies: wget, fc-cache

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
  log_error "An error occurred on line $1. Exiting..."
  exit 1
}

trap 'error_handler $LINENO' ERR

# --- Configuration ---
FONT_URL="$1"
LOCAL_FONT_DIR="$HOME/.local/share/fonts/"

# --- Functions ---

# Function to check for dependencies
check_dependencies() {
    log_info "Checking dependencies (wget and fc-cache)..."
    if ! command -v wget &> /dev/null; then
        log_error "'wget' is not installed. Please install it to proceed."
        exit 1
    fi
    if ! command -v fc-cache &> /dev/null; then
        log_error "'fc-cache' (fontconfig) is not installed. Please install it to proceed."
        exit 1
    fi
    log_success "Dependencies checked successfully."
}

# Function to extract the filename from the URL
get_filename() {
    # Uses basename to extract the filename from the URL path
    FILENAME=$(basename "$FONT_URL" | cut -d '?' -f 1)
    if [[ -z "$FILENAME" || "$FILENAME" != *.ttf ]]; then
        log_error "Could not determine a valid .ttf filename from the URL: $FONT_URL"
        log_info "Please ensure the URL points directly to a .ttf file."
        exit 1
    fi
    log_info "Identified filename: $FILENAME"
}

# Function to install the font
install_font() {
    log_info "Creating font directory: $LOCAL_FONT_DIR"
    mkdir -p "$LOCAL_FONT_DIR"

    log_info "Downloading font from $FONT_URL..."
    # The -O flag saves the file with the name derived from the URL
    if ! wget -q -O "$LOCAL_FONT_DIR/$FILENAME" "$FONT_URL"; then
        log_error "Failed to download the font file."
        exit 1
    fi

    log_info "Setting permissions for the new font file..."
    chmod 644 "$LOCAL_FONT_DIR/$FILENAME"

    log_success "Successfully downloaded $FILENAME."
}

# Function to update the font cache
update_cache() {
    log_info "Updating font cache. This may take a moment..."
    # -f: force scanning, -v: verbose output
    if fc-cache -fv > /dev/null; then
        log_success "Font cache updated."
    else
        log_warn "fc-cache failed or returned a warning."
    fi

    # Check if the font is in the cache list
    log_info "Verifying installation..."
    if fc-list | grep -i "$FILENAME" &> /dev/null; then
        log_success "Verification successful! The font should now be available."
    else
        log_warn "Font not immediately found in fc-list. Please restart your applications."
    fi
}

# --- Main Execution ---
if [ -z "$FONT_URL" ]; then
    log_info "Usage: $0 <URL_TO_TTF_FILE>"
    log_info "Example: $0 https://example.com/fonts/MyFont.ttf"
    exit 1
fi

check_dependencies
get_filename
install_font
update_cache
