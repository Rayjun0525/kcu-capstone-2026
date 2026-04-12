-- =============================================================================
-- argo--1.0.sql  ARGO Extension v1.0 — Full install script
-- Section order: Extensions → Schemas → Roles → Types → Tables → Views
--            → Functions → Grants → Indexes → Triggers
-- =============================================================================

-- =============================================================================
-- 01. Required Extensions
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS plpython3u;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =============================================================================
-- 02. Schemas
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS argo_private;
CREATE SCHEMA IF NOT EXISTS argo_public;

COMMENT ON SCHEMA argo_private IS 'ARGO internal tables. Not directly accessible to agent roles.';
COMMENT ON SCHEMA argo_public  IS 'ARGO public API: views and functions for agent roles.';

-- =============================================================================
-- 03. Roles
-- =============================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'argo_operator')   THEN CREATE ROLE argo_operator   NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'argo_agent_base') THEN CREATE ROLE argo_agent_base NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'argo_sql_sandbox')THEN CREATE ROLE argo_sql_sandbox NOLOGIN; END IF;
END $$;

COMMENT ON ROLE argo_operator    IS 'ARGO admin role. Grant to human DBAs.';
COMMENT ON ROLE argo_agent_base  IS 'Base role inherited by all agent roles.';
COMMENT ON ROLE argo_sql_sandbox IS 'Minimal role used by fn_execute_sql. SELECT on allowlisted views only.';

-- =============================================================================
-- 04. Types
-- =============================================================================
CREATE TYPE argo_public.agent_role_type AS ENUM ('orchestrator','executor','evaluator');
CREATE TYPE argo_public.task_status     AS ENUM ('pending','running','completed','failed','cancelled');
CREATE TYPE argo_public.llm_provider    AS ENUM ('anthropic','openai','ollama','custom');
CREATE TYPE argo_public.session_status  AS ENUM ('active','completed','failed');

-- =============================================================================
-- 05. Tables
-- =============================================================================

