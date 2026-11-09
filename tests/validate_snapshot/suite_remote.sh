#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: Remote mode of validate-snapshot.sh against a private sshd on 127.0.0.1 playing the Secondary VPS.
# Usage: sourced by tests/test_validate_snapshot.sh (suite "remote"); needs tests/validate_snapshot/lib.sh
# Dependencies: lib.sh, mkfixture.sh, mock_drive.py, ssh, sshd, ssh-keygen, fake docker/df/gcloud, PostgreSQL server binaries
#
# The sshd uses only files in the test folder (HostKey, AuthorizedKeysFile, PidFile, StrictModes no,
# UsePAM no, PermitUserRC no) and a ForceCommand wrapper that loads the "Secondary VPS" environment:
# HOME=$T/rhome, the fake docker/gcloud on PATH, its own QUEUE_LOCK_DIR ($T/rlocks) and Docker state
# ($T/dr). The client side uses an ssh wrapper that adds -F $T/ssh/client_config (own known_hosts,
# key, no agent), so ~/.ssh is never read or written. If the login does not work here (for example a
# locked root account with UsePAM no), the suite is skipped with the reason.

remote_setup() {
  # Prints a skip reason and returns 1 when this host cannot run the suite
  local sshd real_ssh keygen user port
  real_ssh=$(PATH="$TVS_ORIG_PATH" command -v ssh)
  keygen=$(PATH="$TVS_ORIG_PATH" command -v ssh-keygen)
  sshd=$(PATH="$TVS_ORIG_PATH:/usr/sbin:/sbin:/usr/local/sbin" command -v sshd)
  [ -n "$real_ssh" ] && [ -n "$keygen" ] && [ -n "$sshd" ] || { echo "ssh, ssh-keygen and sshd are needed"; return 1; }
  sshd=$(readlink -f "$sshd")
  user=$(id -un)
  RUSER="$user"
  mkdir -p "$T/ssh" "$T/rhome/snapshots" "$T/rlocks" "$T/rtmp" "$T/dr" || return 1
  chmod 700 "$T/ssh"; chmod 711 "$T/dr"
  "$keygen" -q -t ed25519 -N '' -C tvs-host -f "$T/ssh/host_key" || { echo "ssh-keygen failed"; return 1; }
  "$keygen" -q -t ed25519 -N '' -C tvs-client -f "$T/ssh/client_key" || { echo "ssh-keygen failed"; return 1; }
  echo "restrict $(cat "$T/ssh/client_key.pub")" > "$T/ssh/authorized_keys"
  chmod 600 "$T/ssh/authorized_keys"

  cat > "$T/ssh/forcecommand.sh" <<EOF
#!/usr/bin/env bash
# The "Secondary VPS" environment for every SSH command of the tests
export HOME="$T/rhome" TMPDIR="$T/rtmp" QUEUE_LOCK_DIR="$T/rlocks" QUEUE_LOCK_HEARTBEAT=1 QUEUE_LOCK_POLL_INTERVAL=1
export PATH="$T/fakebin:$TVS_ORIG_PATH" FAKE_DOCKER_STATE="$T/dr" FAKE_GCS_ROOT="$T/gcs"
export PG_BIN="$TVS_PG_BIN" FAKE_PG_USER="$TVS_PG_USER" LANG=C.UTF-8 NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
set -a; [ -f "$T/remote.env" ] && . "$T/remote.env"; set +a
printf '%s\n' "\${SSH_ORIGINAL_COMMAND:0:80}" >> "$T/ssh/commands.log"
cd "\$HOME" || exit 1
exec bash -c "\$SSH_ORIGINAL_COMMAND"
EOF
  chmod 755 "$T/ssh/forcecommand.sh"

  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
  RPORT="$port"
  cat > "$T/ssh/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $T/ssh/host_key
AuthorizedKeysFile $T/ssh/authorized_keys
PidFile $T/ssh/sshd.pid
StrictModes no
UsePAM no
PermitUserRC no
PermitUserEnvironment no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
AllowUsers $user
AllowTcpForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTTY no
ForceCommand $T/ssh/forcecommand.sh
LogLevel VERBOSE
EOF
  cat > "$T/ssh/client_config" <<EOF
Host *
  IdentityFile $T/ssh/client_key
  IdentitiesOnly yes
  IdentityAgent none
  UserKnownHostsFile $T/ssh/known_hosts
  GlobalKnownHostsFile /dev/null
  CheckHostIP no
  UpdateHostKeys no
  ControlMaster no
  ControlPath none
  LogLevel ERROR
EOF
  cat > "$T/cbin/ssh" <<EOF
#!/usr/bin/env bash
# Test ssh: only the test's own config, keys and known_hosts (never ~/.ssh)
printf '%s\n' "\$*" >> "$T/ssh/client_calls.log"
exec "$real_ssh" -F "$T/ssh/client_config" "\$@"
EOF
  chmod 755 "$T/cbin/ssh"

  local err
  if ! err=$("$sshd" -t -f "$T/ssh/sshd_config" 2>&1); then echo "sshd rejects the test config: $err"; return 1; fi
  "$sshd" -D -e -f "$T/ssh/sshd_config" -E "$T/ssh/sshd.log" </dev/null >/dev/null 2>&1 &
  TVS_SSHD_PID=$!
  for _ in $(seq 50); do
    python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.5).close()' "$port" 2>/dev/null && break
    sleep 0.2
  done
  if ! timeout 20 "$T/cbin/ssh" -p "$port" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$user@127.0.0.1" true </dev/null >/dev/null 2>"$T/ssh/login.err"; then
    echo "cannot log in as $user over SSH with UsePAM no ($(tail -n 2 "$T/ssh/sshd.log" "$T/ssh/login.err" 2>/dev/null | grep -v '^==' | grep . | tail -n 2 | tr '\n' ' '))"
    return 1
  fi
  return 0
}

