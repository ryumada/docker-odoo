#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: Builds small synthetic Odoo snapshot archives (good and deliberately broken) for the validator tests.
# Usage: mkfixture.sh OUT_DIR VARIANT [SERVICE] [TIMESTAMP]   (prints the archive path; needs FIXTURE_GIT_REMOTE, FIXTURE_GIT_COMMIT)
# Dependencies: bash, python3, tar, zstd, sha256sum
#
# Variants:
#   good          passes every stage (sidecar, manifest with db size, git repo + bundled folder, 20 attachments)
#   plaindump     good, but the manifest has no database size (disk estimate "plain dump x2.5")
#   newerdump     dump written by a newer pg_dump (17) than the server it came from (16)
#   fewmissing    1 of 200 attachments missing (0.5%: a warning, below the 1% limit)
#   missingfiles  5 of 20 attachments missing            wrongsize   2 of 20 attachments with the wrong size
#   sqlerror      dump.sql has a failing statement        truncdump   dump.sql without its end-of-dump marker
#   nokeys        no primary/foreign/unique keys          nousers     res_users is empty
#   badcommit     a commit that is not on the remote      noremote    a repository with no remote, not bundled
#   gitinject     option-shaped commit and remote values (must never reach git as options)
#   credurl       a remote with credentials in its URL (must be redacted everywhere)
#   badsidecar    .sha256 that does not match             nosidecar   no .sha256 at all
#   truncated     archive cut to 60% of its size (no sidecar, so the archive stage judges it)
# Older layout (until the October 2026 snapshot refactor): dump.sql, manifest.json and filestore/ inside
# backupdata-<SERVICE>.zip in the archive:
#   oldzip           good, in the older layout              oldzip-corrupt   one file in the zip fails its CRC
#   oldzip-nodump    the zip has no dump.sql                oldzip-missing   5 of 20 attachments not in the zip
#   oldzip-linkfs    filestore stored in the zip as a symlink (nothing to restore)
# Odoo version in manifest.json (the database is always Odoo 17.0, base 17.0.1.3):
#   odoomanifest   version, version_info and major_version as the fixed snapshot tool writes them
#   buggyversion   what the snapshot tool wrote before the version fix: version 16.0, version_info right
#   wrongversion   the old 16.0 default in every field (release.py not found), so only the database knows
#   noversion      no version in the manifest at all
# Boot check (Phase 2): .env, conf/odoo.conf and requirements.txt as a deployment has them, plus
#   bootgood      Odoo starts: base and web installed, their code in odoo-base (built image: DOCKER_BUILD_MODE=1)
#   bootpull      bootgood, but the image is pulled: DOCKER_BUILD_MODE=3, ODOO_IMAGE_NAME + DOCKER_PULL_KEY in .env
#   bootmissing   an installed module (hr_custom) has no code anywhere in addons_path
#   bootimport    an installed module's Python does not import (CRITICAL "Couldn't load module")
#   bootnoisy     an installed module logs an ERROR line while Odoo runs (a warning; a failure when strict)
#   boothttp      /web/login answers 500            bootcrash   Odoo stops before the registry is ready
#   bootaddons    addons_path names a folder the snapshot does not have (left out, with a note)
#   bootnoconf    no conf/odoo.conf: addons_path comes from ADDONS_PATH in .env

OUT="$1"; VARIANT="$2"; SERVICE="${3:-svc}"; TS="${4:-20260101-000000}"
[ -n "$OUT" ] && [ -n "$VARIANT" ] || { echo "usage: mkfixture.sh OUT_DIR VARIANT [SERVICE] [TIMESTAMP]" >&2; exit 2; }
: "${FIXTURE_GIT_REMOTE:?FIXTURE_GIT_REMOTE is not set}" "${FIXTURE_GIT_COMMIT:?FIXTURE_GIT_COMMIT is not set}"
mkdir -p "$OUT" || exit 1
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/fixture.XXXXXX") || exit 1
trap 'rm -rf "$STAGE"' EXIT

attachments=20 missing=0 wrongsize=0
case "$VARIANT" in
  fewmissing) attachments=200; missing=1 ;;
  missingfiles) missing=5 ;;
  wrongsize) wrongsize=2 ;;
esac

