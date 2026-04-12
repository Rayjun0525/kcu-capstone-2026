"""
ARGO Dashboard v1.2
- Built-in worker: enqueues a task and runs the fn_next_step/fn_submit_result loop
  directly on the main thread (no threading, Streamlit-compatible).
- Shows a spinner while waiting for the LLM, then re-enables chat_input on completion.
"""
import json
import time
import os
import urllib.request
import urllib.error
import streamlit as st
import psycopg2
import psycopg2.extras
import psycopg2.sql
import pandas as pd
from contextlib import contextmanager

st.set_page_config(page_title="ARGO Dashboard", page_icon="🧠", layout="wide")

st.markdown("""
<style>
.chat-user      { background:var(--secondary-background-color);
                  padding:10px 14px; border-radius:14px 14px 2px 14px;
                  margin:4px 0 4px auto; max-width:78%; text-align:right;
                  font-size:14px; }
.chat-assistant { background:var(--background-color); border:1px solid var(--secondary-background-color);
                  padding:10px 14px; border-radius:14px 14px 14px 2px;
                  margin:4px 0; max-width:84%; font-size:14px; }
.chat-tool      { background:#fff8e1; border-left:3px solid #ffc107;
                  padding:6px 10px; border-radius:4px;
                  margin:2px 0; max-width:84%; font-size:12px; font-family:monospace; }
.chat-thought   { color:#aaa; font-size:12px; font-style:italic; margin:2px 0; }
</style>
""", unsafe_allow_html=True)

PAGES = {
    "🔌 DB Connection":    "db_connect",
    "🤖 Agent Management": "agent_mgmt",
    "💬 Run Agent":        "chat_run",
    "📊 Session Monitoring": "monitoring",
    "🗄️ Table Explorer":     "table_explorer",
    "🧪 Experiments":      "experiments",
}

# ──────────────────────────────────────────────────────
# DB helpers
# ──────────────────────────────────────────────────────
def get_conn_params():
    return dict(
        host    = st.session_state.get("db_host",     "localhost"),
        port    = st.session_state.get("db_port",     5432),
        dbname  = st.session_state.get("db_name",     "postgres"),
        user    = st.session_state.get("db_user",     "postgres"),
        password= st.session_state.get("db_password", ""),
    )

@contextmanager
def get_connection(user=None, password=None):
    p = get_conn_params()
    if user:     p["user"]     = user
    if password: p["password"] = password
    conn = psycopg2.connect(**p)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

def run_query(sql, params=None):
    with get_connection() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(sql, params)
        rows = cur.fetchall()
        return pd.DataFrame(rows) if rows else pd.DataFrame()

def run_query_scalar(sql, params=None):
    with get_connection() as conn:
        cur = conn.cursor()
        cur.execute(sql, params)
        row = cur.fetchone()
        return row[0] if row else None

def is_connected():
    return st.session_state.get("db_connected", False)

def test_connection():
    try:
        with get_connection() as conn:
            cur = conn.cursor()
            cur.execute("SELECT 1 FROM pg_extension WHERE extname='argo'")
            if not cur.fetchone(): return "no_extension"
            cur.execute("SELECT pg_has_role(session_user,'argo_operator','MEMBER')")
            if not cur.fetchone()[0]: return "no_operator"
        return "ok"
    except Exception:
        return "conn_error"

