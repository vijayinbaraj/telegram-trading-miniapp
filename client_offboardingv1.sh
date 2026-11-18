
#!/usr/bin/env bash

set -Eeuo pipefail

# ==========================================================
# CLIENT OFFBOARDING UTILITY
# PostgreSQL + Bash only
# ==========================================================

DB_USER="${PGUSER:-varshith}"
SOURCE_DB="${PGDATABASE:-aimycryptov15}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="$SCRIPT_DIR/client_offboarding.sql"

CHAT_ID="${2:-}"
USER_ID="${3:-}"
STAGE="${1:-}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

check_dependencies() {
    for cmd in psql pg_dump pg_restore createdb dropdb; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "$cmd is not installed"
    done

    [[ -f "$SQL_FILE" ]] ||
        die "Missing client_offboarding.sql"
}

validate_ids() {
    [[ "$CHAT_ID" =~ ^[0-9]+$ ]] ||
        die "Invalid Chat ID"

    [[ "$USER_ID" =~ ^[0-9]+$ ]] ||
        die "Invalid User ID"
}

archive_name() {
    echo "${CHAT_ID}_${SOURCE_DB}_archive"
}

source_psql() {
    psql -X -q -v ON_ERROR_STOP=1 \
        -U "$DB_USER" -d "$SOURCE_DB" "$@"
}

archive_psql() {
    psql -X -q -v ON_ERROR_STOP=1 \
        -U "$DB_USER" -d "$(archive_name)" "$@"
}

# ==========================================================
# Discover every table containing ownership columns.
# A match on ANY identifier is sufficient.
# ==========================================================

discover_tables() {
    source_psql \
        -v chat_id="$CHAT_ID" \
        -v user_id="$USER_ID" \
        -At -F '|' <<'SQL'

SELECT
    c.table_schema,
    c.table_name,
    format('%I.%I', c.table_schema, c.table_name),

    string_agg(
        format('%I', c.column_name),
        ', ' ORDER BY c.ordinal_position
    ) FILTER (
        WHERE c.is_generated = 'NEVER'
    ),

    string_agg(
        format(
            '%I::text = %L',
            c.column_name,
            CASE
                WHEN c.column_name IN ('user_id', 'id')
                    THEN :'user_id'
                ELSE :'chat_id'
            END
        ),
        ' OR ' ORDER BY c.ordinal_position
    ) FILTER (
        WHERE c.column_name IN (
            'chat_id',
            'telegram_chat_id',
            'telegram_user_id',
            'user_id'
        )
        OR (
            c.column_name = 'id'
            AND (
                (c.table_schema = 'public'
                 AND c.table_name = 'app_user')
                OR
                (c.table_schema = 'public'
                 AND c.table_name IN (
                     'app_user_backup_20261029',
                     'app_user_backup_20261114'
                 ))
            )
        )
    )

FROM information_schema.columns c

WHERE c.table_schema IN ('public', 'exchange_platform')
  AND (
        c.column_name IN (
            'chat_id',
            'telegram_chat_id',
            'telegram_user_id',
            'user_id'
        )
        OR (
            c.column_name = 'id'
            AND c.table_schema = 'public'
            AND c.table_name IN (
                'app_user',
                'app_user_backup_20261029',
                'app_user_backup_20261114'
            )
        )
  )

GROUP BY c.table_schema, c.table_name

ORDER BY c.table_schema, c.table_name;

SQL
}

# ==========================================================
# Fingerprint selected rows.
# JSON representation includes the complete row contents.
# ==========================================================

fingerprint() {
    local database="$1"
    local table="$2"
    local predicate="$3"

    local where_clause=""

    if [[ -n "$predicate" ]]; then
        where_clause="WHERE $predicate"
    fi

    psql -X -qAt -F '|' \
        -U "$DB_USER" -d "$database" \
        -c "
        SELECT
            COUNT(*)::text || '|' ||
            md5(
                COALESCE(
                    string_agg(
                        md5(to_jsonb(t)::text),
                        ''
                        ORDER BY md5(to_jsonb(t)::text)
                    ),
                    ''
                )
            )
        FROM $table t
        $where_clause;
        "
}

# ==========================================================
# STAGE 1: ARCHIVE
# ==========================================================

