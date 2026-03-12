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

## Run VSCode on container
If you setup this variable in .env:

```env
...
# # # # # # # # # # # # # # # #
# VSCODE ON Container         #
# # # # # # # # # # # # # # # #
# Set the direct download URL of vscode for debian to install vscode inside your odoo container
# possible values
VSCODE_DIRECT_DOWNLOAD_URL=
...
```

Then, vscode will be installed inside the container when you build the image. Here how to activate vscode from your container:

```bash
# This will open the vscode web on http://localhost:8000
docker compose exec $SERVICE_NAME code serve-web

# You can change the port of vscode if port 8000 is already in use
docker compose exec $SERVICE_NAME code serve-web --port

# See help of code cli
docker compose exec $SERVICE_NAME code serve-web --help
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
```

3. Ensure you have properly bound your Traefik proxy network so the containers can communicate locally.
```env
# Point this to your Traefik web network name
DOCKER_NETWORK_MODE=proxy
```
4. Simply run `sudo ./setup.sh`!
5. The `docker-compose.yml` file is immediately generated with fully baked isolation routing for `odoo.yourdomain.com` targeting both Standard HTTP traffic and `PathPrefix(\`/websocket\`)` longpolling traffic concurrently!

---

Copyright © 2024 ryumada. All Rights Reserved.

Licensed under the [MIT](LICENSE) license.
