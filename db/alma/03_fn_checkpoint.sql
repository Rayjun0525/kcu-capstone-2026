-- ALMA: fn_checkpoint
-- Called by the Group B agent loop between every LLM turn.
-- Returns a JSONB status object that drives the agent's next action.
--
-- Possible return values:
--   {"status": "ok"}
--       → proceed normally
--   {"status": "replan_required", "reason": "last_execution_rolled_back", "task_id": "..."}
--       → the last SQL was rolled back; LLM must be informed and replan
--   {"status": "pending_approval", "approval_id": "...", "task_id": "..."}
--       → an approval_request is still open; agent should wait
--   {"status": "no_session"}
--       → the session_id is invalid

CREATE OR REPLACE FUNCTION alma.fn_checkpoint(p_session_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_last_task_id     UUID;
    v_last_task_status TEXT;
    v_pending_approval UUID;
    v_session_exists   BOOLEAN;
BEGIN
    -- Validate session
    SELECT EXISTS (
        SELECT 1 FROM alma.sessions WHERE id = p_session_id
    ) INTO v_session_exists;

    IF NOT v_session_exists THEN
        RETURN jsonb_build_object('status', 'no_session');
    END IF;

    -- Check for open approval requests on this session's tasks
    SELECT ar.id INTO v_pending_approval
    FROM alma.approval_requests ar
    JOIN alma.tasks t ON t.id = ar.task_id
    WHERE t.session_id = p_session_id
      AND ar.status = 'pending'
    ORDER BY ar.requested_at DESC
    LIMIT 1;

    IF v_pending_approval IS NOT NULL THEN
        SELECT t.id INTO v_last_task_id
        FROM alma.approval_requests ar
        JOIN alma.tasks t ON t.id = ar.task_id
        WHERE ar.id = v_pending_approval;

        RETURN jsonb_build_object(
            'status',       'pending_approval',
            'approval_id',  v_pending_approval,
            'task_id',      v_last_task_id
        );
    END IF;

    -- Check the most recent task for this session
    SELECT id, status
    INTO v_last_task_id, v_last_task_status
    FROM alma.tasks
    WHERE session_id = p_session_id
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_last_task_status = 'rolled_back' THEN
        RETURN jsonb_build_object(
            'status',   'replan_required',
            'reason',   'last_execution_rolled_back',
            'task_id',  v_last_task_id
        );
    END IF;

    RETURN jsonb_build_object('status', 'ok');
END;
$$;

COMMENT ON FUNCTION alma.fn_checkpoint(UUID) IS
    'Gate called between every LLM turn in Group B. '
    'Returns ok / replan_required / pending_approval / no_session. '
    'replan_required is triggered when a task status is rolled_back, '
    'ensuring the LLM is never allowed to proceed after a silent failure (V4).';
