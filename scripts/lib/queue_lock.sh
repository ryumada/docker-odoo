#!/usr/bin/env bash
# Category: Library
# Description: Shared queue lock for snapshot-type jobs, on this host or on a Secondary VPS over SSH.
# Usage: source scripts/lib/queue_lock.sh
# Dependencies: flock, date, hostname, id, ssh (remote mode)
#
# How the queue works (all files live in /tmp, or in QUEUE_LOCK_DIR when it is set):
#   /tmp/<queue>.queue.lock
#       Shared file, never deleted. Only used with a short flock so that
#       "check markers -> write my marker" happens as one atomic step.
#       It is opened read-only, so fs.protected_regular never blocks it,
#       whichever user created it first.
#   /tmp/<queue>.queue.active.<holder>.u<uid>
#       One marker per running job: "<epoch> <token> <description>".
#       The holder rewrites the epoch every QUEUE_LOCK_HEARTBEAT seconds and
#       deletes it on release. Each job only writes its own marker, so jobs
#       running as different users never need to touch each other's files.
#   /tmp/<queue>.queue.active
#       Legacy single marker written by older scripts. Read only, for rollout.
#
# The queue is busy while any marker is fresh (heartbeat newer than
# QUEUE_LOCK_STALE_AFTER). A marker left by a crashed job stops counting once
# its heartbeat is older than that. Local holders also keep the flock for the
# whole run, so older scripts (which only look at the flock) wait for them too.
#
# Public functions:
#   queue_lock_acquire_local  <queue> <service> <description> <timeout_s>
#   queue_lock_release_local
#   queue_lock_acquire_remote <queue> <service> <description> <timeout_s> <runner_fn>
#   queue_lock_release_remote
#   queue_lock_release_all            (safe to call from an EXIT trap)
# <runner_fn> is a function that runs its arguments on the remote host and
# passes stdin through, e.g. remote_exec() { ssh ... "$user@$host" "$@"; }

: "${QUEUE_LOCK_POLL_INTERVAL:=60}"       # seconds between checks while waiting
: "${QUEUE_LOCK_STALE_AFTER:=600}"        # marker without heartbeat for this long = dead job
: "${QUEUE_LOCK_HEARTBEAT:=60}"           # seconds between heartbeats
: "${QUEUE_LOCK_LEGACY_STALE_AFTER:=43200}" # legacy markers have no heartbeat
# QUEUE_LOCK_DIR (optional, default /tmp): folder of the lock files on this host. Only for
# isolated runs such as the tests; jobs that share a queue must use the same folder. It is
# never sent to a remote host: the remote side uses its own QUEUE_LOCK_DIR, else /tmp.

QUEUE_LOCK_LOCAL_QUEUE=""
QUEUE_LOCK_LOCAL_HOLDER=""
QUEUE_LOCK_LOCAL_TOKEN=""
QUEUE_LOCK_LOCAL_HB_PID=""
QUEUE_LOCK_HELD_FD=""
QUEUE_LOCK_REMOTE_QUEUE=""
QUEUE_LOCK_REMOTE_HOLDER=""
QUEUE_LOCK_REMOTE_TOKEN=""
QUEUE_LOCK_REMOTE_RUNNER=""
QUEUE_LOCK_REMOTE_HB_PID=""

_ql_log() {
  local level="$1" msg="$2"
  if declare -f "log_$level" >/dev/null 2>&1; then
    "log_$level" "$msg"
  else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [$level] $msg" >&2
  fi
}

_ql_short_host() { hostname -s 2>/dev/null || hostname 2>/dev/null || echo "host"; }
_ql_sanitize() { printf '%s' "$1" | sed 's|[^a-zA-Z0-9._-]|_|g'; }
_ql_new_token() { printf '%s-%s-%s%s' "$(_ql_sanitize "$(_ql_short_host)")" "$$" "$RANDOM" "$RANDOM"; }

# --- Core steps. These run where the queue lives (locally, or remotely via declare -f). ---

