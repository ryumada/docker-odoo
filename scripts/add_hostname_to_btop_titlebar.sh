#!/bin/bash

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Add Hostname to btop Title Bar Script                                       #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
# Description:
# This script customizes the 'btop' resource monitor configuration for users
# on the system. Its primary goal is to append the server's hostname to the
# 'btop' title bar (specifically, within the clock format string). This makes
# it easier to identify which machine is being monitored when using btop,
# especially when managing multiple servers.
#
# How it works:
# 1. Iterates through all user home directories found under /home/.
# 2. For each user, it locates their btop configuration file
#    (expected at ~/.config/btop/btop.conf).
# 3. If the configuration file exists, it uses 'sed' to modify the
#    'clock_format' line, appending " - /host" before the closing quote.
#    The '/host' is a btop special variable that gets replaced by the hostname.
# 4. Logs its actions, indicating which users' configurations are checked
#    and whether modifications were successful.
#
# Prerequisites:
# - btop should be installed on the system.
# - This script must be run with sudo privileges to modify user configuration
#   files.

set -euo pipefail

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

function main() {
    for user_dir in /home/*; do
        [[ -d "$user_dir" ]] || {
            log_warning "$user's dir not found."
        } && {
            user=$(basename "$user_dir")
            config_file="$user_dir/.config/btop/btop.conf"

            log_info "Checking for $user's btop.conf at $config_file..."

            [[ -f "$config_file" ]] || {
                log_warning "$user's btop.conf file is not exist."
            } && {
                log_info "$user's btop.conf exists. Attempting modification..."

                sudo sed -i '/^clock_format *= *".*"$/ s/"$/ - \/host"/' "$config_file" || {
                    log_error "An unexpected error occurred while modifying $user's btop.conf."
                } && {
                    log_success "Successfully modified clock_format for user $user."
                }
            }
        }
    done

    log_success "Finished attempting to modify btop.conf for all users in /home."
}

main
