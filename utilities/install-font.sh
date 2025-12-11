#!/bin/bash

# ==============================================================================
# SCRIPT: install_font.sh
# DESCRIPTION: Downloads a TTF font file and installs it for the current user.
# USAGE: bash install_font.sh <URL_TO_TTF_FILE>
# ==============================================================================

# --- Configuration ---
FONT_URL="$1"
LOCAL_FONT_DIR="$HOME/.local/share/fonts/"

# --- Functions ---

# Function to check for dependencies
check_dependencies() {
    echo "Checking dependencies (wget and fc-cache)..."
    if ! command -v wget &> /dev/null; then
        echo "Error: 'wget' is not installed. Please install it to proceed."
        exit 1
    fi
    if ! command -v fc-cache &> /dev/null; then
        echo "Error: 'fc-cache' (fontconfig) is not installed. Please install it to proceed."
        exit 1
    fi
    echo "Dependencies checked successfully."
}

# Function to extract the filename from the URL
get_filename() {
    # Uses basename to extract the filename from the URL path
    FILENAME=$(basename "$FONT_URL" | cut -d '?' -f 1)
    if [[ -z "$FILENAME" || "$FILENAME" != *.ttf ]]; then
        echo "Error: Could not determine a valid .ttf filename from the URL: $FONT_URL"
        echo "Please ensure the URL points directly to a .ttf file."
        exit 1
    fi
    echo "Identified filename: $FILENAME"
}

# Function to install the font
install_font() {
    echo "Creating font directory: $LOCAL_FONT_DIR"
    mkdir -p "$LOCAL_FONT_DIR"

    echo "Downloading font from $FONT_URL..."
    # The -O flag saves the file with the name derived from the URL
    if ! wget -O "$LOCAL_FONT_DIR/$FILENAME" "$FONT_URL"; then
        echo "Error: Failed to download the font file."
        exit 1
    fi

    echo "Setting permissions for the new font file..."
    chmod 644 "$LOCAL_FONT_DIR/$FILENAME"

    echo "Successfully installed $FILENAME."
}

# Function to update the font cache
update_cache() {
    echo "Updating font cache. This may take a moment..."
    # -f: force scanning, -v: verbose output
    fc-cache -fv

    # Check if the font is in the cache list
    echo "Verifying installation..."
    if fc-list | grep -i "$FILENAME" &> /dev/null; then
        echo "Verification successful! The font should now be available."
    else
        echo "Warning: Font not immediately found in fc-list. Please restart your applications."
    fi
}

# --- Main Execution ---
if [ -z "$FONT_URL" ]; then
    echo "Usage: $0 <URL_TO_TTF_FILE>"
    echo "Example: $0 https://example.com/fonts/MyFont.ttf"
    exit 1
fi

check_dependencies
get_filename
install_font
update_cache
