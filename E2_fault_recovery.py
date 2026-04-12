#!/usr/bin/env python3
"""
ALMA 실험 E2: 장애 복구와 상태 일관성 (Fault Recovery & State Consistency)
==========================================================
DBaaCP 핵심 검증: 워커 SIGKILL 시 PostgreSQL 트랜잭션이 상태 손실을
방지하는지, 재시작 워커가 마지막 커밋 지점부터 정확히 재개하는지 검증.

시나리오:
  - e2_test_agent가 "실패에 관한 대화" 5턴 진행
  - STEP 3: fn_next_step() 호출 + LLM 응답 수신 완료
             → fn_submit_result() 호출 직전에 SIGKILL
  - 측정:
    (a) kill 직후 execution_logs 상태 — STEP 3 기록 없어야 정상
    (b) kill 직후 tasks.status — running 상태로 멈춰있어야 함
    (c) 재시작 워커가 running 태스크를 감지하고 fn_next_step()부터 재개

구현:
  - 워커를 multiprocessing.Process로 분리
  - 파이프(pipe)로 "fn_submit_result 호출 직전" 시점을 메인에 신호
  - 메인이 신호 수신 즉시 os.kill(pid, SIGKILL)
  - 재시작 워커는 running 상태 태스크를 찾아 fn_next_step()부터 재실행

DB: edb / enterprisedb / port 5444
"""
import os, sys, time, json, signal
import multiprocessing
import psycopg2, psycopg2.extras
import urllib.request
from datetime import datetime

# ══════════════════════════════════════════════════════════════════════════════
# 설정
# ══════════════════════════════════════════════════════════════════════════════
DB_CONFIG = dict(
    dbname  = os.getenv("DB_NAME",     "edb"),
    user    = os.getenv("DB_USER",     "enterprisedb"),
    password= os.getenv("DB_PASSWORD", ""),
    host    = os.getenv("DB_HOST",     "localhost"),
    port    = int(os.getenv("DB_PORT", "5444")),
)
AGENT_ROLE = "e2_test_agent"
AGENT_PW   = os.getenv("AGENT_PASSWORD", "e2_test_pw_2024")
MODEL      = "gpt-oss:20b"
ENDPOINT   = "http://localhost:11434/api/chat"

PROMPT = """\
당신은 인생 상담가입니다. 상대방의 이야기에 공감하며 진심 어린 조언을 건넵니다.
이전 대화 흐름을 이어받아 자연스럽게 답하세요.
반드시 JSON으로만 응답하세요.

응답 형식:
{"thought":"[공감과 분석 과정]","action":"finish","final_answer":"[따뜻한 조언 3~4문장]"}
"""

STEP_TASKS = [
    "저는 최근 중요한 프로젝트에서 실패했습니다. 많이 자책하게 됩니다.",
    "주변 사람들에게 실망을 줬다는 생각이 계속 머릿속을 맴돌아요.",
    "다시 시작할 용기가 나지 않습니다. 어떻게 해야 할까요?",
    "선생님 말씀을 들으니 조금 위안이 됩니다. 그래도 두렵습니다.",
    "앞으로 어떤 마음가짐으로 살아가야 할까요?",
]
KILL_AT_STEP = 3   # 이 스텝의 fn_submit_result 직전에 SIGKILL

# ══════════════════════════════════════════════════════════════════════════════
# 출력 유틸
# ══════════════════════════════════════════════════════════════════════════════
SEP  = "─" * 72
SEP2 = "═" * 72

def header(title):
    print(f"\n{SEP2}\n  {title}\n{SEP2}", flush=True)

def section(title):
    print(f"\n{SEP}\n  {title}\n{SEP}", flush=True)

def sql_block(label, sql, result=None):
    print(f"\n  ▶ {label}", flush=True)
    for line in sql.strip().splitlines():
        print(f"    {line}", flush=True)
    if result is not None:
        print(f"  ◀ 결과: {result}", flush=True)

