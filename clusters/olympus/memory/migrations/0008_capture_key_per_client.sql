-- 0008_capture_key_per_client: the transcript-capture idempotency key becomes (client_id, session_id, seq)
-- (olympus-sdk#503, item 1; contract design §3.2 and §4).
-- 0002 made the key global: (session_id, seq). A write-scoped client that knew or guessed another client's
-- session_id could post a slice at the same seq first, and the owner's later slice for that (session_id, seq)
-- answered "200 duplicate" and was dropped. Scoping the key by client_id means a client can only ever collide with
-- itself: a retry by the same client is still a duplicate, another client's slice is a separate episode.
-- Safe on live data: the new key is strictly weaker than the old one (it adds a column), so every existing row
-- satisfies it. The old unique index is dropped after the new one exists, in the same transaction.
-- episode_session_idx (session_id, seq), the non-unique lookup index from 0002, is kept: it still serves
-- session-only lookups (recall by session, admin repair) across clients.
-- 0002 is not edited (applied migrations are immutable); this file supersedes its episode_session_seq_uq.
-- Idempotent; no BEGIN/COMMIT (the runner wraps it with --single-transaction).

CREATE UNIQUE INDEX IF NOT EXISTS episode_client_session_seq_uq
    ON memory.episode (client_id, session_id, seq) WHERE session_id IS NOT NULL AND seq IS NOT NULL;

DROP INDEX IF EXISTS memory.episode_session_seq_uq;
