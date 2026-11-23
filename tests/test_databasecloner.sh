#!/usr/bin/env bash
set -e
# Category: Test
# Description: Unit and behavioral tests for databasecloner scripts, setup.sh installer, and sudoers config.
# Usage: ./tests/test_databasecloner.sh
# Dependencies: bash, grep, sed, mktemp, python3, base64

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

echo -e "${TEST_COLOR_INFO}Starting unit tests for databasecloner scripts...${TEST_COLOR_RESET}"

TEST_TEMP_DIR=$(mktemp -d /tmp/test_db_cloner_XXXXXX)
cleanup() {
  rm -rf "$TEST_TEMP_DIR"
}
trap cleanup EXIT

# Test 1: Bash syntax verification
echo -e "\n${TEST_COLOR_INFO}Test 1: Bash syntax checks${TEST_COLOR_RESET}"
for f in setup.sh scripts/installer/install_sudoers.sh scripts/example/databasecloner_manual.sh.example scripts/example/databasecloner.sh.example; do
  if bash -n "$f"; then
    echo -e "${TEST_COLOR_SUCCESS}  [PASS] bash -n $f${TEST_COLOR_RESET}"
    test_passed=$((test_passed + 1))
  else
    echo -e "${TEST_COLOR_FAIL}  [FAIL] bash -n $f${TEST_COLOR_RESET}"
    test_failed=$((test_failed + 1))
  fi
done

# Test 2: Static verification for Cross-VPS PRD_SSH_* support & JSON safety
echo -e "\n${TEST_COLOR_INFO}Test 2: Static verification - Cross-VPS & JSON features${TEST_COLOR_RESET}"
cloner_manual=$(cat scripts/example/databasecloner_manual.sh.example)
cloner_endpoint=$(cat scripts/example/databasecloner.sh.example)
setup_content=$(cat setup.sh)
sudoers_content=$(cat scripts/installer/install_sudoers.sh)

for label_content in "databasecloner_manual:$cloner_manual" "databasecloner_endpoint:$cloner_endpoint"; do
  label="${label_content%%:*}"
  content="${label_content#*:}"
  assert_contains "$content" "PRD_SSH_HOST" "$label: Supports PRD_SSH_HOST"
  assert_contains "$content" "ensure_ssh_key_for_remote" "$label: Calls ensure_ssh_key_for_remote"
  assert_contains "$content" "export_filestore" "$label: Supports export_filestore helper"
  assert_contains "$content" "dump_database" "$label: Supports dump_database helper"
  assert_contains "$content" "remote_dump_b64=" "$label: Has base64 container pg_dump fallback"
  assert_contains "$content" "restore_via_odoo_container" "$label: Has restore_via_odoo_container"
  assert_contains "$content" "sanitize_database" "$label: Supports database neutralization"
  assert_contains "$content" "trigger_registry_reload" "$label: Calls trigger_registry_reload"
  assert_contains "$content" "module_upgrade_log" "$label: Emits module_upgrade_log in JSON"
  error_echo_count=$(echo "$content" | grep -cF 'echo "{\"error\":' || true)
  if [ "$error_echo_count" -eq 1 ]; then
    echo -e "${TEST_COLOR_SUCCESS}  [PASS] $label: Emits error JSON solely via log_error${TEST_COLOR_RESET}"
    test_passed=$((test_passed + 1))
  else
    echo -e "${TEST_COLOR_FAIL}  [FAIL] $label: Expected exactly 1 error JSON echo (in log_error), found $error_echo_count${TEST_COLOR_RESET}"
    test_failed=$((test_failed + 1))
  fi
  assert_contains "$content" "fail_with_json" "$label: Uses fail_with_json helper"

  b64_payload=$(echo "$content" | grep 'remote_dump_b64=' | cut -d '"' -f 2)
  if [ -n "$b64_payload" ] && echo "$b64_payload" | base64 -d | bash -n 2>/dev/null; then
    echo -e "${TEST_COLOR_SUCCESS}  [PASS] $label: base64 payload has valid bash syntax${TEST_COLOR_RESET}"
    test_passed=$((test_passed + 1))
  else
    echo -e "${TEST_COLOR_FAIL}  [FAIL] $label: base64 payload missing or invalid syntax${TEST_COLOR_RESET}"
    test_failed=$((test_failed + 1))
  fi
done

# Test 3: setup.sh and install_sudoers.sh checks
echo -e "\n${TEST_COLOR_INFO}Test 3: Installer & sudoers configuration checks${TEST_COLOR_RESET}"
assert_not_contains "$setup_content" 'if [ -n "$ENABLE_DATABASE_CLONER" ]; then' "setup.sh installs databasecloner unconditionally"
assert_contains "$setup_content" 'install-databasecloner.sh' "setup.sh invokes install-databasecloner.sh"
assert_contains "$sudoers_content" 'append_sudoers_rule "devops" "scripts" "databasecloner-$SERVICE_NAME"' "install_sudoers.sh grants devops sudo for databasecloner"
assert_contains "$sudoers_content" 'append_sudoers_rule "odoo" "scripts" "databasecloner-$SERVICE_NAME"' "install_sudoers.sh grants odoo sudo for databasecloner"

