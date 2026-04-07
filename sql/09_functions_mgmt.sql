-- =============================================================
-- 09_functions_mgmt.sql — Agent lifecycle management
-- create_agent / drop_agent / list_agents / list_sessions / get_session
-- =============================================================

-- -------------------------------------------------------------
-- create_agent: Create a new agent (Role + all metadata)
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION alma_public.create_agent(
    p_role_name     TEXT,
    p_name          TEXT,
    p_agent_role    TEXT        DEFAULT 'executor',
    p_provider      TEXT        DEFAULT 'ollama',
    p_endpoint      TEXT        DEFAULT 'http://localhost:11434/api/chat',
    p_model_name    TEXT        DEFAULT 'llama3.2',
    p_api_key_ref   TEXT        DEFAULT NULL,
    p_temperature   NUMERIC     DEFAULT 0.0,
    p_max_tokens    INT         DEFAULT 2048,
    p_request_opts  JSONB       DEFAULT '{}',
    p_system_prompt TEXT        DEFAULT 'You are a helpful AI assistant.',
    p_max_steps     INT         DEFAULT 10,
    p_max_retries   INT         DEFAULT 3
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = alma_private, alma_public, public
AS $$
DECLARE
    v_llm_config_id     UUID;
    v_profile_id        UUID;
    v_agent_id          UUID;
    v_assignment_id     UUID;
BEGIN
    -- ── 1. Validate inputs ─────────────────────────────────
    IF p_role_name ~ '[^a-zA-Z0-9_]' THEN
        RAISE EXCEPTION 'Invalid role name. Use only alphanumeric characters and underscores.';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = p_role_name) THEN
        RAISE EXCEPTION 'PostgreSQL role already exists: %', p_role_name;
    END IF;

    IF EXISTS (SELECT 1 FROM alma_private.agent_meta WHERE role_name = p_role_name) THEN
        RAISE EXCEPTION 'Agent already registered: %', p_role_name;
    END IF;

    -- ── 2. Create PostgreSQL role ───────────────────────────
    EXECUTE format('CREATE ROLE %I LOGIN', p_role_name);
    EXECUTE format('GRANT alma_agent_base TO %I', p_role_name);
    EXECUTE format('GRANT USAGE ON SCHEMA alma_public TO %I', p_role_name);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION alma_public.run_agent(TEXT, TEXT) TO %I',
        p_role_name
    );
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION alma_public.fn_execute_sql(TEXT) TO %I',
        p_role_name
    );
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA alma_public TO %I', p_role_name);

    -- ── 3. llm_configs ─────────────────────────────────────
    INSERT INTO alma_private.llm_configs (
        provider, endpoint, model_name, api_key_ref,
        temperature, max_tokens, request_options
    ) VALUES (
        p_provider::alma_private.llm_provider,
        p_endpoint, p_model_name, p_api_key_ref,
        p_temperature, p_max_tokens, p_request_opts
    )
    RETURNING llm_config_id INTO v_llm_config_id;

    -- ── 4. agent_profiles ──────────────────────────────────
    INSERT INTO alma_private.agent_profiles (
        name, system_prompt, max_steps, max_retries
    ) VALUES (
        p_name || ' profile', p_system_prompt, p_max_steps, p_max_retries
    )
    RETURNING profile_id INTO v_profile_id;

    -- ── 5. agent_meta ──────────────────────────────────────
    INSERT INTO alma_private.agent_meta (
        role_name, display_name, agent_role, llm_config_id, profile_id
    ) VALUES (
        p_role_name, p_name,
        p_agent_role::alma_private.agent_role,
        v_llm_config_id, v_profile_id
    )
    RETURNING agent_id INTO v_agent_id;

    -- ── 6. agent_profile_assignments ───────────────────────
    INSERT INTO alma_private.agent_profile_assignments (agent_id, profile_id)
    VALUES (v_agent_id, v_profile_id)
    RETURNING assignment_id INTO v_assignment_id;

    RETURN jsonb_build_object(
        'status',       'created',
        'agent_id',     v_agent_id,
        'role_name',    p_role_name,
        'llm_config_id', v_llm_config_id,
        'profile_id',   v_profile_id
    );

EXCEPTION WHEN OTHERS THEN
    -- Attempt cleanup if role was created before failure
    BEGIN
        EXECUTE format('DROP ROLE IF EXISTS %I', p_role_name);
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;
    RAISE;
END;
$$;

