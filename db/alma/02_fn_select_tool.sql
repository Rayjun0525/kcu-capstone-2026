-- ALMA: fn_select_tool
-- Classifies a SQL string and determines whether it is irreversible.
-- Called inside the transaction boundary before execution (Group B).

CREATE OR REPLACE FUNCTION alma.fn_select_tool(p_sql TEXT)
RETURNS TABLE (sql_type TEXT, is_irreversible BOOLEAN)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    normalized TEXT;
    first_word TEXT;
BEGIN
    -- Normalize: collapse whitespace, strip leading comments, uppercase
    normalized := upper(trim(
        regexp_replace(
            regexp_replace(p_sql, '--[^\n]*', '', 'g'),  -- strip line comments
            '/\*.*?\*/', '', 'g'                          -- strip block comments
        )
    ));
    normalized := regexp_replace(normalized, '\s+', ' ', 'g');

    -- Extract the first keyword
    first_word := split_part(normalized, ' ', 1);

    -- ── DDL (always irreversible) ──────────────────────────────────────
    IF first_word IN ('DROP', 'TRUNCATE') THEN
        RETURN QUERY SELECT first_word, TRUE;
        RETURN;
    END IF;

    IF first_word IN ('CREATE', 'ALTER') THEN
        RETURN QUERY SELECT 'DDL'::TEXT, TRUE;
        RETURN;
    END IF;

    -- ── DML ───────────────────────────────────────────────────────────
    IF first_word = 'DELETE' THEN
        RETURN QUERY SELECT 'DELETE'::TEXT, TRUE;
        RETURN;
    END IF;

    IF first_word = 'UPDATE' THEN
        RETURN QUERY SELECT 'UPDATE'::TEXT, TRUE;
        RETURN;
    END IF;

    IF first_word = 'INSERT' THEN
        RETURN QUERY SELECT 'INSERT'::TEXT, FALSE;
        RETURN;
    END IF;

    -- ── Read-only ─────────────────────────────────────────────────────
    IF first_word = 'SELECT' THEN
        -- UNION / subquery injection detection:
        -- If the normalized SQL contains '; DROP', '; DELETE', '; UPDATE', '; TRUNCATE
        -- after a SELECT, treat as UNKNOWN / irreversible
        IF normalized ~ ';\s*(DROP|DELETE|UPDATE|TRUNCATE|ALTER|CREATE)' THEN
            RETURN QUERY SELECT 'UNKNOWN'::TEXT, TRUE;
            RETURN;
        END IF;
        RETURN QUERY SELECT 'SELECT'::TEXT, FALSE;
        RETURN;
    END IF;

    IF first_word IN ('WITH', 'EXPLAIN', 'SHOW', 'SET') THEN
        RETURN QUERY SELECT first_word, FALSE;
        RETURN;
    END IF;

    -- Anything else → treat as irreversible (safe default)
    RETURN QUERY SELECT 'UNKNOWN'::TEXT, TRUE;
END;
$$;

COMMENT ON FUNCTION alma.fn_select_tool(TEXT) IS
    'Returns (sql_type, is_irreversible) for the given SQL text. '
    'Conservative: unknown statements are flagged irreversible. '
    'Also detects semicolon-separated injection patterns inside SELECT.';
