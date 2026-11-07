-- 0010_fact_extract_provenance: which extractor wrote a fact (olympus-sdk#672).
-- Contract: olympus-sdk docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md §3.2 (memory.fact) and §6.1
-- (Fact.provenance.extractor). The extract worker used to record its model and prompt version only in
-- episode.metadata.extract, which names the LAST extraction of the episode; a re-extraction that deduplicated against
-- an older fact left the older fact with the wrong answer. The worker now writes both onto each fact it inserts, so a
-- fact row alone answers "which model and which prompt made this". Facts written before this migration, and every
-- fact that is not extracted (remember, import, capture), have both columns NULL.
-- Additive: the running gateway and workers ignore the columns; the new ones need them, so this applies first.
-- Idempotent; no BEGIN/COMMIT (the runner wraps it with --single-transaction).

ALTER TABLE memory.fact ADD COLUMN IF NOT EXISTS extract_model text;
ALTER TABLE memory.fact ADD COLUMN IF NOT EXISTS extract_prompt_version text;

ALTER TABLE memory.fact DROP CONSTRAINT IF EXISTS fact_extract_provenance_check;
ALTER TABLE memory.fact ADD CONSTRAINT fact_extract_provenance_check CHECK (
    (extract_model IS NULL) = (extract_prompt_version IS NULL)
    AND (extract_model IS NULL OR (length(extract_model) BETWEEN 1 AND 200 AND length(extract_prompt_version) BETWEEN 1 AND 100))
);
