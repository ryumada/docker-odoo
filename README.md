---
title: Odoo Docker Image
category: Guide
description: Documentation for the Odoo Docker image and deployment.
context: Project Root
maintainer: ryumada
---

# Odoo Docker Image
A Dockerfile to create a custom Odoo docker image.

| Specification | Version |
|----|----|
|Host OS|Ubuntu 22.04 / Debian 12 / **CentOS 8-9 Stream** (Linux)|
|Python|`'3.7'` (recommended) or `'3.10'`|
|Odoo version|`'16,17,18,19' (tested)`|
|PostgreSQL|`'14' (tested)`, and `'15, 16, 17'` (requires matching `POSTGRESQL_VERSION` in `.env` to the host version)|

| Python `'3.10'` has slower build time and not compatible with ks_dashboard.

| ⚠️ You need to read this README.md file thoroughly. ⚠️


## Host OS Prerequisites

Install the required packages on your **host machine** before running `setup.sh`.

> ⚠️ The Docker container always uses a Debian-based image regardless of host OS — these packages are for the host only.

<details>
<summary><strong>Debian / Ubuntu</strong></summary>

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-plugin logrotate postgresql
```
</details>

<details>
<summary><strong>CentOS 8 / 9 Stream</strong></summary>

```bash
# Install Docker CE
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker

# Install Logrotate and PostgreSQL
sudo dnf install -y logrotate postgresql-server
sudo postgresql-setup --initdb
sudo systemctl enable --now postgresql
```

> **SELinux Note:** If Docker bind-mounts to `/var/lib/odoo` or `/var/log/odoo` fail with permission errors, relabel those directories:
> ```bash
> sudo chcon -R -t container_file_t /var/lib/odoo /var/log/odoo
> ```
> Alternatively, allow Docker to use SELinux labels via volume options in `docker-compose.yml`:
> ```yaml
> volumes:
>   - /var/lib/odoo:/var/lib/odoo:z
> ```

</details>

There are some points you should know:

- **First**, you need to execute `sudo ./setup.sh` script to check if all of your files and directories are ready and to configure the deployment mode.
  ```bash
  sudo ./setup.sh
  ```

  > ⚠️ When asked, select the deployment mode:
  > - **1. Development**: Builds locally. Uses bind-mounts for `odoo-base` and `git` directories to allow real-time code changes.
  > - **2. Builder**: Builds the image, tags it, and prepares it for pushing to a registry. Includes bind-mounts for verification.
  > - **3. Production**: Pulls the pre-built image from the configured registry. No bind-mounts for code.

- **Configuration**:
  Check the `.env` file for important variables, especially:
  - `DOCKER_BUILD_MODE`: 1=Dev, 2=Builder, 3=Prod.
  - `ODOO_IMAGE_NAME`: Image name (e.g., `ghcr.io/username/project`).
  - `CURRENT_IMAGE_VERSION and NEXT_IMAGE_VERSION`: Image tag (e.g., `16.0-v1`).
  - `ODOO_IMAGE_SOURCE`: Source git repo (for GHCR labels).

- [`Odoo Base`] You should add your Odoo base, whether it is Odoo Community, Odoo Enterprise, or your custom Odoo base, to the `odoo-base` directory (⚠️ Only add one directory to `odoo-base` as this will be read automatically by the `entrypoint.sh` script, for the name of the directory is no need to be `odoo` ⚠️).

- [`Extra Addons/Modules`] Add your custom Odoo Modules (Odoo Addons) to `git` directory and add the path to addons_path in `./conf/odoo.conf`. Don't add unused custom module directory to this directory as it will be added to your docker image and increased the image size.

  > ⚠️ If your path is in `./git/odoo-custom-modules`, then your addons_path should be `/opt/odoo/git/odoo-custom-modules`.

  > ⚠️ If you have subdirectory inside your git addons repository path it should be like this:
  > - `/opt/odoo/git/odoo-custom-modules/subdir-1`
  > - `/opt/odoo/git/odoo-custom-modules/subdir-2`

- [`Odoo Static Data`] Odoo `datadir` is placed on `/var/lib/odoo` and Odoo `log` is placed on `/var/log/odoo`. These directories will be used by Odoo for static data storage and logging. It will be called in docker-compose (⚠️ These directories are automatically created on your host machine after you run `sudo ./setup.sh` ⚠️).

- `Build and Run` your odoo deployment.

  **Development / Builder Mode**:
  ```bash
  docker compose up -d --build
  ```

  **Production Mode**:
  ```bash
  docker compose pull
  docker compose up -d
  ```

- If your Odoo module needs libreoffice either:
  1. Set `INSTALL_LIBREOFFICE=Y` in `.env`.
  2. Or run:
  ```bash
  docker exec -itu root $CONTAINER_ID apt --no-install-recommends -y install libreoffice
  ```

- **Container Registry Workflow**:
  <details>
  <summary>Pushing to Container Registry</summary>

    1. Set `DOCKER_BUILD_MODE=2` (or select Builder mode in `setup.sh`).
    2. Set `ODOO_IMAGE_NAME`, `CURRENT_IMAGE_VERSION and NEXT_IMAGE_VERSION`, and `ODOO_IMAGE_SOURCE` in `.env`.
    3. Login to your registry:
       ```bash
       docker login ghcr.io -u <username> -p <token>
       ```
    4. Build and Push:
       ```bash
       docker compose build
       docker compose push
       ```
  </details>

## Multi-Deployment Setup (Folder-Based)

`docker-odoo` supports multi-deployment environments using isolated profiles under the `deployments/` directory. Each deployment can use different Odoo base versions, Python versions, ports, and `requirements.txt`.

### 1. Enable Multi-Deployment
In your root `.env` file, set:
```env
ENABLE_MULTI_DEPLOYMENT=Y
```

> ℹ️ Single-deployment mode remains active by default (`ENABLE_MULTI_DEPLOYMENT=N`).

### 2. Create Deployment Profiles
Each profile lives in `deployments/<deployment_name>/`:

```text
deployments/
├── project_a/
│   ├── .env              # Per-deployment overrides (PYTHON_VERSION, ODOO_VERSION, PORT, etc.)
│   └── requirements.txt  # Custom Python packages for project_a
└── project_b/
    ├── .env
    └── requirements.txt
