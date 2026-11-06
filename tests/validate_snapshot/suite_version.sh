#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: Odoo version: how scripts/lib/odoo_version.sh reads it from odoo/release.py (used by the snapshot tool
#              and by the backup tools' fallback), and how validate-snapshot.sh checks manifest.json against the database.
# Usage: sourced by tests/test_validate_snapshot.sh (suite "version"); needs tests/validate_snapshot/lib.sh
# Dependencies: lib.sh, mkfixture.sh (odoomanifest, buggyversion, wrongversion, noversion), python3, PostgreSQL server binaries

# Writes an odoo/release.py the way Odoo lays it out (version_info literal, the rest computed from it)
ver_release_py() {
  # ver_release_py DEPLOYMENT_DIR MAJOR MINOR   (MAJOR may be a string such as saas~17)
  local d="$1/odoo-base/odoo/odoo" major="$2" minor="$3"
  [[ "$major" =~ ^[0-9]+$ ]] || major="'$major'"
  mkdir -p "$d"
  cat > "$d/release.py" <<EOF
RELEASE_LEVELS = [ALPHA, BETA, RELEASE_CANDIDATE, FINAL] = ['alpha', 'beta', 'candidate', 'final']
RELEASE_LEVELS_DISPLAY = {ALPHA: ALPHA, BETA: BETA, RELEASE_CANDIDATE: 'rc', FINAL: ''}
version_info = ($major, $minor, 0, FINAL, 0, '')
series = serie = major_version = '.'.join(str(s) for s in version_info[:2])
product_name = 'Odoo'
version = series + RELEASE_LEVELS_DISPLAY[version_info[3]] + str(version_info[4] or '') + version_info[5]
EOF
}

# Runs the snapshot tool's extract_odoo_version_info (which uses scripts/lib/odoo_version.sh) against one
# deployment folder. Prints "version|major_version|version_info" and leaves the log in $T/ver/<name>.log
snap_version() {
  local dep="$1" name
  name=$(basename "$dep")
  ( set +o pipefail; set -e   # the snapshot tool's own shell options
    log_info() { echo "INFO $1" >> "$T/ver/$name.log"; }
    log_warn() { echo "WARN $1" >> "$T/ver/$name.log"; }
    # shellcheck source=/dev/null
    source "$T/app/scripts/lib/odoo_version.sh"
    eval "$(sed -n '/^function extract_odoo_version_info()/,/^}/p' "$T/app/scripts/example/snapshot.sh.example")"
    PATH_TO_ODOO="$dep"
    extract_odoo_version_info
    echo "$MANIFEST_VERSION|$MANIFEST_MAJOR_VERSION|$MANIFEST_VERSION_INFO"
  )
}

# Runs a backup tool's generate_manifest with the database query failing, so its fallback writes the
# manifest. Prints the manifest's "version|version_info" ("" when it is not valid JSON).
backup_fallback_manifest() {
  # backup_fallback_manifest SCRIPT DEPLOYMENT_DIR
  local script="$1" dep="$2" out="$T/ver/manifest-$RANDOM.json"
  ( set +o pipefail; set -e
    log_info() { :; }; log_warn() { echo "WARN $1" >> "$T/ver/backup.log"; }
    run_psql() { return 1; }
    eval "$(python3 -c '
import sys
s = open(sys.argv[1]).read()
i = s.index("function generate_manifest() {")
j = s.index("\n  fi\n}\n", i) + len("\n  fi\n}\n")
print(s[i:j])' "$script")"
    PATH_TO_ODOO="$dep"
    generate_manifest testdb "$out"
  ) || return 0
  rj "$out" 'r["version"] + "|" + json.dumps(r["version_info"])'
}

