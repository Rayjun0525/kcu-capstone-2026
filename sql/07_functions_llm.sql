-- =============================================================
-- 07_functions_llm.sql — LLM HTTP call (plpython3u)
-- fn_call_llm: reads llm_configs, dispatches HTTP, returns JSONB
-- API keys: read from environment variables only (api_key_ref)
-- =============================================================

CREATE OR REPLACE FUNCTION alma_private.fn_call_llm(
    p_agent_id  UUID,
    p_messages  JSONB
)
RETURNS JSONB
LANGUAGE plpython3u
AS $$
import json
import os
import urllib.request
import urllib.error
import time

# ── Load LLM config for this agent ──────────────────────────
plan = plpy.prepare(
    """
    SELECT lc.provider::TEXT, lc.endpoint, lc.model_name,
           lc.api_key_ref, lc.temperature, lc.max_tokens, lc.request_options
    FROM   alma_private.llm_configs lc
    JOIN   alma_private.agent_meta  am ON am.llm_config_id = lc.llm_config_id
    WHERE  am.agent_id = $1
    """,
    ["uuid"]
)
rows = plpy.execute(plan, [p_agent_id])
if not rows:
    plpy.error(f"No LLM config found for agent_id={p_agent_id}")

cfg = rows[0]
provider     = cfg["provider"]
endpoint     = cfg["endpoint"]
model_name   = cfg["model_name"]
api_key_ref  = cfg["api_key_ref"]
temperature  = float(cfg["temperature"]) if cfg["temperature"] else 0.0
max_tokens   = int(cfg["max_tokens"])    if cfg["max_tokens"]   else 2048
req_opts     = json.loads(cfg["request_options"]) if cfg["request_options"] else {}

# ── Resolve API key from environment ────────────────────────
api_key = None
if api_key_ref:
    api_key = os.environ.get(api_key_ref)
    if not api_key:
        plpy.warning(f"Environment variable '{api_key_ref}' is not set")

# ── Parse messages ───────────────────────────────────────────
messages = json.loads(p_messages) if isinstance(p_messages, str) else p_messages

# ── Build provider-specific request ─────────────────────────
headers = {"Content-Type": "application/json"}

if provider == "anthropic":
    # Extract system message if present
    system_prompt = None
    user_messages = []
    for msg in messages:
        if msg.get("role") == "system":
            system_prompt = msg["content"]
        else:
            user_messages.append(msg)

    payload = {
        "model":       model_name,
        "max_tokens":  max_tokens,
        "temperature": temperature,
        "messages":    user_messages,
    }
    if system_prompt:
        payload["system"] = system_prompt

    headers["x-api-key"]         = api_key or ""
    headers["anthropic-version"] = "2023-06-01"

elif provider == "openai":
    payload = {
        "model":       model_name,
        "max_tokens":  max_tokens,
        "temperature": temperature,
        "messages":    messages,
    }
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

elif provider in ("ollama", "custom"):
    payload = {
        "model":    model_name,
        "messages": messages,
        "stream":   False,
        "options":  {"temperature": temperature},
    }
    if req_opts.get("format"):
        payload["format"] = req_opts["format"]
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

else:
    plpy.error(f"Unknown LLM provider: {provider}")

# Merge extra request options (provider-level overrides)
for k, v in req_opts.items():
    if k not in ("format",):
        payload[k] = v

# ── HTTP call with retry ─────────────────────────────────────
body = json.dumps(payload).encode("utf-8")
req  = urllib.request.Request(endpoint, data=body, headers=headers, method="POST")

last_error = None
for attempt in range(3):
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            raw = json.loads(resp.read().decode("utf-8"))
        break
    except urllib.error.HTTPError as e:
        last_error = f"HTTP {e.code}: {e.read().decode()}"
        if e.code in (429, 500, 502, 503):
            time.sleep(2 ** attempt)
            continue
        plpy.error(f"LLM HTTP error: {last_error}")
    except Exception as e:
        last_error = str(e)
        time.sleep(2 ** attempt)
else:
    plpy.error(f"LLM call failed after 3 attempts: {last_error}")

# ── Normalise response to {content, raw} ────────────────────
content = None

if provider == "anthropic":
    content_blocks = raw.get("content", [])
    for block in content_blocks:
        if block.get("type") == "text":
            content = block["text"]
            break

elif provider == "openai":
    choices = raw.get("choices", [])
    if choices:
        content = choices[0].get("message", {}).get("content")

elif provider in ("ollama", "custom"):
    # Ollama chat format
    msg = raw.get("message", {})
    content = msg.get("content")
    if content is None:
        # Ollama generate format fallback
        content = raw.get("response")

if content is None:
    plpy.error(f"Could not extract content from LLM response: {json.dumps(raw)[:500]}")

return json.dumps({"content": content, "raw": raw})
$$;

COMMENT ON FUNCTION alma_private.fn_call_llm(UUID, JSONB) IS
    'HTTP LLM call via plpython3u. Supports anthropic/openai/ollama/custom. API keys from env vars only.';
