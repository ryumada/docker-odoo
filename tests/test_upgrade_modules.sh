#!/usr/bin/env bash
set -e
# Category: Test
# Description: Unit and static tests for scripts/upgrade_modules.sh and sudoers registration.
# Usage: ./tests/test_upgrade_modules.sh
# Dependencies: bash, grep, sed, python3

readonly TEST_COLOR_RESET="\033[0m"
readonly TEST_COLOR_SUCCESS="\033[0;32m"
readonly TEST_COLOR_FAIL="\033[0;31m"
readonly TEST_COLOR_INFO="\033[0;34m"

test_passed=0
test_failed=0

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local test_name="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo -e "${TEST_COLOR_SUCCESS}  [PASS] ${test_name}${TEST_COLOR_RESET}"
    test_passed=$((test_passed + 1))
  else
    echo -e "${TEST_COLOR_FAIL}  [FAIL] ${test_name}: Expected to find '$needle'${TEST_COLOR_RESET}"
    test_failed=$((test_failed + 1))
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local test_name="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    echo -e "${TEST_COLOR_SUCCESS}  [PASS] ${test_name}${TEST_COLOR_RESET}"
    test_passed=$((test_passed + 1))
  else
    echo -e "${TEST_COLOR_FAIL}  [FAIL] ${test_name}: Unexpectedly found '$needle'${TEST_COLOR_RESET}"
    test_failed=$((test_failed + 1))
  fi
}

echo -e "${TEST_COLOR_INFO}Starting unit tests for upgrade_modules.sh...${TEST_COLOR_RESET}"

for f in scripts/upgrade_modules.sh scripts/installer/install_sudoers.sh; do
  if bash -n "$f"; then
    echo -e "${TEST_COLOR_SUCCESS}  [PASS] bash -n $f${TEST_COLOR_RESET}"
    test_passed=$((test_passed + 1))
  else
    echo -e "${TEST_COLOR_FAIL}  [FAIL] bash -n $f${TEST_COLOR_RESET}"
    test_failed=$((test_failed + 1))
  fi
done

script_content=$(cat scripts/upgrade_modules.sh)
sudoers_content=$(cat scripts/installer/install_sudoers.sh)

assert_contains "$script_content" "odoo-module-upgrade" "Calls odoo-module-upgrade"
assert_contains "$script_content" "trigger_registry_reload" "Calls trigger_registry_reload"
assert_contains "$script_content" "modules_to_upgrade" "Emits modules_to_upgrade in JSON"
assert_contains "$script_content" "module_upgrade_log" "Emits module_upgrade_log in JSON on error"
assert_not_contains "$script_content" "docker compose restart" "Never restarts container automatically"
assert_contains "$sudoers_content" '"upgrade_modules"' "install_sudoers.sh registers upgrade_modules"

# Test validation rejects 'all' and invalid module names
set +e
out_all=$(bash scripts/upgrade_modules.sh mydb all json 2>/dev/null)
rc_all=$?
out_bad=$(bash scripts/upgrade_modules.sh mydb "sale;rm -rf /" json 2>/dev/null)
rc_bad=$?
set -e

if [ "$rc_all" -ne 0 ] && echo "$out_all" | grep -q "not allowed"; then
  echo -e "${TEST_COLOR_SUCCESS}  [PASS] Rejects 'all' module keyword${TEST_COLOR_RESET}"
  test_passed=$((test_passed + 1))
else
  echo -e "${TEST_COLOR_FAIL}  [FAIL] Should reject 'all' module keyword (rc=$rc_all, out=$out_all)${TEST_COLOR_RESET}"
  test_failed=$((test_failed + 1))
fi

if [ "$rc_bad" -ne 0 ] && echo "$out_bad" | grep -q "Invalid module technical name"; then
  echo -e "${TEST_COLOR_SUCCESS}  [PASS] Rejects invalid module technical names${TEST_COLOR_RESET}"
  test_passed=$((test_passed + 1))
else
  echo -e "${TEST_COLOR_FAIL}  [FAIL] Should reject invalid module technical names (rc=$rc_bad, out=$out_bad)${TEST_COLOR_RESET}"
  test_failed=$((test_failed + 1))
fi

echo ""
echo "Summary: $test_passed passed, $test_failed failed."
if [ "$test_failed" -gt 0 ]; then
  exit 1
fi
