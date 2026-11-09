#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: Phase 2 of validate-snapshot.sh: the Odoo image (pulled with the snapshot's pull key, or built and cached),
#              the code checked out at its commits, neutralize, then Odoo booting on the restored copy, and how the boot
#              is judged (registry/modules/HTTP failures fail; other ERROR lines warn, or fail with VALIDATOR_BOOT_STRICT).
# Usage: sourced by tests/test_validate_snapshot.sh (suite "boot"); needs tests/validate_snapshot/lib.sh
# Dependencies: lib.sh, mkfixture.sh, fake docker (Odoo containers run tests/validate_snapshot/fake_odoo_bin.py), PostgreSQL

boot_detail() { rj "$1" "[s for s in r['stages'] if s['name']=='boot'][-1]['details']$2"; }

suite_boot() {
  # shellcheck disable=SC2034
  TVS_SUITE=boot
  local TVS_BOOT=true a r k

  tvs_section "boot: Odoo starts on a good snapshot (image built here)"
  a=$(fx bootgood svc)
  : > "$T/dl/odoo-events.log"
  vs bootgood -- --file "$a" --keep-workdir
  r="$VS_REPORT"
  check_rc "good snapshot passes with Odoo booted" 0
  check_eq "report level is boot" boot "$(rj "$r" 'r["level"]')"
  for k in image code boot; do check_eq "stage $k passed" pass "$(stage_of "$r" "$k")"; done
  check_eq "the image was built (DOCKER_BUILD_MODE=1 is never in a registry)" built "$(stage_of "$r" image source)"
  check "the report names the drill image" bash -c '[[ "$1" == odoo-drill/svc:build-* ]]' _ "$(rj "$r" 'r["odoo_image"]')"
  check_eq "one build" 1 "$(wc -l < "$T/dl/build.log")"
  check_grep "built with the snapshot's PYTHON_VERSION" "$T/dl/builds/1/args" "PYTHON_VERSION=3.12-bookworm"
  check_grep "and its PIP_ADDITIONAL_PACKAGES" "$T/dl/builds/1/args" "PIP_ADDITIONAL_PACKAGES=paramiko==3.4.0"
  check_grep "and its APT_ADDITIONAL_PACKAGES" "$T/dl/builds/1/args" "APT_ADDITIONAL_PACKAGES=libmagic1"
  check_grep "the snapshot's requirements.txt is in the build" "$T/dl/builds/1/requirements.txt" "paramiko==3.4.0"
  check_grep "the drill Dockerfile installs the requirements" "$T/dl/builds/1/Dockerfile" "pip install -r ./requirements.txt"
  check_no_grep "it leaves out entrypoint.sh and the utilities" "$T/dl/builds/1/Dockerfile" "entrypoint.sh"
  check_no_grep "and the fonts" "$T/dl/builds/1/Dockerfile" "COPY fonts/"
  check_eq "it ends as the odoo user" "USER odoo" "$(grep '^USER' "$T/dl/builds/1/Dockerfile" | tail -n 1)"
  check_eq "neutralize ran first, then Odoo" "neutralize server" "$(awk '{print $1}' "$T/dl/odoo-events.log" | tr '\n' ' ' | sed 's/ $//')"
  check_eq "no workers, no cron threads, no queue_job runner, no database list, the drill's own role" \
    "workers=0 max_cron_threads=0 server_wide_modules=base,web list_db=False db_user=odoo_drill" \
    "$(tail -n 1 "$T/dl/odoo-events.log" | cut -d' ' -f3-)"
  check "Odoo runs on the drill's internal network" bash -c 'grep -q -- "--network odoo-drill-[^ ]*-net " "$1" && grep -q " 1$" "$2"/odoo-drill-*-net 2>/dev/null || grep -q -- "--network odoo-drill-" "$1"' _ "$T/dl/odoo-runs.log" "$T/dl/net"
  check_eq "with its entrypoint replaced (production's entrypoint.sh is not used)" 2 "$(grep -c -- '--entrypoint python3 ' "$T/dl/odoo-runs.log")"
  check_no_grep "and no production environment" "$T/dl/odoo-runs.log" "--env-file"
  check_eq "every mount is read-only" "" "$(grep -v 'ro=1$' "$T/dl/mounts.log")"
  check "odoo-base and custom_addons are mounted where production has them" bash -c 'grep -q " /opt/odoo/odoo-base ro=1" "$1" && grep -q " /opt/odoo/custom_addons ro=1" "$1"' _ "$T/dl/mounts.log"
  check_eq "odoo-bin from the snapshot's odoo-base" /opt/odoo/odoo-base/odoo-bin "$(boot_detail "$r" '["odoo_bin"]')"
  check_eq "addons_path as production has it" '["/opt/odoo/odoo-base/addons", "/opt/odoo/custom_addons"]' "$(boot_detail "$r" '["addons_path"]')"
  check_eq "/web/login answered 200" 200 "$(boot_detail "$r" '["http_status"]')"
  check_eq "neutralized with odoo-bin neutralize" "odoo-bin neutralize" "$(boot_detail "$r" '["neutralized"]')"
  local w; w=$(ls -d "$T"/vwork/runs/*/ 2>/dev/null | tail -n 1)
  check "the drill's configuration has none of production's settings" bash -c '! grep -qE "prod-admin-secret|prod-db.internal|smtp.example.invalid" "$1"' _ "$w/boot/drill.conf"
  check_not "the snapshot's .env (secrets) is not kept, even with --keep-workdir" test -e "$w/boot/snapshot.env"
  check "no drill container left" no_containers
  check "no drill network left" no_networks
  rm -rf "$T"/vwork/runs/*

  tvs_section "boot: the built image is reused"
  vs bootgood2 -- --file "$a"
  check_rc "second drill passes" 0
  check_eq "image from the cache" "cached build" "$(stage_of "$VS_REPORT" image source)"
  check_eq "no second build" 1 "$(wc -l < "$T/dl/build.log")"
  check_eq "the code is fetched once (cached objects)" pass "$(stage_of "$VS_REPORT" code)"

  tvs_section "boot: --publish records the boot level"
  vs bootpublish -- --file "$a" --publish
  check_rc "drill with --publish" 0
  check_eq "record level boot" boot "$(rj "$a.validated.json" 'r["level"]')"
  check_eq "record checks include boot" pass "$(rj "$a.validated.json" 'r["checks"]["boot"]')"

  tvs_section "boot: the deployment's image is pulled with the snapshot's pull key"
  a=$(fx bootpull pullsvc)
  vs bootpull -- --file "$a"
  r="$VS_REPORT"
  check_rc "drill with a pulled image passes" 0
  check_eq "image stage passed" pass "$(stage_of "$r" image)"
  check_eq "pulled ODOO_IMAGE_NAME:CURRENT_IMAGE_VERSION" "pulled ghcr.io/acme/odoo-pullsvc:7" "$(stage_of "$r" image source)"
  check_eq "logged in to ghcr.io as DOCKER_PUSHPULL_USERNAME with DOCKER_PULL_KEY on stdin" \
    "server=ghcr.io user=acme-bot password=ghp_FixturePullKey0123456789" "$(tail -n 1 "$T/dl/login.log" | cut -d' ' -f1-3)"
  check "into a throwaway Docker config in the drill's work folder" bash -c '[[ "$(tail -n 1 "$1")" == *"config=$2/runs/"*"/boot/docker-config" ]]' _ "$T/dl/login.log" "$T/vwork"
  check_no_grep "the key is never on a command line" "$T/dl/calls.log" "ghp_FixturePullKey"
  check "and never in the log or the report" bash -c '! grep -q ghp_FixturePullKey "$1" "$2"' _ "$VS_LOG" "$r"
  check_grep "the pulled image is kept under the drill's name" "$T/dl/tag.log" "tag ghcr.io/acme/odoo-pullsvc:7 odoo-drill/pullsvc:pull-"
  check_grep "and the registry name removed" "$T/dl/tag.log" "rmi ghcr.io/acme/odoo-pullsvc:7"
  check_eq "nothing was built" 1 "$(wc -l < "$T/dl/build.log")"

  tvs_section "boot: a pull that fails falls back to a build (warning)"
  vs bootpullfail FAKE_PULL_FAIL_MATCH=ghcr.io -- --file "$a"
  check_rc "still passes" 0
  check_eq "image stage warns" warn "$(stage_of "$VS_REPORT" image)"
  check_eq "built instead" built "$(stage_of "$VS_REPORT" image source)"
  check "and says why" bash -c '[[ "$1" == *"could not pull ghcr.io/acme/odoo-pullsvc:7"* ]]' _ "$(stage_of "$VS_REPORT" image message)"
  vs bootloginfail FAKE_LOGIN_FAIL=1 -- --file "$a"
  check_rc "a refused login also falls back" 0
  check "and says so" bash -c '[[ "$1" == *"could not log in to ghcr.io"* ]]' _ "$(stage_of "$VS_REPORT" image message)"

  tvs_section "boot: an image that cannot be built proves nothing (exit 2)"
  a=$(fx bootgood buildfail)
  vs bootbuildfail FAKE_BUILD_FAIL=1 -- --file "$a"
  check_rc "build failure is an error, not a broken snapshot" 2
  check_eq "image stage error" error "$(stage_of "$VS_REPORT" image)"
  check "the build log tail is in the report" bash -c '[[ "$1" == *"nosuchpkg"* ]]' _ "$(stage_of "$VS_REPORT" image build_log_tail)"
  check_eq "Odoo was not started" "" "$(stage_of "$VS_REPORT" boot)"
  check_eq "level stays database" database "$(rj "$VS_REPORT" 'r["level"]')"

  tvs_section "boot: what makes the boot check fail (exit 1)"
  local v want
  for v in "bootmissing:installed modules are missing their code" "bootimport:a module's Python code does not import" \
           "boothttp:/web/login answered 500" "bootcrash:Odoo stopped before it was ready"; do
    a=$(fx "${v%%:*}" svc)
    vs "${v%%:*}" -- --file "$a"
    want="${v#*:}"
    check_rc "${v%%:*} fails" 1
    check_eq "${v%%:*}: boot stage failed" fail "$(stage_of "$VS_REPORT" boot)"
    check "${v%%:*}: says '$want'" bash -c '[[ "$1" == *"$2"* ]]' _ "$(stage_of "$VS_REPORT" boot message)" "$want"
    check_eq "${v%%:*}: level stays database" database "$(rj "$VS_REPORT" 'r["level"]')"
    check "${v%%:*}: no container left" no_containers
  done
  check_eq "the missing module is named" "hr_custom" "$(rj "$T/reports/bootmissing.json" "[s for s in r['stages'] if s['name']=='boot'][-1]['details']['fatal'][0]['message']" | grep -o hr_custom)"
  a=$(fx bootmissing svc)
  printf '{"result": "pass"}' > "$a.validated.json"
  vs bootrevoke -- --file "$a" --publish
  check_rc "a failed boot with --publish" 1
  check_not "removes the old validation record" test -e "$a.validated.json"

  tvs_section "boot: other ERROR lines are warnings, unless VALIDATOR_BOOT_STRICT=true"
  a=$(fx bootnoisy svc)
  vs bootnoisy -- --file "$a"
  check_rc "noisy Odoo still passes" 0
  check_eq "boot stage warns" warn "$(stage_of "$VS_REPORT" boot)"
  check_eq "level boot" boot "$(rj "$VS_REPORT" 'r["level"]')"
  check "the ERROR line is in the report" bash -c '[[ "$1" == *"Could not connect to SFTP server"* ]]' _ "$(boot_detail "$VS_REPORT" "['errors'][0]['message']")"
  vs bootstrict VALIDATOR_BOOT_STRICT=true -- --file "$a"
  check_rc "strict: the same snapshot fails" 1
  check "strict: and says why" bash -c '[[ "$1" == *"VALIDATOR_BOOT_STRICT=true"* ]]' _ "$(stage_of "$VS_REPORT" boot message)"
  vs bootstrictok VALIDATOR_BOOT_STRICT=true -- --file "$(fx bootgood svc)"
  check_rc "strict: a clean boot still passes" 0

  tvs_section "boot: addons_path and layout"
  vs bootaddons -- --file "$(fx bootaddons svc)"
  check_rc "a missing addons_path folder does not stop the boot" 0
  check "it is left out, with a note" bash -c '[[ "$1" == *"left out: /opt/odoo/git/enterprise"* ]]' _ "$(boot_detail "$VS_REPORT" "['notes'][0]")"
  vs bootnoconf -- --file "$(fx bootnoconf svc)"
  check_rc "no conf/odoo.conf: ADDONS_PATH from .env" 0
  check_eq "addons_path from .env" '["/opt/odoo/odoo-base/addons", "/opt/odoo/custom_addons"]' "$(boot_detail "$VS_REPORT" '["addons_path"]')"
  vs bootplain -- --file "$(fx good svc)"
  check_rc "an older snapshot without .env or conf still boots" 0
  check_eq "image warns: no requirements.txt in the snapshot" warn "$(stage_of "$VS_REPORT" image)"
  check "built with odoo-base's requirements.txt instead (as setup.sh does)" bash -c '[[ "$1" == *"built with odoo-base'"'"'s odoo-base/requirements.txt"* ]] && grep -q psycopg2 "$2"' _ "$(stage_of "$VS_REPORT" image message)" "$(ls -d "$T"/dl/builds/*/ | sort -V | tail -n 1)requirements.txt"
  check "addons_path is worked out from odoo-base" bash -c '[[ "$1" == *"no addons_path"* ]]' _ "$(boot_detail "$VS_REPORT" "['notes'][0]")"

  tvs_section "boot: when Odoo is not started"
  a=$(fx bootgood svc)
  vs bootoff -- --file "$a" --no-boot
  check_rc "--no-boot passes at the database level" 0
  check_eq "boot skipped" skip "$(stage_of "$VS_REPORT" boot)"
  check_eq "level database" database "$(rj "$VS_REPORT" 'r["level"]')"
  vs bootoffenv VALIDATOR_BOOT=false -- --file "$a"
  check_eq "VALIDATOR_BOOT=false too" skip "$(stage_of "$VS_REPORT" boot)"
  vs bootnogit -- --file "$a" --no-git-check
  check_eq "--no-git-check: boot skipped (the code is checked out at the commits git proves)" skip "$(stage_of "$VS_REPORT" boot)"
  vs bootbadset VALIDATOR_BOOT=yes -- --file "$a"
  check_rc "an invalid VALIDATOR_BOOT is a configuration error" 3
  vs bootbadstrict VALIDATOR_BOOT_STRICT=1 -- --file "$a"
  check_rc "an invalid VALIDATOR_BOOT_STRICT too" 3

  tvs_section "boot: failures outside the snapshot prove nothing (exit 2)"
  vs bootneutfail FAKE_NEUTRALIZE_FAIL=1 -- --file "$a"
  check_rc "neutralize failing is an error" 2
  check_eq "boot stage error" error "$(stage_of "$VS_REPORT" boot)"
  check_eq "Odoo was not started un-neutralized" "neutralize" "$(tail -n 1 "$T/dl/odoo-events.log" | awk '{print $1}')"
  vs bootrunfail FAKE_ODOO_RUN_FAIL=1 -- --file "$a"
  check_rc "a container that cannot start is an error" 2
  check "no drill container left" no_containers
  check "no drill network left" no_networks
}
