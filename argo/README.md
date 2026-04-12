# ARGO — Agent Runtime Governance Operations

**ARGO** is a PostgreSQL extension that implements the **DB as a Control Plane (DBaaCP)** pattern for AI agent runtime governance. It turns your existing PostgreSQL instance into a full control plane for AI agents: policy management, task orchestration, fault-tolerant execution, access control, and audit logging — all inside the database, with zero additional infrastructure.

```sql
CREATE EXTENSION argo;
```

---

## Table of Contents

1. [Why ARGO](#1-why-argo)
2. [Architecture Overview](#2-architecture-overview)
3. [Requirements](#3-requirements)
4. [Installation](#4-installation)
5. [Core Concepts](#5-core-concepts)
6. [Quick Start](#6-quick-start)
7. [Creating Agents](#7-creating-agents)
8. [The Worker Loop](#8-the-worker-loop)
9. [Running the Worker](#9-running-the-worker)
10. [Multi-Agent Orchestration](#10-multi-agent-orchestration)
11. [Runtime Policy Control](#11-runtime-policy-control)
12. [SQL Sandbox & Access Control](#12-sql-sandbox--access-control)
13. [Fault Recovery](#13-fault-recovery)
14. [Log Compression](#14-log-compression)
15. [Monitoring & Audit](#15-monitoring--audit)
16. [Dashboard](#16-dashboard)
17. [Schema Reference](#17-schema-reference)
18. [Function Reference](#18-function-reference)
19. [Roles Reference](#19-roles-reference)
20. [Configuration Reference](#20-configuration-reference)
21. [Troubleshooting](#21-troubleshooting)

---

## 1. Why ARGO

Existing agent frameworks (LangGraph, CrewAI, AutoGen) solve orchestration: how to connect agents, sequence execution, and pass state. They do not solve governance: how to control a running agent without restarting it.

When an agent misbehaves in production, current frameworks leave you two choices:

1. Modify source code → redeploy → lose all in-progress session state
2. Wait and hope

ARGO makes a third option possible: **change agent behavior with a single SQL statement while the agent is running**, with sub-5ms propagation and zero session disruption.

| Feature | LangGraph / CrewAI | ARGO |
|---------|-------------------|------|
| Runtime policy change | Requires redeploy | SQL UPDATE, instant |
| Agent state on crash | Lost (in-memory) | Preserved (ACID) |
| Agent isolation | None | PostgreSQL RBAC |
| SQL access control | Application code | DB-level enforcement |
| Audit trail | Manual | Automatic |

---

## 2. Architecture Overview

```
+-------------------------------------------------------------+
|                     Worker Process                           |
|  argo_agent.py                                               |
|    1. fn_next_step(task_id)  -->  DB returns directive       |
|    2. LLM HTTP call          -->  only responsibility        |
|    3. fn_submit_result(...)  -->  DB updates state           |
+---------------------------+---------------------------------+
                            | psycopg2 / any PostgreSQL driver
+---------------------------v---------------------------------+
|              PostgreSQL + ARGO Extension                     |
|                                                              |
|  argo_public  (accessible to agent roles)                   |
|    +-- create_agent()          register agent + role        |
|    +-- run_agent()             enqueue task -> task_id      |
|    +-- fn_next_step()          return next directive         |
|    +-- fn_submit_result()      receive result, update state |
|    +-- v_my_tasks              agent's own tasks only       |
|    +-- v_ready_tasks           tasks with deps satisfied    |
|    +-- v_session_progress      session summary view         |
|                                                              |
|  argo_private  (operator only, never exposed to agents)     |
|    +-- agent_meta              agent registry               |
|    +-- agent_profiles          system prompts               |
|    +-- llm_configs             LLM endpoints and params     |
|    +-- sessions                top-level execution units    |
|    +-- tasks                   state machine + message queue|
|    +-- execution_logs          append-only step audit log   |
|    +-- sql_sandbox_allowlist   permitted views for SQL calls|
|    +-- memory                  vector long-term memory      |
+-------------------------------------------------------------+
```

**Key principle**: The database is the control plane. The LLM is an execution engine. The worker has no decision authority — it calls `fn_next_step()`, runs the LLM, and calls `fn_submit_result()`. All control logic lives in the DB.

---

## 3. Requirements

| Component | Minimum Version | Notes |
|-----------|-----------------|-------|
| PostgreSQL | 14+ | 16 recommended |
| pgvector | 0.5.0+ | Required for memory feature |
| Python | 3.10+ | For sample worker |
| psycopg2 | 2.9+ | PostgreSQL Python driver |
| LLM endpoint | Any OpenAI-compatible | Ollama, OpenAI, Anthropic, etc. |

**Python packages** (see `sample/requirements.txt`):

```
psycopg2-binary>=2.9
pgvector>=0.2
streamlit>=1.30        # only for dashboard
```

---

## 4. Installation

### Step 1: Install pgvector

```bash
# Ubuntu / Debian
sudo apt install postgresql-16-pgvector

# macOS (Homebrew)
brew install pgvector

# From source
git clone https://github.com/pgvector/pgvector.git
cd pgvector && make && sudo make install
```

### Step 2: Install ARGO extension files

Copy the extension files to your PostgreSQL extension directory:

```bash
# Find your extension directory
pg_config --sharedir

# Copy files
cp argo.control $(pg_config --sharedir)/extension/
cp sql/argo--1.0.sql $(pg_config --sharedir)/extension/
```

Or using make:

```bash
make install
```

### Step 3: Create the extension

Connect to your target database as a superuser:

```sql
-- Enable pgvector first
CREATE EXTENSION IF NOT EXISTS vector;

-- Install ARGO
CREATE EXTENSION argo;
```

This single command creates all schemas, roles, tables, views, and functions.

### Step 4: Verify installation

```sql
-- Check schemas
SELECT schema_name FROM information_schema.schemata
WHERE schema_name IN ('argo_public', 'argo_private');

-- Check roles
SELECT rolname FROM pg_roles
WHERE rolname IN ('argo_agent_base', 'argo_operator', 'argo_sql_sandbox');

-- Check key tables
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'argo_private'
ORDER BY table_name;
```

### Step 5: Grant operator access

```sql
GRANT argo_operator TO your_admin_role;
```

---

## 5. Core Concepts

### Control Plane vs. Data Plane

ARGO separates two responsibilities:

- **Control Plane (PostgreSQL)**: Owns policy, state, and all decisions. Never touches the LLM.
- **Data Plane (Worker)**: Makes LLM HTTP calls. Has no decision authority. Stateless.

This separation means you can change what an agent does (control plane) without restarting what runs it (worker).

### Agents, Sessions, and Tasks

- **Agent**: A PostgreSQL role with a system prompt and LLM configuration. Created once with `create_agent()`.
- **Session**: One goal, one conversation context. Multiple tasks can belong to a session (e.g., in multi-agent workflows).
- **Task**: The atomic execution unit. Goes through states: `pending -> running -> completed` (or `failed`/`cancelled`). Each task produces execution log entries.

### The Step Loop

Each task executes through a loop:

```
fn_next_step(task_id)
    -> returns {action: "call_llm", messages: [...], llm_config: {...}}

Worker calls LLM with messages

fn_submit_result(task_id, llm_response_json)
    -> parses action from response
    -> if "execute_sql": runs SQL against allowlist
    -> if "finish": marks task completed
    -> if "call_llm": continues loop
    -> returns {action: "continue"} or {action: "done", output: "..."}
```

### Policy Propagation

`fn_next_step()` reads `agent_profiles.system_prompt` on every call with no caching. This means:

```sql
-- Change takes effect on the NEXT fn_next_step() call
-- No restart required. Measured propagation delay: ~5ms
UPDATE argo_private.agent_profiles
SET system_prompt = 'New instructions here.'
WHERE name = 'My Agent';
```

---

## 6. Quick Start

### 1. Set up environment

```bash
export DB_NAME=mydb
export DB_USER=postgres
export DB_PASSWORD=secret
export DB_HOST=localhost
export DB_PORT=5432
```

### 2. Create an agent (as operator)

```sql
SELECT argo_public.create_agent(
    'my_first_agent',
    '{
        "name":          "My First Agent",
        "agent_role":    "executor",
        "provider":      "ollama",
        "endpoint":      "http://localhost:11434/api/chat",
        "model_name":    "llama3",
        "temperature":   0.7,
        "max_tokens":    1024,
        "system_prompt": "You are a helpful assistant. Always respond in JSON only: {\"thought\": \"...\", \"action\": \"finish\", \"final_answer\": \"...\"}",
        "max_steps":     10,
        "max_retries":   2,
        "password":      "agent_secret_pw"
    }'::jsonb
);
```

### 3. Enqueue a task (as operator)

```sql
SELECT argo_public.run_agent('my_first_agent', 'What is the capital of France?');
```

### 4. Run the worker

```bash
export DB_PASSWORD=agent_secret_pw
python3 sample/argo_agent.py --worker my_first_agent
```

### 5. Check the result

```sql
SELECT s.session_id, s.goal, s.status, s.final_answer
FROM argo_private.sessions s
JOIN argo_private.agent_meta am ON am.agent_id = s.agent_id
WHERE am.role_name = 'my_first_agent'
ORDER BY s.started_at DESC LIMIT 5;
```

---

## 7. Creating Agents

### create_agent() parameters

```sql
SELECT argo_public.create_agent(role_name TEXT, config JSONB);
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Display name |
| `agent_role` | string | yes | `"executor"` or `"orchestrator"` |
| `provider` | string | yes | `"ollama"`, `"openai"`, `"anthropic"` |
| `endpoint` | string | yes | LLM API URL |
| `model_name` | string | yes | Model identifier |
| `temperature` | float | no | Sampling temperature (default: 0.7) |
| `max_tokens` | int | no | Max tokens per response (default: 1024) |
| `request_options` | object | no | Extra LLM options (e.g., `{"format": "json"}`) |
| `system_prompt` | string | yes | Agent behavioral instructions |
| `max_steps` | int | no | Maximum steps per task (default: 20) |
| `max_retries` | int | no | LLM retry attempts (default: 2) |
| `password` | string | yes | PostgreSQL login password |

### System prompt design

The system prompt must instruct the LLM to respond in a known JSON action schema:

```
You are a data analysis agent. Always respond with valid JSON only.

Available actions:

Query data:
{"thought": "...", "action": "execute_sql", "sql": "SELECT ..."}

Complete the task:
{"thought": "...", "action": "finish", "final_answer": "..."}
```

### Updating agent configuration

```sql
-- Change system prompt (takes effect immediately)
UPDATE argo_private.agent_profiles
SET system_prompt = 'Updated instructions.'
WHERE name = 'My First Agent';

-- Deactivate agent (blocks new tasks, preserves history)
UPDATE argo_private.agent_meta
SET is_active = FALSE
WHERE role_name = 'my_first_agent';
```

---

## 8. The Worker Loop

The worker has exactly one job: bridge between the DB control plane and the LLM.

```python
# Conceptual worker loop
while True:
    directive = fn_next_step(task_id)         # 1. Get directive from DB
    if directive["action"] == "call_llm":
        response = call_llm(directive)         # 2. Call LLM (only independent step)
        result = fn_submit_result(task_id, response)  # 3. Return to DB
        if result["action"] == "done":
            break
```

Key behaviors of the sample worker (`sample/argo_agent.py`):

- **LISTEN/NOTIFY**: Subscribes to `pg_notify` channel `argo_tasks` for instant wake-up on new tasks, falling back to polling every `ARGO_WORKER_POLL_SEC` seconds.
- **Crash safety**: If the worker dies mid-step, the task stays `running` in the DB. On restart, the worker finds it and resumes from the last committed step.
- **Retry logic**: Retries up to `max_retries` times on empty or invalid LLM responses.

---

## 9. Running the Worker

### Basic usage

```bash
# Enqueue a task and run as one-shot worker
python3 sample/argo_agent.py my_first_agent "Analyze Q4 sales"

# Run as persistent daemon (picks up tasks continuously)
python3 sample/argo_agent.py --worker my_first_agent

# Run log compressor
python3 sample/argo_agent.py --compressor argo_compressor
```

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_NAME` | `postgres` | Database name |
| `DB_USER` | (role arg) | Database user |
| `DB_PASSWORD` | (empty) | Database password |
| `DB_HOST` | `localhost` | PostgreSQL host |
| `DB_PORT` | `5432` | PostgreSQL port |
| `ARGO_WORKER_POLL_SEC` | `1.0` | Polling interval (seconds) |

### Running multiple workers in parallel

Workers are stateless — run as many as needed. Each worker acquires tasks with `SELECT ... FOR UPDATE SKIP LOCKED`, so tasks are never processed twice.

```bash
for i in 1 2 3 4; do
    python3 sample/argo_agent.py --worker my_first_agent &
done
```

### Running as systemd service

```ini
[Unit]
Description=ARGO Worker
After=postgresql.service

[Service]
Type=simple
User=appuser
ExecStart=/usr/bin/python3 /opt/argo/sample/argo_agent.py --worker my_first_agent
Environment=DB_NAME=mydb
Environment=DB_PASSWORD=agent_secret_pw
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

---

## 10. Multi-Agent Orchestration

### Setting up orchestrator + executor

```sql
-- Executor
SELECT argo_public.create_agent('data_analyst', '{
    "name": "Data Analyst",
    "agent_role": "executor",
    "provider": "ollama",
    "endpoint": "http://localhost:11434/api/chat",
    "model_name": "llama3",
    "system_prompt": "You analyze data. Respond only in JSON.\n{\"thought\":\"...\",\"action\":\"execute_sql\",\"sql\":\"...\"}\n{\"thought\":\"...\",\"action\":\"finish\",\"final_answer\":\"...\"}",
    "password": "analyst_pw"
}'::jsonb);

-- Orchestrator
SELECT argo_public.create_agent('report_orchestrator', '{
    "name": "Report Orchestrator",
    "agent_role": "orchestrator",
    "provider": "ollama",
    "endpoint": "http://localhost:11434/api/chat",
    "model_name": "llama3",
    "system_prompt": "You coordinate report generation. Respond only in JSON.\n{\"thought\":\"...\",\"action\":\"delegate\",\"agent\":\"data_analyst\",\"task\":\"...\"}\n{\"thought\":\"...\",\"action\":\"finish\",\"final_answer\":\"...\"}",
    "password": "orchestrator_pw"
}'::jsonb);
```

### Running multi-agent workflows

```bash
python3 sample/argo_agent.py --worker data_analyst &
python3 sample/argo_agent.py --worker report_orchestrator &
python3 sample/argo_agent.py report_orchestrator "Generate Q4 operations report"
```

### How delegation works

When the orchestrator responds with:
```json
{"thought": "Need data first", "action": "delegate", "agent": "data_analyst", "task": "Calculate session completion rate"}
```

`fn_submit_result()` atomically:
1. Inserts a new task for `data_analyst` (same session_id)
2. Sends `pg_notify('argo_tasks', ...)` to wake the analyst worker
3. Suspends the orchestrator task pending the delegation result

When the analyst completes, the orchestrator resumes with the analyst's output.

### Task dependencies (DAG)

```sql
-- Create explicit dependency
INSERT INTO argo_private.task_dependencies (task_id, depends_on_task_id)
VALUES (child_task_id, parent_task_id);

-- v_ready_tasks filters for tasks where all dependencies are complete
SELECT * FROM argo_public.v_ready_tasks;
```

---

## 11. Runtime Policy Control

All changes take effect on the next `fn_next_step()` call — no restart required.

### Change agent behavior

```sql
UPDATE argo_private.agent_profiles
SET system_prompt = 'Answer only company policy questions. Refuse all other requests.'
WHERE name = 'Customer Support Agent';
```

### Revoke data access

```sql
-- Block a view immediately
DELETE FROM argo_private.sql_sandbox_allowlist
WHERE view_name = 'argo_public.v_sensitive_data';
```

### Deactivate an agent

```sql
UPDATE argo_private.agent_meta
SET is_active = FALSE
WHERE role_name = 'rogue_agent';
```

### Cancel running tasks

```sql
UPDATE argo_private.tasks t
SET status = 'cancelled'
FROM argo_private.agent_meta am
WHERE t.agent_id = am.agent_id
AND am.role_name = 'my_first_agent'
AND t.status IN ('pending', 'running');
```

### Record an operator intervention

```sql
INSERT INTO argo_private.human_interventions
    (session_id, operator_role, action_taken, reason)
VALUES (42, session_user, 'cancelled task', 'Policy violation detected');
```

---

## 12. SQL Sandbox & Access Control

ARGO provides two-layer SQL isolation for the `execute_sql` action.

### Layer 1: Allowlist enforcement

`fn_execute_sql()` checks whether the target view is registered in `sql_sandbox_allowlist`. If not, the SQL is rejected and the error is logged:

```
SQL ERROR: fn_execute_sql: "argo_private.sessions" not in sql_sandbox_allowlist
```

### Layer 2: PostgreSQL RBAC

Agent roles have no privileges on `argo_private` schema or base tables. Even if a query passes the allowlist check, PostgreSQL enforces role-based access. Internal tables are never reachable regardless of the SQL expression used (uppercase, comments, subqueries, aliases, etc.).

### Managing the allowlist

```sql
-- View current allowlist
SELECT view_name FROM argo_private.sql_sandbox_allowlist ORDER BY view_name;

-- Add a view
INSERT INTO argo_private.sql_sandbox_allowlist (view_name)
VALUES ('argo_public.v_my_custom_view');

-- Remove a view
DELETE FROM argo_private.sql_sandbox_allowlist
WHERE view_name = 'argo_public.v_my_custom_view';
```

### Creating safe views for agents

```sql
-- Create a narrow view exposing only safe columns
CREATE VIEW argo_public.v_session_summary AS
SELECT
    s.session_id,
    am.role_name                                            AS agent,
    s.status,
    COUNT(t.task_id)                                        AS total_tasks,
    COUNT(t.task_id) FILTER (WHERE t.status = 'completed') AS done_tasks
FROM argo_private.sessions s
JOIN argo_private.agent_meta am ON am.agent_id = s.agent_id
JOIN argo_private.tasks t ON t.session_id = s.session_id
GROUP BY s.session_id, am.role_name, s.status, s.started_at, s.completed_at;

-- Grant access and register
GRANT SELECT ON argo_public.v_session_summary TO argo_agent_base;
INSERT INTO argo_private.sql_sandbox_allowlist (view_name) VALUES ('argo_public.v_session_summary');
```

---

## 13. Fault Recovery

All state lives in PostgreSQL — recovery is automatic.

### What happens on worker crash

1. Worker dies during `fn_submit_result()` execution
2. PostgreSQL rolls back the uncommitted transaction
3. Task remains in `running` status, no execution log entry created
4. On worker restart, it finds `running` tasks and resumes from the last committed step

### Manual recovery

```sql
-- Find stuck running tasks
SELECT t.task_id, am.role_name, t.updated_at, NOW() - t.updated_at AS stuck_for
FROM argo_private.tasks t
JOIN argo_private.agent_meta am ON am.agent_id = t.agent_id
WHERE t.status = 'running'
AND t.updated_at < NOW() - INTERVAL '5 minutes';

-- Reset a stuck task
UPDATE argo_private.tasks
SET status = 'pending', updated_at = NOW()
WHERE task_id = 123;
```

---

## 14. Log Compression

### Set up the compressor

```bash
python3 sample/argo_compressor_setup.py
```

### Run the compressor

```bash
python3 sample/argo_agent.py --compressor argo_compressor
```

### Compressor settings

```sql
UPDATE argo_private.system_agent_configs
SET settings = settings || '{"compress_after_steps": 15, "tool_result_max_chars": 500}'::jsonb
WHERE agent_type = 'compressor';
```

| Setting | Default | Description |
|---------|---------|-------------|
| `compress_after_steps` | 20 | Compress tasks exceeding this step count |
| `tool_result_max_chars` | 300 | Truncate tool results above this length |
| `quality_threshold` | 0.9 | Minimum acceptable compression quality |
| `batch_size` | 5 | Tasks compressed per run |

---

## 15. Monitoring & Audit

### Session progress

```sql
SELECT * FROM argo_public.v_session_progress ORDER BY started_at DESC;
```

### Full audit trail

```sql
SELECT
    t.task_id, am.role_name AS agent,
    el.step_number, el.role,
    LEFT(el.content, 120) AS preview,
    el.created_at
FROM argo_private.execution_logs el
JOIN argo_private.tasks t ON t.task_id = el.task_id
JOIN argo_private.agent_meta am ON am.agent_id = t.agent_id
WHERE t.session_id = 42
ORDER BY t.task_id, el.step_number;
```

### Find SQL access violations

```sql
SELECT t.task_id, am.role_name, el.content AS error, el.created_at
FROM argo_private.execution_logs el
JOIN argo_private.tasks t ON t.task_id = el.task_id
JOIN argo_private.agent_meta am ON am.agent_id = t.agent_id
WHERE el.role = 'tool' AND el.content LIKE 'SQL ERROR%'
ORDER BY el.created_at DESC;
```

---

## 16. Dashboard

```bash
pip install streamlit psycopg2-binary pgvector
streamlit run sample/argo_dashboard.py
```

Provides: DB connection, agent management, task enqueueing, session monitoring, table explorer, and experiment comparison.

---

## 17. Schema Reference

### argo_private.agent_meta

| Column | Type | Description |
|--------|------|-------------|
| `agent_id` | serial PK | Internal identifier |
| `role_name` | text unique | PostgreSQL role name |
| `display_name` | text | Human-readable name |
| `agent_type` | text | `executor` or `orchestrator` |
| `is_active` | boolean | Accepts new tasks |
| `created_at` | timestamptz | Creation time |

### argo_private.agent_profiles

| Column | Type | Description |
|--------|------|-------------|
| `profile_id` | serial PK | Profile identifier |
| `name` | text | Profile name |
| `system_prompt` | text | LLM system instructions |
| `max_steps` | int | Step limit per task |
| `max_retries` | int | LLM retry attempts |
| `updated_at` | timestamptz | Last modification |

### argo_private.llm_configs

| Column | Type | Description |
|--------|------|-------------|
| `config_id` | serial PK | Config identifier |
| `provider` | text | LLM provider |
| `endpoint` | text | API URL |
| `model_name` | text | Model identifier |
| `temperature` | float | Sampling temperature |
| `max_tokens` | int | Token limit |
| `request_options` | jsonb | Additional API options |

### argo_private.sessions

| Column | Type | Description |
|--------|------|-------------|
| `session_id` | serial PK | Session identifier |
| `agent_id` | int FK | Owning agent |
| `goal` | text | Top-level objective |
| `status` | text | `active` / `completed` / `failed` |
| `final_answer` | text | Completed session output |
| `started_at` | timestamptz | Session start |
| `completed_at` | timestamptz | Session completion |

### argo_private.tasks

| Column | Type | Description |
|--------|------|-------------|
| `task_id` | serial PK | Task identifier |
| `session_id` | int FK | Parent session |
| `agent_id` | int FK | Assigned agent |
| `status` | text | `pending` / `running` / `completed` / `failed` / `cancelled` |
| `input` | text | Task goal |
| `output` | text | Task result |
| `created_at` | timestamptz | Task creation |
| `updated_at` | timestamptz | Last state change |

### argo_private.execution_logs

| Column | Type | Description |
|--------|------|-------------|
| `log_id` | serial PK | Log entry identifier |
| `task_id` | int FK | Parent task |
| `step_number` | int | Execution step (1-based) |
| `role` | text | `system` / `user` / `assistant` / `tool` |
| `content` | text | Message content |
| `compressed_content` | text | Compressor summary |
| `compression_quality` | float | Quality score 0-1 |
| `compressed_at` | timestamptz | Compression time |
| `created_at` | timestamptz | Log creation |

### argo_private.sql_sandbox_allowlist

| Column | Type | Description |
|--------|------|-------------|
| `allowlist_id` | serial PK | Entry identifier |
| `view_name` | text unique | Fully-qualified view name |

---

## 18. Function Reference

### argo_public.create_agent(role_name, config)

Creates agent role, metadata, profile, and LLM config in a single transaction.

```sql
SELECT argo_public.create_agent('my_agent', '{ ... }'::jsonb);
-- Returns: 'Agent created: my_agent'
```

### argo_public.run_agent(role_name, goal)

Enqueues a task. Returns task_id.

```sql
SELECT argo_public.run_agent('my_agent', 'Summarize last week activity');
```

### argo_public.fn_next_step(task_id)

Returns the next directive. Called by the worker before each LLM call.

```sql
SELECT argo_public.fn_next_step(123);
-- Returns JSONB: {action, messages, llm_config}
```

**Return schema:**
```json
{
  "action": "call_llm",
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user",   "content": "..."}
  ],
  "llm_config": {
    "provider":    "ollama",
    "endpoint":    "http://localhost:11434/api/chat",
    "model_name":  "llama3",
    "temperature": 0.7,
    "max_tokens":  1024
  }
}
```

### argo_public.fn_submit_result(task_id, response, is_last_step)

Submits LLM response. Handles all state transitions atomically.

```sql
SELECT argo_public.fn_submit_result(
    123,
    '{"thought": "Done", "action": "finish", "final_answer": "Paris"}'
);
-- Returns: {action: "done", output: "Paris"} or {action: "continue"}
```

**Supported response actions:**

| Action | Effect |
|--------|--------|
| `call_llm` | Logs assistant message, returns `continue` |
| `execute_sql` | Runs SQL against allowlist, logs result, returns `continue` |
| `finish` | Marks task completed, returns `done` |
| `delegate` | Creates sub-task, notifies worker, returns `continue` |

### argo_private.fn_execute_sql(sql)

Internal. Checks allowlist and executes SQL under the caller's privileges.

```sql
-- Test directly as operator
SELECT argo_private.fn_execute_sql('SELECT task_id FROM argo_public.v_my_tasks');
```

---

## 19. Roles Reference

| Role | Description | Inherits |
|------|-------------|----------|
| `argo_agent_base` | Base for all agent roles. Grants access to `argo_public`. | — |
| `argo_operator` | Full access to `argo_private`. Use for administration. | — |
| `argo_sql_sandbox` | Minimal role with SELECT on allowlisted views. Used internally. | — |
| `<agent_role>` | Per-agent login role. | `argo_agent_base` |

**Agent roles CAN:**
- Call `fn_next_step()` and `fn_submit_result()`
- Read own tasks via `v_my_tasks`
- Read ready tasks via `v_ready_tasks`
- Read session progress via `v_session_progress`

**Agent roles CANNOT:**
- Access `argo_private` schema
- Read other agents' data
- Modify `sql_sandbox_allowlist` or `agent_profiles`

---

## 20. Configuration Reference

### LLM provider examples

**Ollama (local)**
```json
{
  "provider": "ollama",
  "endpoint": "http://localhost:11434/api/chat",
  "model_name": "llama3",
  "request_options": {"format": "json"}
}
```

**OpenAI**
```json
{
  "provider": "openai",
  "endpoint": "https://api.openai.com/v1/chat/completions",
  "model_name": "gpt-4o",
  "request_options": {"response_format": {"type": "json_object"}}
}
```

**Anthropic**
```json
{
  "provider": "anthropic",
  "endpoint": "https://api.anthropic.com/v1/messages",
  "model_name": "claude-sonnet-4-20250514",
  "max_tokens": 4096
}
```

---

## 21. Troubleshooting

### Extension installation fails

```
ERROR: could not open extension control file ".../argo.control"
```

Copy files to the correct directory:
```bash
cp argo.control $(pg_config --sharedir)/extension/
cp sql/argo--1.0.sql $(pg_config --sharedir)/extension/
```

### pgvector not found

```sql
CREATE EXTENSION vector;  -- install pgvector first
CREATE EXTENSION argo;
```

### Task stuck in 'running'

Worker crashed mid-step. Reset the task:
```sql
UPDATE argo_private.tasks SET status = 'pending' WHERE task_id = 123;
```

Or restart the worker — it automatically resumes `running` tasks.

### LLM returns invalid JSON

Add explicit JSON-only instruction to the system prompt:
```
Always respond with valid JSON only. Never include any text outside the JSON object.
```

For Ollama: add `"request_options": {"format": "json"}` to the LLM config.

### fn_execute_sql: not in sql_sandbox_allowlist

Register the view:
```sql
INSERT INTO argo_private.sql_sandbox_allowlist (view_name)
VALUES ('argo_public.your_view_name');
```

### Worker cannot connect

1. Check `DB_PASSWORD` environment variable is set
2. Verify the role exists: `SELECT COUNT(*) FROM pg_roles WHERE rolname = 'my_agent';`
3. Check `pg_hba.conf` allows the connection method

---

## License

MIT License.

## Citation

```bibtex
@misc{argo2026,
  title = {ARGO: DB as a Control Plane Pattern for AI Agent Runtime Governance},
  year  = {2026}
}
```
