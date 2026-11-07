-- 0011_audit_actions_union: the audit action list after both 0005 (graph admin actions) and 0009 (suggest_closed).
-- Contract: olympus-sdk docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md §3.6 step 9 and §8.4.
-- Why: 0009 replaces audit_log_action_check with a list that predates 0005's actions. On a fresh database the files
-- run in filename order (0005 before 0009), so 0009 would drop supersession_accept, supersession_reject, entity_merge,
-- worker_pause and worker_resume. This file restores the union; on the cluster (0009 applied before 0005) it is a no-op
-- restatement. Applied migrations are immutable, so this fixes forward instead of editing 0009.
-- Idempotent; no BEGIN/COMMIT (the runner wraps it with --single-transaction).

ALTER TABLE memory.audit_log DROP CONSTRAINT IF EXISTS audit_log_action_check;
ALTER TABLE memory.audit_log ADD CONSTRAINT audit_log_action_check CHECK (action IN
    ('forget', 'restore', 'purge', 'set_status', 'append', 'client_create', 'client_revoke', 'requeue_dead',
     'suggest_closed', 'supersession_accept', 'supersession_reject', 'entity_merge', 'worker_pause', 'worker_resume'));