__ql_try() {
  # Args: queue holder token description stale_after legacy_stale_after hold(0|1)
  # Prints one line: "ACQUIRED", "BUSY <who>" or "ERROR <why>". Returns 0, 1 or 2.
  local queue="$1" holder="$2" token="$3" desc="$4" stale="$5" legacy_stale="$6" hold="${7:-0}"
  local base="${QUEUE_LOCK_DIR:-/tmp}/$queue.queue"
  local lock="$base.lock"
  local marker="$base.active.$holder.u$(id -u)"
  local fd now f ts rest age limit who

  if [ ! -e "$lock" ]; then
    ( umask 000; : >> "$lock" ) 2>/dev/null || true
    chmod 666 "$lock" 2>/dev/null || true
  fi
  if ! exec {fd}<"$lock"; then
    echo "ERROR cannot open $lock"
    return 2
  fi
  if ! flock -n "$fd"; then
    exec {fd}<&-
    echo "BUSY a job holding $lock"
    return 1
  fi

  now=$(date +%s)
  for f in "$base.active" "$base.active."*; do
    [ -f "$f" ] && [ -s "$f" ] || continue
    ts="" rest=""
    read -r ts rest < "$f" 2>/dev/null || true
    [[ "$ts" =~ ^[0-9]+$ ]] || continue
    if [ "$f" = "$base.active" ]; then
      limit="$legacy_stale"; who="$rest"
    else
      limit="$stale"; who="${rest#* }"
    fi
    age=$((now - ts))
    if [ "$age" -lt "$limit" ]; then
      exec {fd}<&-
      echo "BUSY $who"
      return 1
    fi
    # Dead job: remove its marker if it is ours, otherwise just ignore it.
    if [ -O "$f" ]; then rm -f "$f" 2>/dev/null || true; fi
    echo "[WARN] Ignoring stale queue marker $f (no heartbeat for ${age}s): $who" >&2
  done

  if ! ( umask 022; printf '%s %s %s\n' "$now" "$token" "$desc" > "$marker.tmp.$$" && mv -f "$marker.tmp.$$" "$marker" ); then
    rm -f "$marker.tmp.$$" 2>/dev/null || true
    exec {fd}<&-
    echo "ERROR cannot write $marker"
    return 2
  fi

  if [ "$hold" = "1" ]; then
    QUEUE_LOCK_HELD_FD="$fd"
  else
    exec {fd}<&-
  fi
  echo "ACQUIRED"
  return 0
}

__ql_beat() {
  # Args: queue holder token. Refreshes our marker's timestamp if it is still ours.
  local marker="${QUEUE_LOCK_DIR:-/tmp}/$1.queue.active.$2.u$(id -u)" token="$3" ts tok rest
  [ -f "$marker" ] || { echo "LOST"; return 1; }
  read -r ts tok rest < "$marker" || { echo "LOST"; return 1; }
  [ "$tok" = "$token" ] || { echo "LOST"; return 1; }
  printf '%s %s %s\n' "$(date +%s)" "$token" "$rest" > "$marker.tmp.$$" && mv -f "$marker.tmp.$$" "$marker"
}

__ql_release() {
  # Args: queue holder token. Deletes our marker only if it is still ours.
  local marker="${QUEUE_LOCK_DIR:-/tmp}/$1.queue.active.$2.u$(id -u)" token="$3" ts tok rest
  [ -f "$marker" ] || return 0
  read -r ts tok rest < "$marker" 2>/dev/null || true
  if [ "$tok" = "$token" ]; then rm -f "$marker" 2>/dev/null || true; fi
  return 0
}

# --- Local queue (this host) ---

