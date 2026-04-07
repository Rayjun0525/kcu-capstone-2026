# ALMA — Agent Lifecycle Manager

PostgreSQL-native AI agent lifecycle management framework.

> Everything lives in the database. `run_agent()` is the only call you need.

---

## Quick Start

### Docker (recommended)

```bash
# Start PostgreSQL with pgvector + plpython3u
docker-compose up -d

# Wait for healthy, then connect
psql -h localhost -U postgres -d alma

# Create an agent (Ollama example)
SELECT alma_public.create_agent(
    p_role_name     := 'agent_sql',
    p_name          := 'SQL Analyst',
    p_provider      := 'ollama',
    p_endpoint      := 'http://host.docker.internal:11434/api/chat',
    p_model_name    := 'llama3.2',
    p_system_prompt := 'You are a PostgreSQL expert. Answer questions using SQL queries.'
);

# Run it from psql
SELECT alma_public.run_agent('agent_sql', 'show me all tables in this database');
```

### Python client

```bash
pip install -r requirements.txt

export DB_HOST=localhost
export DB_USER=agent_sql
export DB_PASSWORD=   # set if password required

python3 alma_agent.py run --agent agent_sql --task "show me all tables"
python3 alma_agent.py agents
python3 alma_agent.py sessions --agent agent_sql
```

---

## Installation (manual / production)

```bash
# Build the merged SQL file
make build

# Install extension files
sudo make install

# Apply to database
psql -c "CREATE EXTENSION vector;"
psql -c "CREATE EXTENSION plpython3u;"
psql -f sql/alma--1.0.sql
```

---

## Architecture

```
alma_private/          Tables (operator access only)
  llm_configs          LLM model config per agent
  agent_profiles       System prompt, max_steps, max_retries
  agent_meta           role_name = PostgreSQL role
  sessions             One task = one session
  tasks                Queue + inter-agent messages
  execution_logs       Every step recorded
  memory               pgvector RAG memory
  ...

alma_public/           Views + Functions (agent interface)
  create_agent()       Provision Role + all metadata
  run_agent()          Single-agent loop
  run_multi_agent()    Orchestrator + sub-agents
  v_agent_context      Current agent's full profile
  v_my_tasks           Pending tasks for current agent
  v_my_memory          Agent memory entries
  ...
```

---

## Role Hierarchy

```
alma_operator               Human operator (full alma_private access)
└── alma_agent_base         Agent base (alma_public only)
    ├── agent_sql           SQL analyst agent
    ├── agent_orchestrator  Orchestrator agent
    └── agent_evaluator     Evaluator agent
```

---

## Creating Agents

```sql
-- Anthropic Claude
SELECT alma_public.create_agent(
    p_role_name     := 'agent_claude',
    p_name          := 'Claude Analyst',
    p_provider      := 'anthropic',
    p_endpoint      := 'https://api.anthropic.com/v1/messages',
    p_model_name    := 'claude-sonnet-4-6',
    p_api_key_ref   := 'ANTHROPIC_API_KEY',
    p_temperature   := 0.0,
    p_max_tokens    := 4096,
    p_system_prompt := 'You are a PostgreSQL expert...',
    p_max_steps     := 15
);

-- OpenAI
SELECT alma_public.create_agent(
    p_role_name   := 'agent_gpt',
    p_name        := 'GPT Analyst',
    p_provider    := 'openai',
    p_endpoint    := 'https://api.openai.com/v1/chat/completions',
    p_model_name  := 'gpt-4o',
    p_api_key_ref := 'OPENAI_API_KEY'
);

-- Ollama (local, no API key)
SELECT alma_public.create_agent(
    p_role_name    := 'agent_local',
    p_name         := 'Local Agent',
    p_provider     := 'ollama',
    p_endpoint     := 'http://localhost:11434/api/chat',
    p_model_name   := 'llama3.2',
    p_request_opts := '{"format": "json"}'
);
```

---

## Multi-Agent Example

```sql
-- Create orchestrator
SELECT alma_public.create_agent(
    p_role_name  := 'agent_orchestrator',
    p_name       := 'Orchestrator',
    p_agent_role := 'orchestrator',
    p_system_prompt := 'You coordinate sub-agents. Respond in JSON: {"thought":"...","action":"delegate|finish","agent_role":"...","task":"...","final_answer":"..."}'
);

-- Create sub-agents
SELECT alma_public.create_agent(p_role_name := 'agent_sql',  p_name := 'SQL Agent',  p_agent_role := 'executor');
SELECT alma_public.create_agent(p_role_name := 'agent_eval', p_name := 'Evaluator',  p_agent_role := 'evaluator');

-- Run
SELECT alma_public.run_multi_agent('agent_orchestrator', 'Analyse Q1 2024 sales and identify top 3 products');
```

---

## Swapping LLM Models (no code changes)

```sql
UPDATE alma_private.llm_configs
SET provider   = 'anthropic',
    endpoint   = 'https://api.anthropic.com/v1/messages',
    model_name = 'claude-opus-4-6',
    api_key_ref = 'ANTHROPIC_API_KEY'
WHERE llm_config_id = (
    SELECT llm_config_id FROM alma_private.agent_meta WHERE role_name = 'agent_sql'
);
```

---

## Security Notes

- API keys are **never stored in the database**. Only the environment variable name (`api_key_ref`) is stored.
- Agents have **no access** to `alma_private` tables directly.
- `fn_execute_sql` allows **SELECT only**. INSERT/UPDATE/DELETE/DROP are blocked.
- Each agent role can only see its own sessions and memory via views.

---

## Requirements

- PostgreSQL 16+
- Extensions: `vector` (pgvector), `plpython3u`
- Python 3.11+ with `psycopg2-binary` (client only)
- Docker: `pgvector/pgvector:pg16` image (includes both extensions)
