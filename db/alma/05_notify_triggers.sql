-- ALMA: pg_notify triggers
-- Fires notifications for the approval_worker and monitoring tooling.

-- ── Trigger: notify when a new approval_request is inserted ─────────────────
-- (Belt-and-suspenders: request_approval() already calls pg_notify directly,
--  but this trigger covers any direct INSERT path, e.g. from psql or tests.)

CREATE OR REPLACE FUNCTION alma._trg_approval_inserted()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_sql_text TEXT;
BEGIN
    SELECT sql_text INTO v_sql_text
    FROM alma.tasks
    WHERE id = NEW.task_id;

    PERFORM pg_notify(
        'alma_approval',
        json_build_object(
            'event',       'new_request',
            'approval_id', NEW.id,
            'task_id',     NEW.task_id,
            'sql_text',    v_sql_text
        )::TEXT
    );

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_approval_inserted ON alma.approval_requests;
CREATE TRIGGER trg_approval_inserted
    AFTER INSERT ON alma.approval_requests
    FOR EACH ROW
    EXECUTE FUNCTION alma._trg_approval_inserted();

-- ── Trigger: notify when an approval_request is resolved ────────────────────

CREATE OR REPLACE FUNCTION alma._trg_approval_resolved()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status = 'pending' AND NEW.status <> 'pending' THEN
        PERFORM pg_notify(
            'alma_approval_resolved',
            json_build_object(
                'event',       'resolved',
                'approval_id', NEW.id,
                'task_id',     NEW.task_id,
                'decision',    NEW.status
            )::TEXT
        );
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_approval_resolved ON alma.approval_requests;
CREATE TRIGGER trg_approval_resolved
    AFTER UPDATE ON alma.approval_requests
    FOR EACH ROW
    EXECUTE FUNCTION alma._trg_approval_resolved();

-- ── Trigger: notify when a session status changes ───────────────────────────

CREATE OR REPLACE FUNCTION alma._trg_session_status_changed()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status <> NEW.status THEN
        PERFORM pg_notify(
            'alma_session',
            json_build_object(
                'event',       'status_change',
                'session_id',  NEW.id,
                'scenario_id', NEW.scenario_id,
                'old_status',  OLD.status,
                'new_status',  NEW.status
            )::TEXT
        );
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_session_status_changed ON alma.sessions;
CREATE TRIGGER trg_session_status_changed
    AFTER UPDATE ON alma.sessions
    FOR EACH ROW
    EXECUTE FUNCTION alma._trg_session_status_changed();
