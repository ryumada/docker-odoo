---
title: Scripts and Utilities Guide
category: Guide
description: Documentation for helper scripts and utilities.
context: Scripts
maintainer: ryumada
---

This directory contains utilities to help docker-odoo deployment.

> Most of these utilities are installed automatically when you run the main `setup.sh` script from the root of the repository. The instructions below are for manual installation or for understanding how they work.

<details>
<summary>

# Backup Data

</summary>

This utilities will backup Odoo database and its datadir into a zip file. This zip file can be restored using Odoo Database Manager.

See the example file to create the data backup utility (`./scripts/example/backupdata.sh.example`).

  1. Copy the example file. This will export the service name from your cloned respository dirname.
      ```bash
      export SERVICE_NAME=$(basename "$PWD")
      cp ./scripts/example/backupdata.sh.example ./scripts/backupdata-$SERVICE_NAME.sh
      ```

  2. Edit your example file with your favorite text-editor (`vim` or `nano`, etc)
      ```bash
      vi ./scripts/backupdata-$SERVICE_NAME.sh
      ```

  3. You need to find (`ctrl + f`) the `enter` word to see which value should be changed

  4. Save the file and change the permission.
      ```bash
      sudo chmod 755 ./scripts/backupdata-$SERVICE_NAME.sh
      ```

  5. Create a soft-link to system-wide bin
      ```bash
      sudo ln -s $PWD/scripts/backupdata-$SERVICE_NAME.sh /usr/local/sbin/backupdata-$SERVICE_NAME
      ```

  6. Done, you can try to run the command.
      ```bash
      backupdata-$SERVICE_NAME
      ```

### Lightweight Backup Flags (Manual Mode)

You can pass flags to exclude heavy chatter or web assets, or prune orphaned disk files before packaging:
```bash
# Exclude chatter attachments (dedup-safe: keeps records, images, and binary fields)
backupdata-$SERVICE_NAME --exclude-chatter

# Exclude regenerable web asset bundles (CSS/JS)
backupdata-$SERVICE_NAME --exclude-assets

# Prune unreferenced physical files from filestore before archiving
backupdata-$SERVICE_NAME --clean-orphans

# Combine options
backupdata-$SERVICE_NAME --exclude-chatter --exclude-assets --clean-orphans
```

</details>

<details>
<summary>

# Filestore Manager

</summary>

This utility analyzes, lists, audits, and safely cleans Odoo filestore attachments and orphaned files without breaking database integrity.

Run directly from the repository root:

```bash
# 1. Storage breakdown by category, top models, and excludable savings
./scripts/filestore-manager.sh summary

# 2. List attachments with ownership, model, size, and category
./scripts/filestore-manager.sh list --category chatter --limit 20
./scripts/filestore-manager.sh list --model sale.order
./scripts/filestore-manager.sh list --csv /tmp/attachments.csv

# 3. Clean orphaned physical files (files on disk not referenced in ir_attachment)
./scripts/filestore-manager.sh clean-orphans --dry-run
./scripts/filestore-manager.sh clean-orphans -y

# 4. Clean regenerable web assets (CSS/JS bundles; Odoo rebuilds them on demand)
./scripts/filestore-manager.sh clean-assets

# 5. Clean missing attachment records after restoring a lightweight backup
./scripts/filestore-manager.sh clean-missing --category chatter -y
```

</details>

<details>
<summary>

# Database Cloner

</summary>

This utilies will clone the database from the current deployment to it's dev (development), stg (staging), tst (testing), or other deployment.

See the example file to create the database cloner utility (`./scripts/example/databasecloner.sh.example`).

  1. Copy the example file. This will export the service name from your cloned respository dirname.
      ```bash
      export SERVICE_NAME=$(basename "$PWD")
      cp ./scripts/example/databasecloner.sh.example ./scripts/databasecloner-$SERVICE_NAME.sh
      ```

  2. Edit your example file with your favorite text-editor (`vim` or `nano`, etc)
      ```bash
      vi ./scripts/databasecloner-$SERVICE_NAME.sh
      ```

  3. You need to find (`ctrl + f`) the `enter` word to see which value should be changed

  4. Save the file and change the permission.
      ```bash
      sudo chmod 755 ./scripts/databasecloner-$SERVICE_NAME.sh
      ```

  5. Create a soft-link to system-wide bin
      ```bash
      sudo ln -s $PWD/scripts/databasecloner-$SERVICE_NAME.sh /usr/local/sbin/databasecloner-$SERVICE_NAME
      ```

  6. Done, you can try to run the command.
      ```bash
      databasecloner-$SERVICE_NAME
      ```

