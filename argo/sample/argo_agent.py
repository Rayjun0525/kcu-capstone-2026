#!/usr/bin/env python3
"""
ARGO Python Worker v1.0
========================
The database acts as the control plane (fn_next_step / fn_submit_result).
The worker is responsible only for making LLM HTTP calls.

Usage:
  python3 argo_agent.py agent_sql "show me all tables"   # enqueue a task
  python3 argo_agent.py --worker agent_sql               # run worker loop
  python3 argo_agent.py --compressor argo_compressor     # run compressor

Environment variables:
  DB_NAME              Database name          (default: postgres)
  DB_USER              Database user / role   (default: agent_role arg)
  DB_PASSWORD          Database password      (default: empty)
  DB_HOST              Database host          (default: localhost)
  DB_PORT              Database port          (default: 5432)
  ARGO_WORKER_POLL_SEC Polling interval secs  (default: 1.0)
"""
import os, sys, time, json, select, argparse, urllib.request, urllib.error
import psycopg2, psycopg2.extensions, psycopg2.extras


def get_conn(role):
    return psycopg2.connect(
        dbname   = os.getenv("DB_NAME",     "postgres"),
        user     = os.getenv("DB_USER",     role),
        password = os.getenv("DB_PASSWORD", ""),
        host     = os.getenv("DB_HOST",     "localhost"),
        port     = os.getenv("DB_PORT",     "5432"),
    )


def call_llm(llm_config, messages):
    """Make an HTTP call to the configured LLM provider. Worker-only responsibility."""
    provider    = llm_config.get("provider", "ollama")
    endpoint    = llm_config.get("endpoint", "")
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
        url       = endpoint or "https://api.anthropic.com/v1/messages"
        sys_text  = " ".join(m["content"] for m in messages if m.get("role") == "system")
        user_msgs = [m for m in messages if m.get("role") != "system"]
        payload   = {"model": model, "max_tokens": max_tokens,
                     "temperature": temperature, "messages": user_msgs}
        if sys_text:
            payload["system"] = sys_text
        payload.update(req_opts)
        headers.update({"x-api-key": api_key or "", "anthropic-version": "2023-06-01"})

    elif provider == "openai":
        url     = endpoint or "https://api.openai.com/v1/chat/completions"
        payload = {"model": model, "max_tokens": max_tokens,
                   "temperature": temperature, "messages": messages}
        payload.update(req_opts)
        headers["Authorization"] = "Bearer " + (api_key or "")

    elif provider == "ollama":
        url     = endpoint or "http://localhost:11434/api/chat"
        payload = {"model": model, "messages": messages, "stream": False,
                   "options": {"temperature": temperature}}
        payload.update(req_opts)

    else:
        url     = endpoint
        payload = {"model": model, "messages": messages,
                   "temperature": temperature, "max_tokens": max_tokens}
        payload.update(req_opts)
        if api_key:
            headers["Authorization"] = "Bearer " + api_key

    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(), headers=headers, method="POST"
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        raw = json.loads(resp.read().decode())

    if provider == "anthropic":
        return raw["content"][0]["text"]
    elif provider == "openai":
        return raw["choices"][0]["message"]["content"]
    elif provider == "ollama":
        return raw["message"]["content"]
    else:
        return (raw.get("choices", [{}])[0].get("message", {}).get("content")
                or raw.get("message", {}).get("content") or str(raw))


def execute_task(task_id, conn):
    """
    fn_next_step / fn_submit_result loop.
    The database makes all decisions; the worker only handles HTTP.
    """
    conn.autocommit = True
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    while True:
        cur.execute("SELECT argo_public.fn_next_step(%s)", (task_id,))
        step = cur.fetchone()["fn_next_step"]

        if step["action"] == "done":
            print(f"  [task {task_id}] done", flush=True)
            break

        if step["action"] == "call_llm":
            try:
                response = call_llm(step["llm_config"], step["messages"])
            except Exception as e:
                cur.execute("SELECT argo_public.fn_submit_result(%s,%s,TRUE)",
                            (task_id, f"LLM ERROR: {e}"))
                print(f"  [task {task_id}] LLM error: {e}", flush=True)
                break
            cur.execute("SELECT argo_public.fn_submit_result(%s,%s)", (task_id, response))
            result = cur.fetchone()["fn_submit_result"]
            if result["action"] == "done":
                print(f"  [task {task_id}] completed", flush=True)
                break
    cur.close()


def run_single(args):
    """Enqueue a task and print the task_id."""
    conn = get_conn(args.agent_role)
    conn.autocommit = True
    try:
        cur = conn.cursor()
        if args.session_id:
            cur.execute(
                "SELECT argo_public.run_agent(%s,%s,%s,%s,%s)",
                (args.agent_role, args.task, args.session_id,
                 args.memory_limit, args.history_steps),
            )
        else:
            cur.execute(
                "SELECT argo_public.run_agent(%s,%s,NULL,%s,%s)",
                (args.agent_role, args.task, args.memory_limit, args.history_steps),
            )
        task_id = cur.fetchone()[0]
        print(f"Task enqueued. task_id={task_id}")
        print(f"Monitor: SELECT * FROM argo_public.v_my_tasks WHERE task_id={task_id};")
    finally:
        conn.close()


