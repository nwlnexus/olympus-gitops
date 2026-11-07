-- 0006_graph_cleanup: remove what the Postgres graph (0005) left inert.
-- Contract: olympus-sdk docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md §14.10 step 4 (task P2,
-- olympus-sdk#519). Runs after 0012 on the cluster (the runner skips versions already applied and applies files in
-- lexical order, so a later 0006 still applies); on a fresh database it runs between 0005 and 0007.
-- Idempotent; no BEGIN/COMMIT (the runner wraps it with --single-transaction).

-- 1. Legacy graph_forget jobs. The gateway stopped enqueuing them with G12 (olympus-sdk#514); the worker drained them.
--    Any job not done yet gets the drain's effect here (detach the graph of a fact that is still forgotten), then
--    every graph_forget row goes, so the narrowed CHECKs below hold for every row.
SELECT d.*
FROM (SELECT DISTINCT q.fact_id
      FROM memory.capture_queue q
      JOIN memory.fact f ON f.id = q.fact_id
      WHERE q.stage = 'graph_forget' AND q.state <> 'done' AND f.status = 'forgotten') j,
     LATERAL memory.graph_detach_fact(j.fact_id) d;
DELETE FROM memory.capture_queue WHERE stage = 'graph_forget';

-- 2. The queue knows three stages.
ALTER TABLE memory.capture_queue DROP CONSTRAINT IF EXISTS capture_queue_stage_check;
ALTER TABLE memory.capture_queue ADD CONSTRAINT capture_queue_stage_check
    CHECK (stage IN ('extract', 'embed', 'graph_ingest'));
ALTER TABLE memory.capture_queue DROP CONSTRAINT IF EXISTS capture_queue_target;
ALTER TABLE memory.capture_queue ADD CONSTRAINT capture_queue_target CHECK (
    (stage = 'extract' AND episode_id IS NOT NULL) OR
    (stage IN ('embed', 'graph_ingest') AND fact_id IS NOT NULL)
);

-- 3. The Graphiti episode map (inert since 0005; its grants go with it).
DROP TABLE IF EXISTS memory.fact_graph_episode;

-- 4. entity_alias (alias_norm, 0005) replaced the lower(name) lookup; nothing reads this index.
DROP INDEX IF EXISTS memory.entity_name_lower_idx;
