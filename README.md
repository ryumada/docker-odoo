# Odoo Docker Image
A Dockerfile to create a custom Odoo docker image.

| Specification | Version |
|----|----|
|OS|Ubuntu 22.04 (Linux/Debian)|
|Python|`'3.7'` (recommended) or `'3.10'`|
|Odoo version|`'16'`|
|PostgreSQL|`'14'`|

| Python `'3.10'` has slower build time and not compatible with ks_dashboard.

| ⚠️ You need to read this README.md file thoroughly. ⚠️

There are some points you should know:

- First, you need to execute `sudo ./_RUNMEFIRST.sh` script to check if all of your files and directories are ready to build image.
  ```bash
  sudo ./_RUNMEFIRST.sh
  ```

- Please follow the instruction after you run that script above, before continue the porcess.

- You should add your Odoo base, whether it is Odoo Community, Odoo Enterprise, or your custom Odoo base, to the `odoo-base` directory (⚠️ Only add one directory to `odoo-base` as this will be read automatically by the `entrypoint.sh` script, for the name of the directory is no need to be `odoo` ⚠️).

- Add your custom Odoo Modules (Odoo Addons) to `git` directory and add the path to addons_path in `./conf/odoo.conf`. Don't add unused custom module directory to this directory as it will be added to your docker image and increased the image size.

> ⚠️ If your path is in `./git/odoo-custom-modules`, then your addons_path should be `/opt/odoo/git/odoo-custom-modules`.

> ⚠️ If you have subdirectory inside your git addons repository path it should be like this:
> - `/opt/odoo/git/odoo-custom-modules/subdir-1`
> - `/opt/odoo/git/odoo-custom-modules/subdir-2`

- Odoo `datadir` is placed on `/var/lib/odoo` and Odoo `log` is placed on `/var/log/odoo`. These directories will be used by Odoo for static data storage and logging. It will be called in docker-compose. (⚠️ This directories are automatically created on your host machine after you run `sudo ./_RUNMEFIRST.sh` ⚠️)

- Build your docker image with this command below:

  ```bash
  docker compose build
  ```

  After the build completed, you can copy the image name and enter it in your `docker-compose.yml`.

- Run your odoo deployment with docker compose.

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

- If you want to commit changes of your config, make sure to change the ownership to your user first before create a new commit.
  ```bash
  sudo chown -R $USER: ./
  ```

# Maintenance
The image build using the dockerfile in this repository installed some utility scripts.

## Check the version of Odoo base
You can check the Odoo version and its git hash by running this command:

```bash
docker compose exec $SERVICE_NAME getinfo-odoo_base
```

<details>
  <summary>You can get <code>$SERVICE_NAME</code> by looking at your <code>docker-compose.yml</code> file. </summary>

  ```dockerfile
  ...
  services:
    # Enter the correct the service name, you can use company name (example: sudoerp)
    enter_the_correct_service_name: <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
      # Enter the correct image name below (format: username/repo:tag, example: odoo:16.0)
      image: username/repo:tag
      build:
        context: .
        dockerfile: dockerfile
      # Because we use host ne
  ...
  ```
</details>

## Check the git repository used by Docker Image
You can check the git repository information by running this command:

```bash
docker compose exec $SERVICE_NAME getinfo-odoo_git_addons
```

<details>
  <summary>You can get <code>$SERVICE_NAME</code> by looking at your <code>docker-compose.yml</code> file. </summary>

  ```dockerfile
  ...
  services:
    # Enter the correct the service name, you can use company name (example: sudoerp)
    enter_the_correct_service_name: <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
      # Enter the correct image name below (format: username/repo:tag, example: odoo:16.0)
      image: username/repo:tag
      build:
        context: .
        dockerfile: dockerfile
      # Because we use host ne
  ...
  ```
</details>

---

Copyright © 2024 ryumada. All Rights Reserved.

Licensed under the [MIT](LICENSE) license.
