#!/usr/bin/env bash

# This script contains utility functions for Odoo operations.
# It is intended to be sourced by other scripts.

# Function to reload the Odoo registry for a given database
function trigger_registry_reload() {
  local db_name="$1"
  log_info "Reloading Odoo registry for database '$db_name'..."

  # Store current directory to return later
  local original_dir="$PWD"

  # Change to the repository root to ensure docker compose works
  log_info "Changing to repository root: $PATH_TO_ODOO"
  cd "$PATH_TO_ODOO" || { log_error "Failed to change to repository root. Cannot reload registry."; return 1; }

  # Execute the utility inside the container
  if ! docker compose exec -T odoo odoo-registry-reload "$db_name"; then
    log_error "Failed to reload registry. The application might not work correctly until a restart or module upgrade. You might need to rebuild your Odoo image for the 'odoo-registry-reload' script to be available."
    cd "$original_dir" || true # Attempt to return to original directory
    return 1
  else
    log_success "Registry reloaded successfully."
    cd "$original_dir" || true # Attempt to return to original directory
    return 0
  fi
}