remote_env() {
  # The main side's settings for a drill on the test "Secondary VPS"
  echo "SNAPSHOT_REMOTE_HOST=127.0.0.1" "SNAPSHOT_REMOTE_USER=$RUSER" "SNAPSHOT_REMOTE_PORT=$RPORT" "SNAPSHOT_REMOTE_KEY=$T/ssh/client_key"
}
remote_bundles_gone() { [ -z "$(ls -A "$T/rhome/.odoo-validator/remote" 2>/dev/null)" ]; }
remote_validator_gone() {
  local p
  for p in /proc/[0-9]*; do
    tr '\0' ' ' 2>/dev/null < "$p/cmdline" | grep -qF -- "$T/rhome/.odoo-validator/remote/" && return 1
  done
  return 0
}
remote_clean() {
  # Everything a drill leaves on the "Secondary VPS" is gone (the bundle goes about 4s after the drill)
  remote_bundles_gone && remote_validator_gone && no_containers "$T/dr" && no_networks "$T/dr" \
    && runs_empty "$T/rhome/.odoo-validator" && lock_free "$T/rlocks"
}
ps_sampler() {
  # ps_sampler OUT STOPFILE   records every process command line every 0.1s until STOPFILE exists
  python3 - "$1" "$2" <<'PY' &
import os, sys, time
out, stop = sys.argv[1], sys.argv[2]
with open(out, "w") as f:
    while not os.path.exists(stop):
        for p in os.listdir("/proc"):
            if p.isdigit():
                try:
                    f.write(open("/proc/%s/cmdline" % p, "rb").read().replace(b"\0", b" ").decode(errors="replace") + "\n")
                except OSError:
                    pass
        time.sleep(0.1)
PY
  TVS_SAMPLER_PID=$!
}

