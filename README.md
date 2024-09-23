# Odoo Docker Image
A Dockerfile to create a custom Odoo docker image.

| Specification | Version |
|----|----|
|Python|`'3.7'` (recommended) or `'3.10'`|
|Odoo version|`'16'`|
|PostgreSQL|`'14'`|

| Python `'3.10'` has slower build time and not compatible with ks_dashboard.

| ⚠️ You need to read this README.md file thoroughly. ⚠️

There are some points you should know:

- First, you need to execute `sudo ./_RUNMEFIRST.sh` script to check if all of your files and directories are ready to build image.

- Please follow the instruction after you run that script above, before continue the porcess.

- You should add your Odoo base, whether it is Odoo Community, Odoo Enterprise, or your custom Odoo base, to the `odoo-base` directory (⚠️ Only add one directory to `odoo-base` as this will be read automatically by the `entrypoint.sh` script, for the name of the directory is no need to be `odoo` ⚠️).

- Add your custom Odoo Modules (Odoo Addons) to `git` directory and add the path to addons_path in `./conf/odoo.conf`. Don't add unused custom module directory to this as it will be added to your docker image.

- `datadir` and `log` directories will be used by Odoo for static data storage and logging. It will be called in docker-compose.

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
  

- If your Odoo module needs libreoffice you can install it using this command:

  ```bash
  docker exec -itu root $CONTAINER_ID apt --no-install-recommends -y install libreoffice
  ```

  or you can uncomment this `RUN` syntax on dockerfile to include the installation of libreoffice on your docker image.

  ```docker
  ...
  # install libreoffice only be needed if there is a module need to use libreoffice featrue
  # RUN apt --no-install-recommends -y install libreoffice
  ...
  ```

- If you want to commit changes of your config, make sure to change the ownership to your user first before create a new commit.
  ```bash
  sudo chown -R $USER: ./
  ```

---

Copyright © 2024 ryumada. All Rights Reserved.

Licensed under the [MIT](LICENSE) license.
