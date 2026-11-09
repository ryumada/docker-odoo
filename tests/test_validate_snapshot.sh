#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: Test suite for scripts/validate-snapshot.sh (local drills, older zip snapshots, Odoo version, Drive/GCS storage, credentials, rootless Docker, the Odoo boot check, remote SSH mode), scripts/setup-validator-docker.sh, and the Odoo version reader in scripts/example/snapshot.sh.example.
# Usage: ./tests/test_validate_snapshot.sh [local|formats|version|storage|credentials|rootless|setup|boot|remote|all]   (run from the repo root; TVS_KEEP=1 keeps the work folder)
# Dependencies: bash, python3, zstd, tar, git, curl, openssl, flock, PostgreSQL server binaries (PG_BIN), ssh + sshd (remote suite)
#
# Safe on a real VPS or dev machine: everything happens inside one mktemp folder that is removed at
# the end; the validator runs from a copy of scripts/ with an empty .env; docker, df and gcloud are
# fakes (a "container" is a throwaway local Postgres on 127.0.0.1); Google Drive is a local mock;
# the remote suite starts its own sshd on 127.0.0.1 and never reads or writes ~/.ssh.
# Exit code: 0 all checks passed (skips allowed), 1 a check failed, 3 missing dependency or bad usage.
# TVS_VERBOSE=1 prints the end of the validator log under each failed check.

REPO_ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
SUITE="${1:-all}"
case "$SUITE" in
  local|formats|version|storage|credentials|rootless|setup|boot|remote|all) ;;
  -h|--help) sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "Usage: $0 [local|formats|version|storage|credentials|rootless|setup|boot|remote|all]" >&2; exit 3 ;;
esac
if [ ! -f "$REPO_ROOT/scripts/validate-snapshot.sh" ]; then
  echo "scripts/validate-snapshot.sh not found under $REPO_ROOT" >&2
  exit 3
fi

# shellcheck source=validate_snapshot/lib.sh
source "$REPO_ROOT/tests/validate_snapshot/lib.sh"
for s in local formats version storage credentials rootless setup boot remote; do
  # shellcheck source=/dev/null
  source "$REPO_ROOT/tests/validate_snapshot/suite_$s.sh"
done

trap 'tvs_cleanup' EXIT
trap 'echo; echo "Interrupted." >&2; exit 130' INT TERM

echo -e "${TVS_C_INFO}Starting validate-snapshot tests ($SUITE)...${TVS_C_RESET}"
tvs_setup "$REPO_ROOT"
started=$(date +%s)

if [ "$SUITE" = all ]; then
  suite_local; suite_formats; suite_version; suite_storage; suite_credentials; suite_rootless; suite_setup; suite_boot; suite_remote
else
  "suite_$SUITE"
fi

echo
echo -e "${TVS_C_INFO}Results ($SUITE, $(( $(date +%s) - started ))s): ${TVS_C_PASS}${TVS_PASSED} passed${TVS_C_RESET}, ${TVS_C_FAIL}${TVS_FAILED} failed${TVS_C_RESET}, ${TVS_C_SKIP}${TVS_SKIPPED} skipped${TVS_C_RESET}"
if [ "$TVS_FAILED" -gt 0 ]; then
  printf '  - %s\n' "${TVS_FAILURES[@]}"
  exit 1
fi
exit 0
