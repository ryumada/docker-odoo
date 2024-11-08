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

- First, you need to execute `sudo ./_install.sh` script to check if all of your files and directories are ready to build image.
  ```bash
  sudo ./_install.sh
  ```

  > ⚠️ When you are asked to enter whether you want to build or pull container image, choose the `build` option.

- Please follow the instruction after you run that script above, before continue the process below.

- [`Odoo Base`] You should add your Odoo base, whether it is Odoo Community, Odoo Enterprise, or your custom Odoo base, to the `odoo-base` directory (⚠️ Only add one directory to `odoo-base` as this will be read automatically by the `entrypoint.sh` script, for the name of the directory is no need to be `odoo` ⚠️).

- [`Extra Addons/Modules`] Add your custom Odoo Modules (Odoo Addons) to `git` directory and add the path to addons_path in `./conf/odoo.conf`. Don't add unused custom module directory to this directory as it will be added to your docker image and increased the image size.

  > ⚠️ If your path is in `./git/odoo-custom-modules`, then your addons_path should be `/opt/odoo/git/odoo-custom-modules`.

  > ⚠️ If you have subdirectory inside your git addons repository path it should be like this:
  > - `/opt/odoo/git/odoo-custom-modules/subdir-1`
  > - `/opt/odoo/git/odoo-custom-modules/subdir-2`

- [`Odoo Static Data`] Odoo `datadir` is placed on `/var/lib/odoo` and Odoo `log` is placed on `/var/log/odoo`. These directories will be used by Odoo for static data storage and logging. It will be called in docker-compose (⚠️ These directories are automatically created on your host machine after you run `sudo ./_install.sh` ⚠️).

- `Build and Run` your odoo deployment with docker compose.

  Build your Image using this command:

  ```bash
  docker compose build
  ```

  Run your Container Image using this command:

  ```bash
  docker compose up
  ```

  You can also run detach the docker compose stdout with this command:

  ```bash
  docker compose up -d
  ```

  Or you can up the container and build the image

  ```bash
  docker compose up -d --build
  ```

- If your Odoo module needs libreoffice you can install it using this command:

  ```bash
  docker exec -itu root $CONTAINER_ID apt --no-install-recommends -y install libreoffice
  ```

  or you can uncomment this `RUN` syntax on dockerfile to include the installation of libreoffice on your docker image.

  ```dockerfile
  ...
  # install libreoffice only be needed if there is a module need to use libreoffice featrue
  # RUN apt --no-install-recommends -y install libreoffice
  ...
  ```

- Setup your container registry.
  <details>
  <summary>Setup your Docker container registry.</summary>
    
    > ⚠️ To use Github and Gitlab Container Registry, you need to generate a personal access token (PAT) and use it as a password.
    
    1. Login to Github Container Registry (ghcr.io) using your Github account.

        ```bash
        # if using Github (ghcr.io)
        ## using parameter
        docker login ghcr.io -u your_github_username -p enter_your_personal_access_token
        ## or just login then enter your username and password
        docker login ghcr.io

        # if using Gitlab (registry.gitlab.com)
        ## using parameter
        docker login registry.gitlab.com -u your_gitlab_username -p enter_your_personal_access_token
        ## or just login and then enter your username and password
        docker login registry.gitlab.com

        # if using Docker Hub
        docker login
        ```

  </details>
  <details>
    <summary>Push your Docker container registry.</summary>

    1. Tag your image with the Github Container Registry (ghcr.io) repository. First, you need to edit `docker-compose.yml` file to add the image name and tag.

        ```yaml
        ...
        # push the image to Container registry (enter and choose one)
        ## Use the image from the GitHub Container Registry
        # image: ghcr.io/enter_username/enter_project_name:enter_version
        ## Use the image from the Docker Hub
        # image: enter_username/enter_project_name:enter_version
        ## Use the image from the Gitlab Container Registry
        # image: registry.gitlab.com/enter_username/enter_project_name:enter_version  
        ...
        ```

        > ⚠️ For Github Container Registry (ghcr.io). You need to add labels to the build section on your `docker-compose.yml` file.
        > ```yaml
        > ...
        > # Add labels to connect to github repository (enter github)
        > # labels:
        >   # - org.opencontainers.image.source=https://github.com/enter_username/enter_repository
        > ...
        > ```

    2. Build and push your image to the container registry.

        ```bash
        docker compose up --build -d
        docker compose push
        ```

  </details>

  <details>
    <summary>Pull image from container registry</summary>

    > ⚠️ Before you pull the image from the container registry, make sure the image name is set on your docker compose file.
    
    > ⚠️ You also need to run the `sudo ./_install.sh`. When the script asks you to enter whether you want to build or pull container image, choose the `pull` option.

    1. Make sure the image name is set on your docker compose file.

        ```yaml
        ...
        # push the image to Container registry (enter and choose one)
        ## Use the image from the GitHub Container Registry
        # image: ghcr.io/enter_username/enter_project_name:enter_version
        ## Use the image from the Docker Hub
        # image: enter_username/enter_project_name:enter_version
        ## Use the image from the Gitlab Container Registry
        # image: registry.gitlab.com/enter_username/enter_project_name:enter_version  
        ...
        ```

    2. Pull the image from the container registry.

        ```bash
        docker compose up -d --pull
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
Odoo shell has been created automatically after you run `sudo ./_install.sh` script. The shell is copied when the image is built. You can run the Odoo shell by running this command:

```bash
# See help to see how to use the shell
docker compose exec $SERVICE_NAME odoo-shell help

# example command to run shell with service_name odoo
docker compose exec odoo odoo-shell example_database_name

# example command to update odoo modules
## update single module
docker compose exec odoo odoo-shell example_database_name --update=module_name
## update multiple modules
docker compose exec odoo odoo-shell example_database_name --update=module_name1,module_name2
## update all modules (⚠️ This command is not recommended to use in production ⚠️)
docker compose exec odoo odoo-shell example_database_name --update=all
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
