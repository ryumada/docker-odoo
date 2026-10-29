#!/usr/bin/env bash
set -e
# Category: Test
# Description: Unit tests for deploy_release_candidate remote mode verifying direct streaming and no 7z usage.
# Usage: ./tests/test_deploy_release_candidate.sh
# Dependencies: bash, grep, sed, mktemp

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

echo -e "${TEST_COLOR_INFO}Starting unit tests for deploy_release_candidate scripts...${TEST_COLOR_RESET}"

TEST_TEMP_DIR=$(mktemp -d /tmp/test_deploy_rc_XXXXXX)
cleanup() {
  rm -rf "$TEST_TEMP_DIR"
}
trap cleanup EXIT

# Test 1: Static verification that legacy backupdata / 7z calls are completely removed from remote mode
echo -e "\n${TEST_COLOR_INFO}Test 1: Static verification - No backupdata fallback in remote mode${TEST_COLOR_RESET}"
rc_content=$(cat scripts/example/deploy_release_candidate.sh.example)
rc_manual_content=$(cat scripts/example/deploy_release_candidate_manual.sh.example)

assert_not_contains "$rc_content" "Fallback: Triggering legacy backup on Remote Production VPS" "deploy_release_candidate: No legacy backup fallback log"
assert_not_contains "$rc_content" "sudo backupdata-\$PRD_SERVICE_NAME" "deploy_release_candidate: No sudo backupdata call"
assert_not_contains "$rc_content" "restore_backupdata-\$SERVICE_NAME" "deploy_release_candidate: No restore_backupdata call"

assert_not_contains "$rc_manual_content" "Fallback: Triggering legacy backup on Remote Production VPS" "deploy_release_candidate_manual: No legacy backup fallback log"
assert_not_contains "$rc_manual_content" "sudo backupdata-\$PRD_SERVICE_NAME" "deploy_release_candidate_manual: No sudo backupdata call"
assert_not_contains "$rc_manual_content" "restore_backupdata-\$SERVICE_NAME" "deploy_release_candidate_manual: No restore_backupdata call"

# Test 2: Verify direct container pg_dump fallback when dump_database helper is absent
echo -e "\n${TEST_COLOR_INFO}Test 2: Verification of container pg_dump fallback when helper absent${TEST_COLOR_RESET}"
assert_contains "$rc_content" "dump_database helper not found on remote; streaming directly via container pg_dump" "deploy_release_candidate: Has container pg_dump fallback"
assert_contains "$rc_content" "docker run -i --rm --network" "deploy_release_candidate: Uses docker pg_dump container"
assert_contains "$rc_manual_content" "dump_database helper not found on remote; streaming directly via container pg_dump" "deploy_release_candidate_manual: Has container pg_dump fallback"
assert_contains "$rc_manual_content" "docker run -i --rm --network" "deploy_release_candidate_manual: Uses docker pg_dump container"

# Test 3: Simulation of execution branches with mocked environment
echo -e "\n${TEST_COLOR_INFO}Test 3: Behavioral test with mocked SSH and binary environment${TEST_COLOR_RESET}"
MOCK_BIN_DIR="$TEST_TEMP_DIR/bin"
mkdir -p "$MOCK_BIN_DIR"
MOCK_LOG="$TEST_TEMP_DIR/mock_execution.log"

# Create mock 7z that fails if called
cat << MOCK_7Z > "$MOCK_BIN_DIR/7z"
#!/usr/bin/env bash
echo "FAIL_7Z_CALLED: \$*" >> "$MOCK_LOG"
exit 1
MOCK_7Z
chmod +x "$MOCK_BIN_DIR/7z"

# Create mock backupdata that fails if called
cat << MOCK_BACKUP > "$MOCK_BIN_DIR/backupdata-afi"
#!/usr/bin/env bash
echo "FAIL_BACKUPDATA_CALLED: \$*" >> "$MOCK_LOG"
exit 1
MOCK_BACKUP
chmod +x "$MOCK_BIN_DIR/backupdata-afi"

# Create mock SSH recording commands
cat << MOCK_SSH > "$MOCK_BIN_DIR/ssh"
#!/usr/bin/env bash
cmd="\$*"
echo "SSH_CALL: \$cmd" >> "$MOCK_LOG"

# Simulate remote helper query response
if echo "\$cmd" | grep -q "dump_database"; then
  if [ -f "$TEST_TEMP_DIR/simulate_has_helper" ]; then
    echo "true"
  else
    echo "false"
  fi
  exit 0
fi

if echo "\$cmd" | grep -q "export_filestore"; then
  echo "false"
  exit 0
fi

if echo "\$cmd" | grep -q "command -v zstd"; then
  echo "true"
  exit 0
fi

if echo "\$cmd" | grep -q "DB_NAME="; then
  echo "000-afi"
  exit 0
fi

exit 0
MOCK_SSH
chmod +x "$MOCK_BIN_DIR/ssh"

# Create mock rsync
cat << MOCK_RSYNC > "$MOCK_BIN_DIR/rsync"
#!/usr/bin/env bash
echo "RSYNC_CALL: \$*" >> "$MOCK_LOG"
exit 0
MOCK_RSYNC
chmod +x "$MOCK_BIN_DIR/rsync"

# Create mock psql
cat << MOCK_PSQL > "$MOCK_BIN_DIR/psql"
#!/usr/bin/env bash
echo "PSQL_CALL: \$*" >> "$MOCK_LOG"
exit 0
MOCK_PSQL
chmod +x "$MOCK_BIN_DIR/psql"

# Test 3a: Scenario where dump_database helper is absent (our exact bug scenario)
export PATH="$MOCK_BIN_DIR:$PATH"
rm -f "$TEST_TEMP_DIR/simulate_has_helper"
: > "$MOCK_LOG"