# Test 4: Behavioral tests with mocked environment
echo -e "\n${TEST_COLOR_INFO}Test 4: Behavioral tests for routing & Cross-VPS SSH failure JSON${TEST_COLOR_RESET}"
run_mock_cloner_test() {
  local script_src="$1"
  local test_name="$2"
  local proj_dir="$TEST_TEMP_DIR/${test_name}/myproject"
  local mock_bin="$TEST_TEMP_DIR/${test_name}/bin"
  mkdir -p "$proj_dir/scripts/lib" "$mock_bin"
  git -C "$proj_dir" init -q

  cp "$script_src" "$proj_dir/scripts/databasecloner-myproject.sh"
  cp scripts/lib/odoo_utils.sh "$proj_dir/scripts/lib/odoo_utils.sh"
  cp scripts/lib/ssh_utils.sh "$proj_dir/scripts/lib/ssh_utils.sh"
  chmod +x "$proj_dir/scripts/databasecloner-myproject.sh"

  cat <<'MOCK_ID' > "$mock_bin/id"
#!/usr/bin/env bash
if [ "$1" = "-u" ]; then
  echo "0"
else
  /usr/bin/id "$@"
fi
MOCK_ID
  chmod +x "$mock_bin/id"

  cat <<'MOCK_SUDO' > "$mock_bin/sudo"
#!/usr/bin/env bash
if [ "$1" = "-u" ]; then
  shift 2
  exec "$@"
else
  exec "$@"
fi
MOCK_SUDO
  chmod +x "$mock_bin/sudo"

  cat <<'MOCK_SSH' > "$mock_bin/ssh"
#!/usr/bin/env bash
exit 255
MOCK_SSH
  chmod +x "$mock_bin/ssh"

  # Note: directory basename 'myproject' has NO hyphen (cross-VPS staging VPS scenario)
  cat <<EOF > "$proj_dir/.env"
DB_NAME=myproject_stg
PRD_SSH_HOST=10.20.30.40
PRD_SSH_USER=devops
PRD_SSH_PORT=22
PRD_SSH_KEY=$TEST_TEMP_DIR/${test_name}/fake_key
PRD_SSH_PATH=/opt/myproject
EOF
  touch "$TEST_TEMP_DIR/${test_name}/fake_key"

  local out=""
  set +e
  out=$(PATH="$mock_bin:$PATH" "$proj_dir/scripts/databasecloner-myproject.sh" "" "" json 2>/dev/null)
  local rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    echo -e "${TEST_COLOR_SUCCESS}  [PASS] ${test_name}: Exits non-zero on SSH failure (rc=$rc)${TEST_COLOR_RESET}"
    test_passed=$((test_passed + 1))
  else
    echo -e "${TEST_COLOR_FAIL}  [FAIL] ${test_name}: Expected non-zero exit code on SSH failure${TEST_COLOR_RESET}"
    test_failed=$((test_failed + 1))
  fi

  # Verify stdout is a single valid JSON object (meaning main() routed to pull mode without '-stg' suffix and emitted clean JSON)
  if python3 - "$out" <<'PY'
import json, sys
raw = sys.argv[1].strip()
data = json.loads(raw)
assert isinstance(data, dict), f"Expected dict, got {type(data)}"
assert "error" in data, f"Missing 'error' key in {data}"
assert "10.20.30.40" in data["error"], f"Unexpected error message: {data['error']}"
PY
  then
    echo -e "${TEST_COLOR_SUCCESS}  [PASS] ${test_name}: Routes non-hyphen SERVICE_NAME in json mode to Cross-VPS pull mode with single valid JSON error${TEST_COLOR_RESET}"
    test_passed=$((test_passed + 1))
  else
    echo -e "${TEST_COLOR_FAIL}  [FAIL] ${test_name}: Invalid or unexpected JSON stdout: $out${TEST_COLOR_RESET}"
    test_failed=$((test_failed + 1))
  fi
}

run_mock_cloner_test "scripts/example/databasecloner_manual.sh.example" "manual_mode"
run_mock_cloner_test "scripts/example/databasecloner.sh.example" "endpoint_mode"

echo -e "\n=========================================="
echo -e "Test Results: ${TEST_COLOR_SUCCESS}${test_passed} passed${TEST_COLOR_RESET}, ${TEST_COLOR_FAIL}${test_failed} failed${TEST_COLOR_RESET}"
echo -e "=========================================="

if [ "$test_failed" -gt 0 ]; then
  exit 1
fi
exit 0
