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
14. [ ] Block `/queue_job/` at the reverse proxy in the nginx templates (`nginx-configurations/`): queue_job's `runjob` route runs a job as superuser, without login, for anyone who knows its UUID ("Fix first" item 7 of the addon review). First check how the job runner reaches Odoo, so blocking the path does not stop the runner.

### Snapshot side
4. [x] `sudodevops` block in `manifest.json` (database size, filestore size, attachment count) via a shared `scripts/lib/odoo_sizes.sh`; `disk_free_monitor.sh` uses it too (records `null`, not `0`, on failure). The drill's disk estimate then uses real sizes. Done: also the PostgreSQL version; works for a database on another host; `disk_free_monitor.sh` now supports one too (`tests/test_odoo_sizes.sh`).
5. [x] Remote mode: hand the archive to the validator inbox on the Secondary VPS instead of deleting it; keep only the newest pending snapshot per deployment. Done: `SNAPSHOT_VALIDATOR_INBOX` (default off); moved after the upload, hard-linked when the archive is kept there anyway, never copied; skipped below `VALIDATOR_DISK_RESERVE_GB`; `job.json` records the Drive name and id and the GCS object and generation for the worker (#10); layout in `scripts/README.md` (`tests/test_validator_inbox.sh`).
6. [ ] Write `stats.json` on the Secondary VPS after each remote snapshot, for the disk reserve.
7. [ ] Optional: dated snapshots in GCS instead of one overwritten object.
8. [ ] Optional: retention for local archive folders.

### Validator
9. [ ] Phase 2: start Odoo against the restored copy. Neutralize the database, no outbound network, check registry load and boot, `/web/login` returns 200.
10. [ ] Worker (systemd timer or cron) that drills inbox snapshots automatically, with `VALIDATOR_MIN_INTERVAL_HOURS`.

### Odoo addon
11. [ ] Validation result model, Valid / Broken / Skipped badge, drill settings per deployment.
12. [ ] Cron that collects drill reports over SSH.
13. [ ] Alerts by email, Google Chat / Slack webhook and Telegram.

## For the owner (not code)
- [ ] On every deployment: update docker-odoo and re-run `./setup.sh` (installs the fixed snapshot, backup and restore tools). AFI still runs the old snapshot tool.
- [ ] Test the master-password paths (backup, restore, clone, release-candidate deploy) and the PostgreSQL password through Docker (e.g. `./scripts/list-databases.sh` against a remote database).
- [ ] If a deployment uses Enterprise: private GitLab mirror for its `odoo-base`.
- [ ] Old Drive snapshots have no `.sha256`; they show as "missing" and download with a warning until they age out.
- [ ] When everything is merged: `git worktree remove` the worktrees and delete merged branches.
