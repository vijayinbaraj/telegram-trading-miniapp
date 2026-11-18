
\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS offboarding;

CREATE TABLE IF NOT EXISTS offboarding.archive_info (
    chat_id         text PRIMARY KEY,
    user_id         text NOT NULL,
    source_database text NOT NULL,
    archive_created timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS offboarding.manifest (
    schema_name        text NOT NULL,
    table_name         text NOT NULL,
    table_sql          text NOT NULL,
    columns_sql        text NOT NULL,
    predicate_sql      text NOT NULL,
    source_count       bigint NOT NULL,
    source_fingerprint text NOT NULL,
    archived_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (schema_name, table_name)
);
