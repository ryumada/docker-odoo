#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: The validator inbox source (--inbox), --unless-checksum and the drill worker (validate-snapshot-worker.sh) on this host.
# Usage: sourced by tests/test_validate_snapshot.sh (suite "worker"); needs tests/validate_snapshot/lib.sh
# Dependencies: lib.sh, mkfixture.sh, mock_drive.py, fake docker/df/gcloud, PostgreSQL server binaries
#
# The worker's deployment is the test copy of the app ($T/app, service "app"). Its reports go to
# $T/wwork (VALIDATOR_WORK_DIR) and its local snapshots are looked for in $T/wsnap
# (VALIDATOR_LOCAL_SNAPSHOTS_DIR), never in a real home folder. Inbox jobs are made by the snapshot
# tool's own snap_inbox_handoff. The worker's lock goes to $T/locks (QUEUE_LOCK_DIR).

inbox_put() {
  # inbox_put INBOX_ROOT ARCHIVE MODE(move|link) [DRIVE_NAME DRIVE_ID] [GCS_OBJECT] [KEPT]
  # Hands ARCHIVE to INBOX_ROOT/app/ like the snapshot tool does after an upload.
  local root="$1" a="$2" mode="$3" dn="${4:-}" did="${5:-}" gcs="${6:-}" kept="${7:-}" res="" rc
  if [ -n "$did" ]; then res="$T/tmp/drive-result-$RANDOM"; printf '%s\t%s\n' "$dn" "$did" > "$res"; fi
  env -i PATH="$T/fakebin:$TVS_ORIG_PATH" FAKE_GCS_ROOT="$T/gcs" HOME="$T/home" TMPDIR="$T/tmp" bash -c '
    _ss_log() { :; }
    source "$1/scripts/lib/snapshot_storage.sh"; shift
    snap_inbox_handoff "$@"' _ "$T/app" "$a" "$mode" "$root" app 0 tvs-main "$res" "$gcs" "$kept" "$T/nostats" >>"$T/logs/inbox_put.log" 2>&1
  rc=$?
  rm -f "$res"
  return $rc
}
inbox_jobs_of() { local d n=0; for d in "$1"/app/snapshot-*/; do [ -d "$d" ] && n=$((n + 1)); done; echo "$n"; }
inbox_taken_of() { local d n=0; for d in "$1"/app/.taken-*; do [ -e "$d" ] && n=$((n + 1)); done; echo "$n"; }

drive_seed_id() {
  # drive_seed_id FILE: like drive_seed, and prints the archive's Drive id
  local f="$1" id
  id=$(python3 "$TVS_DIR/mock_drive.py" seed --root "$TVS_DRIVE" --folder "$TVS_FOLDER" --name "$(basename "$f")" --file "$f") || return 1
  [ -f "$f.sha256" ] && python3 "$TVS_DIR/mock_drive.py" seed --root "$TVS_DRIVE" --folder "$TVS_FOLDER" --name "$(basename "$f").sha256" --file "$f.sha256" >/dev/null
  echo "$id"
}

