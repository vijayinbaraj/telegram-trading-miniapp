#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# CLIENT OFFBOARDING UTILITY
# PostgreSQL + Bash only
#
# Stage 1: create a client-only logical archive.
# Stage 2: verify archive + source, then delete transactionally.
# Stage 3: separately confirmed permanent archive deletion.
#
# IMPORTANT: Pause this client's writers/workers before Stage 1
# and keep them paused through Stage 2.
# ==========================================================

DB_USER="${PGUSER:-varshith}"
SOURCE_DB="${PGDATABASE:-aimycryptov15}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="$SCRIPT_DIR/client_offboarding.sql"

STAGE="${1:-}"
CHAT_ID="${2:-}"
USER_ID="${3:-}"

TMP_FILES=()
PGPASS_TEMP=""
ARCHIVE_CREATED=0
ARCHIVE_DB=""

cleanup_tmp() {
    local f
    for f in "${TMP_FILES[@]:-}"; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f"
    done
    if [[ -n "$PGPASS_TEMP" && -f "$PGPASS_TEMP" ]]; then
        rm -f "$PGPASS_TEMP"
    fi
}

on_error() {
    local rc=$?
    if [[ "$ARCHIVE_CREATED" == "1" && -n "$ARCHIVE_DB" ]]; then
        echo "ERROR: Stage 1 failed. Removing the incomplete archive database created by this run: $ARCHIVE_DB" >&2
        dropdb -U "$DB_USER" --if-exists "$ARCHIVE_DB" >/dev/null 2>&1 || true
    fi
    cleanup_tmp
    exit "$rc"
}
trap on_error ERR
trap cleanup_tmp EXIT

die() {
    echo "ERROR: $*" >&2
    exit 1
}

check_dependencies() {
    local cmd
    for cmd in psql pg_dump pg_restore createdb dropdb; do
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not installed"
    done
    [[ -f "$SQL_FILE" ]] || die "Missing companion SQL file: $SQL_FILE"
}

validate_ids() {
    [[ "$CHAT_ID" =~ ^[0-9]+$ ]] || die "Invalid Chat ID"
    [[ "$USER_ID" =~ ^[0-9]+$ ]] || die "Invalid User ID"
}

archive_name() {
    printf '%s_%s_archive' "$CHAT_ID" "$SOURCE_DB"
}

source_psql() {
    psql -X -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$SOURCE_DB" "$@"
}

archive_psql() {
    psql -X -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$(archive_name)" "$@"
}