# --- filestore + the attachment rows that point at it ---
python3 - "$STAGE" "$attachments" "$missing" "$wrongsize" > "$STAGE/attachments.sql" <<'PY' || exit 1
import hashlib, os, sys
stage, n, missing, wrong = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
rows = []
for i in range(n):
    data = ("attachment %d " % i).encode() * (5 + i % 7) + os.urandom(64)
    sha = hashlib.sha1(data).hexdigest()
    fname = "%s/%s" % (sha[:2], sha)
    size = len(data)
    if i >= missing:
        d = os.path.join(stage, "filestore", sha[:2])
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, sha), "wb") as f:
            f.write(data if i >= missing + wrong else data[:-10])
    rows.append("INSERT INTO public.ir_attachment (name, store_fname, file_size) VALUES ('file%d.bin', '%s', %d);" % (i, fname, size))
print("\n".join(rows))
PY

keys=1; [ "$VARIANT" = nokeys ] && keys=0
pk() { [ "$keys" = 1 ] && echo " PRIMARY KEY"; }
fk() { [ "$keys" = 1 ] && echo " REFERENCES public.$1(id)"; }
uq() { [ "$keys" = 1 ] && echo " UNIQUE"; }
dumped_by="16.4"; [ "$VARIANT" = newerdump ] && dumped_by="17.2"

{
  cat <<EOF
--
-- PostgreSQL database dump
--

-- Dumped from database version 16.4
-- Dumped by pg_dump version $dumped_by

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET client_min_messages = warning;

CREATE TABLE public.res_company (id integer$(pk), name character varying NOT NULL);
CREATE TABLE public.res_partner (id integer$(pk), name character varying, company_id integer$(fk res_company));
CREATE TABLE public.res_users (id integer$(pk), login character varying NOT NULL$(uq), partner_id integer$(fk res_partner));
CREATE TABLE public.ir_module_module (id integer$(pk), name character varying NOT NULL, state character varying, latest_version character varying);
CREATE TABLE public.ir_model (id integer$(pk), model character varying NOT NULL);
CREATE TABLE public.ir_attachment (id serial$(pk), name character varying, store_fname character varying, file_size integer);
CREATE INDEX ir_attachment_store_fname_index ON public.ir_attachment USING btree (store_fname);

COPY public.res_company (id, name) FROM stdin;
1	Test Company
\.

INSERT INTO public.res_partner (id, name, company_id) VALUES (1, 'Test Company', 1), (2, 'Administrator', 1), (3, 'Customer', 1);
EOF
  [ "$VARIANT" = nousers ] || echo "INSERT INTO public.res_users (id, login, partner_id) VALUES (1, '__system__', 1), (2, 'admin', 2);"
  cat <<'EOF'
INSERT INTO public.ir_module_module (id, name, state, latest_version) VALUES
  (1, 'base', 'installed', '17.0.1.3'), (2, 'web', 'installed', '17.0.1.0'), (3, 'sale', 'uninstalled', NULL);
INSERT INTO public.ir_model (id, model) VALUES (1, 'res.partner'), (2, 'res.users');
EOF
  case "$VARIANT" in
    bootmissing) echo "INSERT INTO public.ir_module_module (id, name, state, latest_version) VALUES (4, 'hr_custom', 'installed', '17.0.1.0');" ;;
    bootimport) echo "INSERT INTO public.ir_module_module (id, name, state, latest_version) VALUES (4, 'broken_import', 'installed', '17.0.1.0');" ;;
    bootnoisy) echo "INSERT INTO public.ir_module_module (id, name, state, latest_version) VALUES (4, 'noisy', 'installed', '17.0.1.0');" ;;
    boothttp) echo "INSERT INTO public.ir_module_module (id, name, state, latest_version) VALUES (4, 'http500', 'installed', '17.0.1.0');" ;;
    bootcrash) echo "INSERT INTO public.ir_module_module (id, name, state, latest_version) VALUES (4, 'crash', 'installed', '17.0.1.0');" ;;
  esac
  [ "$VARIANT" = sqlerror ] && echo "INSERT INTO public.no_such_table (id) VALUES (1);"
  cat "$STAGE/attachments.sql"
  echo "GRANT SELECT ON TABLE public.res_partner TO odoo_svc;"
  echo
  echo "--"
  [ "$VARIANT" = truncdump ] || echo "-- PostgreSQL database dump complete"
  echo "--"
} > "$STAGE/dump.sql"
rm -f "$STAGE/attachments.sql"

