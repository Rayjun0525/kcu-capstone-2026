-- =============================================================
-- 01_schemas.sql — Schema definitions
-- alma_private : tables (operator-only direct access)
-- alma_public  : views + functions (agent interface)
-- =============================================================

CREATE SCHEMA IF NOT EXISTS alma_private;
CREATE SCHEMA IF NOT EXISTS alma_public;

COMMENT ON SCHEMA alma_private IS 'ALMA internal tables — operator access only';
COMMENT ON SCHEMA alma_public  IS 'ALMA public interface — views and functions for agents';
