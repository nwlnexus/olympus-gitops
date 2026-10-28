-- 0007_knowledge: the curated wiki (nwlnexus/second-brain, wiki/**/*.md) indexed by section, for the read-only
-- `knowledge` tool and the wiki hits of session start (olympus-sdk#563; harness spec H7b, H7c).
-- Contract: olympus-sdk docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md §15.
-- Memory and knowledge stay distinct: nothing here references memory.fact, and only the knowledge indexer
-- (CronJob memory-knowledge-indexer, role memory_worker) writes this table. The gateway only reads it.
-- 0005 and 0006 are reserved for the Postgres graph (§3.6); the runner applies files in lexical order and skips
-- versions already in memory.schema_migrations, so a later 0005/0006 still applies.
-- Idempotent; no BEGIN/COMMIT (the runner wraps it with --single-transaction).

-- One row per section of a wiki page. A section is the text under one heading (levels 1 to 3); `heading` is the
-- breadcrumb of the headings above it joined with ' > ' (unique within a page; the indexer suffixes duplicates
-- and the parts of an over-long section with ' (2)', ' (3)', ...). `commit` is the second-brain commit the row was
-- last indexed from; after a run every row carries the run's commit, and rows of any other commit (sections or
-- pages that no longer exist) are deleted in the same transaction. `aliases` is the page's frontmatter aliases,
-- one per line (newline-separated). `text_sha256` lets the indexer reuse an embedding when the text is unchanged.
CREATE TABLE IF NOT EXISTS memory.knowledge_page (
    path         text        NOT NULL CHECK (path LIKE 'wiki/%.md' AND length(path) <= 512),
    heading      text        NOT NULL CHECK (length(heading) BETWEEN 1 AND 512),
    commit       text        NOT NULL CHECK (commit ~ '^[0-9a-f]{40}$'),
    ord          integer     NOT NULL CHECK (ord >= 0),
    title        text        NOT NULL CHECK (length(title) BETWEEN 1 AND 300),
    aliases      text        NOT NULL DEFAULT '' CHECK (length(aliases) <= 2000),
    text         text        NOT NULL CHECK (length(text) <= 8000),
    text_sha256  bytea       NOT NULL,
    embedding    vector(768),
    embed_model  text,
    tsv          tsvector    GENERATED ALWAYS AS (
                     setweight(to_tsvector('english'::regconfig, title || ' ' || aliases), 'A')
                     || setweight(to_tsvector('english'::regconfig, heading), 'B')
                     || setweight(to_tsvector('english'::regconfig, text), 'C')) STORED,
    indexed_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (path, heading)
);

CREATE INDEX IF NOT EXISTS knowledge_page_tsv_idx ON memory.knowledge_page USING gin (tsv);
-- No vector index: the wiki is a few hundred sections, an exact scan is faster than HNSW at that size.

GRANT SELECT ON memory.knowledge_page TO memory_gateway;
GRANT SELECT, INSERT, UPDATE, DELETE ON memory.knowledge_page TO memory_worker;
