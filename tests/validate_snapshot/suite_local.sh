#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: Local --file drills for validate-snapshot.sh: every stage, publish/revoke, settings, Docker flags, watchdog.
# Usage: sourced by tests/test_validate_snapshot.sh (suite "local"); needs tests/validate_snapshot/lib.sh
# Dependencies: lib.sh, mkfixture.sh, fake docker/df, PostgreSQL server binaries

suite_local() {
  # shellcheck disable=SC2034
  TVS_SUITE=local
  local a r good

  tvs_section "local: a good snapshot passes every stage"
  good=$(fx good)
  vs good -- --file "$good"
  check_rc "good snapshot passes" 0
  r="$VS_REPORT"
  check_eq "report result is pass" pass "$(rj "$r" 'r["result"]')"
  for s in fetch checksum archive structure manifest git disk database filestore; do
    check_eq "stage $s passed" pass "$(stage_of "$r" "$s")"
  done
  check_eq "Odoo version read from the manifest" 17.0 "$(rj "$r" 'r["odoo_version"]')"
  check_eq "Postgres image follows the dump (postgres:16)" postgres:16 "$(rj "$r" 'r["postgres_image"]')"
  check_eq "database stats: 2 users" 2 "$(rj "$r" 'r["database"]["users"]')"
  check_eq "database stats: 20 stored attachments" 20 "$(rj "$r" 'r["database"]["attachments_stored"]')"
  check_eq "git: odoo-base found and custom_addons bundled" 2 "$(stage_of "$r" git ok)"
  check_eq "no publish without --publish" "" "$(rj "$r" 'r["record_published"]')"
  check_not "no validation record written" test -e "$good.validated.json"
  check "no drill container left" no_containers
  check "no drill network left" no_networks
  check "work folder removed" runs_empty
  check "queue lock released" lock_free
  check "the lock lives in the test folder" test -e "$T/locks/odoo-snapshot-validator.queue.lock"
  check "report is private (0600)" test "$(stat -c %a "$r")" = 600

  tvs_section "local: --publish writes the record"
  vs publish -- --file "$good" --publish
  check_rc "drill with --publish" 0
  a="$good.validated.json"
  check "record written next to the archive" test -f "$a"
  check_eq "record result pass" pass "$(rj "$a" 'r["result"]')"
  check_eq "record level database" database "$(rj "$a" 'r["level"]')"
  check_eq "record sha256 is the archive's" "$(sha256sum "$good" | cut -d' ' -f1)" "$(rj "$a" 'r["sha256"]')"
  check "record has the run_id" bash -c '[[ "$1" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ ]]' _ "$(rj "$a" 'r["run_id"]')"
  check_eq "record checks block has git=pass" pass "$(rj "$a" 'r["checks"]["git"]')"
  check_eq "record checks block has database and filestore" "pass pass" "$(rj "$a" 'r["checks"]["database"]') $(rj "$a" 'r["checks"]["filestore"]')"
  check_eq "record checks block leaves out fetch/disk" "false" "$(rj "$a" '"fetch" in r["checks"] or "disk" in r["checks"]')"
  check_eq "record carries database stats" 2 "$(rj "$a" 'r["database"]["users"]')"
  check_eq "report says the record was published" yes "$(rj "$VS_REPORT" 'r["record_published"]')"

  tvs_section "local: broken snapshots fail (exit 1)"
  local v stage
  for v in sqlerror:database missingfiles:filestore wrongsize:filestore badcommit:git noremote:git \
           truncdump:database nokeys:database nousers:database badsidecar:checksum truncated:archive; do
    stage="${v#*:}"; v="${v%%:*}"
    a=$(fx "$v")
    vs "fail-$v" -- --file "$a"
    check_rc "$v fails" 1
    check_eq "$v: the $stage stage failed" fail "$(stage_of "$VS_REPORT" "$stage")"
  done
  check_grep "sqlerror: the SQL error is in the report" "$T/reports/fail-sqlerror.json" "no_such_table"
  check_grep "truncdump: end-of-dump marker reported" "$T/reports/fail-truncdump.json" "end-of-dump marker"
  check_grep "nokeys: missing keys reported" "$T/reports/fail-nokeys.json" "no primary/foreign/unique keys"
  check_grep "badcommit: missing commit reported" "$T/reports/fail-badcommit.json" "is not on"
  check "failed drills leave no containers" no_containers

  tvs_section "local: warnings and skips"
  a=$(fx fewmissing)
  vs fewmissing -- --file "$a"
  check_rc "1 of 200 attachments missing still passes" 0
  check_eq "filestore stage warns" warn "$(stage_of "$VS_REPORT" filestore)"
  vs fewmissing-strict VALIDATOR_FILESTORE_MAX_MISSING_PCT=0.4 -- --file "$a"
  check_rc "the same snapshot fails with a 0.4% limit" 1
  a=$(fx nosidecar)
  vs nosidecar -- --file "$a"
  check_rc "no .sha256 still passes" 0
  check_eq "checksum stage skipped" skip "$(stage_of "$VS_REPORT" checksum)"
  check_eq "skipped checksum still records the sha256" "$(sha256sum "$a" | cut -d' ' -f1)" "$(stage_of "$VS_REPORT" checksum sha256)"

  tvs_section "local: git values from the archive never reach git as options"
  a=$(fx gitinject)
  vs gitinject -- --file "$a"
  check_rc "option-shaped commit/remote fail the git check" 1
  check_grep "invalid commit id reported" "$VS_REPORT" "invalid or missing commit id"
  check_grep "invalid remote reported" "$VS_REPORT" "invalid remote"
  check_not "no command ran via the commit value" test -e "$T/pwned-commit"
  check_not "no command ran via the remote value" test -e "$T/pwned-remote"

  tvs_section "local: credentials in git URLs are redacted"
  a=$(fx credurl)
  vs credurl -- --file "$a"
  check_rc "an unreachable remote is an error, not a failure" 2
  check_eq "git stage error" error "$(stage_of "$VS_REPORT" git)"
  check_no_grep "token not in the report" "$VS_REPORT" "S3cr3tT0ken"
  check_no_grep "token not in the log" "$VS_LOG" "S3cr3tT0ken"
  check_grep "URL shown redacted" "$VS_REPORT" "https://***@git.example.invalid"

  tvs_section "local: bad settings and arguments (exit 3)"
  local s
  for s in VALIDATOR_PG_CPUS=lots VALIDATOR_PULL_POLICY=sometimes VALIDATOR_DISK_RESERVE_GB=5GB \
           VALIDATOR_WATCHDOG_INTERVAL=0 VALIDATOR_PG_MEMORY=2gigs VALIDATOR_FILESTORE_MAX_MISSING_PCT=one \
           VALIDATOR_GIT_ALLOW_PROTOCOL='https ssh'; do
    vs "badsetting" "$s" -- --file "$good"
    check_rc "rejects $s" 3
  done
  check_grep "the bad setting is named" "$VS_LOG" "Invalid setting: VALIDATOR_GIT_ALLOW_PROTOCOL"
  VS_NO_REPORT=1 vs badarg -- --file "$good" --frobnicate; check_rc "unknown option" 3
  VS_NO_REPORT=1 vs noval -- --file; check_rc "--file without a value" 3
  VS_NO_REPORT=1 vs nosource -- --publish; check_rc "no source" 3
  VS_NO_REPORT=1 vs badgcs -- --gcs bucket/obj; check_rc "--gcs without gs://" 3
  vs notfound -- --file "$T/nope/snapshot-x-20260101-000000.tar.zst"
  check_rc "file not found is an error" 2
  check_eq "fetch stage error" error "$(stage_of "$VS_REPORT" fetch)"

  tvs_section "local: Docker on the drill host"
  vs nodocker FAKE_DOCKER_DOWN=1 -- --file "$good"
  check_rc "Docker not reachable" 3
  check "the log names the Docker problem" grep -qE "Docker (is not (running|usable)|at .* is not answering)" "$VS_LOG"
  if [ "$(id -u)" != 0 ] && ! grep -q "is not answering" "$VS_LOG"; then
    check_grep "a non-root user is told how to set up rootless Docker" "$VS_LOG" "setup-validator-docker.sh"
  fi
  echo "cpuset cpu io memory hugetlb pids rdma misc" > "$T/cgroup-full"
  echo "cpuset io" > "$T/cgroup-partial"
  vs rootless FAKE_DOCKER_ROOTLESS=1 VALIDATOR_TEST_CGROUP_FILE="$T/cgroup-full" -- --file "$good"
  check_rc "rootless Docker with cpu/memory/pids delegated passes" 0
  check_no_grep "no docker-group warning for rootless Docker" "$VS_LOG" "docker group"
  vs rootless-nocg FAKE_DOCKER_ROOTLESS=1 VALIDATOR_TEST_CGROUP_FILE="$T/cgroup-partial" -- --file "$good"
  check_rc "rootless Docker without delegated controllers is refused" 3
  check_grep "the missing controllers are named" "$VS_LOG" "cannot limit cpu memory pids"
  check "no container started without limits" no_containers
  if [ "$(id -u)" != 0 ]; then
    check_grep "a non-root user on the system daemon gets the docker-group warning" "$T/logs/good.log" "docker group"
  fi

  tvs_section "local: publish rules"
  a=$(fx sqlerror)
  echo '{"result": "pass"}' > "$a.validated.json"
  vs revoke -- --file "$a" --publish
  check_rc "failed drill" 1
  check_not "failed drill revokes the old record" test -e "$a.validated.json"
  check_eq "revoke stage recorded" pass "$(stage_of "$VS_REPORT" revoke)"
  a=$(fx good)
  echo '{"result": "pass", "keep": "me"}' > "$a.validated.json"
  vs infra FAKE_NO_IMAGE=1 FAKE_PULL_FAIL=1 -- --file "$a" --publish
  check_rc "no Postgres image is an infrastructure error" 2
  check_grep "an infrastructure error keeps the old record" "$a.validated.json" '"keep": "me"'
  rm -f "$a.validated.json"
  vs nogit -- --file "$a" --publish --no-git-check
  check_rc "--no-git-check --publish passes without a record" 4
  check_not "no record without the git check" test -e "$a.validated.json"
  check_grep "publish refusal explained" "$VS_REPORT" "the git check did not run"

  tvs_section "local: file replaced during the drill"
  a=$(fx good)
  vs_bg replaced FAKE_SLOW_RESTORE=60 -- --file "$a" --publish
  if wait_for_log "$VS_LOG" "Restoring" 90; then
    cp "$(fx nosidecar)" "$a.new" && mv -f "$a.new" "$a"
    kill_slow_restore
  fi
  vs_wait 120
  check_rc "drill of the original bytes passes, but no record" 4
  check_not "no record for a file that was not drilled" test -e "$a.validated.json"
  check_grep "replacement explained" "$VS_REPORT" "was replaced during the drill"

  tvs_section "local: Postgres image and pull policy"
  a=$(fx newerdump)
  vs newerdump -- --file "$a"
  check_rc "newer pg_dump snapshot passes" 0
  check_eq "a newer pg_dump picks the newer image" postgres:17 "$(rj "$VS_REPORT" 'r["postgres_image"]')"
  : > "$T/dl/pull.log"
  vs pullfail FAKE_PULL_FAIL=1 -- --file "$good"
  check_rc "pull failure with a cached image still passes" 0
  check_eq "database stage warns about the cached image" warn "$(stage_of "$VS_REPORT" database)"
  check_grep "warning names the image" "$VS_REPORT" "could not refresh postgres:16"
  : > "$T/dl/pull.log"
  vs pullmissing VALIDATOR_PULL_POLICY=missing -- --file "$good"
  check_rc "pull policy missing" 0
  check_eq "cached image is not pulled again" "" "$(cat "$T/dl/pull.log")"
  vs pullalways -- --file "$good"
  check_grep "default policy refreshes the image" "$T/dl/pull.log" "postgres:16"

  tvs_section "local: docker run flags"
  local runline
  runline=$(tail -n 1 "$T/dl/run.log")
  for s in "--oom-score-adj 1000" "--pids-limit 512" "--memory 2g" "--memory-swap 2g" "-c fsync=off" \
           "-c full_page_writes=off" "-c autovacuum=off" "-c synchronous_commit=off" "--network odoo-drill-"; do
    case "$runline" in *"$s"*) pass "docker run has $s" ;; *) fail "docker run has $s" "$runline" ;; esac
  done
  check_grep "drill network is internal" "$T/dl/calls.log" "network create --internal --label odoo-drill="
  vs pgmem VALIDATOR_PG_MEMORY=3g VALIDATOR_PG_CPUS=1.5 -- --file "$good"
  runline=$(tail -n 1 "$T/dl/run.log")
  case "$runline" in *"--cpus 1.5 --memory 3g --memory-swap 3g"*) pass "CPU and memory settings applied" ;; *) fail "CPU and memory settings applied" "$runline" ;; esac

  tvs_section "local: disk estimate"
  check_eq "manifest size label" "manifest database size x1.2" "$(stage_of "$T/reports/good.json" disk estimate)"
  check_eq "manifest size estimate" 62914560 "$(stage_of "$T/reports/good.json" disk estimated_db_bytes)"
  a=$(fx plaindump)
  vs plaindump -- --file "$a"
  check_rc "plain dump snapshot passes" 0
  check_eq "plain dump label" "plain dump x2.5" "$(stage_of "$VS_REPORT" disk estimate)"
  vs lowdisk FAKE_DF_AVAIL=1073741824 -- --file "$good"
  check_rc "not enough disk before the restore is an error" 2
  check_eq "disk stage error" error "$(stage_of "$VS_REPORT" disk)"

  tvs_section "local: the watchdog stops a drill when the disk runs low"
  local t0 secs
  vs_bg watchdog FAKE_SLOW_RESTORE=60 FAKE_DF_LOW_FILE="$T/disk-low" -- --file "$good"
  if wait_for_log "$VS_LOG" "Restoring" 90; then
    t0=$(date +%s%N)
    touch "$T/disk-low"
    vs_wait 30
    secs=$(( ($(date +%s%N) - t0) / 1000000000 ))
  else
    vs_wait 5; secs=99
  fi
  rm -f "$T/disk-low"
  check_rc "low-disk drill stops with an error" 2
  if [ "$secs" -le 6 ]; then pass "stopped within 6s (${secs}s)"; else fail "stopped within 6s" "${secs}s"; fi
  # The watchdog removes the container before it signals the drill, so the restore can die first:
  # the report then says the drill's Postgres stopped instead of naming the low disk. Both are exit 2.
  if grep -qF "free disk space fell below the reserve" "$VS_REPORT" 2>/dev/null; then
    pass "abort reason recorded (low disk)"
  elif grep -qF "Postgres stopped during the restore" "$VS_REPORT" 2>/dev/null; then
    pass "abort reason recorded (Postgres stopped; low-disk reason lost to the race)"
  else
    fail "abort reason recorded" "neither the low-disk nor the stopped-Postgres reason is in the report"
  fi
  check "its container was removed" no_containers
  check "no Postgres left running" no_postgres_under "$T/dl"
  check "lock released after the abort" lock_free
  check "work folder removed after the abort" runs_empty
}