-- llm_configs
CREATE TABLE argo_private.llm_configs (
    llm_config_id   SERIAL PRIMARY KEY,
    provider        TEXT    NOT NULL CHECK (provider IN ('anthropic','openai','ollama','custom')),
    endpoint        TEXT    NOT NULL DEFAULT '',
    model_name      TEXT    NOT NULL,
    embedding_model TEXT,
    api_key_ref     TEXT,
    temperature     FLOAT   NOT NULL DEFAULT 0.7 CHECK (temperature >= 0 AND temperature <= 2),
    max_tokens      INT     NOT NULL DEFAULT 4096 CHECK (max_tokens > 0),
    request_options JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE  argo_private.llm_configs IS 'LLM provider and model config. api_key_ref = env var name only, never the key itself.';

-- agent_profiles
CREATE TABLE argo_private.agent_profiles (
    profile_id    SERIAL PRIMARY KEY,
    name          TEXT NOT NULL UNIQUE,
    agent_role    TEXT NOT NULL CHECK (agent_role IN ('orchestrator','executor','evaluator')),
    system_prompt TEXT NOT NULL DEFAULT '',
    max_steps     INT  NOT NULL DEFAULT 10 CHECK (max_steps > 0),
    max_retries   INT  NOT NULL DEFAULT 3  CHECK (max_retries >= 0),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE argo_private.agent_profiles IS 'Agent behavioural profile: system prompt and execution limits.';

-- agent_meta
CREATE TABLE argo_private.agent_meta (
    agent_id     SERIAL PRIMARY KEY,
    role_name    TEXT    NOT NULL UNIQUE,
    display_name TEXT    NOT NULL,
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE  argo_private.agent_meta IS 'Agent identity. role_name must match a PostgreSQL role.';

-- agent_profile_assignments
CREATE TABLE argo_private.agent_profile_assignments (
    assignment_id SERIAL PRIMARY KEY,
    role_name     TEXT NOT NULL UNIQUE REFERENCES argo_private.agent_meta(role_name) ON DELETE CASCADE ON UPDATE CASCADE,
    profile_id    INT  NOT NULL REFERENCES argo_private.agent_profiles(profile_id)   ON DELETE RESTRICT,
    llm_config_id INT  NOT NULL REFERENCES argo_private.llm_configs(llm_config_id)   ON DELETE RESTRICT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- sessions
CREATE TABLE argo_private.sessions (
    session_id   SERIAL PRIMARY KEY,
    agent_id     INT  NOT NULL REFERENCES argo_private.agent_meta(agent_id) ON DELETE CASCADE,
    status       TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','completed','failed')),
    goal         TEXT NOT NULL,
    final_answer TEXT,
    started_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ
);

-- tasks
CREATE TABLE argo_private.tasks (
    task_id    SERIAL PRIMARY KEY,
    session_id INT  NOT NULL REFERENCES argo_private.sessions(session_id) ON DELETE CASCADE,
    agent_id   INT  NOT NULL REFERENCES argo_private.agent_meta(agent_id) ON DELETE CASCADE,
    status     TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','running','completed','failed','cancelled')),
    input      TEXT NOT NULL,
    output     TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE argo_private.tasks IS 'Task queue / message bus between DB and external workers.';

-- execution_logs
CREATE TABLE argo_private.execution_logs (
    log_id              SERIAL PRIMARY KEY,
    task_id             INT  NOT NULL REFERENCES argo_private.tasks(task_id) ON DELETE CASCADE,
    step_number         INT  NOT NULL,
    role                TEXT NOT NULL CHECK (role IN ('system','user','assistant','tool')),
    content             TEXT NOT NULL,
    compressed_content  TEXT,
    compression_quality FLOAT CHECK (compression_quality IS NULL OR (compression_quality >= 0 AND compression_quality <= 1)),
    compressed_at       TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE  argo_private.execution_logs IS 'Per-step message history. Compression fields populated by compressor agent.';
COMMENT ON COLUMN argo_private.execution_logs.compressed_content  IS 'LLM-generated summary. NULL until compressed.';
COMMENT ON COLUMN argo_private.execution_logs.compression_quality IS 'Self-assessed quality score 0-1. NULL until compressed.';

-- memory
CREATE TABLE argo_private.memory (
    memory_id  SERIAL PRIMARY KEY,
    agent_id   INT  NOT NULL REFERENCES argo_private.agent_meta(agent_id) ON DELETE CASCADE,
    session_id INT  REFERENCES argo_private.sessions(session_id) ON DELETE SET NULL,
    content    TEXT NOT NULL,
    embedding  vector,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE argo_private.memory IS 'Agent long-term memory. embedding NULL when provider has no embeddings API.';

-- task_dependencies
CREATE TABLE argo_private.task_dependencies (
    dependency_id      SERIAL PRIMARY KEY,
    task_id            INT NOT NULL REFERENCES argo_private.tasks(task_id) ON DELETE CASCADE,
    depends_on_task_id INT NOT NULL REFERENCES argo_private.tasks(task_id) ON DELETE CASCADE,
    CONSTRAINT uq_task_dep     UNIQUE (task_id, depends_on_task_id),
    CONSTRAINT chk_no_self_dep CHECK  (task_id <> depends_on_task_id)
);
COMMENT ON TABLE argo_private.task_dependencies IS 'DAG execution order. Worker polls v_ready_tasks.';

-- agent_messages
CREATE TABLE argo_private.agent_messages (
    message_id    SERIAL PRIMARY KEY,
    from_agent_id INT  NOT NULL REFERENCES argo_private.agent_meta(agent_id) ON DELETE CASCADE,
    to_agent_id   INT  NOT NULL REFERENCES argo_private.agent_meta(agent_id) ON DELETE CASCADE,
    session_id    INT  REFERENCES argo_private.sessions(session_id) ON DELETE SET NULL,
    direction     TEXT NOT NULL CHECK (direction IN ('instruction','result')),
    content       TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- human_interventions
CREATE TABLE argo_private.human_interventions (
    intervention_id SERIAL PRIMARY KEY,
    session_id      INT  NOT NULL REFERENCES argo_private.sessions(session_id) ON DELETE CASCADE,
    operator_role   TEXT NOT NULL,
    reason          TEXT,
    action_taken    TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- experiments
CREATE TABLE argo_private.experiments (
    experiment_id SERIAL PRIMARY KEY,
    name          TEXT NOT NULL,
    task_prompt   TEXT NOT NULL,
    description   TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- experiment_results
CREATE TABLE argo_private.experiment_results (
    result_id       SERIAL PRIMARY KEY,
    experiment_id   INT  NOT NULL REFERENCES argo_private.experiments(experiment_id) ON DELETE CASCADE,
    framework       TEXT NOT NULL,
    session_id      INT,
    is_success      BOOLEAN NOT NULL,
    total_steps     INT,
    duration_ms     INT,
    reasoning_score FLOAT CHECK (reasoning_score IS NULL OR (reasoning_score >= 0 AND reasoning_score <= 1)),
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- sql_sandbox_allowlist
CREATE TABLE argo_private.sql_sandbox_allowlist (
    view_name   TEXT PRIMARY KEY,
    description TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE argo_private.sql_sandbox_allowlist IS 'Whitelist for fn_execute_sql. INSERT to allow, DELETE to revoke.';

INSERT INTO argo_private.sql_sandbox_allowlist (view_name, description) VALUES
    ('argo_public.v_my_tasks',         'Agent own task list'),
    ('argo_public.v_my_memory',        'Agent own memory'),
    ('argo_public.v_session_progress', 'Session progress summary'),
    ('argo_public.v_ready_tasks',      'Ready-to-run tasks');

-- system_agent_configs
CREATE TABLE argo_private.system_agent_configs (
    config_id         SERIAL PRIMARY KEY,
    agent_type        TEXT    NOT NULL UNIQUE CHECK (agent_type IN ('compressor')),
    is_enabled        BOOLEAN NOT NULL DEFAULT FALSE,
    role_name         TEXT    REFERENCES argo_private.agent_meta(role_name) ON DELETE SET NULL ON UPDATE CASCADE,
    run_interval_secs INT     NOT NULL DEFAULT 3600 CHECK (run_interval_secs > 0),
    settings          JSONB   NOT NULL DEFAULT '{}',
    last_run_at       TIMESTAMPTZ,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE  argo_private.system_agent_configs IS 'ARGO built-in system agent configs. is_enabled=FALSE by default.';
COMMENT ON COLUMN argo_private.system_agent_configs.settings IS
    'compressor: quality_threshold(0.9), retry_threshold(0.8), max_retries(2), compress_after_steps(20), tool_result_max_chars(300), batch_size(5)';

INSERT INTO argo_private.system_agent_configs (agent_type, is_enabled, run_interval_secs, settings)
VALUES ('compressor', FALSE, 3600,
    '{"quality_threshold":0.9,"retry_threshold":0.8,"max_retries":2,
      "compress_after_steps":20,"tool_result_max_chars":300,"batch_size":5}');

-- =============================================================================
-- 06. Views  (after tables, before GRANTs)
-- =============================================================================

CREATE OR REPLACE VIEW argo_public.v_agent_context AS
SELECT am.agent_id, am.role_name, am.display_name, am.is_active,
       ap.profile_id, ap.agent_role, ap.system_prompt, ap.max_steps, ap.max_retries,
       lc.llm_config_id, lc.provider, lc.endpoint, lc.model_name, lc.embedding_model,
       lc.api_key_ref, lc.temperature, lc.max_tokens, lc.request_options
FROM argo_private.agent_meta am
JOIN argo_private.agent_profile_assignments apa ON apa.role_name = am.role_name
JOIN argo_private.agent_profiles ap ON ap.profile_id = apa.profile_id
JOIN argo_private.llm_configs lc ON lc.llm_config_id = apa.llm_config_id
WHERE am.role_name = session_user::text AND am.is_active = TRUE;
COMMENT ON VIEW argo_public.v_agent_context IS 'Current agent profile + LLM config. Scoped to session_user.';

CREATE OR REPLACE VIEW argo_public.v_my_tasks AS
SELECT t.task_id, t.session_id, t.status, t.input, t.output, t.created_at, t.updated_at
FROM argo_private.tasks t
JOIN argo_private.agent_meta am ON am.agent_id = t.agent_id
WHERE am.role_name = session_user::text;
COMMENT ON VIEW argo_public.v_my_tasks IS 'Tasks for the current agent. Scoped to session_user.';

CREATE OR REPLACE VIEW argo_public.v_my_memory AS
SELECT m.memory_id, m.session_id, m.content, m.embedding, m.created_at
FROM argo_private.memory m
JOIN argo_private.agent_meta am ON am.agent_id = m.agent_id
WHERE am.role_name = session_user::text
ORDER BY m.created_at DESC;
COMMENT ON VIEW argo_public.v_my_memory IS 'Long-term memory for current agent. Scoped to session_user.';

CREATE OR REPLACE VIEW argo_public.v_session_progress AS
SELECT s.session_id, s.status, s.goal, s.started_at, s.completed_at,
       am.role_name, am.display_name,
       COUNT(t.task_id)                                                    AS total_tasks,
       COUNT(t.task_id) FILTER (WHERE t.status = 'completed')             AS completed_tasks,
       COUNT(t.task_id) FILTER (WHERE t.status = 'running')               AS running_tasks,
       COUNT(t.task_id) FILTER (WHERE t.status IN ('failed','cancelled'))  AS failed_tasks
FROM argo_private.sessions s
JOIN argo_private.agent_meta am ON am.agent_id = s.agent_id
LEFT JOIN argo_private.tasks t ON t.session_id = s.session_id
WHERE am.role_name = session_user::text
   OR pg_has_role(session_user, 'argo_operator', 'MEMBER')
GROUP BY s.session_id, am.role_name, am.display_name;
COMMENT ON VIEW argo_public.v_session_progress IS 'Session progress. Agents see own; argo_operator sees all.';

CREATE OR REPLACE VIEW argo_public.v_session_audit AS
SELECT s.session_id, s.status AS session_status, s.goal, s.final_answer,
       s.started_at, s.completed_at,
       am.role_name, am.display_name,
       t.task_id, t.status AS task_status, t.input AS task_input, t.output AS task_output,
       el.log_id, el.step_number, el.role AS log_role, el.content AS log_content,
       el.compressed_at, el.compression_quality,
       el.created_at AS log_created_at
FROM argo_private.sessions s
JOIN argo_private.agent_meta am ON am.agent_id = s.agent_id
LEFT JOIN argo_private.tasks t  ON t.session_id = s.session_id
LEFT JOIN argo_private.execution_logs el ON el.task_id = t.task_id
ORDER BY s.session_id, t.task_id, el.step_number;
COMMENT ON VIEW argo_public.v_session_audit IS 'Full audit log. argo_operator only.';

CREATE OR REPLACE VIEW argo_public.v_ready_tasks AS
SELECT t.task_id, t.session_id, t.agent_id, t.status, t.input, t.created_at
FROM argo_private.tasks t
WHERE t.status = 'pending'
  AND NOT EXISTS (
      SELECT 1 FROM argo_private.task_dependencies td
      JOIN argo_private.tasks dep ON dep.task_id = td.depends_on_task_id
      WHERE td.task_id = t.task_id AND dep.status <> 'completed'
  );
COMMENT ON VIEW argo_public.v_ready_tasks IS 'Pending tasks with all dependencies completed. Worker polls this.';

CREATE OR REPLACE VIEW argo_public.v_compressible_logs AS
SELECT t.task_id, t.session_id,
       COUNT(*)                                              AS total_steps,
       COUNT(*) FILTER (WHERE el.compressed_at IS NULL)     AS uncompressed_steps,
       COUNT(*) FILTER (WHERE el.compressed_at IS NOT NULL) AS compressed_steps
FROM argo_private.tasks t
JOIN argo_private.execution_logs el ON el.task_id = t.task_id
WHERE t.status IN ('completed','failed')
GROUP BY t.task_id, t.session_id
HAVING COUNT(*) >= COALESCE(
    (SELECT (settings->>'compress_after_steps')::int
     FROM argo_private.system_agent_configs WHERE agent_type = 'compressor'), 20)
   AND COUNT(*) FILTER (WHERE el.compressed_at IS NULL) > 0;
COMMENT ON VIEW argo_public.v_compressible_logs IS 'Tasks eligible for log compression. Compressor agent polls this.';

CREATE OR REPLACE VIEW argo_public.v_system_agents AS
SELECT sc.config_id, sc.agent_type, sc.is_enabled, sc.role_name,
       am.display_name, am.is_active AS agent_is_active,
       sc.run_interval_secs, sc.settings, sc.last_run_at,
       CASE WHEN sc.last_run_at IS NOT NULL
            THEN sc.last_run_at + (sc.run_interval_secs || ' seconds')::interval
            ELSE NULL END AS next_run_at,
       CASE WHEN sc.agent_type = 'compressor'
            THEN (SELECT COUNT(*) FROM argo_public.v_compressible_logs)
            ELSE NULL END AS pending_targets,
       sc.updated_at
FROM argo_private.system_agent_configs sc
LEFT JOIN argo_private.agent_meta am ON am.role_name = sc.role_name;
COMMENT ON VIEW argo_public.v_system_agents IS 'System agent status and config. argo_operator only.';

-- =============================================================================
-- 07. Functions
-- =============================================================================

-- fn_execute_sql: allowlist sandbox
CREATE OR REPLACE FUNCTION argo_private.fn_execute_sql(p_sql TEXT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, argo_public, public, pg_catalog AS $$
DECLARE v_sql TEXT; v_result TEXT; v_table_name TEXT;
BEGIN
    v_sql := regexp_replace(p_sql, '--[^\n]*', '', 'g');
    v_sql := regexp_replace(v_sql, '/\*.*?\*/', '', 'gs');
    v_sql := btrim(v_sql);
    IF v_sql = '' THEN RAISE EXCEPTION 'fn_execute_sql: empty SQL'; END IF;
    IF position(';' IN v_sql) > 0 THEN RAISE EXCEPTION 'fn_execute_sql: multiple statements not allowed'; END IF;
    IF NOT (v_sql ~* '^[[:space:]]*SELECT[[:space:]]') THEN
        RAISE EXCEPTION 'fn_execute_sql: only SELECT allowed (got: %)', left(v_sql,50);
    END IF;
    v_table_name := lower(trim(substring(v_sql FROM '(?i)FROM[[:space:]]+([\w.]+)')));
    IF v_table_name IS NULL OR v_table_name = '' THEN
        RAISE EXCEPTION 'fn_execute_sql: could not parse table name from SQL';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM argo_private.sql_sandbox_allowlist
                   WHERE lower(view_name) = v_table_name) THEN
        RAISE EXCEPTION 'fn_execute_sql: "%" not in sql_sandbox_allowlist', v_table_name;
    END IF;
    EXECUTE 'SELECT json_agg(t)::text FROM (' || v_sql || ') t' INTO v_result;
    RETURN COALESCE(v_result, '[]');
EXCEPTION WHEN OTHERS THEN RAISE;
END;
$$;

-- fn_log_step
CREATE OR REPLACE FUNCTION argo_private.fn_log_step(p_task_id INT, p_step INT, p_role TEXT, p_content TEXT)
RETURNS VOID LANGUAGE sql SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
    INSERT INTO argo_private.execution_logs (task_id, step_number, role, content)
    VALUES (p_task_id, p_step, p_role, p_content);
$$;

-- fn_get_embedding
CREATE OR REPLACE FUNCTION argo_private.fn_get_embedding(p_agent_id INT, p_text TEXT)
RETURNS vector LANGUAGE plpython3u SECURITY DEFINER
SET search_path = argo_private, public, pg_catalog AS $$
import json, os, urllib.request
rows = plpy.execute(
    "SELECT lc.provider,lc.endpoint,lc.model_name,lc.embedding_model,lc.api_key_ref "
    "FROM argo_private.llm_configs lc "
    "JOIN argo_private.agent_profile_assignments apa ON lc.llm_config_id=apa.llm_config_id "
    "WHERE apa.role_name=(SELECT role_name FROM argo_private.agent_meta WHERE agent_id=%d)"%p_agent_id)
if not rows: return None
c=rows[0]; api_key=os.getenv(c['api_key_ref']) if c['api_key_ref'] else None
try:
    if c['provider']=='openai':
        url='https://api.openai.com/v1/embeddings'
        payload=json.dumps({'model':c['embedding_model'] or 'text-embedding-3-small','input':p_text}).encode()
        req=urllib.request.Request(url,data=payload,headers={'Content-Type':'application/json','Authorization':'Bearer '+(api_key or '')},method='POST')
        with urllib.request.urlopen(req,timeout=30) as r: return json.loads(r.read())['data'][0]['embedding']
    elif c['provider']=='ollama':
        base=(c['endpoint'].rsplit('/api/',1)[0] if '/api/' in (c['endpoint'] or '') else c['endpoint'] or 'http://localhost:11434')
        url=base.rstrip('/')+'/api/embeddings'
        payload=json.dumps({'model':c['embedding_model'] or c['model_name'],'prompt':p_text}).encode()
        req=urllib.request.Request(url,data=payload,headers={'Content-Type':'application/json'},method='POST')
        with urllib.request.urlopen(req,timeout=30) as r: return json.loads(r.read()).get('embedding')
    else: return None
except: return None
$$;

-- fn_search_memory
CREATE OR REPLACE FUNCTION argo_public.fn_search_memory(p_query_embedding vector, p_limit INT DEFAULT 5)
RETURNS TABLE (memory_id INT, content TEXT, similarity FLOAT)
LANGUAGE sql SECURITY DEFINER SET search_path = argo_private, public, pg_catalog AS $$
    SELECT m.memory_id, m.content, 1-(m.embedding<=>p_query_embedding) AS similarity
    FROM argo_private.memory m
    JOIN argo_private.agent_meta am ON am.agent_id=m.agent_id
    WHERE am.role_name=session_user::text AND m.embedding IS NOT NULL
      AND vector_dims(m.embedding)=vector_dims(p_query_embedding)
    ORDER BY m.embedding<=>p_query_embedding LIMIT p_limit;
$$;

-- fn_load_recent_memory
CREATE OR REPLACE FUNCTION argo_private.fn_load_recent_memory(p_agent_id INT, p_task TEXT, p_limit INT DEFAULT 5)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = argo_private, public, pg_catalog AS $$
DECLARE v_emb vector; v_result TEXT:=''; v_row RECORD;
BEGIN
    IF p_limit<=0 THEN RETURN ''; END IF;
    v_emb:=argo_private.fn_get_embedding(p_agent_id,p_task);
    IF v_emb IS NOT NULL THEN
        FOR v_row IN SELECT content FROM argo_private.memory
            WHERE agent_id=p_agent_id AND embedding IS NOT NULL AND vector_dims(embedding)=vector_dims(v_emb)
            ORDER BY embedding<=>v_emb LIMIT p_limit
        LOOP v_result:=v_result||'- '||v_row.content||E'\n'; END LOOP;
    ELSE
        FOR v_row IN SELECT content FROM argo_private.memory
            WHERE agent_id=p_agent_id ORDER BY created_at DESC LIMIT p_limit
        LOOP v_result:=v_result||'- '||v_row.content||E'\n'; END LOOP;
    END IF;
    IF v_result<>'' THEN v_result:=E'\n[MEMORY]\nRelevant past interactions:\n'||v_result; END IF;
    RETURN v_result;
END;
$$;

-- fn_build_messages
-- Assembles the full conversation history for a session.
-- 1) system prompt
-- 2) Previous tasks in the same session: user(input) + assistant(output) pairs
-- 3) execution_logs of the current task (including intermediate tool calls)
-- 4) User message for the current task (falls back to tasks.input if not yet in logs)
CREATE OR REPLACE FUNCTION argo_private.fn_build_messages(p_task_id INT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, argo_public, public, pg_catalog AS $$
DECLARE
    v_task      RECORD;
    v_sys       TEXT;
    v_history   JSONB;
    v_cur_logs  JSONB;
    v_msgs      JSONB;
BEGIN
    SELECT t.*, am.agent_id INTO v_task
    FROM argo_private.tasks t
    JOIN argo_private.agent_meta am ON am.agent_id = t.agent_id
    WHERE t.task_id = p_task_id;

    -- System prompt
    SELECT ap.system_prompt INTO v_sys
    FROM argo_private.agent_profile_assignments apa
    JOIN argo_private.agent_profiles ap ON ap.profile_id = apa.profile_id
    WHERE apa.role_name = (
        SELECT role_name FROM argo_private.agent_meta WHERE agent_id = v_task.agent_id
    );

    -- Completed task history from the same session (user + assistant pairs only)
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_array(
                jsonb_build_object('role','user',    'content', t_prev.input),
                jsonb_build_object('role','assistant','content', t_prev.output)
            )
            ORDER BY t_prev.task_id
        ),
        '[]'::jsonb
    )
    INTO v_history
    FROM argo_private.tasks t_prev
    WHERE t_prev.session_id = v_task.session_id
      AND t_prev.task_id    < p_task_id
      AND t_prev.status     = 'completed'
      AND t_prev.output     IS NOT NULL;

    -- Flatten the array-of-arrays produced by jsonb_agg
    SELECT COALESCE(
        (SELECT jsonb_agg(elem)
         FROM jsonb_array_elements(v_history) AS outer_arr(pair),
              jsonb_array_elements(pair) AS elem),
        '[]'::jsonb
    ) INTO v_history;

    -- Intermediate logs for the current task (including tool call round-trips)
    SELECT COALESCE(
        (SELECT jsonb_agg(
                    jsonb_build_object('role', el.role, 'content', el.content)
                    ORDER BY el.step_number
                )
         FROM argo_private.execution_logs el
         WHERE el.task_id = p_task_id
           AND el.role IN ('user','assistant','tool')),
        '[]'::jsonb
    ) INTO v_cur_logs;

    -- Prepend user message from tasks.input if not yet in execution_logs
    IF NOT EXISTS (
        SELECT 1 FROM argo_private.execution_logs
        WHERE task_id = p_task_id AND role = 'user'
    ) THEN
        v_cur_logs := jsonb_build_array(
                          jsonb_build_object('role','user','content', v_task.input)
                      ) || v_cur_logs;
    END IF;

    v_msgs := jsonb_build_array(
                  jsonb_build_object('role','system','content', COALESCE(v_sys,''))
              )
              || v_history
              || v_cur_logs;

    RETURN v_msgs;
END;
$$;
COMMENT ON FUNCTION argo_private.fn_build_messages(INT) IS
    'Assembles the full LLM message array: system + session history + current task logs.';

-- fn_next_step
CREATE OR REPLACE FUNCTION argo_public.fn_next_step(p_task_id INT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, argo_public, public, pg_catalog AS $$
DECLARE v_task RECORD; v_max_steps INT; v_cur_steps INT;
BEGIN
    SELECT t.*, am.agent_id INTO v_task
    FROM argo_private.tasks t JOIN argo_private.agent_meta am ON am.agent_id=t.agent_id
    WHERE t.task_id=p_task_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'fn_next_step: task_id % not found',p_task_id; END IF;
    IF v_task.status IN ('completed','failed','cancelled') THEN
        RETURN jsonb_build_object('action','done','output',v_task.output); END IF;
    SELECT ap.max_steps INTO v_max_steps
    FROM argo_private.agent_profile_assignments apa
    JOIN argo_private.agent_profiles ap ON ap.profile_id=apa.profile_id
    WHERE apa.role_name=(SELECT role_name FROM argo_private.agent_meta WHERE agent_id=v_task.agent_id);
    SELECT COUNT(*) INTO v_cur_steps FROM argo_private.execution_logs
    WHERE task_id=p_task_id AND role='assistant';
    IF v_cur_steps>=v_max_steps THEN
        PERFORM argo_public.fn_submit_result(p_task_id,'Max steps ('||v_max_steps||') reached.',TRUE);
        RETURN jsonb_build_object('action','done'); END IF;
    RETURN jsonb_build_object(
        'action','call_llm','task_id',p_task_id,'agent_id',v_task.agent_id,
        'messages',argo_private.fn_build_messages(p_task_id),
        'llm_config',(SELECT jsonb_build_object(
            'provider',lc.provider,'endpoint',lc.endpoint,'model_name',lc.model_name,
            'api_key_ref',lc.api_key_ref,'temperature',lc.temperature,
            'max_tokens',lc.max_tokens,'request_options',lc.request_options)
            FROM argo_private.llm_configs lc
            JOIN argo_private.agent_profile_assignments apa ON lc.llm_config_id=apa.llm_config_id
            JOIN argo_private.agent_meta am ON am.role_name=apa.role_name
            WHERE am.agent_id=v_task.agent_id));
END;
$$;
COMMENT ON FUNCTION argo_public.fn_next_step(INT) IS
    'Control plane: returns {action:call_llm,...} or {action:done}. Worker calls this in a loop.';

-- fn_submit_result
CREATE OR REPLACE FUNCTION argo_public.fn_submit_result(p_task_id INT, p_response TEXT, p_is_final BOOLEAN DEFAULT FALSE)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, argo_public, public, pg_catalog AS $$
DECLARE v_task RECORD; v_parsed JSONB; v_action TEXT; v_step INT; v_ans TEXT; v_emb vector; v_sql_result TEXT;
BEGIN
    SELECT * INTO v_task FROM argo_private.tasks WHERE task_id=p_task_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'fn_submit_result: task_id % not found',p_task_id; END IF;
    SELECT COALESCE(MAX(step_number),0)+1 INTO v_step FROM argo_private.execution_logs WHERE task_id=p_task_id;
    PERFORM argo_private.fn_log_step(p_task_id,v_step,'assistant',p_response);
    IF p_is_final THEN
        UPDATE argo_private.tasks SET status='completed',output=p_response,updated_at=now() WHERE task_id=p_task_id;
        RETURN jsonb_build_object('action','done','output',p_response); END IF;
    BEGIN v_parsed:=p_response::jsonb;
    EXCEPTION WHEN OTHERS THEN v_parsed:=jsonb_build_object('action','finish','final_answer',p_response); END;
    v_action:=v_parsed->>'action';
    IF v_action='finish' THEN
        v_ans:=v_parsed->>'final_answer';
        UPDATE argo_private.tasks SET status='completed',output=v_ans,updated_at=now() WHERE task_id=p_task_id;
        IF (SELECT COUNT(*) FROM argo_private.tasks WHERE session_id=v_task.session_id)=1 THEN
            UPDATE argo_private.sessions SET status='completed',final_answer=v_ans,completed_at=now()
            WHERE session_id=v_task.session_id; END IF;
        v_emb:=argo_private.fn_get_embedding(v_task.agent_id,'Task: '||v_task.input||' Answer: '||v_ans);
        INSERT INTO argo_private.memory(agent_id,session_id,content,embedding)
        VALUES(v_task.agent_id,v_task.session_id,'Task: '||v_task.input||E'\nAnswer: '||v_ans,v_emb);
        RETURN jsonb_build_object('action','done','output',v_ans);
    ELSIF v_action='execute_sql' THEN
        BEGIN v_sql_result:=argo_private.fn_execute_sql(v_parsed->>'sql');
        EXCEPTION WHEN OTHERS THEN v_sql_result:='SQL ERROR: '||SQLERRM; END;
        PERFORM argo_private.fn_log_step(p_task_id,v_step+1,'tool',v_sql_result);
        RETURN jsonb_build_object('action','continue');
    ELSE RETURN jsonb_build_object('action','continue'); END IF;
END;
$$;
COMMENT ON FUNCTION argo_public.fn_submit_result(INT,TEXT,BOOLEAN) IS
    'Worker submits LLM response. DB updates state and returns next action.';

-- fn_purge_compressed_logs
CREATE OR REPLACE FUNCTION argo_public.fn_purge_compressed_logs(p_task_id INT, p_quality_threshold FLOAT DEFAULT 0.9)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = argo_private, public, pg_catalog AS $$
DECLARE v_deleted INT;
BEGIN
    IF NOT pg_has_role(session_user,'argo_operator','MEMBER') THEN
        RAISE EXCEPTION 'fn_purge_compressed_logs: argo_operator required'; END IF;
    IF EXISTS (SELECT 1 FROM argo_private.execution_logs
               WHERE task_id=p_task_id AND (compressed_at IS NULL OR compression_quality<p_quality_threshold)) THEN
        RAISE EXCEPTION 'fn_purge_compressed_logs: uncompressed or low-quality logs exist for task %',p_task_id; END IF;
    DELETE FROM argo_private.execution_logs WHERE task_id=p_task_id;
    GET DIAGNOSTICS v_deleted=ROW_COUNT;
    RETURN v_deleted;
END;
$$;

-- run_agent
CREATE OR REPLACE FUNCTION argo_public.run_agent(
    p_agent_role TEXT, p_task TEXT, p_session_id INT DEFAULT NULL,
    p_memory_limit INT DEFAULT 5, p_history_steps INT DEFAULT 20)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, argo_public, public, pg_catalog AS $$
DECLARE v_agent_id INT; v_session_id INT; v_task_id INT;
BEGIN
    IF session_user::text<>p_agent_role THEN
        RAISE EXCEPTION 'run_agent: permission denied — session_user(%) cannot run as agent(%)',session_user,p_agent_role; END IF;
    SELECT agent_id INTO v_agent_id FROM argo_private.agent_meta WHERE role_name=p_agent_role AND is_active=TRUE;
    IF v_agent_id IS NULL THEN RAISE EXCEPTION 'run_agent: agent not found or inactive: %',p_agent_role; END IF;
    IF p_session_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM argo_private.sessions WHERE session_id=p_session_id AND agent_id=v_agent_id) THEN
            RAISE EXCEPTION 'run_agent: session % does not belong to agent %',p_session_id,p_agent_role; END IF;
        v_session_id:=p_session_id;
    ELSE
        INSERT INTO argo_private.sessions(agent_id,status,goal) VALUES(v_agent_id,'active',p_task) RETURNING session_id INTO v_session_id;
    END IF;
    INSERT INTO argo_private.tasks(session_id,agent_id,status,input) VALUES(v_session_id,v_agent_id,'pending',p_task) RETURNING task_id INTO v_task_id;
    RETURN v_task_id;
END;
$$;
COMMENT ON FUNCTION argo_public.run_agent(TEXT,TEXT,INT,INT,INT) IS
    'Enqueues a task (pending) and returns task_id. Worker executes via fn_next_step/fn_submit_result loop.';

-- run_multi_agent
CREATE OR REPLACE FUNCTION argo_public.run_multi_agent(p_orchestrator_role TEXT, p_goal TEXT)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, argo_public, public, pg_catalog AS $$
DECLARE v_orch_id INT; v_session_id INT; v_task_id INT;
BEGIN
    IF session_user::text<>p_orchestrator_role THEN
        RAISE EXCEPTION 'run_multi_agent: permission denied — session_user(%) != orchestrator(%)',session_user,p_orchestrator_role; END IF;
    SELECT agent_id INTO v_orch_id FROM argo_private.agent_meta WHERE role_name=p_orchestrator_role AND is_active=TRUE;
    IF v_orch_id IS NULL THEN RAISE EXCEPTION 'run_multi_agent: orchestrator not found: %',p_orchestrator_role; END IF;
    INSERT INTO argo_private.sessions(agent_id,status,goal) VALUES(v_orch_id,'active',p_goal) RETURNING session_id INTO v_session_id;
    INSERT INTO argo_private.tasks(session_id,agent_id,status,input) VALUES(v_session_id,v_orch_id,'pending',p_goal) RETURNING task_id INTO v_task_id;
    RETURN v_task_id;
END;
$$;

-- create_agent
CREATE OR REPLACE FUNCTION argo_public.create_agent(p_role_name TEXT, p_config JSONB)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, argo_public, public, pg_catalog AS $$
DECLARE
    v_config_id INT; v_profile_id INT; v_password TEXT;
    v_name TEXT; v_agent_role TEXT; v_provider TEXT; v_endpoint TEXT;
    v_model TEXT; v_emb_model TEXT; v_api_ref TEXT;
    v_temp FLOAT; v_max_tok INT; v_req_opts JSONB;
    v_sys_prompt TEXT; v_max_steps INT; v_max_retries INT;
BEGIN
    IF NOT pg_has_role(session_user,'argo_operator','MEMBER') THEN
        RAISE EXCEPTION 'create_agent: permission denied — not argo_operator'; END IF;
    v_name:=p_config->>'name'; v_agent_role:=p_config->>'agent_role';
    v_provider:=p_config->>'provider'; v_endpoint:=COALESCE(p_config->>'endpoint','');
    v_model:=p_config->>'model_name'; v_emb_model:=p_config->>'embedding_model';
    v_api_ref:=p_config->>'api_key_ref';
    v_temp:=COALESCE((p_config->>'temperature')::float,0.7);
    v_max_tok:=COALESCE((p_config->>'max_tokens')::int,4096);
    v_req_opts:=p_config->'request_options';
    v_sys_prompt:=COALESCE(p_config->>'system_prompt','');
    v_max_steps:=COALESCE((p_config->>'max_steps')::int,10);
    v_max_retries:=COALESCE((p_config->>'max_retries')::int,3);
    v_password:=p_config->>'password';
    IF v_name IS NULL OR v_agent_role IS NULL OR v_provider IS NULL OR v_model IS NULL THEN
        RAISE EXCEPTION 'create_agent: name, agent_role, provider, model_name required'; END IF;
    PERFORM v_agent_role::argo_public.agent_role_type;
    PERFORM v_provider::argo_public.llm_provider;
    IF v_temp<0 OR v_temp>2 THEN RAISE EXCEPTION 'create_agent: temperature 0-2'; END IF;
    IF v_max_tok<=0 THEN RAISE EXCEPTION 'create_agent: max_tokens > 0'; END IF;
    IF v_max_steps<=0 THEN RAISE EXCEPTION 'create_agent: max_steps > 0'; END IF;
    v_password:=COALESCE(v_password,encode(sha256((random()::text||clock_timestamp()::text)::bytea),'hex'));
    EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L INHERIT IN ROLE argo_agent_base',p_role_name,v_password);
    INSERT INTO argo_private.llm_configs(provider,endpoint,model_name,embedding_model,api_key_ref,temperature,max_tokens,request_options)
    VALUES(v_provider,v_endpoint,v_model,v_emb_model,v_api_ref,v_temp,v_max_tok,v_req_opts) RETURNING llm_config_id INTO v_config_id;
    INSERT INTO argo_private.agent_profiles(name,agent_role,system_prompt,max_steps,max_retries)
    VALUES(v_name,v_agent_role,v_sys_prompt,v_max_steps,v_max_retries) RETURNING profile_id INTO v_profile_id;
    INSERT INTO argo_private.agent_meta(role_name,display_name) VALUES(p_role_name,v_name);
    INSERT INTO argo_private.agent_profile_assignments(role_name,profile_id,llm_config_id)
    VALUES(p_role_name,v_profile_id,v_config_id);
    RETURN 'Agent created: '||p_role_name;
EXCEPTION
    WHEN duplicate_object THEN RAISE EXCEPTION 'create_agent: role % already exists',p_role_name;
    WHEN unique_violation THEN RAISE EXCEPTION 'create_agent: name or role already exists';
END;
$$;
COMMENT ON FUNCTION argo_public.create_agent(TEXT,JSONB) IS
    'Create agent: PG role + LLM config + profile + meta. Required JSONB: name, agent_role, provider, model_name.';

-- drop_agent
CREATE OR REPLACE FUNCTION argo_public.drop_agent(p_role_name TEXT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = argo_private, public, pg_catalog AS $$
BEGIN
    IF NOT pg_has_role(session_user,'argo_operator','MEMBER') THEN
        RAISE EXCEPTION 'drop_agent: permission denied'; END IF;
    IF NOT EXISTS (SELECT 1 FROM argo_private.agent_meta WHERE role_name=p_role_name) THEN
        RAISE EXCEPTION 'drop_agent: agent not found: %',p_role_name; END IF;
    UPDATE argo_private.system_agent_configs SET role_name=NULL WHERE role_name=p_role_name;
    DELETE FROM argo_private.agent_meta WHERE role_name=p_role_name;
    EXECUTE format('DROP ROLE IF EXISTS %I',p_role_name);
    RETURN 'Agent dropped: '||p_role_name;
END;
$$;

-- list_agents
CREATE OR REPLACE FUNCTION argo_public.list_agents()
RETURNS TABLE(agent_id INT, role_name TEXT, display_name TEXT, agent_role TEXT,
              provider TEXT, model_name TEXT, embedding_model TEXT, is_active BOOLEAN, created_at TIMESTAMPTZ)
LANGUAGE sql SECURITY DEFINER SET search_path = argo_private, public, pg_catalog AS $$
    SELECT am.agent_id, am.role_name, am.display_name, ap.agent_role,
           lc.provider, lc.model_name, lc.embedding_model, am.is_active, am.created_at
    FROM argo_private.agent_meta am
    JOIN argo_private.agent_profile_assignments apa ON apa.role_name=am.role_name
    JOIN argo_private.agent_profiles ap ON ap.profile_id=apa.profile_id
    JOIN argo_private.llm_configs lc ON lc.llm_config_id=apa.llm_config_id
    ORDER BY am.created_at;
$$;

-- list_sessions
CREATE OR REPLACE FUNCTION argo_public.list_sessions(p_agent_role TEXT DEFAULT NULL)
RETURNS TABLE(session_id INT, role_name TEXT, status TEXT, goal TEXT, started_at TIMESTAMPTZ, completed_at TIMESTAMPTZ)
LANGUAGE sql SECURITY DEFINER SET search_path = argo_private, public, pg_catalog AS $$
    SELECT s.session_id, am.role_name, s.status, s.goal, s.started_at, s.completed_at
    FROM argo_private.sessions s JOIN argo_private.agent_meta am ON am.agent_id=s.agent_id
    WHERE (p_agent_role IS NULL AND (am.role_name=session_user::text OR pg_has_role(session_user,'argo_operator','MEMBER')))
       OR am.role_name=p_agent_role
    ORDER BY s.started_at DESC;
$$;

-- get_session
CREATE OR REPLACE FUNCTION argo_public.get_session(p_session_id INT)
RETURNS TABLE(session_id INT, role_name TEXT, status TEXT, goal TEXT, final_answer TEXT,
              started_at TIMESTAMPTZ, completed_at TIMESTAMPTZ,
              step_number INT, log_role TEXT, log_content TEXT,
              compressed_at TIMESTAMPTZ, compression_quality FLOAT)
LANGUAGE sql SECURITY DEFINER SET search_path = argo_private, public, pg_catalog AS $$
    SELECT s.session_id, am.role_name, s.status, s.goal, s.final_answer,
           s.started_at, s.completed_at, el.step_number, el.role, el.content,
           el.compressed_at, el.compression_quality
    FROM argo_private.sessions s JOIN argo_private.agent_meta am ON am.agent_id=s.agent_id
    LEFT JOIN argo_private.tasks t ON t.session_id=s.session_id
    LEFT JOIN argo_private.execution_logs el ON el.task_id=t.task_id
    WHERE s.session_id=p_session_id
      AND (am.role_name=session_user::text OR pg_has_role(session_user,'argo_operator','MEMBER'))
    ORDER BY t.task_id, el.step_number;
$$;

-- =============================================================================
-- 08. Compressor Agent Profile (built-in, inactive by default)
-- =============================================================================
INSERT INTO argo_private.agent_profiles(name, agent_role, system_prompt, max_steps, max_retries)
VALUES('ARGO Log Compressor','evaluator',
$PROMPT$You are ARGO-Compressor, a specialist agent for lossless-semantic compression of AI agent execution logs.

MISSION: Compress execution_logs into a structured summary preserving all reasoning while eliminating redundant content.

INPUT: JSON array: [{"step":1,"role":"system","content":"..."},...]

COMPRESSION RULES:
[R1] system → extract role+constraints only → {"role":"system_summary","content":"..."}
[R2] user (original task) → ALWAYS verbatim → {"role":"task","content":"..."}
[R3] assistant intermediate → preserve IF: new strategy, error correction, multi-option decision, reasoning causing final answer. Discard IF: repetition, generic acknowledgment, restating task.
[R4] tool pairs → result<300chars: verbatim; result>=300chars: key findings only; failed: error+fix; same tool+input repeated: first+last only.
[R5] final answer → ALWAYS verbatim → {"role":"final","content":"..."}
[R6] write 2-4 sentence execution_summary in task language.

QUALITY SCORING: 1.0=all recoverable; 0.95=trivial removed; 0.90=minor loss; 0.85=summarized; 0.80=notable; <0.80=UNACCEPTABLE re-compress.
Criteria: final explainable(+0.3), all tool outcomes(+0.2), strategy changes(+0.2), original task recoverable(+0.2), output<=40% tokens(+0.1).

OUTPUT — valid JSON only, no explanation outside JSON:
{"execution_summary":"...","compressed_steps":[{"role":"system_summary","content":"..."},{"role":"task","content":"..."},{"role":"reasoning","content":"...","original_steps":[3,5]},{"role":"tool_call","content":"...","tool_result":"...","original_steps":[4,5],"success":true},{"role":"final","content":"..."}],"compression_stats":{"original_steps":0,"compressed_steps":0,"reduction_ratio":0.0},"quality_score":0.0,"quality_justification":"..."}

VERIFY before submitting: (1)task entry verbatim, (2)final entry verbatim, (3)every tool_call has content+tool_result, (4)quality_score>=0.90 else re-compress, (5)no new information introduced, (6)valid complete JSON.$PROMPT$,
20, 3) ON CONFLICT (name) DO NOTHING;


-- activate_system_agent
-- Activates a built-in system agent in one call.
-- p_agent_type: 'compressor' (currently supported)
-- p_password:   DB login password (NULL = auto-generated)
-- p_overrides:  JSONB overrides for LLM config (NULL = use built-in defaults)
--               e.g. '{"model_name":"llama3","endpoint":"http://gpu:11434/api/chat"}'
CREATE OR REPLACE FUNCTION argo_public.activate_system_agent(
    p_agent_type TEXT,
    p_password   TEXT  DEFAULT NULL,
    p_overrides  JSONB DEFAULT NULL
) RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER
SET search_path = argo_private, argo_public, public, pg_catalog AS $$
DECLARE
    v_role_name   TEXT;
    v_display     TEXT;
    v_profile_id  INT;
    v_config_id   INT;
    v_password    TEXT;
    v_provider    TEXT;
    v_endpoint    TEXT;
    v_model       TEXT;
    v_temperature FLOAT;
    v_max_tokens  INT;
    v_req_opts    JSONB;
    v_max_steps   INT;
    v_max_retries INT;
BEGIN
    IF NOT pg_has_role(session_user, 'argo_operator', 'MEMBER') THEN
        RAISE EXCEPTION 'activate_system_agent: argo_operator required';
    END IF;

    IF p_agent_type NOT IN ('compressor') THEN
        RAISE EXCEPTION 'activate_system_agent: unknown agent_type "%". supported: compressor', p_agent_type;
    END IF;

    -- Default values by agent_type
    IF p_agent_type = 'compressor' THEN
        v_role_name   := 'argo_compressor';
        v_display     := 'ARGO Log Compressor';
        v_provider    := 'ollama';
        v_endpoint    := 'http://localhost:11434/api/chat';
        v_model       := 'gpt-oss:20b';
        v_temperature := 0.0;
        v_max_tokens  := 4096;
        v_req_opts    := '{"format":"json"}'::jsonb;
    END IF;

    -- Apply p_overrides on top of defaults
    IF p_overrides IS NOT NULL THEN
        v_provider    := COALESCE(p_overrides->>'provider',    v_provider);
        v_endpoint    := COALESCE(p_overrides->>'endpoint',    v_endpoint);
        v_model       := COALESCE(p_overrides->>'model_name',  v_model);
        v_temperature := COALESCE((p_overrides->>'temperature')::float, v_temperature);
        v_max_tokens  := COALESCE((p_overrides->>'max_tokens')::int,    v_max_tokens);
        IF p_overrides ? 'request_options' THEN
            v_req_opts := p_overrides->'request_options';
        END IF;
    END IF;

    -- Already activated
    IF EXISTS (SELECT 1 FROM argo_private.agent_meta WHERE role_name = v_role_name) THEN
        -- Enable system_agent_configs only
        UPDATE argo_private.system_agent_configs
        SET role_name  = v_role_name,
            is_enabled = TRUE
        WHERE agent_type = p_agent_type;
        RETURN format('System agent "%s" already exists. Enabled in system_agent_configs.', v_role_name);
    END IF;

    -- Fetch built-in profile
    SELECT profile_id, max_steps, max_retries
    INTO v_profile_id, v_max_steps, v_max_retries
    FROM argo_private.agent_profiles
    WHERE name = v_display;

    IF v_profile_id IS NULL THEN
        RAISE EXCEPTION 'activate_system_agent: built-in profile "%" not found. Re-install extension.', v_display;
    END IF;

    -- Generate password
    v_password := COALESCE(
        p_password,
        encode(sha256((random()::text || clock_timestamp()::text)::bytea), 'hex')
    );

    -- Create PostgreSQL role
    EXECUTE format(
        'CREATE ROLE %I WITH LOGIN PASSWORD %L INHERIT IN ROLE argo_agent_base',
        v_role_name, v_password
    );

    -- Register in agent_meta
    INSERT INTO argo_private.agent_meta (role_name, display_name)
    VALUES (v_role_name, v_display);

    -- Register LLM config
    INSERT INTO argo_private.llm_configs
        (provider, endpoint, model_name, temperature, max_tokens, request_options)
    VALUES (v_provider, v_endpoint, v_model, v_temperature, v_max_tokens, v_req_opts)
    RETURNING llm_config_id INTO v_config_id;

    -- Link profile + LLM config
    INSERT INTO argo_private.agent_profile_assignments (role_name, profile_id, llm_config_id)
    VALUES (v_role_name, v_profile_id, v_config_id);

    -- Activate system_agent_configs
    UPDATE argo_private.system_agent_configs
    SET role_name  = v_role_name,
        is_enabled = TRUE
    WHERE agent_type = p_agent_type;

    RETURN format(
        'System agent "%s" activated. role=%s  password=%s',
        v_display, v_role_name, v_password
    );
EXCEPTION
    WHEN duplicate_object THEN
        RAISE EXCEPTION 'activate_system_agent: role % already exists. Drop it first or call with existing role.', v_role_name;
END;
$$;
COMMENT ON FUNCTION argo_public.activate_system_agent(TEXT,TEXT,JSONB) IS
    'One-shot activation of a built-in system agent (compressor).
     Creates PG role + registers meta + LLM config + enables system_agent_configs.
     p_overrides JSONB can override model_name, endpoint, provider, temperature, max_tokens, request_options.
     Returns the generated password — save it for the worker process.';

-- =============================================================================
-- 09. Grants
-- =============================================================================
REVOKE ALL ON SCHEMA argo_private FROM PUBLIC;
REVOKE ALL ON SCHEMA argo_public  FROM PUBLIC;

-- argo_operator: full access
GRANT USAGE ON SCHEMA argo_private TO argo_operator;
GRANT USAGE ON SCHEMA argo_public  TO argo_operator;
GRANT ALL   ON ALL TABLES    IN SCHEMA argo_private TO argo_operator;
GRANT ALL   ON ALL SEQUENCES IN SCHEMA argo_private TO argo_operator;
GRANT ALL   ON ALL TABLES    IN SCHEMA argo_public  TO argo_operator;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA argo_private TO argo_operator;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA argo_public  TO argo_operator;
ALTER DEFAULT PRIVILEGES IN SCHEMA argo_private GRANT ALL ON TABLES    TO argo_operator;
ALTER DEFAULT PRIVILEGES IN SCHEMA argo_private GRANT ALL ON SEQUENCES TO argo_operator;

-- argo_agent_base: designated argo_public views/functions
GRANT USAGE ON SCHEMA argo_public TO argo_agent_base;
GRANT SELECT ON argo_public.v_agent_context    TO argo_agent_base;
GRANT SELECT ON argo_public.v_my_tasks         TO argo_agent_base;
GRANT SELECT ON argo_public.v_my_memory        TO argo_agent_base;
GRANT SELECT ON argo_public.v_session_progress TO argo_agent_base;
GRANT SELECT ON argo_public.v_ready_tasks      TO argo_agent_base;
GRANT EXECUTE ON FUNCTION argo_public.run_agent(TEXT,TEXT,INT,INT,INT)   TO argo_agent_base;
GRANT EXECUTE ON FUNCTION argo_public.run_multi_agent(TEXT,TEXT)         TO argo_agent_base;
GRANT EXECUTE ON FUNCTION argo_public.fn_next_step(INT)                  TO argo_agent_base;
GRANT EXECUTE ON FUNCTION argo_public.fn_submit_result(INT,TEXT,BOOLEAN) TO argo_agent_base;
GRANT EXECUTE ON FUNCTION argo_public.fn_search_memory(vector,INT)       TO argo_agent_base;
GRANT EXECUTE ON FUNCTION argo_public.list_sessions(TEXT)                TO argo_agent_base;
GRANT EXECUTE ON FUNCTION argo_public.get_session(INT)                   TO argo_agent_base;

-- operator-only additions
GRANT SELECT ON argo_public.v_session_audit    TO argo_operator;
GRANT SELECT ON argo_public.v_system_agents    TO argo_operator;
GRANT SELECT ON argo_public.v_compressible_logs TO argo_operator;
GRANT EXECUTE ON FUNCTION argo_public.create_agent(TEXT,JSONB)             TO argo_operator;
GRANT EXECUTE ON FUNCTION argo_public.activate_system_agent(TEXT,TEXT,JSONB) TO argo_operator;
GRANT EXECUTE ON FUNCTION argo_public.drop_agent(TEXT)                     TO argo_operator;
GRANT EXECUTE ON FUNCTION argo_public.list_agents()                        TO argo_operator;
GRANT EXECUTE ON FUNCTION argo_public.fn_purge_compressed_logs(INT,FLOAT)  TO argo_operator;

-- argo_sql_sandbox: SELECT on allowlisted views only
GRANT USAGE ON SCHEMA argo_public TO argo_sql_sandbox;
GRANT SELECT ON argo_public.v_my_tasks         TO argo_sql_sandbox;
GRANT SELECT ON argo_public.v_my_memory        TO argo_sql_sandbox;
GRANT SELECT ON argo_public.v_session_progress TO argo_sql_sandbox;
GRANT SELECT ON argo_public.v_ready_tasks      TO argo_sql_sandbox;

-- =============================================================================
-- 10. Indexes
-- =============================================================================
CREATE INDEX IF NOT EXISTS idx_tasks_agent_id       ON argo_private.tasks (agent_id);
CREATE INDEX IF NOT EXISTS idx_tasks_session_id     ON argo_private.tasks (session_id);
CREATE INDEX IF NOT EXISTS idx_tasks_status         ON argo_private.tasks (status);
CREATE INDEX IF NOT EXISTS idx_sessions_agent_id    ON argo_private.sessions (agent_id);
CREATE INDEX IF NOT EXISTS idx_sessions_status      ON argo_private.sessions (status);
CREATE INDEX IF NOT EXISTS idx_sessions_started_at  ON argo_private.sessions (started_at DESC);
CREATE INDEX IF NOT EXISTS idx_exec_logs_task_step  ON argo_private.execution_logs (task_id, step_number);
CREATE INDEX IF NOT EXISTS idx_exec_logs_uncompressed ON argo_private.execution_logs (task_id) WHERE compressed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_memory_agent_id      ON argo_private.memory (agent_id);
CREATE INDEX IF NOT EXISTS idx_memory_agent_created ON argo_private.memory (agent_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_agent_profile_role   ON argo_private.agent_profile_assignments (role_name);
CREATE INDEX IF NOT EXISTS idx_agent_msg_session    ON argo_private.agent_messages (session_id);
CREATE INDEX IF NOT EXISTS idx_task_dep_task        ON argo_private.task_dependencies (task_id);
CREATE INDEX IF NOT EXISTS idx_task_dep_dep         ON argo_private.task_dependencies (depends_on_task_id);
CREATE INDEX IF NOT EXISTS idx_exp_results          ON argo_private.experiment_results (experiment_id);

-- =============================================================================
-- 11. Triggers
-- =============================================================================

-- Auto-update tasks.updated_at
CREATE OR REPLACE FUNCTION argo_private.fn_tasks_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at:=now(); RETURN NEW; END;
$$;
CREATE TRIGGER trg_tasks_updated_at
    BEFORE UPDATE ON argo_private.tasks
    FOR EACH ROW EXECUTE FUNCTION argo_private.fn_tasks_updated_at();

-- Auto-update system_agent_configs.updated_at
CREATE OR REPLACE FUNCTION argo_private.fn_sac_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at:=now(); RETURN NEW; END;
$$;
CREATE TRIGGER trg_sac_updated_at
    BEFORE UPDATE ON argo_private.system_agent_configs
    FOR EACH ROW EXECUTE FUNCTION argo_private.fn_sac_updated_at();

-- pg_notify on session completion
CREATE OR REPLACE FUNCTION argo_private.fn_session_notify()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IN ('completed','failed') AND OLD.status='active' THEN
        PERFORM pg_notify('argo_session_done',json_build_object(
            'session_id',NEW.session_id,'status',NEW.status,
            'agent_id',NEW.agent_id,
            'final_answer',left(COALESCE(NEW.final_answer,''),500))::text);
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_session_notify
    AFTER UPDATE ON argo_private.sessions
    FOR EACH ROW EXECUTE FUNCTION argo_private.fn_session_notify();

-- pg_notify on pending task (supports worker LISTEN)
CREATE OR REPLACE FUNCTION argo_private.fn_task_notify()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status='pending' THEN
        PERFORM pg_notify('argo_task_ready',json_build_object(
            'task_id',NEW.task_id,'session_id',NEW.session_id,'agent_id',NEW.agent_id)::text);
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_task_notify
    AFTER INSERT OR UPDATE ON argo_private.tasks
    FOR EACH ROW EXECUTE FUNCTION argo_private.fn_task_notify();