```

> Copy template files from `deployments/deployment.example/.env.example` and `deployments/deployment.example/requirements.txt.example` to get started.

### 3. Switch Between Deployments
To switch active environments:

```bash
sudo ./scripts/switch_env.sh project_a
```

`switch_env.sh` automatically:
- Syncs per-deployment `.env` overrides and `requirements.txt`.
- Manages deployment secrets (`.secrets/db_user_project_a` and `.secrets/db_password_project_a`).
- Provisions host data (`/var/lib/odoo/docker-odoo-project_a`) and log (`/var/log/odoo/docker-odoo-project_a`) directories.
- Builds an isolated Docker image (`docker-odoo-project_a`) and starts the container.

# Maintenance
The image build using the dockerfile in this repository installed some utility scripts.

## Check the version of Odoo base
You can check the Odoo version and its git hash by running this command:

```bash
docker compose exec $SERVICE_NAME getinfo-odoo_base
```

<details>
  <summary>You can get <code>$SERVICE_NAME</code> by running <code>docker compose ps</code> in your root repository where docker compose file located. </summary>

  This is the output of the command:

  ```bash
  NAME                 IMAGE                COMMAND                  SERVICE   CREATED         STATUS         PORTS
  docker-odoo-odoo-1   docker-odoo:latest   "/opt/odoo/entrypoin…"   odoo      2 minutes ago   Up 2 minutes
  ```

  As you can see in the `SERVICE` column, the service name is `odoo`.
</details>

## Check the git repository for custom addons used by Docker Image
You can check the git repository information by running this command:

```bash
docker compose exec $SERVICE_NAME getinfo-odoo_git_addons
```

<details>
  <summary>You can get <code>$SERVICE_NAME</code> by running <code>docker compose ps</code> in your root repository where docker compose file located. </summary>

  This is the output of the command:

  ```bash
  NAME                 IMAGE                COMMAND                  SERVICE   CREATED         STATUS         PORTS
  docker-odoo-odoo-1   docker-odoo:latest   "/opt/odoo/entrypoin…"   odoo      2 minutes ago   Up 2 minutes
  ```

  As you can see in the `SERVICE` column, the service name is `odoo`.
</details>

## Run Odoo shell
Odoo shell has been created automatically after you run `sudo ./setup.sh` script. The shell is copied when the image is built. You can run the Odoo shell by running this command:

```bash
# See help to see how to use the shell
docker compose exec $SERVICE_NAME odoo-shell help