# ──────────────────────────────────────────────────────
# LLM HTTP call
# ──────────────────────────────────────────────────────
def call_llm(llm_config: dict, messages: list) -> str:
    provider    = llm_config.get("provider", "ollama")
    endpoint    = llm_config.get("endpoint") or ""
    model       = llm_config.get("model_name", "")
    api_key_ref = llm_config.get("api_key_ref")
    temperature = float(llm_config.get("temperature", 0.7))
    max_tokens  = int(llm_config.get("max_tokens", 4096))
    req_opts    = llm_config.get("request_options") or {}
    if isinstance(req_opts, str):
        req_opts = json.loads(req_opts)

    api_key = os.getenv(api_key_ref) if api_key_ref else None
    headers = {"Content-Type": "application/json"}

    if provider == "anthropic":
        url      = endpoint or "https://api.anthropic.com/v1/messages"
        sys_text = " ".join(m["content"] for m in messages if m.get("role") == "system")
        user_msgs = [m for m in messages if m.get("role") != "system"]
        payload  = {"model": model, "max_tokens": max_tokens,
                    "temperature": temperature, "messages": user_msgs}
        if sys_text: payload["system"] = sys_text
        payload.update(req_opts)
        headers.update({"x-api-key": api_key or "",
                         "anthropic-version": "2023-06-01"})
    elif provider == "openai":
        url     = endpoint or "https://api.openai.com/v1/chat/completions"
        payload = {"model": model, "max_tokens": max_tokens,
                   "temperature": temperature, "messages": messages}
        payload.update(req_opts)
        headers["Authorization"] = "Bearer " + (api_key or "")
    elif provider == "ollama":
        url     = endpoint or "http://localhost:11434/api/chat"
        payload = {"model": model, "messages": messages,
                   "stream": False, "options": {"temperature": temperature}}
        payload.update(req_opts)
    else:
        url     = endpoint
        payload = {"model": model, "messages": messages,
                   "temperature": temperature, "max_tokens": max_tokens}
        payload.update(req_opts)
        if api_key: headers["Authorization"] = "Bearer " + api_key

    body = json.dumps(payload).encode("utf-8")
    req  = urllib.request.Request(url, data=body, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=120) as resp:
        raw = json.loads(resp.read().decode("utf-8"))

    if provider == "anthropic": return raw["content"][0]["text"]
    elif provider == "openai":  return raw["choices"][0]["message"]["content"]
    elif provider == "ollama":  return raw["message"]["content"]
    else:
        return (raw.get("choices",[{}])[0].get("message",{}).get("content")
                or raw.get("message",{}).get("content") or str(raw))

# ──────────────────────────────────────────────────────
# Inline worker — runs directly on the main thread
# ──────────────────────────────────────────────────────
def run_task_inline(task_id: int, agent_role: str, agent_pw: str) -> list:
    """
    Runs the fn_next_step / fn_submit_result loop synchronously.
    Displays a Streamlit spinner while running and returns the conversation log on completion.
    """
    conn_params = get_conn_params()
    conn_params["user"]     = agent_role
    conn_params["password"] = agent_pw

    conn = psycopg2.connect(**conn_params)
    conn.autocommit = True
    cur  = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    chat_entries = []   # {"role": ..., "content": ...}
    step_count   = 0

    status_placeholder = st.empty()
    log_placeholder    = st.empty()

    def refresh_display():
        with log_placeholder.container():
            for e in chat_entries:
                _render_entry(e)

    try:
        while True:
            step_count += 1
            status_placeholder.caption(f"⚙️ step {step_count} — calling fn_next_step…")

            cur.execute("SELECT argo_public.fn_next_step(%s)", (task_id,))
            step = cur.fetchone()["fn_next_step"]

            if step["action"] == "done":
                output = step.get("output") or ""
                # when done, final answer is already in execution_logs
                # add only if the last assistant entry is missing
                if not any(e["role"] == "assistant" for e in chat_entries):
                    chat_entries.append({"role": "assistant", "content": output})
                status_placeholder.empty()
                refresh_display()
                break

            if step["action"] == "call_llm":
                status_placeholder.caption(f"⚙️ step {step_count} — calling LLM… ({step['llm_config'].get('model_name','')})")

                try:
                    response = call_llm(step["llm_config"], step["messages"])
                except Exception as e:
                    cur.execute(
                        "SELECT argo_public.fn_submit_result(%s, %s, TRUE)",
                        (task_id, f"LLM ERROR: {e}")
                    )
                    chat_entries.append({"role": "error", "content": f"LLM error: {e}"})
                    status_placeholder.empty()
                    refresh_display()
                    break

                # parse response and render to screen
                try:
                    parsed = json.loads(response)
                    action = parsed.get("action", "")
                    thought = parsed.get("thought", "")

                    if thought:
                        chat_entries.append({"role": "thought", "content": thought})

                    if action == "finish":
                        final = parsed.get("final_answer", response)
                        chat_entries.append({"role": "assistant", "content": final})
                    elif action == "execute_sql":
                        sql_stmt = parsed.get("sql", "")
                        chat_entries.append({"role": "tool_input", "content": sql_stmt})
                    else:
                        # other actions or plain text
                        content = parsed.get("content") or parsed.get("message") or response
                        if content and action not in ("delegate",):
                            chat_entries.append({"role": "assistant", "content": content})

                except (json.JSONDecodeError, TypeError):
                    # if not JSON, treat as plain text
                    chat_entries.append({"role": "assistant", "content": response})

                refresh_display()

                # submit result back to DB
                status_placeholder.caption(f"⚙️ step {step_count} — calling fn_submit_result…")
                cur.execute(
                    "SELECT argo_public.fn_submit_result(%s, %s)",
                    (task_id, response)
                )
                result = cur.fetchone()["fn_submit_result"]

                # display tool result if present
                if result.get("tool_result"):
                    chat_entries.append({"role": "tool_result",
                                         "content": str(result["tool_result"])})
                    refresh_display()

                if result["action"] == "done":
                    status_placeholder.empty()
                    refresh_display()
                    break
                # action == "continue" → continue loop

    except Exception as e:
        chat_entries.append({"role": "error", "content": f"Worker error: {e}"})
        status_placeholder.empty()
        refresh_display()

    finally:
        conn.close()
        status_placeholder.empty()

    log_placeholder.empty()   # clear temporary render (will be redrawn from history)
    return chat_entries