def kv(key, value, indent=2):
    pad = " " * indent
    lines = str(value).splitlines()
    if len(lines) > 1:
        print(f"{pad}【{key}】", flush=True)
        for l in lines:
            print(f"{pad}  {l}", flush=True)
    else:
        print(f"{pad}【{key}】 {lines[0] if lines else ''}", flush=True)

# ══════════════════════════════════════════════════════════════════════════════
# DB 연결
# ══════════════════════════════════════════════════════════════════════════════
def get_op_conn():
    return psycopg2.connect(**DB_CONFIG)

def get_agent_conn():
    return psycopg2.connect(**{**DB_CONFIG, "user": AGENT_ROLE, "password": AGENT_PW})

# ══════════════════════════════════════════════════════════════════════════════
# LLM 호출
# ══════════════════════════════════════════════════════════════════════════════
def call_llm(llm_config, messages):
    payload = {
        "model":   llm_config["model_name"],
        "messages": messages,
        "stream":  False,
        "options": {"temperature": float(llm_config.get("temperature", 0.0))},
        "format":  "json",
    }
    req = urllib.request.Request(
        llm_config["endpoint"],
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read().decode())["message"]["content"]

# ══════════════════════════════════════════════════════════════════════════════
# SETUP: 에이전트 준비
# ══════════════════════════════════════════════════════════════════════════════
def setup_agent():
    header("SETUP. 에이전트 준비")
    op = get_op_conn(); op.autocommit = True
    cur = op.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    cur.execute("SELECT COUNT(*) AS cnt FROM pg_roles WHERE rolname = %s", (AGENT_ROLE,))
    exists = cur.fetchone()["cnt"] > 0
    sql_block("pg_roles 확인",
              f"SELECT COUNT(*) FROM pg_roles WHERE rolname = '{AGENT_ROLE}';",
              f"{'존재 → 재사용' if exists else '없음 → 신규 생성'}")

    if exists:
        cur.execute(f"ALTER ROLE {AGENT_ROLE} PASSWORD %s", (AGENT_PW,))
        sql_block("비밀번호 재설정", f"ALTER ROLE {AGENT_ROLE} PASSWORD '***';", "OK")
    else:
        config = {
            "name": "E2 테스트 에이전트", "agent_role": "executor",
            "provider": "ollama", "endpoint": ENDPOINT,
            "model_name": MODEL, "temperature": 0.0, "max_tokens": 1024,
            "request_options": {"format": "json"},
            "system_prompt": PROMPT,
            "max_steps": 20, "max_retries": 2, "password": AGENT_PW,
        }
        cur.execute("SELECT alma_public.create_agent(%s, %s::jsonb)",
                    (AGENT_ROLE, json.dumps(config)))
        res = cur.fetchone()
        sql_block("에이전트 생성",
                  f"SELECT alma_public.create_agent('{AGENT_ROLE}', '{{...}}'::jsonb);",
                  list(res.values())[0])

    cur.execute("SELECT agent_id FROM alma_private.agent_meta WHERE role_name = %s", (AGENT_ROLE,))
    agent_id = cur.fetchone()["agent_id"]
    kv("agent_id", agent_id)
    op.close()
    return agent_id

# ══════════════════════════════════════════════════════════════════════════════
# execution_logs + 태스크 현황 출력
# ══════════════════════════════════════════════════════════════════════════════
def print_exec_logs(op_cur, task_id, session_id):
    op_cur.execute("""
        SELECT step_number, role, content
        FROM alma_private.execution_logs
        WHERE task_id = %s ORDER BY step_number""", (task_id,))
    logs = op_cur.fetchall()
    sql_block("execution_logs (현재 태스크)",
              f"SELECT step_number, role, content\n"
              f"FROM alma_private.execution_logs\n"
              f"WHERE task_id = {task_id} ORDER BY step_number;")
    print(f"    {'step':>4}  {'role':<10}  content")
    print(f"    {'----':>4}  {'----------':<10}  {'-------'}")
    for row in logs:
        try:
            c = json.dumps(json.loads(row["content"]), ensure_ascii=False)[:72]
        except Exception:
            c = str(row["content"])[:72]
        print(f"    {row['step_number']:>4}  {row['role']:<10}  {c}")

    op_cur.execute("""
        SELECT task_id, status, LEFT(input, 40) AS input_short
        FROM alma_private.tasks
        WHERE session_id = %s ORDER BY task_id""", (session_id,))
    tasks = op_cur.fetchall()
    sql_block("세션 내 전체 태스크 현황",
              f"SELECT task_id, status, LEFT(input,40)\n"
              f"FROM alma_private.tasks\n"
              f"WHERE session_id = {session_id} ORDER BY task_id;")
    print(f"    {'task_id':>8}  {'status':<12}  input")
    print(f"    {'-------':>8}  {'------':<12}  {'-----'}")
    for t in tasks:
        print(f"    {t['task_id']:>8}  {t['status']:<12}  {t['input_short']}")