suite_version() {
  # shellcheck disable=SC2034
  TVS_SUITE=version
  local a r out
  mkdir -p "$T/ver"

  tvs_section "version: the snapshot tool reads the Odoo version from release.py"
  if [ ! -f "$T/app/scripts/example/snapshot.sh.example" ]; then
    skip "snapshot tool version reader" "scripts/example/snapshot.sh.example not found"
  else
    ver_release_py "$T/ver/odoo18" 18 0
    out=$(snap_version "$T/ver/odoo18")
    check_eq "Odoo 18 release.py gives 18.0 (not the old 16.0 default)" "18.0|18.0|[18, 0, 0, \"final\", 0, \"\"]" "$out"
    check_grep "the tool logs where it read the version" "$T/ver/odoo18.log" "Odoo version from odoo-base/odoo/odoo/release.py: 18.0"

    ver_release_py "$T/ver/odoo11" 11 0
    check_eq "Odoo 11 release.py gives 11.0" "11.0|11.0|[11, 0, 0, \"final\", 0, \"\"]" "$(snap_version "$T/ver/odoo11")"

    ver_release_py "$T/ver/saas" saas~17 1
    check_eq "a saas release gives saas~17.1" "saas~17.1" "$(snap_version "$T/ver/saas" | cut -d'|' -f1)"

    mkdir -p "$T/ver/literal/odoo-base/odoo/odoo"
    printf "version_info = (12, 0, 0, 'final', 0, '')\nversion = '12.0'\n" > "$T/ver/literal/odoo-base/odoo/odoo/release.py"
    check_eq "a literal version string is used as it is" "12.0" "$(snap_version "$T/ver/literal" | cut -d'|' -f1)"

    mkdir -p "$T/ver/active/odoo-base/odoo16/odoo" "$T/ver/active/odoo-base/odoo18/odoo"
    ver_release_py "$T/ver/active-a" 16 0; mv "$T/ver/active-a/odoo-base/odoo/odoo/release.py" "$T/ver/active/odoo-base/odoo16/odoo/"
    ver_release_py "$T/ver/active-b" 18 0; mv "$T/ver/active-b/odoo-base/odoo/odoo/release.py" "$T/ver/active/odoo-base/odoo18/odoo/"
    echo "ACTIVE_ODOO_BASE_PATH=odoo-base/odoo18" > "$T/ver/active/.env"
    check_eq "ACTIVE_ODOO_BASE_PATH picks the right base" "18.0" "$(snap_version "$T/ver/active" | cut -d'|' -f1)"

    mkdir -p "$T/ver/broken/odoo-base/odoo/odoo"
    printf "version_info = (18, 0\n" > "$T/ver/broken/odoo-base/odoo/odoo/release.py"
    echo "ODOO_VERSION=17" > "$T/ver/broken/.env"
    check_eq "unreadable release.py falls back to ODOO_VERSION in .env" "17.0|17.0|[17, 0, 0, \"final\", 0, \"\"]" "$(snap_version "$T/ver/broken")"
    check_grep "and says so" "$T/ver/broken.log" "using ODOO_VERSION=17 from .env"

    mkdir -p "$T/ver/nothing"
    check_eq "no release.py and no ODOO_VERSION: empty, never a made-up 16.0" "||null" "$(snap_version "$T/ver/nothing")"
    check_grep "and warns" "$T/ver/nothing.log" "manifest.json will have no version"

    check_grep "the snapshot tool loads the shared reader" "$T/app/scripts/example/snapshot.sh.example" 'source "$PATH_TO_ODOO/scripts/lib/odoo_version.sh"'

    out=$(snap_version "$T/ver/odoo18")
    check "the values make a valid manifest.json" python3 -c 'import json,sys; v,mv,vi=sys.argv[1].split("|"); json.loads("{\"version\": \"%s\", \"version_info\": %s, \"major_version\": \"%s\"}" % (v, vi, mv))' "$out"
  fi

  tvs_section "version: the backup tools' fallback when the database cannot be queried"
  local tool d
  # The backup tools load scripts/lib/odoo_version.sh from the deployment (PATH_TO_ODOO)
  for d in odoo18 nothing; do
    mkdir -p "$T/ver/$d/scripts/lib"; cp "$T/app/scripts/lib/odoo_version.sh" "$T/ver/$d/scripts/lib/"
  done
  ver_release_py "$T/ver/nolib" 18 0
  for tool in example/backupdata_manual.sh.example dataodoo-backupper.sh; do
    if [ ! -f "$T/app/scripts/$tool" ]; then
      skip "$tool fallback" "not found"; continue
    fi
    check_eq "$tool: Odoo 18 deployment gets 18.0 (not 16.0)" '18.0|[18, 0, 0, "final", 0, ""]' \
      "$(backup_fallback_manifest "$T/app/scripts/$tool" "$T/ver/odoo18")"
    check_eq "$tool: nothing to read gives a valid manifest with no version" '|null' \
      "$(backup_fallback_manifest "$T/app/scripts/$tool" "$T/ver/nothing")"
    rm -f "$T/ver/backup.log"
    check_eq "$tool: without scripts/lib/odoo_version.sh it still writes a valid manifest" '|null' \
      "$(backup_fallback_manifest "$T/app/scripts/$tool" "$T/ver/nolib")"
    check_grep "$tool: and says the library is missing" "$T/ver/backup.log" "odoo_version.sh not found"
  done

  tvs_section "version: the validator reads the manifest and checks it against the database"
  a=$(fx odoomanifest)
  vs odoomanifest -- --file "$a"
  check_rc "a manifest as the fixed snapshot tool writes it passes" 0
  r="$VS_REPORT"
  check_eq "manifest stage passes" pass "$(stage_of "$r" manifest)"
  check_eq "database stage passes (versions agree)" pass "$(stage_of "$r" database)"
  check_eq "report odoo_version" 17.0 "$(rj "$r" 'r["odoo_version"]')"

  a=$(fx buggyversion)
  vs buggyversion -- --file "$a"
  check_rc "a manifest from before the fix still passes (warnings only)" 0
  r="$VS_REPORT"
  check_eq "manifest stage warns" warn "$(stage_of "$r" manifest)"
  check_eq "the version comes from version_info, not the wrong version field" 17.0 "$(stage_of "$r" manifest odoo_version)"
  check_grep "the warning names both values and the fix" "$r" "version_info says 17.0 but version says 16.0"
  check_eq "database stage passes (version_info matches the database)" pass "$(stage_of "$r" database)"
  check_eq "report odoo_version is 17.0" 17.0 "$(rj "$r" 'r["odoo_version"]')"

  a=$(fx wrongversion)
  vs wrongversion -- --file "$a" --publish
  check_rc "a manifest that is wrong in every field still passes (warning only)" 0
  r="$VS_REPORT"
  check_eq "manifest stage passes (it is consistent with itself)" pass "$(stage_of "$r" manifest)"
  check_eq "database stage warns about the mismatch" warn "$(stage_of "$r" database)"
  check_grep "the warning names both versions" "$r" "manifest.json says Odoo 16.0 but the database is Odoo 17.0"
  check_eq "database stage records the real version" 17.0 "$(stage_of "$r" database odoo_version)"
  check_eq "and what the manifest claimed" 16.0 "$(stage_of "$r" database manifest_odoo_version)"
  check_eq "report odoo_version comes from the database" 17.0 "$(rj "$r" 'r["odoo_version"]')"
  check_eq "the published record carries the database's version" 17.0 "$(rj "$a.validated.json" 'r["odoo_version"]')"

  a=$(fx noversion)
  vs noversion -- --file "$a"
  check_rc "a manifest without a version passes (warning only)" 0
  r="$VS_REPORT"
  check_eq "manifest stage warns" warn "$(stage_of "$r" manifest)"
  check_grep "the warning says the database tells it" "$r" "manifest.json has no Odoo version"
  check_eq "database stage passes" pass "$(stage_of "$r" database)"
  check_eq "report odoo_version comes from the database" 17.0 "$(rj "$r" 'r["odoo_version"]')"
  check "no drill container left" no_containers
}