def _render_entry(e: dict):
    role    = e["role"]
    content = e["content"]
    if role == "assistant":
        st.markdown(
            f'<div class="chat-assistant">{content}</div>',
            unsafe_allow_html=True)
    elif role == "thought":
        st.markdown(
            f'<div class="chat-thought">💭 {content}</div>',
            unsafe_allow_html=True)
    elif role == "tool_input":
        st.markdown(
            f'<div class="chat-tool">🔧 SQL<br><code>{content}</code></div>',
            unsafe_allow_html=True)
    elif role == "tool_result":
        preview = content[:500] + ("…" if len(content) > 500 else "")
        st.markdown(
            f'<div class="chat-tool">📋 Result<br><code>{preview}</code></div>',
            unsafe_allow_html=True)
    elif role == "error":
        st.error(content)


# ──────────────────────────────────────────────────────
# Sidebar
# ──────────────────────────────────────────────────────
with st.sidebar:
    st.markdown("# 🧠 ARGO")
    st.markdown("**Agent Lifecycle Manager**")
    st.markdown("---")
    if is_connected():
        st.success(f"✅ {st.session_state.get('db_user','')}@"
                   f"{st.session_state.get('db_host','')}/"
                   f"{st.session_state.get('db_name','')}")
    else:
        st.warning("⚠️ Not connected to DB")
    st.markdown("---")
    page = st.radio("Menu", list(PAGES.keys()), label_visibility="collapsed")

# ──────────────────────────────────────────────────────
# DB Connection
# ──────────────────────────────────────────────────────
def page_db_connect():
    st.header("🔌 Database Connection")
    c1, c2 = st.columns(2)
    with c1:
        host   = st.text_input("Host",       value=st.session_state.get("db_host","localhost"))
        port   = st.number_input("Port",        value=st.session_state.get("db_port",5432),
                                  min_value=1, max_value=65535)
        dbname = st.text_input("Database",  value=st.session_state.get("db_name","postgres"))
    with c2:
        user   = st.text_input("Username",      value=st.session_state.get("db_user","postgres"))
        pw     = st.text_input("Password",       value=st.session_state.get("db_password",""),
                                type="password")

    if st.button("🔗 Test Connection", type="primary", use_container_width=True):
        st.session_state.update({"db_host": host, "db_port": int(port),
                                  "db_name": dbname, "db_user": user, "db_password": pw})
        with st.spinner("Connecting..."):
            result = test_connection()
        if result == "ok":
            st.session_state["db_connected"] = True
            st.success("✅ Connection successful!")
            st.balloons()
        elif result == "no_extension":
            st.error("❌ ARGO not installed. Run `CREATE EXTENSION argo;`")
            st.session_state["db_connected"] = False
        elif result == "no_operator":
            st.error(f"❌ Missing argo_operator privilege. `GRANT argo_operator TO {user};`")
            st.session_state["db_connected"] = False
        else:
            st.error("❌ Connection failed.")
            st.session_state["db_connected"] = False

