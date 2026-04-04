-- ALMA: fn_execute_and_validate
-- Pure SQL helper used by the Python agent (Group B) to record task outcomes.
-- The actual SQL execution happens in Python (with savepoint control);
-- this function handles the classification and post-execution bookkeeping.

-- ── Helper: record an execution outcome ──────────────────────────────────────

CREATE OR REPLACE FUNCTION alma.record_execution(
    p_task_id       UUID,
    p_session_id    UUID,
    p_group_label   CHAR,
    p_sql_text      TEXT,
    p_outcome       TEXT,           -- success | error | blocked | rolled_back
    p_error_message TEXT    DEFAULT NULL,
    p_duration_ms   INT     DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_log_id UUID;
BEGIN
    INSERT INTO alma.execution_logs (
        task_id, session_id, group_label, sql_text,
        outcome, error_message, duration_ms
    ) VALUES (
        p_task_id, p_session_id, p_group_label, p_sql_text,
        p_outcome, p_error_message, p_duration_ms
    )
    RETURNING id INTO v_log_id;

    -- Sync task status
    UPDATE alma.tasks
    SET status = CASE p_outcome
                     WHEN 'success'     THEN 'executed'
                     WHEN 'blocked'     THEN 'blocked'
                     WHEN 'rolled_back' THEN 'rolled_back'
                     ELSE 'error'
                 END
    WHERE id = p_task_id;

    RETURN v_log_id;
END;
$$;

-- ── Helper: create a task and classify the SQL ───────────────────────────────

CREATE OR REPLACE FUNCTION alma.create_task(
    p_session_id UUID,
    p_sql_text   TEXT
)
RETURNS TABLE (
    task_id         UUID,
    sql_type        TEXT,
    is_irreversible BOOLEAN
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_task_id        UUID;
    v_sql_type       TEXT;
    v_is_irreversible BOOLEAN;
BEGIN
    -- Classify first
    SELECT t.sql_type, t.is_irreversible
    INTO v_sql_type, v_is_irreversible
    FROM alma.fn_select_tool(p_sql_text) t;

    -- Persist task
    INSERT INTO alma.tasks (session_id, sql_text, sql_type, is_irreversible)
    VALUES (p_session_id, p_sql_text, v_sql_type, v_is_irreversible)
    RETURNING id INTO v_task_id;

    RETURN QUERY SELECT v_task_id, v_sql_type, v_is_irreversible;
END;
$$;

-- ── Helper: open an approval request and notify ──────────────────────────────

CREATE OR REPLACE FUNCTION alma.request_approval(p_task_id UUID)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_approval_id UUID;
    v_sql_text    TEXT;
BEGIN
    INSERT INTO alma.approval_requests (task_id)
    VALUES (p_task_id)
    RETURNING id INTO v_approval_id;

    -- Update task status
    UPDATE alma.tasks SET status = 'pending' WHERE id = p_task_id;

    -- Fetch SQL for notification payload
    SELECT sql_text INTO v_sql_text FROM alma.tasks WHERE id = p_task_id;

    -- Notify approval_worker
    PERFORM pg_notify(
        'alma_approval',
        json_build_object(
            'approval_id', v_approval_id,
            'task_id',     p_task_id,
            'sql_text',    v_sql_text
        )::TEXT
    );

    RETURN v_approval_id;
END;
$$;

-- ── Helper: resolve an approval request ─────────────────────────────────────

CREATE OR REPLACE FUNCTION alma.resolve_approval(
    p_approval_id UUID,
    p_decision    TEXT  -- 'approved' | 'denied' | 'timeout'
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE alma.approval_requests
    SET status      = p_decision,
        resolved_at = NOW()
    WHERE id = p_approval_id;

    IF p_decision = 'approved' THEN
        UPDATE alma.tasks
        SET status = 'approved'
        WHERE id = (SELECT task_id FROM alma.approval_requests WHERE id = p_approval_id);
    END IF;
END;
$$;

COMMENT ON FUNCTION alma.create_task(UUID, TEXT) IS
    'Creates a task record and classifies the SQL. '
    'Returns task_id, sql_type, is_irreversible for the caller to act on.';

COMMENT ON FUNCTION alma.request_approval(UUID) IS
    'Inserts an approval_request and fires pg_notify(''alma_approval'', ...). '
    'The approval_worker LISTENs on this channel.';

COMMENT ON FUNCTION alma.record_execution(UUID, UUID, CHAR, TEXT, TEXT, TEXT, INT) IS
    'Persists an execution outcome and syncs the task status. '
    'Group B calls this ONLY on success or blocked — never on rollback. '
    'This deliberate omission is what fn_checkpoint detects for V4.';
