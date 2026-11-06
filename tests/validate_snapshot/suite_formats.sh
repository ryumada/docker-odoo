#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: Older snapshot layout for validate-snapshot.sh: dump.sql, manifest.json and filestore/ inside backupdata-<service>.zip in the archive.
# Usage: sourced by tests/test_validate_snapshot.sh (suite "formats"); needs tests/validate_snapshot/lib.sh
# Dependencies: lib.sh, mkfixture.sh (oldzip variants), fake docker/df, PostgreSQL server binaries

suite_formats() {
  # shellcheck disable=SC2034
  TVS_SUITE=formats
  local a r

  tvs_section "formats: older snapshot (backupdata-<service>.zip inside the archive)"
  a=$(fx oldzip)
  vs oldzip -- --file "$a" --publish
  check_rc "older-layout snapshot passes" 0
  r="$VS_REPORT"
  for s in fetch checksum archive structure manifest git disk database filestore; do
    check_eq "stage $s passed" pass "$(stage_of "$r" "$s")"
  done
  check_eq "the report names the older layout and the zip" "older: backupdata-svc.zip inside the archive" "$(stage_of "$r" structure format)"
  check_eq "dump.sql is read from inside the zip" dump.sql "$(stage_of "$r" structure dump_sql)"
  check_eq "all 20 attachments found in the zip's filestore" 20 "$(stage_of "$r" filestore files_in_archive)"
  check_eq "database restored from the zip (2 users)" 2 "$(rj "$r" 'r["database"]["users"]')"
  check "a record is published for an older-layout snapshot" test -e "$a.validated.json"
  check_eq "fetch reports the real archive size" "$(stat -c %s "$a")" "$(stage_of "$r" fetch bytes)"
  check "no drill container left" no_containers

  tvs_section "formats: broken older snapshots"
  a=$(fx oldzip-corrupt)
  vs oldzip-corrupt -- --file "$a"
  check_rc "a file in the zip that fails its CRC" 1
  check_eq "structure stage fails" fail "$(stage_of "$VS_REPORT" structure)"
  check_grep "the zip is named as corrupted" "$VS_REPORT" "backupdata-svc.zip is corrupted"
  check "nothing restored from a corrupted zip" no_containers

  a=$(fx oldzip-nodump)
  vs oldzip-nodump -- --file "$a"
  check_rc "a zip without dump.sql" 1
  check_grep "the report says it looked inside the zip" "$VS_REPORT" "(and from backupdata-svc.zip): dump.sql"

  a=$(fx oldzip-missing)
  vs oldzip-missing -- --file "$a"
  check_rc "attachments missing from the zip" 1
  check_eq "filestore stage fails" fail "$(stage_of "$VS_REPORT" filestore)"
  check_eq "5 attachments reported missing" 5 "$(stage_of "$VS_REPORT" filestore missing)"

  a=$(fx oldzip-linkfs)
  vs oldzip-linkfs -- --file "$a"
  check_rc "filestore stored as a symlink in the zip (nothing to restore)" 1
  check_eq "filestore stage fails" fail "$(stage_of "$VS_REPORT" filestore)"

  tvs_section "formats: the current layout is unaffected"
  a=$(fx good)
  vs current -- --file "$a"
  check_rc "current-layout snapshot passes" 0
  check_eq "the report says current layout" current "$(stage_of "$VS_REPORT" structure format)"
}