if [ "$VARIANT" = odoomanifest ]; then
  echo '{"odoo_dump": "1", "version": "17.0", "version_info": [17, 0, 0, "final", 0, ""], "major_version": "17.0", "modules": {}}' > "$STAGE/manifest.json"
elif [ "$VARIANT" = buggyversion ]; then
  echo '{"odoo_dump": "1", "version": "16.0", "version_info": [17, 0, 0, "final", 0, ""], "major_version": "16", "modules": {}}' > "$STAGE/manifest.json"
elif [ "$VARIANT" = wrongversion ]; then
  echo '{"odoo_dump": "1", "version": "16.0", "version_info": [16, 0, 0, "final", 0, ""], "major_version": "16", "modules": {}}' > "$STAGE/manifest.json"
elif [ "$VARIANT" = noversion ]; then
  echo '{"odoo_dump": "1", "version": "", "version_info": null, "major_version": "", "modules": {}}' > "$STAGE/manifest.json"
elif [ "$VARIANT" = plaindump ] || [ "$VARIANT" = newerdump ]; then
  echo '{"version": "17.0", "service": "'"$SERVICE"'"}' > "$STAGE/manifest.json"
else
  echo '{"version": "17.0", "service": "'"$SERVICE"'", "sudodevops": {"postgres": {"server_version": "16.4", "db_size_bytes": 52428800}}}' > "$STAGE/manifest.json"
fi

mkdir -p "$STAGE/.secrets" "$STAGE/custom_addons/my_module"
printf 'odoo_svc\n' > "$STAGE/.secrets/db_user"
printf "{'name': 'My Module', 'version': '17.0.1.0'}\n" > "$STAGE/custom_addons/my_module/__manifest__.py"
boot_files=()
if [[ "$VARIANT" == boot* ]]; then
  for m in broken_import:import_error noisy:log_error http500:http_500 crash:crash; do
    mkdir -p "$STAGE/custom_addons/${m%%:*}"
    printf "{'name': '%s', 'version': '17.0.1.0', 'fake_behavior': '%s'}\n" "${m%%:*}" "${m#*:}" > "$STAGE/custom_addons/${m%%:*}/__manifest__.py"
  done
  mkdir -p "$STAGE/conf"
  addons="/opt/odoo/odoo-base/addons,/opt/odoo/custom_addons"
  [ "$VARIANT" = bootaddons ] && addons="$addons,/opt/odoo/git/enterprise"
  {
    echo "ADMIN_PASSWD=prod-admin-secret"
    echo "ADDONS_PATH=$addons"
    echo "PYTHON_VERSION=3.12-bookworm"
    echo "PIP_ADDITIONAL_PACKAGES=paramiko==3.4.0"
    echo "APT_ADDITIONAL_PACKAGES=libmagic1"
    if [ "$VARIANT" = bootpull ]; then
      echo "DOCKER_BUILD_MODE=3"
      echo "ODOO_IMAGE_NAME=ghcr.io/acme/odoo-$SERVICE"
      echo "CURRENT_IMAGE_VERSION=7"
      echo "DOCKER_PUSHPULL_USERNAME=acme-bot"
      echo "DOCKER_PULL_KEY=ghp_FixturePullKey0123456789"
    else
      echo "DOCKER_BUILD_MODE=1"
    fi
  } > "$STAGE/.env"
  if [ "$VARIANT" != bootnoconf ]; then
    printf '[options]\nadmin_passwd = prod-admin-secret\naddons_path = %s\ndb_host = prod-db.internal\nsmtp_server = smtp.example.invalid\n' "$addons" > "$STAGE/conf/odoo.conf"
    boot_files+=(conf)
  fi
  printf 'paramiko==3.4.0\n' > "$STAGE/requirements.txt"
  boot_files+=(.env requirements.txt)
fi

remote="$FIXTURE_GIT_REMOTE" commit="$FIXTURE_GIT_COMMIT"
case "$VARIANT" in
  badcommit) commit="0123456789abcdef0123456789abcdef01234567" ;;
  noremote) remote="N/A" ;;
  credurl) remote="https://deploy:S3cr3tT0ken@git.example.invalid/acme/odoo-base.git" ;;
