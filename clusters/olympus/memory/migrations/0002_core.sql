-- 0002_core: clients, episodes, facts, embeddings, import ledger, audit.
-- Contract: olympus-sdk docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md §3.
-- Idempotent: every object is guarded; safe to replay. No BEGIN/COMMIT (the runner wraps it).

-- Who is calling. One row per credential-bearing client (SSO user, Access service
-- token, gateway key, in-cluster worker). Identity resolution: §5.3.
CREATE TABLE IF NOT EXISTS memory.client (
    id                  text        PRIMARY KEY
                                    CHECK (id ~ '^[a-z0-9][a-z0-9._@:-]{1,63}$'),
    display_name        text        NOT NULL,
    kind                text        NOT NULL
                                    CHECK (kind IN ('access_sso', 'access_service_token', 'gateway_key', 'internal')),
    access_email        text        UNIQUE,            -- kind access_sso: JWT claim `email`, lower-cased
    access_common_name  text        UNIQUE,            -- kind access_service_token: JWT claim `common_name`
    key_id              text        UNIQUE              -- kind gateway_key: the public part of mgw_<key_id>_<secret>
                                    CHECK (key_id IS NULL OR key_id ~ '^[a-z0-9]{12}$'),
    key_hash            bytea,                          -- sha256(secret), never the secret itself
    scopes              text[]      NOT NULL DEFAULT ARRAY['read', 'write']::text[]
                                    CHECK (scopes <@ ARRAY['read', 'write', 'forget', 'admin']::text[]),
    rate_per_min        integer     NOT NULL DEFAULT 120 CHECK (rate_per_min BETWEEN 1 AND 10000),
    enabled             boolean     NOT NULL DEFAULT true,
    created_at          timestamptz NOT NULL DEFAULT now(),
    last_seen_at        timestamptz,
    revoked_at          timestamptz,
    CONSTRAINT client_credential_matches_kind CHECK (
        (kind = 'access_sso'            AND access_email IS NOT NULL) OR
        (kind = 'access_service_token'  AND access_common_name IS NOT NULL) OR
        (kind = 'gateway_key'           AND key_id IS NOT NULL AND key_hash IS NOT NULL) OR
        (kind = 'internal')
    )
);

-- Seed the in-cluster identities the workers and the import job write as.
INSERT INTO memory.client (id, display_name, kind, scopes)
VALUES ('internal:worker', 'memory workers', 'internal', ARRAY['read', 'write']),
       ('internal:import', 'one-shot imports (WS9)', 'internal', ARRAY['read', 'write'])
ON CONFLICT (id) DO NOTHING;

