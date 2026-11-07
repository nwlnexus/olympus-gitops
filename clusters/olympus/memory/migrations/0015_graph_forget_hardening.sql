-- 0015_graph_forget_hardening: the graph functions of 0013, hardened after the R1 review (olympus-sdk#518; issues
-- olympus-sdk#804 and #807).
-- Contract: olympus-sdk docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md §10.3, §14.4, §14.5.
-- Idempotent (CREATE OR REPLACE, the 0005/0013 signatures and grants are kept); no BEGIN/COMMIT (the runner wraps it
-- with --single-transaction). No table is altered and no row is rewritten, so it is safe to apply while the gateway
-- and the workers write: replacing a function takes no lock a running call holds, and a call that already started
-- finishes on the old body. lock_timeout bounds any wait on the catalog (the runner's Job retries).
--
-- What changes:
-- 1. (#804, privacy) A shared edge that loses the forgotten fact no longer keeps that fact's sentence: its fact_text
--    becomes the neutral rendering `source RELATION target` (as recall and `entity` render the relation columns; the
--    edge does not record which fact wrote the sentence, so every shared edge gets it). When the forget renames an
--    entity (its canonical name was only the forgotten fact's wording), neutral sentences that carry the old name are
--    rendered again with the new one.
-- 2. (#807 item 2) graph_detach_fact refuses (42501) a fact that is not forgotten when the caller is the gateway
--    role. The gateway only detaches inside its forget transaction, after Q-FORGET-FACT; the worker still detaches
--    current facts (re-extraction after append), and so may a superuser.
-- 3. (#807 item 1) graph_merge_entities applies the §14.5 conflict rule to the kept entity's current statements after
--    the move: per (subject, predicate), the newest current statement (valid_at, then created_at) invalidates the
--    older current ones it contradicts and that share no fact with it, and a pending suggestion is proposed for each
--    pair of live facts (never a pair that was rejected). Before, `Y RUNS_ON Z` and the moved `Y RUNS_ON S` both
--    stayed current.
-- 4. (#807 item 4) A fold (graph_repair_invalidated, graph_merge_entities) keeps the newer statement's sentence.

SET LOCAL lock_timeout = '5s';

-- The neutral sentence of a relation: subject, predicate (NOT_<PREDICATE> when negated), object, as Q-EXPAND-EDGES
-- and Q-ENTITY-RELATIONS render the columns. Called only by graph_detach_fact.
CREATE OR REPLACE FUNCTION memory.graph_neutral_sentence(p_source text, p_name text, p_negated boolean,
                                                         p_target text)
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
RETURN coalesce(p_source, '?') || ' ' || CASE WHEN p_negated THEN 'NOT_' || p_name ELSE p_name END || ' '
       || coalesce(p_target, '?');
REVOKE ALL ON FUNCTION memory.graph_neutral_sentence(text, text, boolean, text) FROM PUBLIC;

-- 0013's helper; the fold keeps the newer statement's sentence (item 4).
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
          AND ((p.single_valued AND NOT c.negated AND NOT r.negated AND c.target_key <> r.target_key)
               OR (c.target_key = r.target_key AND c.negated <> r.negated));
    END LOOP;
END
$fn$;
REVOKE ALL ON FUNCTION memory.graph_repair_invalidated(uuid[]) FROM PUBLIC;

-- 0013's graph_detach_fact with the gateway guard (item 2), the neutral sentence of a shared edge (step 5) and the
-- re-rendering of neutral sentences on a rename (step 9).
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
    v_caller    text;
BEGIN
    links_deleted := 0; edges_deleted := 0; edges_revalidated := 0; edges_repointed := 0; edges_folded := 0;
    aliases_deleted := 0; entities_deleted := 0; entities_renamed := 0; suggestions_deleted := 0;

    PERFORM pg_advisory_xact_lock(20261021, 1);

    -- (0) The gateway detaches a fact only once it is forgotten (its forget transaction runs Q-FORGET-FACT first).
    --     The caller is the role the session acts as: SECURITY DEFINER changes current_user, not the `role` setting
    --     (SET ROLE) nor session_user.
    v_caller := CASE WHEN current_setting('role') = 'none' THEN session_user::text ELSE current_setting('role') END;
    IF v_caller = 'memory_gateway'
       AND NOT EXISTS (SELECT 1 FROM memory.fact f WHERE f.id = p_fact AND f.status = 'forgotten') THEN
        RAISE EXCEPTION 'graph_detach_fact: the gateway detaches only a forgotten fact (%)', p_fact
            USING ERRCODE = '42501';
    END IF;

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

    -- (4) Delete the edges only this fact supported; (5) shared edges lose it from their support, and its sentence:
    --     the edge does not record which fact wrote fact_text, so the neutral rendering replaces it (§10.3).
    DELETE FROM memory.entity_edge WHERE uuid = ANY (v_dead);
    GET DIAGNOSTICS edges_deleted = ROW_COUNT;
    UPDATE memory.entity_edge ee
    SET fact_ids = array_remove(ee.fact_ids, p_fact),
        fact_text = memory.graph_neutral_sentence(
            (SELECT s.name FROM memory.entity s WHERE s.uuid = ee.source_uuid), ee.name, ee.negated,
            coalesce((SELECT t.name FROM memory.entity t WHERE t.uuid = ee.target_uuid), ee.target_value)),
        synced_at = now()
    WHERE ee.fact_ids @> ARRAY[p_fact];

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
    --     Neutral sentences that carry the old name (this step 5, or an earlier forget's) are rendered with the new.
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
            UPDATE memory.entity_edge ee
            SET fact_text = memory.graph_neutral_sentence(
                    CASE WHEN ee.source_uuid = r.entity_uuid THEN v_alias.alias ELSE n.source_name END, ee.name,
                    ee.negated,
                    CASE WHEN ee.target_uuid = r.entity_uuid THEN v_alias.alias ELSE n.target_name END),
                synced_at = now()
            FROM (SELECT e2.uuid,
                         (SELECT s.name FROM memory.entity s WHERE s.uuid = e2.source_uuid) AS source_name,
                         coalesce((SELECT t.name FROM memory.entity t WHERE t.uuid = e2.target_uuid),
                                  e2.target_value) AS target_name
                  FROM memory.entity_edge e2
                  WHERE e2.source_uuid = r.entity_uuid OR e2.target_uuid = r.entity_uuid) n
            WHERE ee.uuid = n.uuid
              AND ee.fact_text = memory.graph_neutral_sentence(n.source_name, ee.name, ee.negated, n.target_name);
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

-- 0013's graph_merge_entities; the fold keeps the newer sentence (item 4) and the kept entity's current statements
-- go through the §14.5 conflict rule at the end (item 1).
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
    -- supersedes itself), and a suggestion is proposed for each pair of live facts, as the write rule would have.
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
              AND ((p.single_valued AND NOT c2.negated AND NOT w.negated AND c2.target_key <> w.target_key)
                   OR (c2.target_key = w.target_key AND c2.negated <> w.negated))
            RETURNING c2.uuid, c2.fact_ids, c2.target_value, (c2.target_key = w.target_key) AS flip
        LOOP
            INSERT INTO memory.supersession_suggestion (old_fact_id, new_fact_id, old_edge_uuid, new_edge_uuid, rule,
                                                        proposed_by, confidence)
            SELECT o, n, c.uuid, w.uuid,
                   CASE WHEN c.flip THEN 'polarity_flip'
                        WHEN c.target_value IS NOT NULL AND w.target_value IS NOT NULL THEN 'single_valued_value'
                        ELSE 'single_valued_entity' END,
                   'graph_merge_entities',
                   CASE WHEN NOT c.flip AND c.target_value IS NOT NULL AND w.target_value IS NOT NULL THEN 0.8
                        ELSE 0.5 END
            FROM unnest(c.fact_ids) AS o, unnest(w.fact_ids) AS n
            WHERE o <> n
              AND EXISTS (SELECT 1 FROM memory.fact f WHERE f.id = o AND f.status IN ('active', 'canonical', 'draft'))
              AND EXISTS (SELECT 1 FROM memory.fact f WHERE f.id = n AND f.status IN ('active', 'canonical', 'draft'))
              AND NOT EXISTS (SELECT 1 FROM memory.supersession_suggestion x
                              WHERE x.old_fact_id = o AND x.new_fact_id = n AND x.state = 'rejected')
            ON CONFLICT (old_fact_id, new_fact_id) WHERE state IN ('pending', 'accepted') DO NOTHING;
        END LOOP;
    END LOOP;
    RETURN NEXT;
END
$fn$;

-- Grants as 0005 step 13 and 0013 (CREATE OR REPLACE keeps them; restated so a fresh database needs no order).
REVOKE ALL ON FUNCTION memory.graph_detach_fact(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION memory.graph_merge_entities(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION memory.graph_detach_fact(uuid) TO memory_gateway, memory_worker;
GRANT EXECUTE ON FUNCTION memory.graph_merge_entities(uuid, uuid) TO memory_gateway, memory_worker;
