#!/usr/bin/env bash
# Category: Library
# Description: The drill settings that are in effect. VALIDATOR_WORKER and SNAPSHOT_VALIDATOR_INBOX may be left
#              empty in .env, meaning "automatic":
#                - an empty VALIDATOR_WORKER is on whenever the snapshot tool is on (ENABLE_SNAPSHOT);
#                - an empty SNAPSHOT_VALIDATOR_INBOX is on when SNAPSHOT_REMOTE_HOST is a real Secondary VPS
#                  (set, and not this machine: localhost, a loopback address, this host's name or addresses).
#              An explicit true or false always wins. Setup (install-snapshot.sh), the drill worker, the snapshot
#              tool and read-drill-reports.sh all use these functions, so they decide the same way.
#              Free disk is not part of the decision: the inbox hand-off and every drill check the disk reserve
#              when they run (VALIDATOR_DISK_RESERVE_GB).
# Usage: source scripts/lib/drill_defaults.sh
#        drill_resolve_worker "$VALIDATOR_WORKER" "$ENABLE_SNAPSHOT" "$SNAPSHOT_REMOTE_HOST"
#        drill_resolve_inbox  "$SNAPSHOT_VALIDATOR_INBOX" "$SNAPSHOT_REMOTE_HOST"
#          Each sets DRILL_VALUE (true|false), DRILL_AUTO (true when the .env value was empty) and DRILL_REASON
#          (one line, for logs), and returns 2 when the .env value is neither empty, true nor false
#          (DRILL_VALUE is then false).
#        drill_host_is_local HOST   -> exit 0 when HOST is this machine (or empty)
# Dependencies: hostname, getent (optional), ip (optional), ssh (optional, to resolve ssh_config aliases)
# shellcheck disable=SC2034  # DRILL_VALUE, DRILL_AUTO and DRILL_REASON are this library's output

# Only for tests: extra names/addresses that count as "this machine" (space separated), and an ssh_config file
# to read aliases from instead of the user's own.
DRILL_LOCAL_EXTRA="${DRILL_LOCAL_EXTRA:-}"
DRILL_SSH_CONFIG="${DRILL_SSH_CONFIG:-}"

_drill_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# This machine's own addresses (IPv4 and IPv6, without prefix length).
_drill_own_addresses() {
  { hostname -I 2>/dev/null | tr ' ' '\n'
    command -v ip >/dev/null 2>&1 && ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1
  } | grep -v '^$' | sort -u
}

# Addresses HOST resolves to (empty when it does not resolve within 3 seconds).
_drill_resolve() {
  command -v getent >/dev/null 2>&1 || return 0
  if command -v timeout >/dev/null 2>&1; then
    timeout 3 getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u
  else
    getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u
  fi
}

_drill_is_loopback() {
  case "$1" in
    127.*|::1|0:0:0:0:0:0:0:1|::ffff:127.*|0.0.0.0|::) return 0 ;;
  esac
  return 1
}

_drill_is_local_name() {
  local h="$1" n own
  case "$h" in
    localhost|localhost.*|*.localhost|ip6-localhost|ip6-loopback) return 0 ;;
  esac
  _drill_is_loopback "$h" && return 0
  for n in $(hostname 2>/dev/null) $(hostname -s 2>/dev/null) $(hostname -f 2>/dev/null) $DRILL_LOCAL_EXTRA; do
    [ "$h" = "$(_drill_lower "$n")" ] && return 0
  done
  own="$(_drill_own_addresses) $DRILL_LOCAL_EXTRA"
  for n in $own; do [ "$h" = "$(_drill_lower "$n")" ] && return 0; done
  for n in $(_drill_resolve "$h"); do
    _drill_is_loopback "$n" && return 0
    for o in $own; do [ "$(_drill_lower "$n")" = "$(_drill_lower "$o")" ] && return 0; done
  done
  return 1
}

drill_host_is_local() {
  local h alias
  h="$(_drill_lower "$1")"
  h="${h##*@}"; h="${h#[}"; h="${h%]}"
  [ -z "$h" ] && return 0
  _drill_is_local_name "$h" && return 0
  # An ssh_config alias (Host backup / HostName 127.0.0.1) is what ssh really connects to.
  if command -v ssh >/dev/null 2>&1; then
    alias="$(ssh ${DRILL_SSH_CONFIG:+-F "$DRILL_SSH_CONFIG"} -G -- "$h" </dev/null 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')"
    alias="$(_drill_lower "$alias")"
    if [ -n "$alias" ] && [ "$alias" != "$h" ]; then
      _drill_is_local_name "$alias" && return 0
    fi
  fi
  return 1
}

_drill_snapshot_on() {
  local v
  v="$(_drill_lower "$1")"
  [ -n "$v" ] && ! [[ "$v" =~ ^(n|no|false|0|off)$ ]]
}

drill_resolve_worker() {
  local raw="$1" enable_snapshot="$2" remote="$3"
  DRILL_AUTO=false
  case "$raw" in
    true)  DRILL_VALUE=true;  DRILL_REASON="VALIDATOR_WORKER=true in .env"; return 0 ;;
    false) DRILL_VALUE=false; DRILL_REASON="VALIDATOR_WORKER=false in .env"; return 0 ;;
    "")    DRILL_AUTO=true ;;
    *)     DRILL_VALUE=false; DRILL_REASON="VALIDATOR_WORKER='$raw' in .env is not true, false or empty"; return 2 ;;
  esac
  if _drill_snapshot_on "$enable_snapshot"; then
    DRILL_VALUE=true
    if [ -n "$remote" ] && ! drill_host_is_local "$remote"; then
      DRILL_REASON="automatic (VALIDATOR_WORKER empty): on, because snapshots are on; drills run on the Secondary VPS $remote"
    else
      DRILL_REASON="automatic (VALIDATOR_WORKER empty): on, because snapshots are on; no Secondary VPS, so drills run on this host"
    fi
  else
    DRILL_VALUE=false
    DRILL_REASON="automatic (VALIDATOR_WORKER empty): off, because snapshots are off (ENABLE_SNAPSHOT)"
  fi
  return 0
}

drill_resolve_inbox() {
  local raw="$1" remote="$2"
  DRILL_AUTO=false
  case "$raw" in
    true)  DRILL_VALUE=true;  DRILL_REASON="SNAPSHOT_VALIDATOR_INBOX=true in .env"; return 0 ;;
    false) DRILL_VALUE=false; DRILL_REASON="SNAPSHOT_VALIDATOR_INBOX=false in .env"; return 0 ;;
    "")    DRILL_AUTO=true ;;
    *)     DRILL_VALUE=false; DRILL_REASON="SNAPSHOT_VALIDATOR_INBOX='$raw' in .env is not true, false or empty"; return 2 ;;
  esac
  if [ -z "$remote" ]; then
    DRILL_VALUE=false
    DRILL_REASON="automatic (SNAPSHOT_VALIDATOR_INBOX empty): off, because there is no Secondary VPS (SNAPSHOT_REMOTE_HOST)"
  elif drill_host_is_local "$remote"; then
    DRILL_VALUE=false
    DRILL_REASON="automatic (SNAPSHOT_VALIDATOR_INBOX empty): off, because SNAPSHOT_REMOTE_HOST=$remote is this machine"
  else
    DRILL_VALUE=true
    DRILL_REASON="automatic (SNAPSHOT_VALIDATOR_INBOX empty): on, because SNAPSHOT_REMOTE_HOST=$remote is a Secondary VPS"
  fi
  return 0
}