-- One captured unit: a transcript slice, a deliberate remember, or an imported item.
CREATE TABLE IF NOT EXISTS memory.episode (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    kind            text        NOT NULL CHECK (kind IN ('transcript', 'remember', 'import')),
    client_id       text        NOT NULL REFERENCES memory.client (id),
    source_system   text        NOT NULL DEFAULT 'live'
                                CHECK (source_system IN ('live', 'moneta', 'openmemory', 'claude-mem', 'second-brain')),
    -- Capture idempotency key (§4.2): Claude Code session id + byte offset of the slice.
    session_id      text        CHECK (session_id IS NULL OR length(session_id) BETWEEN 1 AND 128),
    seq             bigint      CHECK (seq IS NULL OR seq >= 0),
    end_offset      bigint      CHECK (end_offset IS NULL OR end_offset >= 0),
    hook_event      text        CHECK (hook_event IS NULL OR hook_event IN
                                       ('Stop', 'PreCompact', 'SessionEnd', 'SessionStart', 'manual')),
    -- Provenance (every write records these; NULL only when genuinely unknown).
    machine         text,
    os_user         text,
    project         text,       -- derived server-side by project_key() (§6.4), never trusted from the client
    cwd             text,
    git_remote      text,
    git_branch      text,
    agent           text,       -- e.g. 'claude-code/2.1.305', 'claude.ai', 'moneta-import'
    content         text        NOT NULL,               -- redacted, normalised text
    content_sha256  bytea       NOT NULL,
    byte_size       integer     NOT NULL CHECK (byte_size >= 0),
    turn_count      integer     CHECK (turn_count IS NULL OR turn_count >= 0),
    truncated       boolean     NOT NULL DEFAULT false,
    redactions      integer     NOT NULL DEFAULT 0 CHECK (redactions >= 0),
    first_at        timestamptz,                         -- first turn timestamp in the slice
    last_at         timestamptz,                         -- last turn timestamp in the slice
    captured_at     timestamptz NOT NULL,                -- client clock
    received_at     timestamptz NOT NULL DEFAULT now(),  -- server clock
    extracted_at    timestamptz,
    metadata        jsonb       NOT NULL DEFAULT '{}'::jsonb
                                CHECK (jsonb_typeof(metadata) = 'object' AND pg_column_size(metadata) <= 4096),
    forgotten_at    timestamptz,
    purged_at       timestamptz,
    CONSTRAINT episode_transcript_has_key CHECK (
        kind <> 'transcript' OR (session_id IS NOT NULL AND seq IS NOT NULL AND end_offset IS NOT NULL AND end_offset >= seq)
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS episode_session_seq_uq
    ON memory.episode (session_id, seq) WHERE session_id IS NOT NULL AND seq IS NOT NULL;
CREATE INDEX IF NOT EXISTS episode_project_received_idx ON memory.episode (project, received_at DESC);
CREATE INDEX IF NOT EXISTS episode_session_idx ON memory.episode (session_id, seq) WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS episode_received_idx ON memory.episode (received_at DESC);
-- cwd -> project resolution for MCP calls that only know their working directory (§6.4).
CREATE INDEX IF NOT EXISTS episode_cwd_idx ON memory.episode (cwd, received_at DESC) WHERE cwd IS NOT NULL;

-- A distilled, recallable statement. Immutable text except via append (fact_revision).
CREATE TABLE IF NOT EXISTS memory.fact (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    episode_id      uuid        NOT NULL REFERENCES memory.episode (id),
    content         text        NOT NULL CHECK (length(content) <= 8000),
    content_norm_sha256 bytea   NOT NULL,                -- sha256(lower(collapse_ws(trim(content)))), dedupe key
    kind            text        NOT NULL DEFAULT 'fact'
                                CHECK (kind IN ('fact', 'decision', 'preference', 'lesson', 'event', 'todo')),
    status          text        NOT NULL DEFAULT 'active'
                                CHECK (status IN ('active', 'canonical', 'draft', 'deprecated', 'superseded', 'forgotten')),
    confidence      real        CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    importance      smallint    NOT NULL DEFAULT 0 CHECK (importance BETWEEN 0 AND 5),
    tags            text[]      NOT NULL DEFAULT '{}'::text[],
    revision        integer     NOT NULL DEFAULT 1 CHECK (revision >= 1),
    -- Provenance, denormalised from the episode so recall filters without a join.
    client_id       text        NOT NULL REFERENCES memory.client (id),
    source_system   text        NOT NULL DEFAULT 'live'
                                CHECK (source_system IN ('live', 'moneta', 'openmemory', 'claude-mem', 'second-brain')),
    machine         text,
    project         text,
    cwd             text,
    git_remote      text,
    session_id      text,
    -- Validity: when the statement is true in the world (bitemporal: recorded_at is when we learned it).
    valid_from      timestamptz NOT NULL DEFAULT now(),
    valid_to        timestamptz CHECK (valid_to IS NULL OR valid_to >= valid_from),
    superseded_by   uuid        REFERENCES memory.fact (id),
    recorded_at     timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    recall_count    integer     NOT NULL DEFAULT 0,
    last_recalled_at timestamptz,
    forgotten_at    timestamptz,
    forgotten_by    text        REFERENCES memory.client (id),
    forget_reason   text        CHECK (forget_reason IS NULL OR length(forget_reason) <= 500),
    purged_at       timestamptz,
    search_tsv      tsvector    GENERATED ALWAYS AS (to_tsvector('english'::regconfig, content)) STORED,
    CONSTRAINT fact_forgotten_consistent CHECK ((status = 'forgotten') = (forgotten_at IS NOT NULL))
);

-- Exact-duplicate guard per project ('' = global). remember/import return the existing id on conflict.
CREATE UNIQUE INDEX IF NOT EXISTS fact_dedupe_uq
    ON memory.fact (content_norm_sha256, coalesce(project, '')) WHERE status <> 'forgotten';
CREATE INDEX IF NOT EXISTS fact_tsv_idx ON memory.fact USING gin (search_tsv);
CREATE INDEX IF NOT EXISTS fact_project_recent_idx ON memory.fact (project, recorded_at DESC)
    WHERE status IN ('active', 'canonical', 'draft');
CREATE INDEX IF NOT EXISTS fact_recent_idx ON memory.fact (recorded_at DESC)
    WHERE status IN ('active', 'canonical', 'draft');
CREATE INDEX IF NOT EXISTS fact_episode_idx ON memory.fact (episode_id);
CREATE INDEX IF NOT EXISTS fact_tags_idx ON memory.fact USING gin (tags);
CREATE INDEX IF NOT EXISTS fact_forgotten_idx ON memory.fact (forgotten_at) WHERE status = 'forgotten' AND purged_at IS NULL;

-- History of appends (Moneta `append` semantics) for audit and graph re-ingest.
CREATE TABLE IF NOT EXISTS memory.fact_revision (
    fact_id         uuid        NOT NULL REFERENCES memory.fact (id) ON DELETE CASCADE,
    revision        integer     NOT NULL CHECK (revision >= 1),
    content         text        NOT NULL,
    changed_by      text        NOT NULL REFERENCES memory.client (id),
    changed_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (fact_id, revision)
);

-- nomic-embed-text via the LiteLLM alias memory-embed: 768 dims, cosine.
-- Documents are embedded with the prefix 'search_document: ', queries with 'search_query: '.
CREATE TABLE IF NOT EXISTS memory.fact_embedding (
    fact_id         uuid        PRIMARY KEY REFERENCES memory.fact (id) ON DELETE CASCADE,
    model           text        NOT NULL,                -- what LiteLLM reported, e.g. 'nomic-embed-text'
    content_sha256  bytea       NOT NULL,                -- sha256 of the exact text embedded (detects staleness)
    embedding       vector(768) NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS fact_embedding_hnsw_idx
    ON memory.fact_embedding USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);

-- Imports are idempotent on (source_system, source_id).
CREATE TABLE IF NOT EXISTS memory.import_ledger (
    source_system   text        NOT NULL CHECK (source_system IN ('moneta', 'openmemory', 'claude-mem', 'second-brain')),
    source_id       text        NOT NULL CHECK (length(source_id) BETWEEN 1 AND 200),
    episode_id      uuid        NOT NULL REFERENCES memory.episode (id),
    fact_id         uuid        REFERENCES memory.fact (id),
    outcome         text        NOT NULL CHECK (outcome IN ('created', 'deduplicated', 'skipped_secret', 'skipped_empty')),
    source_created_at timestamptz,
    imported_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source_system, source_id)
);
CREATE INDEX IF NOT EXISTS import_ledger_fact_idx ON memory.import_ledger (fact_id);

-- Append-only audit of privileged and destructive actions.
CREATE TABLE IF NOT EXISTS memory.audit_log (
    id              bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at              timestamptz NOT NULL DEFAULT now(),
    client_id       text        NOT NULL,                -- no FK: survives client deletion
    action          text        NOT NULL CHECK (action IN
                                ('forget', 'restore', 'purge', 'set_status', 'append',
                                 'client_create', 'client_revoke', 'requeue_dead')),
    target_kind     text        NOT NULL CHECK (target_kind IN ('fact', 'episode', 'client', 'queue')),
    target_id       text        NOT NULL,
    request_id      text,
    detail          jsonb       NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS audit_log_target_idx ON memory.audit_log (target_kind, target_id);
CREATE INDEX IF NOT EXISTS audit_log_at_idx ON memory.audit_log (at DESC);

CREATE OR REPLACE FUNCTION memory.touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER fact_touch_updated_at
    BEFORE UPDATE ON memory.fact
    FOR EACH ROW EXECUTE FUNCTION memory.touch_updated_at();
