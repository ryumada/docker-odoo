#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: scripts/setup-validator-docker.sh: argument checks, and its drill-host steps in --check mode with every system path moved into the test folder and system commands stubbed.
# Usage: sourced by tests/test_validate_snapshot.sh (suite "setup"); needs tests/validate_snapshot/lib.sh
# Dependencies: lib.sh, awk, sed
#
# The steps the script runs on the drill host are taken from the script itself, with /etc, /proc, /sys,
# /run/user, /var/lib/systemd and /tmp moved into $T/svd and the commands it uses (apt-get, dpkg,
# systemctl, loginctl, usermod, apparmor_parser, rootlesskit, docker...) replaced by stubs. Only the
# current account (id, home folder) is read for real; nothing outside the test folder is written.
# Setup mode changes a real account, so it is left to a test VPS (--local -u <spare account>).

suite_setup() {
  # shellcheck disable=SC2034
  TVS_SUITE=setup
  local SV="$T/app/scripts/setup-validator-docker.sh" V="$T/svd" out rc me uid
  local CTL KP RK AD
  me=$(id -un); uid=$(id -u)

  tvs_section "setup: arguments (nothing connects anywhere)"
  printf 'SNAPSHOT_REMOTE_HOST=\nSNAPSHOT_REMOTE_USER=\n' > "$T/app/.env"
  out=$(bash "$SV" -a admin 2>&1); rc=$?
  check_eq "no drill user: refused (exit 1)" 1 "$rc"; check "and says so" grep -q "No drill user" <<< "$out"
  out=$(bash "$SV" -a admin -u root -t 10.0.0.1 2>&1); rc=$?
  check_eq "drill user root: refused" 1 "$rc"; check "and says it must not be root" grep -q "not root" <<< "$out"
  out=$(bash "$SV" -u drill -t 10.0.0.1 2>&1); rc=$?
  check_eq "setup without an admin account: refused" 1 "$rc"; check "and points to --check" grep -q "use --check" <<< "$out"
  out=$(bash "$SV" -a 'bad;admin' -u drill -t 10.0.0.1 2>&1); rc=$?
  check_eq "admin name with shell characters: refused" 1 "$rc"
  out=$(bash "$SV" -a admin -u drill -t '-oProxyCommand=x' 2>&1); rc=$?
  check_eq "host that looks like an ssh option: refused" 1 "$rc"
  : > "$T/app/.env"

  tvs_section "setup: drill-host steps (--check, stubbed system)"
  if [ "$uid" = 0 ]; then
    skip "drill-host steps" "run the tests as a normal user (the current user plays the drill user, and root is refused)"
    return 0
  fi
  CTL="$V/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers"
  KP="$V/sys/kernel/security/apparmor/profiles"; RK="$V/stub/real/rootlesskit"; AD="$V/etc/apparmor.d"
  mkdir -p "$V/stub/real" "$AD" "$V/etc/systemd/system/user@.service.d" "$V/linger" "$V/run/user/$uid" "$V/tmp" \
           "$V/proc/sys/kernel" "$V/sys/kernel/security/apparmor" "$(dirname "$CTL")"
  : > "$V/sys/fs/cgroup/cgroup.controllers"; echo 1 > "$V/proc/sys/kernel/apparmor_restrict_unprivileged_userns"
  printf '#!/usr/bin/env bash\n[ "$1" = -s ] && grep -qx "$2" %q\n' "$V/pkgs" > "$V/stub/dpkg"
  printf '#!/usr/bin/env bash\necho "Docker version 29.0.0, build test"\n' > "$V/stub/dockerd"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$V/stub/dockerd-rootless-setuptool.sh"
  for c in apt-get loginctl usermod gpasswd logger apparmor_parser; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> %q\n' "$c" "$V/changes.log" > "$V/stub/$c"
  done
  printf '#!/usr/bin/env bash\n[ "$1" = is-active ] && exit 1\nexit 0\n' > "$V/stub/systemctl"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$RK"; ln -sf real/rootlesskit "$V/stub/rootlesskit"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$V/stub/docker"
  chmod 755 "$V"/stub/* "$RK"
  # the steps, taken from the script, with the system paths redirected
  awk "/^read -r -d '' ROOT_SCRIPT/{f=1;next} /^ROOT_EOF/{f=0} f" "$SV" | sed \
    -e "s#/sys/fs/cgroup#$V/sys/fs/cgroup#g" -e "s#/sys/kernel/security#$V/sys/kernel/security#g" \
    -e "s#/proc/sys/kernel#$V/proc/sys/kernel#g" -e "s#/etc/subuid#$V/etc/subuid#g; s#/etc/sub\$kind#$V/etc/sub\$kind#g" \
    -e "s#/etc/apparmor.d#$AD#g" -e "s#/etc/systemd/system#$V/etc/systemd/system#g" \
    -e "s#/var/lib/systemd/linger#$V/linger#g" -e "s#/run/user/#$V/run/user/#g" \
    -e "s#/tmp/odoo-snapshot-validator#$V/tmp/odoo-snapshot-validator#g" \
    -e "s#PATH=\"/usr/local/sbin:#PATH=\"$V/stub:/usr/local/sbin:#g" > "$V/steps.sh"
  if grep -v '^[[:space:]]*#' "$V/steps.sh" | grep -v -F "$V" | grep -qE '/(etc/(sub|apparmor|systemd)|proc/sys|sys/(fs|kernel)|var/lib/systemd|run/user)'; then
    fail "every system path of the drill-host steps is redirected" "a path in setup-validator-docker.sh is not covered; the steps were not run"
    return 0
  fi
  pass "every system path of the drill-host steps is redirected"
  steps() { PATH="$V/stub:$PATH" bash "$V/steps.sh" "$me" check false 2>&1; }

  : > "$V/pkgs"; : > "$V/etc/subuid"; : > "$V/etc/subgid"; : > "$KP"; echo "memory pids" > "$CTL"
  out=$(steps); rc=$?
  check_eq "--check on a bare host: exit 3" 3 "$rc"
  check "lists every missing step (at least 7)" test "$(grep -c '^\[!\]' <<< "$out")" -ge 7
  check_not "--check changes nothing" test -s "$V/changes.log"

  printf 'docker-ce\ndocker-ce-rootless-extras\nuidmap\ndbus-user-session\nslirp4netns\n' > "$V/pkgs"
  echo "$me:100000:65536" > "$V/etc/subuid"; echo "$me:100000:65536" > "$V/etc/subgid"
  printf '[Service]\nDelegate=cpu cpuset io memory pids\n' > "$V/etc/systemd/system/user@.service.d/delegate.conf"
  touch "$V/linger/$me"; echo "cpuset cpu io memory pids" > "$CTL"
  printf 'abi <abi/4.0>,\ninclude <tunables/global>\n\nprofile rootlesskit %s flags=(unconfined) {\n  userns,\n}\n' "$RK" > "$AD/rootlesskit"
  echo "rootlesskit (unconfined)" > "$KP"
  out=$(steps)
  # whether rootless Docker itself is set up depends on this machine's account, so it is not asserted
  check "prepared host: packages ok" grep -q '^\[ok\] Packages' <<< "$out"
  check "prepared host: subordinate ID ranges ok" grep -q '^\[ok\] .*subuid has a range' <<< "$out"
  check "prepared host: Ubuntu's own AppArmor profile accepted" grep -q '^\[ok\] AppArmor allows user namespaces' <<< "$out"
  check "prepared host: limits delegated" grep -q '^\[ok\] CPU, memory and process limits delegated' <<< "$out"
  check "prepared host: lingering on" grep -q '^\[ok\] Lingering on' <<< "$out"

  # Ubuntu's own rootlesskit profile plus a second one: AppArmor would refuse to run rootlesskit
  printf '# Written by docker-odoo setup-validator-docker.sh: test\nabi <abi/4.0>,\n\n"%s" flags=(unconfined) {\n  userns,\n}\n' "$RK" > "$AD/$(printf '%s' "${RK#/}" | tr / .)"
  out=$(steps); rc=$?
  check_eq "two AppArmor profiles for rootlesskit: --check exit 3" 3 "$rc"
  check "and reports the clash" grep -q 'More than one AppArmor profile attaches' <<< "$out"
  rm -f "$AD/$(printf '%s' "${RK#/}" | tr / .)"
  echo 0 > "$V/proc/sys/kernel/apparmor_restrict_unprivileged_userns"
  out=$(steps)
  check "AppArmor not restricting user namespaces: no profile needed" grep -q '^\[ok\] AppArmor does not restrict' <<< "$out"
  skip "setup mode of setup-validator-docker.sh" "it changes a real account: try it on a test VPS (--local -u <spare account>)"
}