queue_lock_acquire_local() {
  local queue="$1" service="$2" desc="$3" timeout="$4"
  local holder token start out rc elapsed
  holder="$(_ql_sanitize "$(_ql_short_host).$service.local")"
  token="$(_ql_new_token)"
  start=$(date +%s)

  while true; do
    rc=0
    out=$(__ql_try "$queue" "$holder" "$token" "$desc" "$QUEUE_LOCK_STALE_AFTER" "$QUEUE_LOCK_LEGACY_STALE_AFTER" 0) || rc=$?
    if [ "$rc" -eq 0 ]; then
      # __ql_try ran in a subshell, so take and keep the flock here in the main shell.
      exec {QUEUE_LOCK_HELD_FD}<"${QUEUE_LOCK_DIR:-/tmp}/$queue.queue.lock"
      if ! flock -n "$QUEUE_LOCK_HELD_FD"; then
        exec {QUEUE_LOCK_HELD_FD}<&-
        QUEUE_LOCK_HELD_FD=""
        __ql_release "$queue" "$holder" "$token"
        out="BUSY a job that started at the same moment"
        rc=1
      fi
    fi

    if [ "$rc" -eq 0 ]; then
      QUEUE_LOCK_LOCAL_QUEUE="$queue"
      QUEUE_LOCK_LOCAL_HOLDER="$holder"
      QUEUE_LOCK_LOCAL_TOKEN="$token"
      _ql_start_local_heartbeat
      _ql_log success "Acquired '$queue' queue on this host ($desc)."
      return 0
    fi
    if [ "$rc" -eq 2 ]; then
      _ql_log error "Queue '$queue' on this host: ${out#ERROR }"
      return 1
    fi

    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$timeout" ]; then
      _ql_log error "Queue '$queue' on this host: wait timed out after ${timeout}s. Still busy with: ${out#BUSY }"
      return 1
    fi
    _ql_log info "⏳ Queue '$queue' on this host is busy with: ${out#BUSY }. Checking again in ${QUEUE_LOCK_POLL_INTERVAL}s (${elapsed}s / ${timeout}s)..."
    sleep "$QUEUE_LOCK_POLL_INTERVAL"
  done
}

_ql_start_local_heartbeat() {
  local parent=$$
  (
    # The heartbeat must never keep the flock alive on its own.
    [ -n "$QUEUE_LOCK_HELD_FD" ] && exec {QUEUE_LOCK_HELD_FD}<&-
    while sleep "$QUEUE_LOCK_HEARTBEAT"; do
      kill -0 "$parent" 2>/dev/null || break
      __ql_beat "$QUEUE_LOCK_LOCAL_QUEUE" "$QUEUE_LOCK_LOCAL_HOLDER" "$QUEUE_LOCK_LOCAL_TOKEN" >/dev/null 2>&1 || break
    done
  ) </dev/null >/dev/null 2>&1 &
  QUEUE_LOCK_LOCAL_HB_PID=$!
}

queue_lock_release_local() {
  [ -n "$QUEUE_LOCK_LOCAL_QUEUE" ] || return 0
  if [ -n "$QUEUE_LOCK_LOCAL_HB_PID" ]; then
    kill "$QUEUE_LOCK_LOCAL_HB_PID" 2>/dev/null || true
    wait "$QUEUE_LOCK_LOCAL_HB_PID" 2>/dev/null || true
  fi
  __ql_release "$QUEUE_LOCK_LOCAL_QUEUE" "$QUEUE_LOCK_LOCAL_HOLDER" "$QUEUE_LOCK_LOCAL_TOKEN"
  if [ -n "$QUEUE_LOCK_HELD_FD" ]; then
    # In braces: "exec ... 2>/dev/null" alone would send the rest of the caller's log to /dev/null
    { exec {QUEUE_LOCK_HELD_FD}<&-; } 2>/dev/null || true
  fi
  QUEUE_LOCK_LOCAL_QUEUE="" QUEUE_LOCK_LOCAL_HOLDER="" QUEUE_LOCK_LOCAL_TOKEN="" QUEUE_LOCK_LOCAL_HB_PID="" QUEUE_LOCK_HELD_FD=""
}

# --- Remote queue (e.g. the Secondary VPS), driven over SSH ---

_ql_remote_call() {
  # Args: runner function_name args... Runs one core function on the remote host.
  local runner="$1" fn="$2"; shift 2
  local call
  call="$fn$(printf ' %q' "$@")"
  "$runner" "bash -s" <<QL_REMOTE_EOF
$(declare -f "$fn")
$call
QL_REMOTE_EOF
}