</details>

<details>
<summary>

# Restore Snapshot

</summary>

To use restore snapshot, make sure the main directory (`../`) is has the same name of the archive file. For example, `snapshot-docker-odoo.tar.zst` the main directory name should be `docker-odoo` removing the `snapshot-` prefix and `.tar.zst` suffix.

Before you run the restore snapshot script, you need to prepare [snapshot utilities first](#snapshot-utilities).

```bash
# Full snapshot restore (replaces database, filestore, and environment/config files)
./scripts/restore-snapshot.sh

# Fast data-only restore (restores database + filestore only, skips config/environment overwrite and container restart)
./scripts/restore-snapshot.sh --data-only

# Fast data-only restore with specific file and skip confirmation
./scripts/restore-snapshot.sh --data-only ~/snapshot-docker-odoo.tar.zst -y
```

</details>

<details>
<summary>

# List Snapshot

</summary>

Lists available Odoo snapshot archives stored on Google Drive using Google Service Account credentials.

```bash
# List snapshots for the current project
./scripts/list-snapshot.sh

# List all snapshots across all projects/services
./scripts/list-snapshot.sh --all

# Output listing in JSON format
./scripts/list-snapshot.sh --json
```

</details>

<details>
<summary>

# Download Snapshot

</summary>

Downloads an Odoo snapshot archive directly from Google Drive by File ID, sharing URL, filename, or `latest`.

```bash
# Download the latest snapshot for this project
./scripts/download-snapshot.sh latest

# Download using Google Drive File ID
./scripts/download-snapshot.sh 1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OIvE2up0Y

# Download using Google Drive sharing URL
./scripts/download-snapshot.sh "https://drive.google.com/file/d/1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OIvE2up0Y/view"

# Interactive selection menu
./scripts/download-snapshot.sh
```

By default, `download-snapshot.sh` saves the file to `~/<filename>` and creates `~/snapshot-<service>.tar.zst`, allowing immediate restoration with `./scripts/restore-snapshot.sh`.

</details>

<details>
<summary>

# Validate Snapshot

</summary>

Restore drill that proves a snapshot can really be recovered. It runs in throwaway Docker containers on an internal network with no outbound access, and never touches the production server or its database.

**Where it runs.** When `SNAPSHOT_REMOTE_HOST` is set in `.env`, you start the validator on the main VPS as usual, but the drill runs on the Secondary VPS, over the same SSH connection the snapshot tool uses (`SNAPSHOT_REMOTE_USER`, `SNAPSHOT_REMOTE_PORT`, `SNAPSHOT_REMOTE_KEY`). The download, Docker and the restore all happen there; the main VPS only shows the live log and keeps the report. Nothing is installed on the Secondary VPS: the validator is sent over SSH for each run and removed afterwards. It needs rootless Docker for that user (see **Secondary VPS setup** below), `zstd`, `git`, `python3` and `curl` there, `gcloud` for GCS, and read access to your git repositories (GitLab Reporter). Without `SNAPSHOT_REMOTE_HOST`, or with `--local`, the drill runs on the host you start it on.

**Secondary VPS setup (once).** Drills use **rootless Docker** for the SSH user (`SNAPSHOT_REMOTE_USER`, e.g. `odoo-backupper`): that user gets its own Docker daemon and never gets root. Do not add it to the `docker` group instead: that membership is equivalent to root on the VPS, and anyone with the main VPS's SSH key would have it. Set it up from the main VPS with a sudo admin account of the Secondary VPS:

```bash
./scripts/setup-validator-docker.sh -a sysadmin --check   # what is missing (nothing is changed)
./scripts/setup-validator-docker.sh -a sysadmin           # set it up (asks for the admin password)
echo "secret" | ./scripts/setup-validator-docker.sh -a sysadmin --password-stdin
./scripts/setup-validator-docker.sh --check               # read-only check as the drill user, with its snapshot key
```

It reads `SNAPSHOT_REMOTE_HOST`, `SNAPSHOT_REMOTE_USER` and `SNAPSHOT_REMOTE_PORT` from `.env`, and only does what is missing (running it again is safe): installs `docker-ce-rootless-extras` (or `rootlesskit` with Ubuntu's `docker.io`), `uidmap`, `dbus-user-session` and `slirp4netns`; gives the user subordinate UID/GID ranges; adds the AppArmor profile Ubuntu 23.10+ needs for rootless user namespaces; delegates CPU, memory and process limits to user services (so drills can be limited); turns on lingering; runs `dockerd-rootless-setuptool.sh install` as the user; and checks that its Docker answers. It needs Docker Engine and cgroup v2 on the VPS, and never restarts the user's services while a drill is running. `--remove-docker-group` also takes the user out of the `docker` group. On the Secondary VPS itself: `sudo ./scripts/setup-validator-docker.sh --local -u odoo-backupper`.

`./setup.sh` checks this automatically when `ENABLE_SNAPSHOT` and `SNAPSHOT_REMOTE_HOST` are set and the snapshot key works: if something is missing it offers to set it up (it asks for the admin account; leave it empty to skip), or adds a TODO when run non-interactively. The validator also checks it before each drill and names the missing step.

Its images, containers and the drill's database live in `~odoo-backupper/.local/share/docker`, so that disk needs room for the restored database (the disk reserve check watches it automatically).

Checks, in order: checksum (`.sha256`), the whole archive decompresses, required files are present, the Odoo version in `manifest.json` (read from `version_info`, then compared with the restored database's `base` module: a mismatch is a warning, and the report's `odoo_version` is the database's), every git repository can be re-cloned at its recorded commit (or is bundled; only the commit itself is fetched, and the report says per repository whether it was found by id or in the history and how long it took), `dump.sql` restores completely (end-of-dump marker, zero SQL errors) into a matching Postgres version and looks like a usable Odoo database (core tables, users, keys and indexes), and every stored attachment exists in the filestore with the right size. Older snapshots (before the October 2026 snapshot refactor), which keep `dump.sql`, `manifest.json` and the filestore in `backupdata-<service>.zip` inside the archive, are checked the same way: the zip is taken out, every file in it is checked against its CRC, and the report says `"format": "older: backupdata-<service>.zip inside the archive"`.

```bash
# Drill a local snapshot file
./scripts/validate-snapshot.sh --file ~/snapshot-docker-odoo.tar.zst

# Drill the newest Google Drive snapshot of a service and record the result next to it
./scripts/validate-snapshot.sh --drive docker-odoo --publish

# Drill one specific Google Drive snapshot
./scripts/validate-snapshot.sh --drive docker-odoo --name snapshot-docker-odoo-20261104-010000.tar.zst --publish

# Drill a snapshot in Google Cloud Storage
./scripts/validate-snapshot.sh --gcs gs://my-bucket/snapshot-docker-odoo.tar.zst --publish

# With a Secondary VPS, --file is a path ON the Secondary VPS (relative paths start in its home folder),
# e.g. a snapshot kept there because its upload failed
./scripts/validate-snapshot.sh --file .odoo-snapshots/docker-odoo/archives/snapshot-docker-odoo.tar.zst

# Drill on this host even though SNAPSHOT_REMOTE_HOST is set
./scripts/validate-snapshot.sh --local --file ~/snapshot-docker-odoo.tar.zst
```

| Exit code | Meaning |
|---|---|
| `0` | Passed: the snapshot is recoverable (with `--publish`, the record was written) |
| `1` | Failed: the snapshot itself is broken |
| `2` | Could not finish for reasons outside the snapshot (Docker, network, Drive/GCS, unreachable git remote, not enough disk, interrupted, SSH to the Secondary VPS failed or was lost). Nothing was proven either way |
| `3` | Usage or configuration error (for example an invalid `VALIDATOR_*` value, or a Secondary VPS missing a required tool or the rootless Docker setup; the log names the step) |
| `4` | Passed, but `--publish` could not write the record, so retention will not protect this snapshot |

- Each run writes a JSON report to `.odoo-validator/reports/` in the home folder of the deployment's owner (the owner of this checkout, as the snapshot tool uses), plus `latest-<service>.json`, whoever runs it: as root (`sudo`) the files are handed to the owner. Another user's runs fall back to their own home, with a warning. `VALIDATOR_WORK_DIR` overrides it. A drill that ran on the Secondary VPS has its report copied back to the main VPS, marked with `"remote"`; the copy on the Secondary VPS is temporary.
- Remote drills: the Drive service account key or token is read on the main VPS and sent over SSH stdin into a private (0600) folder on the Secondary VPS, never on a command line, and removed when the drill ends (a folder left behind by a lost session is removed by the next drill). GCS drills use the Secondary VPS's own `gcloud` login, like the snapshot tool. If the main VPS stops the validator (Ctrl-C, `kill`, lost connection), the drill on the Secondary VPS notices within a few seconds, stops and removes its containers.
- With `--publish`, a passed drill uploads `<snapshot>.validated.json` next to the snapshot, and retention then keeps the newest validated snapshot even beyond `MAX_SNAPSHOT_BACKUPS`. The record lists the result of every check. It is only written when the git check really ran (not with `--no-git-check` or without `git_hashes.json`); otherwise the drill exits `4`. A **failed** drill removes an existing record, so a snapshot that no longer restores stops being protected. Exit code `2` never touches records.
- Prefer `GDRIVE_SERVICE_ACCOUNT_KEY` in `.env` over `--token`: command-line arguments are visible to other users of the host. Drive tokens are never put on command lines by the scripts themselves.
- The drill reads one fixed copy of the snapshot: the archive is held open for the whole run, and a GCS object is downloaded at a fixed generation. If the snapshot is replaced while the drill runs, no record is written for the new file.
- Git remotes come from the snapshot, so they are treated as untrusted: only real commit ids are accepted, and only the transports in `VALIDATOR_GIT_ALLOW_PROTOCOL` (default `https:ssh`) are used. The validator's user needs read access (deploy key or GitLab Reporter) to every repository.
- One drill runs at a time per host (queue `odoo-snapshot-validator`, separate from the snapshot queue), at the lowest CPU and I/O priority. `VALIDATOR_DISK_RESERVE_GB` (default 5) keeps free disk for snapshots: a drill does not start below it and is stopped if free space falls below it while running. Leftovers of a drill that was killed are removed when the next drill starts.
- This is phase 1 of the validator: it does not boot Odoo yet. Reports and records carry `"level": "database"`.

**Tests.** `./tests/test_validate_snapshot.sh [local|formats|version|storage|credentials|rootless|setup|remote|all]` (from the repo root; `TVS_KEEP=1` keeps the work folder, `TVS_VERBOSE=1` shows the log under a failed check). They are safe on a real VPS or dev machine: everything happens in one `mktemp` folder that is removed at the end, the validator runs from a copy of `scripts/` with an empty `.env` (your real `.env`, Secondary VPS and Drive credentials are never read), queue locks go to that folder (`QUEUE_LOCK_DIR`), Docker, `df` and `gcloud` are fakes (a "container" is a throwaway local Postgres on 127.0.0.1), Google Drive is a local mock, and the remote suite starts its own `sshd` on 127.0.0.1 without touching `~/.ssh`. Linux only; needs `python3`, `zstd`, `tar`, `git`, `curl`, `openssl`, `flock`, the PostgreSQL server binaries (`PG_BIN` to choose them), and `ssh`/`sshd` for the remote suite (skipped with the reason if a login is not possible). Run them as a normal user to cover everything: as root, the `rootless` suite and the drill-host steps of the `setup` suite are skipped. `formats` covers older snapshots (`backupdata-<service>.zip` inside the archive); `version` covers how the snapshot tool reads the Odoo version from `odoo/release.py` and how the validator checks it; `setup` covers `setup-validator-docker.sh` (`--check` against a stubbed system; setup mode itself is left to a test VPS). Support files are in `tests/validate_snapshot/`.

**Secrets on command lines.** No script passes a secret as a command argument, where any user on the server can read it with `ps`: the Odoo master password reaches `curl` on its stdin (`printf '%s' "$ADMIN_PASSWD" | curl -F "master_pwd=<-" ...`, or `--data-urlencode "master_pwd@"<(printf ...)` for urlencoded calls), Google Drive tokens and service-account assertions go through a pipe (`-H @<(printf 'Authorization: Bearer %s\n' ...)`, `--data-urlencode "assertion@"<(...)`, and the token check POSTs the token instead of putting it in the URL), and the PostgreSQL password is handed to Docker through the environment (`PGPASSWORD="$db_pass" docker run ... -e PGPASSWORD ...`, also for `docker exec`). Keep new scripts to these forms: `./tests/test_secret_args.sh` scans every script for secrets in arguments and checks, with the real `curl` and `docker` clients against local stand-ins, that each form still delivers the exact value (a password with `;type=`, `<`, `@`, quotes and `&` included; the old `-F "master_pwd=$X"` form broke on those). It is safe anywhere: one `mktemp` folder, servers on 127.0.0.1 only, and Docker talks to a stand-in API that runs nothing.

</details>

<details>
<summary>

# Upload Snapshot

</summary>

Uploads a local Odoo snapshot archive to Google Drive using Google Service Account credentials or OAuth2 token configured in `.env`.

```bash
# Upload automatically detected snapshot for the current project
./scripts/upload-snapshot.sh

# Upload a specific snapshot file
./scripts/upload-snapshot.sh ~/snapshot-docker-odoo-20260826.tar.zst

# Upload with overridden Google Drive folder ID
./scripts/upload-snapshot.sh --folder-id "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OIvE2up0Y"
</details>

<details>
<summary>

# Upload Temporary Snapshots

</summary>

Uploads all temporary Odoo snapshot files and directories (stored in `~/.odoo-snapshots/.../archives` or `~/.odoo-tmp` when scheduled snapshot uploads fail due to key issues or connection errors) to the configured backup storage (Google Drive, Google Cloud Storage) based on `.env`. Once uploaded successfully, the local temporary files are automatically cleaned up.

```bash
# Upload all temporary snapshots for current service
./scripts/upload-temp-snapshots.sh

# Dry-run preview without uploading or deleting
./scripts/upload-temp-snapshots.sh --dry-run

# Upload temporary snapshots for all services
./scripts/upload-temp-snapshots.sh --all

# Upload temporary snapshots for a specific service name
./scripts/upload-temp-snapshots.sh --service fluidco-16

# Keep local temporary snapshots after successful upload
./scripts/upload-temp-snapshots.sh --keep-local
```

</details>

<details>
<summary>

# Cleanup Snapshot

</summary>

Inspects and cleans up older Odoo snapshots on Google Drive based on retention policy.

```bash
# List snapshots with total size and retention status without deleting
./scripts/cleanup-snapshot.sh -l

# Dry-run deletion simulation
./scripts/cleanup-snapshot.sh --dry-run

# Delete snapshots keeping the latest 10
./scripts/cleanup-snapshot.sh --keep 10 --force
```

</details>

<details>
<summary>

# Generate Snapshot SSH Key

</summary>

Generates an ed25519 SSH key pair named `snapshot-$THIS_VPS_HOSTNAME-$TARGET_VPS_HOSTNAME` in `~/.ssh`, updates `.env`, and outputs the public key for manual installation on the Secondary VPS.

```bash
# Generate key interactively or using .env SNAPSHOT_REMOTE_HOST
./scripts/generate-snapshot-ssh-key.sh

# Specify target VPS host directly
./scripts/generate-snapshot-ssh-key.sh --target-host backup-vps.example.com
```

</details>

<details>
<summary>

# Generate Deploy RC SSH Key

</summary>

Generates an ed25519 SSH key pair named `deploy_rc-$THIS_VPS_HOSTNAME-$TARGET_VPS_HOSTNAME` in `~/.ssh`, updates `PRD_SSH_KEY` in `.env`, and outputs the public key for installation on the Remote Production VPS. Supports automatic remote provisioning via remote sudo admin.

```bash
# Generate key interactively or using .env PRD_SSH_HOST
./scripts/generate-deploy-rc-ssh-key.sh

# Provision automatically via remote administrator (prompts for password once via stdin, or pipe it)
./scripts/generate-deploy-rc-ssh-key.sh -a sysadmin

# Non-interactive provisioning via piped stdin
echo "$ADMIN_PASSWORD" | ./scripts/generate-deploy-rc-ssh-key.sh -a sysadmin --password-stdin

# Specify target VPS host directly
./scripts/generate-deploy-rc-ssh-key.sh --target-host prd-vps.example.com -a sysadmin
```

</details>

<details>
  <summary>

  # Snapshot Utilities

  </summary>

  See the example file to create the snapshot utility (`./scripts/example/snapshot.sh.example`).

  1. Copy the example file. This will export the service name from your cloned repository dirname.
      ```bash
      export SERVICE_NAME=$(basename "$PWD")
      cp ./scripts/example/snapshot.sh.example ./scripts/snapshot-$SERVICE_NAME.sh
      ```

  2. Edit your example file with your favorite text-editor (`vim` or `nano`, etc)
      ```bash
      vi ./scripts/snapshot-$SERVICE_NAME.sh
      ```

  3. You need to find (`ctrl + f`) the `enter` word to see which value should be changed

  4. Save the file and change the permission.
      ```bash
      sudo chmod 755 ./scripts/snapshot-$SERVICE_NAME.sh
      ```

  5. Create a soft-link to system-wide bin
      ```bash
      sudo ln -s $PWD/scripts/snapshot-$SERVICE_NAME.sh /usr/local/sbin/snapshot-$SERVICE_NAME
      ```

  6. Add a new crontab to run your script (You can skip this step and continue to step 7 if you don't want to use cron for automatic snapshot).
      ```bash
      export SERVICE_NAME=$(basename "$PWD")
      cat << EOF > ~/snapshot-$SERVICE_NAME
      SHELL=/bin/bash
      PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

      27 */4 * * * root "/usr/local/sbin/snapshot-$SERVICE_NAME"

      EOF

      sudo mv ~/snapshot-$SERVICE_NAME /etc/cron.d/snapshot-$SERVICE_NAME
      sudo chown root:root /etc/cron.d/snapshot-$SERVICE_NAME
      sudo chmod 644 /etc/cron.d/snapshot-$SERVICE_NAME
      sudo systemctl restart cron
      ```

      > ⚠️ Replace `$SERVICE_NAME` to the value of your root repository name (`basename "$PWD"`).

  7. Rotate the logfile.
      > ⚠️ Make sure you are in the root repository.
      ```bash
      export SERVICE_NAME=$(basename "$PWD")
      sudo cat << EOF > ~/snapshot-$SERVICE_NAME
      /var/log/odoo/_utilities/snapshot-$SERVICE_NAME.log {
          rotate 4
          su root syslog
          olddir /var/log/odoo/_utilities/snapshot-$SERVICE_NAME.log-old
          weekly
          missingok
          #notifempty
          nocreate
          createolddir 775 odoo root
          renamecopy
          compress
          compresscmd /usr/bin/xz
          compressoptions -ze -T 0
          delaycompress
          dateext
          dateformat -%Y%m%d-%H%M%S
      }

      EOF

      sudo chown root:root ~/snapshot-$SERVICE_NAME
      sudo chmod 644 ~/snapshot-$SERVICE_NAME
      sudo mv ~/snapshot-$SERVICE_NAME /etc/logrotate.d/snapshot-$SERVICE_NAME
      ```

  8. You can setup Google Cloud Storage for automatic rotate snapshot file or use `logrotate` on Ubuntu.

  <details>
  <summary>

  ## Setup Google Cloud Storage as the storage of your snapshot

  </summary>

  Setup `google-cloud-cli` to move your backup file to Google Cloud using `gcloud storage`
  1. Prepare the key from service account for our server access to gcloud storage
     <details>
     <summary>
     The steps to prepare the service account
     </summary>

     1. Go to this page to get `gcs-backupper` key: https://console.cloud.google.com/iam-admin/serviceaccounts
     2. Then, click on your service account (example: gcs-backupper@ryumada.iam.gserviceaccount.com). You will be directed to the detail page of that service account.
     3. Click on the `Keys` tab.
     4. Create a new key by clicking `Add Key` button.
     5. Then click `Create new key` menu.
     6. Download the key as json file and move it to your server.
     7. Move your key file to that directory and set the owner of the keyfile to the user.

      </details>

  2. Install `google-cloud-cli` from GCP Official docs
     <details>
     <summary>
     Follow this docs for the guide:
     </summary>

     [Install the gcloud CLI  |  Google Cloud CLI Documentation](https://cloud.google.com/sdk/docs/install)
     </details>

  3. Activate the service account (auth using the json key)
     <details>
     <summary>
      The steps to activate the service account
     </summary>

     1. Move the `json` key file to the server using `scp`

         ```bash
         scp -P $YOUR_SSH_PORT /path/to/your/gcloud_service_account.json odoo@your-server-ip:/opt/.keys/gcloud_service_account.json
         ```

     2. Create a `keys` directory in `/opt` and set up the least permission to the storage.

        ```bash
        sudo mkdir /opt/.keys

        sudo chown $USER:$USER /opt/.keys
        # denied access for other user
        sudo chmod 750 /opt/.keys

        sudo chown $USER:$USER /opt/.keys/gcloud_service_account.json
        sudo chmod 440 /opt/.keys/gcloud_service_account.json
        ```

     3. Use Linux user that used for runnig the backup utility, normally the user is `odoo`

        ```bash
        sudo su odoo
        ```

     4. Activate the service account

        ```bash
        gcloud auth activate-service-account --key-file $JSON_KEY_FILE
        ```

        [gcloud auth activate-service-account  |  Google Cloud CLI Documentation](https://cloud.google.com/sdk/gcloud/reference/auth/activate-service-account)
     </details>

   4. Test your service account

      ```bash
      gcloud storage ls gs://$YOUR_GCS_BUCKET/
      ```

      The command will list objects available on `$YOUR_GCS_BUCKET` bucket.

      If the command show the list of files, it means that your service account is successfully authenticated.

   5. Setup object lifecycle and versioning to your bucket

      See this documentation to know how it's works:
      - https://cloud.google.com/storage/docs/lifecycle
      - https://cloud.google.com/storage/docs/object-versioning

  </details>

</details>

<details>
<summary>

# VSCode Server

</summary>

This utility installs and manages a systemd service for running VSCode Web Server (`code serve-web`) to assist in debugging Odoo deployments.

### Setup & Usage

1. Enable in `.env`:
    ```bash
    ENABLE_VSCODE_SERVER=Y
    VSCODE_SERVER_PORT=8000
    VSCODE_DIRECT_DOWNLOAD_URL=
    ```

2. Run `setup.sh` or run the installer script directly:
    ```bash
    sudo ./scripts/installer/install-code_server.sh
    ```

3. Restart service and retrieve authentication token:
   Executing the installer or the system-wide restart command will restart the service, extract the token from `journalctl`, and save it to your home directory:
    ```bash
    sudo /usr/local/sbin/restart-code_server
    cat ~/vscode-server-token.txt
    ```

4. Nginx HTTPS Proxy setup (optional):
   See `nginx-configurations/nginx_sites_available_vscode.example` for the reverse proxy template with WebSocket and CORS support.

5. Uninstalling / Disabling:
   Set `ENABLE_VSCODE_SERVER=` in `.env` and re-run `setup.sh`, or execute:
    ```bash
    sudo ./scripts/installer/uninstall-code_server.sh
    ```

</details>
