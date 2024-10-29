This directory contains utilities to help docker-odoo deployment.

<details>
<summary>

# Backup Data

</summary>

This utilities will backup Odoo database and its datadir into a zip file. This zip file can be restored using Odoo Database Manager.

See the example file to create the data backup utility (`./scripts/example/backupdata.sh.example`).

  1. Copy the example file. This will export the service name from your cloned respository dirname.
      ```bash
      export SERVICE_NAME=$(basename "$PWD")
      cp ./scripts/example/backupdata.sh.example ./scripts/backupdata-$SERVICE_NAME
      ```

  2. Edit your example file with your favorite text-editor (`vim` or `nano`, etc)
      ```bash
      vi ./scripts/backupdata-$SERVICE_NAME
      ```

  3. You need to find (`ctrl + f`) the `enter` word to see which value should be changed

  4. Save the file and change the permission.
      ```bash
      sudo chmod 755 ./scripts/backupdata-$SERVICE_NAME
      ```

  5. Create a soft-link to system-wide bin
      ```bash
      sudo ln -s $PWD/scripts/backupdata-$SERVICE_NAME /usr/local/sbin/backupdata-$SERVICE_NAME
      ```

  6. Done, you can try to run the command.
      ```bash
      backupdata-$SERVICE_NAME
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
      cp ./scripts/example/databasecloner.sh.example ./scripts/databasecloner-$SERVICE_NAME
      ```

  2. Edit your example file with your favorite text-editor (`vim` or `nano`, etc)
      ```bash
      vi ./scripts/databasecloner-$SERVICE_NAME
      ```

  3. You need to find (`ctrl + f`) the `enter` word to see which value should be changed

  4. Save the file and change the permission.
      ```bash
      sudo chmod 755 ./scripts/databasecloner-$SERVICE_NAME
      ```
  
  5. Create a soft-link to system-wide bin
      ```bash
      sudo ln -s $PWD/scripts/databasecloner-$SERVICE_NAME /usr/local/sbin/databasecloner-$SERVICE_NAME
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

</details>

<details>
  <summary>

  # Snapshot Utilities

  </summary>

  See the example file to create the snapshot utility (`./scripts/example/snapshot.sh.example`).

  1. Copy the example file. This will export the service name from your cloned repository dirname.
      ```bash
      export SERVICE_NAME=$(basename "$PWD")
      cp ./scripts/example/snapshot.sh.example ./scripts/snapshot-$SERVICE_NAME
      ```

  2. Edit your example file with your favorite text-editor (`vim` or `nano`, etc)
      ```bash
      vi ./scripts/snapshot-$SERVICE_NAME
      ```

  3. You need to find (`ctrl + f`) the `enter` word to see which value should be changed

  4. Save the file and change the permission.
      ```bash
      sudo chmod 755 ./scripts/snapshot-$SERVICE_NAME
      ```

  5. Create a soft-link to system-wide bin
      ```bash
      sudo ln -s $PWD/scripts/snapshot-$SERVICE_NAME /usr/local/sbin/snapshot-$SERVICE_NAME
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
      sudo chown root: /etc/cron.d/snapshot-$SERVICE_NAME
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

      sudo chown root: ~/snapshot-$SERVICE_NAME
      sudo chmod 644 ~/snapshot-$SERVICE_NAME
      sudo mv ~/snapshot-$SERVICE_NAME /etc/logrotate.d/snapshot-$SERVICE_NAME
      ```

  8. You can setup Google Cloud Storage for automatic rotate snapshot file or use `logrotate` on Ubuntu.

</details>
