#!/bin/bash

# ==============================================================================
# SCRIPT: docker_install_font.sh
# DESCRIPTION: Extracts a comma-separated list of font URLs from the FONT_URLS
#              variable in the .env file and installs each font via Docker.
# USAGE: ./docker_install_font.sh
# ==============================================================================

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


# --- Configuration ---
DOCKER_COMPOSE_FILE="../docker-compose.yml"
DOTENV_FILE="../.env"
DEPLOYMENT_NAME="odoo"
CONTAINER_SCRIPT="install-font"

# --- Variables ---
# Global error status for the loop
OVERALL_EXIT_STATUS=0
FONT_URLS="" # Initialize the variable that will hold the extracted URLs

# --- Functions ---

# Function to safely load environment variables from the .env file
# (Avoids 'source' by parsing the file content)
load_dotenv() {
    if [[ ! -f "$DOTENV_FILE" ]]; then
        log_error "Required .env file not found at $DOTENV_FILE."
        exit 1
    fi

    log_info "Safely loading environment variables from: $DOTENV_FILE"

    # Process the .env file:
    # 1. 'cat' the file content.
    # 2. 'grep -vE' ignores comments (#) and blank lines.
    # 3. 'sed' removes single quotes, double quotes, and carriage returns (for Windows files).
    # 4. 'xargs' reads the output line by line and exports each key=value pair.
    # Note: This method is robust but simple (doesn't handle multi-line values or escaped quotes).
    export $(
        cat "$DOTENV_FILE" | \
        grep -vE '^\s*#|^\s*$' | \
        sed -e 's/"//g' -e "s/'//g" -e 's/\r//g' | \
        xargs
    )

    # Check if FONT_URLS was loaded, which is our required variable
    if [[ -z "$FONT_URLS" ]]; then
        log_warn "The FONT_URLS variable is empty or not found after loading $DOTENV_FILE."
        return 1
    fi

    log_info "Successfully loaded environment variables."
    return 0
}

# Function to process and install fonts
process_fonts() {
    # Check if FONT_URLS has content after loading the .env file
    if [[ -z "$FONT_URLS" ]]; then
        log_warn "No font URLs to process. Exiting font installation."
        return 0
    fi

    # Set Internal Field Separator (IFS) to comma for splitting
    # Save the original IFS to restore it later
    local ORIGINAL_IFS="$IFS"
    IFS=,

    # Convert the comma-separated string into an array
    read -ra URL_ARRAY <<< "$FONT_URLS"

    # Restore IFS
    IFS="$ORIGINAL_IFS"

    log_info "Found ${#URL_ARRAY[@]} font URLs to process."
    echo "---"

    # Loop through each URL in the array
    for FONT_URL in "${URL_ARRAY[@]}"; do
        # Clean up any leading/trailing whitespace around the URL
        FONT_URL=$(echo "$FONT_URL" | xargs)

        if [ -z "$FONT_URL" ]; then
            log_warn "Skipping empty or whitespace-only font URL entry."
            continue
        fi

        log_info "Processing font: $FONT_URL"

        # Execute the docker compose command
        docker compose -f "$DOCKER_COMPOSE_FILE" exec "$DEPLOYMENT_NAME" "$CONTAINER_SCRIPT" "$FONT_URL"
        echo "docker compose -f "$DOCKER_COMPOSE_FILE" exec "$DEPLOYMENT_NAME" "$CONTAINER_SCRIPT" "$FONT_URL""
        EXIT_STATUS=$?

        if [ $EXIT_STATUS -eq 0 ]; then
            log_success "Successfully ran '$CONTAINER_SCRIPT' for font URL: $FONT_URL"
        else
            log_error "Command failed (Exit Code $EXIT_STATUS) for font URL: $FONT_URL"
            # Set global status to non-zero to indicate an error occurred
            OVERALL_EXIT_STATUS=1
        fi
        echo "---"
    done
}


# --- Main Execution ---

if load_dotenv; then
    log_info "Starting font installation process via Docker Compose for service: '$DEPLOYMENT_NAME'"
    log_info "Container Script: '$CONTAINER_SCRIPT'"
    echo "---"

    process_fonts

    # Final summary based on the global status
    if [ $OVERALL_EXIT_STATUS -eq 0 ]; then
        log_success "All fonts processed successfully."
    else
        log_error "One or more font installations failed. Check the logs above."
    fi

    exit $OVERALL_EXIT_STATUS
else
    # load_dotenv already logged the error/warning
    exit 1
fi
