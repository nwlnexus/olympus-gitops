-- 0005_postgres_graph: the knowledge graph lives in Postgres only (no Graphiti, no FalkorDB; decision 2026-10-21).
-- Contract: olympus-sdk docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md §3.6 and §14.
-- Idempotent; no BEGIN/COMMIT (the runner wraps it with --single-transaction).
-- Leaves inert, for 0006 to drop: memory.fact_graph_episode, the queue stage 'graph_forget'.

-- 1. One normalisation for every entity name, alias and literal value (lower case, NFKC, no leading article,
--    only letters/digits/space and . : # / - kept, runs of space or _ collapsed, no edge spaces or dots). The worker
--    and the gateway call this function; neither re-implements it. Its output never contains a LIKE wildcard.
CREATE OR REPLACE FUNCTION memory.graph_norm(t text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN nullif(btrim(regexp_replace(regexp_replace(regexp_replace(lower(normalize(t, NFKC)),
                                                                 '^[[:space:]]*(the|a|an)[[:space:]]+', ''),
                                                  '[^[:alnum:][:space:]._:#/-]', '', 'g'),
                                   '[[:space:]_]+', ' ', 'g'),
                    ' .'),
              '');

-- 2. Relation vocabulary. single_valued: a subject has one current object (a new object supersedes the old one).
--    Changed only by a migration; the worker refuses to start when its prompt lists a different vocabulary.
CREATE TABLE IF NOT EXISTS memory.graph_predicate (
    name            text        PRIMARY KEY CHECK (name ~ '^[A-Z][A-Z_]{1,39}$'),
    single_valued   boolean     NOT NULL,
    description     text        NOT NULL CHECK (length(description) BETWEEN 1 AND 200)
);
INSERT INTO memory.graph_predicate (name, single_valued, description) VALUES
    ('RUNS_ON',            true,  'where a service, job or workload runs (host, cluster, runner)'),
    ('LISTENS_ON',         true,  'address or port a service binds to (literal value)'),
    ('SERVES_MODEL',       true,  'model an alias or endpoint serves'),
    ('RUNS_VERSION',       true,  'software version in use (literal value)'),
    ('PINNED_TO',          true,  'version, digest or node something is pinned to'),
    ('HAS_STATUS',         true,  'lifecycle state: live, retired, read-only, decommissioned, dropped (literal value)'),
    ('AUTHENTICATES_WITH', true,  'credential or mechanism used to authenticate'),
    ('REPLACED_BY',        true,  'successor of a retired thing'),
    ('CONFIGURED_WITH',    false, 'setting or configuration value'),
    ('USES',               false, 'uses a tool, library or service'),
    ('DEPENDS_ON',         false, 'requires another thing to work'),
    ('PART_OF',            false, 'component of a larger thing'),
    ('MEMBER_OF',          false, 'member of a group, cluster or scale set'),
    ('CONNECTS_TO',        false, 'network or API connection to'),
    ('STORES_DATA_IN',     false, 'persists data in a store or volume'),
    ('DEPLOYED_WITH',      false, 'deployed or managed by a tool'),
    ('IMPORTED_INTO',      false, 'data imported or migrated into'),
    ('MIRRORS_INTO',       false, 'copied or mirrored into'),
    ('RELATED_TO',         false, 'fallback when no other predicate fits')
ON CONFLICT (name) DO UPDATE SET single_valued = EXCLUDED.single_valued, description = EXCLUDED.description;

-- 3. Entities: ids minted in Postgres now, and a name embedding for resolution and prompt context.
ALTER TABLE memory.entity ALTER COLUMN uuid SET DEFAULT gen_random_uuid();
ALTER TABLE memory.entity ALTER COLUMN created_at SET DEFAULT now();
-- nomic-embed-text via memory-embed, input 'search_document: ' || name. Written by the worker in the same
-- transaction that creates the entity; NULL only after a rename by graph_detach_fact (the worker refills it).
ALTER TABLE memory.entity ADD COLUMN IF NOT EXISTS name_embedding vector(768);
ALTER TABLE memory.entity ADD COLUMN IF NOT EXISTS name_embedding_model text;
CREATE INDEX IF NOT EXISTS entity_name_embedding_hnsw_idx
    ON memory.entity USING hnsw (name_embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);

-- 4. Every surface form of an entity, its canonical name included (is_name), each supported by the facts that used it.
--    alias_norm is globally unique: one normalised form names one entity. This unique key is also the backstop
--    against two concurrent workers creating the same entity (§14.4).
CREATE TABLE IF NOT EXISTS memory.entity_alias (
    alias_norm      text        PRIMARY KEY,
    alias           text        NOT NULL CHECK (length(alias) BETWEEN 1 AND 200),
    entity_uuid     uuid        NOT NULL REFERENCES memory.entity (uuid) ON DELETE CASCADE,
    is_name         boolean     NOT NULL DEFAULT false,
    source          text        NOT NULL CHECK (source IN ('name', 'mention', 'embedding', 'stated', 'merge')),
    fact_ids        uuid[]      NOT NULL DEFAULT '{}'::uuid[],   -- support: facts whose text used this form
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT entity_alias_norm_matches CHECK (alias_norm = memory.graph_norm(alias))
);
CREATE UNIQUE INDEX IF NOT EXISTS entity_alias_one_name_uq ON memory.entity_alias (entity_uuid) WHERE is_name;
CREATE INDEX IF NOT EXISTS entity_alias_entity_idx ON memory.entity_alias (entity_uuid);
CREATE INDEX IF NOT EXISTS entity_alias_fact_ids_idx ON memory.entity_alias USING gin (fact_ids);
CREATE INDEX IF NOT EXISTS entity_alias_prefix_idx ON memory.entity_alias (alias_norm text_pattern_ops);

-- 5. Relations: literal objects (IPs, ports, versions, status words) are values on the edge, not entities;
--    polarity is a column; the edge that invalidated another is recorded so forget can undo it.
ALTER TABLE memory.entity_edge ALTER COLUMN uuid SET DEFAULT gen_random_uuid();
ALTER TABLE memory.entity_edge ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE memory.entity_edge ALTER COLUMN target_uuid DROP NOT NULL;
ALTER TABLE memory.entity_edge ADD COLUMN IF NOT EXISTS target_value text
    CHECK (target_value IS NULL OR length(target_value) BETWEEN 1 AND 200);
ALTER TABLE memory.entity_edge ADD COLUMN IF NOT EXISTS negated boolean NOT NULL DEFAULT false;
ALTER TABLE memory.entity_edge ADD COLUMN IF NOT EXISTS invalidated_by uuid
    REFERENCES memory.entity_edge (uuid) ON DELETE SET NULL;
ALTER TABLE memory.entity_edge ADD COLUMN IF NOT EXISTS target_key text
    GENERATED ALWAYS AS (coalesce('e:' || target_uuid::text, 'v:' || memory.graph_norm(target_value))) STORED;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'memory.entity_edge'::regclass AND conname = 'entity_edge_target_one') THEN
        ALTER TABLE memory.entity_edge ADD CONSTRAINT entity_edge_target_one
            CHECK ((target_uuid IS NULL) <> (target_value IS NULL));
    END IF;
    -- The constraint back-filled facts would otherwise break (findings §4.7): an edge never ends before it starts.
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'memory.entity_edge'::regclass AND conname = 'entity_edge_validity_order') THEN
        ALTER TABLE memory.entity_edge ADD CONSTRAINT entity_edge_validity_order
            CHECK (invalid_at IS NULL OR valid_at IS NULL OR invalid_at >= valid_at);
    END IF;
    -- An edge exists only while a fact supports it (graph_detach_fact deletes it in the same transaction).
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'memory.entity_edge'::regclass AND conname = 'entity_edge_supported') THEN
        ALTER TABLE memory.entity_edge ADD CONSTRAINT entity_edge_supported CHECK (cardinality(fact_ids) >= 1);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'memory.entity_edge'::regclass AND conname = 'entity_edge_not_self_invalidated') THEN
        ALTER TABLE memory.entity_edge ADD CONSTRAINT entity_edge_not_self_invalidated
            CHECK (invalidated_by IS DISTINCT FROM uuid);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'memory.entity_edge'::regclass AND conname = 'entity_edge_predicate_fk') THEN
        ALTER TABLE memory.entity_edge ADD CONSTRAINT entity_edge_predicate_fk
            FOREIGN KEY (name) REFERENCES memory.graph_predicate (name);
    END IF;
