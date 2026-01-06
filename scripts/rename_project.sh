#!/bin/bash
set -e

# --- Logging Functions & Colors ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[0;33m"
readonly COLOR_ERROR="\033[0;31m"

log() {
  local color="$1"
  local emoji="$2"
  local message="$3"
  echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}"
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_warn() { log "${COLOR_WARN}" "⚠️" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }

# --- Check for Root ---
if [ "$(id -u)" -ne 0 ]; then
    log_info "Elevating permissions to root..."
    exec sudo "$0" "$@"
fi

# --- Main Logic ---

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
OLD_SERVICE_NAME="$SERVICE_NAME"
ENV_FILE="$PATH_TO_ODOO/.env"

if [ ! -f "$ENV_FILE" ]; then
    log_error ".env file not found in current directory."
    exit 1
fi

log_info "Current Service Name: $OLD_SERVICE_NAME"

# Identify databases owned by the old user
log_info "Identifying databases owned by '$OLD_SERVICE_NAME'..."
if ! command -v psql &> /dev/null; then
  log_error "psql command not found. Please install postgresql-client."
  exit 1
fi

DATABASES_TO_MIGRATE=()
# Get list of databases owned by the service user
while IFS= read -r dbname; do
  DATABASES_TO_MIGRATE+=("$dbname")
done < <(sudo -u postgres psql -tAc "SELECT datname FROM pg_database WHERE datdba = (SELECT usesysid FROM pg_user WHERE usename = '$OLD_SERVICE_NAME');")

if [ ${#DATABASES_TO_MIGRATE[@]} -eq 0 ]; then
    log_warn "No databases found owned by user '$OLD_SERVICE_NAME'."
else
    log_success "Found ${#DATABASES_TO_MIGRATE[@]} database(s) to migrate: ${DATABASES_TO_MIGRATE[*]}"
fi

# Ask for new Service Name
echo -e "\nPlease enter the NEW Service Name. (e.g., partsindo_16)"
read -rp "New Service Name: " NEW_SERVICE_NAME

if [ -z "$NEW_SERVICE_NAME" ]; then
    log_error "New Service Name cannot be empty."
    exit 1
fi

if [ "$NEW_SERVICE_NAME" == "$OLD_SERVICE_NAME" ]; then
    log_error "New Service Name is the same as the old one."
    exit 1
fi

log_info "Preparing to rename '$OLD_SERVICE_NAME' to '$NEW_SERVICE_NAME'..."
log_warn "This operation will restart services and move directories."
read -rp "Are you sure you want to proceed? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[yY] ]]; then
    log_info "Operation cancelled."
    exit 0
fi

# Create a temporary script to handle the actual move and restart
TEMP_SCRIPT=$(mktemp)
chmod +x "$TEMP_SCRIPT"

cat <<EOF > "$TEMP_SCRIPT"
#!/bin/bash
set -e

# Re-define log functions for the temp script
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[0;33m"
readonly COLOR_ERROR="\033[0;31m"

log() {
  local color="\$1"
  local emoji="\$2"
  local message="\$3"
  echo -e "\${color}[\$(date +"%Y-%m-%d %H:%M:%S")] \${emoji} \${message}\${COLOR_RESET}"
}
log_info() { log "\${COLOR_INFO}" "ℹ️" "\$1"; }
log_success() { log "\${COLOR_SUCCESS}" "✅" "\$1"; }
log_warn() { log "\${COLOR_WARN}" "⚠️" "\$1"; }
log_error() { log "\${COLOR_ERROR}" "❌" "\$1"; }

OLD_DIR="$CURRENT_DIR"
PARENT_DIR="\$(dirname "\$OLD_DIR")"
NEW_DIR="\$PARENT_DIR/$NEW_SERVICE_NAME"

log_info "Stopping containers in \$OLD_DIR..."
cd "\$OLD_DIR" || exit 1
docker compose down || true

log_info "Renaming project directory..."
cd "\$PARENT_DIR"
mv "\$OLD_DIR" "\$NEW_DIR"

log_info "Renaming data directories..."
# Check and rename lib dir
if [ -d "/var/lib/odoo/$OLD_SERVICE_NAME" ]; then
    sudo mv "/var/lib/odoo/$OLD_SERVICE_NAME" "/var/lib/odoo/$NEW_SERVICE_NAME"
    log_success "Renamed /var/lib/odoo/$OLD_SERVICE_NAME to /var/lib/odoo/$NEW_SERVICE_NAME"
else
    log_warn "/var/lib/odoo/$OLD_SERVICE_NAME not found."
fi

# Check and rename log dir
if [ -d "/var/log/odoo/$OLD_SERVICE_NAME" ]; then
    sudo mv "/var/log/odoo/$OLD_SERVICE_NAME" "/var/log/odoo/$NEW_SERVICE_NAME"
    log_success "Renamed /var/log/odoo/$OLD_SERVICE_NAME to /var/log/odoo/$NEW_SERVICE_NAME"
else
    log_warn "/var/log/odoo/$OLD_SERVICE_NAME not found."
fi

log_info "Updating .env file..."
cd "\$NEW_DIR"
sed -i "s|^SERVICE_NAME=.*|SERVICE_NAME=$NEW_SERVICE_NAME|" .env
sed -i "s|/var/log/odoo/$OLD_SERVICE_NAME|/var/log/odoo/$NEW_SERVICE_NAME|g" .env
sed -i "s|/var/lib/odoo/$OLD_SERVICE_NAME|/var/lib/odoo/$NEW_SERVICE_NAME|g" .env

log_info "Running setup.sh to configure new user and permissions..."
sudo ./setup.sh auto

log_info "Transferring database ownership..."
# We use the array passed from the parent script
DATABASES=(${DATABASES_TO_MIGRATE[@]})
NEW_USER="$NEW_SERVICE_NAME"

for DB in "\${DATABASES[@]}"; do
    log_info "Migrating database: \$DB to owner \$NEW_USER"

    # 1. Change Database Owner
    sudo -u postgres psql -c "ALTER DATABASE \"\$DB\" OWNER TO \"\$NEW_USER\";"

    # 2. Change ownership of tables, sequences, and views
    sudo -u postgres psql -d "\$DB" -c "
      DO \\\$\\\$
      DECLARE
          rec RECORD;
      BEGIN
          FOR rec IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
              EXECUTE 'ALTER TABLE ' || quote_ident(rec.tablename) || ' OWNER TO \"\$NEW_USER\"';
          END LOOP;
      END \\\$\\\$;

      DO \\\$\\\$
      DECLARE
          rec RECORD;
      BEGIN
          FOR rec IN (SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema = 'public') LOOP
              EXECUTE 'ALTER SEQUENCE ' || quote_ident(rec.sequence_name) || ' OWNER TO \"\$NEW_USER\"';
          END LOOP;
      END \\\$\\\$;

      DO \\\$\\\$
      DECLARE
          rec RECORD;
      BEGIN
          FOR rec IN (SELECT table_name FROM information_schema.views WHERE table_schema = 'public') LOOP
              EXECUTE 'ALTER VIEW ' || quote_ident(rec.table_name) || ' OWNER TO \"\$NEW_USER\"';
          END LOOP;
      END \\\$\\\$;
    "
    log_success "Database \$DB ownership transferred."
done

log_info "Rebuilding and starting services..."
docker compose up -d --build

log_success "Rename operation completed successfully! New service is running at \$NEW_DIR"

EOF

log_info "Handing over execution to temporary script..."
# Execute the temp script replacing the current process
exec "$TEMP_SCRIPT"
