#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

error_handler() {
  echo "An error occurred on line $1. Exiting..."
  exit 1
}

trap 'error_handler $LINENO' ERR

: "${SERVICE_NAME:=$(basename "$(pwd)")}"
: "${ODOO_VERSION:=16}"

: "${PORT:=8069}"
: "${GEVENT_PORT:=8072}"

: "${WORKERS:=4}"
: "${MAX_CRON_THREADS:=2}"

: "${LIMIT_MEMORY_SOFT:=1073741824}"
: "${LIMIT_MEMORY_HARD:=2684354560}"
: "${LIMIT_TIME_CPU:=2100}"
: "${LIMIT_TIME_REAL:=2700}"
: "${LIMIT_TIME_REAL_CRON:=3600}"
: "${LIMIT_REQUEST:=8196}"

: "${ODOO_DATABASE_MANAGER:=enable}"
: "${ODOO_DATADIR_SERVICE:=/var/lib/odoo/$SERVICE_NAME}"
ODOO_LOG_FILE=$ODOO_LOG_DIR_SERVICE/$SERVICE_NAME.log

: "${DB_HOST:=localhost}"
: "${DB_PORT:=5432}"
: "${DB_MAXCONN:=64}"

ODOO_ARGS=()
function add_arg() {
  param=$1
  value=$2

  if [ -z "$value" ]; then
    ODOO_ARGS+=("--$param")
  else
    ODOO_ARGS+=("--$param=$value")
  fi
}

function getDate() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")]"
}

function main() {
  if [ "$ODOO_VERSION" -ge 11 ]; then
    add_arg "http-port" "$PORT"
  else
    add_arg "xmlrpc-port" "$PORT"
  fi

  if [ "$ODOO_VERSION" -ge 16 ]; then
    : "${TRANSIENT_AGE_LIMIT:=1.0}"

    add_arg "gevent-port" "$GEVENT_PORT"
    add_arg "transient-age-limit" "$TRANSIENT_AGE_LIMIT"
  else
    add_arg "longpolling-port" "$GEVENT_PORT"
  fi

  add_arg "limit-memory-soft" "$LIMIT_MEMORY_SOFT"
  add_arg "limit-memory-hard" "$LIMIT_MEMORY_HARD"
  add_arg "limit-time-cpu" "$LIMIT_TIME_CPU"
  add_arg "limit-time-real" "$LIMIT_TIME_REAL"
  add_arg "limit-time-real-cron" "$LIMIT_TIME_REAL_CRON"
  add_arg "limit-request" "$LIMIT_REQUEST"

  add_arg "data-dir" "$ODOO_DATADIR_SERVICE"
  add_arg "logfile" "$ODOO_LOG_FILE"

  add_arg "db_host" "$DB_HOST"
  add_arg "db_port" "$DB_PORT"
  add_arg "db_maxconn" "$DB_MAXCONN"

  if [ -f /run/secrets/db_user ]; then
    add_arg "db_user" "$(cat /run/secrets/db_user)"
  else
    echo "No secret found at /run/secrets/db_user. Exiting..."
    exit 1
  fi

  if [ -f /run/secrets/db_password ]; then
    add_arg "db_password" "$(cat /run/secrets/db_password)"
  else
    echo "No secret found at /run/secrets/db_password. Exiting..."
    exit 1
  fi

  if [ -n "$DB_NAME" ]; then
    add_arg "database" "$DB_NAME"
    add_arg "db-filter" "^$DB_NAME\$"
    [ -n "$WITHOUT_DEMO" ] && add_arg "without-demo" "$WITHOUT_DEMO"

    if [ -n "$INIT_INSTALL_MODULES" ]; then
      add_arg "init" "$INIT_INSTALL_MODULES"
    fi

    if [ "$ODOO_DATABASE_MANAGER" == "disable" ]; then
      add_arg "no-database-list"
    fi

    if [ -n "$ODOO_UPGRADE_MODULE" ]; then
      add_arg "update" "$ODOO_UPGRADE_MODULE"
    fi
  fi

  ODOO_BASE_DIRECTORY=$(find ./odoo-base -mindepth 1 -maxdepth 1 -type d -print -quit)
  if [ -z "$ODOO_BASE_DIRECTORY" ]; then
    echo "No directory found inside ./odoo-base. Exiting..."
    exit 1
  fi
  ODOO_BASE_DIRECTORY=$(basename "$ODOO_BASE_DIRECTORY")

  if [ "$DEBUG" == "Y" ]; then
    echo "$(getDate) Starting Odoo in debugging mode (with debugpy)"

    # echo "$(getDate) setup workers and max-cron-threads to 1 and 2 respectively"
    # add_arg "workers" "1"
    # add_arg "max-cron-threads" "2"

    echo "$(getDate) Setting up debugpy..."
    pip install debugpy -t /tmp
    echo "$(getDate) Debugpy installed, waiting for client to connect on port 5678..."
    exec python /tmp/debugpy --wait-for-client --listen 0.0.0.0:5678 "/opt/odoo/odoo-base/$ODOO_BASE_DIRECTORY/odoo-bin" -c "/etc/odoo/odoo.conf" "${ODOO_ARGS[@]}"
  else
    echo "$(getDate) Starting Odoo without debugging..."

    add_arg "workers" "$WORKERS"
    add_arg "max-cron-threads" "$MAX_CRON_THREADS"

    exec python "/opt/odoo/odoo-base/$ODOO_BASE_DIRECTORY/odoo-bin" -c "/etc/odoo/odoo.conf" "${ODOO_ARGS[@]}"
  fi
}

main