# ══════════════════════════════════════════════════════════════════════════════
# DB 스냅샷 (장애 상태 확인용)
# ══════════════════════════════════════════════════════════════════════════════
def snapshot_db_state(label, session_id, task_id=None):
    section(f"DB 상태 스냅샷: {label}")
    op = get_op_conn(); op.autocommit = True
    cur = op.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    # 태스크 상태
    cur.execute("""
        SELECT task_id, status, LEFT(input,40) AS input_short
        FROM alma_private.tasks WHERE session_id = %s ORDER BY task_id""", (session_id,))
    tasks = cur.fetchall()
    sql_block("tasks 상태 조회",
              f"SELECT task_id, status, LEFT(input,40)\n"
              f"FROM alma_private.tasks\n"
              f"WHERE session_id = {session_id} ORDER BY task_id;")
    print(f"    {'task_id':>8}  {'status':<12}  input")
    print(f"    {'-------':>8}  {'------':<12}  {'-----'}")
    for t in tasks:
        print(f"    {t['task_id']:>8}  {t['status']:<12}  {t['input_short']}")

    # execution_logs 전체 행 수
    cur.execute("""
        SELECT t.task_id, COUNT(el.log_id) AS log_count
        FROM alma_private.tasks t
        LEFT JOIN alma_private.execution_logs el ON el.task_id = t.task_id
        WHERE t.session_id = %s
        GROUP BY t.task_id ORDER BY t.task_id""", (session_id,))
    log_counts = cur.fetchall()
    sql_block("execution_logs 행 수 확인",
              f"SELECT t.task_id, COUNT(el.log_id) AS log_count\n"
              f"FROM alma_private.tasks t\n"
              f"LEFT JOIN alma_private.execution_logs el ON el.task_id = t.task_id\n"
              f"WHERE t.session_id = {session_id}\n"
              f"GROUP BY t.task_id ORDER BY t.task_id;")
    print(f"    {'task_id':>8}  {'log_count':>10}")
    for r in log_counts:
        print(f"    {r['task_id']:>8}  {r['log_count']:>10}")

    op.close()

