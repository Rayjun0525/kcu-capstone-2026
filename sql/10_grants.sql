-- =============================================================
-- 10_grants.sql — Role privilege grants
-- alma_operator : full alma_private access
-- alma_agent_base : alma_public interface only
-- =============================================================

-- ── alma_operator ─────────────────────────────────────────────
GRANT USAGE ON SCHEMA alma_private TO alma_operator;
GRANT USAGE ON SCHEMA alma_public  TO alma_operator;

GRANT ALL ON ALL TABLES    IN SCHEMA alma_private TO alma_operator;
GRANT ALL ON ALL SEQUENCES IN SCHEMA alma_private TO alma_operator;
GRANT ALL ON ALL TABLES    IN SCHEMA alma_public  TO alma_operator;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA alma_private TO alma_operator;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA alma_public  TO alma_operator;

-- ── alma_agent_base ───────────────────────────────────────────
-- NO access to alma_private (tables/sequences/functions)
REVOKE ALL ON SCHEMA alma_private FROM alma_agent_base;

GRANT USAGE  ON SCHEMA alma_public TO alma_agent_base;

-- Views (read-only)
GRANT SELECT ON alma_public.v_agent_context    TO alma_agent_base;
GRANT SELECT ON alma_public.v_my_tasks         TO alma_agent_base;
GRANT SELECT ON alma_public.v_my_memory        TO alma_agent_base;
GRANT SELECT ON alma_public.v_session_progress TO alma_agent_base;
GRANT SELECT ON alma_public.v_session_audit    TO alma_agent_base;

-- Core functions
GRANT EXECUTE ON FUNCTION alma_public.fn_create_session(TEXT)                   TO alma_agent_base;
GRANT EXECUTE ON FUNCTION alma_public.fn_complete_session(UUID, TEXT, TEXT)      TO alma_agent_base;
GRANT EXECUTE ON FUNCTION alma_public.fn_create_task(UUID, TEXT, TEXT)           TO alma_agent_base;
GRANT EXECUTE ON FUNCTION alma_public.fn_update_task(UUID, TEXT, TEXT)           TO alma_agent_base;
GRANT EXECUTE ON FUNCTION alma_public.fn_log_step(UUID, INT, TEXT, JSONB, JSONB, TEXT, INT) TO alma_agent_base;
GRANT EXECUTE ON FUNCTION alma_public.fn_save_memory(TEXT, TEXT, UUID, NUMERIC, vector)     TO alma_agent_base;
GRANT EXECUTE ON FUNCTION alma_public.fn_search_memory(vector, INT, TEXT)        TO alma_agent_base;
GRANT EXECUTE ON FUNCTION alma_public.fn_execute_sql(TEXT)                       TO alma_agent_base;
GRANT EXECUTE ON FUNCTION alma_public.fn_record_message(UUID, TEXT, TEXT, TEXT)  TO alma_agent_base;

-- Agent execution
GRANT EXECUTE ON FUNCTION alma_public.run_agent(TEXT, TEXT)            TO alma_agent_base;
GRANT EXECUTE ON FUNCTION alma_public.run_multi_agent(TEXT, TEXT)      TO alma_agent_base;

-- Read-only management
GRANT EXECUTE ON FUNCTION alma_public.list_agents(BOOLEAN)             TO alma_agent_base;
GRANT EXECUTE ON FUNCTION alma_public.list_sessions(TEXT, INT)         TO alma_agent_base;
GRANT EXECUTE ON FUNCTION alma_public.get_session(UUID)                TO alma_agent_base;

-- Management functions (operator-only)
GRANT EXECUTE ON FUNCTION alma_public.create_agent(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,NUMERIC,INT,JSONB,TEXT,INT,INT) TO alma_operator;
GRANT EXECUTE ON FUNCTION alma_public.drop_agent(TEXT, BOOLEAN)        TO alma_operator;