END
$$;

-- Identity of a current statement: (subject, predicate, polarity, object). A restatement adds support instead of a
-- second row; concurrent writers that miss each other fail on this index and retry.
CREATE UNIQUE INDEX IF NOT EXISTS entity_edge_current_uq
    ON memory.entity_edge (source_uuid, name, negated, target_key) WHERE invalid_at IS NULL;
CREATE INDEX IF NOT EXISTS entity_edge_subject_current_idx
    ON memory.entity_edge (source_uuid, name) WHERE invalid_at IS NULL;
CREATE INDEX IF NOT EXISTS entity_edge_invalidated_by_idx
    ON memory.entity_edge (invalidated_by) WHERE invalidated_by IS NOT NULL;

-- 6. Which revision of a fact the graph currently reflects, and how: 'entities' (mentions and aliases only),
--    'full' (also relations), 'failed' (the model's answer was unusable twice; not retried until an admin asks).
ALTER TABLE memory.fact ADD COLUMN IF NOT EXISTS graph_revision integer;
ALTER TABLE memory.fact ADD COLUMN IF NOT EXISTS graph_mode text CHECK (graph_mode IN ('entities', 'full', 'failed'));
ALTER TABLE memory.fact ADD COLUMN IF NOT EXISTS graph_extracted_at timestamptz;
ALTER TABLE memory.fact ADD COLUMN IF NOT EXISTS graph_extractor text
    CHECK (graph_extractor IS NULL OR length(graph_extractor) <= 100);
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'memory.fact'::regclass AND conname = 'fact_graph_state_consistent') THEN
        ALTER TABLE memory.fact ADD CONSTRAINT fact_graph_state_consistent CHECK (
            (graph_revision IS NULL) = (graph_mode IS NULL)
            AND (graph_revision IS NULL) = (graph_extracted_at IS NULL)
            AND (graph_revision IS NULL OR graph_revision BETWEEN 1 AND revision));
    END IF;
