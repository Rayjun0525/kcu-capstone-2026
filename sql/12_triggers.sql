-- =============================================================
-- 12_triggers.sql — Automation triggers
-- 1. updated_at auto-refresh for mutable tables
-- 2. Session completion pg_notify
-- 3. Memory auto-compression (keep top-N by importance)
-- =============================================================

-- ── Helper: fn_set_updated_at ─────────────────────────────────
CREATE OR REPLACE FUNCTION alma_private.fn_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

-- Attach to mutable tables with updated_at column
CREATE TRIGGER trg_llm_configs_updated_at
    BEFORE UPDATE ON alma_private.llm_configs
    FOR EACH ROW EXECUTE FUNCTION alma_private.fn_set_updated_at();

CREATE TRIGGER trg_agent_profiles_updated_at
    BEFORE UPDATE ON alma_private.agent_profiles
    FOR EACH ROW EXECUTE FUNCTION alma_private.fn_set_updated_at();

-- ── Session completion notification ──────────────────────────
CREATE OR REPLACE FUNCTION alma_private.fn_notify_session_complete()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IN ('completed', 'failed', 'cancelled')
       AND OLD.status = 'active' THEN
        PERFORM pg_notify(
            'alma_session_complete',
            json_build_object(
                'session_id', NEW.session_id,
                'status',     NEW.status,
                'agent_id',   NEW.agent_id,
                'ended_at',   NEW.ended_at
            )::TEXT
        );
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_session_complete_notify
    AFTER UPDATE ON alma_private.sessions
    FOR EACH ROW EXECUTE FUNCTION alma_private.fn_notify_session_complete();

-- ── Task status notification ──────────────────────────────────
CREATE OR REPLACE FUNCTION alma_private.fn_notify_task_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status <> OLD.status THEN
        PERFORM pg_notify(
            'alma_task_update',
            json_build_object(
                'task_id',    NEW.task_id,
                'session_id', NEW.session_id,
                'agent_id',   NEW.agent_id,
                'status',     NEW.status
            )::TEXT
        );
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_task_status_notify
    AFTER UPDATE ON alma_private.tasks
    FOR EACH ROW EXECUTE FUNCTION alma_private.fn_notify_task_status();

-- ── Memory auto-compression ───────────────────────────────────
-- Keep top 1000 memories per agent (by importance DESC, then created_at DESC)
-- Triggered when memory count exceeds 1100 for an agent
CREATE OR REPLACE FUNCTION alma_private.fn_compress_memory()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INT;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM alma_private.memory
    WHERE agent_id = NEW.agent_id;

    IF v_count > 1100 THEN
        DELETE FROM alma_private.memory
        WHERE memory_id IN (
            SELECT memory_id
            FROM alma_private.memory
            WHERE agent_id = NEW.agent_id
            ORDER BY importance ASC, created_at ASC
            LIMIT (v_count - 1000)
        );
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_memory_compress
    AFTER INSERT ON alma_private.memory
    FOR EACH ROW EXECUTE FUNCTION alma_private.fn_compress_memory();

-- ── Memory access_at auto-refresh ────────────────────────────
-- (done via fn_search_memory UPDATE; no trigger needed for reads)
