---
name: docker-odoo-management
description: Comprehensive knowledge and utilities for managing the docker-odoo repository, including setup, deployment, and maintenance workflows.
---

# Docker-Odoo Management Skill

This skill provides the necessary context and instructions for managing the Odoo Docker environment in this repository. Use this knowledge to assist the user with deployment, configuration, and troubleshooting tasks.

## Repository Overview

This toolkit allows for the deployment and management of Odoo instances using Docker. Use the `setup.sh` script to configure the environment's mode:

1.  **Development Mode**:
    -   Builds locally.
    -   Uses bind-mounts for `odoo-base` (core code) and `git` (custom addons).
    -   Ideal for coding and debugging.
    -   **Action**: Modify files in `odoo-base/` or `git/` and restart the container to see changes.

2.  **Builder Mode**:
    -   Builds images for distribution.
    -   Tags images with version numbers.
    -   Pushes to container registries.
    -   **Action**: Use this mode in CI/CD pipelines.

3.  **Production Mode**:
    -   Pulls pre-built images.
    -   No bind-mounts for code (improves security and consistency).
    -   **Action**: Use for stable deployments.

## Core Infrastructure

### 1. The Setup Script (`setup.sh`)
Always check if `setup.sh` needs to be run or if the environment is already configured. This script:
-   Generates `docker-compose.yml` and `dockerfile`.
-   Creates `.secrets/` with database credentials.
-   Sets up log rotation in `/etc/logrotate.d/`.

**Command**: `sudo ./setup.sh`

### 2. Directory Structure
-   `scripts/`: Contains executable scripts for maintenance.
    -   **Note**: Scripts in `scripts/example/` are templates. Copy them to `scripts/` (removing `.example`) and customize them before use.
-   `utilities/`: Scripts mounted/copied into the container (e.g., `odoo-shell`).
-   `conf/`: Configuration files like `odoo.conf`.
-   `odoo-base/`: The Odoo core source code.
-   `git/`: Custom Odoo modules/addons.

## Critical Workflows

### 1. Deployment and Updates
To deploy changes or update modules, use the `deploy_release_candidate.sh` script.
-   **Function**: Pulls latest images (Prod), restarts services, and upgrades specified modules.
-   **Usage**: `./scripts/deploy_release_candidate.sh <database_name> --update=<module_list>`

### 2. Database Management
-   **Cloning**: Use `scripts/databasecloner.sh` to copy a database from one environment to another (e.g., Prod -> Dev).
    -   *Caution*: This script often sanitizes the database (disables emails/crons) to prevent accidental spam from non-prod environments.
-   **Backups**: Use `scripts/backupdata.sh`.
-   **Restoring**: Use `scripts/restore_backupdata.sh`.

### 3. Database Restoration Scripts
The following scripts utilize the database restoration method and will automatically generate a database name (using a sequential prefix) if one is not provided:
-   `scripts/databasecloner_manual.sh`
-   `scripts/databasecloner.sh`
-   `scripts/deploy_release_candidate.sh`
-   `scripts/deploy_release_candidate_manual.sh`
-   `scripts/restore_backupdata.sh`
-   `scripts/restore_backupdata_manual.sh`

### 3. Debugging
-   **Odoo Shell**:
    ```bash
    docker compose exec odoo odoo-module-upgrade <database_name>
    ```
-   **Logs**:
    Check `/var/log/odoo/<service_name>/` for Odoo server logs.

## Best Practices
-   **Secrets**: Never hardcode passwords. Use the `.secrets/` directory.
-   **Configuration**: Make changes to `odoo.conf` in the `conf/` directory, then restart the container.
-   **Testing**: When adding new modules, verify them in Development mode first before building a production image.