# ──────────────────────────────────────────────────────
# Agent Management
# ──────────────────────────────────────────────────────
def page_agent_mgmt():
    st.header("🤖 Agent Management")
    if not is_connected():
        st.warning("Please connect to the database first."); return

    tab_list, tab_create, tab_edit, tab_delete = st.tabs(
        ["List", "Create Agent", "Edit Settings", "Delete"])

    with tab_list:
        try:
            df = run_query("SELECT * FROM argo_public.list_agents()")
            st.dataframe(df, use_container_width=True, hide_index=True) if not df.empty                 else st.info("No agents registered.")
        except Exception as e:
            st.error(f"Failed to list agents: {e}")

    with tab_create:
        c1, c2 = st.columns(2)
        with c1:
            role_name     = st.text_input("Role Name",   placeholder="agent_sql",           key="ca_role")
            display_name  = st.text_input("Display Name",   placeholder="SQL Analysis Agent",    key="ca_name")
            agent_role_t  = st.selectbox("Agent Role",
                                         ["executor","orchestrator","evaluator"],              key="ca_role_t")
            system_prompt = st.text_area("System Prompt", height=180,
                placeholder=(
                    'You are an SQL expert. Always respond in JSON format.\n'
                    'Done: {"thought":"...","action":"finish","final_answer":"..."}\n'
                    'SQL: {"thought":"...","action":"execute_sql","sql":"SELECT ..."}'
                ),
                key="ca_sysprompt")
        with c2:
            provider      = st.selectbox("LLM Provider",
                                         ["ollama","openai","anthropic","custom"],             key="ca_prov")
            ep_defaults   = {"ollama":"http://localhost:11434/api/chat",
                             "openai":"https://api.openai.com/v1/chat/completions",
                             "anthropic":"https://api.anthropic.com/v1/messages","custom":""}
            endpoint      = st.text_input("Endpoint", value=ep_defaults.get(provider,""),  key="ca_ep")
            model_name    = st.text_input("Model Name",      placeholder="gpt-oss:20b",           key="ca_model")
            emb_model     = st.text_input("Embedding Model (optional)",                               key="ca_emb")
            api_key_ref   = st.text_input("API Key Env Var", placeholder="OPENAI_API_KEY",  key="ca_apiref")
            temperature   = st.slider("Temperature", 0.0, 2.0, 0.7, 0.1,                     key="ca_temp")
            max_tokens    = st.number_input("Max Tokens", min_value=1, value=4096,            key="ca_maxtok")
            req_opts_str  = st.text_input('Request Options (JSON)', placeholder='{"format":"json"}', key="ca_reqopts",
                                          help='Leave blank to omit. Ollama JSON mode: {"format":"json"}')
            max_steps     = st.number_input("Max Steps", min_value=1, value=10,               key="ca_maxsteps")
            max_retries   = st.number_input("Max Retries", min_value=0, value=3,              key="ca_maxretry")
            pwd           = st.text_input("DB Password (leave blank for auto-generated)", type="password",     key="ca_pwd")

        if st.button("✅ Create Agent", type="primary", key="btn_create"):
            if not role_name or not display_name or not model_name:
                st.warning("role_name, display name, and model name are required.")
            else:
                # validate req_opts_str
                parsed_req_opts = None
                if req_opts_str.strip():
                    try:
                        parsed_req_opts = json.loads(req_opts_str.strip())
                    except json.JSONDecodeError as je:
                        st.error("Request Options JSON error: " + str(je) + '  e.g. {"format":"json"}')
                        st.stop()
                try:
                    config = {"name": display_name, "agent_role": agent_role_t,
                              "provider": provider, "endpoint": endpoint,
                              "model_name": model_name, "temperature": float(temperature),
                              "max_tokens": int(max_tokens), "system_prompt": system_prompt,
                              "max_steps": int(max_steps), "max_retries": int(max_retries)}
                    if emb_model.strip():   config["embedding_model"] = emb_model.strip()
                    if api_key_ref.strip(): config["api_key_ref"]     = api_key_ref.strip()
                    if parsed_req_opts:     config["request_options"] = parsed_req_opts
                    if pwd:                 config["password"]        = pwd
                    result = run_query_scalar(
                        "SELECT argo_public.create_agent(%s,%s::jsonb)",
                        (role_name, json.dumps(config, ensure_ascii=False)))
                    st.success(f"✅ {result}")
                except Exception as e:
                    st.error(f"Creation failed: {e}")

    with tab_edit:
        try:
            ag = run_query("SELECT role_name FROM argo_public.list_agents()")
        except Exception as e:
            st.error(f"Failed to fetch agent list: {e}")
            ag = None
        if ag is None or ag.empty:
            st.info("No agents found.")
        else:
            sel = st.selectbox("Select agent", ag["role_name"].tolist(), key="edit_sel")
            try:
                info = run_query("""
                    SELECT ap.system_prompt, ap.max_steps, ap.max_retries,
                           lc.model_name, lc.temperature, lc.max_tokens, lc.endpoint,
                           lc.request_options
                    FROM argo_private.agent_profile_assignments apa
                    JOIN argo_private.agent_profiles ap ON ap.profile_id=apa.profile_id
                    JOIN argo_private.llm_configs lc ON lc.llm_config_id=apa.llm_config_id
                    WHERE apa.role_name=%s""", (sel,))
            except Exception as e:
                st.error(f"Failed to fetch agent info: {e}")
                info = None
            if info is not None and not info.empty:
                row = info.iloc[0]
                new_prompt = st.text_area("System Prompt",
                                          value=str(row.get("system_prompt") or ""),
                                          height=150, key="edit_prompt")
                ec1, ec2 = st.columns(2)
                with ec1:
                    new_model  = st.text_input("Model Name",
                                               value=str(row.get("model_name") or ""),        key="edit_model")
                    new_temp   = st.slider("Temperature", 0.0, 2.0,
                                           float(row.get("temperature") or 0.7), 0.1,         key="edit_temp")
                    new_steps  = st.number_input("Max Steps", min_value=1,
                                                  value=int(row.get("max_steps") or 10),      key="edit_steps")
                with ec2:
                    new_ep     = st.text_input("Endpoint",
                                               value=str(row.get("endpoint") or ""),          key="edit_ep")
                    new_maxtok = st.number_input("Max Tokens", min_value=1,
                                                  value=int(row.get("max_tokens") or 4096),   key="edit_maxtok")
                    new_retry  = st.number_input("Max Retries", min_value=0,
                                                  value=int(row.get("max_retries") or 3),     key="edit_retry")
                    # edit request_options
                    cur_req = row.get("request_options")
                    cur_req_str = json.dumps(cur_req, ensure_ascii=False) if cur_req else ""
                    new_req_str = st.text_input("Request Options (JSON)",
                                                value=cur_req_str,                             key="edit_reqopts",
                                                help='Leave blank to save as NULL. e.g. {"format":"json"}')
                if st.button("💾 Save", type="primary", key="btn_edit_save"):
                    # validate request_options
                    new_req_opts = None
                    if new_req_str.strip():
                        try:
                            new_req_opts = json.loads(new_req_str.strip())
                        except json.JSONDecodeError as je:
                            st.error("Request Options JSON error: " + str(je))
                            st.stop()
                    try:
                        with get_connection() as conn:
                            cur = conn.cursor()
                            cur.execute("""
                                UPDATE argo_private.agent_profiles ap
                                SET system_prompt=%s, max_steps=%s, max_retries=%s
                                FROM argo_private.agent_profile_assignments apa
                                WHERE ap.profile_id=apa.profile_id AND apa.role_name=%s
                            """, (new_prompt, int(new_steps), int(new_retry), sel))
                            cur.execute("""
                                UPDATE argo_private.llm_configs lc
                                SET model_name=%s, temperature=%s, max_tokens=%s,
                                    endpoint=%s, request_options=%s::jsonb
                                FROM argo_private.agent_profile_assignments apa
                                WHERE lc.llm_config_id=apa.llm_config_id AND apa.role_name=%s
                            """, (new_model, float(new_temp), int(new_maxtok),
                                  new_ep,
                                  json.dumps(new_req_opts) if new_req_opts else None,
                                  sel))
                        st.success("✅ Saved")
                    except Exception as e:
                        st.error(f"Save failed: {e}")

    with tab_delete:
        st.warning("⚠️ The agent and all associated data will be permanently deleted.")
        try:
            ag = run_query("SELECT role_name FROM argo_public.list_agents()")
        except Exception as e:
            st.error(f"Failed to fetch agent list: {e}")
            ag = None
        if ag is None or ag.empty:
            st.info("No agents found.")
        else:
            del_sel = st.selectbox("Select agent to delete", ag["role_name"].tolist(), key="del_sel")
            confirm = st.text_input(f'Type "{del_sel}" to confirm deletion', key="del_confirm")
            if st.button("🗑️ Delete", type="primary", key="btn_delete"):
                if confirm != del_sel:
                    st.warning("Please type the agent name exactly to confirm.")
                else:
                    try:
                        result = run_query_scalar("SELECT argo_public.drop_agent(%s)", (del_sel,))
                        st.success(f"✅ {result}")
                    except Exception as e:
                        st.error(f"Delete Failed: {e}")