wk() {
  # wk NAME [VAR=value ...] [-- worker args]   runs the worker of deployment "app"; sets WK_RC, WK_LOG
  local name="$1" envs=() line; shift
  WK_LOG="$T/logs/worker-$name.log"
  while IFS= read -r line; do envs+=("$line"); done < <(tvs_env)
  envs+=("VALIDATOR_WORK_DIR=$T/wwork" "VALIDATOR_LOCAL_SNAPSHOTS_DIR=$T/wsnap")
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env -i "${envs[@]}" bash "$T/app/scripts/validate-snapshot-worker.sh" "$@" </dev/null >"$WK_LOG.out" 2>"$WK_LOG"
  WK_RC=$?
  VS_LOG="$WK_LOG"   # what fail() shows with TVS_VERBOSE=1
}
check_wk() { if [ "${WK_RC:-x}" = "$2" ]; then pass "$1 (exit $2)"; else fail "$1" "expected exit $2, got ${WK_RC:-none} (log: $WK_LOG)"; fi; }
wreports() { local f n=0; for f in "${1:-$T/wwork}"/reports/app-*.json; do [ -f "$f" ] && n=$((n + 1)); done; echo "$n"; }
wlatest() { readlink -f "${1:-$T/wwork}/reports/latest-app.json" 2>/dev/null; }
age_reports() {
  # age_reports HOURS [DIR] [ONLY_RESULT]   moves started_at of the app reports back by HOURS
  python3 - "${2:-$T/wwork}/reports" "$1" "${3:-}" <<'PY'
import calendar, glob, json, os, sys, time
d, h, only = sys.argv[1], float(sys.argv[2]), sys.argv[3]
for p in glob.glob(os.path.join(d, "app-*.json")):
    r = json.load(open(p))
    if only and r.get("result") != only:
        continue
    t = calendar.timegm(time.strptime(r["started_at"], "%Y-%m-%dT%H:%M:%SZ")) - int(h * 3600)
    r["started_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
    json.dump(r, open(p, "w"), indent=2)
PY
}
local_put() {
  # local_put TIMESTAMP [VARIANT]: a local snapshot as the snapshot tool keeps it
  # ($T/wsnap/app/archives/snapshot-app.tar.zst-<TS>/snapshot-app.tar.zst + .sha256); prints the archive
  local d="$T/wsnap/app/archives/snapshot-app.tar.zst-$1" a
  a=$(fx "${2:-good}" app "$1") || return 1
  mkdir -p "$d" && mv "$a" "$d/snapshot-app.tar.zst" || return 1
  [ -f "$a.sha256" ] && printf '%s  snapshot-app.tar.zst\n' "$(cut -d' ' -f1 "$a.sha256")" > "$d/snapshot-app.tar.zst.sha256" && rm -f "$a.sha256"
  echo "$d/snapshot-app.tar.zst"
}

suite_worker() {
  TVS_SUITE=worker
  local inbox="$T/home/.odoo-validator/inbox" a b r id sha n g gen url kept holder

  tvs_section "worker: settings"
  wk off
  check_wk "worker off by default" 0
  check_grep "says it is off" "$WK_LOG" "VALIDATOR_WORKER is not true"
  check_eq "nothing drilled" 0 "$(wreports)"
  wk badint VALIDATOR_WORKER=true VALIDATOR_MIN_INTERVAL_HOURS=0
  check_wk "VALIDATOR_MIN_INTERVAL_HOURS=0 refused" 3
  wk badint2 VALIDATOR_WORKER=true VALIDATOR_MIN_INTERVAL_HOURS=12h
  check_wk "VALIDATOR_MIN_INTERVAL_HOURS=12h refused" 3
  check_grep "names the setting" "$WK_LOG" "VALIDATOR_MIN_INTERVAL_HOURS='12h'"
  wk badflag VALIDATOR_WORKER=yes
  check_wk "VALIDATOR_WORKER=yes refused" 3
  wk status-empty -- --status
  check_wk "--status works with the worker off" 0
  check_grep "never drilled: due now" "$WK_LOG.out" "Due:               yes"
  check_grep "no snapshot to drill yet" "$WK_LOG.out" "nothing found"
  wk nothing VALIDATOR_WORKER=true
  check_wk "nothing to drill is not an error" 0
  check_grep "says there is no snapshot" "$WK_LOG" "No snapshot of app found to drill"

  tvs_section "worker: newest local archive, then the interval"
  local_put 20260101-000000 >/dev/null
  a=$(local_put 20260201-000000)
  wk first VALIDATOR_WORKER=true
  check_wk "first drill passes" 0
  check_eq "one report" 1 "$(wreports)"
  r=$(wlatest)
  check_eq "drilled the newest local archive" "$a" "$(rj "$r" 'r["source"]["ref"]')"
  check_eq "with --publish: record next to it" pass "$(rj "$a.validated.json" 'r["result"]')"
  check_not "the older archive is not drilled" test -e "$T/wsnap/app/archives/snapshot-app.tar.zst-20260101-000000/snapshot-app.tar.zst.validated.json"
  check_grep "warns that the drill runs on this host" "$WK_LOG" "SNAPSHOT_REMOTE_HOST is not set"
  wk notdue VALIDATOR_WORKER=true
  check_wk "next tick: not due" 0
  check_grep "says when the next drill is due" "$WK_LOG" "No drill of app is due before"
  check_eq "no new drill" 1 "$(wreports)"
  wk status VALIDATOR_WORKER=true -- --status
  check_grep "--status: not due" "$WK_LOG.out" "Due:               no"
  check_grep "--status: last pass" "$WK_LOG.out" "Last pass/fail:    pass"
  check_grep "--status: what it drills" "$WK_LOG.out" "(newest local archive)"
  age_reports 23.9
  wk almost VALIDATOR_WORKER=true
  check_eq "23.9h later: due (10 min slack for the cron tick)" 1 "$(wreports)"
  check_grep "23.9h later, same snapshot: skipped" "$WK_LOG" "already proved"
  age_reports 0.05
  wk sameagain VALIDATOR_WORKER=true
  check_wk "24h later, no new snapshot" 0
  check_eq "nothing drilled (--unless-checksum)" 1 "$(wreports)"
  check_grep "the drill says why" "$WK_LOG" "is the snapshot the last drill already proved"
  wk sameagain-status VALIDATOR_WORKER=true -- --status
  check_grep "--status: names the proved snapshot" "$WK_LOG.out" "Already proved:    sha256 $(cut -d' ' -f1 "$a.sha256")"
  b=$(local_put 20260301-000000)
  wk newer VALIDATOR_WORKER=true
  check_wk "a newer snapshot is drilled" 0
  check_eq "second report" 2 "$(wreports)"
  check_eq "that snapshot" "$b" "$(rj "$(wlatest)" 'r["source"]["ref"]')"

  tvs_section "worker: an error is retried after a quarter of the interval"
  age_reports 25
  b=$(local_put 20260401-000000)
  wk err VALIDATOR_WORKER=true FAKE_DF_AVAIL=1073741824
  check_wk "drill error is passed on" 2
  check_eq "error report" error "$(rj "$(wlatest)" 'r["result"]')"
  wk err-notdue VALIDATOR_WORKER=true
  check_wk "right after the error: not due" 0
  check_eq "no retry yet" 3 "$(wreports)"
  age_reports 5.5 "" error
  wk err-5h VALIDATOR_WORKER=true
  check_eq "5.5h after the error (24h interval: retry after 6h): still not due" 3 "$(wreports)"
  wk err-status VALIDATOR_WORKER=true -- --status
  check_grep "--status: error retry interval" "$WK_LOG.out" "24h after a pass or fail, 6h after an error"
  age_reports 1 "" error
  wk retry VALIDATOR_WORKER=true
  check_wk "6.5h after the error: retried and passed" 0
  check_eq "retried" pass "$(rj "$(wlatest)" 'r["result"]')"
  wk short-status VALIDATOR_WORKER=true VALIDATOR_MIN_INTERVAL_HOURS=2 -- --status
  check_grep "a short interval retries an error after at least 1h" "$WK_LOG.out" "2h after a pass or fail, 1h after an error"

  tvs_section "worker: a broken snapshot waits the full interval"
  age_reports 25
  b=$(local_put 20260501-000000 sqlerror)
  wk broken VALIDATOR_WORKER=true
  check_wk "broken snapshot fails" 1
  check_eq "fail report" fail "$(rj "$(wlatest)" 'r["result"]')"
  age_reports 7
  wk broken-7h VALIDATOR_WORKER=true
  check_eq "7h later: not drilled again" 5 "$(wreports)"
  age_reports 20
  wk broken-27h VALIDATOR_WORKER=true
  check_wk "27h later, still the same broken snapshot" 0
  check_eq "it is not drilled again (the fail is proven)" 5 "$(wreports)"
  check_grep "skipped as already proved" "$WK_LOG" "already proved"

  tvs_section "worker: --force and the lock"
  b=$(local_put 20260601-000000)
  wk force VALIDATOR_WORKER=true -- --force
  check_wk "--force drills a new snapshot at once" 0
  check_eq "drilled" "$b" "$(rj "$(wlatest)" 'r["source"]["ref"]')"
  b=$(local_put 20260701-000000)
  wk force-off -- --force
  check_wk "--force also works with the worker off" 0
  check_eq "drilled too" "$b" "$(rj "$(wlatest)" 'r["source"]["ref"]')"
  age_reports 25
  b=$(local_put 20260801-000000)
  n=$(wreports)
  : >> "$T/locks/odoo-snapshot-validator-worker.app.lock"
  # One process holds the lock (a "flock FILE sleep" would leave it with the sleep)
  python3 -c 'import fcntl, sys, time; f = open(sys.argv[1]); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(60)' "$T/locks/odoo-snapshot-validator-worker.app.lock" &
  holder=$!
  wait_until 10 bash -c "! flock -n '$T/locks/odoo-snapshot-validator-worker.app.lock' true"
  wk locked VALIDATOR_WORKER=true
  check_wk "a second worker run does nothing" 0
  check_grep "says the previous run is still going" "$WK_LOG" "still going"
  check_eq "no drill" "$n" "$(wreports)"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  wk unlocked VALIDATOR_WORKER=true
  check_wk "after the previous run ends, the drill runs" 0
  check_eq "drilled" "$b" "$(rj "$(wlatest)" 'r["source"]["ref"]')"
  check "the worker lock is in QUEUE_LOCK_DIR (never a real /tmp file)" test -e "$T/locks/odoo-snapshot-validator-worker.app.lock"

  tvs_section "inbox: --inbox on the drill host"
  mkdir -p "$inbox"
  vs inbox-empty -- --inbox app
  check_rc "empty inbox: nothing to drill" 5
  check_not "no report for nothing" test -e "$VS_REPORT"
  check_grep "says so" "$VS_LOG" "nothing to drill"
  check "nothing left in the work folder" runs_empty
  vs inbox-badname -- --inbox "../x"
  check_rc "--inbox with a path is refused" 3

  drive_start || return 0
  a=$(fx good app 20260901-000000)
  id=$(drive_seed_id "$a")
  inbox_put "$inbox" "$a" move "$(basename "$a")" "$id"
  check_eq "job in the inbox" 1 "$(inbox_jobs_of "$inbox")"
  : > "$TVS_DRIVE/requests.log"
  # shellcheck disable=SC2046
  vs inbox-drive GDRIVE_ACCESS_TOKEN="$TVS_TOKEN" $(drive_env) -- --inbox app --publish
  check_rc "inbox snapshot passes" 0
  check_eq "report: source inbox" "inbox app" "$(rj "$VS_REPORT" 'r["source"]["kind"]') $(rj "$VS_REPORT" 'r["source"]["ref"]')"
  check_eq "report: archive and service" "$(basename "$a") app" "$(rj "$VS_REPORT" 'r["archive"]') $(rj "$VS_REPORT" 'r["service"]')"
  check_eq "checksum checked against the inbox .sha256" pass "$(stage_of "$VS_REPORT" checksum)"
  check_eq "record on Google Drive" 1 "$(drive_count "$(basename "$a").validated.json")"
  check_not "nothing downloaded from Drive" grep -qE "^GET /drive/v3/files/[A-Za-z0-9]+ " "$TVS_DRIVE/requests.log"
  check_eq "job done: the inbox is empty" "0 0" "$(inbox_jobs_of "$inbox") $(inbox_taken_of "$inbox")"

  b=$(fx sqlerror app 20260902-000000)
  id=$(drive_seed_id "$b")
  echo '{"result": "pass"}' > "$T/tmp/old.json"
  python3 "$TVS_DIR/mock_drive.py" seed --root "$TVS_DRIVE" --folder "$TVS_FOLDER" --name "$(basename "$b").validated.json" --file "$T/tmp/old.json" >/dev/null
  rm -f "$T/tmp/old.json"
  inbox_put "$inbox" "$b" move "$(basename "$b")" "$id"
  # shellcheck disable=SC2046
  vs inbox-broken GDRIVE_ACCESS_TOKEN="$TVS_TOKEN" $(drive_env) -- --inbox app --publish
  check_rc "broken inbox snapshot fails" 1
  check_eq "its old record on Drive is revoked" 0 "$(drive_count "$(basename "$b").validated.json")"
  check_eq "the other snapshot's record stays" 1 "$(drive_count "$(basename "$a").validated.json")"
  check_eq "a fail is final: the job is removed" "0 0" "$(inbox_jobs_of "$inbox") $(inbox_taken_of "$inbox")"

  url="gs://wbucket/snapshot-app.tar.zst"
  g=$(fx good app 20260903-000000)
  env FAKE_GCS_ROOT="$T/gcs" bash "$T/fakebin/gcloud" storage cp "$g" "$url" && env FAKE_GCS_ROOT="$T/gcs" bash "$T/fakebin/gcloud" storage cp "$g.sha256" "$url.sha256"
  gen=$(cat "$T/gcs/wbucket/snapshot-app.tar.zst/live")
  inbox_put "$inbox" "$g" move "" "" "$url"
  check_eq "hand-off recorded the GCS generation" "$gen" "$(rj "$(ls -d "$inbox"/app/snapshot-*/ | head -n 1)job.json" 'r["gcs"]["generation"]')"
  : > "$T/gcs/calls.log"
  vs inbox-gcs -- --inbox app --publish
  check_rc "inbox snapshot uploaded to GCS passes" 0
  check "record next to the GCS object" test -s "$T/gcs/wbucket/snapshot-app.tar.zst.validated.json/live"
  env FAKE_GCS_ROOT="$T/gcs" bash "$T/fakebin/gcloud" storage cp "$url.validated.json" "$T/tmp/rec.json"
  check_eq "GCS record: named after the object, pinned to its generation" "snapshot-app.tar.zst $gen" "$(rj "$T/tmp/rec.json" 'r["archive"]') $(rj "$T/tmp/rec.json" 'r["gcs_generation"]')"
  check_eq "GCS record: the archive's sha256" "$(rj "$VS_REPORT" 'r["sha256"]')" "$(rj "$T/tmp/rec.json" 'r["sha256"]')"
  rm -f "$T/tmp/rec.json"
  check_not "nothing downloaded from GCS" grep -q "storage cp $url#" "$T/gcs/calls.log"

  g=$(fx good app 20260904-000000)
  env FAKE_GCS_ROOT="$T/gcs" bash "$T/fakebin/gcloud" storage rm "$url.validated.json" >/dev/null 2>&1
  env FAKE_GCS_ROOT="$T/gcs" bash "$T/fakebin/gcloud" storage cp "$g" "$url"
  inbox_put "$inbox" "$g" move "" "" "$url"
  env FAKE_GCS_ROOT="$T/gcs" bash "$T/fakebin/gcloud" storage cp "$(fx good app 20260905-000000)" "$url"
  vs inbox-gcs-replaced -- --inbox app --publish
  check_rc "GCS object replaced since the hand-off: passes without a record" 4
  check_grep "publish says why" "$VS_REPORT" "now holds a newer snapshot"
  check_not "no record for the newer object" test -s "$T/gcs/wbucket/snapshot-app.tar.zst.validated.json/live"

  kept="$T/wkept/snapshot-app.tar.zst"
  mkdir -p "$T/wkept"
  a=$(fx good app 20260906-000000)
  mv "$a" "$kept" && mv "$a.sha256" "$kept.sha256"
  inbox_put "$inbox" "$kept" link "" "" "" "$kept"
  vs inbox-kept -- --inbox app --publish
  check_rc "kept copy only (no upload): passes" 0
  check_eq "record next to the kept copy, named after it" "pass snapshot-app.tar.zst" "$(rj "$kept.validated.json" 'r["result"]') $(rj "$kept.validated.json" 'r["archive"]')"
  check "the kept copy itself stays" test -f "$kept"
  check_eq "the inbox link is gone" "0 0" "$(inbox_jobs_of "$inbox") $(inbox_taken_of "$inbox")"

  a=$(fx good app 20260907-000000)
  inbox_put "$inbox" "$a" move
  vs inbox-nowhere -- --inbox app --publish
  check_rc "no uploaded or kept copy: passes without a record" 4
  check_grep "publish says why" "$VS_REPORT" "no uploaded or kept copy"

  tvs_section "inbox: errors, leftovers and bad jobs"
  a=$(fx good app 20260908-000000)
  inbox_put "$inbox" "$a" move
  n=$(basename "$(ls -d "$inbox"/app/snapshot-*/)")
  vs inbox-error FAKE_DF_AVAIL=1073741824 -- --inbox app
  check_rc "drill error" 2
  check_eq "the job is back in the inbox, under its name" "$n" "$(basename "$(ls -d "$inbox"/app/snapshot-*/ 2>/dev/null)")"
  check_eq "no taken job left" 0 "$(inbox_taken_of "$inbox")"
  check_grep "says it waits for the next try" "$VS_LOG" "is waiting again"
  mv "$inbox/app/$n" "$inbox/app/.taken-$n-99999999"
  vs inbox-leftover -- --inbox app
  check_rc "a job taken by a drill that died is drilled again" 0
  check_grep "says so" "$VS_LOG" "was taken by a drill that did not finish"
  check_eq "and then done" "0 0" "$(inbox_jobs_of "$inbox") $(inbox_taken_of "$inbox")"
  a=$(fx good app 20260909-000000)
  inbox_put "$inbox" "$a" move
  mkdir -p "$inbox/app/.taken-snapshot-app-20200101-000000.tar.zst-99999999"
  vs inbox-leftover-newer -- --inbox app
  check_rc "a newer job is waiting: drilled" 0
  check_grep "the dead drill's older job is removed" "$VS_LOG" "removed snapshot-app-20200101-000000.tar.zst, left by a drill that did not finish"
  check_eq "nothing left" "0 0" "$(inbox_jobs_of "$inbox") $(inbox_taken_of "$inbox")"
  a=$(fx good app 20260910-000000)
  inbox_put "$inbox" "$a" move
  n=$(ls -d "$inbox"/app/snapshot-*/)
  python3 -c 'import json,sys; p=sys.argv[1]+"job.json"; j=json.load(open(p)); j["service"]="other"; json.dump(j, open(p,"w"))' "$n"
  vs inbox-badjob -- --inbox app
  check_rc "a job.json naming another service is an error" 2
  check_grep "the reason is in the report" "$VS_REPORT" "cannot be drilled"
  check_eq "and the unusable job is removed (not retried forever)" "0 0" "$(inbox_jobs_of "$inbox") $(inbox_taken_of "$inbox")"

  tvs_section "--unless-checksum"
  a=$(fx good app 20261001-000000)
  sha=$(cut -d' ' -f1 "$a.sha256")
  vs unless-bad -- --file "$a" --unless-checksum abc
  check_rc "a value that is not a sha256 is refused" 3
  vs unless-inbox -- --inbox app --unless-checksum "$sha"
  check_rc "not with --inbox" 3
  vs unless-file -- --file "$a" --unless-checksum "$sha"
  check_rc "file: same sha256, nothing to drill" 5
  check_not "no report" test -e "$VS_REPORT"
  vs unless-file-other -- --file "$a" --unless-checksum "$(printf 'x' | sha256sum | cut -d' ' -f1)"
  check_rc "file: other sha256, drilled" 0
  # shellcheck disable=SC2046
  id=$(drive_seed_id "$a")
  : > "$TVS_DRIVE/requests.log"
  # shellcheck disable=SC2046
  vs unless-drive GDRIVE_ACCESS_TOKEN="$TVS_TOKEN" $(drive_env) -- --drive app --unless-checksum "$sha"
  check_rc "Drive: newest is the proved one, nothing to drill" 5
  check_not "the archive was not downloaded" grep -q "^GET /drive/v3/files/$id " "$TVS_DRIVE/requests.log"
  # shellcheck disable=SC2046
  vs unless-drive-other GDRIVE_ACCESS_TOKEN="$TVS_TOKEN" $(drive_env) -- --drive app --unless-checksum "$(printf 'x' | sha256sum | cut -d' ' -f1)"
  check_rc "Drive: another one is drilled" 0
  url="gs://wbucket/unless/snapshot-app.tar.zst"
  env FAKE_GCS_ROOT="$T/gcs" bash "$T/fakebin/gcloud" storage cp "$a" "$url" && env FAKE_GCS_ROOT="$T/gcs" bash "$T/fakebin/gcloud" storage cp "$a.sha256" "$url.sha256"
  : > "$T/gcs/calls.log"
  vs unless-gcs -- --gcs "$url" --unless-checksum "$sha"
  check_rc "GCS: same sha256, nothing to drill" 5
  check_not "GCS: the archive was not downloaded" grep -q "storage cp $url#" "$T/gcs/calls.log"
  drive_stop

  tvs_section "worker: Drive is drilled when there is no inbox snapshot"
  drive_start || return 0
  a=$(fx good app 20261101-000000)
  drive_seed "$a"
  age_reports 25
  # shellcheck disable=SC2046
  wk drive VALIDATOR_WORKER=true GDRIVE_ACCESS_TOKEN="$TVS_TOKEN" $(drive_env)
  check_wk "worker drills the newest Drive snapshot" 0
  check_eq "that one" "$(basename "$a") drive" "$(rj "$(wlatest)" 'r["archive"]') $(rj "$(wlatest)" 'r["source"]["kind"]')"
  check_eq "record on Drive" 1 "$(drive_count "$(basename "$a").validated.json")"
  age_reports 25
  : > "$TVS_DRIVE/requests.log"
  # shellcheck disable=SC2046
  wk drive-same VALIDATOR_WORKER=true GDRIVE_ACCESS_TOKEN="$TVS_TOKEN" $(drive_env)
  check_wk "next day, same Drive snapshot: nothing to do" 0
  check_grep "already proved" "$WK_LOG" "already proved"
  check_eq "only its .sha256 was read" 1 "$(grep -cE '^GET /drive/v3/files/[A-Za-z0-9]+ ' "$TVS_DRIVE/requests.log")"
  drive_stop
  check "no containers left" no_containers
  check "drill queue free" lock_free
}
