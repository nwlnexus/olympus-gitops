-- 0004_roles: least-privilege login roles for the gateway and the workers.
-- Passwords are NOT set here (migrations are in git). The migrate Job sets them from the
-- Secret after the last migration (§12, task G0). Until then the roles cannot log in.
-- Idempotent; no BEGIN/COMMIT.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'memory_gateway') THEN
        CREATE ROLE memory_gateway LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'memory_worker') THEN
        CREATE ROLE memory_worker LOGIN;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA memory TO memory_gateway, memory_worker;

-- Gateway: reads everything it serves; writes captures, remembers, appends, status,
-- forgets (soft) and the audit trail; enqueues jobs. No DELETE anywhere except the
-- embedding and fact_entity rows that forget removes synchronously (§10.3).
GRANT SELECT ON ALL TABLES IN SCHEMA memory TO memory_gateway;
GRANT INSERT, UPDATE ON memory.client, memory.episode, memory.fact, memory.fact_revision,
                        memory.import_ledger, memory.capture_queue TO memory_gateway;
GRANT INSERT ON memory.audit_log TO memory_gateway;
GRANT DELETE ON memory.fact_embedding, memory.fact_entity TO memory_gateway;

-- Workers: claim and complete jobs, write facts/embeddings and the graph mirror,
-- purge forgotten content.
GRANT SELECT ON ALL TABLES IN SCHEMA memory TO memory_worker;
GRANT INSERT, UPDATE ON memory.episode, memory.fact, memory.fact_revision, memory.capture_queue,
                        memory.fact_embedding, memory.fact_graph_episode,
                        memory.entity, memory.entity_edge, memory.fact_entity TO memory_worker;
GRANT DELETE ON memory.capture_queue, memory.fact_embedding, memory.fact_graph_episode,
                memory.entity, memory.entity_edge, memory.fact_entity, memory.fact_revision TO memory_worker;
GRANT INSERT ON memory.audit_log TO memory_worker;

GRANT USAGE ON ALL SEQUENCES IN SCHEMA memory TO memory_gateway, memory_worker;
REVOKE ALL ON memory.schema_migrations FROM memory_gateway, memory_worker;