# ──────────────────────────────────────────────────────
# 💬 Run Agent (core chat)
# ──────────────────────────────────────────────────────
def page_chat_run():
    st.header("💬 Run Agent")
    if not is_connected():
        st.warning("Please connect to the database first."); return

    # Initialise session_state — separate per agent
    if "chat_history" not in st.session_state:
        st.session_state["chat_history"] = {}    # {agent_role: [...]}
    if "chat_session_id" not in st.session_state:
        st.session_state["chat_session_id"] = {} # {agent_role: session_id | None}

    # ── Agent Select
    try:
        agents_df = run_query("SELECT role_name, agent_role FROM argo_public.list_agents()")
    except Exception as e:
        st.error(f"Failed to fetch agent list: {e}"); return

    if agents_df.empty:
        st.info("Please create an agent first."); return

    col_a, col_b, col_c = st.columns([3, 3, 1])
    with col_a:
        agent_role = st.selectbox(
            "Agent",
            agents_df["role_name"].tolist(), key="chat_sel_role",
            format_func=lambda r:
                f"{r}  ({agents_df[agents_df['role_name']==r]['agent_role'].iloc[0]})"
        )
    with col_b:
        agent_pw = st.text_input(
            "Agent DB Password", type="password", key="chat_pw",
            help="Required to connect directly as the agent role")
    with col_c:
        st.markdown("<br>", unsafe_allow_html=True)
        if st.button("🗑️ Reset", key="chat_clear"):
            st.session_state["chat_history"][agent_role]    = []
            st.session_state["chat_session_id"][agent_role] = None
            st.rerun()

    # Initialise per-agent slots — auto-restore last session from DB
    if agent_role not in st.session_state["chat_session_id"]:
        last_sid = run_query_scalar("""
            SELECT s.session_id
            FROM argo_private.sessions s
            JOIN argo_private.agent_meta am ON am.agent_id = s.agent_id
            WHERE am.role_name = %s AND s.status = 'active'
            ORDER BY s.session_id DESC LIMIT 1
        """, (agent_role,))
        st.session_state["chat_session_id"][agent_role] = last_sid

    if agent_role not in st.session_state["chat_history"]:
        last_sid = st.session_state["chat_session_id"].get(agent_role)
        if last_sid:
            try:
                logs = run_query("""
                    SELECT el.role, el.content
                    FROM argo_private.tasks t
                    JOIN argo_private.execution_logs el ON el.task_id = t.task_id
                    WHERE t.session_id = %s
                      AND el.role IN ('user', 'assistant')
                    ORDER BY t.task_id, el.step_number
                """, (last_sid,))
                history = []
                for _, row in logs.iterrows():
                    role = "user" if row["role"] == "user" else "assistant"
                    history.append({"role": role, "content": row["content"]})
                st.session_state["chat_history"][agent_role] = history
            except Exception:
                st.session_state["chat_history"][agent_role] = []
        else:
            st.session_state["chat_history"][agent_role] = []

    # Display current session
    cur_session_id = st.session_state["chat_session_id"].get(agent_role)

    col_m, col_s = st.columns([1, 3])
    with col_m:
        mem_limit = st.number_input("Memory references", min_value=0, value=5, key="chat_mem")
    with col_s:
        keep_session = st.checkbox(
            "Continue in same session", value=True, key="chat_keep_sess",
            help="Keep previous conversation context when checked")

    if keep_session and cur_session_id:
        st.caption(f"🔗 Current session_id={cur_session_id}  (press Reset to start a new session)")
    elif keep_session:
        st.caption("💬 Send your first message to start a new session.")

    st.markdown("---")

    # ── Render conversation history (per agent)
    for entry in st.session_state["chat_history"][agent_role]:
        role    = entry["role"]
        content = entry["content"]
        if role == "user":
            st.markdown(
                f'<div class="chat-user">{content}</div>',
                unsafe_allow_html=True)
        else:
            _render_entry(entry)

    # ── Input box (chat_input is always pinned to the bottom)
    user_input = st.chat_input(
        "Type a message… (Agent Password required)",
        key="chat_input_box")

    if not user_input:
        return   # no input, do nothing

    # Password Confirm
    if not agent_pw:
        st.error("Please enter the Agent DB Password.")
        return

    # Test connection as agent role
    try:
        p = get_conn_params()
        p["user"] = agent_role; p["password"] = agent_pw
        test = psycopg2.connect(**p, connect_timeout=5)
        test.close()
    except Exception as e:
        st.error(f"Agent connection failed: {e}")
        return

    # Show user message immediately
    st.session_state["chat_history"][agent_role].append({"role": "user", "content": user_input})
    st.markdown(f'<div class="chat-user">{user_input}</div>', unsafe_allow_html=True)

    # ── call run_agent (connected as agent role)
    session_id = st.session_state["chat_session_id"].get(agent_role) if keep_session else None
    try:
        p = get_conn_params()
        p["user"] = agent_role; p["password"] = agent_pw
        conn_ag = psycopg2.connect(**p)
        conn_ag.autocommit = True
        cur_ag  = conn_ag.cursor()
        if session_id:
            cur_ag.execute(
                "SELECT argo_public.run_agent(%s,%s,%s,%s,%s)",
                (agent_role, user_input, session_id, int(mem_limit), 20))
        else:
            cur_ag.execute(
                "SELECT argo_public.run_agent(%s,%s,NULL,%s,%s)",
                (agent_role, user_input, int(mem_limit), 20))
        task_id = cur_ag.fetchone()[0]
        conn_ag.close()
    except Exception as e:
        st.error(f"Task enqueue failed: {e}")
        return

    # Save session_id for new sessions (query argo_private.tasks via operator connection)
    if keep_session and not session_id:
        try:
            new_sid = run_query_scalar(
                "SELECT session_id FROM argo_private.tasks WHERE task_id=%s", (task_id,))
            if new_sid:
                st.session_state["chat_session_id"][agent_role] = new_sid
        except Exception:
            pass

    # ── Run inline worker (synchronous, main thread)
    with st.spinner(f"⚙️ Agent processing… (task_id={task_id})"):
        result_entries = run_task_inline(task_id, agent_role, agent_pw)

    # Append result to per-agent history
    for e in result_entries:
        st.session_state["chat_history"][agent_role].append(e)

    # Refresh screen (redraw full history)
    st.rerun()

