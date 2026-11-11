#!/usr/bin/env bash
set -euo pipefail
# Category: Snapshot
# Description: Prints this deployment's snapshot drill reports and drill settings as one JSON document, for
#              Deployment Control (sudodevops_deployment_control), which runs it over SSH every hour. Read-only.
#              Only the drill keys of the .env leave the server (VALIDATOR_*, SNAPSHOT_VALIDATOR_INBOX,
#              SNAPSHOT_REMOTE_HOST), plus a summary of each report in ~/.odoo-validator/reports (or
#              VALIDATOR_WORK_DIR/reports) of the deployment owner.
#              The automation user may run it with sudo without a password (Deployment Control's setup.sh adds
#              it to /etc/sudoers.d/99-odoo-deployment, with no arguments allowed); it then reads everything as
#              the deployment owner, never as root.
# Usage: sudo ./scripts/read-drill-reports.sh   (or ./scripts/read-drill-reports.sh as the deployment owner)
# Dependencies: python3, stat, sudo (only when run as root for another owner)
# Keep the Python below the same as REMOTE_COLLECT_SCRIPT in sudodevops_deployment_control
# (models/snapshot_drill_tools.py): Deployment Control reads this output with schema 1.

if [ "$#" -ne 0 ]; then
  echo "Error: read-drill-reports.sh takes no arguments." >&2
  exit 1
fi

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
DEPLOYMENT_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
OWNER=$(stat -c '%U' "$DEPLOYMENT_DIR")
ME=$(id -un)

IFS= read -r -d '' COLLECTOR <<'PY' || true
import glob, json, os, re, sys
dep = sys.argv[1].rstrip('/') or '/'
svc = os.path.basename(dep)
KEYS = ('VALIDATOR_WORKER', 'VALIDATOR_MIN_INTERVAL_HOURS', 'VALIDATOR_BOOT_STRICT', 'SNAPSHOT_VALIDATOR_INBOX', 'SNAPSHOT_REMOTE_HOST', 'VALIDATOR_WORK_DIR')
LIMIT = 50

def clean(v):
    # Same as docker-odoo's env_get: the comment, surrounding blanks and quotes go
    v = re.sub(r'\s*#.*', '', v).strip()
    if v[:1] in ('"', "'"):
        v = v[1:]
    if v[-1:] in ('"', "'"):
        v = v[:-1]
    return v

settings, env_readable = {}, True
try:
    with open(os.path.join(dep, '.env'), errors='replace') as f:
        for line in f:
            line = line.rstrip('\n')
            k = line.split('=', 1)[0]
            if k in KEYS and '=' in line:
                settings[k] = clean(line.split('=', 1)[1])
except (IOError, OSError):
    env_readable = False

wd = settings.get('VALIDATOR_WORK_DIR') or os.path.join(os.path.expanduser('~'), '.odoo-validator')
rdir = os.path.join(wd, 'reports')

def message(s):
    d = s.get('details')
    if isinstance(d, dict):
        m = d.get('message')
        if not m:
            m = json.dumps(d, sort_keys=True)
    else:
        m = d
    return str(m if m is not None else '')[:500]

runs = []
for p in glob.glob(os.path.join(rdir, '*.json')):
    n = os.path.basename(p)
    if n.startswith('latest-') or n.startswith('.') or os.path.islink(p):
        continue
    try:
        if os.path.getsize(p) > 2000000:
            continue
        with open(p) as f:
            r = json.load(f)
    except Exception:
        continue
    if not isinstance(r, dict) or r.get('service') != svc:
        continue
    stages = [s for s in (r.get('stages') or []) if isinstance(s, dict)] if isinstance(r.get('stages'), list) else []
    bad = [s for s in stages if s.get('status') in ('fail', 'error')]
    warns = [s for s in stages if s.get('status') == 'warn']
    src = r.get('source') if isinstance(r.get('source'), dict) else {}
    rem = r.get('remote') if isinstance(r.get('remote'), dict) else {}
    runs.append({
        'name': n,
        'result': r.get('result'),
        'level': r.get('level'),
        'archive': r.get('archive'),
        'sha256': r.get('sha256'),
        'started_at': r.get('started_at'),
        'finished_at': r.get('finished_at'),
        'duration_seconds': r.get('duration_seconds'),
        'odoo_version': r.get('odoo_version'),
        'source_kind': src.get('kind'),
        'remote_host': rem.get('host'),
        'record_published': r.get('record_published'),
        'failed_stage': bad[0].get('name') if bad else None,
        'failed_message': message(bad[0]) if bad else None,
        'warning_count': len(warns),
        'warnings': ['%s: %s' % (s.get('name'), message(s)[:300]) for s in warns[:5]],
    })
runs.sort(key=lambda x: (str(x.get('started_at') or ''), x['name']))
print(json.dumps({
    'schema': 1,
    'service': svc,
    'env_readable': env_readable,
    'settings': settings,
    'reports_dir': rdir,
    'reports_dir_exists': os.path.isdir(rdir),
    'worker_installed': os.path.exists('/etc/cron.d/validate-snapshot-' + svc),
    'worker_script': os.path.exists(os.path.join(dep, 'scripts', 'validate-snapshot-worker.sh')),
    'runs': runs[-LIMIT:],
}))
PY

cd /
if [ "$OWNER" = "$ME" ]; then
  printf '%s\n' "$COLLECTOR" | python3 -I - "$DEPLOYMENT_DIR"
elif [ "$(id -u)" -eq 0 ] && [ -n "$OWNER" ] && [ "$OWNER" != "UNKNOWN" ]; then
  printf '%s\n' "$COLLECTOR" | sudo -H -u "$OWNER" python3 -I - "$DEPLOYMENT_DIR"
else
  echo "Error: run read-drill-reports.sh with sudo, or as the deployment owner ($OWNER)." >&2
  exit 1
fi
