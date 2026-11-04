-- 0009_closure_suggestion: a to-do that a newer fact probably finished (olympus-sdk#726).
-- Contract: olympus-sdk docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md §8.4 (closure of
-- finished to-dos). The extract worker sets `possibly_closed_by` on an active or draft to-do when the extractor's
-- closure mark and the text rule agree that a newer event/fact closed the issue the to-do is about; session start then
-- shows the to-do as "possibly done" instead of as open work. The to-do's status does not change. Every suggestion is
-- audited with the new action `suggest_closed`.
-- Idempotent; no BEGIN/COMMIT (the runner wraps it with --single-transaction).

ALTER TABLE memory.fact ADD COLUMN IF NOT EXISTS possibly_closed_by uuid REFERENCES memory.fact (id);
CREATE INDEX IF NOT EXISTS fact_possibly_closed_by_idx ON memory.fact (possibly_closed_by)
    WHERE possibly_closed_by IS NOT NULL;

ALTER TABLE memory.audit_log DROP CONSTRAINT IF EXISTS audit_log_action_check;
ALTER TABLE memory.audit_log ADD CONSTRAINT audit_log_action_check CHECK (action IN
    ('forget', 'restore', 'purge', 'set_status', 'append',
     'client_create', 'client_revoke', 'requeue_dead', 'suggest_closed'));
