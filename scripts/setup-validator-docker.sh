#!/usr/bin/env bash
set -o pipefail
# Category: Utility
# Description: Sets up rootless Docker for the snapshot validator's drills on the Secondary VPS (or this host), through a sudo admin account, so the drill user never needs the docker group.
# Usage: ./scripts/setup-validator-docker.sh -a ADMIN [--password-stdin] [--target-host HOST] [--target-user USER] [--port PORT] [--check] [--check-git] [--remote URL] [--skip-git-check] [--remove-docker-group] [--local] [--key PATH]
# Dependencies: ssh, git, timeout, sudo (with --local); on the target: Ubuntu/Debian with Docker Engine, systemd, cgroup v2

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
PATH_TO_ODOO=$(git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$CURRENT_DIR")

# --- Logging Functions & Colors ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[0;31m"
readonly COLOR_CYAN="\033[0;36m"

log() { echo -e "${1}[$(date +"%Y-%m-%d %H:%M:%S")] ${2} ${3}${COLOR_RESET}" >&2; }
log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_warn() { log "${COLOR_WARN}" "⚠️" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }

env_get() {
  [ -f "$PATH_TO_ODOO/.env" ] || return 0
  grep "^$1=" "$PATH_TO_ODOO/.env" 2>/dev/null | tail -n1 | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//'
}

TARGET_HOST="" TARGET_USER="" TARGET_PORT="" TARGET_KEY="" ADMIN_USER="" ADMIN_PASS="" PASSWORD_STDIN=false
MODE=setup REMOVE_DOCKER_GROUP=false LOCAL=false CHECK_GIT=false CHECK_DOCKER=false SKIP_GIT_CHECK=false
CUSTOM_REMOTES=()

show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Sets up rootless Docker for the user that runs snapshot drills (SNAPSHOT_REMOTE_USER) on the Secondary VPS
(SNAPSHOT_REMOTE_HOST), through a sudo admin account on that VPS. The drill user gets its own Docker daemon
and never needs the docker group, which would be equivalent to root. Safe to run again: steps already done
are skipped. Run it from the main VPS after generate-snapshot-ssh-key.sh.

It makes sure of, on the target host:
  - Docker Engine is installed and the host uses cgroup v2
  - packages: docker-ce-rootless-extras (or rootlesskit with Ubuntu's docker.io), uidmap, dbus-user-session, slirp4netns
  - subordinate UID/GID ranges for the user (/etc/subuid, /etc/subgid)
  - an AppArmor profile that lets rootlesskit use user namespaces (Ubuntu 23.10 and later)
  - CPU, memory and process limits delegated to user services (systemd drop-in), so drills can be limited
  - lingering for the user, so its Docker keeps running without a login session
  - rootless Docker installed for the user (dockerd-rootless-setuptool.sh) and answering

Options:
  -a, --admin-user <ADMIN>   Sudo admin account on the target host (required, except with --local)
  --admin-password <PASS>    Admin password (visible to other users in ps; prefer --password-stdin)
  --password-stdin           Read the admin password from stdin
  -t, --target-host <HOST>   Secondary VPS (default: SNAPSHOT_REMOTE_HOST from .env)
  -u, --target-user <USER>   Drill user (default: SNAPSHOT_REMOTE_USER from .env)
  -p, --port <PORT>          SSH port (default: SNAPSHOT_REMOTE_PORT from .env, or 22)
  --check                    Only report what is missing; change nothing. Without -a it logs in as the drill
                             user with its snapshot key (SNAPSHOT_REMOTE_KEY), so no admin account is needed.
                             Exit code: 0 ready, 3 steps missing, 1 could not check
  --check-git                Check if the drill user (SNAPSHOT_REMOTE_USER, or current user with --local)
                             can reach/clone git remotes from git/*, odoo-base/*, and docker-odoo.
                             Can be used alone or combined with --check. (Setup mode runs this automatically.)
  --remote <URL>             Test a specific git remote URL with --check-git (can be repeated)
  --skip-git-check           Skip the automatic git access check after setup
  -i, --key <PATH>           SSH key of the drill user for --check (default: SNAPSHOT_REMOTE_KEY from .env)
  --remove-docker-group      Also remove the drill user from the docker group
  --local                    Set up this host instead (runs the steps with sudo here)
  -h, --help                 Show this help message

Examples:
  ./scripts/setup-validator-docker.sh -a sysadmin --check
  ./scripts/setup-validator-docker.sh -a sysadmin
  echo "secret" | ./scripts/setup-validator-docker.sh -a sysadmin --password-stdin
  sudo ./scripts/setup-validator-docker.sh --local -u odoo-backupper     # on the Secondary VPS itself
EOF
}

need_value() { if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then log_error "$1 needs a value."; exit 1; fi; }
while [ $# -gt 0 ]; do
  case "$1" in
    -a|--admin-user) need_value "$1" "${2:-}"; ADMIN_USER="$2"; shift 2 ;;
    --admin-user=*) ADMIN_USER="${1#*=}"; shift ;;
    --admin-password) need_value "$1" "${2:-}"; ADMIN_PASS="$2"; shift 2 ;;
    --admin-password=*) ADMIN_PASS="${1#*=}"; shift ;;
    --password-stdin) PASSWORD_STDIN=true; shift ;;
    -t|--target-host) need_value "$1" "${2:-}"; TARGET_HOST="$2"; shift 2 ;;
    --target-host=*) TARGET_HOST="${1#*=}"; shift ;;
    -u|--target-user) need_value "$1" "${2:-}"; TARGET_USER="$2"; shift 2 ;;
    --target-user=*) TARGET_USER="${1#*=}"; shift ;;
    -p|--port) need_value "$1" "${2:-}"; TARGET_PORT="$2"; shift 2 ;;
    --port=*) TARGET_PORT="${1#*=}"; shift ;;
    --check) MODE=check; CHECK_DOCKER=true; shift ;;
    --check-git) CHECK_GIT=true; shift ;;
    --remote) need_value "$1" "${2:-}"; CUSTOM_REMOTES+=("$2"); shift 2 ;;
    --skip-git-check) SKIP_GIT_CHECK=true; shift ;;
    -i|--key) need_value "$1" "${2:-}"; TARGET_KEY="$2"; shift 2 ;;
    --remove-docker-group) REMOVE_DOCKER_GROUP=true; shift ;;
    --local) LOCAL=true; shift ;;
    -h|--help) show_help; exit 0 ;;
    *) log_error "Unknown option: $1"; show_help; exit 1 ;;
  esac
done

git_redact() { sed -E 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@[:space:]]+@#\1***@#g' <<< "$1"; }
git_valid_remote() { [ -n "$1" ] && [[ "$1" != -* ]] && [[ "$1" != *[[:space:][:cntrl:]]* ]]; }

run_git_check() {
  local allow tout rhost ruser rport rkey owner owner_home this_vps clean_tgt cand
  local remotes=() ssh_opts=() remote_target="" local_user=""
  local entry label remote shown cmd ok=0 fail=0 rc_cmd
  allow="${VALIDATOR_GIT_ALLOW_PROTOCOL:-$(env_get VALIDATOR_GIT_ALLOW_PROTOCOL)}"; allow="${allow:-https:ssh}"
  tout="${VALIDATOR_GIT_TIMEOUT:-$(env_get VALIDATOR_GIT_TIMEOUT)}"; tout="${tout:-30}"

  add_repo_remote() {
    local dir="$1" lbl="$2" url
    [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || return 0
    url=$(git -C "$dir" remote get-url origin 2>/dev/null || git -C "$dir" remote -v 2>/dev/null | awk 'NR==1{print $2}')
    [ -n "$url" ] && remotes+=("$lbl|$url")
  }

  if [ ${#CUSTOM_REMOTES[@]} -gt 0 ]; then
    for cand in "${CUSTOM_REMOTES[@]}"; do remotes+=("custom|$cand"); done
  else
    for cand in "$PATH_TO_ODOO"/git/*/; do [ -d "$cand" ] && add_repo_remote "${cand%/}" "git/$(basename "${cand%/}")"; done
    for cand in "$PATH_TO_ODOO"/odoo-base/*/; do [ -d "$cand" ] && add_repo_remote "${cand%/}" "odoo-base/$(basename "${cand%/}")"; done
    add_repo_remote "$PATH_TO_ODOO" "docker-odoo"
  fi
  if [ ${#remotes[@]} -eq 0 ]; then
    log_error "No git repositories found in git/*, odoo-base/*, or $PATH_TO_ODOO (pass --remote <URL>)."
    return 3
  fi

  rhost="${TARGET_HOST:-$(env_get SNAPSHOT_REMOTE_HOST)}"
  ruser="${TARGET_USER:-$(env_get SNAPSHOT_REMOTE_USER)}"
  rport="${TARGET_PORT:-$(env_get SNAPSHOT_REMOTE_PORT)}"; rport="${rport:-22}"
  rkey="${TARGET_KEY:-$(env_get SNAPSHOT_REMOTE_KEY)}"

  if [ "$LOCAL" != true ] && [ -n "$rhost" ]; then
    [ -n "$ruser" ] || { log_error "SNAPSHOT_REMOTE_USER is required when SNAPSHOT_REMOTE_HOST is set."; return 3; }
    if [[ "$rhost" == -* || "$rhost" =~ [[:space:][:cntrl:]@] || "$ruser" == -* || "$ruser" =~ [[:space:][:cntrl:]@] ]] || ! [[ "$rport" =~ ^[0-9]{1,5}$ ]]; then
      log_error "Invalid SNAPSHOT_REMOTE_HOST/USER/PORT ('$ruser@$rhost:$rport')."; return 3
    fi
    owner=$(stat -c '%U' "$PATH_TO_ODOO" 2>/dev/null)
    owner_home=$(getent passwd "$owner" 2>/dev/null | cut -d: -f6)
    [ -d "$owner_home" ] || owner_home="$HOME"
    if [ -z "$rkey" ]; then
      this_vps=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "vps-source")
      clean_tgt=$(echo "$rhost" | sed -e 's|^.*://||' -e 's|:.*$||' -e 's|/.*$||' -e 's|[^a-zA-Z0-9._-]|_|g')
      for cand in "$owner_home/.ssh/snapshot-${this_vps}-${clean_tgt}" "$owner_home/.ssh/id_ed25519-snapshot-$(basename "$PATH_TO_ODOO")" "$owner_home/.ssh/id_ed25519_snapshot"; do
        [ -f "$cand" ] && { rkey="$cand"; break; }
      done
    fi
    rkey="${rkey/#\~/$owner_home}"
    ssh_opts=(-p "$rport" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
    [ -n "$rkey" ] && [ -f "$rkey" ] && ssh_opts+=(-i "$rkey")
    remote_target="$ruser@$rhost"
    log_info "Checking git access on Secondary VPS as $remote_target (port $rport)..."
    if ! ssh "${ssh_opts[@]}" "$remote_target" true </dev/null 2>/dev/null; then
      log_error "Cannot connect to $remote_target over SSH."; return 2
    fi
  else
    [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "$(id -un)" ] && local_user="$TARGET_USER"
    log_info "Checking git access locally as ${local_user:-$(id -un)}..."
  fi

  declare -A seen=()
  for entry in "${remotes[@]}"; do
    label="${entry%%|*}"
    remote="${entry#*|}"
    shown=$(git_redact "$remote")
    if ! git_valid_remote "$remote"; then
      log_error "[$label] Invalid remote URL: $shown"
      fail=$((fail + 1)); continue
    fi
    if [ -n "${seen[$remote]:-}" ]; then
      log_info "[$label] $shown (already checked via ${seen[$remote]})"
      continue
    fi
    seen["$remote"]="$label"

    cmd=$(printf 'GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL=%q GIT_CONFIG_NOSYSTEM=1 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15" timeout %q git ls-remote -q --heads -- %q >/dev/null 2>&1 || GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL=%q GIT_CONFIG_NOSYSTEM=1 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15" timeout %q git ls-remote -q -- %q >/dev/null 2>&1' \
      "$allow" "$tout" "$remote" "$allow" "$tout" "$remote")
    rc_cmd=0
    if [ -n "$remote_target" ]; then
      ssh "${ssh_opts[@]}" "$remote_target" "$cmd" </dev/null || rc_cmd=$?
    elif [ -n "$local_user" ]; then
      sudo -u "$local_user" -H bash -c "$cmd" || rc_cmd=$?
    else
      bash -c "$cmd" || rc_cmd=$?
    fi
    if [ "$rc_cmd" -eq 0 ]; then
      log_success "[$label] Reachable: $shown"
      ok=$((ok + 1))
    else
      log_error "[$label] Cannot reach: $shown"
      fail=$((fail + 1))
    fi
  done

  if [ "$fail" -gt 0 ]; then
    log_error "$fail remote(s) unreachable ($ok ok). Ensure the drill user has a passwordless deploy key / credentials for those repositories."
    return 1
  fi
  log_success "All $ok unique remote(s) are reachable."
  return 0
}

if [ "$CHECK_GIT" = true ] && [ "$CHECK_DOCKER" != true ] && [ -z "$ADMIN_USER" ]; then
  run_git_check
  exit $?
fi

TARGET_USER="${TARGET_USER:-$(env_get SNAPSHOT_REMOTE_USER)}"
if [ -z "$TARGET_USER" ]; then log_error "No drill user: pass --target-user or set SNAPSHOT_REMOTE_USER in .env."; exit 1; fi
if ! [[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || [ "$TARGET_USER" = root ]; then
  log_error "Invalid drill user '$TARGET_USER' (a normal account name, not root)."; exit 1
fi
if [ "$LOCAL" != true ]; then
  TARGET_HOST="${TARGET_HOST:-$(env_get SNAPSHOT_REMOTE_HOST)}"
  TARGET_PORT="${TARGET_PORT:-$(env_get SNAPSHOT_REMOTE_PORT)}"; TARGET_PORT="${TARGET_PORT:-22}"
  if [ -z "$TARGET_HOST" ]; then log_error "No Secondary VPS: pass --target-host or set SNAPSHOT_REMOTE_HOST in .env (or use --local)."; exit 1; fi
  if [ -z "$ADMIN_USER" ] && [ "$MODE" != check ]; then log_error "Pass the sudo admin account on $TARGET_HOST with -a ADMIN (or use --check to only look)."; exit 1; fi
  if [ -n "$ADMIN_USER" ] && ! [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then log_error "Invalid admin username: '$ADMIN_USER'."; exit 1; fi
  if [[ "$TARGET_HOST" == -* || "$TARGET_HOST" =~ [[:space:][:cntrl:]@] ]] || ! [[ "$TARGET_PORT" =~ ^[0-9]{1,5}$ ]]; then
    log_error "Invalid target host or port ('$TARGET_HOST:$TARGET_PORT')."; exit 1
  fi
fi

# --- What runs as root on the target host. Prints one line per step: [ok] done, [+] changed, [!] missing ---
read -r -d '' ROOT_SCRIPT << 'ROOT_EOF'
set -u
tu="$1"; mode="$2"; remove_group="$3"
say() { printf '%s\n' "$*" >&2; }
ok() { say "[ok] $*"; }
did() { say "[+] $*"; }
miss() { say "[!] $*"; MISSING=$((MISSING + 1)); }
die() { say "[-] $*"; exit 1; }
MISSING=0
[ "$(id -u)" = 0 ] || [ "$mode" = check ] || die "These steps need root (sudo)."
[[ "$tu" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [ "$tu" != root ] || die "Invalid drill user '$tu'."
id "$tu" >/dev/null 2>&1 || die "User '$tu' does not exist on $(hostname). Set up the snapshot SSH key first (./scripts/generate-snapshot-ssh-key.sh -a ADMIN)."
uid=$(id -u "$tu"); home=$(getent passwd "$tu" | cut -d: -f6)
[ -d "$home" ] || die "Home folder of '$tu' not found."
say "Host $(hostname), drill user $tu (uid $uid)$([ "$mode" = check ] && echo ', check only')"

command -v dockerd >/dev/null 2>&1 || die "Docker Engine is not installed on this host. Install it first: https://docs.docker.com/engine/install/ubuntu/"
ok "Docker Engine: $(dockerd --version 2>/dev/null | head -n1)"
[ -f /sys/fs/cgroup/cgroup.controllers ] || die "This host uses cgroup v1: rootless Docker cannot limit drills there. A host with cgroup v2 (Ubuntu 21.10 and later) is needed."
ok "cgroup v2"
command -v systemctl >/dev/null 2>&1 && command -v loginctl >/dev/null 2>&1 || die "systemd (systemctl, loginctl) is required."

# Packages: Docker's own repository has docker-ce-rootless-extras; Ubuntu's docker.io works with rootlesskit
if dpkg -s docker-ce >/dev/null 2>&1; then rl_pkg=docker-ce-rootless-extras; else rl_pkg=rootlesskit; fi
pkgs=()
for p in "$rl_pkg" uidmap dbus-user-session slirp4netns; do dpkg -s "$p" >/dev/null 2>&1 || pkgs+=("$p"); done
if [ ${#pkgs[@]} -eq 0 ]; then
  ok "Packages: $rl_pkg uidmap dbus-user-session slirp4netns"
elif [ "$mode" = check ]; then
  miss "Packages to install: ${pkgs[*]}"
else
  did "Installing ${pkgs[*]}..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${pkgs[@]}" >&2 \
    || die "apt-get install failed (for docker-ce-rootless-extras, Docker's apt repository must be configured)."
fi
setuptool=$(command -v dockerd-rootless-setuptool.sh 2>/dev/null || true)
[ -n "$setuptool" ] || for c in /usr/share/docker.io/contrib/dockerd-rootless-setuptool.sh /usr/share/doc/docker.io/contrib/dockerd-rootless-setuptool.sh; do
  [ -x "$c" ] && { setuptool="$c"; break; }
done
if [ -z "$setuptool" ]; then
  [ "$mode" = check ] && miss "dockerd-rootless-setuptool.sh not found yet (comes with the packages)" || die "dockerd-rootless-setuptool.sh not found after installing the packages."
fi

# Subordinate UID/GID ranges: a free block of 65536 after the highest one in use
for kind in uid gid; do
  f="/etc/sub$kind"
  if grep -q "^$tu:" "$f" 2>/dev/null || grep -q "^$uid:" "$f" 2>/dev/null; then
    ok "$f has a range for $tu"
  elif [ "$mode" = check ]; then
    miss "$f has no range for $tu"
  else
    start=$(awk -F: '{e = $2 + $3; if (e > m) m = e} END {print (m < 100000 ? 100000 : m)}' "$f" 2>/dev/null)
    usermod "--add-sub${kind}s" "$start-$((start + 65535))" "$tu" || die "usermod --add-sub${kind}s failed."
    did "$f: $tu gets $start-$((start + 65535))"
  fi
done

# AppArmor: Ubuntu 23.10+ blocks unprivileged user namespaces unless a profile allows them.
# Exactly ONE enabled profile may attach to rootlesskit: two (e.g. Ubuntu's own
# /etc/apparmor.d/rootlesskit plus one from Docker's hint) make AppArmor refuse to run it at all.
# Read the kernel switch directly (rootlesskit does the same) and name the real binary, not a symlink.
aa_restrict=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)
aa_dir=/etc/apparmor.d
aa_kprof=/sys/kernel/security/apparmor/profiles
rk="" prof="" ours_marker="Written by docker-odoo setup-validator-docker.sh"
aa_enabled() { [ -f "$1" ] && [ ! -e "$aa_dir/disable/$(basename "$1")" ]; }
# Profile files (top level, enabled) whose header attaches to $rk
aa_attaching() {
  local f re
  re=$(printf '%s' "$rk" | sed 's/[.[\*^$()+?{|]/\\&/g')
  for f in "$aa_dir"/*; do
    aa_enabled "$f" || continue
    grep -qsE "^[[:space:]]*(profile[[:space:]]+[^[:space:]]+[[:space:]]+)?\"?$re\"?([[:space:]]|\{|$)" "$f" && echo "$f"
  done
}
# Name the kernel lists a profile file under: "profile NAME ..." or else the attached path
aa_name() {
  local h
  h=$(grep -m1 -E "^[[:space:]]*(profile[[:space:]]+[^[:space:]]+[[:space:]]+)?\"?/" "$1" | sed 's/^[[:space:]]*//')
  case "$h" in profile\ *) set -- $h; printf '%s' "${2//\"/}" ;; *) set -- $h; printf '%s' "${1//\"/}" ;; esac
}
aa_is_loaded() { awk -v n="$1 (" 'index($0, n) == 1 { f = 1 } END { exit !f }' "$aa_kprof" 2>/dev/null; }
# Our old profile can stay loaded in the kernel after its file is gone (it still clashes)
aa_stale() { [ -n "$aa_keep" ] && [ "$(aa_name "$aa_keep")" != "$rk" ] && [ ! -f "$prof" ] && aa_is_loaded "$rk"; }
aa_diag() {
  say "    kernel.apparmor_restrict_unprivileged_userns = $aa_restrict"
  say "    rootlesskit binary: ${rk:-not found}"
  say "    profiles attaching to it: $(aa_attaching | tr '\n' ' ')"
  say "    loaded in the kernel: $(grep -iF rootlesskit "$aa_kprof" 2>/dev/null | tr '\n' ' ' || echo 'none')"
  say "    kernel log (AppArmor, last lines):"
  { journalctl -k --no-pager -n 300 2>/dev/null || dmesg 2>/dev/null; } | grep -iE 'apparmor=.*(rootlesskit|userns)|conflicting profile' | tail -n 5 | sed 's/^/      /' >&2
}
if [ "$aa_restrict" = 1 ]; then
  rk=$(command -v rootlesskit 2>/dev/null || true)
  if [ -z "$rk" ]; then
    [ "$mode" = check ] && miss "AppArmor profile for rootlesskit (after the packages are installed)" \
      || die "rootlesskit is not installed, so its AppArmor profile cannot be set up."
  else
    rk=$(readlink -f "$rk")
    prof="$aa_dir/$(printf '%s' "${rk#/}" | tr / .)"
    mapfile -t aa_files < <(aa_attaching)
    # A profile that came with the system (Ubuntu's apparmor package) wins over ours
    aa_keep=""
    for f in "${aa_files[@]}"; do [ "$f" != "$prof" ] && grep -q 'userns' "$f" && { aa_keep="$f"; break; }; done
    if [ -z "$aa_keep" ] && [ -f "$prof" ] && grep -q userns "$prof" && aa_enabled "$prof"; then aa_keep="$prof"; fi
    aa_extra=(); for f in "${aa_files[@]}"; do [ "$f" != "$aa_keep" ] && aa_extra+=("$f"); done
    if [ -n "$aa_keep" ] && [ ${#aa_extra[@]} -eq 0 ] && { [ "$(id -u)" != 0 ] || { aa_is_loaded "$(aa_name "$aa_keep")" && ! aa_stale; }; }; then
      ok "AppArmor allows user namespaces for $rk ($aa_keep)"
    elif [ "$mode" = check ]; then
      if [ ${#aa_extra[@]} -gt 0 ] || aa_stale; then miss "More than one AppArmor profile attaches to $rk (${aa_files[*]}): AppArmor then refuses to run it"
      elif [ -n "$aa_keep" ]; then miss "AppArmor profile $aa_keep is not loaded"
      else miss "AppArmor profile $prof (user namespaces for rootlesskit)"; fi
    else
      # Take duplicates out: ours are removed, anything else is disabled (reversible) and named
      for f in "${aa_extra[@]}"; do
        apparmor_parser -R "$f" >/dev/null 2>&1
        if grep -qF "$ours_marker" "$f"; then
          rm -f "$f"; did "Removed duplicate AppArmor profile $f (written by an earlier run; $aa_keep already covers rootlesskit)"
        else
          mkdir -p "$aa_dir/disable" && ln -sf "$f" "$aa_dir/disable/$(basename "$f")"
          did "Disabled duplicate AppArmor profile $f ($aa_keep already covers rootlesskit). Undo: sudo rm $aa_dir/disable/$(basename "$f") && sudo apparmor_parser -r $f"
        fi
      done
      if aa_stale; then
        printf '%s' "$rk" > "${aa_kprof%/profiles}/.remove" 2>/dev/null && did "Unloaded a leftover AppArmor profile '$rk' (its file was already gone)"
      fi
      if [ -z "$aa_keep" ]; then
        cat > "$prof" << PROF
# $ours_marker: lets rootless Docker create user namespaces
# ref: https://ubuntu.com/blog/ubuntu-23-10-restricted-unprivileged-user-namespaces
abi <abi/4.0>,
include <tunables/global>

"$rk" flags=(unconfined) {
  userns,

  include if exists <local/$(basename "$prof")>
}
PROF
        aa_keep="$prof"; did "Wrote AppArmor profile $prof"
      fi
      apparmor_parser -r "$aa_keep" >&2 || say "[i] apparmor_parser -r $aa_keep failed; restarting AppArmor instead"
      aa_is_loaded "$(aa_name "$aa_keep")" || systemctl restart apparmor.service >&2
      if ! aa_is_loaded "$(aa_name "$aa_keep")"; then
        say "[-] The AppArmor profile for rootlesskit ($aa_keep) is not loaded, so rootless Docker cannot start:"
        aa_diag; exit 1
      fi
      ok "AppArmor: $aa_keep lets $rk create user namespaces (the only profile for it)"
    fi
  fi
else
  ok "AppArmor does not restrict user namespaces here"
fi

# Limits for user services: without cpu/memory/pids delegation, drills could not be limited
dropin=/etc/systemd/system/user@.service.d/delegate.conf
if grep -qs '^Delegate=.*\bcpu\b' "$dropin" && grep -qs '^Delegate=.*\bmemory\b' "$dropin" && grep -qs '^Delegate=.*\bpids\b' "$dropin"; then
  ok "CPU, memory and process limits delegated ($dropin)"
elif [ "$mode" = check ]; then
  miss "Limits not delegated to user services ($dropin)"
else
  mkdir -p "$(dirname "$dropin")"
  printf '# Written by docker-odoo setup-validator-docker.sh: lets rootless Docker limit CPU, memory and processes\n[Service]\nDelegate=cpu cpuset io memory pids\n' > "$dropin"
  systemctl daemon-reload
  did "Delegated CPU, memory and process limits ($dropin)"
fi

if [ -e "/var/lib/systemd/linger/$tu" ]; then
  ok "Lingering on for $tu"
elif [ "$mode" = check ]; then
  miss "Lingering off for $tu (its Docker would stop without a login session)"
else
  loginctl enable-linger "$tu" || die "loginctl enable-linger failed."
  did "Lingering on for $tu"
fi

if id -nG "$tu" | tr ' ' '\n' | grep -qx docker; then
  if [ "$remove_group" = true ] && [ "$mode" != check ]; then
    gpasswd -d "$tu" docker >/dev/null && did "Removed $tu from the docker group"
  else
    say "[!] $tu is in the docker group, which is equivalent to root on this host. Remove it with --remove-docker-group (or: sudo gpasswd -d $tu docker)."
  fi
fi

if [ "$mode" = check ]; then
  rt="/run/user/$uid"
  if [ ! -f "$home/.config/systemd/user/docker.service" ]; then
    miss "Rootless Docker not set up for $tu yet"
  else
    ok "Rootless Docker set up for $tu"
    if [ "$(id -u)" = "$uid" ]; then sec=$(docker -H "unix://$rt/docker.sock" info -f '{{json .SecurityOptions}}' 2>/dev/null)
    elif [ "$(id -u)" = 0 ]; then sec=$(runuser -u "$tu" -- env -i HOME="$home" PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" docker -H "unix://$rt/docker.sock" info -f '{{json .SecurityOptions}}' 2>/dev/null)
    else sec="rootless(not checked)"; fi
    [[ "$sec" == *rootless* ]] && ok "Rootless Docker for $tu is answering" || miss "Rootless Docker for $tu is not running (systemctl --user status docker)"
    ctl="/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers"
    if [ -f "$ctl" ]; then
      for c in cpu memory pids; do grep -qw "$c" "$ctl" || miss "Limit '$c' not yet active for $tu's services (restart user@$uid.service or reboot)"; done
    fi
  fi
  if [ "$MISSING" -eq 0 ]; then say "Nothing missing: $tu can run snapshot drills."; exit 0; fi
  say "$MISSING step(s) missing."
  exit 3
fi

# The user's systemd: start it, and restart it when the delegated limits are not active yet
# (a drop-in only applies to a freshly started user manager). Never while a drill is running.
rt="/run/user/$uid"
ctl="/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers"
limits_active() { local c; for c in cpu memory pids; do grep -qw "$c" "$ctl" 2>/dev/null || return 1; done; }
if systemctl is-active -q "user@$uid.service" && ! limits_active; then
  busy=""
  for m in /tmp/odoo-snapshot-validator.queue.active.*; do
    [ -f "$m" ] && [ $(( $(date +%s) - $(stat -c %Y "$m") )) -lt 600 ] && busy=yes
  done
  if [ -n "$busy" ]; then
    say "[!] A drill is running, so $tu's services were not restarted: the new limits apply after it ends. Run this again then."
  else
    systemctl restart "user@$uid.service" && did "Restarted $tu's user services so the limits apply"
  fi
fi
systemctl start "user@$uid.service" 2>/dev/null
for i in $(seq 20); do [ -S "$rt/bus" ] && break; sleep 0.5; done
[ -S "$rt/bus" ] || die "The user services of $tu did not start ($rt/bus missing)."
asu() {
  runuser -u "$tu" -- env -i HOME="$home" USER="$tu" LOGNAME="$tu" \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$(dirname "$setuptool")" \
    XDG_RUNTIME_DIR="$rt" DBUS_SESSION_BUS_ADDRESS="unix:path=$rt/bus" "$@"
}
limits_active || die "CPU, memory and process limits are not active for $tu's services yet ($ctl: $(cat "$ctl" 2>/dev/null)). Run this again when no drill is running, or reboot."
ok "$tu's services can limit cpu, memory and pids"

# Prove that the drill user can create a user namespace with rootlesskit before the setup tool runs
rk_bin=$(readlink -f "$(command -v rootlesskit 2>/dev/null)" 2>/dev/null)
if [ -n "$rk_bin" ]; then
  if rk_out=$(cd / && asu "$rk_bin" --net=host true 2>&1); then
    ok "rootlesskit works for $tu"
  else
    say "[-] rootlesskit cannot start for $tu, so rootless Docker cannot either:"
    printf '%s\n' "$rk_out" | tail -n 5 | sed 's/^/    /' >&2
    rk="$rk_bin"; aa_diag
    exit 1
  fi
fi
if [ -f "$home/.config/systemd/user/docker.service" ]; then
  ok "Rootless Docker already set up for $tu"
  asu systemctl --user enable --now docker.service >/dev/null 2>&1
else
  did "Setting up rootless Docker for $tu (dockerd-rootless-setuptool.sh install)..."
  asu "$setuptool" install >&2 || die "dockerd-rootless-setuptool.sh install failed (see above)."
fi
for i in $(seq 40); do [ -S "$rt/docker.sock" ] && break; sleep 0.5; done
sec=$(asu docker -H "unix://$rt/docker.sock" info -f '{{json .SecurityOptions}}' 2>/dev/null)
[[ "$sec" == *rootless* ]] || die "Rootless Docker for $tu is not answering on $rt/docker.sock. Check: sudo -iu $tu systemctl --user status docker"
ok "Rootless Docker for $tu answers on $rt/docker.sock ($(asu docker -H "unix://$rt/docker.sock" info -f '{{.DockerRootDir}}' 2>/dev/null))"
command -v logger >/dev/null 2>&1 && logger -t docker-odoo "rootless Docker set up for $tu (snapshot validator)" 2>/dev/null
say "[SUCCESS] $tu can run snapshot drills with rootless Docker."
ROOT_EOF

ARGS=("$TARGET_USER" "$MODE" "$REMOVE_DOCKER_GROUP")
if [ "$LOCAL" = true ]; then
  log_info "$([ "$MODE" = check ] && echo Checking || echo Setting up) rootless Docker for $TARGET_USER on this host..."
  if [ "$(id -u)" = 0 ]; then bash -c "$ROOT_SCRIPT" -- "${ARGS[@]}"; else sudo bash -c "$ROOT_SCRIPT" -- "${ARGS[@]}"; fi
  rc=$?
elif [ "$MODE" = check ] && [ -z "$ADMIN_USER" ]; then
  # Read-only check as the drill user itself, with its snapshot key: no admin account or password needed
  TARGET_KEY="${TARGET_KEY:-$(env_get SNAPSHOT_REMOTE_KEY)}"
  TARGET_KEY="${TARGET_KEY/#\~/$HOME}"
  key_opts=()
  [ -n "$TARGET_KEY" ] && [ -f "$TARGET_KEY" ] && key_opts=(-i "$TARGET_KEY")
  log_info "Checking rootless Docker for $TARGET_USER on $TARGET_HOST (as $TARGET_USER, read-only)..."
  ssh -p "$TARGET_PORT" "${key_opts[@]}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 \
    "${TARGET_USER}@${TARGET_HOST}" "bash -c $(printf '%q' "$ROOT_SCRIPT") --$(printf ' %q' "${ARGS[@]}")" </dev/null
  rc=$?
  [ "$rc" = 255 ] && log_error "Cannot log in as $TARGET_USER@$TARGET_HOST:$TARGET_PORT with its key (set up the snapshot key first: ./scripts/generate-snapshot-ssh-key.sh -a ADMIN)."
else
  if [ "$PASSWORD_STDIN" = true ] || { [ ! -t 0 ] && [ -z "$ADMIN_PASS" ]; }; then
    read -r ADMIN_PASS || true
  elif [ -z "$ADMIN_PASS" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
    ADMIN_PASS="$ADMIN_PASSWORD"
  elif [ -z "$ADMIN_PASS" ]; then
    echo -ne "${COLOR_CYAN}Enter password for admin user '${ADMIN_USER}@${TARGET_HOST}': ${COLOR_RESET}" >&2
    read -s -r ADMIN_PASS; echo "" >&2
  fi
  [ -n "$ADMIN_PASS" ] || { log_error "No admin password given."; exit 1; }
  log_info "$([ "$MODE" = check ] && echo Checking || echo Setting up) rootless Docker for $TARGET_USER on $TARGET_HOST (as $ADMIN_USER with sudo)..."
  remote_cmd="sudo -S -p '' bash -c $(printf '%q' "$ROOT_SCRIPT") --$(printf ' %q' "${ARGS[@]}")"
  askpass=$(umask 077; mktemp) || exit 1
  printf '#!/bin/sh\nprintf "%%s\\n" "$_SSH_ADMIN_PASS"\n' > "$askpass"; chmod 700 "$askpass"
  # The password reaches ssh (askpass) and sudo -S (stdin) only through the environment and stdin
  printf '%s\n' "$ADMIN_PASS" | _SSH_ADMIN_PASS="$ADMIN_PASS" SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$askpass" DISPLAY="${DISPLAY:-:0}" \
    ssh -p "$TARGET_PORT" -o StrictHostKeyChecking=accept-new -o BatchMode=no -o ConnectTimeout=20 \
    "${ADMIN_USER}@${TARGET_HOST}" "$remote_cmd"
  rc=$?
  rm -f "$askpass"
fi

if [ "$MODE" = check ]; then
  case "$rc" in
    0)
      log_success "Rootless Docker is ready for $TARGET_USER: snapshot drills can run."
      if [ "$CHECK_GIT" = true ]; then run_git_check; exit $?; fi
      exit 0 ;;
    3) log_warn "Some steps are missing (marked [!]). Set them up with: ./scripts/setup-validator-docker.sh -a <sudo-admin>"; exit 3 ;;
    *) log_error "Could not check (exit $rc)."; exit 1 ;;
  esac
fi
if [ "$rc" = 255 ] && [ "$LOCAL" != true ]; then
  log_error "Could not log in as $ADMIN_USER@$TARGET_HOST:$TARGET_PORT (wrong password, password login disabled, or host unreachable). Nothing was changed."
  exit 1
elif [ "$rc" -ne 0 ]; then
  log_error "Setup did not finish (exit $rc). Fix the step marked [-] above and run this again; finished steps are skipped."
  exit 1
else
  log_success "Rootless Docker is ready for $TARGET_USER."
  if [ "$SKIP_GIT_CHECK" != true ]; then
    if ! run_git_check; then
      log_error "Rootless Docker is ready, but git access failed for $TARGET_USER. Configure a passwordless deploy key / credentials for $TARGET_USER before running validate-snapshot.sh."
      exit 1
    fi
  fi
  log_success "Validator host is ready for $TARGET_USER. Next: ./scripts/validate-snapshot.sh --drive <service>"
fi
