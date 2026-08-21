#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Compresses Odoo container and deployment logs by filtering routine INFO lines and keeping high-signal warnings, errors, tracebacks, and summaries.
# Usage: docker compose logs odoo | ./scripts/lib/filter_odoo_log.sh [OPTIONS]
# Dependencies: bash, grep, awk

# Options:
#   -v, --verbose    Show warnings and notices in addition to errors/tracebacks (default)
#   -e, --errors     Show only errors, criticals, and tracebacks
#   -h, --help       Show help message

FILTER_MODE="verbose"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--errors)
      FILTER_MODE="errors"
      shift
      ;;
    -v|--verbose)
      FILTER_MODE="verbose"
      shift
      ;;
    -h|--help)
      echo "Usage: <command> | $(basename "$0") [-e|--errors] [-v|--verbose]"
      echo "Filters Odoo log streams to eliminate routine INFO token bloat."
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

if [ "$FILTER_MODE" = "errors" ]; then
  # Only critical errors, tracebacks, and final status
  awk '
    /Traceback \(most recent call last\):/ { in_traceback=1; print; next }
    in_traceback && /^[A-Za-z_][A-Za-z0-9_]*Error:/ { in_traceback=0; print; next }
    in_traceback { print; next }
    / (ERROR|CRITICAL|FATAL) / { print; next }
    /Failed to load|Failed to initialize|Module upgrade failed/ { print; next }
  '
else
  # Errors, warnings, exceptions, tracebacks, and high-level progress summaries
  awk '
    /Traceback \(most recent call last\):/ { in_traceback=1; print; next }
    in_traceback && /^[A-Za-z_][A-Za-z0-9_]*Error:/ { in_traceback=0; print; next }
    in_traceback { print; next }
    / (ERROR|CRITICAL|FATAL|WARNING|WARN) / { print; next }
    / (Exception|Failed|Error|modules loaded|registry loaded|Initiating shutdown|Database .* created|Database .* updated)/ { print; next }
  '
fi