esac
python3 - "$remote" "$commit" "$VARIANT" "${FIXTURE_PWNED_DIR:-$OUT}" > "$STAGE/git_hashes.json" <<'PY' || exit 1
import json, sys
remote, commit, variant, pwned = sys.argv[1:5]
repos = [{"relative_path": "odoo-base", "remote": remote, "commit": commit},
         {"relative_path": "custom_addons", "remote": "", "commit": ""}]
if variant == "gitinject":
    repos += [{"relative_path": "inject-commit", "remote": remote, "commit": "--upload-pack=touch %s/pwned-commit" % pwned},
              {"relative_path": "inject-remote", "remote": "--upload-pack=touch %s/pwned-remote" % pwned, "commit": commit}]
print(json.dumps({"git_repositories": repos,
                  "bundled_directories": [{"relative_path": "custom_addons", "remote": "", "commit": ""}]}, indent=2))
PY

ARCHIVE="$OUT/snapshot-$SERVICE-$TS.tar.zst"
members=(dump.sql manifest.json git_hashes.json .secrets custom_addons "${boot_files[@]}")
[ -d "$STAGE/filestore" ] && members+=(filestore)
if [[ "$VARIANT" == oldzip* ]]; then
  # Older layout: the Odoo backup zip (dump.sql, manifest.json, filestore/) next to git_hashes.json etc.
  python3 - "$STAGE" "backupdata-$SERVICE.zip" "$VARIANT" <<'PY' || exit 1
import os, stat, sys, zipfile
stage, name, variant = sys.argv[1:4]
fs = os.path.join(stage, "filestore")
files = sorted(os.path.relpath(os.path.join(r, f), fs) for r, _, names in os.walk(fs) for f in names) if os.path.isdir(fs) else []
if variant == "oldzip-missing":
    files = files[5:]
with zipfile.ZipFile(os.path.join(stage, name), "w") as z:
    if variant != "oldzip-nodump":
        z.write(os.path.join(stage, "dump.sql"), "dump.sql", compress_type=zipfile.ZIP_DEFLATED)
    z.write(os.path.join(stage, "manifest.json"), "manifest.json", compress_type=zipfile.ZIP_DEFLATED)
    if variant == "oldzip-linkfs":
        link = zipfile.ZipInfo("filestore")
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        z.writestr(link, "/var/lib/odoo/mirror/filestore")
    else:
        for f in files:   # stored, like 7z -mx=0 in the old snapshot tool
            z.write(os.path.join(fs, f), "filestore/" + f, compress_type=zipfile.ZIP_STORED)
if variant == "oldzip-corrupt":
    # flip one byte inside the first stored filestore file: the zip still opens, its CRC check fails
    path = os.path.join(stage, name)
    with zipfile.ZipFile(path) as z:
        info = next(i for i in z.infolist() if i.filename.startswith("filestore/") and i.file_size > 0)
    data = bytearray(open(path, "rb").read())
    start = info.header_offset + 30 + len(info.filename.encode()) + len(info.extra)
    data[start] ^= 0xFF
    open(path, "wb").write(bytes(data))
PY
  members=("backupdata-$SERVICE.zip" git_hashes.json .secrets custom_addons)
fi
tar -C "$STAGE" -cf - "${members[@]}" | zstd -q -T1 -f -o "$ARCHIVE" || exit 1

case "$VARIANT" in
  nosidecar|truncated) rm -f "$ARCHIVE.sha256" ;;
  badsidecar) printf '%s  %s\n' "$(printf 'x' | sha256sum | cut -d' ' -f1)" "$(basename "$ARCHIVE")" > "$ARCHIVE.sha256" ;;
  *) printf '%s  %s\n' "$(sha256sum "$ARCHIVE" | cut -d' ' -f1)" "$(basename "$ARCHIVE")" > "$ARCHIVE.sha256" ;;
esac
if [ "$VARIANT" = truncated ]; then
  size=$(stat -c %s "$ARCHIVE")
  truncate -s $(( size * 60 / 100 )) "$ARCHIVE" || exit 1
fi
echo "$ARCHIVE"
