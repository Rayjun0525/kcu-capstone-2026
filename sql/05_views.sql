-- =============================================================
-- 05_views.sql — Public views (agent interface)
-- All views in alma_public, backed by alma_private tables
-- Agents connect as their own role — views filter by session_user
-- =============================================================

-- -------------------------------------------------------------
-- v_agent_context: Full agent context in one read
-- Returns current agent's profile, LLM config, active session
-- -------------------------------------------------------------
CREATE OR REPLACE VIEW alma_public.v_agent_context AS
SELECT
    am.agent_id,
    am.role_name,
    am.display_name,
    am.agent_role::TEXT            AS agent_role,
    ap.system_prompt,
    ap.max_steps,
    ap.max_retries,
    lc.provider::TEXT              AS llm_provider,
    lc.endpoint                    AS llm_endpoint,
    lc.model_name,
    lc.api_key_ref,
    lc.temperature,
    lc.max_tokens,
    lc.request_options,
    am.is_active
FROM alma_private.agent_meta         am
JOIN alma_private.agent_profile_assignments apa ON apa.agent_id = am.agent_id
JOIN alma_private.agent_profiles     ap  ON ap.profile_id = apa.profile_id
LEFT JOIN alma_private.llm_configs   lc  ON lc.llm_config_id = am.llm_config_id
WHERE am.role_name = session_user;

COMMENT ON VIEW alma_public.v_agent_context IS
    'Current agent full context — filtered by session_user automatically';

-- -------------------------------------------------------------
-- v_my_tasks: Current agent's pending/running tasks
-- -------------------------------------------------------------
CREATE OR REPLACE VIEW alma_public.v_my_tasks AS
SELECT
    t.task_id,
    t.session_id,
    t.description,
    t.status::TEXT   AS status,
    t.result,
    t.created_at,
    t.started_at,
    t.completed_at
FROM alma_private.tasks      t
JOIN alma_private.agent_meta am ON am.agent_id = t.agent_id
WHERE am.role_name = session_user
  AND t.status IN ('pending', 'running')
ORDER BY t.created_at;

COMMENT ON VIEW alma_public.v_my_tasks IS
    'Pending/running tasks for the current agent role';

-- -------------------------------------------------------------
-- v_my_memory: Current agent's memory (sorted by recency)
-- -------------------------------------------------------------
CREATE OR REPLACE VIEW alma_public.v_my_memory AS
SELECT
    m.memory_id,
    m.session_id,
    m.memory_type::TEXT  AS memory_type,
    m.content,
    m.importance,
    m.created_at,
    m.accessed_at,
    m.access_count
FROM alma_private.memory     m
JOIN alma_private.agent_meta am ON am.agent_id = m.agent_id
WHERE am.role_name = session_user
ORDER BY m.importance DESC, m.accessed_at DESC;

COMMENT ON VIEW alma_public.v_my_memory IS
    'Memory entries for the current agent, ordered by importance then recency';

-- -------------------------------------------------------------
-- v_session_progress: Active session summary for current agent
-- -------------------------------------------------------------
CREATE OR REPLACE VIEW alma_public.v_session_progress AS
SELECT
    s.session_id,
    s.task_prompt,
    s.status::TEXT    AS status,
    s.total_steps,
    s.started_at,
    s.ended_at,
    COUNT(el.log_id)  AS steps_executed,
    MAX(el.step_number) AS last_step
FROM alma_private.sessions       s
JOIN alma_private.agent_meta     am ON am.agent_id = s.agent_id
LEFT JOIN alma_private.execution_logs el ON el.session_id = s.session_id
WHERE am.role_name = session_user
GROUP BY s.session_id, s.task_prompt, s.status, s.total_steps, s.started_at, s.ended_at
ORDER BY s.started_at DESC;

COMMENT ON VIEW alma_public.v_session_progress IS
    'Session progress summary for the current agent';

-- -------------------------------------------------------------
-- v_session_audit: Full execution audit log (operator-only)
-- Agents can only see their own sessions; operators see all
-- -------------------------------------------------------------
CREATE OR REPLACE VIEW alma_public.v_session_audit AS
SELECT
    s.session_id,
    am.role_name       AS agent_role,
    am.display_name    AS agent_name,
    s.task_prompt,
    s.status::TEXT     AS session_status,
    el.step_number,
    el.action_type,
    el.action_result,
    el.duration_ms,
    el.executed_at
FROM alma_private.sessions       s
JOIN alma_private.agent_meta     am ON am.agent_id = s.agent_id
LEFT JOIN alma_private.execution_logs el ON el.session_id = s.session_id
WHERE am.role_name = session_user          -- agents see own sessions
   OR pg_has_role(session_user, 'alma_operator', 'member')  -- operators see all
ORDER BY s.started_at DESC, el.step_number;

COMMENT ON VIEW alma_public.v_session_audit IS
    'Full execution audit. Agents see own sessions; alma_operator sees all.';
