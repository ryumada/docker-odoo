#!/bin/bash

# This script updates the .env file from .env.example then add the value from the old .env.

function getDate() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")]"
}

function main() {
  CURRENT_DIR=$(dirname "$(readlink -f "$0")")
  CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
  PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
  SERVICE_NAME=$(basename "$PATH_TO_ODOO")
  REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO")

  echo "-------------------------------------------------------------------------------"
  echo " UPDATE ENV FILE FOR $SERVICE_NAME @ $(date +"%A, %d %B %Y %H:%M %Z")"
  echo "-------------------------------------------------------------------------------"

  echo "$(getDate) Path to Odoo: $PATH_TO_ODOO"
  cd "$PATH_TO_ODOO" || exit 1

  if [ -f "$PATH_TO_ODOO/.env" ]; then
    echo "$(getDate) Backup current .env file"
    cp .env .env.bak
  else
    echo "$(getDate) .env file not found. Backup skipped"
  fi

  if [ -f "$PATH_TO_ODOO/.env.example" ]; then
    echo "$(getDate) Copy .env.example to .env"
    cp .env.example .env
  else
    echo "$(getDate) .env.example file not found."
    exit 1
  fi

  if [ -f .env.bak ]; then
    echo "$(getDate) Importing values from .env.bak to .env"
    while IFS= read -r line; do
      if [[ "$line" =~ ^[a-zA-Z_]+[a-zA-Z0-9_]*= ]]; then # Check if line is a variable assignment
        variable_name=$(echo "$line" | cut -d'=' -f1)
        variable_value=$(echo "$line" | cut -d'=' -f2-)
        
        if grep -q "^$variable_name=" .env && [ -n "$variable_value" ]; then
          echo "$(getDate) 🟦 Update $variable_name"
          sed -i "s/^$variable_name=.*/$variable_name=$variable_value/" .env
        fi
      fi
    done < .env.bak
  else
    echo "$(getDate) 🔴 .env.bak file not found. Import skipped."
  fi

  echo "$(getDate) Update .env file with current user and group."
  chown "$REPOSITORY_OWNER": .env

  echo "$(getDate) ✅ Update finished"
}

main
