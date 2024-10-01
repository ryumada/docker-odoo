# Manage your secrets
Create a role on your postgres database:

| ⚠️ Change the username and password.

```bash
sudo -u postgres psql -c "CREATE ROLE \"enter_your_user_name\" LOGIN CREATEDB PASSWORD 'enter_your_password'"
```

You can add your `db_password` and `db_user` by copying the example files and changing the values in each file based on the database username and password you have set before.

```
cp db_password.example db_password
```

```
cp db_user.example db_user
```
