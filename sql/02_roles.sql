-- =============================================================
-- 02_roles.sql — Role hierarchy
-- alma_operator   : human operator (full alma_private access)
-- alma_agent_base : agent base role (alma_public only)
-- =============================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'alma_operator') THEN
        CREATE ROLE alma_operator NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'alma_agent_base') THEN
        CREATE ROLE alma_agent_base NOLOGIN;
    END IF;
END;
$$;

COMMENT ON ROLE alma_operator   IS 'ALMA human operator — full access to alma_private';
COMMENT ON ROLE alma_agent_base IS 'ALMA agent base role — alma_public interface only';