# example command to run shell with service_name odoo
docker compose exec odoo odoo-shell example_database_name
```

<details>
  <summary>You can get <code>$SERVICE_NAME</code> by running <code>docker compose ps</code> in your root repository where docker compose file located. </summary>

  This is the output of the command:

  ```bash
  NAME                 IMAGE                COMMAND                  SERVICE   CREATED         STATUS         PORTS
  docker-odoo-odoo-1   docker-odoo:latest   "/opt/odoo/entrypoin…"   odoo      2 minutes ago   Up 2 minutes
  ```

  As you can see in the `SERVICE` column, the service name is `odoo`.
</details>

## Run Odoo Module Upgrade tool
Odoo Module Upgrade tool also has been created automatically after you run `sudo ./setup.sh`. The tool is copied when the image is built. You can run the tool by running one of these command examples:

```bash
# See help to see how to use the tool
docker compose exec $SERVICE_NAME odoo-module-upgrade help

# example command to update odoo modules
## update single module
docker compose exec odoo odoo-module-upgrade example_database_name --update=module_name
## update multiple modules (Be careful with module that need to install in order)
docker compose exec odoo odoo-module-upgrade example_database_name --update=module_name1,module_name2
## update all modules (⚠️ This command is not recommended to use in production ⚠️)
docker compose exec odoo odoo-module-upgrade example_database_name --update=all
```

<details>
  <summary>You can get <code>$SERVICE_NAME</code> by running <code>docker compose ps</code> in your root repository where docker compose file located. </summary>

  This is the output of the command:

  ```bash
  NAME                 IMAGE                COMMAND                  SERVICE   CREATED         STATUS         PORTS
  docker-odoo-odoo-1   docker-odoo:latest   "/opt/odoo/entrypoin…"   odoo      2 minutes ago   Up 2 minutes
  ```

  As you can see in the `SERVICE` column, the service name is `odoo`.
</details>

## VSCode Server for Odoo Debugging (Host Server)
If you setup these variables in `.env`:

```env
# # # # # # # # # # # # # # # # #
# VSCODE SERVER FOR ODOO DEBUG  #
# # # # # # # # # # # # # # # # #
# Set Y to install VSCode Web Server systemd service for debugging Odoo
ENABLE_VSCODE_SERVER=Y
# Port for VSCode Web Server (default: 8000)
VSCODE_SERVER_PORT=8000
# Domain for VSCode Web Server Nginx proxy setup (e.g., vscode.example.com)
VSCODE_SERVER_DOMAIN=
# SSL Domain for VSCode Web Server Nginx proxy setup (e.g., example.com if using the main domain as the SSL or the domain is wildcard)
VSCODE_SERVER_SSL_DOMAIN=
# Custom working directory for VSCode Server (leave empty to default to path to Odoo repo)
VSCODE_SERVER_WORKING_DIR=
# Optional: Direct download URL of VSCode CLI .deb package if not installed on host server
VSCODE_DIRECT_DOWNLOAD_URL=
```

When `ENABLE_VSCODE_SERVER=Y` is set, `setup.sh` (or `sudo ./scripts/installer/install-code_server.sh`) will install and configure a systemd service running VSCode Web Server (`code serve-web`) on the host system. If `code` CLI is not installed on the host server, specifying `VSCODE_DIRECT_DOWNLOAD_URL` will automatically download and install VSCode CLI during setup.

<details>
  <summary>You can get <code>$SERVICE_NAME</code> by running <code>docker compose ps</code> in your root repository where docker compose file located. </summary>

  This is the output of the command:

  ```bash
  NAME                 IMAGE                COMMAND                  SERVICE   CREATED         STATUS         PORTS
  docker-odoo-odoo-1   docker-odoo:latest   "/opt/odoo/entrypoin…"   odoo      2 minutes ago   Up 2 minutes
  ```

  As you can see in the `SERVICE` column, the service name is `odoo`.
</details>

## Remote or Containerized PostgreSQL
By default, `docker-odoo` assumes PostgreSQL is running natively on the host machine. However, it fully supports connecting to remote PostgreSQL servers or containerized database instances (e.g., another Docker container like `docker-postgresql`).

### Configuration
1. Open up your `.env` file.
2. Change `DB_HOST` from `localhost` to the target IP address, domain name, or Docker container name (e.g., `docker-postgresql-postgres-1`).
3. Set `DOCKER_NETWORK_MODE` to the name of the Docker network shared between Odoo and your target database (e.g., `db-net`).

### Automatic Credential Generation
When `setup.sh` detects a non-local `DB_HOST`, it skips local database provisioning. Instead, it securely generates a strong PostgreSQL username and password, saving them into your local `.secrets/` directory.

The setup script will then print a precise `CREATE ROLE` SQL command to your terminal. Simply copy and execute this command manually within your target PostgreSQL instance to grant Odoo the necessary authenticated access!

*Note: All auxiliary tools (such as `scripts/example/restore_backupdata.sh.example` and `databasecloner.sh.example`) dynamically adapt to remote targets by spinning up lightweight `docker run --rm postgres` query runners to execute cross-network SQL commands safely, avoiding the need for host credentials!*

## Reverse Proxy (Traefik Support)
Deploying Odoo securely over the web with automated SSL generation and isolated internal traffic is strongly recommended. `docker-odoo` supports both NGINX and Traefik workflows out of the box.

If you are using **Traefik**, the `setup.sh` script will automatically map routing paths (including Longpolling and WebSockets logic for Odoo 16+) and mount all the necessary Docker labels onto your deployment!

### Configuration
1. Open up your `.env` file.
2. Ensure you have the following variables populated:

```env
# Choose your reverse proxy type (NGINX or Traefik)
REVERSE_PROXY_TYPE=traefik