def run_worker(args):
    """
    Worker loop: listens for pg_notify on 'argo_task_ready' and polls
    v_ready_tasks. Processes one task at a time per worker process.
    Run multiple worker processes for parallelism.
    """
    print(f"[ARGO worker] Starting: {args.agent_role}", flush=True)
    listen_conn = get_conn(args.agent_role)
    listen_conn.autocommit = True
    listen_conn.cursor().execute("LISTEN argo_task_ready;")
    poll = float(os.getenv("ARGO_WORKER_POLL_SEC", "1.0"))

    try:
        while True:
            if select.select([listen_conn], [], [], poll)[0]:
                listen_conn.poll()
                while listen_conn.notifies:
                    listen_conn.notifies.pop(0)

            qconn = get_conn(args.agent_role)
            qconn.autocommit = False
            try:
                cur = qconn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
                cur.execute("""
                    SELECT t.task_id
                    FROM argo_private.tasks t
                    JOIN argo_public.v_ready_tasks vr ON vr.task_id = t.task_id
                    JOIN argo_private.agent_meta   am ON am.agent_id = t.agent_id
                    WHERE am.role_name = %s
                    ORDER BY t.created_at
                    LIMIT 1
                    FOR UPDATE OF t SKIP LOCKED
                """, (args.agent_role,))
                row = cur.fetchone()
                if not row:
                    qconn.rollback(); cur.close(); qconn.close()
                    continue
                task_id = row["task_id"]
                cur.execute(
                    "UPDATE argo_private.tasks SET status='running' WHERE task_id=%s",
                    (task_id,)
                )
                qconn.commit(); cur.close(); qconn.close()
            except Exception as e:
                qconn.rollback(); qconn.close()
                print(f"[worker] query error: {e}", flush=True)
                continue

            print(f"[worker] executing task_id={task_id}", flush=True)
            econn = get_conn(args.agent_role)
            try:
                execute_task(task_id, econn)
            except Exception as e:
                print(f"[worker] task={task_id} FAILED: {e}", flush=True)
                fconn = get_conn(args.agent_role)
                fconn.autocommit = True
                fconn.cursor().execute(
                    "UPDATE argo_private.tasks SET status='failed', output=%s WHERE task_id=%s",
                    (str(e), task_id)
                )
                fconn.close()
            finally:
                econn.close()

    except KeyboardInterrupt:
        print("[ARGO worker] Stopped.", flush=True)
    finally:
        listen_conn.close()


