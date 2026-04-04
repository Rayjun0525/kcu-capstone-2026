-- ALMA Core Schema: Tables
-- Provides the audit infrastructure for comparing Group A (Claude+MCP) vs Group B (ALMA)

CREATE SCHEMA IF NOT EXISTS alma;

-- ─────────────────────────────────────────────
-- agents: registry of experiment agents (Group A / B)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS alma.agents (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    group_label  CHAR(1)     NOT NULL CHECK (group_label IN ('A', 'B')),
    model_id     TEXT        NOT NULL,
    temperature  NUMERIC(3,2) NOT NULL DEFAULT 0.0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE alma.agents IS
    'Registry of experiment agents. group_label A = Claude+MCP baseline, B = ALMA.';

-- ─────────────────────────────────────────────
-- sessions: one session per scenario execution
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS alma.sessions (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id        UUID        NOT NULL REFERENCES alma.agents(id),
    scenario_id     TEXT        NOT NULL,   -- S1 ~ S5
    scenario_index  INT         NOT NULL,   -- ordinal within the scenario batch
    status          TEXT        NOT NULL DEFAULT 'active'
                                CHECK (status IN ('active', 'completed', 'failed')),
    conversation    JSONB       NOT NULL DEFAULT '[]',
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ended_at        TIMESTAMPTZ
);

COMMENT ON TABLE alma.sessions IS
    'One session per (agent, scenario item). conversation stores the full message history as JSONB.';

-- ─────────────────────────────────────────────
-- tasks: individual SQL execution requests from the LLM
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS alma.tasks (
    id               UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id       UUID    NOT NULL REFERENCES alma.sessions(id),
    sql_text         TEXT    NOT NULL,
    sql_type         TEXT    CHECK (sql_type IN (
                                 'SELECT', 'INSERT', 'UPDATE', 'DELETE',
                                 'DROP', 'TRUNCATE', 'DDL', 'UNKNOWN')),
    is_irreversible  BOOLEAN NOT NULL DEFAULT FALSE,
    status           TEXT    NOT NULL DEFAULT 'pending'
                             CHECK (status IN (
                                 'pending', 'approved', 'blocked',
                                 'executed', 'rolled_back', 'error')),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE alma.tasks IS
    'Each SQL the LLM wants to run becomes a task. '
    'is_irreversible=TRUE triggers the approval gate in Group B.';

-- ─────────────────────────────────────────────
-- execution_logs: audit log of actual DB interactions
-- NOTE: In Group B, rolled-back executions are NOT recorded here.
--       fn_checkpoint detects the gap and forces a replan. (V4 guarantee)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS alma.execution_logs (
    id            UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id       UUID    NOT NULL REFERENCES alma.tasks(id),
    session_id    UUID    NOT NULL REFERENCES alma.sessions(id),
    group_label   CHAR(1) NOT NULL CHECK (group_label IN ('A', 'B')),
    sql_text      TEXT    NOT NULL,
    outcome       TEXT    NOT NULL
                          CHECK (outcome IN ('success', 'error', 'blocked', 'rolled_back')),
    error_message TEXT,
    duration_ms   INT,
    executed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE alma.execution_logs IS
    'Audit trail. Group B omits rolled_back entries so fn_checkpoint can detect inconsistency.';

CREATE INDEX IF NOT EXISTS idx_execution_logs_session
    ON alma.execution_logs (session_id, executed_at DESC);

CREATE INDEX IF NOT EXISTS idx_execution_logs_outcome
    ON alma.execution_logs (group_label, outcome);

-- ─────────────────────────────────────────────
-- approval_requests: queue for irreversible SQL awaiting human approval
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS alma.approval_requests (
    id           UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id      UUID    NOT NULL REFERENCES alma.tasks(id),
    status       TEXT    NOT NULL DEFAULT 'pending'
                         CHECK (status IN ('pending', 'approved', 'denied', 'timeout')),
    requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at  TIMESTAMPTZ
);

COMMENT ON TABLE alma.approval_requests IS
    'Irreversible SQL waits here for approval. '
    'The approval_worker listens via pg_notify and resolves within a timeout.';

CREATE INDEX IF NOT EXISTS idx_approval_requests_pending
    ON alma.approval_requests (status) WHERE status = 'pending';
