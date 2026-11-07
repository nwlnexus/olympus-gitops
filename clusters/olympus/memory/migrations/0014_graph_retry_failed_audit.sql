-- 0014_graph_retry_failed_audit: the audit action of `memory-admin graph retry-failed` (olympus-sdk#519, task G13).
-- Contract: olympus-sdk docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md §14.14 Q-GRAPH-RETRY-FAILED.
-- One audit row per fact made eligible for the backfill again (target_kind 'fact'). Not in 0006: on a fresh database
-- 0006 runs before 0011, which re-asserts the action list and would drop the new action again.
-- The list is 0011's union plus the new action. Idempotent; no BEGIN/COMMIT (the runner wraps it with
-- --single-transaction).

ALTER TABLE memory.audit_log DROP CONSTRAINT IF EXISTS audit_log_action_check;
ALTER TABLE memory.audit_log ADD CONSTRAINT audit_log_action_check CHECK (action IN
    ('forget', 'restore', 'purge', 'set_status', 'append', 'client_create', 'client_revoke', 'requeue_dead',
     'suggest_closed', 'supersession_accept', 'supersession_reject', 'entity_merge', 'worker_pause', 'worker_resume',
     'graph_retry_failed'));