def run_compressor(args):
    """
    Compressor loop: polls v_compressible_logs, asks the LLM to summarize
    execution logs, stores the compressed summary, and purges originals
    if the quality score meets the configured threshold.
    """
    print(f"[ARGO compressor] Starting: {args.agent_role}", flush=True)
    try:
        while True:
            oconn = psycopg2.connect(
                dbname   = os.getenv("DB_NAME",     "postgres"),
                user     = os.getenv("DB_USER",     "postgres"),
                password = os.getenv("DB_PASSWORD", ""),
                host     = os.getenv("DB_HOST",     "localhost"),
                port     = os.getenv("DB_PORT",     "5432"),
            )
            oconn.autocommit = True
            ocur = oconn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

            ocur.execute(
                "SELECT * FROM argo_private.system_agent_configs WHERE agent_type='compressor'"
            )
            cfg = ocur.fetchone()
            if not cfg or not cfg["is_enabled"]:
                ocur.close(); oconn.close()
                print("[compressor] disabled.", flush=True)
                time.sleep(60)
                continue

            s  = cfg["settings"] or {}
            qt = float(s.get("quality_threshold", 0.9))
            rt = float(s.get("retry_threshold",   0.8))
            mr = int(  s.get("max_retries",        2))
            bs = int(  s.get("batch_size",          5))
            ri = int(cfg["run_interval_secs"])
            last = cfg["last_run_at"]

            if last:
                import datetime
                elapsed = (
                    datetime.datetime.now(datetime.timezone.utc) - last
                ).total_seconds()
                if elapsed < ri:
                    ocur.close(); oconn.close()
                    time.sleep(60)
                    continue

            ocur.execute(
                f"SELECT task_id, total_steps FROM argo_public.v_compressible_logs "
                f"ORDER BY total_steps DESC LIMIT {bs}"
            )
            targets = ocur.fetchall()

            if not targets:
                ocur.execute(
                    "UPDATE argo_private.system_agent_configs "
                    "SET last_run_at=now() WHERE agent_type='compressor'"
                )
                ocur.close(); oconn.close()
                time.sleep(ri)
                continue

            ocur.execute("""
                SELECT lc.*, ap.system_prompt
                FROM argo_private.llm_configs lc
                JOIN argo_private.agent_profile_assignments apa
                     ON lc.llm_config_id = apa.llm_config_id
                JOIN argo_private.agent_profiles ap
                     ON ap.profile_id = apa.profile_id
                WHERE apa.role_name = %s
            """, (args.agent_role,))
            lcfg = ocur.fetchone()
            if not lcfg:
                print(f"[compressor] no LLM config for {args.agent_role}", flush=True)
                ocur.close(); oconn.close()
                time.sleep(ri)
                continue

            system_prompt = lcfg["system_prompt"]
            llm_config = {k: lcfg[k] for k in [
                "provider", "endpoint", "model_name", "api_key_ref",
                "temperature", "max_tokens", "request_options"
            ]}

            for target in targets:
                task_id = target["task_id"]
                ocur.execute("""
                    SELECT step_number, role, content
                    FROM argo_private.execution_logs
                    WHERE task_id = %s AND compressed_at IS NULL
                    ORDER BY step_number
                """, (task_id,))
                logs = ocur.fetchall()
                if not logs:
                    continue

                logs_payload = json.dumps([
                    {"step": r["step_number"], "role": r["role"], "content": r["content"]}
                    for r in logs
                ], ensure_ascii=False)
                messages = [
                    {"role": "system", "content": system_prompt},
                    {"role": "user",   "content": logs_payload},
                ]

                result = None
                for attempt in range(mr + 1):
                    try:
                        raw     = call_llm(llm_config, messages)
                        parsed  = json.loads(raw)
                        quality = float(parsed.get("quality_score", 0))
                        print(
                            f"[compressor] task={task_id} attempt={attempt+1} "
                            f"quality={quality:.2f}", flush=True
                        )
                        if quality >= rt:
                            result = parsed
                            break
                        elif attempt < mr:
                            messages += [
                                {"role": "assistant", "content": raw},
                                {"role": "user",
                                 "content": f"Quality {quality:.2f} is below {rt}. "
                                            f"Re-compress with more detail."},
                            ]
                    except Exception as e:
                        print(f"[compressor] LLM error attempt {attempt+1}: {e}", flush=True)

                if not result:
                    print(f"[compressor] task={task_id} all attempts failed, skipping.",
                          flush=True)
                    continue

                quality = float(result.get("quality_score", 0))
                summary = json.dumps(result, ensure_ascii=False)
                ocur.execute("""
                    UPDATE argo_private.execution_logs
                    SET compressed_content  = %s,
                        compression_quality = %s,
                        compressed_at       = now()
                    WHERE task_id = %s AND compressed_at IS NULL
                """, (summary, quality, task_id))

                if quality >= qt:
                    try:
                        ocur.execute(
                            "SELECT argo_public.fn_purge_compressed_logs(%s, %s)",
                            (task_id, qt)
                        )
                        deleted = ocur.fetchone()[0]
                        print(f"[compressor] task={task_id} purged {deleted} logs",
                              flush=True)
                    except Exception as e:
                        print(f"[compressor] purge failed task={task_id}: {e}", flush=True)
                else:
                    print(
                        f"[compressor] task={task_id} quality {quality:.2f} < {qt}, "
                        f"keeping originals", flush=True
                    )

            ocur.execute(
                "UPDATE argo_private.system_agent_configs "
                "SET last_run_at=now() WHERE agent_type='compressor'"
            )
            ocur.close(); oconn.close()
            time.sleep(ri)

    except KeyboardInterrupt:
        print("[ARGO compressor] Stopped.", flush=True)


def main():
    p = argparse.ArgumentParser(description="ARGO Worker v1.0")
    p.add_argument("--worker",     action="store_true",
                   help="Run as a task worker (polling loop)")
    p.add_argument("--compressor", action="store_true",
                   help="Run as a log compressor")
    p.add_argument("agent_role",   nargs="?", default=os.getenv("ARGO_AGENT_ROLE"),
                   help="PostgreSQL role name of the agent")
    p.add_argument("task",         nargs="?", default=os.getenv("ARGO_TASK"),
                   help="Task instruction (enqueue mode only)")
    p.add_argument("-s", "--session-id",  type=int, default=None,
                   help="Resume an existing session")
    p.add_argument("--memory-limit",      type=int, default=5,
                   help="Long-term memory entries to inject (default: 5)")
    p.add_argument("--history-steps",     type=int, default=20,
                   help="Previous conversation steps to restore (default: 20)")
    args = p.parse_args()

    if not args.agent_role:
        p.print_help()
        sys.exit(1)

    if args.compressor:
        run_compressor(args)
    elif args.worker:
        run_worker(args)
    else:
        if not args.task:
            p.print_help()
            sys.exit(1)
        run_single(args)


if __name__ == "__main__":
    main()