suite_remote() {
  # shellcheck disable=SC2034
  TVS_SUITE=remote
  local reason a r n rel stale deadpid
  tvs_section "remote: private sshd on 127.0.0.1 as the Secondary VPS"
  if ! remote_setup > "$T/remote-skip.txt" 2>&1; then
    reason=$(tr '\n' ' ' < "$T/remote-skip.txt")
    skip "remote suite" "$reason"
    [ -n "${TVS_SSHD_PID:-}" ] && kill "$TVS_SSHD_PID" 2>/dev/null
    return 0
  fi
  pass "test sshd accepts the test key (port $RPORT)"
  : > "$T/remote.env"

  tvs_section "remote: a drill on the Secondary VPS"
  a=$(fx good svc 20260101-000000 "$T/rhome/snapshots")
  deadpid=$(bash -c 'echo $$')
  stale="$T/rhome/.odoo-validator/remote/20200101-000000-$deadpid"
  mkdir -p "$stale" && echo '{"private_key": "stale"}' > "$stale/sa.json"
  n=$(cat "$T/dl/calls.log" 2>/dev/null | wc -l)
  # shellcheck disable=SC2046
  vs remote-pass $(remote_env) VALIDATOR_PG_MEMORY=3g -- --file "$a"
  check_rc "remote drill passes" 0
  r="$VS_REPORT"
  check "report copied back to this host" test -s "$r"
  check_eq "report marked remote" "$RUSER@127.0.0.1" "$(rj "$r" 'r["remote"]["host"]')"
  check_eq "report says via ssh" ssh "$(rj "$r" 'r["remote"]["via"]')"
  check_eq "report result pass" pass "$(rj "$r" 'r["result"]')"
  check_grep "live log streamed back" "$VS_LOG" "[database] Restoring"
  check_grep "log says where the drill runs" "$VS_LOG" "Running the drill on the Secondary VPS"
  check_eq "no Docker call on the main side" "$n" "$(cat "$T/dl/calls.log" 2>/dev/null | wc -l)"
  check "the drill ran in the Secondary VPS's Docker" test -s "$T/dr/run.log"
  check_grep "settings forwarded (VALIDATOR_PG_MEMORY)" "$T/dr/run.log" "--memory 3g"
  check "nothing left on the Secondary VPS" wait_until 15 remote_clean
  check "a stale credential bundle was swept" test ! -e "$stale"
  check_eq "nothing left in this host's temp folder" "" "$(ls -A "$T/tmp")"
  check "no queue lock taken on the main side" lock_free "$T/locks"
  check "the Secondary VPS used its own lock folder" test -e "$T/rlocks/odoo-snapshot-validator.queue.lock"

  # shellcheck disable=SC2046
  vs remote-publish $(remote_env) -- --file "$a" --publish
  check_rc "remote drill with --publish" 0
  check_eq "record written next to the snapshot on the Secondary VPS" pass "$(rj "$a.validated.json" 'r["result"]')"
  check "clean after publish" wait_until 15 remote_clean

  a=$(fx sqlerror bad 20260101-000000 "$T/rhome/snapshots")
  # shellcheck disable=SC2046
  vs remote-broken $(remote_env) -- --file "$a"
  check_rc "broken snapshot fails remotely" 1
  check_eq "failure report marked remote" "$RUSER@127.0.0.1" "$(rj "$VS_REPORT" 'r["remote"]["host"]')"

  rel="snapshots/$(basename "$(fx good rel 20260101-000000 "$T/rhome/snapshots")")"
  # shellcheck disable=SC2046
  vs remote-relative $(remote_env) -- --file "$rel"
  check_rc "relative --file starts in the remote home" 0

  a=$(fx good)
  n=$(cat "$T/dl/run.log" 2>/dev/null | wc -l)
  # shellcheck disable=SC2046
  vs remote-local $(remote_env) -- --file "$a" --local
  check_rc "--local drills on this host" 0
  check_eq "--local report is not marked remote" "" "$(rj "$VS_REPORT" 'r.get("remote")')"
  check_eq "--local used this host's Docker" "$((n + 1))" "$(cat "$T/dl/run.log" 2>/dev/null | wc -l)"
  check "clean after the drills" wait_until 15 remote_clean

  tvs_section "remote: Odoo boots on the Secondary VPS"
  a=$(fx bootgood rboot 20260101-000000 "$T/rhome/snapshots")
  # shellcheck disable=SC2046
  vs remote-boot $(remote_env) VALIDATOR_BOOT=true VALIDATOR_BOOT_STRICT=true -- --file "$a"
  check_rc "remote drill with the boot check passes" 0
  check_eq "remote report level boot" boot "$(rj "$VS_REPORT" 'r["level"]')"
  check "the drill image was built on the Secondary VPS (dockerfile.example travels with the validator)" grep -q "odoo-drill/rboot:build-" "$T/dr/build.log"
  check_eq "VALIDATOR_BOOT_STRICT forwarded" true "$(rj "$VS_REPORT" "[s for s in r['stages'] if s['name']=='boot'][-1]['details']['strict']")"
  check "clean after the boot drill" wait_until 15 remote_clean

  tvs_section "remote: connection and configuration problems"
  local closed
  closed=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
  # shellcheck disable=SC2046
  vs remote-unreachable $(remote_env) SNAPSHOT_REMOTE_PORT="$closed" -- --file snapshots/x.tar.zst
  check_rc "SSH unreachable is an error" 2
  check_eq "a local report is written" error "$(rj "$VS_REPORT" 'r["result"]')"
  check_eq "its remote stage explains it" error "$(stage_of "$VS_REPORT" remote)"
  # shellcheck disable=SC2046
  vs remote-nouser $(remote_env) SNAPSHOT_REMOTE_USER= -- --file snapshots/x.tar.zst
  check_rc "missing SNAPSHOT_REMOTE_USER" 3
  n=$(wc -l < "$T/ssh/client_calls.log")
  # shellcheck disable=SC2046
  vs remote-opthost $(remote_env) SNAPSHOT_REMOTE_HOST="-oProxyCommand=touch $T/pwned-ssh" -- --file snapshots/x.tar.zst
  check_rc "an option-shaped host is refused" 3
  check_not "its ProxyCommand never ran" test -e "$T/pwned-ssh"
  check_eq "ssh was not even called" "$n" "$(wc -l < "$T/ssh/client_calls.log")"
  echo "FAKE_DOCKER_DOWN=1" > "$T/remote.env"
  a=$(fx good svc 20260101-000000 "$T/rhome/snapshots")
  # shellcheck disable=SC2046
  vs remote-nodocker $(remote_env) -- --file "$a"
  check_rc "Docker down on the Secondary VPS" 3
  check "the remote's Docker error is shown" grep -qE "Docker (is not (running|usable)|at .* is not answering)" "$VS_LOG"
  : > "$T/remote.env"
  check "clean after the failures" wait_until 15 remote_clean

  tvs_section "remote: stopping the main side stops the remote drill"
  local how
  echo "FAKE_SLOW_RESTORE=120" > "$T/remote.env"
  for how in ctrl-c term kill-9; do
    # shellcheck disable=SC2046
    vs_bg "remote-$how" $(remote_env) -- --file "$a"
    if ! wait_for_log "$VS_LOG" "Restoring" 90; then
      fail "$how: remote drill reached the restore" "$(tail -n 3 "$VS_LOG")"; vs_wait 5; continue
    fi
    case "$how" in
      ctrl-c) kill -INT -- "-$VS_PID" ;;     # what a terminal's Ctrl-C does: the whole process group
      term) kill -TERM "$VS_PID" ;;           # only the validator
      kill-9) kill -KILL -- "-$VS_PID" ;;     # the validator and its ssh, killed outright
    esac
    if [ "$how" = kill-9 ]; then
      { wait "$VS_PID"; VS_RC=$?; } 2>/dev/null   # reap at once: no "Killed" job notice
    else
      vs_wait 30
    fi
    if [ "$how" = kill-9 ]; then
      check_eq "$how: main side killed" 137 "$VS_RC"
    else
      check_rc "$how: main side reports an error" 2
      check_grep "$how: local report says interrupted" "$VS_REPORT" "Interrupted"
    fi
    check "$how: remote drill stopped, containers removed, lock free" wait_until 20 remote_clean
  done
  : > "$T/remote.env"

  tvs_section "remote: Google Drive and GCS through the Secondary VPS"
  if drive_start; then
    local b64
    drive_seed "$(fx good rdrv 20260101-000000)"
    make_sa "$T/home/sa.json"
    b64=$(base64 -w0 < "$T/home/sa.json")
    rm -f "$T/stop-sampler"
    ps_sampler "$T/ps-samples.txt" "$T/stop-sampler"
    # shellcheck disable=SC2046
    vs remote-drive $(remote_env) $(drive_env) GDRIVE_SERVICE_ACCOUNT_KEY="$T/home/sa.json" -- --drive rdrv --publish
    touch "$T/stop-sampler"; wait "$TVS_SAMPLER_PID" 2>/dev/null
    check_rc "Drive drill through the Secondary VPS" 0
    check_eq "Drive record uploaded" 1 "$(drive_count "snapshot-rdrv-20260101-000000.tar.zst.validated.json")"
    check_not "every Drive call was authorized" grep -q "auth=BAD" "$TVS_DRIVE/requests.log"
    check "ps samples were taken" test "$(wc -l < "$T/ps-samples.txt")" -gt 100
    check_no_grep "no access token in any ps sample" "$T/ps-samples.txt" "$TVS_TOKEN"
    check_no_grep "no private key in any ps sample" "$T/ps-samples.txt" "PRIVATE KEY"
    check_no_grep "no encoded key in any ps sample" "$T/ps-samples.txt" "${b64:40:40}"
    check_no_grep "no JWT in any ps sample" "$T/ps-samples.txt" "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
    check "credentials removed from the Secondary VPS" wait_until 15 remote_clean
    check_eq "no file with the token on either side" "" "$(grep -rlF -- "$TVS_TOKEN" "$T/rhome" "$T/rtmp" "$T/tmp" "$T/vwork" 2>/dev/null)"
    rm -f "$T/ps-samples.txt" "$T/stop-sampler"
    drive_stop
  fi
  local url="gs://tvs-remote/snapshot-rgcs.tar.zst"
  a=$(fx good rgcs)
  env FAKE_GCS_ROOT="$T/gcs" bash "$T/fakebin/gcloud" storage cp "$a" "$url"
  env FAKE_GCS_ROOT="$T/gcs" bash "$T/fakebin/gcloud" storage cp "$a.sha256" "$url.sha256"
  # shellcheck disable=SC2046
  vs remote-gcs $(remote_env) -- --gcs "$url" --publish
  check_rc "GCS drill through the Secondary VPS" 0
  check "GCS record uploaded" test -s "$T/gcs/tvs-remote/snapshot-rgcs.tar.zst.validated.json/live"
  check "clean after the storage drills" wait_until 15 remote_clean

  tvs_section "remote: the drill worker and the validator inbox on the Secondary VPS"
  local rinbox="$T/rhome/.odoo-validator/inbox" rkept="$T/rhome/.odoo-snapshots/app/archives/snapshot-app.tar.zst" n
  mkdir -p "$(dirname "$rkept")"
  a=$(fx good app 20261201-000000)
  mv "$a" "$rkept" && mv "$a.sha256" "$rkept.sha256"
  # As the snapshot tool does on the Secondary VPS when there is no upload: kept there, linked into the inbox
  inbox_put "$rinbox" "$rkept" link "" "" "" "$rkept"
  check_eq "a job waits in the inbox on the Secondary VPS" 1 "$(inbox_jobs_of "$rinbox")"
  # shellcheck disable=SC2046
  wk remote-inbox VALIDATOR_WORKER=true SNAPSHOT_VALIDATOR_INBOX=true VALIDATOR_WORK_DIR="$T/wwork-r" $(remote_env)
  check_wk "worker drills the inbox snapshot on the Secondary VPS" 0
  r=$(wlatest "$T/wwork-r")
  check_eq "report on the main VPS: inbox, from the Secondary VPS" "inbox app $RUSER@127.0.0.1" \
    "$(rj "$r" 'r["source"]["kind"]') $(rj "$r" 'r["source"]["ref"]') $(rj "$r" 'r["remote"]["host"]')"
  check_eq "record next to the copy kept on the Secondary VPS" pass "$(rj "$rkept.validated.json" 'r["result"]')"
  check_eq "the inbox on the Secondary VPS is empty" "0 0" "$(inbox_jobs_of "$rinbox") $(inbox_taken_of "$rinbox")"
  check "clean on the Secondary VPS" wait_until 15 remote_clean
  age_reports 25 "$T/wwork-r"
  n=$(wreports "$T/wwork-r")
  # shellcheck disable=SC2046
  wk remote-same VALIDATOR_WORKER=true SNAPSHOT_VALIDATOR_INBOX=true VALIDATOR_WORK_DIR="$T/wwork-r" $(remote_env)
  check_wk "next day, empty inbox and the kept copy already proved: nothing to do" 0
  check_grep "the inbox is looked at first" "$WK_LOG" "No snapshot of app is waiting in the validator inbox"
  check_grep "then the kept copy, skipped as already proved" "$WK_LOG" "already proved"
  check_eq "no new report (nothing to drill is not a drill)" "$n" "$(wreports "$T/wwork-r")"
  check "clean after nothing to do" wait_until 15 remote_clean

  kill "$TVS_SSHD_PID" 2>/dev/null; wait "$TVS_SSHD_PID" 2>/dev/null
}
