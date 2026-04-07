-- =============================================================
-- 03_types.sql — ENUM type definitions
-- All enums live in alma_private to prevent direct agent access
-- Agent-facing functions accept TEXT and cast internally
-- =============================================================

CREATE TYPE alma_private.agent_role AS ENUM (
    'orchestrator',
    'executor',
    'evaluator'
);

CREATE TYPE alma_private.llm_provider AS ENUM (
    'anthropic',
    'openai',
    'ollama',
    'custom'
);

CREATE TYPE alma_private.session_status AS ENUM (
    'active',
    'completed',
    'failed',
    'cancelled'
);

CREATE TYPE alma_private.task_status AS ENUM (
    'pending',
    'running',
    'completed',
    'failed',
    'cancelled'
);

CREATE TYPE alma_private.memory_type AS ENUM (
    'episodic',     -- specific event memory
    'semantic',     -- general knowledge
    'procedural'    -- how-to / skill memory
);

CREATE TYPE alma_private.intervention_type AS ENUM (
    'approval',     -- human approved an action
    'rejection',    -- human rejected an action
    'correction',   -- human corrected agent output
    'escalation'    -- agent escalated to human
);
