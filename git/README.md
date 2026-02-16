---
title: Git Addons Guide
category: Guide
description: Instructions for managing custom Odoo addons via git.
context: Addons
maintainer: ryumada
---

# Clone your custom git addons and add other extra addons to this directory.

Add your custom Odoo Modules (Odoo Addons) to `git` directory and add the path to `addons_path` in `../conf/odoo.conf`. Don't add unused custom module directory to this directory as it will be added to your docker image and increased the image size.

> ⚠️ If your path is in `./git/odoo-custom-modules`, then your `addons_path` should be `/opt/odoo/git/odoo-custom-modules`.

> ⚠️ If you have subdirectory inside your git addons repository path it should be like this:
> - `/opt/odoo/git/odoo-custom-modules/subdir-1`
> - `/opt/odoo/git/odoo-custom-modules/subdir-2`

> ⚠️ Don't forget to back up your custom module directory that doesn't use git by setting it up in the snapshot utility for your deployment.
