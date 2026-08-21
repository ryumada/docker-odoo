#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Lightweight zero-token health probe for Odoo instances to verify deployment readiness without dumping container logs.
# Usage: ./scripts/lib/check_odoo_health.sh [--port=PORT] [--host=HOST] [--timeout=SECONDS] [--retries=COUNT]
# Dependencies: bash, curl

HOST="127.0.0.1"
PORT="8069"
TIMEOUT=5
RETRIES=1
RETRY_DELAY=2

# Load PORT from .env if available
if [ -f ".env" ]; then
  ENV_PORT=$(grep -E "^PORT=" .env | cut -d '=' -f 2 | tr -d ' "\047' || true)
  if [ -n "$ENV_PORT" ]; then
    PORT="$ENV_PORT"
  fi
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port=*)
      PORT="${1#*=}"
      shift
      ;;
    --host=*)
      HOST="${1#*=}"
      shift
      ;;
    --timeout=*)
      TIMEOUT="${1#*=}"
      shift
      ;;
    --retries=*)
      RETRIES="${1#*=}"
      shift
      ;;
    --delay=*)
      RETRY_DELAY="${1#*=}"
      shift
      ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--port=8069] [--host=127.0.0.1] [--timeout=5] [--retries=1] [--delay=2]"
      echo "Verifies Odoo HTTP availability with zero log overhead."
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

TARGET_URL="http://${HOST}:${PORT}/web/health"
FALLBACK_URL="http://${HOST}:${PORT}/web/login"

attempt=1
while [ "$attempt" -le "$RETRIES" ]; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" "$TARGET_URL" 2>/dev/null || true)

  # If /web/health returned 200, 301, 302, 303 (Odoo redirects)
  if [[ "$HTTP_CODE" =~ ^(200|301|302|303)$ ]]; then
    echo "[HEALTHCHECK] OK (HTTP ${HTTP_CODE}) - Target ${TARGET_URL} is responsive."
    exit 0
  fi

  # Fallback to /web/login in case /web/health is not routed
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" "$FALLBACK_URL" 2>/dev/null || true)
  if [[ "$HTTP_CODE" =~ ^(200|301|302|303)$ ]]; then
    echo "[HEALTHCHECK] OK (HTTP ${HTTP_CODE}) - Target ${FALLBACK_URL} is responsive."
    exit 0
  fi

  if [ "$attempt" -lt "$RETRIES" ]; then
    sleep "$RETRY_DELAY"
  fi
  attempt=$((attempt + 1))
done

echo "[HEALTHCHECK] FAILED (HTTP ${HTTP_CODE:-N/A}) - Target http://${HOST}:${PORT} is unreachable after ${RETRIES} attempts."
exit 1
