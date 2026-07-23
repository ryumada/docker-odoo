---
name: docker-odoo-management
description: Knowledge for managing the docker-odoo repository — setup, deployment, maintenance.
tokens: ~50
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
- `odoo-base/` — Odoo source.
- `git/` — custom module repos.

## Critical Workflows

### Deployment
`./scripts/deploy_release_candidate.sh <database> --update=<modules>`

### Database
Clone: `./scripts/databasecloner.sh` (sanitizes DB — disables emails/crons).
Backup: `./scripts/backupdata.sh`. Restore: `./scripts/restore_backupdata.sh`.

### Shell Access
```bash
docker compose exec odoo odoo-shell <database>
```

### Test Log Compression
- Docker builds: use `--quiet` or pipe through grep for errors only.
- Odoo tests: use `--test-tags` to target specific modules.
- On failure: report only the traceback block (`ERROR` / `Traceback`) and final failure count. Do NOT paste full init logs.
