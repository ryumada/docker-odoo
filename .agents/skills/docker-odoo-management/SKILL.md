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

### Remote Snapshot Secondary Host Management
- **Key Generation & Admin Provisioning**:
  `./scripts/generate-snapshot-ssh-key.sh [-a <admin_user>] [--from <ip>|--no-from]`
  - Generates ed25519 key at `~/.ssh/snapshot-<src>-<dst>`, updates `SNAPSHOT_REMOTE_KEY` in `.env`.
  - When `-a <admin_user>` is passed, connects interactively via sudo, creates remote backup user (locked password, non-sudo) if missing, sets 700/600 permissions, and restricts key to incoming IP via `from="<ip>"` by default.
- **Switching Secondary VPS**:
  `./scripts/change-snapshot-remote.sh --new-host <HOST> [-a <admin_user>] [--purge]`
  - Acquires snapshot flock to prevent collisions with cron jobs.
  - Cleans temporary/mirror directories on the old host while preserving `archives/` by default.
  - Revokes old SSH key from old server's `authorized_keys`, removes local old keys, and bootstraps new VPS.
  - Only deletes old `archives/` if `--purge` is explicitly supplied with confirmation.

### Shell Access
```bash
docker compose exec odoo odoo-shell <database>
```

### Remote Database Sync & Containerized PostgreSQL Patterns
- **Reading Protected Secrets via Container**: `.secrets/` files are `chmod 0400` (owned by `odoo:odoo`). When executing remote tasks via non-root SSH (`devops`), read credentials by mounting `.secrets` into a container:
  `docker run --rm --network="$net" -v "$path/.secrets:/secrets:ro" postgres bash -c '...'`
- **Postgres Roles vs OS Users**: Odoo DB users are PostgreSQL roles, not OS system users. Never run `sudo -u "$db_user"` on the host.
- **SQL Dumps & Object Ownership**:
  - Always dump with `--no-owner` to avoid hardcoding source usernames in the DDL.
  - On the target environment, restore via the Odoo container using the target's `.secrets`:
    `PGPASSWORD="$pass" docker exec -i -e PGPASSWORD "$(docker compose ps -q odoo)" psql -h "$db_host" -p "$db_port" -U "$user" -d "$db_name" < file.sql` (the password comes from the environment, never the command line)
  - Reassign ownership of tables/sequences/views in `public` schema to `$user` to prevent `base_registry_signaling` permission errors during `odoo-registry-reload`.
- **Bash Syntax Guardrails**: Never prefix function declarations with `local` (`local fn() { ... }` is invalid in bash).
- **JSON-Clean Outputs**: In CLI scripts with `JSON_MODE=true`, redirect verbose commands (`rsync`, `ssh` logs) to `>&2` to protect JSON stdout.

### Filestore Optimization & Safe Pruning
- **Rsync Compression**: Never use `-z` (`--compress`) when synchronizing Odoo filestore over `rsync`. Attachments (PDF, images, documents) are already compressed; gzip pegs a single CPU core at 100% and drastically throttles transfer throughput.
- **SHA1 Deduplication Invariant**: Odoo filestores store files by SHA1 hash (`store_fname`). Multiple `ir_attachment` records (e.g., a chatter message and an official invoice) may reference the same physical file. Never exclude or delete a physical file unless **all** referencing attachment records belong to excludable categories (`bool_and(category IN (...))`).
- **Remote Tool Validation**: When offloading packaging or compression to a secondary VPS, validate dependencies (`7z`, `zstd`) on the executing machine rather than failing pre-emptively on the source host.

### Cross-VPS Deployments, Helpers & Dual-Path Sudoers
- **Cross-VPS Helper Requirements**: Cross-VPS operations (e.g., `deploy_release_candidate`) require helper utilities (`dump_database-$SERVICE`, `export_filestore-$SERVICE`) to be installed on the **Production VPS**, not merely the initiating development/staging environment.
- **Dual-Path Sudoers Rules**: Always configure passwordless sudoers rules for both the repository path (`<path>/scripts/<name>.sh`) and the binary symlink (`/usr/local/sbin/<name>`). Scripts invoked via PATH or `/usr/local/sbin/` will fail with `sudo: a password is required` if only the repository path is whitelisted.
- **Multi-User Production Access**: When a non-owner SSH user (e.g. `devops`) interacts with a production deployment owned by another user (e.g. `devopsadmin`):
  1. Add the SSH user to the owner's group: `sudo usermod -aG <owner_group> <ssh_user>`.
  2. Ensure parent directory traversal: `chmod g+rx /home/<owner>` and `chmod -R g+rX <path_to_odoo>`.
  3. Grant passwordless sudoers rules for the helper commands in `/etc/sudoers.d/`.

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