-- -------------------------------------------------------------
-- drop_agent: Deactivate or permanently remove an agent
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION alma_public.drop_agent(
    p_role_name TEXT,
    p_permanent BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = alma_private, alma_public, public
AS $$
DECLARE
    v_agent_id UUID;
BEGIN
    SELECT agent_id INTO v_agent_id
    FROM alma_private.agent_meta
    WHERE role_name = p_role_name;

    IF v_agent_id IS NULL THEN
        RAISE EXCEPTION 'Agent not found: %', p_role_name;
    END IF;

    IF p_permanent THEN
        -- Hard delete (cascade on FK)
        DELETE FROM alma_private.agent_meta WHERE agent_id = v_agent_id;
        EXECUTE format('DROP ROLE IF EXISTS %I', p_role_name);
        RETURN jsonb_build_object('status', 'dropped', 'role_name', p_role_name);
    ELSE
        -- Soft deactivation
        UPDATE alma_private.agent_meta
        SET is_active = FALSE
        WHERE agent_id = v_agent_id;
        RETURN jsonb_build_object('status', 'deactivated', 'role_name', p_role_name);
    END IF;
END;
$$;

-- -------------------------------------------------------------
-- list_agents: Show all registered agents
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION alma_public.list_agents(
    p_active_only BOOLEAN DEFAULT TRUE
)
RETURNS TABLE (
    agent_id        UUID,
    role_name       TEXT,
    display_name    TEXT,
    agent_role      TEXT,
    llm_provider    TEXT,
    model_name      TEXT,
    is_active       BOOLEAN,
    created_at      TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = alma_private, alma_public, public
AS $$
BEGIN
    RETURN QUERY
    SELECT
        am.agent_id,
        am.role_name,
        am.display_name,
        am.agent_role::TEXT,
        lc.provider::TEXT,
        lc.model_name,
        am.is_active,
        am.created_at
    FROM alma_private.agent_meta am
    LEFT JOIN alma_private.llm_configs lc ON lc.llm_config_id = am.llm_config_id
    WHERE (NOT p_active_only OR am.is_active = TRUE)
    ORDER BY am.created_at;
END;
$$;

-- -------------------------------------------------------------
-- list_sessions: Session history for an agent (or all)
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION alma_public.list_sessions(
    p_agent_role    TEXT    DEFAULT NULL,
    p_limit         INT     DEFAULT 20
)
RETURNS TABLE (
    session_id      UUID,
    agent_role      TEXT,
    task_prompt     TEXT,
    status          TEXT,
    total_steps     INT,
    final_answer    TEXT,
    started_at      TIMESTAMPTZ,
    ended_at        TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = alma_private, alma_public, public
AS $$
BEGIN
    RETURN QUERY
    SELECT
        s.session_id,
        am.role_name,
        s.task_prompt,
        s.status::TEXT,
        s.total_steps,
        s.final_answer,
        s.started_at,
        s.ended_at
    FROM alma_private.sessions s
    JOIN alma_private.agent_meta am ON am.agent_id = s.agent_id
    WHERE (p_agent_role IS NULL OR am.role_name = p_agent_role)
      AND (am.role_name = session_user
           OR pg_has_role(session_user, 'alma_operator', 'member'))
    ORDER BY s.started_at DESC
    LIMIT p_limit;
END;
$$;

-- -------------------------------------------------------------
-- get_session: Full audit log for a session
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION alma_public.get_session(
    p_session_id UUID
)
RETURNS TABLE (
    step_number     INT,
    action_type     TEXT,
    action_result   TEXT,
    duration_ms     INT,
    executed_at     TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = alma_private, alma_public, public
AS $$
DECLARE
    v_agent_role TEXT;
BEGIN
    SELECT am.role_name INTO v_agent_role
    FROM alma_private.sessions s
    JOIN alma_private.agent_meta am ON am.agent_id = s.agent_id
    WHERE s.session_id = p_session_id;

    -- Access control: only own sessions or operator
    IF v_agent_role <> session_user
       AND NOT pg_has_role(session_user, 'alma_operator', 'member') THEN
        RAISE EXCEPTION 'Access denied to session %', p_session_id;
    END IF;

    RETURN QUERY
    SELECT
        el.step_number,
        el.action_type,
        el.action_result,
        el.duration_ms,
        el.executed_at
    FROM alma_private.execution_logs el
    WHERE el.session_id = p_session_id
    ORDER BY el.step_number;
END;
$$;

COMMENT ON FUNCTION alma_public.create_agent IS
    'Create a new agent: PostgreSQL Role + LLM config + profile + meta in one call';
COMMENT ON FUNCTION alma_public.drop_agent IS
    'Deactivate (default) or permanently drop an agent and its PostgreSQL role';
COMMENT ON FUNCTION alma_public.list_agents IS
    'List registered agents. Operators see all; agents see all active agents.';
