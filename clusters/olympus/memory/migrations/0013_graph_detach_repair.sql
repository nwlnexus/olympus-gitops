-- 0013_graph_detach_repair: repairs to the two graph functions of 0005, from the R1 review (olympus-sdk#518).
-- Contract: olympus-sdk docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md §3.6 (amended 2026-11-07).
-- Idempotent (CREATE OR REPLACE, the 0005 signatures are kept); no BEGIN/COMMIT (the runner wraps it with
-- --single-transaction).
--
-- What was wrong in 0005:
-- 1. graph_detach_fact made an edge current again while a dying edge with the same identity still existed (the dead
--    edges were deleted after the repair loop): entity_edge_current_uq raised 23505 and the gateway's forget
--    transaction aborted, so the fact could not be forgotten (and graph_ingest could not re-run on it). A fact that
--    states "S runs on Y and X" after an older "S runs on X" is enough.
-- 2. The statement a dying edge's victim was re-pointed to could share a fact with it (§14.5: a fact never supersedes
--    itself), so a fact ended up invalidating its own other relation.
-- 3. An edge made current again did not invalidate the older current statements it contradicts, as its own write
--    would have (§14.5 step 3), leaving two contradicting current statements.
-- 4. graph_merge_entities dropped a self-edge without repairing the edges it had invalidated: they stayed invalid with
--    invalidated_by NULL (the FK), beyond the reach of any later forget.
-- The repair of edges whose invalidating statement is gone is now one helper, called by both functions after the dead
-- edges are deleted (the edges to repair are remembered first: the FK nulls their pointer).

-- Edges whose invalidating statement no longer exists, newest first: re-point each to another current contradicting
-- statement that shares no fact with it, fold it into an identical current one, or make it current again and
-- invalidate the older (or undated) current statements it contradicts. Runs with the caller's rights inside the two
-- SECURITY DEFINER functions; nothing else calls it.
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
          AND ((p.single_valued AND NOT c.negated AND NOT r.negated AND c.target_key <> r.target_key)
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
          AND ((p.single_valued AND NOT c.negated AND NOT r.negated AND c.target_key <> r.target_key)
               OR (c.target_key = r.target_key AND c.negated <> r.negated));
    END LOOP;
END
$fn$;
REVOKE ALL ON FUNCTION memory.graph_repair_invalidated(uuid[]) FROM PUBLIC;

-- 0005 step 10, amended: dead edges go before the repair; the repair is the helper above.
CREATE OR REPLACE FUNCTION memory.graph_detach_fact(p_fact uuid)
RETURNS TABLE (links_deleted integer, edges_deleted integer, edges_revalidated integer, edges_repointed integer,
               edges_folded integer, aliases_deleted integer, entities_deleted integer, entities_renamed integer,
               suggestions_deleted integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_dead      uuid[];
    v_orphans   uuid[];
    v_entities  uuid[];
    v_fix       record;
    r           record;
    v_alias     record;
BEGIN
    links_deleted := 0; edges_deleted := 0; edges_revalidated := 0; edges_repointed := 0; edges_folded := 0;
    aliases_deleted := 0; entities_deleted := 0; entities_renamed := 0; suggestions_deleted := 0;

    PERFORM pg_advisory_xact_lock(20261021, 1);

    -- (1) Pending suggestions that name the fact. Decided ones hold ids only and stay as the decision record.
    DELETE FROM memory.supersession_suggestion s
    WHERE s.state = 'pending' AND (s.old_fact_id = p_fact OR s.new_fact_id = p_fact);
    GET DIAGNOSTICS suggestions_deleted = ROW_COUNT;

    -- (2) Edges this fact alone supports, and (3) the edges they had invalidated, remembered before the delete
    --     nulls the pointer.
    SELECT coalesce(array_agg(e.uuid), '{}'::uuid[]) INTO v_dead
    FROM memory.entity_edge e
    WHERE e.fact_ids @> ARRAY[p_fact] AND e.fact_ids <@ ARRAY[p_fact];
    SELECT coalesce(array_agg(e.uuid), '{}'::uuid[]) INTO v_orphans
    FROM memory.entity_edge e
    WHERE e.invalidated_by = ANY (v_dead) AND NOT (e.uuid = ANY (v_dead));

    -- (4) Delete the edges only this fact supported; (5) shared edges lose it from their support.
    DELETE FROM memory.entity_edge WHERE uuid = ANY (v_dead);
    GET DIAGNOSTICS edges_deleted = ROW_COUNT;
    UPDATE memory.entity_edge SET fact_ids = array_remove(fact_ids, p_fact), synced_at = now()
    WHERE fact_ids @> ARRAY[p_fact];

    -- (3) Repair the edges the dead ones had invalidated (after the delete, so a revived edge never collides with a
    --     dying twin; after (5), so the support test sees the fact gone).
    SELECT * INTO v_fix FROM memory.graph_repair_invalidated(v_orphans);
    edges_repointed := v_fix.repointed; edges_folded := v_fix.folded; edges_revalidated := v_fix.revalidated;

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

-- 0005 step 11, amended: a dropped self-edge's victims are repaired once every edge has moved to p_keep.
CREATE OR REPLACE FUNCTION memory.graph_merge_entities(p_keep uuid, p_drop uuid)
RETURNS TABLE (links_moved integer, aliases_moved integer, edges_moved integer, edges_folded integer,
               edges_dropped integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    r           record;
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

    IF cardinality(v_orphans) > 0 THEN
        SELECT * INTO v_fix FROM memory.graph_repair_invalidated(v_orphans);
    END IF;
    RETURN NEXT;
END
$fn$;

-- Grants as 0005 step 13 (CREATE OR REPLACE keeps them; restated so a fresh database needs no order).
REVOKE ALL ON FUNCTION memory.graph_detach_fact(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION memory.graph_merge_entities(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION memory.graph_detach_fact(uuid) TO memory_gateway, memory_worker;
GRANT EXECUTE ON FUNCTION memory.graph_merge_entities(uuid, uuid) TO memory_gateway, memory_worker;