# ──────────────────────────────────────────────────────
# Session Monitoring
# ──────────────────────────────────────────────────────
def page_monitoring():
    st.header("📊 Session Monitoring")
    if not is_connected():
        st.warning("Please connect to the database first."); return

    try:
        stats = run_query("""
            SELECT COUNT(*) AS total,
                   COUNT(*) FILTER (WHERE status='active')    AS active,
                   COUNT(*) FILTER (WHERE status='completed') AS completed,
                   COUNT(*) FILTER (WHERE status='failed')    AS failed
            FROM argo_private.sessions""")
        if not stats.empty:
            r = stats.iloc[0]
            c1,c2,c3,c4 = st.columns(4)
            c1.metric("Total Sessions", int(r["total"]))
            c2.metric("Active",      int(r["active"]))
            c3.metric("Completed",      int(r["completed"]))
            c4.metric("Failed",      int(r["failed"]))
    except Exception: pass

    st.markdown("---")
    t1, t2, t3 = st.tabs(["Task Status", "Session List", "Audit Log"])

    with t1:
        try:
            df = run_query("""
                SELECT t.task_id, am.role_name, t.status,
                       left(t.input,60) AS input_preview,
                       left(t.output,60) AS output_preview,
                       t.created_at, t.updated_at
                FROM argo_private.tasks t
                JOIN argo_private.agent_meta am ON am.agent_id=t.agent_id
                ORDER BY t.task_id DESC LIMIT 50""")
            st.dataframe(df, use_container_width=True, hide_index=True) if not df.empty \
                else st.info("No tasks found.")
        except Exception as e: st.error(f"{e}")

    with t2:
        try:
            df = run_query("""
                SELECT s.session_id, am.role_name, s.status,
                       left(s.goal,50) AS goal, s.started_at, s.completed_at,
                       left(s.final_answer,60) AS answer_preview
                FROM argo_private.sessions s
                JOIN argo_private.agent_meta am ON am.agent_id=s.agent_id
                ORDER BY s.session_id DESC LIMIT 50""")
            if not df.empty:
                sid = st.selectbox("Select Session → view steps",
                                   ["(none)"] + df["session_id"].tolist(),
                                   key="mon_sid")
                st.dataframe(df, use_container_width=True, hide_index=True)
                if sid != "(none)":
                    detail = run_query("SELECT * FROM argo_public.get_session(%s)", (int(sid),))
                    st.dataframe(detail, use_container_width=True, hide_index=True)
            else:
                st.info("No sessions found.")
        except Exception as e: st.error(f"{e}")

    with t3:
        try:
            df = run_query("""
                SELECT * FROM argo_public.v_session_audit
                ORDER BY session_id DESC, task_id, step_number LIMIT 200""")
            st.dataframe(df, use_container_width=True, hide_index=True) if not df.empty \
                else st.info("No audit logs found.")
        except Exception as e: st.error(f"{e}")

    if st.button("🔄 Refresh", key="mon_refresh"):
        st.rerun()