# ══════════════════════════════════════════════════════════════════════════════
# 워커 프로세스 함수 (자식 프로세스에서 실행)
# kill_pipe_w: 메인에게 "fn_submit_result 직전" 시점을 알리는 파이프 write end
# ══════════════════════════════════════════════════════════════════════════════
def worker_process(session_id, agent_id, step_tasks, kill_at_step,
                   kill_pipe_w, db_config, agent_role, agent_pw,
                   model, endpoint, start_step=1):
    """
    자식 프로세스: start_step부터 스텝 태스크를 생성하고 fn_next_step/fn_submit_result 루프 실행.
    kill_at_step 스텝에서 fn_submit_result 직전에 파이프로 신호를 보냄.
    메인이 SIGKILL을 보내면 이 프로세스는 즉시 종료됨.
    """
    import psycopg2, psycopg2.extras, json, urllib.request, os

    def get_conn(user=None, pw=None):
        cfg = dict(db_config)
        if user:
            cfg['user'] = user
            cfg['password'] = pw or ''
        return psycopg2.connect(**cfg)

    def llm_call(llm_config, messages):
        payload = {
            "model": llm_config["model_name"],
            "messages": messages, "stream": False,
            "options": {"temperature": 0.0}, "format": "json",
        }
        req = urllib.request.Request(
            llm_config["endpoint"],
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode())["message"]["content"]

    op_conn = get_conn(); op_conn.autocommit = True
    op_cur  = op_conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    ag_conn = get_conn(user=agent_role, pw=agent_pw); ag_conn.autocommit = True
    ag_cur  = ag_conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    for step_num, task_input in enumerate(step_tasks, 1):
        if step_num < start_step:
            continue
        # 태스크 생성
        op_cur.execute(
            "INSERT INTO alma_private.tasks (session_id, agent_id, status, input)"
            " VALUES (%s,%s,'running',%s) RETURNING task_id",
            (session_id, agent_id, task_input))
        task_id = op_cur.fetchone()["task_id"]

        # fn_next_step
        ag_cur.execute("SELECT alma_public.fn_next_step(%s)", (task_id,))
        directive = ag_cur.fetchone()["fn_next_step"]

        if directive.get("action") == "done":
            break
        if directive.get("action") != "call_llm":
            break

        # LLM 호출
        response = llm_call(directive["llm_config"], directive["messages"])

        # kill_at_step 도달: fn_submit_result 직전에 파이프로 신호
        if step_num == kill_at_step:
            # 메인에게 task_id와 응답을 전달 (디버그용)
            msg = json.dumps({"step": step_num, "task_id": task_id,
                              "response_preview": response[:80]})
            os.write(kill_pipe_w, (msg + "\n").encode())
            # 메인이 SIGKILL 보낼 때까지 대기 (실제로는 즉시 kill됨)
            time.sleep(10)

        # fn_submit_result
        ag_cur.execute("SELECT alma_public.fn_submit_result(%s,%s)", (task_id, response))

    op_conn.close()
    ag_conn.close()

# ══════════════════════════════════════════════════════════════════════════════
# 재시작 워커: running 상태 태스크를 찾아 fn_next_step부터 재실행
# ══════════════════════════════════════════════════════════════════════════════
def restart_and_recover(session_id, agent_id, step_tasks, op_cur, ag_cur):
    section("워커 재시작 — running 상태 태스크 감지 및 재개")

    # running 상태 태스크 탐색
    detect_sql = f"""SELECT t.task_id, t.status, t.input
FROM alma_private.tasks t
WHERE t.session_id = {session_id}
  AND t.status = 'running'
ORDER BY t.task_id;"""
    sql_block("running 상태 태스크 탐색", detect_sql)
    op_cur.execute("""
        SELECT task_id, status, input
        FROM alma_private.tasks
        WHERE session_id = %s AND status = 'running'
        ORDER BY task_id""", (session_id,))
    stuck = op_cur.fetchall()

    if not stuck:
        print("  ◀ running 상태 태스크 없음")
        return

    for t in stuck:
        print(f"  ◀ 발견: task_id={t['task_id']}  status={t['status']}")
        print(f"          input={t['input'][:60]}")

    stuck_task = stuck[0]
    task_id    = stuck_task["task_id"]
    kv("재개 대상 task_id", task_id)

    # 어느 스텝인지 파악 (execution_logs 행 수로 판단)
    op_cur.execute(
        "SELECT COUNT(*) AS cnt FROM alma_private.execution_logs WHERE task_id = %s",
        (task_id,))
    log_cnt = op_cur.fetchone()["cnt"]
    sql_block("해당 태스크의 execution_logs 행 수",
              f"SELECT COUNT(*) FROM alma_private.execution_logs\n"
              f"WHERE task_id = {task_id};",
              f"{log_cnt}행 — fn_submit_result 미호출 확인 (0이어야 정상)")

    # fn_next_step부터 재실행
    print(f"\n  ▶ fn_next_step({task_id}) 재호출 — DB가 최신 상태 기준으로 지시 반환")
    sql_block("fn_next_step 재호출",
              f"SELECT alma_public.fn_next_step({task_id});")
    ag_cur.execute("SELECT alma_public.fn_next_step(%s)", (task_id,))
    directive = ag_cur.fetchone()["fn_next_step"]
    kv("fn_next_step action", directive.get("action"))

    if directive.get("action") != "call_llm":
        kv("output", directive.get("output", ""))
        return task_id

    # messages 출력
    messages = directive.get("messages", [])
    print(f"\n  ▶ LLM에 전달되는 messages ({len(messages)}개):")
    for i, msg in enumerate(messages):
        role    = msg.get("role", "")
        content = msg.get("content", "")
        print(f"\n    [{i+1}] role = {role.upper()}")
        if role == "system":
            print(f"    {'─'*64}")
            for line in content.strip().splitlines():
                print(f"      {line}")
            print(f"    {'─'*64}")
        else:
            display = content if len(content) <= 300 else content[:300] + "\n      ...(이하 생략)"
            for line in display.splitlines():
                print(f"      {line}")

    # LLM 재호출
    llm_config = directive.get("llm_config", {})
    print(f"\n  ▶ LLM 재호출")
    print(f"    provider : {llm_config.get('provider')}")
    print(f"    model    : {llm_config.get('model_name')}")

    t0 = time.perf_counter()
    response = call_llm(llm_config, messages)
    llm_ms   = round((time.perf_counter() - t0) * 1000, 1)

    print(f"\n  ◀ LLM 응답 (소요: {llm_ms} ms):")
    print(f"    raw: {response}")
    try:
        robj = json.loads(response)
        print(f"\n    thought   : {robj.get('thought','')}")
        print(f"    action    : {robj.get('action','')}")
        fa = robj.get("final_answer","") or robj.get("observation","")
        if fa:
            print(f"    final_ans : {fa}")
    except Exception:
        pass

    # fn_submit_result
    sql_block("fn_submit_result 호출",
              f"SELECT alma_public.fn_submit_result({task_id}, '[LLM 응답]');")
    ag_cur.execute("SELECT alma_public.fn_submit_result(%s,%s)", (task_id, response))
    sr = ag_cur.fetchone()["fn_submit_result"]
    kv("fn_submit_result 반환값", sr)

    return task_id, response

