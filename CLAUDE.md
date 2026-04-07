# ALMA — Agent Lifecycle Manager
## Claude.md — 프로젝트 설계 가이드

---

## 프로젝트 개요

ALMA는 PostgreSQL Extension으로 구현된 RDBMS 기반 AI 에이전트 라이프사이클 관리 프레임워크다.

**핵심 목표:**
- DB에 접속하는 순간 에이전트를 바로 사용할 수 있어야 한다
- 에이전트 생성, 실행, 조회 전부 SQL 한 줄로 가능해야 한다
- Python은 DB에 접속하는 수단 중 하나일 뿐이다. psql로도 동일하게 동작해야 한다

---

## 핵심 설계 철학

### 1. 모든 것은 DB에 있다
- LLM은 상태를 가지지 않는다. DB가 상태를 소유한다
- 에이전트의 모든 동작 (LLM 호출, 툴 실행, 결과 기록) 은 DB 함수 안에서 실행된다
- Python 클라이언트는 `run_agent()` 를 호출하는 것이 전부다

### 2. 에이전트는 PostgreSQL Role이다
- 에이전트 = DB Role. 접속 계정 자체가 에이전트 식별자다
- Role로 접속하면 자신에게 허용된 것만 볼 수 있다 (뷰 마스킹)
- 새 에이전트 추가 = `create_agent()` 호출만. 코드 수정/재배포 없음

### 3. tasks 테이블이 메시지 큐다
- 에이전트 간 통신 = tasks 테이블 INSERT/SELECT
- pg_notify가 실시간 알림을 담당한다
- 별도 메시지 큐 (RabbitMQ, Kafka 등) 불필요

### 4. 트랜잭션이 일관성을 보장한다
- 모든 상태 변경은 PostgreSQL 트랜잭션으로 보장된다
- 실행 결과 기록 + 다음 태스크 생성이 하나의 트랜잭션으로 처리된다
- 장애 발생 시 WAL로 자동 복구된다

### 5. SECURITY DEFINER 함수 주의사항
- `SECURITY DEFINER` 함수 안에서 `current_user` = 함수 소유자 (enterprisedb)
- 에이전트 식별은 반드시 `session_user` 사용
- 파라미터 타입: `alma_private` ENUM을 직접 참조하면 에이전트가 접근 불가
  → 함수 파라미터는 TEXT로 받고 내부에서 ENUM 캐스팅

---

## 스키마 구조

### alma_private (테이블 — operator만 직접 접근)
```
llm_configs              LLM 모델 설정 (정규화 분리)
agent_profiles           에이전트 동작 프로필 (SOUL.md 역할)
agent_profile_assignments Role ↔ 프로필 매핑
agent_meta               에이전트 정체성 (role_name = PostgreSQL Role)
sessions                 실행 단위
tasks                    태스크 큐 (에이전트 간 메시지 큐 역할)
execution_logs           매 스텝 실행 이력 (DB가 상태 소유의 증거)
memory                   에이전트 기억 (pgvector RAG)
task_dependencies        태스크 실행 순서 정의
agent_messages           에이전트 간 메시지 이력 (감사용)
human_interventions      인간 개입 이력 (감사용)
experiments              비교 실험 설정
experiment_results       비교 실험 결과
```

### alma_public (뷰 + 함수 — 인터페이스)
```
create_agent()           에이전트 생성 (Role + 메타정보 한번에)
drop_agent()             에이전트 삭제/비활성화
list_agents()            에이전트 목록
run_agent()              단일 에이전트 실행
run_multi_agent()        멀티 에이전트 실행 (orchestrator 조율)
list_sessions()          세션 이력
get_session()            세션 상세 감사 로그
v_agent_context          에이전트 컨텍스트 뷰 (한 번에 읽기)
v_my_tasks               내 태스크 목록 (tasks 큐에서 필터링)
v_my_memory              내 기억 목록
v_session_progress       세션 진행 상황
v_session_audit          전체 작업 이력 (operator 전용)
```

---

## Role 계층

```
alma_operator               인간 운영자 (alma_private 전체 접근)
└── alma_agent_base         에이전트 베이스 (alma_public만 접근)
    ├── agent_sql           SQL 분석 에이전트
    ├── agent_orchestrator  오케스트레이터
    └── agent_evaluator     평가 에이전트
```

---

## 파일 구조

```
alma/
├── alma.control               Extension 메타 (vector, plpython3u 의존)
├── Makefile                   빌드/설치
├── README.md                  사용 가이드
├── CLAUDE.md                  이 파일 (설계 가이드)
├── requirements.txt           psycopg2-binary
├── alma_agent.py              Python 클라이언트 (run_agent 호출만)
└── sql/
    ├── alma--1.0.sql          설치용 합본 (make build로 자동 생성)
    ├── 01_schemas.sql         alma_private / alma_public 스키마
    ├── 02_roles.sql           alma_operator / alma_agent_base Role
    ├── 03_types.sql           ENUM 타입 정의
    ├── 04_tables.sql          테이블 전체
    ├── 05_views.sql           뷰 전체 (에이전트 접근 인터페이스)
    ├── 06_functions_core.sql  세션/태스크/메모리 관리 함수
    ├── 07_functions_llm.sql   LLM HTTP 호출 (plpython3u)
    ├── 08_functions_agent.sql run_agent / run_multi_agent
    ├── 09_functions_mgmt.sql  create/drop/list_agents
    ├── 10_grants.sql          권한 부여
    ├── 11_indexes.sql         인덱스 (pgvector IVFFlat)
    └── 12_triggers.sql        자동 압축 + 완료 알림 트리거
```

---

## LLM 연동 방식

