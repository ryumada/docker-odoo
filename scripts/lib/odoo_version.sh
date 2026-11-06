#!/usr/bin/env bash
# Category: Library
# Description: Reads a deployment's Odoo version without running Odoo, for manifest.json (snapshot and backup tools).
# Usage: source scripts/lib/odoo_version.sh; odoo_version_detect "$PATH_TO_ODOO"
#        Sets MANIFEST_VERSION ("18.0"), MANIFEST_MAJOR_VERSION ("18.0") and MANIFEST_VERSION_INFO
#        (JSON, e.g. [18, 0, 0, "final", 0, ""]), or "", "" and null when the version cannot be found.
# Dependencies: python3 (for release.py), grep, sed
#
# Order: odoo/release.py of the active Odoo base (ACTIVE_ODOO_BASE_PATH in .env, else the first folder
# under odoo-base/), then ODOO_VERSION in .env, else empty with a warning. Never a made-up default:
# a wrong version looks right and nothing flags it, an empty one is reported.
# release.py is parsed, never run. In Odoo's release.py only version_info is a literal; series,
# major_version and version are computed from it, so series = "<version_info[0]>.<version_info[1]>".

_odoo_version_log() {
  # Args: info|warn message. Uses the caller's log_info / log_warn when it has them.
  if [ "$1" = warn ] && declare -F log_warn >/dev/null; then log_warn "$2"
  elif [ "$1" = info ] && declare -F log_info >/dev/null; then log_info "$2"
  else echo "$2" >&2; fi
}

odoo_version_env_value() {
  # Args: .env path, key. Prints the value without quotes or trailing comment.
  grep "^$2=" "$1" 2>/dev/null | head -n 1 | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true
}

odoo_version_from_release_py() {
  # Args: path to release.py. Prints: version<TAB>series<TAB>version_info (JSON or null), or nothing.
  python3 - "$1" <<'PY' 2>/dev/null || true
import ast, json, sys
try:
    tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
except Exception:
    sys.exit()
lit, version_info = {}, None
for node in tree.body:
    if not isinstance(node, ast.Assign):
        continue
    for target in node.targets:
        if not isinstance(target, ast.Name):
            continue
        if target.id == "version_info" and isinstance(node.value, (ast.Tuple, ast.List)):
            version_info = [e.value if isinstance(e, ast.Constant)
                            else (e.id.lower() if isinstance(e, ast.Name) else None)
                            for e in node.value.elts]
        elif target.id in ("version", "series", "serie", "major_version") \
                and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
            lit[target.id] = node.value.value
series = lit.get("series") or lit.get("serie") or lit.get("major_version")
if not series and version_info and len(version_info) >= 2 and None not in version_info[:2]:
    series = "%s.%s" % (version_info[0], version_info[1])
safe = lambda v: "".join(c for c in str(v or "") if c.isalnum() or c in ".~+_-")[:40]
series = safe(series)
if not series:
    sys.exit()
version = safe(lit.get("version")) or series
print("%s\t%s\t%s" % (version, series, json.dumps(version_info) if version_info else "null"))
PY
}

odoo_version_detect() {
  # Args: PATH_TO_ODOO. Sets MANIFEST_VERSION, MANIFEST_MAJOR_VERSION, MANIFEST_VERSION_INFO.
  local root="$1" active base="" release="" parsed env_version
  MANIFEST_VERSION=""
  MANIFEST_MAJOR_VERSION=""
  MANIFEST_VERSION_INFO="null"

  active=$(odoo_version_env_value "$root/.env" ACTIVE_ODOO_BASE_PATH)
  if [ -n "$active" ] && [ -d "$root/$active" ]; then
    base="$root/$active"
  else
    base=$(find "$root/odoo-base" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null || true)
  fi
  if [ -n "$base" ] && [ -f "$base/odoo/release.py" ]; then
    release="$base/odoo/release.py"
  else
    release=$(find "$root/odoo-base" "$root/odoo" -name "release.py" -path "*/odoo/release.py" 2>/dev/null | head -n 1 || true)
  fi

  parsed=""
  if [ -n "$release" ] && [ -f "$release" ] && command -v python3 >/dev/null 2>&1; then
    parsed=$(odoo_version_from_release_py "$release")
  fi
  if [ -n "$parsed" ]; then
    IFS=$'\t' read -r MANIFEST_VERSION MANIFEST_MAJOR_VERSION MANIFEST_VERSION_INFO <<< "$parsed"
    _odoo_version_log info "Odoo version from ${release#"$root"/}: $MANIFEST_VERSION"
    return 0
  fi

  env_version=$(odoo_version_env_value "$root/.env" ODOO_VERSION)
  if [[ "$env_version" =~ ^([0-9]+)(\.([0-9]+))?$ ]]; then
    MANIFEST_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[3]:-0}"
    MANIFEST_MAJOR_VERSION="$MANIFEST_VERSION"
    MANIFEST_VERSION_INFO="[${BASH_REMATCH[1]}, ${BASH_REMATCH[3]:-0}, 0, \"final\", 0, \"\"]"
    _odoo_version_log warn "Could not read the Odoo version from release.py; using ODOO_VERSION=$env_version from .env ($MANIFEST_VERSION)."
  else
    _odoo_version_log warn "Could not read the Odoo version (no readable odoo/release.py and no numeric ODOO_VERSION in .env). manifest.json will have no version."
  fi
  return 0
}
