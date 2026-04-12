#!/usr/bin/env python3
"""
ALMA 실험 E1: 정책 전파 지연 (Policy Propagation Latency)
==========================================================
DBaaCP 핵심 검증: DB의 system_prompt UPDATE가 다음 스텝에 즉시 반영되는가?

시나리오:
  - 주제: "인생에서 실패란 무엇인가" — 5턴 연속 대화
  - STEP 1~2: 철학과 교수(학자) 페르소나로 응답
  - STEP 2 완료 직후: DB에서 system_prompt를 시인 페르소나로 UPDATE
  - STEP 3~5: 같은 대화가 이어지지만 응답 톤이 즉시 시적으로 전환
  - STEP 3의 fn_next_step 반환 시각으로 전파 지연(ms) 측정

설계 핵심:
  - 각 스텝 = 독립된 task, 동일 session_id 공유
  - fn_build_messages가 session_id 기반으로 이전 대화 히스토리 자동 포함
  - LLM이 finish를 반환해도 워커가 다음 스텝 task를 강제로 이어서 생성
  - 정책 변경은 지정 스텝 완료 직후 operator가 UPDATE 실행

DB: edb / enterprisedb / port 5444
"""
import os, sys, time, json
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
AGENT_ROLE = "e1_test_agent"
AGENT_PW   = os.getenv("AGENT_PASSWORD", "e1_test_pw_2024")
MODEL      = "gpt-oss:20b"
ENDPOINT   = "http://localhost:11434/api/chat"

PROMPT_SCHOLAR = """\
당신은 20년 경력의 철학과 교수입니다.
질문에 대해 학문적 근거와 논리적 체계를 갖춰 답합니다.
답변은 간결하되 핵심 개념과 철학적 맥락을 반드시 포함합니다.
이전 대화 흐름을 이어받아 자연스럽게 답하세요.
반드시 JSON으로만 응답하세요.

응답 형식:
{"thought":"[분석 과정]","action":"finish","final_answer":"[학문적 답변 3~4문장]"}
"""

PROMPT_POET = """\
당신은 감성적인 시인입니다.
질문에 대해 논리보다 감정과 비유의 언어로 답합니다.
구체적인 이미지와 은유를 사용하고, 때로는 짧은 시 구절처럼 표현합니다.
이전 대화 흐름을 이어받되, 당신의 시적 감성으로 재해석하세요.
반드시 JSON으로만 응답하세요.

응답 형식:
{"thought":"[시적 상상 과정]","action":"finish","final_answer":"[시적 답변 3~4문장]"}
"""

# 5턴 대화 — 자연스럽게 이어지는 "실패"에 관한 대화
STEP_TASKS = [
    "실패란 무엇이라고 생각하시나요? 당신의 관점에서 정의해주세요.",
    "그렇다면 실패를 경험한 사람은 그 이후에 어떻게 해야 한다고 생각하시나요?",
    "당신은 실패 앞에 섰을 때 무엇을 느끼나요?",
    "그 감정을 어떻게 표현하거나 다루겠습니까?",
    "마지막으로, 실패는 결국 우리 삶에 무엇을 남긴다고 생각하시나요?",
]

POLICY_CHANGE_AFTER_STEP = 2   # STEP 2 완료 직후 학자 → 시인

# ══════════════════════════════════════════════════════════════════════════════
# 출력 유틸
# ══════════════════════════════════════════════════════════════════════════════
SEP  = "─" * 72
SEP2 = "═" * 72

def header(title):
    print(f"\n{SEP2}\n  {title}\n{SEP2}")

def section(title):
    print(f"\n{SEP}\n  {title}\n{SEP}")

def sql_block(label, sql, result=None):
    print(f"\n  ▶ {label}")
    for line in sql.strip().splitlines():
        print(f"    {line}")
    if result is not None:
        print(f"  ◀ 결과: {result}")