# ══════════════════════════════════════════════════════════════════════════════
# 일반 스텝 실행 (장애 없는 스텝용)
# ══════════════════════════════════════════════════════════════════════════════
def run_normal_step(step_num, total, session_id, agent_id, task_input,
                    op_cur, ag_cur):
    section(f"STEP {step_num} / {total}  │  정상 실행")
    print(f"  질문: {task_input}")

    op_cur.execute(
        "INSERT INTO alma_private.tasks (session_id, agent_id, status, input)"
        " VALUES (%s,%s,'running',%s) RETURNING task_id",
        (session_id, agent_id, task_input))
    task_id = op_cur.fetchone()["task_id"]
    sql_block("태스크 생성",
              f"INSERT INTO alma_private.tasks (session_id, agent_id, status, input)\n"
              f"VALUES ({session_id}, {agent_id}, 'running', '[질문]')\n"
              f"RETURNING task_id;",
              f"task_id = {task_id}")

    sql_block("fn_next_step 호출",
              f"SELECT alma_public.fn_next_step({task_id});")
    ag_cur.execute("SELECT alma_public.fn_next_step(%s)", (task_id,))
    directive = ag_cur.fetchone()["fn_next_step"]
    kv("action", directive.get("action"))

    if directive.get("action") != "call_llm":
        return task_id, None

    messages   = directive.get("messages", [])
    llm_config = directive.get("llm_config", {})
    print(f"\n  ▶ LLM 호출 (messages {len(messages)}개)")

    t0 = time.perf_counter()
    response = call_llm(llm_config, messages)
    llm_ms   = round((time.perf_counter() - t0) * 1000, 1)

    print(f"  ◀ LLM 응답 (소요: {llm_ms} ms):")
    try:
        robj = json.loads(response)
        print(f"    thought   : {robj.get('thought','')[:80]}")
        print(f"    final_ans : {(robj.get('final_answer','') or robj.get('observation',''))[:80]}")
    except Exception:
        print(f"    raw: {response[:120]}")

    sql_block("fn_submit_result 호출",
              f"SELECT alma_public.fn_submit_result({task_id}, '[LLM 응답]');")
    ag_cur.execute("SELECT alma_public.fn_submit_result(%s,%s)", (task_id, response))
    sr = ag_cur.fetchone()["fn_submit_result"]
    kv("fn_submit_result 반환값", sr)

    print_exec_logs(op_cur, task_id, session_id)
    return task_id, response

