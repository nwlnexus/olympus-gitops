-- 0003_queue_and_graph: the durable job queue and the Postgres mirror of the Graphiti graph.
-- Contract: §3.3 (queue), §3.4 (graph mirror), §8 (worker semantics).
-- Idempotent; no BEGIN/COMMIT.

-- One row per unit of asynchronous work. Not only captures: every pipeline stage
-- (extract -> embed -> graph_ingest, and graph_forget) is a row here, claimed with
-- FOR UPDATE SKIP LOCKED. State machine in §8.1.
CREATE TABLE IF NOT EXISTS memory.capture_queue (
    id              bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    stage           text        NOT NULL CHECK (stage IN ('extract', 'embed', 'graph_ingest', 'graph_forget')),
    episode_id      uuid        REFERENCES memory.episode (id),
    fact_id         uuid        REFERENCES memory.fact (id),
    -- Exactly-once enqueue (§8.2): extract:<episode_id> | embed:<fact_id>:r<revision>
    --   | graph_ingest:<fact_id>:r<revision> | graph_forget:<fact_id>
    idempotency_key text        NOT NULL UNIQUE CHECK (length(idempotency_key) <= 200),
    state           text        NOT NULL DEFAULT 'pending'
                                CHECK (state IN ('pending', 'running', 'done', 'dead')),
    priority        smallint    NOT NULL DEFAULT 100,    -- lower runs first: live 100, backlog/imports 200
    attempts        integer     NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    max_attempts    integer     NOT NULL DEFAULT 8 CHECK (max_attempts BETWEEN 1 AND 50),
    available_at    timestamptz NOT NULL DEFAULT now(),
    locked_by       text,
    locked_at       timestamptz,
    lease_until     timestamptz,
    last_error      text        CHECK (last_error IS NULL OR length(last_error) <= 4000),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    done_at         timestamptz,
    CONSTRAINT capture_queue_target CHECK (
        (stage = 'extract' AND episode_id IS NOT NULL) OR
        (stage IN ('embed', 'graph_ingest', 'graph_forget') AND fact_id IS NOT NULL)
    ),
    CONSTRAINT capture_queue_lease CHECK (
        (state = 'running') = (locked_by IS NOT NULL AND lease_until IS NOT NULL)
    )
);

-- The claim query's access path (§8.3) and the reaper's.
CREATE INDEX IF NOT EXISTS capture_queue_claim_idx
    ON memory.capture_queue (stage, priority, available_at, id) WHERE state = 'pending';
CREATE INDEX IF NOT EXISTS capture_queue_lease_idx
    ON memory.capture_queue (lease_until) WHERE state = 'running';
CREATE INDEX IF NOT EXISTS capture_queue_dead_idx
    ON memory.capture_queue (stage, updated_at) WHERE state = 'dead';
CREATE INDEX IF NOT EXISTS capture_queue_done_idx
    ON memory.capture_queue (done_at) WHERE state = 'done';
CREATE INDEX IF NOT EXISTS capture_queue_fact_idx ON memory.capture_queue (fact_id) WHERE fact_id IS NOT NULL;

CREATE OR REPLACE TRIGGER capture_queue_touch_updated_at
    BEFORE UPDATE ON memory.capture_queue
    FOR EACH ROW EXECUTE FUNCTION memory.touch_updated_at();

-- Graphiti episodes created from a fact revision. Graphiti mints the uuid; the ingest
-- worker records it here (and looks it up by name '<fact_id>:r<revision>' before a retry).
CREATE TABLE IF NOT EXISTS memory.fact_graph_episode (
    graph_episode_uuid uuid     PRIMARY KEY,
    fact_id         uuid        NOT NULL REFERENCES memory.fact (id) ON DELETE CASCADE,
    revision        integer     NOT NULL CHECK (revision >= 1),
    ingested_at     timestamptz NOT NULL DEFAULT now(),
    removed_at      timestamptz,                         -- set by graph_forget after remove_episode
    UNIQUE (fact_id, revision)
);

-- Mirror of Graphiti EntityNode, written only by the ingest worker. The gateway reads
-- this, never FalkorDB (§3.4).
CREATE TABLE IF NOT EXISTS memory.entity (
    uuid            uuid        PRIMARY KEY,             -- Graphiti EntityNode.uuid
    name            text        NOT NULL,
    labels          text[]      NOT NULL DEFAULT '{}'::text[],
    summary         text        NOT NULL DEFAULT '',
    created_at      timestamptz NOT NULL,
    synced_at       timestamptz NOT NULL DEFAULT now(),
    name_tsv        tsvector    GENERATED ALWAYS AS (to_tsvector('simple'::regconfig, name)) STORED
);
CREATE INDEX IF NOT EXISTS entity_name_tsv_idx ON memory.entity USING gin (name_tsv);
CREATE INDEX IF NOT EXISTS entity_name_lower_idx ON memory.entity (lower(name));

-- Mirror of Graphiti EntityEdge (a relation with a validity interval).
CREATE TABLE IF NOT EXISTS memory.entity_edge (
    uuid            uuid        PRIMARY KEY,             -- Graphiti EntityEdge.uuid
    source_uuid     uuid        NOT NULL REFERENCES memory.entity (uuid) ON DELETE CASCADE,
    target_uuid     uuid        NOT NULL REFERENCES memory.entity (uuid) ON DELETE CASCADE,
    name            text        NOT NULL,                -- relation type, e.g. 'USES', 'DEPENDS_ON'
    fact_text       text        NOT NULL,                -- EntityEdge.fact
    fact_ids        uuid[]      NOT NULL DEFAULT '{}'::uuid[],  -- our facts whose Graphiti episodes support it
    valid_at        timestamptz,
    invalid_at      timestamptz,
    expired_at      timestamptz,
    created_at      timestamptz NOT NULL,
    synced_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS entity_edge_source_idx ON memory.entity_edge (source_uuid);
CREATE INDEX IF NOT EXISTS entity_edge_target_idx ON memory.entity_edge (target_uuid);
CREATE INDEX IF NOT EXISTS entity_edge_fact_ids_idx ON memory.entity_edge USING gin (fact_ids);
CREATE INDEX IF NOT EXISTS entity_edge_current_idx ON memory.entity_edge (source_uuid, target_uuid)
    WHERE invalid_at IS NULL AND expired_at IS NULL;

-- Which entities a fact mentions (from AddEpisodeResults.nodes). Drives one-hop expansion.
CREATE TABLE IF NOT EXISTS memory.fact_entity (
    fact_id         uuid        NOT NULL REFERENCES memory.fact (id) ON DELETE CASCADE,
    entity_uuid     uuid        NOT NULL REFERENCES memory.entity (uuid) ON DELETE CASCADE,
    PRIMARY KEY (fact_id, entity_uuid)
);
CREATE INDEX IF NOT EXISTS fact_entity_entity_idx ON memory.fact_entity (entity_uuid);