queue_lock_acquire_remote() {
  local queue="$1" service="$2" desc="$3" timeout="$4" runner="$5"
  local holder token start out rc elapsed
  holder="$(_ql_sanitize "$(_ql_short_host).$service.remote")"
  token="$(_ql_new_token)"
  start=$(date +%s)

  while true; do
    rc=0
    out=$(_ql_remote_call "$runner" __ql_try "$queue" "$holder" "$token" "$desc" "$QUEUE_LOCK_STALE_AFTER" "$QUEUE_LOCK_LEGACY_STALE_AFTER" 0 2>/dev/null | tail -n 1) || true
    case "$out" in
      ACQUIRED) rc=0 ;;
      BUSY*)    rc=1 ;;
      ERROR*)   rc=2 ;;
      *)        rc=3; out="BUSY (no answer from the remote host, will retry)" ;;
    esac

    if [ "$rc" -eq 0 ]; then
      QUEUE_LOCK_REMOTE_QUEUE="$queue"
      QUEUE_LOCK_REMOTE_HOLDER="$holder"
      QUEUE_LOCK_REMOTE_TOKEN="$token"
      QUEUE_LOCK_REMOTE_RUNNER="$runner"
      _ql_start_remote_heartbeat
      _ql_log success "Acquired '$queue' queue on the remote host ($desc)."
      return 0
    fi
    if [ "$rc" -eq 2 ]; then
      _ql_log error "Queue '$queue' on the remote host: ${out#ERROR }"
      return 1
    fi

    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$timeout" ]; then
      _ql_log error "Queue '$queue' on the remote host: wait timed out after ${timeout}s. Still busy with: ${out#BUSY }"
      return 1
    fi
    _ql_log info "⏳ Queue '$queue' on the remote host is busy with: ${out#BUSY }. Checking again in ${QUEUE_LOCK_POLL_INTERVAL}s (${elapsed}s / ${timeout}s)..."
    sleep "$QUEUE_LOCK_POLL_INTERVAL"
  done
}

_ql_start_remote_heartbeat() {
  local parent=$$
  (
    [ -n "$QUEUE_LOCK_HELD_FD" ] && exec {QUEUE_LOCK_HELD_FD}<&-
    while sleep "$QUEUE_LOCK_HEARTBEAT"; do
      kill -0 "$parent" 2>/dev/null || break
      # A failed beat (e.g. a short SSH drop) is retried next round; the marker only
      # goes stale after QUEUE_LOCK_STALE_AFTER without any successful beat.
      out=$(_ql_remote_call "$QUEUE_LOCK_REMOTE_RUNNER" __ql_beat "$QUEUE_LOCK_REMOTE_QUEUE" "$QUEUE_LOCK_REMOTE_HOLDER" "$QUEUE_LOCK_REMOTE_TOKEN" 2>/dev/null | tail -n 1) || true
      [ "$out" = "LOST" ] && break
    done
  ) </dev/null >/dev/null 2>&1 &
  QUEUE_LOCK_REMOTE_HB_PID=$!
}

queue_lock_release_remote() {
  [ -n "$QUEUE_LOCK_REMOTE_QUEUE" ] || return 0
  if [ -n "$QUEUE_LOCK_REMOTE_HB_PID" ]; then
    kill "$QUEUE_LOCK_REMOTE_HB_PID" 2>/dev/null || true
    wait "$QUEUE_LOCK_REMOTE_HB_PID" 2>/dev/null || true
  fi
  _ql_remote_call "$QUEUE_LOCK_REMOTE_RUNNER" __ql_release "$QUEUE_LOCK_REMOTE_QUEUE" "$QUEUE_LOCK_REMOTE_HOLDER" "$QUEUE_LOCK_REMOTE_TOKEN" >/dev/null 2>&1 || true
  QUEUE_LOCK_REMOTE_QUEUE="" QUEUE_LOCK_REMOTE_HOLDER="" QUEUE_LOCK_REMOTE_TOKEN="" QUEUE_LOCK_REMOTE_RUNNER="" QUEUE_LOCK_REMOTE_HB_PID=""
}

queue_lock_release_all() {
  queue_lock_release_remote
  queue_lock_release_local
}