### fn_call_llm (07_functions_llm.sql)
- plpython3u로 구현된 HTTP 호출 함수
- `agent_id`로 `llm_configs`에서 설정을 읽어서 동적 라우팅
- provider별 요청 구성 (anthropic / openai / ollama / custom)
- API 키는 환경변수에서 읽음 (`api_key_ref` 컬럼은 환경변수명만 저장)
- `request_options` JSONB로 provider별 추가 옵션 지정 가능
  (Ollama: `{"format": "json"}` 으로 JSON 응답 강제)

### 모델 교체
```sql
UPDATE alma_private.llm_configs
SET provider = 'anthropic',
    endpoint = 'https://api.anthropic.com/v1/messages',
    model_name = 'claude-sonnet-4-6',
    api_key_ref = 'ANTHROPIC_API_KEY'
WHERE llm_config_id = $id;
```
코드 수정 없이 DB UPDATE만으로 모델 교체 가능

---

## 에이전트 실행 흐름

### 단일 에이전트 (run_agent)
```
run_agent('agent_sql', '태스크')
    → agent_meta에서 에이전트 정보 조회
    → sessions INSERT
    → tasks INSERT (status = running)
    → LOOP:
        fn_call_llm() → LLM HTTP 호출
        action = execute_sql → SQL 실행 후 결과를 다음 메시지로
        action = finish → execution_logs 기록 → memory 저장 → 세션 완료
    → 최종 답변 반환
```

### 멀티 에이전트 (run_multi_agent)
```
run_multi_agent('agent_orchestrator', '전체 목표')
    → orchestrator LLM 호출
    → action = delegate:
        run_agent('agent_sql', '서브 태스크') 호출
        agent_messages에 지시/결과 기록
        서브 결과를 orchestrator 컨텍스트에 추가
    → action = finish → 최종 답변 반환
```

### orchestrator 시스템 프롬프트 예시
```json
{
    "thought": "매출 데이터 조회가 필요하다",
    "action": "delegate",
    "agent_role": "agent_sql",
    "task": "SELECT * FROM sales WHERE date >= '2024-01-01'"
}
```
```json
{
    "thought": "모든 분석이 완료됐다",
    "action": "finish",
    "final_answer": "2024년 매출은 총 1억원입니다"
}
```

---

## 에이전트 생성 가이드

```sql
SELECT alma_public.create_agent(
    p_role_name     := 'agent_sql',
    p_name          := 'SQL 분석 에이전트',
    p_agent_role    := 'executor',        -- orchestrator / executor / evaluator
    p_provider      := 'ollama',          -- anthropic / openai / ollama / custom
    p_endpoint      := 'http://localhost:11434/api/chat',
    p_model_name    := 'gpt-oss:20b',
    p_api_key_ref   := NULL,              -- 환경변수명 (Ollama는 불필요)
    p_temperature   := 0.0,
    p_max_tokens    := 2048,
    p_request_opts  := '{"format": "json"}',
    p_system_prompt := '당신은 PostgreSQL 전문가입니다...',
    p_max_steps     := 10,
    p_max_retries   := 3
);
```

`create_agent()`가 내부적으로 처리하는 것:
1. `CREATE ROLE p_role_name LOGIN`
2. `GRANT alma_agent_base TO p_role_name`
3. `GRANT USAGE ON SCHEMA alma_public TO p_role_name`
4. `GRANT EXECUTE ON FUNCTION run_agent TO p_role_name`
5. llm_configs INSERT
6. agent_profiles INSERT
7. agent_profile_assignments INSERT
8. agent_meta INSERT

---

## 비교 실험 설계

ALMA vs LangGraph vs OpenClaw 비교를 위한 실험 테이블:

```sql
-- 실험 등록
INSERT INTO alma_private.experiments (name, task_prompt)
VALUES ('SQL 분석 태스크 비교', 'show me all tables in this database');

-- ALMA 실행 결과 기록
INSERT INTO alma_private.experiment_results (
    experiment_id, framework, session_id,
    is_success, total_steps, duration_ms, reasoning_score
) VALUES ($exp_id, 'alma', $session_id, TRUE, 3, 5200, 0.95);

-- 비교 결과 조회
SELECT framework, AVG(reasoning_score), AVG(total_steps), AVG(duration_ms)
FROM alma_private.experiment_results
WHERE experiment_id = $exp_id
GROUP BY framework;
```

---

## 주의사항 및 제약

### 보안
- API 키는 DB에 저장하지 않는다. `api_key_ref`는 환경변수 참조명만 저장
- 에이전트는 `alma_private` 직접 접근 불가. 뷰와 함수만 사용
- `fn_execute_sql`은 SELECT만 허용. INSERT/UPDATE/DELETE/DROP 차단

### 성능
- pgvector 인덱스: Docker 환경은 IVFFlat, 운영 환경은 HNSW 권장
- Docker shm 크기: `mount -o remount,size=1G /dev/shm`

### ENUM 타입
- 함수 파라미터에서 `alma_private.*` ENUM 직접 참조 금지
- TEXT로 받아서 함수 내부에서 캐스팅 (`p_status::alma_private.task_status`)

### plpython3u
- HTTP 요청만 담당. 모델 로드/추론 직접 실행 금지
- `import torch`, `import transformers` 등 무거운 라이브러리 임포트 금지

---

## 설치 및 실행

```bash
# 빌드 및 설치
make build
sudo make install

# DB 적용
psql -c "CREATE EXTENSION vector;"
psql -c "CREATE EXTENSION alma;"

# 에이전트 생성
psql -c "SELECT alma_public.create_agent('agent_sql', 'SQL 분석기', ...);"

# psql에서 바로 실행
psql -c "SELECT alma_public.run_agent('agent_sql', 'show me all tables');"

# Python으로 실행
export DB_USER=agent_sql
python3 alma_agent.py
```