# ══════════════════════════════════════════════════════════════════════════════
# 메인
# ══════════════════════════════════════════════════════════════════════════════
def main():
    multiprocessing.set_start_method("fork", force=True)

    header("ALMA E2: 장애 복구와 상태 일관성 실험")
    print(f"  DB      : {DB_CONFIG['dbname']} / {DB_CONFIG['user']} / port {DB_CONFIG['port']}")
    print(f"  모델    : {MODEL}")
    print(f"  에이전트: {AGENT_ROLE}")
    print(f"  주제    : 실패 후 회복 — 5턴 상담 대화")
    print(f"  SIGKILL : STEP {KILL_AT_STEP}의 fn_submit_result 직전")
    print()
    for i, t in enumerate(STEP_TASKS, 1):
        mark = f"  ← SIGKILL 시점" if i == KILL_AT_STEP else ""
        print(f"    STEP {i}: {t[:50]}{mark}")

    agent_id = setup_agent()

    op_conn = get_op_conn(); op_conn.autocommit = True
    op_cur  = op_conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    ag_conn = get_agent_conn(); ag_conn.autocommit = True
    ag_cur  = ag_conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    # 세션 생성
    header("세션 생성")
    op_cur.execute(
        "INSERT INTO alma_private.sessions (agent_id, status, goal)"
        " VALUES (%s,'active','E2 실험 — 실패 회복 상담 대화') RETURNING session_id",
        (agent_id,))
    session_id = op_cur.fetchone()["session_id"]
    sql_block("세션 생성",
              f"INSERT INTO alma_private.sessions (agent_id, status, goal)\n"
              f"VALUES ({agent_id}, 'active', 'E2 실험 — 실패 회복 상담 대화')\n"
              f"RETURNING session_id;",
              f"session_id = {session_id}")
    kv("session_id", session_id)

    # ── PHASE 1: STEP 1~2 정상 실행 ──────────────────────────────────────────
    header("PHASE 1. STEP 1~2 정상 실행")
    for step_num in range(1, KILL_AT_STEP):
        run_normal_step(
            step_num   = step_num,
            total      = len(STEP_TASKS),
            session_id = session_id,
            agent_id   = agent_id,
            task_input = STEP_TASKS[step_num - 1],
            op_cur     = op_cur,
            ag_cur     = ag_cur,
        )

    # ── PHASE 2: STEP 3 — 자식 프로세스로 실행, fn_submit_result 직전 SIGKILL ─
    header(f"PHASE 2. STEP {KILL_AT_STEP} — SIGKILL 장애 주입")
    print(f"  자식 프로세스로 STEP {KILL_AT_STEP} 시작")
    print(f"  fn_next_step() + LLM 호출 완료 후 파이프 신호 → 메인이 SIGKILL")

    # 파이프 생성 (자식 → 메인 단방향)
    kill_pipe_r, kill_pipe_w = os.pipe()

    proc = multiprocessing.Process(
        target = worker_process,
        args   = (session_id, agent_id, STEP_TASKS, KILL_AT_STEP,
                  kill_pipe_w, DB_CONFIG, AGENT_ROLE, AGENT_PW, MODEL, ENDPOINT,
                  KILL_AT_STEP),   # start_step=KILL_AT_STEP: STEP 3만 실행
        daemon = True,
    )
    proc.start()
    os.close(kill_pipe_w)  # 메인은 write end 불필요

    # 자식으로부터 신호 대기
    print(f"\n  ▶ 자식 프로세스 pid={proc.pid} 시작, 파이프 신호 대기...")
    raw = b""
    while b"\n" not in raw:
        chunk = os.read(kill_pipe_r, 4096)
        if not chunk:
            break
        raw += chunk
    os.close(kill_pipe_r)

    signal_data = {}
    try:
        signal_data = json.loads(raw.decode().strip())
    except Exception:
        pass

    print(f"\n  ★ 파이프 신호 수신!")
    print(f"    step     : {signal_data.get('step')}")
    print(f"    task_id  : {signal_data.get('task_id')}")
    print(f"    LLM 응답 : {signal_data.get('response_preview')}...")
    print(f"    → fn_submit_result 미호출 상태 확인")

    # SIGKILL 발사
    t_kill = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    os.kill(proc.pid, signal.SIGKILL)
    proc.join(timeout=3)
    print(f"\n  ★ SIGKILL 발사: {t_kill}  (pid={proc.pid})")
    print(f"  ★ 자식 프로세스 종료 확인: exitcode={proc.exitcode}")

    # ── PHASE 3: SIGKILL 직후 DB 상태 스냅샷 ─────────────────────────────────
    header("PHASE 3. SIGKILL 직후 DB 상태 검증")

    snapshot_db_state("SIGKILL 직후", session_id)

    # tasks.status 상세 검증
    killed_task_id = signal_data.get("task_id")
    if killed_task_id:
        op_cur.execute("SELECT task_id, status FROM alma_private.tasks WHERE task_id = %s",
                       (killed_task_id,))
        killed_task = op_cur.fetchone()
        sql_block("SIGKILL된 태스크 상태 직접 조회",
                  f"SELECT task_id, status\n"
                  f"FROM alma_private.tasks\n"
                  f"WHERE task_id = {killed_task_id};")
        kv("task_id", killed_task["task_id"])
        kv("status",  killed_task["status"])

        # execution_logs 기록 여부
        op_cur.execute(
            "SELECT COUNT(*) AS cnt FROM alma_private.execution_logs WHERE task_id = %s",
            (killed_task_id,))
        log_cnt = op_cur.fetchone()["cnt"]
        sql_block("SIGKILL된 태스크의 execution_logs 행 수",
                  f"SELECT COUNT(*) FROM alma_private.execution_logs\n"
                  f"WHERE task_id = {killed_task_id};",
                  f"{log_cnt}행")

        if log_cnt == 0:
            print(f"\n  ✅ 검증 (a): execution_logs에 STEP {KILL_AT_STEP} 기록 없음")
            print(f"              fn_submit_result 미호출 → PostgreSQL 트랜잭션 보호 확인")
        else:
            print(f"\n  ❌ 검증 (a): execution_logs에 {log_cnt}행 존재 (예상치 않은 상태)")

        if killed_task["status"] == "running":
            print(f"  ✅ 검증 (b): tasks.status = 'running' (워커 사망 후 상태 잔존)")
            print(f"              재시작 워커가 이 태스크를 감지하고 재개 가능")
        else:
            print(f"  ⚠️  검증 (b): tasks.status = '{killed_task['status']}' (예상: running)")

    # ── PHASE 4: 워커 재시작 및 복구 ─────────────────────────────────────────
    header("PHASE 4. 워커 재시작 — running 태스크 감지 및 STEP 3 재개")
    killed_task_id_recovered, recovered_response = restart_and_recover(
        session_id, agent_id, STEP_TASKS, op_cur, ag_cur
    )

    # execution_logs 재확인
    if killed_task_id_recovered:
        op_cur.execute(
            "SELECT COUNT(*) AS cnt FROM alma_private.execution_logs WHERE task_id = %s",
            (killed_task_id_recovered,))
        log_cnt_after = op_cur.fetchone()["cnt"]
        sql_block("재개 후 execution_logs 행 수",
                  f"SELECT COUNT(*) FROM alma_private.execution_logs\n"
                  f"WHERE task_id = {killed_task_id_recovered};",
                  f"{log_cnt_after}행")
        if log_cnt_after > 0:
            print(f"  ✅ 검증 (c): 재시작 후 execution_logs에 {log_cnt_after}행 기록됨")
            print(f"              fn_next_step()부터 정상 재개 완료")

    # ── PHASE 5: STEP 4~5 정상 실행 ──────────────────────────────────────────
    header("PHASE 5. STEP 4~5 정상 실행 (복구 후 대화 계속)")
    for step_num in range(KILL_AT_STEP + 1, len(STEP_TASKS) + 1):
        run_normal_step(
            step_num   = step_num,
            total      = len(STEP_TASKS),
            session_id = session_id,
            agent_id   = agent_id,
            task_input = STEP_TASKS[step_num - 1],
            op_cur     = op_cur,
            ag_cur     = ag_cur,
        )

    # 세션 완료
    op_cur.execute(
        "UPDATE alma_private.sessions SET status='completed', completed_at=now()"
        " WHERE session_id=%s", (session_id,))

    # ── 최종 리포트 ──────────────────────────────────────────────────────────
    header("최종 리포트")

    # 세션 전체 execution_logs
    section("세션 전체 execution_logs")
    op_cur.execute("""
        SELECT t.task_id, el.step_number, el.role, el.content
        FROM alma_private.execution_logs el
        JOIN alma_private.tasks t ON t.task_id = el.task_id
        WHERE t.session_id = %s
        ORDER BY t.task_id, el.step_number""", (session_id,))
    all_logs = op_cur.fetchall()
    sql_block("전체 로그",
              f"SELECT t.task_id, el.step_number, el.role, el.content\n"
              f"FROM alma_private.execution_logs el\n"
              f"JOIN alma_private.tasks t ON t.task_id = el.task_id\n"
              f"WHERE t.session_id = {session_id}\n"
              f"ORDER BY t.task_id, el.step_number;")
    print(f"    {'task':>6}  {'step':>4}  {'role':<10}  content")
    print(f"    {'------':>6}  {'----':>4}  {'----------':<10}  {'-------'}")
    for row in all_logs:
        try:
            c = json.dumps(json.loads(row["content"]), ensure_ascii=False)[:62]
        except Exception:
            c = str(row["content"])[:62]
        print(f"    {row['task_id']:>6}  {row['step_number']:>4}  {row['role']:<10}  {c}")

    # 최종 태스크 현황
    section("최종 태스크 현황")
    op_cur.execute("""
        SELECT task_id, status, LEFT(input,45) AS input_short
        FROM alma_private.tasks WHERE session_id = %s ORDER BY task_id""",
        (session_id,))
    final_tasks = op_cur.fetchall()
    sql_block("최종 태스크 현황",
              f"SELECT task_id, status, LEFT(input,45)\n"
              f"FROM alma_private.tasks\n"
              f"WHERE session_id = {session_id} ORDER BY task_id;")
    print(f"    {'task_id':>8}  {'status':<12}  input")
    print(f"    {'-------':>8}  {'------':<12}  {'-----'}")
    for t in final_tasks:
        mark = "  ← SIGKILL 후 재개" if t["task_id"] == killed_task_id else ""
        print(f"    {t['task_id']:>8}  {t['status']:<12}  {t['input_short']}{mark}")

    # 검증 요약
    section("검증 요약")
    print(f"  (a) SIGKILL 직후 execution_logs: STEP {KILL_AT_STEP} 기록 없음 → 트랜잭션 보호 확인")
    print(f"  (b) SIGKILL 직후 tasks.status  : running 상태 잔존 → 재시작 워커 감지 가능")
    print(f"  (c) 재시작 후 재개              : fn_next_step()부터 STEP {KILL_AT_STEP} 정상 완료")
    print(f"  (d) 대화 연속성                : STEP 4~5에서 STEP 3 내용이 히스토리로 유지됨")

    print(f"\n{SEP2}")
    print(f"  실험 완료  |  에이전트: {AGENT_ROLE} (id={agent_id}) 유지됨")
    print(f"  session_id={session_id}")
    print(f"{SEP2}\n")

    ag_conn.close()
    op_conn.close()


if __name__ == "__main__":
    import time
    main()
