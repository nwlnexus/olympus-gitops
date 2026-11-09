-- 0016_knowledge_source: a second knowledge source, the generated code pages (nwlnexus/olympus-knowledge,
-- repos/<repo>/pages/*.md), next to the curated wiki in memory.knowledge_page (olympus-sdk#853; code knowledge layer
-- spec 2026-11-08-code-knowledge-layer-design.md sections 5 and 6).
-- Contract: olympus-sdk docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md §15.8.
-- Idempotent; no BEGIN/COMMIT (the runner wraps it with --single-transaction). Existing rows are wiki rows and take
-- the column default, so nothing is rewritten by hand. ADD COLUMN with a constant default does not rewrite the table
-- (Postgres 11+); the CHECK swap scans the table once (a few thousand rows). lock_timeout bounds the wait for the
-- table lock (the runner's Job retries). No grant changes: the table is the same, and the table-level grants of 0007
-- cover the new column (gateway SELECT; indexer SELECT, INSERT, UPDATE, DELETE).

SET LOCAL lock_timeout = '10s';

-- Which source a row was indexed from. The indexer scopes every read, write and delete by it, so a wiki run never
-- touches code rows and a code run never touches wiki rows.
ALTER TABLE memory.knowledge_page ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'wiki';

-- 0007 allowed only wiki paths (CHECK knowledge_page_path_check). Replace it with one CHECK that ties the source to
-- the path prefix: a wiki row lives under wiki/, a code row under repos/<repo>/pages/. The length limit is kept.
ALTER TABLE memory.knowledge_page DROP CONSTRAINT IF EXISTS knowledge_page_path_check;
ALTER TABLE memory.knowledge_page DROP CONSTRAINT IF EXISTS knowledge_page_source_path_check;
ALTER TABLE memory.knowledge_page ADD CONSTRAINT knowledge_page_source_path_check CHECK (
    length(path) <= 512
    AND ((source = 'wiki' AND path LIKE 'wiki/%.md')
         OR (source = 'code' AND path LIKE 'repos/%/pages/%.md')));
