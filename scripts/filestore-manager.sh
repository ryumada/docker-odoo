#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Analyzes, audits, lists, and safely prunes Odoo filestore attachments and orphans.
# Usage: ./scripts/filestore-manager.sh [summary|list|clean-orphans|clean-assets|clean-missing] [OPTIONS]
# Dependencies: psql, docker, find, comm, sort, awk, sudo

# Detect Repository Owner to run non-root commands as that user
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR" 2>/dev/null || echo "$USER")
PATH_TO_ODOO=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$CURRENT_DIR")
SERVICE_NAME=$(basename "$PATH_TO_ODOO")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ODOO" 2>/dev/null || echo "$USER")

# --- Logging Functions & Colors ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[0;31m"

log() {
  local color="$1"
  local emoji="$2"
  local message="$3"
  echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}"
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_warn() { log "${COLOR_WARN}" "⚠️ " "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }

function usage() {
  cat <<EOF
Usage: ./scripts/filestore-manager.sh <COMMAND> [OPTIONS]

Commands:
  summary          Show storage breakdown by category, top models, and excludable savings
  list             List attachments with ownership, model, size, and category
  clean-orphans    Delete physical disk files that have no matching record in ir_attachment
  clean-assets     Purge cached web assets from DB and disk (Odoo regenerates automatically)
  clean-missing    Purge ir_attachment records whose physical files are missing on disk

Options:
  -d, --db NAME             Target database name (default: DB_NAME from .env)
  --category CATS           Filter by category (comma-separated: chatter,field,record,asset,standalone,orphan)
  --model MODEL             Filter list by res_model (e.g. sale.order, product.template)
  --sort [size|date]        Sort order for list (default: size)
  --limit N                 Limit results in list (0 for all)
  --csv FILE                Export list output to CSV file
  --dry-run                 Simulate cleanup without making any changes
  -y, --yes                 Skip interactive confirmation prompts
  -h, --help                Show this help message

Examples:
  ./scripts/filestore-manager.sh summary
  ./scripts/filestore-manager.sh list --category chatter --limit 20
  ./scripts/filestore-manager.sh list --csv /tmp/attachments.csv
  ./scripts/filestore-manager.sh clean-orphans --dry-run
  ./scripts/filestore-manager.sh clean-orphans -y
  ./scripts/filestore-manager.sh clean-assets
  ./scripts/filestore-manager.sh clean-missing --category chatter -y
EOF
  exit 0
}

# Allow help without sudo
if [ "$1" = "-h" ] || [ "$1" = "--help" ] || [ "$1" = "help" ] || [ -z "$1" ]; then
  usage
fi

# Self-elevate to root if not already (required for /var/lib/odoo filestore access and sudo -u postgres)
if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

function run_psql() {
  local env_file="${PSQL_ENV_FILE:-$PATH_TO_ODOO/.env}"
  local db_host=""
  if [ -f "$env_file" ]; then
    db_host=$(grep "^DB_HOST=" "$env_file" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
  fi

  local has_db=false
  for arg in "$@"; do
    if [[ "$arg" == "-d" || "$arg" == -d* || "$arg" == "--dbname="* || "$arg" == "--dbname" ]]; then
      has_db=true
      break
    fi
  done
  local db_default=()
  if [ "$has_db" = false ]; then
    db_default=(-d postgres)
  fi

  if [ -n "$db_host" ] && [ "$db_host" != "localhost" ]; then
    local db_port=$(grep "^DB_PORT=" "$env_file" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
    local db_user=$(grep "^ACTIVE_DB_USER=" "$env_file" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
    [ -z "$db_user" ] && db_user=$(cat "$(dirname "$env_file")/.secrets/db_user" 2>/dev/null || true)
    local db_pass=$(cat "$(dirname "$env_file")/.secrets/db_password" 2>/dev/null || true)
    local docker_net=$(grep "^DOCKER_NETWORK_MODE=" "$env_file" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
    [ -z "$db_port" ] && db_port="5432"
    [ -z "$docker_net" ] && docker_net="host"
    local net=$(echo "$docker_net" | cut -d "," -f 1)
    PGPASSWORD="$db_pass" docker run -i --rm --network="$net" -e PGPASSWORD postgres psql -h "$db_host" -p "$db_port" -U "$db_user" "${db_default[@]}" "$@"
  else
    sudo -u postgres psql "${db_default[@]}" "$@"
  fi
}

function format_bytes() {
  local bytes=${1:-0}
  numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || awk -v b="$bytes" 'BEGIN {
    split("B KB MB GB TB PB", units);
    i = 1;
    while (b >= 1024 && i < 6) { b /= 1024; i++; }
    printf "%.1f %s", b, units[i];
  }'
}

function get_database_name() {
  local db="$1"
  if [ -z "$db" ] && [ -f "$PATH_TO_ODOO/.env" ]; then
    db=$(grep "^DB_NAME=" "$PATH_TO_ODOO/.env" | cut -d "=" -f 2 | sed 's/^[[:space:]\n]*//g' | sed 's/[[:space:]\n]*$//g' || true)
  fi
  if [ -z "$db" ]; then
    log_error "Database name not found. Provide via -d <DB_NAME> or define DB_NAME in .env"
    exit 1
  fi
  echo "$db"
}

function has_chatter_table() {
  local db="$1"
  local count
  count=$(run_psql -d "$db" -t -A -c "SELECT count(*) FROM information_schema.tables WHERE table_name = 'message_attachment_rel';" 2>/dev/null || echo "0")
  [ "$count" = "1" ]
}

function build_classification_cte() {
  local db="$1"
  if has_chatter_table "$db"; then
    cat <<'EOF'
WITH chatter_ids AS (
  SELECT DISTINCT attachment_id FROM message_attachment_rel
),
classified AS (
  SELECT
    id,
    name,
    res_model,
    res_id,
    res_field,
    store_fname,
    COALESCE(file_size, 0)::bigint AS file_size,
    mimetype,
    create_date,
    CASE
      WHEN id IN (SELECT attachment_id FROM chatter_ids) THEN 'chatter'
      WHEN res_model = 'ir.ui.view' AND (url LIKE '/web/assets/%' OR name LIKE '%.assets_%') THEN 'asset'
      WHEN res_field IS NOT NULL AND res_field != '' THEN 'field'
      WHEN res_model IS NOT NULL AND res_model != '' THEN 'record'
      ELSE 'standalone'
    END AS category
  FROM ir_attachment
  WHERE store_fname IS NOT NULL
)
EOF
  else
    cat <<'EOF'
WITH classified AS (
  SELECT
    id,
    name,
    res_model,
    res_id,
    res_field,
    store_fname,
    COALESCE(file_size, 0)::bigint AS file_size,
    mimetype,
    create_date,
    CASE
      WHEN res_model = 'mail.message' THEN 'chatter'
      WHEN res_model = 'ir.ui.view' AND (url LIKE '/web/assets/%' OR name LIKE '%.assets_%') THEN 'asset'
      WHEN res_field IS NOT NULL AND res_field != '' THEN 'field'
      WHEN res_model IS NOT NULL AND res_model != '' THEN 'record'
      ELSE 'standalone'
    END AS category
  FROM ir_attachment
  WHERE store_fname IS NOT NULL
)
EOF
  fi
}

function cmd_summary() {
  local db="$1"
  local filestore_path="/var/lib/odoo/$SERVICE_NAME/filestore/$db"

  log_info "Analyzing filestore for database '$db'..."

  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' EXIT

  # Disk stats
  local disk_count=0
  local disk_bytes=0
  if [ -d "$filestore_path" ]; then
    disk_count=$(find "$filestore_path" -type f 2>/dev/null | wc -l || echo "0")
    disk_bytes=$(du -sb "$filestore_path" 2>/dev/null | cut -f1 || echo "0")
    find "$filestore_path" -type f -printf '%P\t%s\n' 2>/dev/null | sort -k1,1 > "$tmp_dir/disk_files.tsv" || true
  else
    touch "$tmp_dir/disk_files.tsv"
  fi

  cut -f1 "$tmp_dir/disk_files.tsv" > "$tmp_dir/disk_paths.txt"

  # Query DB store_fnames
  run_psql -d "$db" -t -A -c "SELECT DISTINCT store_fname FROM ir_attachment WHERE store_fname IS NOT NULL ORDER BY store_fname;" 2>/dev/null > "$tmp_dir/db_paths.txt" || true

  # Orphans on disk
  comm -23 "$tmp_dir/disk_paths.txt" "$tmp_dir/db_paths.txt" > "$tmp_dir/orphan_paths.txt" || true
  local orphan_count
  orphan_count=$(wc -l < "$tmp_dir/orphan_paths.txt")
  local orphan_bytes=0
  if [ "$orphan_count" -gt 0 ]; then
    orphan_bytes=$(join -t $'\t' -1 1 -2 1 "$tmp_dir/orphan_paths.txt" "$tmp_dir/disk_files.tsv" 2>/dev/null | awk -F'\t' '{s+=$2} END {print s+0}')
  fi

  # Query category stats
  local cte
  cte=$(build_classification_cte "$db")

  local cat_sql="
$cte
SELECT
  category,
  count(*)::text,
  count(DISTINCT store_fname)::text,
  COALESCE(sum(file_size), 0)::text
FROM classified
GROUP BY category
ORDER BY sum(file_size) DESC;
"

  local cat_results
  cat_results=$(run_psql -d "$db" -t -A -F $'\t' -c "$cat_sql" 2>/dev/null || true)

  # Query excludable size with dedup safety (chatter + assets only, if NOT referenced by any kept category)
  local dedup_sql="
$cte,
excludable_fnames AS (
  SELECT store_fname
  FROM classified
  GROUP BY store_fname
  HAVING bool_and(category IN ('chatter', 'asset'))
)
SELECT
  count(DISTINCT store_fname)::text,
  COALESCE(sum(file_size), 0)::text
FROM (
  SELECT DISTINCT ON (store_fname) store_fname, file_size
  FROM classified
  WHERE store_fname IN (SELECT store_fname FROM excludable_fnames)
) sub;
"
  local dedup_results
  dedup_results=$(run_psql -d "$db" -t -A -F $'\t' -c "$dedup_sql" 2>/dev/null || echo "0"$'\t'"0")
  local excludable_count=$(echo "$dedup_results" | cut -f1)
  local excludable_bytes=$(echo "$dedup_results" | cut -f2)

  # Query top models
  local model_sql="
$cte
SELECT
  res_model,
  category,
  count(*)::text,
  COALESCE(sum(file_size), 0)::text
FROM classified
WHERE res_model IS NOT NULL AND res_model != ''
GROUP BY res_model, category
ORDER BY sum(file_size) DESC
LIMIT 10;
"
  local model_results
  model_results=$(run_psql -d "$db" -t -A -F $'\t' -c "$model_sql" 2>/dev/null || true)

  echo ""
  echo "=========================================================================="
  echo " Filestore Summary: $SERVICE_NAME ($db)"
  echo "=========================================================================="
  printf "%-14s %-12s %-14s %-12s\n" "Category" "Rows" "Unique Files" "Logical Size"
  echo "--------------------------------------------------------------------------"
  while IFS=$'\t' read -r cat rows uniq size; do
    [ -z "$cat" ] && continue
    printf "%-14s %'-12d %'-14d %-12s\n" "$cat" "$rows" "$uniq" "$(format_bytes "$size")"
  done <<< "$cat_results"

  printf "%-14s %-12s %'-14d %-12s (disk only)\n" "orphan" "-" "$orphan_count" "$(format_bytes "$orphan_bytes")"
  echo "--------------------------------------------------------------------------"
  printf "Total on disk: %'d files, %s\n" "$disk_count" "$(format_bytes "$disk_bytes")"
  echo ""
  printf "Excludable with --exclude-chatter --exclude-assets (dedup-safe):\n"
  printf "  %'d unique files (~%s)\n" "$excludable_count" "$(format_bytes "$excludable_bytes")"
  echo ""
  echo "Top Models by Attachment Size:"
  printf "%-28s %-12s %-10s %-12s\n" "res_model" "Category" "Rows" "Size"
  echo "--------------------------------------------------------------------------"
  while IFS=$'\t' read -r mdl cat rows size; do
    [ -z "$mdl" ] && continue
    printf "%-28s %-12s %'-10d %-12s\n" "$mdl" "$cat" "$rows" "$(format_bytes "$size")"
  done <<< "$model_results"
  echo "=========================================================================="
  echo ""
}

function cmd_list() {
  local db="$1"
  local category_filter="$2"
  local model_filter="$3"
  local sort_mode="${4:-size}"
  local limit_num="${5:-0}"
  local csv_output="$6"

  local filestore_path="/var/lib/odoo/$SERVICE_NAME/filestore/$db"
  local cte
  cte=$(build_classification_cte "$db")

  local where_clauses=()
  if [ -n "$category_filter" ]; then
    local cat_in=""
    IFS=',' read -ra CATS <<< "$category_filter"
    for c in "${CATS[@]}"; do
      c=$(echo "$c" | xargs)
      [ -n "$c" ] && cat_in="${cat_in:+$cat_in, }'$c'"
    done
    [ -n "$cat_in" ] && where_clauses+=("category IN ($cat_in)")
  fi

  if [ -n "$model_filter" ]; then
    where_clauses+=("res_model = '$model_filter'")
  fi

  local where_sql=""
  if [ ${#where_clauses[@]} -gt 0 ]; then
    local joined
    joined=$(printf " AND %s" "${where_clauses[@]}")
    where_sql="WHERE ${joined:5}"
  fi

  local order_sql="ORDER BY file_size DESC"
  if [ "$sort_mode" = "date" ]; then
    order_sql="ORDER BY create_date DESC"
  fi

  local limit_sql=""
  if [ "$limit_num" -gt 0 ]; then
    limit_sql="LIMIT $limit_num"
  fi

  local list_sql="
$cte
SELECT
  store_fname,
  file_size::text,
  category,
  COALESCE(res_model, ''),
  COALESCE(res_id::text, ''),
  COALESCE(res_field, ''),
  REPLACE(REPLACE(COALESCE(name, ''), E'\t', ' '), E'\n', ' '),
  COALESCE(create_date::text, '')
FROM classified
$where_sql
$order_sql
$limit_sql;
"

  local out_stream
  out_stream=$(run_psql -d "$db" -t -A -F $'\t' -c "$list_sql" 2>/dev/null || true)

  if [ -n "$csv_output" ]; then
    {
      echo "store_fname,file_size,category,res_model,res_id,res_field,name,create_date"
      while IFS=$'\t' read -r sf sz cat mdl rid rfd nm cd; do
        [ -z "$sf" ] && continue
        # Escape quotes in name
        nm=$(echo "$nm" | sed 's/"/""/g')
        echo "\"$sf\",$sz,\"$cat\",\"$mdl\",\"$rid\",\"$rfd\",\"$nm\",\"$cd\""
      done <<< "$out_stream"
    } > "$csv_output"
    log_success "Exported attachment list to: $csv_output"
    return 0
  fi

  printf "%-32s %-10s %-10s %-22s %-8s %-16s %-25s\n" "store_fname" "Size" "Category" "res_model" "res_id" "res_field" "Name"
  echo "------------------------------------------------------------------------------------------------------------------------"
  while IFS=$'\t' read -r sf sz cat mdl rid rfd nm cd; do
    [ -z "$sf" ] && continue
    local short_name="${nm:0:24}"
    local short_fname="${sf:0:31}"
    printf "%-32s %-10s %-10s %-22s %-8s %-16s %-25s\n" "$short_fname" "$(format_bytes "$sz")" "$cat" "${mdl:0:21}" "$rid" "${rfd:0:15}" "$short_name"
  done <<< "$out_stream"
}

function cmd_clean_orphans() {
  local db="$1"
  local dry_run="$2"
  local auto_yes="$3"

  local filestore_path="/var/lib/odoo/$SERVICE_NAME/filestore/$db"
  if [ ! -d "$filestore_path" ]; then
    log_warn "Filestore directory not found at: $filestore_path"
    return 0
  fi

  log_info "Scanning for orphaned files in $filestore_path..."

  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' EXIT

  find "$filestore_path" -type f -printf '%P\t%s\n' 2>/dev/null | sort -k1,1 > "$tmp_dir/disk_files.tsv"
  cut -f1 "$tmp_dir/disk_files.tsv" > "$tmp_dir/disk_paths.txt"

  run_psql -d "$db" -t -A -c "SELECT DISTINCT store_fname FROM ir_attachment WHERE store_fname IS NOT NULL ORDER BY store_fname;" 2>/dev/null > "$tmp_dir/db_paths.txt"

  comm -23 "$tmp_dir/disk_paths.txt" "$tmp_dir/db_paths.txt" > "$tmp_dir/orphan_paths.txt"

  local orphan_count
  orphan_count=$(wc -l < "$tmp_dir/orphan_paths.txt")

  if [ "$orphan_count" -eq 0 ]; then
    log_success "No orphaned files found. Filestore is clean."
    return 0
  fi

  local orphan_bytes
  orphan_bytes=$(join -t $'\t' -1 1 -2 1 "$tmp_dir/orphan_paths.txt" "$tmp_dir/disk_files.tsv" 2>/dev/null | awk -F'\t' '{s+=$2} END {print s+0}')

  log_info "Found $orphan_count orphaned files taking $(format_bytes "$orphan_bytes")."

  if [ "$dry_run" = true ]; then
    log_info "[DRY-RUN] No files were deleted."
    return 0
  fi

  if [ "$auto_yes" != true ]; then
    echo -n "Are you sure you want to delete $orphan_count orphaned files ($(format_bytes "$orphan_bytes"))? [y/N]: "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      log_warn "Aborted by user."
      return 0
    fi
  fi

  log_info "Deleting $orphan_count orphaned files..."
  (cd "$filestore_path" && xargs -r rm -f < "$tmp_dir/orphan_paths.txt")
  find "$filestore_path" -mindepth 1 -type d -empty -delete 2>/dev/null || true

  log_success "Deleted $orphan_count orphaned files. Reclaimed $(format_bytes "$orphan_bytes")."
}

function cmd_clean_assets() {
  local db="$1"
  local dry_run="$2"
  local auto_yes="$3"

  log_info "Scanning for cached web assets in database '$db'..."

  local asset_sql="
SELECT count(*)::text || E'\t' || COALESCE(sum(file_size), 0)::text
FROM ir_attachment
WHERE res_model = 'ir.ui.view' AND (url LIKE '/web/assets/%' OR name LIKE '%.assets_%');
"
  local res
  res=$(run_psql -d "$db" -t -A -c "$asset_sql" 2>/dev/null || echo "0"$'\t'"0")
  local asset_count=$(echo "$res" | cut -f1)
  local asset_bytes=$(echo "$res" | cut -f2)

  if [ "$asset_count" -eq 0 ]; then
    log_success "No cached web assets found in database."
    return 0
  fi

  log_info "Found $asset_count cached web assets ($(format_bytes "$asset_bytes")). Odoo will automatically regenerate them on demand."

  if [ "$dry_run" = true ]; then
    log_info "[DRY-RUN] No records were deleted."
    return 0
  fi

  if [ "$auto_yes" != true ]; then
    echo -n "Delete $asset_count web asset records from database '$db'? [y/N]: "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      log_warn "Aborted by user."
      return 0
    fi
  fi

  log_info "Deleting web asset records from ir_attachment..."
  run_psql -d "$db" -c "DELETE FROM ir_attachment WHERE res_model = 'ir.ui.view' AND (url LIKE '/web/assets/%' OR name LIKE '%.assets_%');" >/dev/null

  log_success "Deleted $asset_count web asset records. Now pruning orphaned physical files..."
  cmd_clean_orphans "$db" false true
}

function cmd_clean_missing() {
  local db="$1"
  local category_filter="${2:-chatter}"
  local dry_run="$3"
  local auto_yes="$4"

  local filestore_path="/var/lib/odoo/$SERVICE_NAME/filestore/$db"
  if [ ! -d "$filestore_path" ]; then
    log_error "Filestore directory not found at: $filestore_path"
    exit 1
  fi

  log_info "Scanning database '$db' for missing files (category: $category_filter)..."

  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' EXIT

  find "$filestore_path" -type f -printf '%P\n' 2>/dev/null | sort -u > "$tmp_dir/disk_paths.txt"

  local cte
  cte=$(build_classification_cte "$db")
  local cat_where=""
  if [ "$category_filter" != "all" ]; then
    cat_where="WHERE category = '$category_filter'"
  fi

  local sql="
$cte
SELECT id::text || E'\t' || store_fname
FROM classified
$cat_where;
"
  run_psql -d "$db" -t -A -F $'\t' -c "$sql" 2>/dev/null > "$tmp_dir/db_records.tsv"

  # Find records whose store_fname is NOT in disk_paths.txt
  awk -F'\t' 'NR==FNR {disk[$1]=1; next} !($2 in disk) {print $1}' "$tmp_dir/disk_paths.txt" "$tmp_dir/db_records.tsv" > "$tmp_dir/missing_ids.txt"

  local missing_count
  missing_count=$(wc -l < "$tmp_dir/missing_ids.txt")

  if [ "$missing_count" -eq 0 ]; then
    log_success "No missing attachment records found. Database matches filestore."
    return 0
  fi

  log_warn "Found $missing_count ir_attachment records whose files are missing on disk (category: $category_filter)."

  if [ "$dry_run" = true ]; then
    log_info "[DRY-RUN] No records were deleted."
    return 0
  fi

  if [ "$auto_yes" != true ]; then
    echo -n "Delete $missing_count broken ir_attachment records from database '$db'? [y/N]: "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      log_warn "Aborted by user."
      return 0
    fi
  fi

  log_info "Deleting broken records from ir_attachment..."
  # Delete in batches of 5000
  local batch=()
  local deleted=0
  while read -r id; do
    [ -z "$id" ] && continue
    batch+=("$id")
    if [ "${#batch[@]}" -ge 5000 ]; then
      local id_list
      id_list=$(IFS=,; echo "${batch[*]}")
      run_psql -d "$db" -c "DELETE FROM ir_attachment WHERE id IN ($id_list);" >/dev/null
      deleted=$((deleted + ${#batch[@]}))
      batch=()
    fi
  done < "$tmp_dir/missing_ids.txt"

  if [ "${#batch[@]}" -gt 0 ]; then
    local id_list
    id_list=$(IFS=,; echo "${batch[*]}")
    run_psql -d "$db" -c "DELETE FROM ir_attachment WHERE id IN ($id_list);" >/dev/null
    deleted=$((deleted + ${#batch[@]}))
  fi

  log_success "Successfully deleted $deleted broken ir_attachment records."
}

# --- CLI Argument Parsing ---
COMMAND="${1:-}"
[ -z "$COMMAND" ] && usage
shift || true

DB_ARG=""
CATEGORY_ARG=""
MODEL_ARG=""
SORT_ARG="size"
LIMIT_ARG=0
CSV_ARG=""
DRY_RUN=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--db)
      DB_ARG="$2"
      shift 2
      ;;
    --category)
      CATEGORY_ARG="$2"
      shift 2
      ;;
    --model)
      MODEL_ARG="$2"
      shift 2
      ;;
    --sort)
      SORT_ARG="$2"
      shift 2
      ;;
    --limit)
      LIMIT_ARG="$2"
      shift 2
      ;;
    --csv)
      CSV_ARG="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -y|--yes)
      AUTO_YES=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      log_error "Unknown option: $1"
      usage
      ;;
  esac
done

TARGET_DB=$(get_database_name "$DB_ARG")

case "$COMMAND" in
  summary)
    cmd_summary "$TARGET_DB"
    ;;
  list)
    cmd_list "$TARGET_DB" "$CATEGORY_ARG" "$MODEL_ARG" "$SORT_ARG" "$LIMIT_ARG" "$CSV_ARG"
    ;;
  clean-orphans)
    cmd_clean_orphans "$TARGET_DB" "$DRY_RUN" "$AUTO_YES"
    ;;
  clean-assets)
    cmd_clean_assets "$TARGET_DB" "$DRY_RUN" "$AUTO_YES"
    ;;
  clean-missing)
    cmd_clean_missing "$TARGET_DB" "${CATEGORY_ARG:-chatter}" "$DRY_RUN" "$AUTO_YES"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    log_error "Unknown command: $COMMAND"
    usage
    ;;
esac