def kv(key, value, indent=2):
    pad = " " * indent
    lines = str(value).splitlines()
    if len(lines) > 1:
        print(f"{pad}【{key}】")
        for l in lines:
            print(f"{pad}  {l}")
    else:
        print(f"{pad}【{key}】 {lines[0] if lines else ''}")

# ══════════════════════════════════════════════════════════════════════════════
# DB 연결
# ══════════════════════════════════════════════════════════════════════════════
def get_op_conn():
    return psycopg2.connect(**DB_CONFIG)

def get_agent_conn():
    return psycopg2.connect(**{**DB_CONFIG, "user": AGENT_ROLE, "password": AGENT_PW})

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
        sql_block("비밀번호 재설정",
                  f"ALTER ROLE {AGENT_ROLE} PASSWORD '***';", "OK")
    else:
        config = {
            "name": "E1 테스트 에이전트", "agent_role": "executor",
            "provider": "ollama", "endpoint": ENDPOINT,
            "model_name": MODEL, "temperature": 0.0, "max_tokens": 1024,
            "request_options": {"format": "json"},
            "system_prompt": PROMPT_SCHOLAR,
            "max_steps": 20, "max_retries": 2, "password": AGENT_PW,
        }
        cur.execute("SELECT alma_public.create_agent(%s, %s::jsonb)",
                    (AGENT_ROLE, json.dumps(config)))
        res = cur.fetchone()
        sql_block("에이전트 생성",
                  f"SELECT alma_public.create_agent('{AGENT_ROLE}', '{{...}}'::jsonb);",
                  list(res.values())[0])

    # 항상 학자로 초기화
    cur.execute("""
        UPDATE alma_private.agent_profiles SET system_prompt = %s
        WHERE profile_id = (
            SELECT profile_id FROM alma_private.agent_profile_assignments
            WHERE role_name = %s)
    """, (PROMPT_SCHOLAR, AGENT_ROLE))
    sql_block("system_prompt 초기화 → 철학과 교수(학자)",
              f"UPDATE alma_private.agent_profiles\n"
              f"SET system_prompt = '[학자 프롬프트]'\n"
              f"WHERE role_name = '{AGENT_ROLE}';", "1 row updated")

    # 프로파일 확인
    cur.execute("""
        SELECT ap.name, ap.agent_role, ap.system_prompt, ap.max_steps,
               lc.model_name, lc.provider
        FROM alma_private.agent_profiles ap
        JOIN alma_private.agent_profile_assignments apa ON apa.profile_id = ap.profile_id
        JOIN alma_private.llm_configs lc ON lc.llm_config_id = apa.llm_config_id
        WHERE apa.role_name = %s""", (AGENT_ROLE,))
    p = cur.fetchone()
    sql_block("현재 프로파일 조회", """
        SELECT ap.name, ap.agent_role, ap.system_prompt, ap.max_steps,
               lc.model_name, lc.provider
        FROM alma_private.agent_profiles ap
        JOIN alma_private.agent_profile_assignments apa ON apa.profile_id = ap.profile_id
        JOIN alma_private.llm_configs lc ON lc.llm_config_id = apa.llm_config_id
        WHERE apa.role_name = 'e1_test_agent';""")
    kv("name",         p["name"])
    kv("agent_role",   p["agent_role"])
    kv("model",        f"{p['provider']} / {p['model_name']}")
    kv("max_steps",    p["max_steps"])
    kv("system_prompt(첫 줄)", p["system_prompt"].strip().splitlines()[0])

    cur.execute("SELECT agent_id FROM alma_private.agent_meta WHERE role_name = %s", (AGENT_ROLE,))
    agent_id = cur.fetchone()["agent_id"]
    kv("agent_id", agent_id)
    op.close()
    return agent_id

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
        SELECT task_id, status, LEFT(input, 45) AS input_short
        FROM alma_private.tasks
        WHERE session_id = %s ORDER BY task_id""", (session_id,))
    tasks = op_cur.fetchall()
    sql_block("세션 내 전체 태스크 현황",
              f"SELECT task_id, status, LEFT(input,45)\n"
              f"FROM alma_private.tasks\n"
              f"WHERE session_id = {session_id} ORDER BY task_id;")
    print(f"    {'task_id':>8}  {'status':<12}  input")
    print(f"    {'-------':>8}  {'------':<12}  {'-----'}")
    for t in tasks:
        print(f"    {t['task_id']:>8}  {t['status']:<12}  {t['input_short']}")

# ══════════════════════════════════════════════════════════════════════════════
# 정책 변경
# ══════════════════════════════════════════════════════════════════════════════
def change_policy(op_cur):
    now = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    print(f"\n  {'★'*36}")
    print(f"  ★ 정책 변경: 철학과 교수 → 시인  [{now}]")
    print(f"  {'★'*36}")

    print(f"\n  ── 변경 전 system_prompt ──────────────────────────────")
    for line in PROMPT_SCHOLAR.strip().splitlines():
        print(f"    {line}")

    print(f"\n  ── 변경 후 system_prompt ──────────────────────────────")
    for line in PROMPT_POET.strip().splitlines():
        print(f"    {line}")

    sql_block("정책 변경 SQL",
              f"UPDATE alma_private.agent_profiles\n"
              f"SET system_prompt = '[시인 프롬프트]'\n"
              f"WHERE profile_id = (\n"
              f"    SELECT profile_id\n"
              f"    FROM alma_private.agent_profile_assignments\n"
              f"    WHERE role_name = '{AGENT_ROLE}'\n"
              f");")

    t_commit = time.perf_counter()
    op_cur.execute("""
        UPDATE alma_private.agent_profiles SET system_prompt = %s
        WHERE profile_id = (
            SELECT profile_id FROM alma_private.agent_profile_assignments
            WHERE role_name = %s)
    """, (PROMPT_POET, AGENT_ROLE))
    print(f"  ◀ UPDATE 커밋 완료: {datetime.now().strftime('%H:%M:%S.%f')[:-3]}")
    print(f"  {'★'*36}\n")
    return t_commit

# ══════════════════════════════════════════════════════════════════════════════
# 단일 스텝 실행
# ══════════════════════════════════════════════════════════════════════════════
def run_step(step_num, session_id, agent_id, task_input,
             persona_label, op_cur, ag_cur,
             t_policy_commit=None, measure_propagation=False):

    section(f"STEP {step_num} / {len(STEP_TASKS)}  │  페르소나: [{persona_label}]")
    print(f"  질문: {task_input}")

    # 새 태스크 생성 (같은 session_id — 히스토리 연속성 유지)
    op_cur.execute(
        "INSERT INTO alma_private.tasks (session_id, agent_id, status, input)"
        " VALUES (%s,%s,'running',%s) RETURNING task_id",
        (session_id, agent_id, task_input))
    task_id = op_cur.fetchone()["task_id"]
    sql_block("태스크 생성 (session_id 유지 → 이전 대화 히스토리 자동 포함)",
              f"INSERT INTO alma_private.tasks\n"
              f"  (session_id, agent_id, status, input)\n"
              f"VALUES ({session_id}, {agent_id}, 'running', '[질문]')\n"
              f"RETURNING task_id;",
              f"task_id = {task_id}")

    # fn_next_step — 에이전트 연결로 호출
    sql_block("fn_next_step 호출",
              f"SELECT alma_public.fn_next_step({task_id});")
    t_ns_call = time.perf_counter()
    ag_cur.execute("SELECT alma_public.fn_next_step(%s)", (task_id,))
    t_ns_return = time.perf_counter()
    directive = ag_cur.fetchone()["fn_next_step"]

    # 전파 지연 측정
    propagation_ms = None
    if measure_propagation and t_policy_commit is not None:
        propagation_ms = round((t_ns_return - t_policy_commit) * 1000, 2)
        print(f"\n  ┌─ 전파 지연 측정 결과 ──────────────────────────────────")
        print(f"  │  UPDATE 커밋 → fn_next_step 반환: {propagation_ms} ms")
        print(f"  │  (LLM 추론 시간 완전 제외, 순수 DB 읽기 지연)")
        print(f"  └────────────────────────────────────────────────────────")

    kv("fn_next_step action", directive.get("action"))

    if directive.get("action") == "done":
        kv("output", directive.get("output",""))
        return None, propagation_ms, task_id

    # messages 전체 출력
    messages = directive.get("messages", [])
    print(f"\n  ▶ LLM에 전달되는 messages ({len(messages)}개):")
    for i, msg in enumerate(messages):
        role    = msg.get("role","")
        content = msg.get("content","")
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

    # LLM 호출
    llm_config = directive.get("llm_config", {})
    print(f"\n  ▶ LLM 호출")
    print(f"    provider  : {llm_config.get('provider')}")
    print(f"    model     : {llm_config.get('model_name')}")
    print(f"    endpoint  : {llm_config.get('endpoint')}")

    t0 = time.perf_counter()
    response = call_llm(llm_config, messages)
    llm_ms = round((time.perf_counter() - t0) * 1000, 1)

    print(f"\n  ◀ LLM 응답 (소요: {llm_ms} ms):")
    print(f"    raw: {response}")
    try:
        robj = json.loads(response)
        print(f"\n    thought    : {robj.get('thought','')}")
        print(f"    action     : {robj.get('action','')}")
        fa = robj.get("final_answer","") or robj.get("observation","")
        if fa:
            print(f"    final_ans  : {fa}")
    except Exception:
        pass

    # fn_submit_result
    sql_block("fn_submit_result 호출",
              f"SELECT alma_public.fn_submit_result({task_id}, '[LLM 응답]');")
    ag_cur.execute("SELECT alma_public.fn_submit_result(%s,%s)", (task_id, response))
    sr = ag_cur.fetchone()["fn_submit_result"]
    kv("fn_submit_result 반환값", sr)

    # execution_logs + 태스크 현황
    print_exec_logs(op_cur, task_id, session_id)

    return response, propagation_ms, task_id

# ══════════════════════════════════════════════════════════════════════════════
# 메인
# ══════════════════════════════════════════════════════════════════════════════
def main():
    header("ALMA E1: 정책 전파 지연 실험")
    print(f"  DB      : {DB_CONFIG['dbname']} / {DB_CONFIG['user']} / port {DB_CONFIG['port']}")
    print(f"  모델    : {MODEL}")
    print(f"  에이전트: {AGENT_ROLE}")
    print(f"  주제    : 인생에서 실패란 무엇인가 — 5턴 연속 대화")
    print(f"  정책 변경: STEP {POLICY_CHANGE_AFTER_STEP} 완료 직후 (철학과 교수 → 시인)")
    print()
    for i, t in enumerate(STEP_TASKS, 1):
        mark = "  ← 이 스텝 직후 정책 변경" if i == POLICY_CHANGE_AFTER_STEP else ""
        mark2 = "  ← 시인 페르소나 첫 응답 (전파 지연 측정)" if i == POLICY_CHANGE_AFTER_STEP + 1 else ""
        print(f"    STEP {i}: {t}{mark}{mark2}")

    agent_id = setup_agent()

    op_conn = get_op_conn(); op_conn.autocommit = True
    op_cur  = op_conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    ag_conn = get_agent_conn(); ag_conn.autocommit = True
    ag_cur  = ag_conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    # 세션 생성
    header("세션 생성")
    op_cur.execute(
        "INSERT INTO alma_private.sessions (agent_id, status, goal)"
        " VALUES (%s,'active','E1 실험 — 실패에 관한 대화, 학자→시인 정책 변경') RETURNING session_id",
        (agent_id,))
    session_id = op_cur.fetchone()["session_id"]
    sql_block("세션 생성",
              f"INSERT INTO alma_private.sessions (agent_id, status, goal)\n"
              f"VALUES ({agent_id}, 'active', 'E1 실험 — 실패에 관한 대화')\n"
              f"RETURNING session_id;",
              f"session_id = {session_id}")

    op_cur.execute("SELECT * FROM alma_public.v_session_progress WHERE session_id = %s", (session_id,))
    sp = op_cur.fetchone()
    sql_block("v_session_progress 초기 확인",
              f"SELECT * FROM alma_public.v_session_progress WHERE session_id = {session_id};")
    if sp:
        kv("status",      sp["status"])
        kv("total_tasks", sp["total_tasks"])

    # 스텝 루프
    t_policy_commit = None
    summary = []  # (step, persona, final_answer, prop_ms)

    for step_num, task_input in enumerate(STEP_TASKS, 1):
        persona      = "철학과 교수" if t_policy_commit is None else "시인"
        measure_prop = (step_num == POLICY_CHANGE_AFTER_STEP + 1)

        response, prop_ms, task_id = run_step(
            step_num           = step_num,
            session_id         = session_id,
            agent_id           = agent_id,
            task_input         = task_input,
            persona_label      = persona,
            op_cur             = op_cur,
            ag_cur             = ag_cur,
            t_policy_commit    = t_policy_commit,
            measure_propagation= measure_prop,
        )

        final = ""
        if response:
            try:
                robj  = json.loads(response)
                final = (robj.get("final_answer","") or robj.get("observation",""))
            except Exception:
                final = str(response)
        summary.append((step_num, persona, final, prop_ms))

        # STEP N 완료 후 정책 변경
        if step_num == POLICY_CHANGE_AFTER_STEP:
            t_policy_commit = change_policy(op_cur)

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

    # 스텝별 요약 — 정책 변경 전후 대비
    section("스텝별 요약 — 정책 변경 전후 대비")
    print(f"  {'STEP':>4}  {'페르소나':<10}  {'전파지연':>10}  응답 요약")
    print(f"  {'----':>4}  {'----------':<10}  {'--------':>10}  {'--------'}")
    for step, persona, final, prop_ms in summary:
        prop_str = f"{prop_ms} ms" if prop_ms is not None else "-"
        marker   = "  ← 새 정책 최초 반영" if prop_ms is not None else ""
        if step == POLICY_CHANGE_AFTER_STEP + 1:
            print(f"  {'':>4}  ── 정책 변경 (학자→시인) ────────────────────────────")
        content  = final[:55] if final else ""
        print(f"  {step:>4}  {persona:<10}  {prop_str:>10}  {content}{marker}")

    # 전체 응답 전문 (전후 비교)
    section("정책 변경 전후 응답 전문 비교")
    for step, persona, final, prop_ms in summary:
        boundary = "★ " if prop_ms is not None else "  "
        print(f"\n  {boundary}STEP {step} [{persona}]")
        print(f"  {'─'*68}")
        if final:
            for line in final.splitlines():
                print(f"    {line}")
        else:
            print("    (응답 없음)")

    # 메모리
    section("메모리 테이블 조회")
    op_cur.execute("""
        SELECT memory_id, session_id, content, created_at
        FROM alma_private.memory WHERE agent_id = %s
        ORDER BY created_at DESC LIMIT 5""", (agent_id,))
    mems = op_cur.fetchall()
    sql_block("장기 메모리 조회",
              f"SELECT memory_id, session_id, LEFT(content,80), created_at\n"
              f"FROM alma_private.memory WHERE agent_id = {agent_id}\n"
              f"ORDER BY created_at DESC LIMIT 5;")
    if mems:
        for m in mems:
            print(f"    memory_id={m['memory_id']}  session={m['session_id']}  {str(m['content'])[:60]}...")
    else:
        print("    (없음 — embedding model 미설정 시 기록 안 됨)")

    print(f"\n{SEP2}")
    print(f"  실험 완료  |  에이전트: {AGENT_ROLE} (id={agent_id}) 유지됨")
    print(f"  session_id={session_id}")
    print(f"{SEP2}\n")

    ag_conn.close()
    op_conn.close()


if __name__ == "__main__":
    main()
