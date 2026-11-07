-- 0012_recall_usage: usage-labelled live recall evaluation (olympus-sdk#666).
-- An injection log of what recall showed (the denominator) and, per shown fact, whether the session used it.
-- Privacy: ids, ranks, flags and a sha256 of the recall query only; no transcript or query text.
--   recall_injection       one row per rendering: session start (REST, the hook passes the session id) or recall
--                          (MCP tool or REST query; Claude Code sends no session id over MCP, so the gateway binds the
--                          row to a session later from the captured transcript: query hash + tool call time window).
--   recall_injection_fact  one row per fact shown, with its 1-based rank; `used` is set by the capture path when a
--                          later assistant turn of the same session echoes the fact id or its distinctive content.
-- Idempotent; no BEGIN/COMMIT (the runner wraps it with --single-transaction).

CREATE TABLE IF NOT EXISTS memory.recall_injection (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    surface     text NOT NULL CHECK (surface IN ('session_start', 'recall')),
    session_id  text CHECK (session_id IS NULL OR length(session_id) BETWEEN 1 AND 128),
    client_id   text NOT NULL,
    project     text,
    query_hash  text CHECK (query_hash IS NULL OR query_hash ~ '^[0-9a-f]{64}$'),
    shown_at    timestamptz NOT NULL DEFAULT now(),
    fact_count  integer NOT NULL CHECK (fact_count >= 0),
    bound_at    timestamptz
);
CREATE INDEX IF NOT EXISTS recall_injection_session_idx ON memory.recall_injection (session_id, shown_at)
    WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS recall_injection_unbound_idx ON memory.recall_injection (query_hash, shown_at)
    WHERE session_id IS NULL;
CREATE INDEX IF NOT EXISTS recall_injection_shown_at_idx ON memory.recall_injection (shown_at);

CREATE TABLE IF NOT EXISTS memory.recall_injection_fact (
    injection_id uuid NOT NULL REFERENCES memory.recall_injection (id) ON DELETE CASCADE,
    fact_id      uuid NOT NULL REFERENCES memory.fact (id) ON DELETE CASCADE,
    rank         smallint NOT NULL CHECK (rank >= 1),
    used         boolean NOT NULL DEFAULT false,
    used_at      timestamptz,
    used_via     text CHECK (used_via IS NULL OR used_via IN ('id', 'content')),
    PRIMARY KEY (injection_id, fact_id)
);
CREATE INDEX IF NOT EXISTS recall_injection_fact_fact_idx ON memory.recall_injection_fact (fact_id);

GRANT SELECT, INSERT, UPDATE ON memory.recall_injection, memory.recall_injection_fact TO memory_gateway;
GRANT SELECT ON memory.recall_injection, memory.recall_injection_fact TO memory_worker;
