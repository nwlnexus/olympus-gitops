-- 0018_supersession_judge: a model judge reads pending supersession suggestions before a person does
-- (olympus-sdk#968). The LLM worker stores the judge's verdict on the suggestion; when its auto-apply switch is on, it
-- also decides routine suggestions itself through the same accept/reject statements as the admin CLI, attributed to
-- the client `internal:judge`.
-- Contract: olympus-sdk docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md §3.6, §14.5, §14.14.
-- Idempotent; no BEGIN/COMMIT (the runner wraps it with --single-transaction). ADD COLUMN without a default does not
-- rewrite the table; the CHECKs and the partial index scan it once (a few thousand rows). lock_timeout bounds the wait
-- for the table lock (the runner's Job retries).
--
-- No grant changes: memory_worker already holds UPDATE on supersession_suggestion and fact and INSERT on audit_log
-- (0004, 0005), and memory_gateway UPDATE on both tables (the admin CLI's undo); table-level grants cover the new
-- columns. Apply before the worker and gateway images that read or write the columns.

SET LOCAL lock_timeout = '10s';

-- 1. The judge's verdict. NULL until judged. 'error' = the judge could not give a usable answer (the suggestion then
--    waits for a person, like 'unsure'). judge_model is `<prompt version>@<model>`.
ALTER TABLE memory.supersession_suggestion ADD COLUMN IF NOT EXISTS judge_verdict text;
ALTER TABLE memory.supersession_suggestion ADD COLUMN IF NOT EXISTS judge_reason text;
ALTER TABLE memory.supersession_suggestion ADD COLUMN IF NOT EXISTS judge_model text;
ALTER TABLE memory.supersession_suggestion ADD COLUMN IF NOT EXISTS judged_at timestamptz;

ALTER TABLE memory.supersession_suggestion DROP CONSTRAINT IF EXISTS supersession_judge_verdict_check;
ALTER TABLE memory.supersession_suggestion ADD CONSTRAINT supersession_judge_verdict_check CHECK (
    judge_verdict IS NULL OR judge_verdict IN ('accept', 'reject', 'unsure', 'error'));
ALTER TABLE memory.supersession_suggestion DROP CONSTRAINT IF EXISTS supersession_judge_reason_check;
ALTER TABLE memory.supersession_suggestion ADD CONSTRAINT supersession_judge_reason_check CHECK (
    judge_reason IS NULL OR length(judge_reason) <= 500);
ALTER TABLE memory.supersession_suggestion DROP CONSTRAINT IF EXISTS supersession_judge_model_check;
ALTER TABLE memory.supersession_suggestion ADD CONSTRAINT supersession_judge_model_check CHECK (
    judge_model IS NULL OR length(judge_model) BETWEEN 1 AND 100);
-- A verdict, its model and its time are written together.
ALTER TABLE memory.supersession_suggestion DROP CONSTRAINT IF EXISTS supersession_judge_consistent;
ALTER TABLE memory.supersession_suggestion ADD CONSTRAINT supersession_judge_consistent CHECK (
    (judged_at IS NULL) = (judge_verdict IS NULL) AND (judged_at IS NULL) = (judge_model IS NULL));

-- 2. What the judge reads next: pending suggestions without a verdict, oldest first.
CREATE INDEX IF NOT EXISTS supersession_unjudged_idx
    ON memory.supersession_suggestion (created_at, id) WHERE state = 'pending' AND judged_at IS NULL;

-- 3. The judge's client row: decided_by and audit_log.client_id of its decisions. Internal, no scopes (it never calls
--    the gateway API).
INSERT INTO memory.client (id, display_name, kind, scopes)
VALUES ('internal:judge', 'supersession judge (model decisions)', 'internal', '{}'::text[])
ON CONFLICT (id) DO NOTHING;