END
$$;
-- Backfill progress and selection (§14.6).
CREATE INDEX IF NOT EXISTS fact_graph_backlog_idx ON memory.fact (recorded_at DESC)
    WHERE status IN ('active', 'canonical', 'draft') AND graph_revision IS DISTINCT FROM revision;

-- 7. Supersession suggestions. Graph invalidation never changes fact.status by itself (§14.5): a rule proposes,
--    a human (admin CLI) accepts or rejects; the consolidation job only closes suggestions that became moot.
CREATE TABLE IF NOT EXISTS memory.supersession_suggestion (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    old_fact_id         uuid        NOT NULL REFERENCES memory.fact (id),
    new_fact_id         uuid        NOT NULL REFERENCES memory.fact (id),
    old_edge_uuid       uuid        REFERENCES memory.entity_edge (uuid) ON DELETE SET NULL,
    new_edge_uuid       uuid        REFERENCES memory.entity_edge (uuid) ON DELETE SET NULL,
    rule                text        NOT NULL CHECK (rule IN ('single_valued_value', 'single_valued_entity', 'polarity_flip')),
    proposed_by         text        NOT NULL CHECK (length(proposed_by) BETWEEN 1 AND 100),  -- e.g. 'graph-v1@memory-extract'
    confidence          real        NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
    state               text        NOT NULL DEFAULT 'pending'
                                    CHECK (state IN ('pending', 'accepted', 'rejected', 'obsolete')),
    old_status_before   text        CHECK (old_status_before IS NULL OR old_status_before IN ('active', 'canonical', 'draft')),
    created_at          timestamptz NOT NULL DEFAULT now(),
    decided_at          timestamptz,
    decided_by          text        REFERENCES memory.client (id),
    decision_note       text        CHECK (decision_note IS NULL OR length(decision_note) <= 500),
    CONSTRAINT supersession_distinct_facts CHECK (old_fact_id <> new_fact_id),
    CONSTRAINT supersession_decision_consistent CHECK (
        (state = 'pending') = (decided_at IS NULL) AND (state = 'pending') = (decided_by IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS supersession_open_pair_uq
    ON memory.supersession_suggestion (old_fact_id, new_fact_id) WHERE state IN ('pending', 'accepted');
CREATE INDEX IF NOT EXISTS supersession_pending_idx
    ON memory.supersession_suggestion (created_at DESC) WHERE state = 'pending';
CREATE INDEX IF NOT EXISTS supersession_old_fact_idx ON memory.supersession_suggestion (old_fact_id);
CREATE INDEX IF NOT EXISTS supersession_new_fact_idx ON memory.supersession_suggestion (new_fact_id);

-- 8. Pause switch for the LLM worker (§14.8): 'llm' stops every claim that calls the 27B, 'backfill' only
--    priority >= 200 work. Always time-boxed (at most 7 days); set and cleared with memory-admin.
CREATE TABLE IF NOT EXISTS memory.worker_pause (
    scope           text        PRIMARY KEY CHECK (scope IN ('llm', 'backfill')),
    paused_until    timestamptz NOT NULL,
    reason          text        NOT NULL CHECK (length(reason) BETWEEN 1 AND 200),
    paused_by       text        NOT NULL REFERENCES memory.client (id),
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT worker_pause_bounded CHECK (paused_until > created_at AND paused_until <= created_at + interval '7 days')
);

-- 9. Audit actions for the new admin operations (the CHECK lists of 0002, extended). 'suggest_closed' is the action
--    migration 0009 (olympus-sdk#726) added after this migration was designed; it is kept so this DROP/ADD neither
--    fails on existing audit rows nor loses the action. 0011 re-asserts the full list after 0009 on a fresh database.
ALTER TABLE memory.audit_log DROP CONSTRAINT IF EXISTS audit_log_action_check;
ALTER TABLE memory.audit_log ADD CONSTRAINT audit_log_action_check CHECK (action IN
    ('forget', 'restore', 'purge', 'set_status', 'append', 'client_create', 'client_revoke', 'requeue_dead',
     'supersession_accept', 'supersession_reject', 'entity_merge', 'worker_pause', 'worker_resume',
     'suggest_closed'));
ALTER TABLE memory.audit_log DROP CONSTRAINT IF EXISTS audit_log_target_kind_check;
ALTER TABLE memory.audit_log ADD CONSTRAINT audit_log_target_kind_check CHECK (target_kind IN
    ('fact', 'episode', 'client', 'queue', 'entity', 'suggestion', 'worker'));

-- 10. Exact removal of one fact's graph support (forget, re-extraction after append, legacy graph_forget jobs).
--     One transaction with the caller; takes the graph lock first (lock order: graph lock, fact rows, graph rows).
--     SECURITY DEFINER so the gateway, which only reads graph tables, can run it inside its forget transaction.
CREATE OR REPLACE FUNCTION memory.graph_detach_fact(p_fact uuid)
RETURNS TABLE (links_deleted integer, edges_deleted integer, edges_revalidated integer, edges_repointed integer,
               edges_folded integer, aliases_deleted integer, entities_deleted integer, entities_renamed integer,
               suggestions_deleted integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_dead      uuid[];
    v_entities  uuid[];
    r           record;
    v_rep       record;
    v_twin      uuid;
    v_alias     record;
BEGIN
    links_deleted := 0; edges_deleted := 0; edges_revalidated := 0; edges_repointed := 0; edges_folded := 0;
    aliases_deleted := 0; entities_deleted := 0; entities_renamed := 0; suggestions_deleted := 0;

    PERFORM pg_advisory_xact_lock(20261021, 1);

    -- (1) Pending suggestions that name the fact. Decided ones hold ids only and stay as the decision record.
    DELETE FROM memory.supersession_suggestion s
    WHERE s.state = 'pending' AND (s.old_fact_id = p_fact OR s.new_fact_id = p_fact);
    GET DIAGNOSTICS suggestions_deleted = ROW_COUNT;

    -- (2) Edges this fact alone supports.
    SELECT coalesce(array_agg(e.uuid), '{}'::uuid[]) INTO v_dead
    FROM memory.entity_edge e
    WHERE e.fact_ids @> ARRAY[p_fact] AND e.fact_ids <@ ARRAY[p_fact];

    -- (3) Edges a dying edge had invalidated, newest statement first: re-point to another current contradicting
    --     statement, fold into an identical current one, or make current again.
    FOR r IN
        SELECT e.* FROM memory.entity_edge e
        WHERE e.invalidated_by = ANY (v_dead) AND NOT (e.uuid = ANY (v_dead))
        ORDER BY e.valid_at DESC NULLS LAST, e.created_at DESC, e.uuid
    LOOP
        SELECT c.uuid, c.valid_at INTO v_rep
        FROM memory.entity_edge c
        JOIN memory.graph_predicate p ON p.name = c.name
        WHERE c.source_uuid = r.source_uuid AND c.name = r.name AND c.invalid_at IS NULL
          AND c.uuid <> r.uuid AND NOT (c.uuid = ANY (v_dead))
          AND ((p.single_valued AND NOT c.negated AND NOT r.negated AND c.target_key <> r.target_key)
               OR (c.target_key = r.target_key AND c.negated <> r.negated))
          AND (r.valid_at IS NULL OR c.valid_at IS NULL OR c.valid_at >= r.valid_at)
        ORDER BY c.valid_at ASC NULLS LAST, c.created_at, c.uuid
        LIMIT 1;
        IF FOUND THEN
            UPDATE memory.entity_edge
            SET invalidated_by = v_rep.uuid, invalid_at = coalesce(v_rep.valid_at, invalid_at), synced_at = now()
            WHERE uuid = r.uuid;
            edges_repointed := edges_repointed + 1;
            CONTINUE;
        END IF;

        SELECT c.uuid INTO v_twin
        FROM memory.entity_edge c
        WHERE c.source_uuid = r.source_uuid AND c.name = r.name AND c.negated = r.negated
          AND c.target_key = r.target_key AND c.invalid_at IS NULL AND NOT (c.uuid = ANY (v_dead))
        LIMIT 1;
        IF FOUND THEN
            UPDATE memory.entity_edge c
            SET fact_ids = (SELECT array_agg(DISTINCT x ORDER BY x) FROM unnest(c.fact_ids || r.fact_ids) AS x),
                valid_at = least(c.valid_at, r.valid_at), synced_at = now()
            WHERE c.uuid = v_twin;
            UPDATE memory.entity_edge SET invalidated_by = v_twin WHERE invalidated_by = r.uuid;
            DELETE FROM memory.entity_edge WHERE uuid = r.uuid;
            edges_folded := edges_folded + 1;
            CONTINUE;
        END IF;

        UPDATE memory.entity_edge
        SET invalid_at = NULL, expired_at = NULL, invalidated_by = NULL, synced_at = now()
        WHERE uuid = r.uuid;
        edges_revalidated := edges_revalidated + 1;
    END LOOP;

    -- (4) Delete the edges only this fact supported; (5) shared edges lose it from their support.
    DELETE FROM memory.entity_edge WHERE uuid = ANY (v_dead);
    GET DIAGNOSTICS edges_deleted = ROW_COUNT;
    UPDATE memory.entity_edge SET fact_ids = array_remove(fact_ids, p_fact), synced_at = now()
    WHERE fact_ids @> ARRAY[p_fact];

    -- (6) Aliases only this fact used are deleted (a canonical name is handled in step 9); others lose it.
    SELECT coalesce(array_agg(DISTINCT fe.entity_uuid), '{}'::uuid[]) INTO v_entities
    FROM memory.fact_entity fe WHERE fe.fact_id = p_fact;
    DELETE FROM memory.entity_alias a
    WHERE NOT a.is_name AND a.fact_ids @> ARRAY[p_fact] AND a.fact_ids <@ ARRAY[p_fact];
    GET DIAGNOSTICS aliases_deleted = ROW_COUNT;
    UPDATE memory.entity_alias SET fact_ids = array_remove(fact_ids, p_fact), updated_at = now()
    WHERE fact_ids @> ARRAY[p_fact];

    -- (7) Mentions; (8) entities no remaining fact mentions (their aliases and edges cascade).
    DELETE FROM memory.fact_entity WHERE fact_id = p_fact;
    GET DIAGNOSTICS links_deleted = ROW_COUNT;
    DELETE FROM memory.entity e
    WHERE e.uuid = ANY (v_entities)
      AND NOT EXISTS (SELECT 1 FROM memory.fact_entity fe WHERE fe.entity_uuid = e.uuid);
    GET DIAGNOSTICS entities_deleted = ROW_COUNT;

    -- (9) A surviving entity whose canonical name no remaining fact used takes its best-supported surviving alias
    --     as its name (the forgotten fact's wording does not live on as a label); the worker re-embeds the name.
    FOR r IN
        SELECT a.entity_uuid, a.alias_norm FROM memory.entity_alias a
        WHERE a.is_name AND cardinality(a.fact_ids) = 0 AND a.entity_uuid = ANY (v_entities)
    LOOP
        SELECT b.alias_norm, b.alias INTO v_alias
        FROM memory.entity_alias b
        WHERE b.entity_uuid = r.entity_uuid AND NOT b.is_name AND cardinality(b.fact_ids) > 0
        ORDER BY cardinality(b.fact_ids) DESC, b.created_at, b.alias_norm
        LIMIT 1;
        IF FOUND THEN
            DELETE FROM memory.entity_alias WHERE alias_norm = r.alias_norm;
            UPDATE memory.entity_alias SET is_name = true, updated_at = now() WHERE alias_norm = v_alias.alias_norm;
            UPDATE memory.entity
            SET name = v_alias.alias, name_embedding = NULL, name_embedding_model = NULL, synced_at = now()
            WHERE uuid = r.entity_uuid;
            aliases_deleted := aliases_deleted + 1;
            entities_renamed := entities_renamed + 1;
        END IF;
    END LOOP;

    -- (10) The fact has no graph any more (a restore or a new revision re-extracts it).
    UPDATE memory.fact
    SET graph_revision = NULL, graph_mode = NULL, graph_extracted_at = NULL, graph_extractor = NULL
    WHERE id = p_fact AND graph_revision IS NOT NULL;

    RETURN NEXT;
END
$fn$;

-- 11. Merge two entities (a stated equivalence found by the worker, or `memory-admin entity merge`). Mentions,
--     aliases and edges move to p_keep; a current edge that already exists on p_keep absorbs the moved one's
--     support; an edge that would point from p_keep to itself is dropped (the alias now carries that statement).
CREATE OR REPLACE FUNCTION memory.graph_merge_entities(p_keep uuid, p_drop uuid)
RETURNS TABLE (links_moved integer, aliases_moved integer, edges_moved integer, edges_folded integer,
               edges_dropped integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    r       record;
    v_src   uuid;
    v_tgt   uuid;
    v_twin  uuid;
BEGIN
    links_moved := 0; aliases_moved := 0; edges_moved := 0; edges_folded := 0; edges_dropped := 0;
    IF p_keep IS NULL OR p_drop IS NULL OR p_keep = p_drop THEN
        RAISE EXCEPTION 'graph_merge_entities: two different entities are required' USING ERRCODE = '22023';
    END IF;
    PERFORM pg_advisory_xact_lock(20261021, 1);
    IF (SELECT count(*) FROM memory.entity WHERE uuid IN (p_keep, p_drop)) <> 2 THEN
        RAISE EXCEPTION 'graph_merge_entities: entity not found' USING ERRCODE = 'P0002';
    END IF;

    INSERT INTO memory.fact_entity (fact_id, entity_uuid)
    SELECT fe.fact_id, p_keep FROM memory.fact_entity fe WHERE fe.entity_uuid = p_drop
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS links_moved = ROW_COUNT;

    UPDATE memory.entity_alias
    SET entity_uuid = p_keep, is_name = false, source = CASE WHEN is_name THEN 'merge' ELSE source END,
        updated_at = now()
    WHERE entity_uuid = p_drop;
    GET DIAGNOSTICS aliases_moved = ROW_COUNT;

    FOR r IN
        SELECT e.* FROM memory.entity_edge e
        WHERE e.source_uuid = p_drop OR e.target_uuid = p_drop
        ORDER BY e.created_at, e.uuid
    LOOP
        v_src := CASE WHEN r.source_uuid = p_drop THEN p_keep ELSE r.source_uuid END;
        v_tgt := CASE WHEN r.target_uuid = p_drop THEN p_keep ELSE r.target_uuid END;
        IF v_tgt IS NOT NULL AND v_src = v_tgt THEN
            DELETE FROM memory.entity_edge WHERE uuid = r.uuid;
            edges_dropped := edges_dropped + 1;
            CONTINUE;
        END IF;
        v_twin := NULL;
        IF r.invalid_at IS NULL THEN
            SELECT c.uuid INTO v_twin
            FROM memory.entity_edge c
            WHERE c.source_uuid = v_src AND c.name = r.name AND c.negated = r.negated AND c.invalid_at IS NULL
              AND c.uuid <> r.uuid
              AND c.target_key = coalesce('e:' || v_tgt::text, 'v:' || memory.graph_norm(r.target_value))
            LIMIT 1;
        END IF;
        IF v_twin IS NOT NULL THEN
            UPDATE memory.entity_edge c
            SET fact_ids = (SELECT array_agg(DISTINCT x ORDER BY x) FROM unnest(c.fact_ids || r.fact_ids) AS x),
                valid_at = least(c.valid_at, r.valid_at), synced_at = now()
            WHERE c.uuid = v_twin;
            UPDATE memory.entity_edge SET invalidated_by = v_twin WHERE invalidated_by = r.uuid;
            DELETE FROM memory.entity_edge WHERE uuid = r.uuid;
            edges_folded := edges_folded + 1;
        ELSE
            UPDATE memory.entity_edge SET source_uuid = v_src, target_uuid = v_tgt, synced_at = now()
            WHERE uuid = r.uuid;
            edges_moved := edges_moved + 1;
        END IF;
    END LOOP;

    DELETE FROM memory.fact_entity WHERE entity_uuid = p_drop;
    DELETE FROM memory.entity WHERE uuid = p_drop;
    RETURN NEXT;
END
$fn$;

-- 12. Left inert (dropped by 0006 once no code or test names them): the Graphiti episode map, and graph_forget.
COMMENT ON TABLE memory.fact_graph_episode IS
    'Inert since 0005 (no Graphiti). Nothing reads or writes it; dropped by 0006.';

-- 13. Privileges (0004 style): the gateway reads the graph and runs the two functions; the worker writes it.
GRANT SELECT ON memory.graph_predicate, memory.entity_alias, memory.supersession_suggestion, memory.worker_pause
    TO memory_gateway, memory_worker;
GRANT INSERT, UPDATE ON memory.entity_alias, memory.supersession_suggestion TO memory_worker;
GRANT UPDATE ON memory.supersession_suggestion TO memory_gateway;                 -- admin CLI accept/reject
GRANT INSERT, UPDATE, DELETE ON memory.worker_pause TO memory_gateway;            -- admin CLI pause/resume
REVOKE ALL ON FUNCTION memory.graph_detach_fact(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION memory.graph_merge_entities(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION memory.graph_detach_fact(uuid) TO memory_gateway, memory_worker;
GRANT EXECUTE ON FUNCTION memory.graph_merge_entities(uuid, uuid) TO memory_gateway, memory_worker;
