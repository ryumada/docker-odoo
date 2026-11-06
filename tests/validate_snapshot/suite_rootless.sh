#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: Rootless Docker on the drill host for validate-snapshot.sh: finding a user's own Docker socket, and every incomplete setup stopping the drill with the command that fixes it.
# Usage: sourced by tests/test_validate_snapshot.sh (suite "rootless"); needs tests/validate_snapshot/lib.sh
# Dependencies: lib.sh, mkfixture.sh, fake docker/df, PostgreSQL server binaries
#
# Runs as a normal user only (as root the validator uses the system Docker). The suite "local" covers
# rootless Docker with and without delegated limits and the docker-group warning; this one covers the
# rest of the checks: HOME=$T/home and XDG_RUNTIME_DIR=$T/run stand in for the drill user's account.

suite_rootless() {
  # shellcheck disable=SC2034
  TVS_SUITE=rootless
  local good run="$T/run" bin="$T/rootless-bin" unit="$T/home/.config/systemd/user/docker.service" t0 t1

  tvs_section "rootless: Docker for a normal drill user"
  if [ "$(id -u)" = 0 ]; then
    skip "rootless suite" "run the tests as a normal user (root uses the system Docker)"
    return 0
  fi
  mkdir -p "$run" "$bin" && chmod 700 "$run"
  echo "cpuset cpu io memory pids" > "$T/cgroup-delegated"
  good=$(fx good)
  # dockerd-rootless.sh present = the rootless package is installed; its own PATH so other suites never see it
  printf '#!/bin/sh\nexit 0\n' > "$bin/dockerd-rootless.sh" && chmod 755 "$bin/dockerd-rootless.sh"
  local pkg_path="PATH=$bin:$T/fakebin:$T/cbin:$TVS_ORIG_PATH"

  vs rl-notinstalled FAKE_DOCKER_DOWN=1 XDG_RUNTIME_DIR="$run" -- --file "$good"
  check_rc "no Docker for this user" 3
  if command -v dockerd-rootless.sh >/dev/null 2>&1 || command -v rootlesskit >/dev/null 2>&1; then
    # rootless Docker is really installed on this machine (in /usr/bin, which the validator needs)
    check_grep "says rootless Docker is installed but not set up for this user" "$VS_LOG" "installed on this host but not set up"
  else
    check_grep "says rootless Docker is not installed" "$VS_LOG" "rootless Docker is not installed"
  fi
  check_grep "gives the one command for the main VPS" "$VS_LOG" "setup-validator-docker.sh -a <sudo-admin"
  check_grep "and the one for this host" "$VS_LOG" "setup-validator-docker.sh --local -u"
  check_no_grep "never suggests the docker group" "$VS_LOG" "add the user to the docker group"

  vs rl-notsetup FAKE_DOCKER_DOWN=1 XDG_RUNTIME_DIR="$run" "$pkg_path" -- --file "$good"
  check_rc "package installed, setup tool never run" 3
  check_grep "says it is installed but not set up" "$VS_LOG" "installed on this host but not set up"

  mkdir -p "$(dirname "$unit")" && : > "$unit"
  t0=$(date +%s)
  vs rl-notrunning FAKE_DOCKER_DOWN=1 XDG_RUNTIME_DIR="$run" VALIDATOR_DOCKER_START_WAIT=2 "$pkg_path" -- --file "$good"
  t1=$(date +%s)
  check_rc "set up, but its daemon is not running" 3
  check "waits for a daemon that is still starting" test $((t1 - t0)) -ge 2
  check_grep "names the missing socket" "$VS_LOG" "$run/docker.sock is missing"
  check_grep "gives the command that starts it" "$VS_LOG" "systemctl --user enable --now docker"

  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$run/docker.sock"
  vs rl-socket FAKE_DOCKER_HOST_ONLY="unix://$run/docker.sock" FAKE_DOCKER_ROOTLESS=1 \
     VALIDATOR_TEST_CGROUP_FILE="$T/cgroup-delegated" XDG_RUNTIME_DIR="$run" -- --file "$good"
  check_rc "the user's own rootless socket is found without DOCKER_HOST" 0
  check_grep "lingering off: warned, with the fix" "$VS_LOG" "Lingering is off"
  check_no_grep "no docker-group warning for rootless Docker" "$VS_LOG" "docker group"

  vs rl-deadhost DOCKER_HOST="unix://$T/nothing-here.sock" FAKE_DOCKER_HOST_ONLY="unix://$run/docker.sock" -- --file "$good"
  check_rc "DOCKER_HOST set, nothing answers" 3
  check_grep "names the DOCKER_HOST that does not answer" "$VS_LOG" "Docker at unix://$T/nothing-here.sock is not answering"
  rm -f "$run/docker.sock" "$unit"
}
