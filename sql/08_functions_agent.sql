-- =============================================================
-- 08_functions_agent.sql — run_agent / run_multi_agent
-- Core agent execution loops — all state lives in DB
-- =============================================================

-- -------------------------------------------------------------
-- run_agent: Single-agent execution loop
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION alma_public.run_agent(
    p_agent_role    TEXT,
    p_task_prompt   TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = alma_private, alma_public, public
AS $$
DECLARE
    v_agent_id      UUID;
    v_session_id    UUID;
    v_task_id       UUID;
    v_profile       RECORD;
    v_llm_config    RECORD;
    v_messages      JSONB;
    v_llm_result    JSONB;
    v_content       TEXT;
    v_action        JSONB;
    v_action_type   TEXT;
    v_sql           TEXT;
    v_sql_result    TEXT;
    v_final_answer  TEXT;
    v_step          INT := 0;
    v_start_ms      BIGINT;
    v_duration_ms   INT;
BEGIN
    -- ── Resolve agent ─────────────────────────────────────
    SELECT am.agent_id, ap.system_prompt, ap.max_steps, ap.max_retries,
           am.llm_config_id
    INTO v_agent_id, v_profile.system_prompt, v_profile.max_steps,
         v_profile.max_retries, v_llm_config
    FROM alma_private.agent_meta am
    JOIN alma_private.agent_profile_assignments apa ON apa.agent_id = am.agent_id
    JOIN alma_private.agent_profiles ap ON ap.profile_id = apa.profile_id
    WHERE am.role_name = p_agent_role AND am.is_active = TRUE
    LIMIT 1;

    IF v_agent_id IS NULL THEN
        RAISE EXCEPTION 'Agent not found or inactive: %', p_agent_role;
    END IF;

    -- ── Create session & task ─────────────────────────────
    INSERT INTO alma_private.sessions (agent_id, task_prompt, status)
    VALUES (v_agent_id, p_task_prompt, 'active')
    RETURNING session_id INTO v_session_id;

    INSERT INTO alma_private.tasks (session_id, agent_id, description, status)
    VALUES (v_session_id, v_agent_id, p_task_prompt, 'running')
    RETURNING task_id INTO v_task_id;

    -- ── Initial message list ──────────────────────────────
    v_messages := jsonb_build_array(
        jsonb_build_object('role', 'system',
            'content', v_profile.system_prompt ||
            E'\n\nYou must respond ONLY with valid JSON in this exact format:\n' ||
            '{"thought": "<your reasoning>", "action": "<execute_sql|finish>", ' ||
            '"sql": "<SQL if action=execute_sql>", ' ||
            '"final_answer": "<answer if action=finish>"}'),
        jsonb_build_object('role', 'user', 'content', p_task_prompt)
    );

    -- ── Agent loop ────────────────────────────────────────
    WHILE v_step < v_profile.max_steps LOOP
        v_step := v_step + 1;
        v_start_ms := EXTRACT(EPOCH FROM clock_timestamp()) * 1000;

        -- Call LLM
        BEGIN
            v_llm_result := alma_private.fn_call_llm(v_agent_id, v_messages)::JSONB;
        EXCEPTION WHEN OTHERS THEN
            PERFORM alma_public.fn_log_step(
                v_session_id, v_step, 'error',
                v_messages, NULL,
                'LLM call failed: ' || SQLERRM,
                (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::INT - v_start_ms::INT
            );
            RAISE;
        END;

        v_content     := v_llm_result->>'content';
        v_duration_ms := (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::INT - v_start_ms::INT;

        -- Parse JSON action from LLM
        BEGIN
            -- Strip markdown code blocks if present
            v_content := regexp_replace(v_content, '^```(json)?', '', 'g');
            v_content := regexp_replace(v_content, '```$',        '', 'g');
            v_content := trim(v_content);
            v_action  := v_content::JSONB;
        EXCEPTION WHEN OTHERS THEN
            v_action := jsonb_build_object(
                'thought', 'parse error',
                'action',  'error',
                'raw',     v_content
            );
        END;

        v_action_type := v_action->>'action';

        -- ── execute_sql ───────────────────────────────────
        IF v_action_type = 'execute_sql' THEN
            v_sql := v_action->>'sql';

            BEGIN
                v_sql_result := alma_public.fn_execute_sql(v_sql);
            EXCEPTION WHEN OTHERS THEN
                v_sql_result := 'ERROR: ' || SQLERRM;
            END;

            PERFORM alma_public.fn_log_step(
                v_session_id, v_step, 'execute_sql',
                v_messages, v_llm_result,
                v_sql_result, v_duration_ms
            );

            -- Feed result back into message history
            v_messages := v_messages
                || jsonb_build_object('role', 'assistant', 'content', v_content)
                || jsonb_build_object('role', 'user',
                    'content', 'SQL result: ' || COALESCE(v_sql_result, 'null'));

        -- ── finish ────────────────────────────────────────
        ELSIF v_action_type = 'finish' THEN
            v_final_answer := v_action->>'final_answer';

            PERFORM alma_public.fn_log_step(
                v_session_id, v_step, 'finish',
                v_messages, v_llm_result,
                v_final_answer, v_duration_ms
            );

            -- Save episodic memory
            PERFORM alma_private.fn_save_memory_internal(
                v_agent_id, v_session_id,
                p_task_prompt || ' → ' || COALESCE(v_final_answer, ''),
                'episodic', 0.6
            );

            -- Complete session and task
            UPDATE alma_private.sessions
            SET status = 'completed', final_answer = v_final_answer, ended_at = NOW()
            WHERE session_id = v_session_id;

            UPDATE alma_private.tasks
            SET status = 'completed', result = v_final_answer, completed_at = NOW()
            WHERE task_id = v_task_id;

            -- Notify watchers
            PERFORM pg_notify(
                'alma_session_complete',
                json_build_object('session_id', v_session_id, 'agent', p_agent_role)::TEXT
            );

            RETURN v_final_answer;

        -- ── unknown / error ───────────────────────────────
        ELSE
            PERFORM alma_public.fn_log_step(
                v_session_id, v_step, 'error',
                v_messages, v_llm_result,
                'Unknown action: ' || COALESCE(v_action_type, 'null'),
                v_duration_ms
            );
            -- Add error context and retry
            v_messages := v_messages
                || jsonb_build_object('role', 'assistant', 'content', v_content)
                || jsonb_build_object('role', 'user',
                    'content',
                    'Your response was not valid JSON or had an unknown action. ' ||
                    'Please respond with exactly: {"thought":"...","action":"execute_sql|finish",' ||
                    '"sql":"...","final_answer":"..."}');
        END IF;
    END LOOP;

    -- ── Max steps exceeded ────────────────────────────────
    UPDATE alma_private.sessions
    SET status = 'failed', ended_at = NOW()
    WHERE session_id = v_session_id;

    UPDATE alma_private.tasks
    SET status = 'failed', completed_at = NOW()
    WHERE task_id = v_task_id;

    RETURN 'FAILED: max steps (' || v_profile.max_steps || ') exceeded';
END;
$$;

-- Internal helper: save memory without session_user restriction
CREATE OR REPLACE FUNCTION alma_private.fn_save_memory_internal(
    p_agent_id      UUID,
    p_session_id    UUID,
    p_content       TEXT,
    p_memory_type   TEXT    DEFAULT 'episodic',
    p_importance    NUMERIC DEFAULT 0.5
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_memory_id UUID;
BEGIN
    INSERT INTO alma_private.memory (
        agent_id, session_id, memory_type, content, importance
    ) VALUES (
        p_agent_id, p_session_id,
        p_memory_type::alma_private.memory_type,
        p_content, p_importance
    )
    RETURNING memory_id INTO v_memory_id;
    RETURN v_memory_id;
END;
$$;

-- -------------------------------------------------------------
-- run_multi_agent: Orchestrator-driven multi-agent execution
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION alma_public.run_multi_agent(
    p_orchestrator_role TEXT,
    p_goal              TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = alma_private, alma_public, public
AS $$
DECLARE
    v_agent_id      UUID;
    v_session_id    UUID;
    v_task_id       UUID;
    v_profile       RECORD;
    v_messages      JSONB;
    v_llm_result    JSONB;
    v_content       TEXT;
    v_action        JSONB;
    v_action_type   TEXT;
    v_delegate_role TEXT;
    v_delegate_task TEXT;
    v_sub_result    TEXT;
    v_final_answer  TEXT;
    v_step          INT := 0;
    v_start_ms      BIGINT;
    v_duration_ms   INT;
BEGIN
    -- ── Resolve orchestrator ──────────────────────────────
    SELECT am.agent_id, ap.system_prompt, ap.max_steps, ap.max_retries
    INTO v_agent_id, v_profile.system_prompt, v_profile.max_steps, v_profile.max_retries
    FROM alma_private.agent_meta am
    JOIN alma_private.agent_profile_assignments apa ON apa.agent_id = am.agent_id
    JOIN alma_private.agent_profiles ap ON ap.profile_id = apa.profile_id
    WHERE am.role_name = p_orchestrator_role AND am.is_active = TRUE
    LIMIT 1;

    IF v_agent_id IS NULL THEN
        RAISE EXCEPTION 'Orchestrator not found or inactive: %', p_orchestrator_role;
    END IF;

    -- ── Create session & task ─────────────────────────────
    INSERT INTO alma_private.sessions (agent_id, task_prompt, status)
    VALUES (v_agent_id, p_goal, 'active')
    RETURNING session_id INTO v_session_id;

    INSERT INTO alma_private.tasks (session_id, agent_id, description, status)
    VALUES (v_session_id, v_agent_id, p_goal, 'running')
    RETURNING task_id INTO v_task_id;

    -- ── Initial messages ──────────────────────────────────
    v_messages := jsonb_build_array(
        jsonb_build_object('role', 'system',
            'content', v_profile.system_prompt ||
            E'\n\nYou are an orchestrator. Respond ONLY with valid JSON:\n' ||
            '{"thought":"<reasoning>","action":"<delegate|finish>",' ||
            '"agent_role":"<role if delegate>","task":"<task if delegate>",' ||
            '"final_answer":"<answer if finish>"}'),
        jsonb_build_object('role', 'user', 'content', p_goal)
    );

    -- ── Orchestrator loop ─────────────────────────────────
    WHILE v_step < v_profile.max_steps LOOP
        v_step := v_step + 1;
        v_start_ms := EXTRACT(EPOCH FROM clock_timestamp()) * 1000;

        v_llm_result  := alma_private.fn_call_llm(v_agent_id, v_messages)::JSONB;
        v_content     := v_llm_result->>'content';
        v_duration_ms := (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::INT - v_start_ms::INT;

        BEGIN
            v_content := regexp_replace(v_content, '^```(json)?', '', 'g');
            v_content := regexp_replace(v_content, '```$',        '', 'g');
            v_content := trim(v_content);
            v_action  := v_content::JSONB;
        EXCEPTION WHEN OTHERS THEN
            v_action := '{"action":"error"}'::JSONB;
        END;

        v_action_type := v_action->>'action';

        -- ── delegate ──────────────────────────────────────
        IF v_action_type = 'delegate' THEN
            v_delegate_role := v_action->>'agent_role';
            v_delegate_task := v_action->>'task';

            PERFORM alma_public.fn_log_step(
                v_session_id, v_step, 'delegate',
                v_messages, v_llm_result,
                'delegating to ' || v_delegate_role || ': ' || v_delegate_task,
                v_duration_ms
            );

            -- Record outbound message
            PERFORM alma_public.fn_record_message(
                v_session_id, v_delegate_role, 'instruction', v_delegate_task
            );

            -- Execute sub-agent
            BEGIN
                v_sub_result := alma_public.run_agent(v_delegate_role, v_delegate_task);
            EXCEPTION WHEN OTHERS THEN
                v_sub_result := 'ERROR: ' || SQLERRM;
            END;

            -- Record result
            PERFORM alma_public.fn_record_message(
                v_session_id, p_orchestrator_role, 'result', v_sub_result
            );

            -- Feed sub-result back to orchestrator
            v_messages := v_messages
                || jsonb_build_object('role', 'assistant', 'content', v_content)
                || jsonb_build_object('role', 'user',
                    'content', 'Sub-agent [' || v_delegate_role || '] result: ' || v_sub_result);

        -- ── finish ────────────────────────────────────────
        ELSIF v_action_type = 'finish' THEN
            v_final_answer := v_action->>'final_answer';

            PERFORM alma_public.fn_log_step(
                v_session_id, v_step, 'finish',
                v_messages, v_llm_result,
                v_final_answer, v_duration_ms
            );

            UPDATE alma_private.sessions
            SET status = 'completed', final_answer = v_final_answer, ended_at = NOW()
            WHERE session_id = v_session_id;

            UPDATE alma_private.tasks
            SET status = 'completed', result = v_final_answer, completed_at = NOW()
            WHERE task_id = v_task_id;

            PERFORM pg_notify(
                'alma_session_complete',
                json_build_object('session_id', v_session_id,
                                  'agent', p_orchestrator_role)::TEXT
            );

            RETURN v_final_answer;

        ELSE
            v_messages := v_messages
                || jsonb_build_object('role', 'assistant', 'content', v_content)
                || jsonb_build_object('role', 'user',
                    'content', 'Invalid action. Respond with: delegate or finish.');
        END IF;
    END LOOP;

    UPDATE alma_private.sessions
    SET status = 'failed', ended_at = NOW()
    WHERE session_id = v_session_id;

    UPDATE alma_private.tasks
    SET status = 'failed', completed_at = NOW()
    WHERE task_id = v_task_id;

    RETURN 'FAILED: orchestrator max steps exceeded';
END;
$$;

COMMENT ON FUNCTION alma_public.run_agent(TEXT, TEXT) IS
    'Single-agent execution loop. Pass agent role name and task prompt.';
COMMENT ON FUNCTION alma_public.run_multi_agent(TEXT, TEXT) IS
    'Multi-agent execution. Orchestrator delegates to sub-agents via tasks table.';
