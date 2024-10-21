# Manage your secrets
Database secrets credentials should be automatically generated after you run the "_install.sh" script. If you want to create the secrets manually, you can follow these two methods below. There are two methods to create the secrets:

<details>
<summary>

## ✅ Automatic - Create a new role and credentials

</summary>

This script below will automatically create a new role on your postgres database and create a new db_user and db_password file. The username taken from your root project directory name. The password generated automatically using `openssl rand` command with 64 character. After the script successfully run, the `clear` command will clear your screen and remove the password from the terminal output history.

```bash
ROOT_DIR=$(git rev-parse --show-toplevel)
SERVICE_NAME=$(basename $ROOT_DIR)

POSTGRES_ODOO_USERNAME=$SERVICE_NAME
POSTGRES_ODOO_PASSWORD=$(openssl rand -base64 64 | tr -d '\n')

sudo -u postgres psql -c "DROP ROLE IF EXISTS \"$POSTGRES_ODOO_USERNAME\";"
sudo -u postgres psql -c "CREATE ROLE \"$POSTGRES_ODOO_USERNAME\" LOGIN CREATEDB PASSWORD '$POSTGRES_ODOO_PASSWORD';"

echo "$POSTGRES_ODOO_USERNAME" > db_user
echo "$POSTGRES_ODOO_PASSWORD" > db_password
```

</details>

<details>
<summary>

## Manual - Add your database credentials by copying the example files

</summary>

1. You need to Create a new role on your postgres database:

    | ⚠️ Change the username and password.

    ```bash
    read -rp "Enter your username: " POSTGRES_ODOO_USERNAME
    read -rp "Enter your password: " POSTGRES_ODOO_PASSWORD

    sudo -u postgres psql -c "CREATE ROLE \"$POSTGRES_ODOO_USERNAME\" LOGIN CREATEDB PASSWORD '$POSTGRES_ODOO_PASSWORD';"
    ```

2. You can add your `db_password` and `db_user` by copying the example files and changing the values in each file based on the database username and password you have set before.

    ```
    cp db_password.example db_password
    ```

    ```
    cp db_user.example db_user
    ```

</details>