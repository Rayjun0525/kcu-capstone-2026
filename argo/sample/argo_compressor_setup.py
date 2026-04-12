#!/usr/bin/env python3
"""
ARGO Log Compressor Setup Guide
================================
The compressor agent profile is registered during extension installation,
but the agent role itself must be created and enabled manually.

Follow the four steps below to activate log compression.

Run this file to print the setup SQL:
    python3 argo_compressor_setup.py
"""

STEP1_CREATE_AGENT = """
-- =============================================================
-- Step 1: Create the compressor agent
--         (replace model_name with your actual model)
-- =============================================================
SELECT argo_public.create_agent(
    'argo_compressor',
    '{
        "name":          "ARGO Log Compressor",
        "agent_role":    "evaluator",
        "provider":      "ollama",
        "endpoint":      "http://localhost:11434/api/chat",
        "model_name":    "gpt-oss:20b",
        "temperature":   0.1,
        "max_tokens":    4096,
        "request_options": {"format": "json"},
        "max_steps":     20,
        "max_retries":   3
    }'::jsonb
);
-- The system_prompt is automatically loaded from the built-in
-- "ARGO Log Compressor" profile registered at installation time.
-- To customise it:
--   UPDATE argo_private.agent_profiles
--   SET system_prompt = '...'
--   WHERE name = 'ARGO Log Compressor';
"""

STEP2_LINK_AND_ENABLE = """
-- =============================================================
-- Step 2: Link the agent role and enable the compressor
-- =============================================================
UPDATE argo_private.system_agent_configs
SET role_name  = 'argo_compressor',
    is_enabled = TRUE
WHERE agent_type = 'compressor';
"""

STEP3_CHECK = """
-- =============================================================
-- Step 3: Verify the configuration
-- =============================================================
SELECT * FROM argo_public.v_system_agents;
"""

CONTROL_EXAMPLES = """
-- =============================================================
-- Fine-tuning (all changes take effect immediately via SQL)
-- =============================================================

-- Raise quality threshold (stricter)
UPDATE argo_private.system_agent_configs
SET settings = settings || '{"quality_threshold": 0.95}'
WHERE agent_type = 'compressor';

-- Change run interval to every 6 hours
UPDATE argo_private.system_agent_configs
SET run_interval_secs = 21600
WHERE agent_type = 'compressor';

-- Lower compression trigger (compress when >= 10 steps)
UPDATE argo_private.system_agent_configs
SET settings = settings || '{"compress_after_steps": 10}'
WHERE agent_type = 'compressor';

-- Increase batch size
UPDATE argo_private.system_agent_configs
SET settings = settings || '{"batch_size": 10}'
WHERE agent_type = 'compressor';

-- Disable the compressor
UPDATE argo_private.system_agent_configs
SET is_enabled = FALSE
WHERE agent_type = 'compressor';

-- Check how many tasks are waiting for compression
SELECT * FROM argo_public.v_compressible_logs;

-- Manually purge originals for a specific task (operator only)
-- SELECT argo_public.fn_purge_compressed_logs(<task_id>, 0.9);
"""

STEP4_RUN_WORKER = """
# =============================================================
# Step 4: Start the compressor worker
# =============================================================

# If the role password was auto-generated, reset it first:
# psql -U postgres -c "ALTER ROLE argo_compressor PASSWORD 'your_password';"

export DB_USER=argo_compressor
export DB_PASSWORD=your_password

# Run as a foreground process
python3 sample/argo_agent.py --compressor argo_compressor

# Or schedule via cron (daily at 03:00)
# 0 3 * * * DB_USER=argo_compressor DB_PASSWORD=... \\
#   python3 /path/to/argo_agent.py --compressor argo_compressor \\
#   >> /var/log/argo_compressor.log 2>&1
"""

if __name__ == "__main__":
    print(__doc__)
    print("=" * 60)
    print("Execute the following SQL statements in order:\n")
    print(STEP1_CREATE_AGENT)
    print(STEP2_LINK_AND_ENABLE)
    print(STEP3_CHECK)
    print("\nFine-tuning examples:")
    print(CONTROL_EXAMPLES)
    print("\nStart the worker:")
    print(STEP4_RUN_WORKER)
