-- =============================================================
-- 11_indexes.sql — Performance indexes
-- pgvector: IVFFlat for Docker / dev (HNSW for production)
-- =============================================================

-- ── agent_meta ────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_agent_meta_role_name
    ON alma_private.agent_meta (role_name);

CREATE INDEX IF NOT EXISTS idx_agent_meta_active
    ON alma_private.agent_meta (is_active)
    WHERE is_active = TRUE;

-- ── sessions ──────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_sessions_agent_id
    ON alma_private.sessions (agent_id);

CREATE INDEX IF NOT EXISTS idx_sessions_status
    ON alma_private.sessions (status);

CREATE INDEX IF NOT EXISTS idx_sessions_started_at
    ON alma_private.sessions (started_at DESC);

-- ── tasks ─────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_tasks_session_id
    ON alma_private.tasks (session_id);

CREATE INDEX IF NOT EXISTS idx_tasks_agent_status
    ON alma_private.tasks (agent_id, status);

-- ── execution_logs ────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_execution_logs_session_id
    ON alma_private.execution_logs (session_id);

CREATE INDEX IF NOT EXISTS idx_execution_logs_agent_id
    ON alma_private.execution_logs (agent_id);

CREATE INDEX IF NOT EXISTS idx_execution_logs_executed_at
    ON alma_private.execution_logs (executed_at DESC);

-- ── memory ────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_memory_agent_id
    ON alma_private.memory (agent_id);

CREATE INDEX IF NOT EXISTS idx_memory_importance
    ON alma_private.memory (agent_id, importance DESC);

-- pgvector IVFFlat index (Docker / dev environment)
-- Requires: at least 1 row inserted before CREATE INDEX
-- For production, replace with HNSW:
--   CREATE INDEX idx_memory_embedding_hnsw ON alma_private.memory
--   USING hnsw (embedding vector_cosine_ops)
--   WITH (m = 16, ef_construction = 64);
--
-- IVFFlat: faster to build, good for datasets < 1M rows
CREATE INDEX IF NOT EXISTS idx_memory_embedding_ivfflat
    ON alma_private.memory
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);

-- ── memory access pattern ─────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_memory_accessed_at
    ON alma_private.memory (agent_id, accessed_at DESC);

-- ── agent_messages ────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_agent_messages_session_id
    ON alma_private.agent_messages (session_id);

-- ── experiment_results ────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_experiment_results_exp_id
    ON alma_private.experiment_results (experiment_id);
