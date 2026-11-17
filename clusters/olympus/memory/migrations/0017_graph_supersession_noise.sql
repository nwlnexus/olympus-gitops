-- 0017_graph_supersession_noise: fewer, better supersession suggestions (olympus-sdk#967, epic #965).
-- Contract: olympus-sdk docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md §14.4, §14.5, §14.14.
-- Idempotent (CREATE OR REPLACE, the 0005/0013/0015 signatures and grants are kept); no BEGIN/COMMIT (the runner wraps
-- it with --single-transaction). No table is altered and no row is rewritten, so it is safe to apply while the gateway
-- and the workers write: replacing a function takes no lock a running call holds, and a call that already started
-- finishes on the old body. lock_timeout bounds any wait on the catalog (the runner's Job retries).
--
-- What changes (the worker's Q-GRAPH-SUGGEST and relation rule change the same way in its image):
-- 1. Closed HAS_STATUS vocabulary. Only the lifecycle values (live, retired, read-only, decommissioned, dropped,
--    not built) take part in the single-valued rule of HAS_STATUS. A statement with any other value (free text written
--    before the worker mapped it, e.g. "noisy" or "merged") neither invalidates nor is invalidated by another value.
--    New helper memory.graph_single_valued_target; used by graph_repair_invalidated and graph_merge_entities.
-- 2. graph_merge_entities proposes no suggestion whose older fact is an event (a point-in-time record nothing can
--    supersede) or has a valid_to in the past (recall no longer returns it). The edge is still invalidated.
-- 3. graph_merge_entities proposes at most one suggestion per invalidated edge: the most recent older fact that can
--    still be superseded against the most recent live newer fact (before: every older fact times every newer fact).

SET LOCAL lock_timeout = '5s';

-- Whether a statement with this predicate and target_key takes part in the single-valued rule of its predicate. Only
-- HAS_STATUS has a closed value list; the worker's policy maps synonyms onto it and demotes other values to
-- RELATED_TO, so only edges written before that can hold free text. Called only by the two functions below.
CREATE OR REPLACE FUNCTION memory.graph_single_valued_target(p_name text, p_target_key text)
RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
RETURN p_name IS DISTINCT FROM 'HAS_STATUS'
       OR p_target_key IN ('v:live', 'v:retired', 'v:read-only', 'v:decommissioned', 'v:dropped', 'v:not built');
REVOKE ALL ON FUNCTION memory.graph_single_valued_target(text, text) FROM PUBLIC;

-- 0015's helper; a revived statement applies the closed HAS_STATUS vocabulary (item 1).
CREATE OR REPLACE FUNCTION memory.graph_repair_invalidated(p_edges uuid[],
    OUT repointed integer, OUT folded integer, OUT revalidated integer)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    r       record;
    v_rep   record;
    v_twin  uuid;
BEGIN
    repointed := 0; folded := 0; revalidated := 0;
    FOR r IN
        SELECT e.uuid FROM memory.entity_edge e
        WHERE e.uuid = ANY (p_edges)
        ORDER BY e.valid_at DESC NULLS LAST, e.created_at DESC, e.uuid
    LOOP
        -- Re-read: an earlier iteration may have folded it away or already invalidated it again.
        SELECT e.* INTO r FROM memory.entity_edge e WHERE e.uuid = r.uuid;
        IF NOT FOUND OR r.invalidated_by IS NOT NULL THEN
            CONTINUE;
        END IF;

        SELECT c.uuid, c.valid_at INTO v_rep
        FROM memory.entity_edge c
        JOIN memory.graph_predicate p ON p.name = c.name
        WHERE c.source_uuid = r.source_uuid AND c.name = r.name AND c.invalid_at IS NULL AND c.uuid <> r.uuid
          AND NOT (c.fact_ids && r.fact_ids)
          AND ((p.single_valued AND NOT c.negated AND NOT r.negated AND c.target_key <> r.target_key
                AND memory.graph_single_valued_target(c.name, c.target_key)
                AND memory.graph_single_valued_target(r.name, r.target_key))
               OR (c.target_key = r.target_key AND c.negated <> r.negated))
          AND (r.valid_at IS NULL OR c.valid_at IS NULL OR c.valid_at >= r.valid_at)
        ORDER BY c.valid_at ASC NULLS LAST, c.created_at, c.uuid
        LIMIT 1;
        IF FOUND THEN
            UPDATE memory.entity_edge
            SET invalidated_by = v_rep.uuid, invalid_at = coalesce(v_rep.valid_at, invalid_at), synced_at = now()
            WHERE uuid = r.uuid;
            repointed := repointed + 1;
            CONTINUE;
        END IF;

        SELECT c.uuid INTO v_twin
        FROM memory.entity_edge c
        WHERE c.source_uuid = r.source_uuid AND c.name = r.name AND c.negated = r.negated
          AND c.target_key = r.target_key AND c.invalid_at IS NULL AND c.uuid <> r.uuid
        LIMIT 1;
        IF FOUND THEN
            UPDATE memory.entity_edge c
            SET fact_ids = (SELECT array_agg(DISTINCT x ORDER BY x) FROM unnest(c.fact_ids || r.fact_ids) AS x),
                fact_text = CASE WHEN (coalesce(r.valid_at, '-infinity'), r.created_at)
                                > (coalesce(c.valid_at, '-infinity'), c.created_at) THEN r.fact_text
                                 ELSE c.fact_text END,
                valid_at = least(c.valid_at, r.valid_at), synced_at = now()
            WHERE c.uuid = v_twin;
            UPDATE memory.entity_edge SET invalidated_by = v_twin WHERE invalidated_by = r.uuid;
            DELETE FROM memory.entity_edge WHERE uuid = r.uuid;
            folded := folded + 1;
            CONTINUE;
        END IF;

        UPDATE memory.entity_edge
        SET invalid_at = NULL, expired_at = NULL, invalidated_by = NULL, synced_at = now()
        WHERE uuid = r.uuid;
        revalidated := revalidated + 1;
        -- Current again: the older or undated current statements it contradicts are invalidated by it (§14.5 step 3),
        -- never one that shares a fact with it.
        UPDATE memory.entity_edge c
        SET invalid_at = r.valid_at, expired_at = now(), invalidated_by = r.uuid, synced_at = now()
        FROM memory.graph_predicate p
        WHERE p.name = c.name AND c.source_uuid = r.source_uuid AND c.name = r.name AND c.invalid_at IS NULL
          AND c.uuid <> r.uuid AND NOT (c.fact_ids && r.fact_ids)
          AND r.valid_at IS NOT NULL AND (c.valid_at IS NULL OR c.valid_at < r.valid_at)
          AND ((p.single_valued AND NOT c.negated AND NOT r.negated AND c.target_key <> r.target_key
                AND memory.graph_single_valued_target(c.name, c.target_key)
                AND memory.graph_single_valued_target(r.name, r.target_key))
               OR (c.target_key = r.target_key AND c.negated <> r.negated));
    END LOOP;
END
$fn$;
REVOKE ALL ON FUNCTION memory.graph_repair_invalidated(uuid[]) FROM PUBLIC;

-- 0015's graph_merge_entities; the conflict rule applies the closed HAS_STATUS vocabulary (item 1) and the suggestion
-- loop skips events and expired facts (item 2) and proposes at most one suggestion per invalidated edge (item 3).
CREATE OR REPLACE FUNCTION memory.graph_merge_entities(p_keep uuid, p_drop uuid)
RETURNS TABLE (links_moved integer, aliases_moved integer, edges_moved integer, edges_folded integer,
               edges_dropped integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    r           record;
    w           record;
    c           record;
    v_src       uuid;
    v_tgt       uuid;
    v_twin      uuid;
    v_orphans   uuid[] := '{}'::uuid[];
    v_fix       record;
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
            -- The alias now carries this statement. What it had invalidated is repaired after the loop.
            SELECT v_orphans || coalesce(array_agg(e.uuid), '{}'::uuid[]) INTO v_orphans
            FROM memory.entity_edge e WHERE e.invalidated_by = r.uuid;
            DELETE FROM memory.entity_edge WHERE uuid = r.uuid;
            edges_dropped := edges_dropped + 1;
            CONTINUE;
        END IF;
        v_twin := NULL;
        IF r.invalid_at IS NULL THEN
            SELECT c2.uuid INTO v_twin
            FROM memory.entity_edge c2
            WHERE c2.source_uuid = v_src AND c2.name = r.name AND c2.negated = r.negated AND c2.invalid_at IS NULL
              AND c2.uuid <> r.uuid
              AND c2.target_key = coalesce('e:' || v_tgt::text, 'v:' || memory.graph_norm(r.target_value))
            LIMIT 1;
        END IF;
        IF v_twin IS NOT NULL THEN
            UPDATE memory.entity_edge c2
            SET fact_ids = (SELECT array_agg(DISTINCT x ORDER BY x) FROM unnest(c2.fact_ids || r.fact_ids) AS x),
                fact_text = CASE WHEN (coalesce(r.valid_at, '-infinity'), r.created_at)
                                > (coalesce(c2.valid_at, '-infinity'), c2.created_at) THEN r.fact_text
                                 ELSE c2.fact_text END,
                valid_at = least(c2.valid_at, r.valid_at), synced_at = now()
            WHERE c2.uuid = v_twin;
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

    IF cardinality(v_orphans) > 0 THEN
        SELECT * INTO v_fix FROM memory.graph_repair_invalidated(v_orphans);
    END IF;

    -- §14.5 over the kept entity's current statements: newest first, each still-current statement invalidates the
    -- older current ones of its (subject, predicate) that contradict it and share no fact with it (a fact never
    -- supersedes itself; for HAS_STATUS only lifecycle values take part in the single-valued rule), and at most one
    -- suggestion is proposed per invalidated edge, as Q-GRAPH-SUGGEST does: the most recent older fact that can still
    -- be superseded (current, not an event, valid_to unset or in the future) against the most recent live newer fact.
    -- As in graph_repair_invalidated, an undated statement never invalidates a dated one (so invalid_at >= valid_at).
    FOR r IN
        SELECT e.uuid FROM memory.entity_edge e
        WHERE e.invalid_at IS NULL AND (e.source_uuid = p_keep OR e.target_uuid = p_keep)
        ORDER BY e.valid_at DESC NULLS LAST, e.created_at DESC, e.uuid DESC
    LOOP
        SELECT e.* INTO w FROM memory.entity_edge e WHERE e.uuid = r.uuid;
        IF NOT FOUND OR w.invalid_at IS NOT NULL THEN
            CONTINUE;
        END IF;
        FOR c IN
            UPDATE memory.entity_edge c2
            SET invalid_at = coalesce(w.valid_at, now()), expired_at = now(), invalidated_by = w.uuid,
                synced_at = now()
            FROM memory.graph_predicate p
            WHERE p.name = c2.name AND c2.source_uuid = w.source_uuid AND c2.name = w.name
              AND c2.invalid_at IS NULL AND c2.uuid <> w.uuid AND NOT (c2.fact_ids && w.fact_ids)
              AND (c2.valid_at IS NULL OR c2.valid_at <= w.valid_at)
              AND ((p.single_valued AND NOT c2.negated AND NOT w.negated AND c2.target_key <> w.target_key
                    AND memory.graph_single_valued_target(c2.name, c2.target_key)
                    AND memory.graph_single_valued_target(w.name, w.target_key))
                   OR (c2.target_key = w.target_key AND c2.negated <> w.negated))
            RETURNING c2.uuid, c2.fact_ids, c2.target_value, (c2.target_key = w.target_key) AS flip
        LOOP
            INSERT INTO memory.supersession_suggestion (old_fact_id, new_fact_id, old_edge_uuid, new_edge_uuid, rule,
                                                        proposed_by, confidence)
            SELECT o.id, n.id, c.uuid, w.uuid,
                   CASE WHEN c.flip THEN 'polarity_flip'
                        WHEN c.target_value IS NOT NULL AND w.target_value IS NOT NULL THEN 'single_valued_value'
                        ELSE 'single_valued_entity' END,
                   'graph_merge_entities',
                   CASE WHEN NOT c.flip AND c.target_value IS NOT NULL AND w.target_value IS NOT NULL THEN 0.8
                        ELSE 0.5 END
            FROM (SELECT f.id FROM memory.fact f
                  WHERE f.id = ANY (c.fact_ids) AND NOT (f.id = ANY (w.fact_ids))
                    AND f.status IN ('active', 'canonical', 'draft') AND f.kind <> 'event'
                    AND (f.valid_to IS NULL OR f.valid_to > now())
                  ORDER BY f.valid_from DESC, f.recorded_at DESC, f.id DESC
                  LIMIT 1) o,
                 (SELECT f.id FROM memory.fact f
                  WHERE f.id = ANY (w.fact_ids) AND NOT (f.id = ANY (c.fact_ids))
                    AND f.status IN ('active', 'canonical', 'draft')
                  ORDER BY f.valid_from DESC, f.recorded_at DESC, f.id DESC
                  LIMIT 1) n
            WHERE NOT EXISTS (SELECT 1 FROM memory.supersession_suggestion x
                              WHERE x.old_fact_id = o.id AND x.new_fact_id = n.id AND x.state = 'rejected')
            ON CONFLICT (old_fact_id, new_fact_id) WHERE state IN ('pending', 'accepted') DO NOTHING;
        END LOOP;
    END LOOP;
    RETURN NEXT;
END
$fn$;

-- Grants as 0005 step 13, 0013 and 0015 (CREATE OR REPLACE keeps them; restated so a fresh database needs no order).
REVOKE ALL ON FUNCTION memory.graph_merge_entities(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION memory.graph_merge_entities(uuid, uuid) TO memory_gateway, memory_worker;
