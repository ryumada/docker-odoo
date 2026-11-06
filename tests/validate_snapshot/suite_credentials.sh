#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: Google Drive credential handling: service-account formats, no secrets on curl's command line or in leftovers.
# Usage: sourced by tests/test_validate_snapshot.sh (suite "credentials"); needs tests/validate_snapshot/lib.sh
# Dependencies: lib.sh, mkfixture.sh, mock_drive.py, openssl, fake docker/df, PostgreSQL server binaries

make_curl_spy() {
  # A curl wrapper that logs its argv, and the contents of every @file argument, then runs the real curl
  local real
  real=$(PATH="$TVS_ORIG_PATH" command -v curl)
  mkdir -p "$T/curlbin"
  cat > "$T/curlbin/curl" <<EOF
#!/usr/bin/env bash
printf 'ARGV:' >> "$T/curl_argv.log"; printf ' %q' "\$@" >> "$T/curl_argv.log"; echo >> "$T/curl_argv.log"
for a in "\$@"; do
  case "\$a" in
    *@*) f="\${a#*@}"; [ -f "\$f" ] && { echo "FILE \$f:"; cat "\$f"; echo; } >> "$T/curl_files.log" ;;
  esac
done
exec "$real" "\$@"
EOF
  chmod 755 "$T/curlbin/curl"
  : > "$T/curl_argv.log"; : > "$T/curl_files.log"
}

verify_jwt() {
  # verify_jwt ASSERTION_FILE PUBKEY CLIENT_EMAIL TOKEN_URI   RS256 signature and claims
  python3 - "$@" <<'PY'
import base64, json, subprocess, sys, tempfile, os
jwt, pub, email, uri = open(sys.argv[1]).read().strip(), sys.argv[2], sys.argv[3], sys.argv[4]
h, c, s = jwt.split(".")
d = lambda x: base64.urlsafe_b64decode(x + "=" * (-len(x) % 4))
claims = json.loads(d(c))
assert json.loads(d(h)) == {"alg": "RS256", "typ": "JWT"}
assert claims["iss"] == email and claims["aud"] == uri and claims["scope"].endswith("/auth/drive")
assert claims["exp"] - claims["iat"] == 3600
with tempfile.TemporaryDirectory() as t:
    open(os.path.join(t, "data"), "w").write(h + "." + c)
    open(os.path.join(t, "sig"), "wb").write(d(s))
    subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub, "-signature", os.path.join(t, "sig"),
                    os.path.join(t, "data")], check=True, capture_output=True)
PY
}

suite_credentials() {
  # shellcheck disable=SC2034
  TVS_SUITE=credentials
  local a spy envs sa pretty
  drive_start || return 0
  a=$(fx good cred 20260201-000000)
  drive_seed "$a"
  make_curl_spy
  spy="PATH=$T/curlbin:$T/fakebin:$T/cbin:$TVS_ORIG_PATH"
  envs="GDS_API_BASE=$TVS_DRIVE_URL GDRIVE_FOLDER_ID=$TVS_FOLDER"
  sa="$T/home/sa.json"
  make_sa "$sa"

  tvs_section "credentials: service-account key formats"
  pretty=$(printf '\n'; cat "$sa")
  # shellcheck disable=SC2086
  vs sa-pasted "$spy" $envs GDRIVE_SERVICE_ACCOUNT_KEY="$pretty" -- --drive cred
  check_rc "SA JSON pasted with a leading newline, pretty-printed" 0
  # shellcheck disable=SC2086
  vs sa-file "$spy" $envs GDRIVE_SERVICE_ACCOUNT_KEY="$sa" -- --drive cred
  check_rc "SA key file" 0
  # shellcheck disable=SC2086
  vs sa-as-token "$spy" $envs GDRIVE_ACCESS_TOKEN="$sa" -- --drive cred
  check_rc "SA key given as the token file" 0
  # shellcheck disable=SC2086
  vs raw-token "$spy" $envs GDRIVE_ACCESS_TOKEN="$TVS_TOKEN" -- --drive cred
  check_rc "plain access token" 0
  check_not "every Drive call was authorized" grep -q "auth=BAD" "$TVS_DRIVE/requests.log"

  tvs_section "credentials: an invalid key is never echoed"
  # shellcheck disable=SC2086
  vs sa-invalid "$spy" $envs GDRIVE_SERVICE_ACCOUNT_KEY="not-json-SECRETKEYVALUE42" -- --drive cred
  check_rc "invalid key value is an error" 2
  check_no_grep "invalid key not in the log" "$VS_LOG" "SECRETKEYVALUE42"
  check_no_grep "invalid key not in the report" "$VS_REPORT" "SECRETKEYVALUE42"
  check_grep "the log says what is wrong" "$VS_LOG" "neither a readable file nor JSON content"
  # shellcheck disable=SC2086
  vs sa-broken "$spy" $envs GDRIVE_SERVICE_ACCOUNT_KEY='{"type": "service_account", "private_key": "SECRETKEYVALUE43"}' -- --drive cred
  check_rc "unparsable key JSON is an error" 2
  check_no_grep "unparsable key not in the log" "$VS_LOG" "SECRETKEYVALUE43"

  tvs_section "credentials: secrets never on curl's command line"
  check_no_grep "access token not on curl argv" "$T/curl_argv.log" "$TVS_TOKEN"
  check_no_grep "no JWT on curl argv" "$T/curl_argv.log" "eyJ"
  check_no_grep "no private key on curl argv" "$T/curl_argv.log" "PRIVATE KEY"
  check_grep "the token went through a header file" "$T/curl_files.log" "Authorization: Bearer $TVS_TOKEN"
  check_grep "the JWT went through an @file" "$T/curl_files.log" "eyJ"
  check_grep "assertion sent with --data-urlencode assertion@file" "$T/curl_argv.log" "--data-urlencode assertion@"
  check "the JWT signature verifies with the SA public key" \
    verify_jwt "$TVS_DRIVE/last_assertion" "$sa.pub" "drill@tvs-test.iam.gserviceaccount.com" "$TVS_DRIVE_URL/token"

  tvs_section "credentials: no temporary credential files left"
  check_eq "temporary folder empty" "" "$(ls -A "$T/tmp" 2>/dev/null)"
  check_eq "no file with the token in the work folders" "" "$(grep -rlF -- "$TVS_TOKEN" "$T/tmp" "$T/vwork" "$T/home" "$T/reports" "$T/locks" 2>/dev/null)"
  check_eq "no file with a JWT in the work folders" "" "$(grep -rlF -- "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9" "$T/tmp" "$T/vwork" "$T/home" "$T/reports" 2>/dev/null)"
  check "no work folders left" runs_empty
  drive_stop
}