# ──────────────────────────────────────────────────────
# Table Explorer
# ──────────────────────────────────────────────────────
def page_table_explorer():
    st.header("🗄️ Table Explorer")
    if not is_connected():
        st.warning("Please connect to the database first."); return

    TABLES = [
        "argo_private.tasks", "argo_private.sessions",
        "argo_private.execution_logs", "argo_private.agent_meta",
        "argo_private.llm_configs", "argo_private.agent_profiles",
        "argo_private.memory", "argo_private.task_dependencies",
        "argo_private.system_agent_configs", "argo_private.sql_sandbox_allowlist",
        "argo_public.v_ready_tasks", "argo_public.v_compressible_logs",
        "argo_public.v_system_agents",
    ]
    sel   = st.selectbox("Table / View", TABLES, key="te_tbl")
    limit = st.number_input("Max rows", min_value=1, value=50, key="te_limit")
    order = st.text_input("Sort column (optional)", key="te_order")

    if st.button("Query", type="primary", key="te_btn"):
        try:
            order_sql = f"ORDER BY {order} DESC" if order.strip() else ""
            df = run_query(f"SELECT * FROM {sel} {order_sql} LIMIT %s", (int(limit),))
            st.dataframe(df, use_container_width=True, hide_index=True) if not df.empty \
                else st.info("No data.")
        except Exception as e:
            st.error(f"Query Failed: {e}")

