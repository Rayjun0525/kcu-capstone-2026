-- =============================================================
-- 04_tables.sql — All tables in alma_private
-- =============================================================

-- -------------------------------------------------------------
-- llm_configs: LLM model configuration (normalized)
-- -------------------------------------------------------------
CREATE TABLE alma_private.llm_configs (
    llm_config_id   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    provider        alma_private.llm_provider NOT NULL,
    endpoint        TEXT        NOT NULL,
    model_name      TEXT        NOT NULL,
    api_key_ref     TEXT,                   -- env var name only, never the key itself
    temperature     NUMERIC(4,3) DEFAULT 0.0 CHECK (temperature BETWEEN 0 AND 2),
    max_tokens      INT         DEFAULT 2048,
    request_options JSONB       DEFAULT '{}',
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON COLUMN alma_private.llm_configs.api_key_ref IS
    'Environment variable name (e.g. ANTHROPIC_API_KEY). Never store the key itself.';

-- -------------------------------------------------------------
-- agent_profiles: Agent behavior profile (SOUL.md equivalent)
-- -------------------------------------------------------------
CREATE TABLE alma_private.agent_profiles (
    profile_id      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT        NOT NULL,
    system_prompt   TEXT        NOT NULL,
    max_steps       INT         DEFAULT 10,
    max_retries     INT         DEFAULT 3,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- -------------------------------------------------------------
-- agent_meta: Agent identity (role_name = PostgreSQL Role)
-- -------------------------------------------------------------
CREATE TABLE alma_private.agent_meta (
    agent_id        UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    role_name       TEXT        NOT NULL UNIQUE,  -- mirrors pg_roles.rolname
    display_name    TEXT        NOT NULL,
    agent_role      alma_private.agent_role NOT NULL DEFAULT 'executor',
    llm_config_id   UUID        REFERENCES alma_private.llm_configs(llm_config_id),
    profile_id      UUID        REFERENCES alma_private.agent_profiles(profile_id),
    is_active       BOOLEAN     DEFAULT TRUE,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON COLUMN alma_private.agent_meta.role_name IS
    'Matches a PostgreSQL login role. Connection account IS the agent identity.';

-- -------------------------------------------------------------
-- agent_profile_assignments: Role <-> Profile mapping
-- -------------------------------------------------------------
CREATE TABLE alma_private.agent_profile_assignments (
    assignment_id   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id        UUID        NOT NULL REFERENCES alma_private.agent_meta(agent_id) ON DELETE CASCADE,
    profile_id      UUID        NOT NULL REFERENCES alma_private.agent_profiles(profile_id),
    assigned_at     TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (agent_id, profile_id)
);

-- -------------------------------------------------------------
-- sessions: Execution unit (one task prompt = one session)
-- -------------------------------------------------------------
CREATE TABLE alma_private.sessions (
    session_id      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id        UUID        NOT NULL REFERENCES alma_private.agent_meta(agent_id),
    task_prompt     TEXT        NOT NULL,
    status          alma_private.session_status DEFAULT 'active',
    final_answer    TEXT,
    total_steps     INT         DEFAULT 0,
    started_at      TIMESTAMPTZ DEFAULT NOW(),
    ended_at        TIMESTAMPTZ,
    metadata        JSONB       DEFAULT '{}'
);

-- -------------------------------------------------------------
-- tasks: Task queue (also inter-agent message queue)
-- -------------------------------------------------------------
CREATE TABLE alma_private.tasks (
    task_id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id      UUID        NOT NULL REFERENCES alma_private.sessions(session_id),
    agent_id        UUID        NOT NULL REFERENCES alma_private.agent_meta(agent_id),
    description     TEXT        NOT NULL,
    status          alma_private.task_status DEFAULT 'pending',
    result          TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ
);

-- -------------------------------------------------------------
-- execution_logs: Per-step execution history (DB owns state)
-- -------------------------------------------------------------
CREATE TABLE alma_private.execution_logs (
    log_id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id      UUID        NOT NULL REFERENCES alma_private.sessions(session_id),
    agent_id        UUID        NOT NULL REFERENCES alma_private.agent_meta(agent_id),
    step_number     INT         NOT NULL,
    action_type     TEXT        NOT NULL,  -- execute_sql / finish / error / delegate
    input_context   JSONB,                 -- messages sent to LLM
    llm_response    JSONB,                 -- raw LLM response
    action_result   TEXT,                  -- SQL result or error message
    duration_ms     INT,
    executed_at     TIMESTAMPTZ DEFAULT NOW()
);

-- -------------------------------------------------------------
-- memory: Agent memory with pgvector embeddings
-- -------------------------------------------------------------
CREATE TABLE alma_private.memory (
    memory_id       UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id        UUID        NOT NULL REFERENCES alma_private.agent_meta(agent_id),
    session_id      UUID        REFERENCES alma_private.sessions(session_id),
    memory_type     alma_private.memory_type DEFAULT 'episodic',
    content         TEXT        NOT NULL,
    embedding       vector(1536),          -- pgvector column
    importance      NUMERIC(3,2) DEFAULT 0.5 CHECK (importance BETWEEN 0 AND 1),
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    accessed_at     TIMESTAMPTZ DEFAULT NOW(),
    access_count    INT         DEFAULT 0
);

-- -------------------------------------------------------------
-- task_dependencies: Task execution ordering
-- -------------------------------------------------------------
CREATE TABLE alma_private.task_dependencies (
    dependency_id   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id         UUID        NOT NULL REFERENCES alma_private.tasks(task_id),
    depends_on      UUID        NOT NULL REFERENCES alma_private.tasks(task_id),
    UNIQUE (task_id, depends_on),
    CHECK (task_id <> depends_on)
);

-- -------------------------------------------------------------
-- agent_messages: Inter-agent message history (audit)
-- -------------------------------------------------------------
CREATE TABLE alma_private.agent_messages (
    message_id      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id      UUID        NOT NULL REFERENCES alma_private.sessions(session_id),
    from_agent_id   UUID        REFERENCES alma_private.agent_meta(agent_id),
    to_agent_id     UUID        REFERENCES alma_private.agent_meta(agent_id),
    message_type    TEXT        NOT NULL,  -- instruction / result / escalation
    content         TEXT        NOT NULL,
    sent_at         TIMESTAMPTZ DEFAULT NOW()
);

-- -------------------------------------------------------------
-- human_interventions: Human intervention history (audit)
-- -------------------------------------------------------------
CREATE TABLE alma_private.human_interventions (
    intervention_id     UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id          UUID        NOT NULL REFERENCES alma_private.sessions(session_id),
    agent_id            UUID        NOT NULL REFERENCES alma_private.agent_meta(agent_id),
    intervention_type   alma_private.intervention_type NOT NULL,
    operator_id         TEXT,              -- human operator identifier
    context             TEXT,              -- what the agent was doing
    intervention_note   TEXT,              -- human's note / correction
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

-- -------------------------------------------------------------
-- experiments: Comparative experiment configuration
-- -------------------------------------------------------------
CREATE TABLE alma_private.experiments (
    experiment_id   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT        NOT NULL,
    description     TEXT,
    task_prompt     TEXT        NOT NULL,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- -------------------------------------------------------------
-- experiment_results: Comparative experiment results
-- -------------------------------------------------------------
CREATE TABLE alma_private.experiment_results (
    result_id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_id       UUID        NOT NULL REFERENCES alma_private.experiments(experiment_id),
    framework           TEXT        NOT NULL,  -- 'alma' / 'langgraph' / 'openclaw' etc.
    session_id          UUID        REFERENCES alma_private.sessions(session_id),
    is_success          BOOLEAN     DEFAULT FALSE,
    total_steps         INT,
    duration_ms         INT,
    reasoning_score     NUMERIC(4,3),
    notes               TEXT,
    recorded_at         TIMESTAMPTZ DEFAULT NOW()
);
