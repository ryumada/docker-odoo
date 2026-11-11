# TODO: snapshot integrity and the snapshot validator

Where this work stands. Tick an item when its change is done and tested in the worktree (the owner commits); add new items at the end of their section.
Details live in `scripts/README.md` (snapshot tool, validator, Secondary VPS setup) and in the tests under `tests/`.

## Done

### Snapshot side
- [x] Queue timeout falls back to 43200 when `SNAPSHOT_QUEUE_TIMEOUT` is missing or invalid.
- [x] Repositories that can't be re-cloned (no remote, unpushed commits, uncommitted changes) are bundled with their `.git`; commit and reason recorded. Restore never clones them and keeps old copies in `.pre-restore-backups/`.
- [x] Shared queue lock (`scripts/lib/queue_lock.sh`): per-job markers in `/tmp`, heartbeat, stale-job cleanup, same code locally and on the Secondary VPS.
- [x] `.sha256` written while the archive is created; upload checks against Drive's sha256 and GCS's crc32c; checksum file uploaded next to each snapshot.
- [x] Sidecar-aware retention (`scripts/lib/snapshot_storage.sh`): exact name matching (`odoo` / `odoo-staging`), sidecars deleted with their snapshot, `--keep 0` refused, and the newest validated snapshot is never deleted.
- [x] List, download, manual upload and restore verify the checksum.
- [x] Odoo version in `manifest.json` read correctly from `odoo/release.py` (`scripts/lib/odoo_version.sh`, shared with the backup tools' fallback); never a made-up `16.0`.

### Validator (`scripts/validate-snapshot.sh`)
- [x] Drill: fetch, checksum, archive, structure, manifest, git (only the commit is fetched), disk, database restore, filestore against `ir_attachment`.
- [x] Remote mode: drills run on the Secondary VPS over SSH; report comes back to the main VPS.
- [x] Own queue (`odoo-snapshot-validator`), disk check before the drill and watchdog during it, low priority with Docker CPU and memory limits.
- [x] Older snapshot format (`backupdata-<service>.zip` inside the archive).
- [x] JSON report in the deployment owner's home; `--publish` writes `<archive>.validated.json` next to the snapshot (this settles where "passed validation" is stored).
- [x] Manifest version checked against the restored database (`base` module); report's `odoo_version` comes from the database.
- [x] Rootless Docker on the Secondary VPS: `scripts/setup-validator-docker.sh` (AppArmor clash handled), readiness check, triggered from `setup.sh`.

### Security
- [x] No secret on a command line: Odoo master password, PostgreSQL password, Drive tokens and service-account assertions (`tests/test_secret_args.sh`).

### Tests
- [x] `tests/test_validate_snapshot.sh` (local, formats, version, storage, credentials, rootless, setup, remote).
- [x] `tests/test_secret_args.sh`.
- [x] `tests/test_restore_snapshot.sh`.

## Open

### Problems that already existed
1. [x] `restore-snapshot.sh` hides `psql` / `pg_restore` errors, so a half-failed restore can report success. Fixed: errors shown and fatal (known-harmless ones warn), cut-short dumps refused before anything is touched, open sessions no longer block the drop, Odoo modules checked after the restore (`tests/test_restore_snapshot.sh`).
2. [x] Data-only restore doesn't extract bundled repository folders. Fixed: members chosen from the archive's listing, bundled directories extracted whole, configuration and custom directories left out; both restore modes refuse a snapshot missing a bundled directory before changing anything (`tests/test_restore_snapshot.sh`).
3. [x] The addon's access-control findings from the earlier review. Done in `sudodevops_odoo_utilities` (A01-A04, tracked in its own `TODO.md`); A01 checked against the code: no self-grant, migration no longer re-grants, listing methods check access, stop and `.env` need a Manager, name and path unique per server, `requeue` restricted, `with_user` tests present.
14. [x] Block `/queue_job/` at the reverse proxy ("Fix first" item 7 of the addon review). Done: the job runner calls Odoo directly on its own port (`http_interface` or `localhost`), not through the proxy, so blocking is safe; every Odoo nginx template answers 404 for `/queue_job/...` except `/queue_job/static/`; `setup.sh` adds a Traefik router that does the same (also for paths starting with `//`, which Odoo reads as `/`); tested with nginx and Traefik v2 and v3 (`tests/test_reverse_proxy.sh`).

### Snapshot side
4. [x] `sudodevops` block in `manifest.json` (database size, filestore size, attachment count) via a shared `scripts/lib/odoo_sizes.sh`; `disk_free_monitor.sh` uses it too (records `null`, not `0`, on failure). The drill's disk estimate then uses real sizes. Done: also the PostgreSQL version; works for a database on another host; `disk_free_monitor.sh` now supports one too (`tests/test_odoo_sizes.sh`).
5. [x] Remote mode: hand the archive to the validator inbox on the Secondary VPS instead of deleting it; keep only the newest pending snapshot per deployment. Done: `SNAPSHOT_VALIDATOR_INBOX` (default off); moved after the upload, hard-linked when the archive is kept there anyway, never copied; skipped below `VALIDATOR_DISK_RESERVE_GB`; `job.json` records the Drive name and id and the GCS object and generation for the worker (#10); layout in `scripts/README.md` (`tests/test_validator_inbox.sh`).
6. [x] Write `stats.json` on the Secondary VPS after each remote snapshot, for the disk reserve. Done: `~/.odoo-snapshots/<service>/stats.json` with the dump and archive sizes and the free space the snapshot took at its fullest point; the validator and the inbox hand-off raise the reserve to the largest recent need on that disk (+25%), and the report says which reserve applied (`tests/test_snapshot_stats.sh`, local suite of `tests/test_validate_snapshot.sh`).
7. [-] Dropped (owner's decision): dated snapshots in GCS. GCS history is kept with the bucket's own tools instead: Object Versioning plus a lifecycle rule (see "For the owner").
8. [x] Optional: retention for local archive folders. Done: `SNAPSHOT_LOCAL_MAX_BACKUPS` (default 5, empty keeps all) applied after each local snapshot to `~/.odoo-snapshots/<service>/archives`; keeps the newest N plus the newest that passed a drill, never deletes a folder with other files or an archive in use; manual `cleanup-snapshot.sh --local [--list|--dry-run|--keep N]` (`tests/test_local_retention.sh`).

### Validator
9. [x] Phase 2: start Odoo against the restored copy. Neutralize the database, no outbound network, check registry load and boot, `/web/login` returns 200. Done: on by default (`--no-boot` / `VALIDATOR_BOOT=false`); code checked out at the proved commits; image pulled with the snapshot's pull key or built from `dockerfile.example` + `requirements.txt` and cached; pass bar = registry, installed modules and `/web/login` (other ERROR lines warn, `VALIDATOR_BOOT_STRICT=true` per deployment makes them fail); reports and records carry `"level": "boot"` (`boot` suite of `tests/test_validate_snapshot.sh`).
10. [x] Worker (systemd timer or cron) that drills inbox snapshots automatically, with `VALIDATOR_MIN_INTERVAL_HOURS`. Done: `scripts/validate-snapshot-worker.sh`, hourly cron per deployment on the main VPS (`VALIDATOR_WORKER=true`, installed by `setup.sh`, removed with the snapshot tool); due `VALIDATOR_MIN_INTERVAL_HOURS` (24) after a pass or fail, a quarter of it (at least 1 h) after an error, manual drills included; drills the inbox snapshot first (`validate-snapshot.sh --inbox`: no download, record next to its Drive / GCS / kept copy, job back in the inbox after an error), else the newest on Drive / GCS / kept copy / local archives unless `--unless-checksum` shows the last drill already proved it (exit 5, no report); `--status`, `--force`, one run per deployment at a time (`worker` suite of `tests/test_validate_snapshot.sh`, and `remote`). Also fixed: `exec {fd}<&- 2>/dev/null` in the validator's cleanup and in `queue_lock.sh` sent the rest of the log to /dev/null.

### Odoo addon
11. [x] Validation result model, Valid / Broken / Skipped badge, drill settings per deployment. Done in `sudodevops_odoo_utilities` (`sudodevops_deployment_control` 18.0.2.1.0, tracked in its `TODO.md`): `depcon.snapshot.drill` (one record per drill report, read-only, record rules per environment); badge on every deployment from the newest pass or fail (Valid, Broken; Skipped when never drilled, only errors, or the pass is older than 2 x `VALIDATOR_MIN_INTERVAL_HOURS`); drill settings (`VALIDATOR_WORKER`, `VALIDATOR_MIN_INTERVAL_HOURS`, `VALIDATOR_BOOT_STRICT`, `SNAPSHOT_VALIDATOR_INBOX`) read from and written to the deployment's `.env` by managers, only the changed lines, audit-logged.
12. [x] Cron that collects drill reports over SSH (since fixed: it runs `scripts/read-drill-reports.sh` with `sudo -n`, see the owner list; a refused sudo shows a short message on the deployment). Done (same module): hourly scheduled action and a *Refresh Drill Status* button; one read-only command as the deployment owner prints the reports of `~/.odoo-validator/reports` (or `VALIDATOR_WORK_DIR`) and the drill settings, nothing else from the `.env`; an unreachable deployment is recorded and skipped, and every badge ages on each run. Checked on a real Odoo 18 (install, upgrade from 18.0.2.0.0, functional run) and by `tests/test_snapshot_drill.py`.
13. [x] Alerts by email, Google Chat / Slack webhook and Telegram. Done (same module, 18.0.2.2.0): an alert when a badge turns Broken or Skipped, when it is Valid again, a reminder every N hours while Broken (default 24), and one when a deployment's drill reports could not be read for N hours (default 24); sent to the deployment's chatter (a *Snapshot Drill Alert* subtype followers can switch on), an e-mail list, Google Chat and Slack webhooks and a Telegram bot, all set once in *Settings > Deployment Control* (webhooks and token encrypted with `depcon_encryption_secret`, write-only, redacted from errors). Only the environments chosen there alert (default Production), and a deployment can be muted. Checked on a real Odoo 18 (install, upgrade from 18.0.2.0.0 and 18.0.2.1.0, functional run, settings page in a browser) and by `tests/test_drill_alert.py`.

## For the owner (not code)
- [ ] Turn on automatic drills where wanted: `VALIDATOR_WORKER=true` (and `SNAPSHOT_VALIDATOR_INBOX=true` for deployments with a Secondary VPS, so drills need no download) in `.env`, then re-run `./setup.sh`. Check with `validate-snapshot-worker-<service> --status` and `/var/log/odoo/_utilities/validate-snapshot-<service>.log`. Several deployments on one Secondary VPS drill one at a time there: keep `VALIDATOR_MIN_INTERVAL_HOURS` large enough that every deployment's drill fits.
- [ ] Drill collection over SSH (found on the partsindo server: "sudo: a terminal is required"): update docker-odoo on every deployment (it brings `scripts/read-drill-reports.sh`), and on every server re-run Deployment Control's `setup.sh` as root (it allows that script with sudo, no password, no arguments). Then *Refresh Drill Status* on one deployment per server.
- [ ] Control Odoo (where `sudodevops_deployment_control` runs): upgrade the module to 18.0.2.2.0 (`-u sudodevops_deployment_control`), then check a deployment's *Snapshot Drill* group after *Refresh Drill Status*. Its server needs `python3` (already a docker-odoo dependency). For alerts: make sure `depcon_encryption_secret` is set and an outgoing mail server works, fill *Settings > Deployment Control > Snapshot Drill Alerts* (e-mails, webhooks, Telegram bot and chat), press *Send Test Alert*, and switch on *Snapshot Drill Alert* on the deployments you follow.
- [ ] First real boot drill per deployment: run `./scripts/validate-snapshot.sh --drive <service>` and check the `boot` stage. The first one builds the drill image on the Secondary VPS (a few minutes, needs internet there and about 1.5 GB of disk per image). Deployments in builder/production mode pull their image with the `DOCKER_PULL_KEY` from the snapshot's `.env` instead. Set `VALIDATOR_BOOT_STRICT=true` for deployments whose log turns out clean.
- [ ] GCS buckets used for snapshots: turn on Object Versioning and add a lifecycle rule for noncurrent versions (e.g. keep the newest N with `numNewerVersions`, or delete after `daysSinceNoncurrentTime`). The snapshot tool overwrites one object per deployment, so without versioning the previous snapshot is gone as soon as the next upload finishes.
- [ ] On every nginx VPS: add the `/queue_job/` block to each Odoo site in `/etc/nginx/sites-available/` (see README, "`/queue_job/` is closed at the proxy"), then `sudo nginx -t && sudo systemctl reload nginx`. Traefik deployments: re-run `./setup.sh`.
- [ ] Check that Odoo's `PORT` and `GEVENT_PORT` are closed to the internet in the firewall (host network: Odoo listens on every interface, and `/queue_job/runjob` is open on those ports without the proxy).
- [ ] On every deployment: update docker-odoo and re-run `./setup.sh` (installs the fixed snapshot, backup and restore tools). AFI still runs the old snapshot tool.
- [ ] Test the master-password paths (backup, restore, clone, release-candidate deploy) and the PostgreSQL password through Docker (e.g. `./scripts/list-databases.sh` against a remote database).
- [ ] If a deployment uses Enterprise: private GitLab mirror for its `odoo-base`.
- [ ] Old Drive snapshots have no `.sha256`; they show as "missing" and download with a warning until they age out.
- [ ] When everything is merged: `git worktree remove` the worktrees and delete merged branches.