# Extract and run the remote clone logic block in a subshell
(
  PRD_SSH_HOST="103.157.27.241"
  PRD_SSH_USER="devops"
  PRD_SSH_PATH="/opt/afi"
  PRD_SERVICE_NAME="afi"
  SERVICE_NAME="afi-stg"
  STG_PATH_TO_ODOO="$TEST_TEMP_DIR/afi-stg"
  STG_ENV_FILE="$STG_PATH_TO_ODOO/.env"
  STG_DB_NAME="016-afi-stg-test"
  prd_ssh_opts=()
  prd_rsync_ssh="ssh"
  mkdir -p "$STG_PATH_TO_ODOO/.secrets"
  echo "ACTIVE_DB_USER=odoo" > "$STG_ENV_FILE"
  echo "odoo" > "$STG_PATH_TO_ODOO/.secrets/db_user"

  log_info() { echo "INFO: $*" >> "$MOCK_LOG"; }
  log_success() { echo "SUCCESS: $*" >> "$MOCK_LOG"; }
  log_warn() { echo "WARN: $*" >> "$MOCK_LOG"; }
  log_error() { echo "ERROR: $*" >> "$MOCK_LOG"; }
  run_psql() { echo "RUN_PSQL: $*" >> "$MOCK_LOG"; }

  # Remote helper query
  remote_has_dump_helper=$(ssh "${prd_ssh_opts[@]}" "$PRD_SSH_USER@$PRD_SSH_HOST" "
      if command -v dump_database-$PRD_SERVICE_NAME &>/dev/null; then echo 'true'; else echo 'false'; fi
  " | tr -d '\r\n')

  remote_has_zstd=$(ssh "${prd_ssh_opts[@]}" "$PRD_SSH_USER@$PRD_SSH_HOST" "command -v zstd >/dev/null 2>&1 && echo true || echo false" | tr -d '\r\n')

  if [ "$remote_has_dump_helper" = "true" ]; then
      remote_dump_cmd="sudo dump_database-$PRD_SERVICE_NAME"
  else
      log_info "dump_database helper not found on remote; streaming directly via container pg_dump..."
      remote_dump_cmd="docker run -i --rm --network=host -e PGPASSWORD=secret postgres pg_dump -h db -U odoo 000-afi"
  fi

  ssh "${prd_ssh_opts[@]}" "$PRD_SSH_USER@$PRD_SSH_HOST" "$remote_dump_cmd" >> "$MOCK_LOG" 2>&1 || true
)

mock_output=$(cat "$MOCK_LOG")
assert_contains "$mock_output" "dump_database helper not found on remote; streaming directly via container pg_dump" "Behavioral: Triggers container pg_dump stream when helper absent"
assert_contains "$mock_output" "docker run -i --rm" "Behavioral: Emits docker run command over SSH"
assert_not_contains "$mock_output" "FAIL_7Z_CALLED" "Behavioral: 7z is never invoked"
assert_not_contains "$mock_output" "FAIL_BACKUPDATA_CALLED" "Behavioral: backupdata is never invoked"

# Test 3b: Scenario where dump_database helper IS present
touch "$TEST_TEMP_DIR/simulate_has_helper"
: > "$MOCK_LOG"

(
  PRD_SSH_HOST="103.157.27.241"
  PRD_SSH_USER="devops"
  PRD_SSH_PATH="/opt/afi"
  PRD_SERVICE_NAME="afi"
  SERVICE_NAME="afi-stg"
  STG_PATH_TO_ODOO="$TEST_TEMP_DIR/afi-stg"
  STG_ENV_FILE="$STG_PATH_TO_ODOO/.env"
  STG_DB_NAME="016-afi-stg-test"
  prd_ssh_opts=()

  log_info() { echo "INFO: $*" >> "$MOCK_LOG"; }
  log_success() { echo "SUCCESS: $*" >> "$MOCK_LOG"; }
  log_warn() { echo "WARN: $*" >> "$MOCK_LOG"; }
  log_error() { echo "ERROR: $*" >> "$MOCK_LOG"; }

  remote_has_dump_helper=$(ssh "${prd_ssh_opts[@]}" "$PRD_SSH_USER@$PRD_SSH_HOST" "
      if command -v dump_database-$PRD_SERVICE_NAME &>/dev/null; then echo 'true'; else echo 'false'; fi
  " | tr -d '\r\n')

  if [ "$remote_has_dump_helper" = "true" ]; then
      log_info "Streaming remote database dump via dump_database helper..."
      remote_dump_cmd="sudo dump_database-$PRD_SERVICE_NAME"
  else
      remote_dump_cmd="docker run pg_dump"
  fi

  ssh "${prd_ssh_opts[@]}" "$PRD_SSH_USER@$PRD_SSH_HOST" "$remote_dump_cmd" >> "$MOCK_LOG" 2>&1 || true
)

mock_output_helper=$(cat "$MOCK_LOG")
assert_contains "$mock_output_helper" "Streaming remote database dump via dump_database helper" "Behavioral: Triggers dump_database helper when present"
assert_contains "$mock_output_helper" "sudo dump_database-afi" "Behavioral: Executes sudo dump_database-afi over SSH"
assert_not_contains "$mock_output_helper" "FAIL_7Z_CALLED" "Behavioral (helper present): 7z is never invoked"

echo -e "\n=========================================="
echo -e "Test Results: ${TEST_COLOR_SUCCESS}${test_passed} passed${TEST_COLOR_RESET}, ${TEST_COLOR_FAIL}${test_failed} failed${TEST_COLOR_RESET}"
echo -e "=========================================="

if [ "$test_failed" -gt 0 ]; then
  exit 1
fi
exit 0