# SQL-literal quote for values obtained from our own database metadata.
sql_literal() {
    local value="$1"
    value=${value//\'/\'\'}
    printf "'%s'" "$value"
}

# Discover base tables with at least one recognised client ownership key.
# A match on ANY recognised identifier is sufficient (OR semantics).
discover_tables() {
    source_psql -v chat_id="$CHAT_ID" -v user_id="$USER_ID" -At -F '|' <<'SQL'
SELECT
    c.table_schema,
    c.table_name,
    format('%I.%I', c.table_schema, c.table_name),
    string_agg(format('%I', c.column_name), ', ' ORDER BY c.ordinal_position)
        FILTER (WHERE c.is_generated = 'NEVER'),
    string_agg(
        format('%I::text = %L', c.column_name,
            CASE WHEN c.column_name IN ('user_id', 'id') THEN :'user_id' ELSE :'chat_id' END),
        ' OR ' ORDER BY c.ordinal_position
    ) FILTER (
        WHERE c.column_name IN ('chat_id', 'telegram_chat_id', 'telegram_user_id', 'user_id')
           OR (c.column_name = 'id' AND c.table_schema = 'public'
               AND c.table_name IN ('app_user', 'app_user_backup_20261029', 'app_user_backup_20261114'))
    )
FROM information_schema.columns c
JOIN information_schema.tables t
  ON t.table_schema = c.table_schema AND t.table_name = c.table_name
WHERE c.table_schema IN ('public', 'exchange_platform')
  AND t.table_type = 'BASE TABLE'
  AND (
      c.column_name IN ('chat_id', 'telegram_chat_id', 'telegram_user_id', 'user_id')
      OR (c.column_name = 'id' AND c.table_schema = 'public'
          AND c.table_name IN ('app_user', 'app_user_backup_20261029', 'app_user_backup_20261114'))
  )
GROUP BY c.table_schema, c.table_name
ORDER BY c.table_schema, c.table_name;
SQL
}

# Fingerprint all matching rows in source, or all rows in an archive table.
# The hash includes the complete JSON representation of every selected row.
fingerprint() {
    local database="$1" table="$2" predicate="${3:-}" where_clause=""
    [[ -n "$predicate" ]] && where_clause="WHERE $predicate"
    psql -X -qAt -F '|' -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$database" -c "
        SELECT COUNT(*)::text || '|' ||
               md5(COALESCE(string_agg(md5(to_jsonb(t)::text), '' ORDER BY md5(to_jsonb(t)::text)), ''))
        FROM $table t $where_clause;
    "
}

stage_archive() {
    ARCHIVE_DB="$(archive_name)"
    echo "=========================================="
    echo "STAGE 1: CLIENT ARCHIVE"
    echo "=========================================="
    echo "Source DB : $SOURCE_DB"
    echo "Chat ID   : $CHAT_ID"
    echo "User ID   : $USER_ID"
    echo "Archive   : $ARCHIVE_DB"

    local exists
    exists=$(psql -X -qAt -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
        -v archive_db="$ARCHIVE_DB" <<'SQL'
SELECT COUNT(*) FROM pg_database WHERE datname = :'archive_db';
SQL
    )
    [[ "$exists" == "0" ]] || die "Archive already exists; refusing to overwrite: $ARCHIVE_DB"

    echo
    echo "Checking application user..."
    source_psql -v chat_id="$CHAT_ID" -v user_id="$USER_ID" <<'SQL'
SELECT id, tenant_id, email, telegram_chat_id, paper_testing
FROM public.app_user
WHERE id::text = :'user_id' OR telegram_chat_id::text = :'chat_id';
SQL

    echo
    echo "Creating schema-only dump (excluding offboarding metadata)..."
    local dump_file
    dump_file=$(mktemp "${TMPDIR:-/tmp}/${ARCHIVE_DB}_schema.XXXXXX.dump")
    TMP_FILES+=("$dump_file")
    pg_dump -U "$DB_USER" -d "$SOURCE_DB" \
        --schema-only --exclude-schema=offboarding -Fc \
        --no-owner --no-privileges -f "$dump_file"

    echo "Creating archive database..."
    createdb -U "$DB_USER" "$ARCHIVE_DB"
    ARCHIVE_CREATED=1

    # Pre-data creates the schemas, types, sequences, functions and tables.
    # Constraints, indexes and triggers are intentionally not installed in
    # this row archive; see the limitation note after the script.
    pg_restore -U "$DB_USER" -d "$ARCHIVE_DB" --section=pre-data \
        --no-owner --no-privileges "$dump_file"

    # Create archive metadata in the archive database, not by dumping the
    # source offboarding schema.
    archive_psql -f "$SQL_FILE"
    archive_psql -v chat_id="$CHAT_ID" -v user_id="$USER_ID" -v source_db="$SOURCE_DB" <<'SQL'
INSERT INTO offboarding.archive_info (chat_id, user_id, source_database)
VALUES (:'chat_id', :'user_id', :'source_db');
SQL

    echo
    echo "Scanning ownership columns and archiving matching rows..."
    local total=0
    while IFS='|' read -r schema table table_sql columns predicate; do
        [[ -n "$table_sql" ]] || continue
        echo "Archiving $schema.$table"

        local source_result source_count source_hash
        source_result=$(fingerprint "$SOURCE_DB" "$table_sql" "$predicate")
        IFS='|' read -r source_count source_hash <<< "$source_result"

        local export_command import_command
        export_command="\\copy (SELECT $columns FROM $table_sql WHERE $predicate) TO STDOUT WITH (FORMAT CSV)"
        import_command="\\copy $table_sql ($columns) FROM STDIN WITH (FORMAT CSV)"
        source_psql -c "$export_command" | archive_psql -c "$import_command"

        local archive_result archive_count archive_hash
        archive_result=$(fingerprint "$ARCHIVE_DB" "$table_sql" "")
        IFS='|' read -r archive_count archive_hash <<< "$archive_result"
        [[ "$source_count" == "$archive_count" ]] || die "Archive count mismatch: $schema.$table"
        [[ "$source_hash" == "$archive_hash" ]] || die "Archive fingerprint mismatch: $schema.$table"

        archive_psql -v schema_name="$schema" -v table_name="$table" \
            -v table_sql="$table_sql" -v columns_sql="$columns" \
            -v predicate_sql="$predicate" -v source_count="$source_count" \
            -v source_fingerprint="$source_hash" <<'SQL'
INSERT INTO offboarding.manifest (
    schema_name, table_name, table_sql, columns_sql,
    predicate_sql, source_count, source_fingerprint
) VALUES (
    :'schema_name', :'table_name', :'table_sql', :'columns_sql',
    :'predicate_sql', :'source_count', :'source_fingerprint'
);
SQL
        echo "Verified: $source_count rows"
        total=$((total + source_count))
    done < <(discover_tables)

    rm -f "$dump_file"
    ARCHIVE_CREATED=0
    echo
    echo "=========================================="
    echo "ARCHIVE COMPLETED"
    echo "Total matching rows: $total"
    echo "Archive database: $ARCHIVE_DB"
    echo "Production unchanged"
    echo "=========================================="
}

stage_cleanup() {
    ARCHIVE_DB="$(archive_name)"
    echo "=========================================="
    echo "STAGE 2: VERIFY AND CLEANUP"
    echo "=========================================="

    # Fail clearly if the archive database is absent.
    local db_exists
    db_exists=$(psql -X -qAt -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
        -v archive_db="$ARCHIVE_DB" <<'SQL'
SELECT COUNT(*) FROM pg_database WHERE datname = :'archive_db';
SQL
    )
    [[ "$db_exists" == "1" ]] || die "Archive database does not exist: $ARCHIVE_DB. Run Stage 1 first."

    archive_psql -v chat_id="$CHAT_ID" -v user_id="$USER_ID" <<'SQL'
SELECT 1
FROM offboarding.archive_info
WHERE chat_id::text = :'chat_id' AND user_id::text = :'user_id';
SQL

    local identity
    identity=$(archive_psql -qAt -v chat_id="$CHAT_ID" -v user_id="$USER_ID" <<'SQL'
SELECT COUNT(*)
FROM offboarding.archive_info
WHERE chat_id::text = :'chat_id'
  AND user_id::text = :'user_id';
SQL
    )
    [[ "$identity" == "1" ]] || die "Archive identity does not match."

    local manifest
    manifest=$(archive_psql -At -F '|' -c "
        SELECT schema_name, table_name, table_sql, columns_sql, predicate_sql,
               source_count, source_fingerprint
        FROM offboarding.manifest ORDER BY schema_name, table_name;")
    [[ -n "$manifest" ]] || die "Archive manifest is empty."

    # Independently verify the archived rows against the manifest before
    # considering any production deletion.
    while IFS='|' read -r schema table table_sql columns predicate count hash; do
        [[ -n "$table_sql" ]] || continue
        local archive_result archive_count archive_hash
        archive_result=$(fingerprint "$ARCHIVE_DB" "$table_sql" "")
        IFS='|' read -r archive_count archive_hash <<< "$archive_result"
        [[ "$archive_count" == "$count" ]] || die "Archive row-count verification failed: $schema.$table"
        [[ "$archive_hash" == "$hash" ]] || die "Archive content verification failed: $schema.$table"
    done <<< "$manifest"

    local tx_file
    tx_file=$(mktemp "${TMPDIR:-/tmp}/offboarding_cleanup.XXXXXX.sql")
    TMP_FILES+=("$tx_file")

    cat > "$tx_file" <<'SQL'
BEGIN;
SET LOCAL lock_timeout = '30s';
SET LOCAL statement_timeout = '0';
CREATE TEMP TABLE offboarding_manifest (
    schema_name text NOT NULL,
    table_name text NOT NULL,
    predicate_sql text NOT NULL,
    expected_count bigint NOT NULL,
    expected_fingerprint text NOT NULL,
    PRIMARY KEY (schema_name, table_name)
) ON COMMIT DROP;
SQL

    # Import the manifest as safely quoted SQL literals.
    while IFS='|' read -r schema table table_sql columns predicate count hash; do
        [[ -n "$table_sql" ]] || continue
        printf 'INSERT INTO offboarding_manifest VALUES (%s,%s,%s,%s,%s);\n' \
            "$(sql_literal "$schema")" "$(sql_literal "$table")" \
            "$(sql_literal "$predicate")" "$(sql_literal "$count")" \
            "$(sql_literal "$hash")" >> "$tx_file"

        # Lock each table before checking it. SHARE ROW EXCLUSIVE blocks
        # concurrent inserts/updates/deletes while allowing ordinary reads.
        printf 'LOCK TABLE %s IN SHARE ROW EXCLUSIVE MODE;\n' "$table_sql" >> "$tx_file"
    done <<< "$manifest"

    cat >> "$tx_file" <<'SQL'

DO $offboarding_checks$
DECLARE
    r record;
    actual_count bigint;
    actual_hash text;
    unarchived_child text;
BEGIN
    -- Verify every source table still contains exactly the archived rows.
    FOR r IN SELECT * FROM offboarding_manifest ORDER BY schema_name, table_name LOOP
        EXECUTE format(
            'SELECT count(*), md5(coalesce(string_agg(md5(to_jsonb(t)::text), '''' ORDER BY md5(to_jsonb(t)::text)), '''')) FROM %I.%I t WHERE %s',
            r.schema_name, r.table_name, r.predicate_sql
        ) INTO actual_count, actual_hash;
        IF actual_count <> r.expected_count OR actual_hash <> r.expected_fingerprint THEN
            RAISE EXCEPTION 'Production data changed after archive: %.%', r.schema_name, r.table_name;
        END IF;
    END LOOP;

    -- Conservatively refuse if any FK child of a table being deleted is not
    -- itself in the archive manifest. This avoids cascading deletion of
    -- rows that were not archived. This can block cleanup even when the
    -- unarchived child currently has no rows; that is intentional.
    SELECT format('%I.%I references %I.%I', child_ns.nspname, child.relname,
                  parent_ns.nspname, parent.relname)
      INTO unarchived_child
    FROM pg_constraint fk
    JOIN pg_class child ON child.oid = fk.conrelid
    JOIN pg_namespace child_ns ON child_ns.oid = child.relnamespace
    JOIN pg_class parent ON parent.oid = fk.confrelid
    JOIN pg_namespace parent_ns ON parent_ns.oid = parent.relnamespace
    JOIN offboarding_manifest pm
      ON pm.schema_name = parent_ns.nspname AND pm.table_name = parent.relname
    LEFT JOIN offboarding_manifest cm
      ON cm.schema_name = child_ns.nspname AND cm.table_name = child.relname
    WHERE fk.contype = 'f' AND cm.table_name IS NULL
    LIMIT 1;
    IF unarchived_child IS NOT NULL THEN
        RAISE EXCEPTION 'Cleanup refused: unarchived FK child table: %', unarchived_child;
    END IF;

    -- Delete child tables before their parents. A table is eligible when
    -- no remaining manifest table has an FK pointing to it. Cycles are
    -- rejected rather than guessed around.
    LOOP
        SELECT m.schema_name, m.table_name, m.predicate_sql
          INTO r
        FROM offboarding_manifest m
        WHERE NOT EXISTS (
            SELECT 1
            FROM pg_constraint fk
            JOIN pg_class child ON child.oid = fk.conrelid
            JOIN pg_namespace child_ns ON child_ns.oid = child.relnamespace
            JOIN offboarding_manifest child_m
              ON child_m.schema_name = child_ns.nspname
             AND child_m.table_name = child.relname
            JOIN pg_class parent ON parent.oid = fk.confrelid
            JOIN pg_namespace parent_ns ON parent_ns.oid = parent.relnamespace
            WHERE fk.contype = 'f'
              AND parent_ns.nspname = m.schema_name
              AND parent.relname = m.table_name
              AND NOT (child_ns.nspname = m.schema_name AND child.relname = m.table_name)
        )
        ORDER BY m.schema_name, m.table_name
        LIMIT 1;

        EXIT WHEN NOT FOUND;
        EXECUTE format('DELETE FROM %I.%I WHERE %s', r.schema_name, r.table_name, r.predicate_sql);
        DELETE FROM offboarding_manifest
        WHERE schema_name = r.schema_name AND table_name = r.table_name;
    END LOOP;

    IF EXISTS (SELECT 1 FROM offboarding_manifest) THEN
        RAISE EXCEPTION 'Cleanup refused: foreign-key dependency cycle detected among archived tables.';
    END IF;
END
$offboarding_checks$;
COMMIT;
SQL

    echo "Verifying archive fingerprints and foreign-key dependencies, then running one transaction..."
    source_psql -f "$tx_file"
    echo
    echo "PRODUCTION CLEANUP COMPLETED"
    echo "Archive retained: $ARCHIVE_DB"
}

stage_delete_archive() {
    ARCHIVE_DB="$(archive_name)"
    echo "=========================================="
    echo "STAGE 3: PERMANENT ARCHIVE DELETION"
    echo "=========================================="
    local db_exists identity
    db_exists=$(psql -X -qAt -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
        -v archive_db="$ARCHIVE_DB" <<'SQL'
SELECT COUNT(*) FROM pg_database WHERE datname = :'archive_db';
SQL
    )
    [[ "$db_exists" == "1" ]] || die "Archive database does not exist: $ARCHIVE_DB"
    identity=$(archive_psql -qAt -v chat_id="$CHAT_ID" <<'SQL'
SELECT COUNT(*)
FROM offboarding.archive_info
WHERE chat_id::text = :'chat_id';
SQL
    )
    [[ "$identity" == "1" ]] || die "Archive identity could not be verified."
    echo "Deleting archive: $ARCHIVE_DB"
    dropdb -U "$DB_USER" "$ARCHIVE_DB"
    echo "Archive permanently deleted."
}

stage_status() {
    ARCHIVE_DB="$(archive_name)"
    echo "Client Chat ID: $CHAT_ID"
    echo "Client User ID: ${USER_ID:-not supplied}"
    echo "Source DB: $SOURCE_DB"
    echo "Archive DB: $ARCHIVE_DB"
    local exists
    exists=$(psql -X -qAt -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
        -v archive_db="$ARCHIVE_DB" <<'SQL'
SELECT COUNT(*) FROM pg_database WHERE datname = :'archive_db';
SQL
    )
    if [[ "$exists" == "1" ]]; then
        echo "Archive status: EXISTS"
        archive_psql -c "SELECT * FROM offboarding.archive_info; SELECT schema_name, table_name, source_count FROM offboarding.manifest ORDER BY schema_name, table_name;"
    else
        echo "Archive status: NOT FOUND"
    fi
}

# When invoked as the PostgreSQL OS account with PGUSER=postgres and
# PGPASSFILE=/dev/null, local peer authentication is used and no DB password
# is required. Otherwise prompt once and use a private temporary pgpass file.
setup_pgpass() {
    if [[ -n "${PGPASSWORD:-}" || -n "${PGPASSFILE:-}" ]]; then
        return
    fi

    local password escaped
    read -r -s -p "PostgreSQL password for user ${DB_USER}: " password
    printf '\n'
    [[ -n "$password" ]] || die "Empty PostgreSQL password was supplied."

    escaped=${password//\/\\}
    escaped=${escaped//:/\:}
    PGPASS_TEMP=$(mktemp "${TMPDIR:-/tmp}/client_offboarding_pgpass.XXXXXX")
    chmod 600 "$PGPASS_TEMP"
    printf '*:*:*:%s:%s\n' "$DB_USER" "$escaped" > "$PGPASS_TEMP"
    unset password escaped
    export PGPASSFILE="$PGPASS_TEMP"
}

check_dependencies
setup_pgpass
case "$STAGE" in
    archive)
        validate_ids
        stage_archive
        ;;
    cleanup)
        validate_ids
        [[ "${4:-}" == "--confirm" ]] || die "Use --confirm for production cleanup."
        stage_cleanup
        ;;
    delete-archive)
        [[ "$CHAT_ID" =~ ^[0-9]+$ ]] || die "Invalid Chat ID"
        [[ "${3:-}" == "--confirm" ]] || die "Use --confirm to permanently delete the archive."
        stage_delete_archive
        ;;
    status)
        [[ "$CHAT_ID" =~ ^[0-9]+$ ]] || die "Invalid Chat ID"
        stage_status
        ;;
    *)
        echo "Usage:"
        echo "  $0 archive CHAT_ID USER_ID"
        echo "  $0 cleanup CHAT_ID USER_ID --confirm"
        echo "  $0 delete-archive CHAT_ID --confirm"
        echo "  $0 status CHAT_ID [USER_ID]"
        exit 1
        ;;
esac
