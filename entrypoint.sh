#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

error_handler() {
  echo "An error occurred on line $1. Exiting..."
  exit 1
}

trap 'error_handler $LINENO' ERR

: "${PORT:=8069}"
: "${GEVENT_PORT:=8072}"

: "${WORKERS:=4}"

: "${LIMIT_MEMORY_SOFT:=1073741824}"
: "${LIMIT_MEMORY_HARD:=2684354560}"
: "${LIMIT_TIME_CPU:=2100}"
: "${LIMIT_TIME_REAL:=2700}"
: "${LIMIT_TIME_REAL_CRON:=3600}"
: "${LIMIT_REQUEST:=8196}"
: "${TRANSIENT_AGE_LIMIT:=1.0}"

: "${DATA_DIR:=/opt/odoo/datadir}"

: "${DB_HOST:=localhost}"
: "${DB_PORT:=5432}"
: "${DB_MAXCONN:=64}"

ODOO_ARGS=()
function add_arg() {
  param=$1
  value=$2
  
  if [ -z "$value"]; then
    ODOO_ARGS+=("--$param")
  else
    ODOO_ARGS+=("--$param=$value")
  fi
}

add_arg "gevent-port" "$GEVENT_PORT"
add_arg "max-cron-threads" "$MAX_CRON_THREADS:=2"

if [ -n "$DB_NAME" ]; then
  add_arg "db-filter" "^$DB_NAME\$"
else
  add_arg "no-database-list"
fi

ODOO_BASE_DIRECTORY=$(find ./odoo-base -mindepth 1 -maxdepth 1 -type d -print -quit)
if [ -z "$ODOO_BASE_DIRECTORY" ]; then
  echo "No directory found inside ./odoo-base. Exiting..."
  exit 1
fi
ODOO_BASE_DIRECTORY=$(basename "$ODOO_BASE_DIRECTORY")

exec python /opt/odoo/odoo-base/$ODOO_BASE_DIRECTORY/odoo-bin "$@" "${ODOO_ARGS[@]}"
