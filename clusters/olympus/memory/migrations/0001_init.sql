-- 0001_init: extension, schema and the migration ledger. Nothing else.
-- The episode/fact/fact_embedding/capture_queue/import_ledger/client tables are NOT
-- created here: their columns depend on the capture contract (olympus-sdk#452) and
-- the gateway (#450), which add their own numbered migrations.
-- Idempotent: safe to re-run against a database where it was already applied.
CREATE EXTENSION IF NOT EXISTS vector;

CREATE SCHEMA IF NOT EXISTS memory;

CREATE TABLE IF NOT EXISTS memory.schema_migrations (
    version     text        PRIMARY KEY,
    name        text        NOT NULL,
    checksum    text        NOT NULL,
    applied_at  timestamptz NOT NULL DEFAULT now()
);