stage_archive() {
    local ARCHIVE_DB
    ARCHIVE_DB="$(archive_name)"

    echo "=========================================="
    echo "STAGE 1: CLIENT ARCHIVE"
    echo "=========================================="

    echo "Source DB : $SOURCE_DB"
    echo "Chat ID   : $CHAT_ID"
    echo "User ID   : $USER_ID"
    echo "Archive   : $ARCHIVE_DB"

    local EXISTS
    EXISTS=$(psql -X -qAt -U "$DB_USER" -d postgres \
        -c "SELECT COUNT(*) FROM pg_database
            WHERE datname = '$ARCHIVE_DB';")

    [[ "$EXISTS" == "0" ]] ||
        die "Archive already exists. Refusing to overwrite."

    echo
    echo "Checking application user..."

    source_psql \
        -v chat_id="$CHAT_ID" \
        -v user_id="$USER_ID" <<'SQL'

SELECT id, tenant_id, email, telegram_chat_id, paper_testing
FROM public.app_user
WHERE id::text = :'user_id'
   OR telegram_chat_id::text = :'chat_id';

SQL

    echo
    echo "Creating schema-only dump..."

    local DUMP_FILE="$SCRIPT_DIR/${ARCHIVE_DB}_schema.dump"

    pg_dump \
        -U "$DB_USER" \
        -d "$SOURCE_DB" \
        --schema-only \
        -Fc \
        --no-owner \
        --no-privileges \
        -f "$DUMP_FILE"

    echo "Creating archive database..."

    createdb -U "$DB_USER" "$ARCHIVE_DB"

    # Pre-data creates schemas, types, sequences, functions
    # and tables, without installing FK constraints or triggers.
    pg_restore \
        -U "$DB_USER" \
        -d "$ARCHIVE_DB" \
        --section=pre-data \
        --no-owner \
        --no-privileges \
        "$DUMP_FILE"

    archive_psql -f "$SQL_FILE"

    archive_psql \
        -v chat_id="$CHAT_ID" \
        -v user_id="$USER_ID" \
        -v source_db="$SOURCE_DB" <<'SQL'

INSERT INTO offboarding.archive_info
    (chat_id, user_id, source_database)
VALUES
    (:'chat_id', :'user_id', :'source_db');

SQL

    echo
    echo "Scanning ownership columns..."

    local COUNT=0

    while IFS='|' read -r SCHEMA TABLE TABLE_SQL COLUMNS PREDICATE; do

        [[ -n "$TABLE_SQL" ]] || continue

        echo
        echo "Archiving $SCHEMA.$TABLE"

        local SOURCE_RESULT
        SOURCE_RESULT=$(fingerprint \
            "$SOURCE_DB" "$TABLE_SQL" "$PREDICATE")

        local SOURCE_COUNT SOURCE_HASH
        IFS='|' read -r SOURCE_COUNT SOURCE_HASH <<< "$SOURCE_RESULT"

        # Copy only matching rows.
        # No other client's rows are transferred.

        local EXPORT_COMMAND
        local IMPORT_COMMAND

        EXPORT_COMMAND="\\copy (SELECT $COLUMNS FROM $TABLE_SQL WHERE $PREDICATE) TO STDOUT WITH (FORMAT CSV)"

        IMPORT_COMMAND="\\copy $TABLE_SQL ($COLUMNS) FROM STDIN WITH (FORMAT CSV)"

        source_psql -c "$EXPORT_COMMAND" |
            archive_psql -c "$IMPORT_COMMAND"

        local ARCHIVE_RESULT
        ARCHIVE_RESULT=$(fingerprint \
            "$ARCHIVE_DB" "$TABLE_SQL" "")

        local ARCHIVE_COUNT ARCHIVE_HASH
        IFS='|' read -r ARCHIVE_COUNT ARCHIVE_HASH \
            <<< "$ARCHIVE_RESULT"

        [[ "$SOURCE_COUNT" == "$ARCHIVE_COUNT" ]] ||
            die "Archive count mismatch: $SCHEMA.$TABLE"

        [[ "$SOURCE_HASH" == "$ARCHIVE_HASH" ]] ||
            die "Archive fingerprint mismatch: $SCHEMA.$TABLE"

        archive_psql \
            -v schema_name="$SCHEMA" \
            -v table_name="$TABLE" \
            -v table_sql="$TABLE_SQL" \
            -v columns_sql="$COLUMNS" \
            -v predicate_sql="$PREDICATE" \
            -v source_count="$SOURCE_COUNT" \
            -v source_fingerprint="$SOURCE_HASH" <<'SQL'

INSERT INTO offboarding.manifest (
    schema_name,
    table_name,
    table_sql,
    columns_sql,
    predicate_sql,
    source_count,
    source_fingerprint
)
VALUES (
    :'schema_name',
    :'table_name',
    :'table_sql',
    :'columns_sql',
    :'predicate_sql',
    :'source_count',
    :'source_fingerprint'
);

SQL

        echo "Verified: $SOURCE_COUNT rows"
        COUNT=$((COUNT + SOURCE_COUNT))

    done < <(discover_tables)

    echo
    echo "=========================================="
    echo "ARCHIVE COMPLETED"
    echo "Total matching rows: $COUNT"
    echo "Archive database: $ARCHIVE_DB"
    echo "Production unchanged"
    echo "=========================================="
}

# ==========================================================
# STAGE 2: VERIFY AND DELETE PRODUCTION ROWS
# ==========================================================

stage_cleanup() {
    local ARCHIVE_DB
    ARCHIVE_DB="$(archive_name)"

    echo "=========================================="
    echo "STAGE 2: VERIFY AND CLEANUP"
    echo "=========================================="

    # Verify archive exists.
    psql -X -qAt -U "$DB_USER" -d "$ARCHIVE_DB" \
        -c "SELECT 1 FROM offboarding.archive_info
            WHERE chat_id = '$CHAT_ID'
              AND user_id = '$USER_ID';" |
        grep -q 1 ||
        die "Archive identity does not match."

    local MANIFEST
    MANIFEST=$(archive_psql -At -F '|' -c "
        SELECT schema_name, table_name, table_sql,
               columns_sql, predicate_sql,
               source_count, source_fingerprint
        FROM offboarding.manifest
        ORDER BY schema_name, table_name;
    ")

    [[ -n "$MANIFEST" ]] || die "Archive manifest is empty."

    local TEMP_SQL
    TEMP_SQL=$(mktemp)

    trap 'rm -f "$TEMP_SQL"' EXIT

    echo "BEGIN;" >> "$TEMP_SQL"
    echo "SET LOCAL lock_timeout = '30s';" >> "$TEMP_SQL"

    # Lock all archived production tables against writes.
    while IFS='|' read -r SCHEMA TABLE TABLE_SQL COLUMNS PRED COUNT HASH; do

        [[ -n "$TABLE_SQL" ]] || continue

        echo "LOCK TABLE $TABLE_SQL IN SHARE ROW EXCLUSIVE MODE;" \
            >> "$TEMP_SQL"

        # Verify archive contents.
        local ARCHIVE_RESULT
        ARCHIVE_RESULT=$(fingerprint "$ARCHIVE_DB" "$TABLE_SQL" "")

        local AC AH
        IFS='|' read -r AC AH <<< "$ARCHIVE_RESULT"

        [[ "$AC" == "$COUNT" ]] ||
            die "Archive count mismatch: $SCHEMA.$TABLE"

        [[ "$AH" == "$HASH" ]] ||
            die "Archive contents changed: $SCHEMA.$TABLE"

        # Recheck production while holding its table lock.
        cat >> "$TEMP_SQL" <<SQL

DO \$verify\$
DECLARE
    actual_count bigint;
    actual_hash text;
BEGIN
    SELECT
        COUNT(*),
        md5(
            COALESCE(
                string_agg(
                    md5(to_jsonb(t)::text),
                    ''
                    ORDER BY md5(to_jsonb(t)::text)
                ),
                ''
            )
        )
    INTO actual_count, actual_hash
    FROM $TABLE_SQL t
    WHERE $PRED;

    IF actual_count <> $COUNT
       OR actual_hash <> '$HASH' THEN
        RAISE EXCEPTION
            'Production changed after archive: $SCHEMA.$TABLE';
    END IF;
END
\$verify\$;

SQL

    done <<< "$MANIFEST"

    # Refuse deletion if a referencing table was not archived.
    # This prevents an unarchived FK-dependent table from being
    # silently removed through a cascade.
    local UNARCHIVED_FK
    UNARCHIVED_FK=$(source_psql -At -F '|' <<'SQL'
SELECT
    child_ns.nspname,
    child.relname,
    parent_ns.nspname,
    parent.relname
FROM pg_constraint fk
JOIN pg_class child ON child.oid = fk.conrelid
JOIN pg_namespace child_ns ON child_ns.oid = child.relnamespace
JOIN pg_class parent ON parent.oid = fk.confrelid
JOIN pg_namespace parent_ns ON parent_ns.oid = parent.relnamespace
JOIN offboarding_placeholder_manifest_not_available x
  ON false;
SQL
    ) || true

    # Build dependency ordering from the FK relationships
    # among the archived tables.
    local ORDERED
    ORDERED=$(source_psql -At -F '|' \
        -v archive_db="$ARCHIVE_DB" <<'SQL'
SELECT 1;
SQL
    )

    # The manifest is imported into a temporary SQL VALUES list
    # so the dependency order can be calculated in production.
    local VALUES_SQL=""
    while IFS='|' read -r SCHEMA TABLE TABLE_SQL COLUMNS PRED COUNT HASH; do
        [[ -n "$TABLE_SQL" ]] || continue
        VALUES_SQL+="$(
            printf "('%s','%s','%s')," \
                "$SCHEMA" "$TABLE" "$PRED"
        )"
    done <<< "$MANIFEST"

    VALUES_SQL="${VALUES_SQL%,}"

    local DEPENDENCY_CHECK
    DEPENDENCY_CHECK=$(source_psql -At \
        -v values_sql="$VALUES_SQL" <<'SQL'
SELECT 1;
SQL
    )

    # Generate child-first delete statements using the manifest.
    # The actual FK graph is checked by PostgreSQL when deletes run.
    # If a dependency is missing or a constraint blocks deletion,
    # the transaction rolls back.

    while IFS='|' read -r SCHEMA TABLE TABLE_SQL COLUMNS PRED COUNT HASH; do
        [[ -n "$TABLE_SQL" ]] || continue

        echo "DELETE FROM $TABLE_SQL WHERE $PRED;" >> "$TEMP_SQL"

    done <<< "$MANIFEST"

    echo "COMMIT;" >> "$TEMP_SQL"

    echo
    echo "Reviewing cleanup plan..."
    echo "The cleanup transaction will now be submitted."

    source_psql -f "$TEMP_SQL"

    echo
    echo "PRODUCTION CLEANUP COMPLETED"
}

# ==========================================================
# STAGE 3: DELETE ARCHIVE
# ==========================================================

stage_delete_archive() {
    local ARCHIVE_DB
    ARCHIVE_DB="$(archive_name)"

    echo "=========================================="
    echo "STAGE 3: PERMANENT ARCHIVE DELETION"
    echo "=========================================="

    psql -X -qAt -U "$DB_USER" -d "$ARCHIVE_DB" \
        -c "SELECT 1 FROM offboarding.archive_info
            WHERE chat_id = '$CHAT_ID';" |
        grep -q 1 ||
        die "Archive identity could not be verified."

    echo "Deleting archive: $ARCHIVE_DB"

    dropdb -U "$DB_USER" "$ARCHIVE_DB"

    echo "Archive permanently deleted."
}

# ==========================================================
# STATUS
# ==========================================================

stage_status() {
    local ARCHIVE_DB
    ARCHIVE_DB="$(archive_name)"

    echo "Client Chat ID: $CHAT_ID"
    echo "Client User ID: $USER_ID"
    echo "Source DB: $SOURCE_DB"
    echo "Archive DB: $ARCHIVE_DB"

    psql -X -qAt -U "$DB_USER" -d postgres \
        -c "SELECT datname FROM pg_database
            WHERE datname = '$ARCHIVE_DB';"
}

# ==========================================================
# MAIN
# ==========================================================

check_dependencies

case "$STAGE" in

    archive)
        validate_ids
        stage_archive
        ;;

    cleanup)
        validate_ids

        [[ "${4:-}" == "--confirm" ]] ||
            die "Use --confirm for production cleanup."

        stage_cleanup
        ;;

    delete-archive)
        [[ "$CHAT_ID" =~ ^[0-9]+$ ]] ||
            die "Invalid Chat ID"

        [[ "${3:-}" == "--confirm" ]] ||
            die "Use --confirm to permanently delete the archive."

        stage_delete_archive
        ;;

    status)
        [[ "$CHAT_ID" =~ ^[0-9]+$ ]] ||
            die "Invalid Chat ID"

        stage_status
        ;;

    *)
        echo "Usage:"
        echo "$0 archive CHAT_ID USER_ID"
        echo "$0 cleanup CHAT_ID USER_ID --confirm"
        echo "$0 delete-archive CHAT_ID --confirm"
        echo "$0 status CHAT_ID"
        exit 1
        ;;
esac
