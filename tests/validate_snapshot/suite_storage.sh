#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: Recovery after kill -9, Google Cloud Storage drills (generation pinning) and Google Drive drills (mock API).
# Usage: sourced by tests/test_validate_snapshot.sh (suite "storage"); needs tests/validate_snapshot/lib.sh
# Dependencies: lib.sh, mkfixture.sh, mock_drive.py, fake docker/df/gcloud, PostgreSQL server binaries

gcs() { env FAKE_GCS_ROOT="$T/gcs" bash "$T/fakebin/gcloud" storage "$@"; }
gcs_live() { cat "$T/gcs/${1#gs://}/live" 2>/dev/null; }
validator_procs() {
  # Number of processes still running the copied validator (main shell or its subshells)
  local p n=0
  for p in /proc/[0-9]*; do
    tr '\0' ' ' 2>/dev/null < "$p/cmdline" | grep -qF -- "$VALIDATOR" && n=$((n + 1))
  done
  echo "$n"
}
no_validator_procs() { [ "$(validator_procs)" = 0 ]; }

suite_storage() {
  # shellcheck disable=SC2034
  TVS_SUITE=storage
  local a b r gen size

  tvs_section "storage: recovery after kill -9"
  a=$(fx good)
  vs_bg kill9 FAKE_SLOW_RESTORE=60 -- --file "$a"
  if wait_for_log "$VS_LOG" "Restoring" 90; then
    kill -KILL "$VS_PID"; wait "$VS_PID" 2>/dev/null
    kill_slow_restore
    check "watchdog, heartbeat and restore exit by themselves" wait_until 20 no_validator_procs
    check "the queue's flock is free again" flock -n "$T/locks/odoo-snapshot-validator.queue.lock" true
    check_eq "the killed drill left its container behind" 1 "$(containers_in)"
    check_not "the killed drill left its work folder behind" runs_empty
    vs after-kill9 QUEUE_LOCK_STALE_AFTER=3 -- --file "$a"
    check_rc "the next drill runs once the dead drill's marker is stale" 0
    check_grep "it sweeps the leftovers" "$VS_LOG" "Removed the leftovers of 1 earlier drill"
    check "leftover container removed" no_containers
    check "leftover network removed" no_networks
    check "leftover run folder removed" runs_empty
    check "no Postgres left running" no_postgres_under "$T/dl"
    check "queue free afterwards" lock_free
  else
    fail "kill -9 drill reached the restore" "$(tail -n 5 "$VS_LOG")"
    vs_wait 5
  fi

  tvs_section "storage: Google Cloud Storage"
  local url="gs://tvs-bucket/snaps/snapshot-svc.tar.zst"
  a=$(fx good)
  gcs cp "$a" "$url" && gcs cp "$a.sha256" "$url.sha256"
  gen=$(gcs_live "$url")
  vs gcs-pass -- --gcs "$url" --publish
  check_rc "GCS snapshot passes and is published" 0
  r="$VS_REPORT"
  check_eq "checksum checked against the GCS .sha256" pass "$(stage_of "$r" checksum)"
  check_eq "report pins the generation" "$gen" "$(rj "$r" 'r["source"]["gcs_generation"]')"
  check "record uploaded next to the object" test -n "$(gcs_live "$url.validated.json")"
  gcs cp "$url.validated.json" "$T/tmp/rec.json"
  check_eq "record pins the same generation" "$gen" "$(rj "$T/tmp/rec.json" 'r["gcs_generation"]')"
  check_eq "record sha256 is the drilled bytes" "$(sha256sum "$a" | cut -d' ' -f1)" "$(rj "$T/tmp/rec.json" 'r["sha256"]')"
  check_grep "download pinned to the generation" "$T/gcs/calls.log" "storage cp $url#$gen"
  rm -f "$T/tmp/rec.json"

  gcs rm "$url.validated.json"
  vs_bg gcs-replaced FAKE_SLOW_RESTORE=60 -- --gcs "$url" --publish
  if wait_for_log "$VS_LOG" "Restoring" 90; then
    gcs cp "$(fx nosidecar)" "$url"
    kill_slow_restore
  fi
  vs_wait 120
  check_rc "object replaced during the drill: passed, no record" 4
  check_grep "replacement explained" "$VS_REPORT" "was replaced during the drill"
  check_eq "no record for the replaced object" "" "$(gcs_live "$url.validated.json")"

  size=$(gcs objects describe "$url" --format='value(size)')
  vs gcs-lowdisk VALIDATOR_DISK_RESERVE_GB=0 FAKE_DF_AVAIL=$((size - 1)) -- --gcs "$url"
  check_rc "not enough disk to download is an error" 2
  check_grep "pre-download disk check explained" "$VS_REPORT" "Not enough disk to download"
  check_not "nothing was downloaded" grep -q "storage cp $url#" <(tail -n 3 "$T/gcs/calls.log")

  local bad="gs://tvs-bucket/snaps/snapshot-broken.tar.zst"
  b=$(fx sqlerror broken)
  gcs cp "$b" "$bad" && gcs cp "$b.sha256" "$bad.sha256"
  echo '{"result": "pass"}' > "$T/tmp/old.json" && gcs cp "$T/tmp/old.json" "$bad.validated.json" && rm -f "$T/tmp/old.json"
  vs gcs-revoke -- --gcs "$bad" --publish
  check_rc "broken GCS snapshot fails" 1
  check_eq "failed drill revokes the GCS record" "" "$(gcs_live "$bad.validated.json")"
  check_eq "revoke stage recorded" pass "$(stage_of "$VS_REPORT" revoke)"

  tvs_section "storage: Google Drive"
  drive_start || return 0
  local older newer other dsha
  older=$(fx sqlerror drv 20260101-000000)
  newer=$(fx good drv 20260301-000000)
  other=$(fx good other 20260401-000000)
  drive_seed "$older" "" 2026-01-01T00:00:00.000Z
  drive_seed "$newer" "" 2026-03-01T00:00:00.000Z
  drive_seed "$other" "" 2026-04-01T00:00:00.000Z
  # shellcheck disable=SC2046
  vs drive-pass GDRIVE_ACCESS_TOKEN="$TVS_TOKEN" $(drive_env) -- --drive drv --publish
  check_rc "Drive: newest snapshot of the service passes" 0
  r="$VS_REPORT"
  check_eq "Drive: picks the newest archive of that service" "$(basename "$newer")" "$(rj "$r" 'r["archive"]')"
  check_eq "Drive: its .sha256 was downloaded and checked" pass "$(stage_of "$r" checksum)"
  check_eq "Drive: record uploaded" 1 "$(drive_count "$(basename "$newer").validated.json")"
  drive_content "$(basename "$newer").validated.json" > "$T/tmp/rec.json"
  dsha=$(sha256sum "$newer" | cut -d' ' -f1)
  check_eq "Drive: record has the archive's sha256" "$dsha" "$(rj "$T/tmp/rec.json" 'r["sha256"]')"
  rm -f "$T/tmp/rec.json"
  # shellcheck disable=SC2046
  vs drive-republish GDRIVE_ACCESS_TOKEN="$TVS_TOKEN" $(drive_env) -- --drive drv --publish
  check_rc "Drive: second drill passes" 0
  check_eq "Drive: republish replaces the record (still one)" 1 "$(drive_count "$(basename "$newer").validated.json")"
  check_not "Drive: every call was authorized" grep -q "auth=BAD" "$TVS_DRIVE/requests.log"
  check_grep "Drive: calls went to the mock" "$TVS_DRIVE/requests.log" "GET /drive/v3/files auth=ok"

  echo '{"result": "pass"}' > "$T/tmp/old.json"
  drive_seed "$T/tmp/old.json" "$(basename "$older").validated.json"; rm -f "$T/tmp/old.json"
  # shellcheck disable=SC2046
  vs drive-name GDRIVE_ACCESS_TOKEN="$TVS_TOKEN" $(drive_env) -- --drive drv --name "$(basename "$older")" --publish
  check_rc "Drive: --name drills that exact (broken) snapshot" 1
  check_eq "Drive: --name archive in the report" "$(basename "$older")" "$(rj "$VS_REPORT" 'r["archive"]')"
  check_eq "Drive: failed drill revokes its record" 0 "$(drive_count "$(basename "$older").validated.json")"
  check_eq "Drive: the other record is untouched" 1 "$(drive_count "$(basename "$newer").validated.json")"

  # shellcheck disable=SC2046
  vs drive-badtoken GDRIVE_ACCESS_TOKEN="ya29.wrong" $(drive_env) -- --drive drv
  check_rc "Drive: wrong token is an error" 2
  check_eq "Drive: fetch stage error" error "$(stage_of "$VS_REPORT" fetch)"
  check_grep "Drive: the mock refused it" "$TVS_DRIVE/requests.log" "auth=BAD"

  make_sa "$T/home/sa.json"
  # shellcheck disable=SC2046
  vs drive-sa GDRIVE_SERVICE_ACCOUNT_KEY="$T/home/sa.json" $(drive_env) -- --drive drv
  check_rc "Drive: service-account key" 0
  check_grep "Drive: token obtained from /token" "$TVS_DRIVE/requests.log" "POST /token"
  drive_stop
}
