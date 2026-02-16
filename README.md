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
|OS|Ubuntu 22.04 (Linux/Debian)|
|Python|`'3.7'` (recommended) or `'3.10'`|
|Odoo version|`'16' (tested)`|
|PostgreSQL|`'14' (tested)`|

| Python `'3.10'` has slower build time and not compatible with ks_dashboard.

| ⚠️ You need to read this README.md file thoroughly. ⚠️

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
  - `ODOO_IMAGE_VERSION`: Image tag (e.g., `16.0-v1`).
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
    2. Set `ODOO_IMAGE_NAME`, `ODOO_IMAGE_VERSION`, and `ODOO_IMAGE_SOURCE` in `.env`.
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

---

Copyright © 2024 ryumada. All Rights Reserved.

Licensed under the [MIT](LICENSE) license.