# ──────────────────────────────────────────────────────
# Experiment management
# ──────────────────────────────────────────────────────
def page_experiments():
    st.header("🧪 Experiments")
    if not is_connected():
        st.warning("Please connect to the database first."); return

    t1, t2, t3 = st.tabs(["List", "New Experiment", "Compare Results"])
    with t1:
        try:
            df = run_query("SELECT * FROM argo_private.experiments ORDER BY created_at DESC")
            st.dataframe(df, use_container_width=True, hide_index=True) if not df.empty \
                else st.info("No experiments found.")
        except Exception as e: st.error(f"{e}")

    with t2:
        name = st.text_input("Experiment Name",       key="exp_name")
        task = st.text_area("Task Prompt",  key="exp_task", height=100)
        desc = st.text_area("Description (optional)",       key="exp_desc", height=60)
        if st.button("Register", type="primary", key="exp_reg"):
            if name and task:
                try:
                    with get_connection() as conn:
                        conn.cursor().execute(
                            "INSERT INTO argo_private.experiments(name,task_prompt,description) VALUES(%s,%s,%s)",
                            (name, task, desc or None))
                    st.success("✅ Registered")
                except Exception as e: st.error(f"{e}")
            else:
                st.warning("Name and Task Prompt are required.")

    with t3:
        try:
            exps = run_query("SELECT experiment_id,name FROM argo_private.experiments")
            if not exps.empty:
                sel_exp = st.selectbox("Experiment Select", exps["experiment_id"].tolist(),
                    format_func=lambda i: f"#{i} {exps[exps['experiment_id']==i]['name'].iloc[0]}",
                    key="res_sel")
                df = run_query(
                    "SELECT * FROM argo_private.experiment_results WHERE experiment_id=%s ORDER BY created_at",
                    (int(sel_exp),))
                st.dataframe(df, use_container_width=True, hide_index=True) if not df.empty \
                    else st.info("No result data.")
        except Exception as e: st.error(f"{e}")

# ──────────────────────────────────────────────────────
# Page routing
# ──────────────────────────────────────────────────────
{
    "🔌 DB Connection":       page_db_connect,
    "🤖 Agent Management": page_agent_mgmt,
    "💬 Run Agent":        page_chat_run,
    "📊 Session Monitoring": page_monitoring,
    "🗄️ Table Explorer":     page_table_explorer,
    "🧪 Experiments":         page_experiments,
}[page]()
