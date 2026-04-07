-- =============================================================
-- 06_functions_core.sql — Session / task / memory management
-- All SECURITY DEFINER: use session_user for agent identity
-- Parameters: TEXT (cast to ENUM internally)
-- =============================================================

-- -------------------------------------------------------------
-- fn_create_session: Create a new session for the current agent
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION alma_public.fn_create_session(
    p_task_prompt TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = alma_private, alma_public, public
AS $$
DECLARE
    v_agent_id  UUID;
    v_session_id UUID;
BEGIN
    SELECT agent_id INTO v_agent_id
    FROM alma_private.agent_meta
    WHERE role_name = session_user AND is_active = TRUE;

    IF v_agent_id IS NULL THEN
        RAISE EXCEPTION 'No active agent found for role: %', session_user;
    END IF;

    INSERT INTO alma_private.sessions (agent_id, task_prompt, status)
    VALUES (v_agent_id, p_task_prompt, 'active')
    RETURNING session_id INTO v_session_id;

    RETURN v_session_id;
END;
$$;

-- -------------------------------------------------------------
-- fn_complete_session: Mark session completed / failed
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION alma_public.fn_complete_session(
    p_session_id    UUID,
    p_status        TEXT,           -- 'completed' / 'failed' / 'cancelled'
    p_final_answer  TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = alma_private, alma_public, public
AS $$
BEGIN
    UPDATE alma_private.sessions
    SET status       = p_status::alma_private.session_status,
        final_answer = p_final_answer,
        ended_at     = NOW()
    WHERE session_id = p_session_id;
END;
$$;

-- -------------------------------------------------------------
-- fn_create_task: Insert a task into the queue
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION alma_public.fn_create_task(
    p_session_id    UUID,
    p_description   TEXT,
    p_agent_role    TEXT DEFAULT NULL    -- NULL = current agent
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = alma_private, alma_public, public
AS $$
DECLARE
    v_agent_id  UUID;
    v_task_id   UUID;
BEGIN
    IF p_agent_role IS NULL THEN
        SELECT agent_id INTO v_agent_id
        FROM alma_private.agent_meta
        WHERE role_name = session_user;
    ELSE
        SELECT agent_id INTO v_agent_id
        FROM alma_private.agent_meta
        WHERE role_name = p_agent_role AND is_active = TRUE;
    END IF;

    IF v_agent_id IS NULL THEN
        RAISE EXCEPTION 'Agent not found: %', COALESCE(p_agent_role, session_user);
    END IF;

    INSERT INTO alma_private.tasks (session_id, agent_id, description, status)
    VALUES (p_session_id, v_agent_id, p_description, 'pending')
    RETURNING task_id INTO v_task_id;

    RETURN v_task_id;
END;
$$;

-- -------------------------------------------------------------
-- fn_update_task: Update task status and result
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION alma_public.fn_update_task(
    p_task_id   UUID,
    p_status    TEXT,
    p_result    TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = alma_private, alma_public, public
AS $$
BEGIN
    UPDATE alma_private.tasks
    SET status       = p_status::alma_private.task_status,
        result       = p_result,
        started_at   = CASE WHEN p_status = 'running'   THEN NOW() ELSE started_at END,
        completed_at = CASE WHEN p_status IN ('completed','failed','cancelled') THEN NOW() ELSE completed_at END
    WHERE task_id = p_task_id;
END;
$$;

-- -------------------------------------------------------------
-- fn_log_step: Record one execution step
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION alma_public.fn_log_step(
    p_session_id    UUID,
    p_step_number   INT,
    p_action_type   TEXT,
    p_input_context JSONB       DEFAULT NULL,
    p_llm_response  JSONB       DEFAULT NULL,
    p_action_result TEXT        DEFAULT NULL,
    p_duration_ms   INT         DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = alma_private, alma_public, public
AS $$
DECLARE
    v_agent_id  UUID;
    v_log_id    UUID;
BEGIN
    SELECT agent_id INTO v_agent_id
    FROM alma_private.sessions
    WHERE session_id = p_session_id;

    INSERT INTO alma_private.execution_logs (
        session_id, agent_id, step_number, action_type,
        input_context, llm_response, action_result, duration_ms
    ) VALUES (
        p_session_id, v_agent_id, p_step_number, p_action_type,
        p_input_context, p_llm_response, p_action_result, p_duration_ms
    )
    RETURNING log_id INTO v_log_id;

    -- Update session step counter
    UPDATE alma_private.sessions
    SET total_steps = p_step_number
    WHERE session_id = p_session_id;

    RETURN v_log_id;
END;
$$;

-- -------------------------------------------------------------
-- fn_save_memory: Store agent memory (with optional embedding)
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION alma_public.fn_save_memory(
    p_content       TEXT,
    p_memory_type   TEXT        DEFAULT 'episodic',
    p_session_id    UUID        DEFAULT NULL,
    p_importance    NUMERIC     DEFAULT 0.5,
    p_embedding     vector(1536) DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = alma_private, alma_public, public
AS $$
DECLARE
    v_agent_id  UUID;
    v_memory_id UUID;
BEGIN
    SELECT agent_id INTO v_agent_id
    FROM alma_private.agent_meta
    WHERE role_name = session_user AND is_active = TRUE;

    IF v_agent_id IS NULL THEN
        RAISE EXCEPTION 'No active agent found for role: %', session_user;
    END IF;

    INSERT INTO alma_private.memory (
        agent_id, session_id, memory_type,
        content, embedding, importance
    ) VALUES (
        v_agent_id, p_session_id, p_memory_type::alma_private.memory_type,
        p_content, p_embedding, p_importance
    )
    RETURNING memory_id INTO v_memory_id;

    RETURN v_memory_id;
END;
$$;

-- -------------------------------------------------------------
-- fn_search_memory: Vector similarity search in memory
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION alma_public.fn_search_memory(
    p_query_embedding   vector(1536),
    p_limit             INT DEFAULT 5,
    p_memory_type       TEXT DEFAULT NULL
)
RETURNS TABLE (
    memory_id   UUID,
    content     TEXT,
    memory_type TEXT,
    importance  NUMERIC,
    similarity  FLOAT,
    created_at  TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = alma_private, alma_public, public
AS $$
DECLARE
    v_agent_id UUID;
BEGIN
    SELECT agent_id INTO v_agent_id
    FROM alma_private.agent_meta
    WHERE role_name = session_user;

    RETURN QUERY
    SELECT
        m.memory_id,
        m.content,
        m.memory_type::TEXT,
        m.importance,
        1 - (m.embedding <=> p_query_embedding) AS similarity,
        m.created_at
    FROM alma_private.memory m
    WHERE m.agent_id = v_agent_id
      AND m.embedding IS NOT NULL
      AND (p_memory_type IS NULL OR m.memory_type::TEXT = p_memory_type)
    ORDER BY m.embedding <=> p_query_embedding
    LIMIT p_limit;

    -- Update access tracking
    UPDATE alma_private.memory
    SET accessed_at  = NOW(),
        access_count = access_count + 1
    WHERE agent_id = v_agent_id
      AND embedding IS NOT NULL
      AND (p_memory_type IS NULL OR memory_type::TEXT = p_memory_type);
END;
$$;

-- -------------------------------------------------------------
-- fn_execute_sql: SELECT-only SQL executor (no writes)
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION alma_public.fn_execute_sql(
    p_sql TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = alma_private, alma_public, public
AS $$
DECLARE
    v_normalized TEXT;
    v_result     TEXT;
    v_refcursor  REFCURSOR;
    v_row        RECORD;
    v_rows       TEXT[] := '{}';
    v_header     TEXT;
    v_cols       TEXT[];
BEGIN
    v_normalized := upper(trim(regexp_replace(p_sql, '\s+', ' ', 'g')));

    -- Strict SELECT-only guard
    IF v_normalized NOT LIKE 'SELECT%' THEN
        RAISE EXCEPTION 'fn_execute_sql: only SELECT statements are allowed. Got: %',
            substring(v_normalized FROM 1 FOR 50);
    END IF;

    -- Additional injection guard: block stacked statements
    IF v_normalized LIKE '%;%' THEN
        RAISE EXCEPTION 'fn_execute_sql: stacked statements (;) are not allowed';
    END IF;

    OPEN v_refcursor FOR EXECUTE p_sql;

    LOOP
        FETCH v_refcursor INTO v_row;
        EXIT WHEN NOT FOUND;
        v_rows := array_append(v_rows, row_to_json(v_row)::TEXT);
        EXIT WHEN array_length(v_rows, 1) >= 500;  -- row limit
    END LOOP;

    CLOSE v_refcursor;

    v_result := '[' || array_to_string(v_rows, ',') || ']';
    RETURN v_result;
END;
$$;

-- -------------------------------------------------------------
-- fn_record_message: Record inter-agent message
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION alma_public.fn_record_message(
    p_session_id    UUID,
    p_to_role       TEXT,
    p_message_type  TEXT,
    p_content       TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = alma_private, alma_public, public
AS $$
DECLARE
    v_from_agent_id UUID;
    v_to_agent_id   UUID;
    v_message_id    UUID;
BEGIN
    SELECT agent_id INTO v_from_agent_id
    FROM alma_private.agent_meta WHERE role_name = session_user;

    SELECT agent_id INTO v_to_agent_id
    FROM alma_private.agent_meta WHERE role_name = p_to_role;

    INSERT INTO alma_private.agent_messages (
        session_id, from_agent_id, to_agent_id, message_type, content
    ) VALUES (
        p_session_id, v_from_agent_id, v_to_agent_id, p_message_type, p_content
    )
    RETURNING message_id INTO v_message_id;

    RETURN v_message_id;
END;
$$;
