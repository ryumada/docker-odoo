---
name: docker-odoo-management
description: Knowledge for managing the docker-odoo repository — setup, deployment, maintenance, and token-optimized operations.
tokens: ~65
---

# Docker-Odoo Management Skill

Use this skill when working with Odoo Docker deployment, config, or troubleshooting.

## Repository Overview

This toolkit deploys Odoo via Docker. Run `sudo ./setup.sh` to configure.

**Modes**: Development (local build, bind-mounts), Builder (image distribution), Production (pull images, no bind-mounts).

## Directory Structure
- `scripts/` — maintenance scripts. Example files in `scripts/example/` are templates to copy.
- `utilities/` — scripts mounted into the container.
- `conf/` — Odoo config (odoo.conf).
- `odoo-base/` — Odoo source (excluded from AI index).
- `git/` — custom module repos.

## Critical Workflows

### Deployment
`./scripts/deploy_release_candidate.sh <database> --update=<modules>`

### Zero-Token Deployment Verification
Never dump full container logs after deploy. Probe the health endpoint:
```bash
./scripts/lib/check_odoo_health.sh
```

### Log Filtering & Troubleshooting
Filter log output to save tokens:
```bash
docker compose logs --tail=100 odoo | ./scripts/lib/filter_odoo_log.sh -e
```

### Database
Clone: `./scripts/databasecloner.sh` (sanitizes DB — disables emails/crons).
Backup: `./scripts/backupdata.sh`. Restore: `./scripts/restore_backupdata.sh`.

### Shell Access
```bash
docker compose exec odoo odoo-shell <database>
```

## Multi-Deployment Architecture

- **Toggle**: Controlled via `ENABLE_MULTI_DEPLOYMENT=Y` in root `.env`. Default is `N` (single-deployment mode).
- **Profiles**: Stored under `deployments/<deployment_name>/`:
  - `deployments/<dep>/.env` — Overrides `PYTHON_VERSION`, `ODOO_VERSION`, `ODOO_BASE_PATH`, `ADDONS_PATH`, `DB_NAME`, `APT/PIP_ADDITIONAL_PACKAGES`.
  - `deployments/<dep>/requirements.txt` — Deployment-specific Python packages.
- **Shared Config**: Network ports (`PORT`, `GEVENT_PORT`), `DB_HOST`, reverse proxy configs, and global `ADMIN_PASSWD` default stay in root `.env`.
- **Environment Switch**: `sudo ./scripts/switch_env.sh <deployment_name>` syncs per-deployment `.env` variables, `requirements.txt`, secrets (`.secrets/db_user_<dep>`), host datadirs, and builds an isolated container image (`${SERVICE_NAME}-${TARGET_DEPLOYMENT}`).

### Deployment & Test Token Compression
- Docker builds: use `--quiet` / `-q`.
- Headless upgrades: add `--log-level=warn --stop-after-init`.
- Odoo tests: use `--test-tags` to target specific modules.
- On failure: report only the traceback block (`ERROR` / `Traceback`) via `filter_odoo_log.sh`. Do NOT paste full init logs.