# Set the domain here
TRAEFIK_DOMAIN=odoo.yourdomain.com

# Set the Let's Encrypt / TLS resolver name configured in your Traefik instance
TRAEFIK_CERTRESOLVER=letsencrypt
```

3. Ensure you have properly bound your Traefik proxy network so the containers can communicate locally.
```env
# Point this to your Traefik web network name
DOCKER_NETWORK_MODE=proxy
```
4. Simply run `sudo ./setup.sh`!
5. The `docker-compose.yml` file is immediately generated with fully baked isolation routing for `odoo.yourdomain.com` targeting both Standard HTTP traffic and `PathPrefix(\`/websocket\`)` longpolling traffic concurrently!

### `/queue_job/` is closed at the proxy
OCA `queue_job`'s `/queue_job/runjob` route runs a job as superuser, without login, for anyone who knows the job's UUID. Its job runner calls Odoo directly on Odoo's own port (`http_interface`, or `localhost`, and `PORT`), never through the reverse proxy, so the proxy closes the path for everyone else:

- **NGINX:** every Odoo template in `nginx-configurations/` (`nginx_sites_available`, `-with_API`, `-localhost`, `_path_base_routing_nodejs`) answers `404` for `/queue_job/...`, except `/queue_job/static/...` (the module's app icon). The templates are copied by hand, so a site set up before this change needs the same `location ~ ^/queue_job/(?!static/) { return 404; }` block added to its file in `/etc/nginx/sites-available/`, then `sudo nginx -t && sudo systemctl reload nginx`.
- **Traefik:** `setup.sh` adds a router (`odoo-qj-<service>`) that sends those paths, and any path starting with `//`, to a non-existent path, so Odoo answers `404`. Re-run `sudo ./setup.sh` to get it.
- Do not point the job runner at the public domain (`[queue_job] host` or `ODOO_QUEUE_JOB_HOST`); it would be blocked too.
- The proxy only protects traffic that goes through it: with the host network, Odoo listens on `PORT` and `GEVENT_PORT` on every interface, so keep those ports closed to the internet in the firewall.

Tested by `./tests/test_reverse_proxy.sh` (each template in a throwaway nginx on 127.0.0.1, and the generated Traefik labels in Traefik v2 and v3 with `TRAEFIK_V2_BIN` / `TRAEFIK_BIN`), including `%`-encoded, `//` and `/../` variants.

## Snapshot Restore Drill & Automatic Validation

`./scripts/validate-snapshot.sh` performs a non-destructive restore drill on a snapshot inside throwaway Docker containers on an isolated network (never touching production). When `SNAPSHOT_REMOTE_HOST` is set, the drill runs over SSH on the Secondary VPS using rootless Docker; otherwise it runs locally.

### How `validate-snapshot.sh` Works
1. **Fetch & Verify:** Pulls the snapshot from `--inbox`, `--drive`, `--gcs`, or `--file`, checks its `.sha256` sidecar (`checksum`), decompresses/lists the `.tar.zst` (`archive`), and verifies `dump.sql`, `manifest.json`, `git_hashes.json`, and `filestore` (`structure`, `manifest`).
2. **Git & Restore:** Verifies every repository can be checked out at its recorded commit (`git`), restores `dump.sql` into a throwaway PostgreSQL container (`database`), and checks attachment sizes (`filestore`).
3. **Odoo Boot Check (Phase 2):** Unless `--no-boot` (`VALIDATOR_BOOT=false`) or `--no-git-check` is set, checks out `odoo-base` + addons (`code`), pulls or builds the Odoo image (`image`), neutralizes the restored database, and boots Odoo (`workers = 0`, `max_cron_threads = 0`, no outbound network) to verify the registry loads and `/web/login` returns HTTP `200` (`boot`).
4. **Reports & Cloud Publishing (`--publish`):** Writes a JSON report to `~/.odoo-validator/reports/`. When `--publish` is passed and the `git` check passes:
   - **On pass:** Uploads `<archive>.validated.json` next to the snapshot on Google Drive, GCS, and/or local archives (for `--inbox`, it publishes to every cloud destination recorded in `job.json`). Retention then protects that validated snapshot.
   - **On fail:** Removes any existing `<archive>.validated.json` so a broken snapshot is no longer protected.

### Automatic Validation & Worker Cron
Automatic drills are controlled by leaving `VALIDATOR_WORKER` and `SNAPSHOT_VALIDATOR_INBOX` empty in `.env` (resolved via `scripts/lib/drill_defaults.sh`):
- **`VALIDATOR_WORKER=` (empty):** Automatically **on** whenever `ENABLE_SNAPSHOT` is enabled. Running `sudo ./setup.sh` installs `/etc/cron.d/validate-snapshot-<service>`, which runs `scripts/validate-snapshot-worker.sh` every hour at minute `47` with low CPU/I/O priority (`nice -n 19`, `ionice -c2 -n7`).
- **`SNAPSHOT_VALIDATOR_INBOX=` (empty):** Automatically **on** when `SNAPSHOT_REMOTE_HOST` points to a Secondary VPS. After uploading a snapshot, the snapshot tool hands the archive to `~/.odoo-validator/inbox/<service>/` on the Secondary VPS so the worker can drill it without re-downloading it.
- **Due Interval (`VALIDATOR_MIN_INTERVAL_HOURS`, default `24`):** On each hourly tick, the worker checks `~/.odoo-validator/reports/`: it drills immediately if never drilled, waits `VALIDATOR_MIN_INTERVAL_HOURS` after a `pass`/`fail`, or retries after `max(1h, VALIDATOR_MIN_INTERVAL_HOURS / 4)` following an `error`. It checks `--inbox` first, then falls back to Drive/GCS/local archives with `--unless-checksum` so already-proven snapshots are skipped.

### Triggering the Cron / Drill Manually
- **Check worker status (no drill runs):**
  ```bash
  ./scripts/validate-snapshot-worker.sh --status
  ```
- **Run with normal cron rules** (only drills if enabled and due):
  ```bash
  ./scripts/validate-snapshot-worker.sh
  ```
- **Force a drill immediately** (ignores `VALIDATOR_WORKER=false` and the interval, but still skips if the newest snapshot's SHA-256 was already proven):
  ```bash
  ./scripts/validate-snapshot-worker.sh --force
  ```
  To run it in the background with the same priority and log file as cron:
  ```bash
  sudo ionice -c2 -n7 nice -n 19 /usr/local/sbin/validate-snapshot-worker-<service> --force >> /var/log/odoo/_utilities/validate-snapshot-<service>.log 2>&1 &
  ```
- **Re-drill an already-proven snapshot** (bypassing `--unless-checksum`):
  ```bash
  ./scripts/validate-snapshot.sh --drive <service> --publish
  ```

For full technical details, exit codes, and configuration variables, see [scripts/README.md](scripts/README.md).

---

Copyright © 2024 ryumada. All Rights Reserved.

Licensed under the [MIT](LICENSE) license.
