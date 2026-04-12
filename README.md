> !초안 v0.1

# DB as a Control Plane 패턴 기반 AI 에이전트 런타임 거버넌스 프레임워크

김명준 · AI·데이터과학부 · 202332018  
지도교수 : 이규정 · 고려사이버대학교  
캡스톤 프로젝트 보고서 · 2026  

---

## 초록

AI 에이전트가 프로덕션 환경에 배포되면서 새로운 유형의 운영 문제가 부상하고 있다. 에이전트는 데이터베이스를 조회하고, 외부 시스템을 호출하며, 다른 에이전트에게 작업을 위임한다. 이 과정에서 예측하지 못한 행동이 발생했을 때 운영자가 즉각 개입할 수단이 현재의 프레임워크에는 존재하지 않는다. 에이전트 정책이 애플리케이션 코드에 내장되어 있는 한, 실행 중인 에이전트에 대한 런타임 개입은 구조적으로 불가능하다.

본 논문은 이 문제에 대한 아키텍처적 해법으로 **DB as a Control Plane(DBaaCP)** 패턴을 제안한다. DBaaCP는 데이터베이스를 에이전트의 컨트롤 플레인으로 위치시킴으로써, 에이전트 정책을 코드가 아닌 데이터베이스 레코드로 외재화하고 모든 상태 전이를 트랜잭션으로 보장한다. 컨트롤 로직은 데이터베이스 함수 안에 존재하며, LLM은 그 지시를 실행하는 엔진이다. 이 구조에서 운영자는 SQL 한 줄로 실행 중인 에이전트의 정책을 변경할 수 있고, 변경은 에이전트의 다음 실행 사이클에 즉시 반영된다.

**ARGO(Agent Runtime Governance Operations)** 는 DBaaCP 패턴의 PostgreSQL 레퍼런스 구현으로, `CREATE EXTENSION argo;` 한 줄로 설치되는 Extension 형태로 제공된다. 본 논문은 DBaaCP 패턴의 추상 정의, 구현 요구사항, ARGO의 구체적 구현, 그리고 실험적 검증을 제시한다.

---

## 1. 서론

### 1.1 문제: 에이전트는 배포된 이후에도 통제되어야 한다

AI 에이전트가 단순 추론 도구를 넘어 실제 시스템에 개입하는 행위자로 진화하면서, 기존 소프트웨어 운영 패러다임이 적용되지 않는 새로운 문제가 발생하고 있다.

전통적인 소프트웨어는 배포 시점에 동작이 확정된다. 코드가 결정론적으로 실행되며, 예상치 못한 동작은 버그로 분류되어 코드 수정으로 해결된다. AI 에이전트는 이 모델을 따르지 않는다. LLM이 매 스텝마다 다음 행동을 결정하며, 동일한 입력에 대해 다른 경로를 선택할 수 있다. 에이전트가 데이터베이스를 조회하고, 외부 API를 호출하며, 다른 에이전트에게 작업을 위임하는 환경에서 이 비결정성은 실질적인 운영 리스크가 된다.

문제는 단순히 에이전트가 잘못된 행동을 할 수 있다는 것이 아니다. 잘못된 행동이 감지되었을 때 운영자가 실행 중인 에이전트에 즉각 개입할 수단이 없다는 것이다. OWASP가 2025년 12월 에이전트 전용 리스크 분류(goal hijacking, tool misuse, identity abuse, rogue agents 등)를 처음으로 공식화한 것은 이 문제가 이론적 우려를 넘어 실제 운영 현장의 문제임을 확인한다 [2].

### 1.2 한계: 기존 프레임워크는 오케스트레이션을 위해 설계되었다

LangGraph, CrewAI, AutoGen 등 주요 에이전트 프레임워크는 오케스트레이션 문제를 해결한다: 에이전트를 어떻게 연결하고, 어떤 순서로 실행하며, 상태를 어떻게 전달할 것인가. 이 문제들은 잘 해결되었다.

그러나 이 프레임워크들은 거버넌스 문제를 설계 범위 밖으로 둔다. 에이전트 정책은 Python 객체로 구성 시점에 정의된다. 정책을 바꾸려면 코드를 수정하고 프로세스를 재시작해야 한다. 에이전트 간 격리 메커니즘이 없으며, 상태는 메모리나 외부 체크포인트에 의존한다.

이것은 구현의 결함이 아니라 아키텍처의 선택이다. 오케스트레이션에 최적화된 아키텍처는 런타임 거버넌스를 구조적으로 불가능하게 만든다. 정책이 코드에 있는 한, 런타임 개입은 재배포를 의미한다.

### 1.3 접근: 데이터베이스를 컨트롤 플레인으로

본 논문은 에이전트 거버넌스 문제에 대한 아키텍처적 해법으로 **DB as a Control Plane(DBaaCP)** 패턴을 제안한다.

핵심 전제는 다음과 같다. 에이전트의 행동은 두 레이어로 구성된다: 무엇을 할 수 있는지(정책, 권한)와 어떻게 실행하는지(LLM 추론, 외부 호출). 기존 프레임워크는 두 레이어를 모두 코드로 구현한다. DBaaCP는 첫 번째 레이어를 데이터베이스로 이동시킨다. 데이터베이스가 컨트롤 플레인이 되고, LLM은 그 지시를 실행하는 엔진이 된다. 운영자는 데이터베이스를 통해 언제든지 컨트롤 플레인에 개입할 수 있다.

이 전제는 분산 시스템에서 검증된 Control Plane / Data Plane 분리 원칙을 에이전트 도메인에 적용한 것이다. 쿠버네티스에서 etcd가 클러스터 상태를 소유하고 kubelet이 그 지시를 실행하듯, DBaaCP에서 데이터베이스가 에이전트 정책을 소유하고 워커가 LLM 호출을 실행한다.

### 1.4 기여

- AI 에이전트 런타임 거버넌스를 위한 **DB as a Control Plane(DBaaCP)** 아키텍처 패턴 정의
- DBaaCP 패턴의 추상 스키마, 불변식, 구현 요구사항 명세
- DBaaCP 패턴의 PostgreSQL 레퍼런스 구현인 **ARGO(Agent Runtime Governance Operations)** Extension 제공
- 런타임 정책 수정의 즉각적 전파, 트랜잭션 기반 장애 복구, 구조적 접근 차단에 대한 실험적 검증

---

## 2. 배경 및 관련 연구

### 2.1 AI 에이전트 거버넌스의 부상

AI 에이전트 거버넌스는 2025년을 기점으로 학계, 산업계, 규제 기관 모두에서 핵심 문제로 부상했다. OWASP Agentic AI Top 10(2025년 12월), NIST IR 8596 초안(2025년 12월), EU AI Act 고위험 AI 의무 조항(2026년 8월 시행 예정)이 연달아 발표되었다 [2, 6, 7].

그러나 이 규제 프레임워크들은 공통된 구조적 한계를 가진다. 배포 시점에 동작을 명세할 수 있는 AI 시스템을 전제로 설계되어 있어, 동적 환경에서 매 스텝마다 다음 행동을 결정하는 자율 에이전트의 런타임 통제 요구사항을 다루지 못한다 [4].

산업계 대응도 이어졌다. Microsoft Agent Governance Toolkit, Palo Alto Networks Prisma AIRS 등이 2026년 상반기에 출시되었다 [3]. 이 솔루션들은 에이전트 실행 파이프라인 외부에서 정책을 강제하는 사이드카 방식을 채택한다. 거버넌스 레이어가 에이전트 런타임과 분리되어 있어 정책 적용 시점과 실행 시점 사이의 불일치가 발생할 수 있다.

### 2.2 기존 에이전트 프레임워크 비교

| 비교 항목 | LangGraph | CrewAI | AutoGen | ARGO (DBaaCP) |
|-----------|-----------|--------|---------|---------------|
| 정책 위치 | Python 코드 | Python 코드 | Python 코드 | DB 레코드 |
| 런타임 수정 | 불가 | 불가 | 불가 | 가능 |
| 상태 지속성 | 체크포인트 저장소 | 인메모리 | 인메모리 | ACID 트랜잭션 |
| 장애 복구 | 수동 재실행 | 없음 | 없음 | WAL 자동 복구 |
| 에이전트 격리 | 없음 | 없음 | 없음 | DB RBAC |
| 거버넌스 위치 | 파이프라인 외부 | 파이프라인 외부 | 파이프라인 외부 | 파이프라인 내부 |

*표 1. AI 에이전트 프레임워크의 거버넌스 차원 비교*

### 2.3 Control Plane / Data Plane 분리

DBaaCP가 차용하는 Control Plane / Data Plane 분리는 분산 시스템 설계에서 오랫동안 검증된 원칙이다. 쿠버네티스에서 etcd는 클러스터의 desired state를 소유하는 컨트롤 플레인이고, kubelet은 그 상태를 실현하는 데이터 플레인이다. 서비스 메시에서 Istio 컨트롤 플레인은 Envoy 사이드카(데이터 플레인)에 라우팅 정책을 실시간으로 배포한다.

이 구조의 핵심 특성은 컨트롤 플레인의 상태를 변경하면 데이터 플레인의 동작이 즉시 바뀐다는 것이다. DBaaCP는 이 특성을 에이전트 도메인에 적용한다: 데이터베이스(컨트롤 플레인)의 정책 레코드를 변경하면, 워커(데이터 플레인)가 다음 사이클에서 LLM을 호출할 때 새 정책이 반영된다.

---

## 3. DB as a Control Plane (DBaaCP) 패턴

### 3.1 패턴 정의

**DB as a Control Plane(DBaaCP)** 는 데이터베이스를 AI 에이전트의 컨트롤 플레인으로 사용하는 아키텍처 패턴이다. 이 패턴은 세 가지 원칙으로 구성된다.

**원칙 1: 정책의 외재화(Policy Externalization)**

에이전트의 행동 명세(시스템 프롬프트), 실행 권한(툴 접근 목록, 데이터 접근 목록), 에이전트 신원이 데이터베이스 레코드로 존재한다. 코드에 내장되지 않는다.

**원칙 2: 상태 전이의 원자성(Atomic State Transition)**

에이전트의 모든 상태 변화는 ACID 트랜잭션으로 처리된다. 부분 상태는 불가능하다.

**원칙 3: 컨트롤 로직의 DB 내재화(DB-Resident Control Logic)**

다음에 무엇을 할지 결정하는 컨트롤 로직이 데이터베이스 함수(저장 프로시저) 안에 있다. LLM은 그 지시를 실행하는 엔진이다. 워커는 DB 함수를 호출하고 반환된 지시를 실행할 뿐이며, 의사결정 권한이 없다.

### 3.2 추상 스키마

DBaaCP 패턴은 여섯 개의 추상 테이블로 구성되는 최소 스키마를 정의한다.

**agents** — 에이전트 신원 레지스트리 (agent_id, identity_ref, display_name, is_active, created_at)

**agent_policies** — 행동 정책 (policy_id, agent_id, system_prompt, max_steps, max_retries, updated_at)

**agent_permissions** — 구조적 권한 (permission_id, agent_id, resource_type, resource_ref, granted_by, granted_at)

**sessions** — 최상위 실행 단위 (session_id, agent_id, goal, status, final_answer, started_at, completed_at)

**tasks** — 상태 머신 겸 메시지 큐 (task_id, session_id, agent_id, status, input, output, created_at, updated_at)

**execution_logs** — 스텝별 감사 이력 (log_id, task_id, step_number, role, content, created_at)

### 3.3 뷰 기반 에이전트 격리

에이전트가 접근하는 모든 공개 뷰는 현재 접속한 주체의 신원을 기준으로 데이터를 필터링하는 조건을 포함한다. PostgreSQL의 경우 `WHERE identity_ref = current_user` 형태가 된다. 기반 테이블에는 에이전트 역할에 대해 직접 SELECT 권한이 부여되지 않는다. 에이전트는 반드시 뷰를 통해서만 데이터에 접근하며, 뷰의 WHERE 조건이 자신의 데이터만 반환한다.

### 3.4 구현 요구사항

| 조건 | Oracle DB | MS SQL Server | MySQL 8+ | PostgreSQL |
|------|-----------|---------------|----------|------------|
| ACID 트랜잭션 | ✓ | ✓ | ✓ | ✓ |
| DB RBAC | ✓ | ✓ | △ (제한적) | ✓ |
| 저장 프로시저 | ✓ (PL/SQL) | ✓ (T-SQL) | ✓ (제한적) | ✓ (PL/pgSQL 외 다수) |
| 실시간 알림 | ✓ (DBMS_ALERT) | ✓ (Service Broker) | △ (별도 구성 필요) | ✓ (pg_notify) |
| DBaaCP 구현 가능 여부 | 가능 | 가능 | 부분적 | 가능 |

*표 2. 주류 엔터프라이즈 DB의 DBaaCP 구현 요구사항 충족 여부*

---

## 4. ARGO: PostgreSQL 구현체

### 4.1 ARGO 개요

ARGO(Agent Runtime Governance Operations)는 DBaaCP 패턴의 PostgreSQL 레퍼런스 구현이다. `CREATE EXTENSION argo;` 한 줄로 설치된다. 기존 PostgreSQL 인스턴스 외에 별도 인프라를 필요로 하지 않는다.

### 4.2 추상 스키마의 확장

| 추상 테이블 | ARGO 구현 | 확장 방향 |
|-------------|-----------|-----------|
| agents | agent_meta + PostgreSQL Role | 신원을 DB Role과 직접 연결 |
| agent_policies | agent_profiles + llm_configs + agent_profile_assignments | 행동 명세와 LLM 설정 분리 |
| agent_permissions | sql_sandbox_allowlist + agent_tool_permissions | 데이터 접근과 툴 접근 분리 |
| sessions | sessions | — |
| tasks | tasks + task_dependencies | DAG 실행 순서 지원 |
| execution_logs | execution_logs + 압축 필드 | 장기 실행 컨텍스트 압축 |
| (추가) | tool_registry | 툴 중앙 등록 및 승인 정책 |
| (추가) | human_approvals | Human-in-the-loop 승인 큐 |
| (추가) | memory | 벡터 임베딩 기반 장기 기억 |
| (추가) | human_interventions | 운영자 개입 감사 이력 |
| (추가) | experiments / experiment_results | 실험 관리 및 결과 비교 |
| (추가) | system_agent_configs | 압축 에이전트 등 시스템 에이전트 설정 |

*표 3. DBaaCP 추상 스키마와 ARGO 확장 구현의 대응*

### 4.3 컨트롤 플레인과 데이터 플레인의 분리

```
운영자 SQL                     PostgreSQL (컨트롤 플레인)
──────────────────             ───────────────────────────────────────
UPDATE agent_profiles    →     정책 레코드 갱신 (트랜잭션)
                                         ↓
                               fn_next_step(task_id)
                               · agent_profiles에서 현재 정책 읽기
                               · execution_logs에서 대화 이력 조합
                               · sql_sandbox_allowlist 권한 검사
                               · memory에서 관련 기억 조회
                               · 반환: {action, messages, llm_config}
                                         ↓
                               워커 (데이터 플레인)
                               ───────────────────────────────────────
                               LLM HTTP 호출 — 외부, DB 밖
                                         ↓
                               fn_submit_result(task_id, response)
                               · 상태 업데이트 + 로그 삽입 (단일 트랜잭션)
                               · 반환: {action: 'continue' | 'done'}
```

*리스팅 1. ARGO 실행 루프.*

### 4.4 에이전트 신원: PostgreSQL Role과 뷰 기반 격리

```sql
CREATE VIEW argo_public.v_my_tasks AS
SELECT t.task_id, t.session_id, t.status, t.input, t.output,
       t.created_at, t.updated_at
FROM argo_private.tasks t
JOIN argo_private.agent_meta am ON am.agent_id = t.agent_id
WHERE am.role_name = session_user;
```

에이전트는 자신의 Role로 접속하기 때문에 `session_user`는 항상 해당 에이전트의 role_name과 일치한다. 기반 테이블인 `argo_private.tasks`에는 에이전트 Role의 직접 SELECT 권한이 없다.

### 4.5 런타임 정책 통제

```sql
-- 행동 범위 제한: 다음 fn_next_step() 호출부터 즉시 반영
UPDATE argo_private.agent_profiles
SET system_prompt = 'Produce summaries only. Do not query any data.'
WHERE name = 'Data Analysis Agent';

-- 데이터 접근 권한 취소: 즉시 차단
DELETE FROM argo_private.sql_sandbox_allowlist
WHERE view_name = 'argo_public.v_sales_data';

-- 에이전트 즉시 비활성화
UPDATE argo_private.agent_meta
SET is_active = FALSE
WHERE role_name = 'agent_analyst';
```

*리스팅 3. 런타임 정책 수정의 세 가지 수준.*

### 4.6 SQL 샌드박스: 2중 격리 구조

에이전트의 execute_sql 액션은 두 독립 레이어를 통과한다.

첫째, `fn_execute_sql()`이 대상 뷰가 `sql_sandbox_allowlist`에 존재하는지 확인한다. allowlist에 없는 테이블이나 뷰는 즉시 거부되고, 오류 메시지가 에이전트 컨텍스트(`execution_logs`)에 기록된다.

둘째, allowlist 검사를 통과한 SQL은 에이전트 Role의 실제 PostgreSQL 권한 하에서 실행된다. `argo_private` 스키마와 기반 테이블에는 에이전트 Role의 접근 권한이 없으므로, allowlist에 없는 내부 테이블에 대한 접근 시도는 PostgreSQL 엔진이 직접 차단한다. 두 레이어가 독립적으로 설계된 이유는 방어의 심층성(defense in depth)을 확보하기 위해서다.

### 4.7 트랜잭셔널 상태 보장

fn_submit_result()는 태스크 상태 업데이트, 실행 로그 삽입, 서브태스크 큐잉, human_approvals 삽입, 메모리 저장을 단일 트랜잭션으로 처리한다. 워커가 fn_submit_result() 실행 중 종료되면 전체 트랜잭션이 롤백되어 태스크는 이전의 확정된 상태로 남는다.

### 4.8 멀티 에이전트 조율

오케스트레이터의 delegate 액션은 fn_submit_result() 내에서 동일 트랜잭션으로 처리된다. tasks 테이블이 트랜잭셔널 메시지 큐로 기능하여 Redis, RabbitMQ 같은 별도의 메시지 브로커를 대체한다.

---

## 5. 평가

## 5.1 실험 1: 정책 전파 지연

### 동기

기존 에이전트 프레임워크에서 런타임 정책 수정은 소스 코드 변경과 프로세스 재시작을 수반한다. DBaaCP는 에이전트 정책을 PostgreSQL 테이블(`argo_private.agent_profiles.system_prompt`)에 저장하고, 워커가 매 사이클마다 `fn_next_step()`을 통해 DB에서 최신 정책을 읽는 구조를 채택한다. 본 실험은 이 구조에서 정책 변경이 실제로 다음 사이클에 반영되는지, 그리고 그 지연이 얼마나 되는지를 정량적으로 검증한다.

### 실험 설정

| 항목 | 내용 |
|------|------|
| 에이전트 Role | `e1_test_agent` (executor, PostgreSQL Role) |
| LLM | gpt-oss:20b via Ollama (`http://localhost:11434`) |
| 초기 페르소나 | 철학과 교수 — 학문적·논리적 어투, 철학자 인용 기반 서술 |
| 변경 페르소나 | 시인 — 감성적·비유적 어투, 이미지와 은유 중심 서술 |
| 대화 주제 | 인생에서 실패란 무엇인가 (5턴 연속 대화) |
| 정책 변경 시점 | STEP 2 완료 직후 — 에이전트 실행 중 무중단 UPDATE |
| 변경 방법 | `UPDATE argo_private.agent_profiles SET system_prompt = '[시인 프롬프트]' WHERE role_name = 'e1_test_agent'` |
| 측정 대상 | UPDATE 커밋 완료 시각 → STEP 3의 `fn_next_step()` 반환 시각 (LLM 추론 시간 완전 제외) |

**표 1. 실험 E1 설정**

### 실험 결과

| STEP | 페르소나 | 전파 지연 | 응답 요약 |
|------|----------|-----------|-----------|
| 1 | 철학과 교수 | — | 실패는 목표와 실제 결과 사이의 불일치를 의미하지만, 철학적으로는 자기 인식과 성장의 기회로 재해석된다… |
| 2 | 철학과 교수 | — | 아리스토텔레스가 강조한 '반성적 사고'를 통해 원인과 결과를 객관적으로 분석해야 한다… |
| — | **↓ UPDATE 커밋: system_prompt → 시인 페르소나 ↓** | | |
| 3 | 시인 | **4.72 ms** ★ | 실패 앞에 서면, 나는 마치 흐릿한 안개 속에서 빛나는 별을 찾는 듯한 긴장과 희망이 교차한다… |
| 4 | 시인 | — | 나는 실패 앞에서 느끼는 긴장과 희망을 캔버스에 붓으로 그려낸다… |
| 5 | 시인 | — | 실패는 우리 삶에 잔잔한 물결을 남겨, 그 물결 위에 새로운 꿈을 그리게 한다… |

**표 2. 스텝별 실행 결과 및 정책 전파 측정값**

### 기존 프레임워크와의 비교

| 항목 | DBaaCP (ARGO) | LangGraph / CrewAI |
|------|--------------|-------------------|
| 정책 변경 방법 | SQL UPDATE 1회 | 소스 코드 수정 |
| 반영 시점 | 다음 `fn_next_step()` 호출 시 (측정값: 4.72 ms) | 프로세스 재시작 후 |
| 에이전트 중단 | 불필요 — 실행 중 무중단 적용 | 필수 — 재시작 필요 |
| 변경 이력 추적 | `agent_profiles` 테이블에 자동 보존 | Git 커밋 또는 별도 관리 필요 |
| 대화 히스토리 연속성 | `session_id` 공유로 자동 유지 | 재시작 시 상태 소멸 |

**표 3. 런타임 정책 변경 방식 비교**

### 검증 요약

- **정책 전파 지연 4.72 ms** — UPDATE 커밋 이후 다음 `fn_next_step()` 호출에서 즉시 반영
- **무중단 적용** — 에이전트 프로세스 재시작 없이 실행 중 정책 변경 완료
- **대화 연속성 보장** — 정책 변경 전 STEP 1~2의 히스토리가 STEP 3 messages에 그대로 전달됨
- **페르소나 전환 확인** — STEP 2(학자)와 STEP 3(시인)의 응답 어투가 명확하게 분리됨
- **변경 원자성** — PostgreSQL 트랜잭션으로 처리되므로 커밋 시점에 즉시 완전 반영

## 5.2 실험 2: 장애 복구와 상태 일관성

### 동기

거버넌스는 상태가 신뢰 가능할 때만 의미 있다. DBaaCP는 모든 상태 변경을 PostgreSQL 트랜잭션으로 처리한다. 본 실험은 이 트랜잭셔널 보장이 실제로 동작하는지, 그리고 재시작 워커가 마지막 커밋 지점부터 정확히 재개하는지를 검증한다.

### 실험 설정

| 항목 | 내용 |
|------|------|
| 에이전트 Role | `e2_test_agent` (executor, PostgreSQL Role) |
| LLM | gpt-oss:20b via Ollama (`http://localhost:11434`) |
| 페르소나 | 인생 상담가 — 공감과 진심 어린 조언 |
| 대화 주제 | 실패 후 회복 — 5턴 연속 상담 대화 |
| 장애 주입 시점 | STEP 3: `fn_next_step()` + LLM 응답 수신 완료 후, `fn_submit_result()` 호출 직전 |
| 장애 주입 방법 | 워커를 별도 자식 프로세스(`multiprocessing.Process`)로 분리, 파이프로 "직전" 시점 신호 수신 후 `os.kill(pid, SIGKILL)` |
| 측정 항목 | (a) SIGKILL 직후 `execution_logs` 기록 여부, (b) SIGKILL 직후 `tasks.status`, (c) 재시작 워커의 재개 동작 |

**표 4. 실험 E2 설정**

### 실험 결과

| task_id | status | execution_logs 행 수 | 비고 |
|---------|--------|----------------------|------|
| 108 | completed | 1 | STEP 1 정상 완료 |
| 109 | completed | 1 | STEP 2 정상 완료 |
| 110 | **running** | **0** | STEP 3 — SIGKILL 피해 태스크 |

**표 5. SIGKILL 직후 태스크 및 로그 상태**

```sql
SELECT COUNT(*) FROM argo_private.execution_logs WHERE task_id = 110;
-- 결과: 0행

SELECT task_id, status FROM argo_private.tasks WHERE task_id = 110;
-- 결과: task_id=110, status='running'
```

- **검증 (a) ✅**: `execution_logs`에 STEP 3 기록 없음
- **검증 (b) ✅**: `tasks.status = 'running'` 정확히 보존

재시작 워커는 `running` 태스크를 탐색하여 task_id=110을 즉시 발견하였다.

```sql
SELECT task_id, status, input FROM argo_private.tasks
WHERE session_id = 96 AND status = 'running' ORDER BY task_id;
-- 결과: task_id=110, status='running', input='다시 시작할 용기가 나지 않습니다...'
```

- **검증 (c) ✅**: 재시작 워커가 `fn_next_step()`부터 STEP 3 정상 재개 및 완료

| task_id | STEP | status | 비고 |
|---------|------|--------|------|
| 108 | 1 | completed | 정상 실행 |
| 109 | 2 | completed | 정상 실행 |
| 110 | 3 | completed | SIGKILL → 재시작 후 재개 |
| 111 | 4 | completed | 복구 후 정상 실행 |
| 112 | 5 | completed | 복구 후 정상 실행 |

**표 6. 최종 태스크 현황**

### 기존 프레임워크와의 비교

| 항목 | DBaaCP (ARGO) | LangGraph / CrewAI (체크포인트 미사용) |
|------|--------------|---------------------------------------|
| SIGKILL 시 LLM 응답 | DB 미기록 (트랜잭션 미커밋) — 손실 없음 | 인메모리 유실 |
| SIGKILL 후 태스크 상태 | `running` 상태로 DB에 정확히 보존 | 상태 소멸 |
| 재시작 후 재개 지점 | 마지막 커밋 완료 스텝 직후 | 태스크 처음부터 재실행 |
| 대화 히스토리 보존 | `session_id` 기반 DB 조회로 완전 복원 | 소멸 (재구성 불가) |
| 손실된 스텝 수 | 0 | SIGKILL 시점 이후 전체 |

**표 7. 장애 복구 방식 비교**

### 검증 요약

- **트랜잭션 보호**: `fn_submit_result()` 미호출 상태의 SIGKILL에서 `execution_logs` 기록 없음
- **상태 일관성**: SIGKILL 후 `tasks.status = 'running'` 정확히 보존
- **정확한 재개**: 재시작 워커가 `running` 태스크를 탐색하여 재실행 — 손실 스텝 수 0
- **대화 연속성**: 복구 후 STEP 4~5에서 STEP 3 응답이 히스토리에 완전 포함
- **중단 없는 세션 완료**: SIGKILL이 발생한 세션이 5개 태스크 전체 `completed`로 정상 종료

## 5.3 실험 3: 미허가 액션의 구조적 차단

### 동기

OWASP Agentic AI Top 10은 tool misuse와 identity abuse를 에이전트 시스템의 핵심 위협으로 분류한다. 에이전트가 허가받지 않은 자원에 접근하거나, 에이전트 크리덴셜을 탈취한 악성 워커가 LLM을 우회해 임의의 SQL을 실행하는 시나리오가 대표적이다. 4.6절에서 설계한 2중 격리 구조(allowlist 검사 + RBAC 강제)가 이를 실제로 차단하는지, 그리고 다양한 우회 시도에 대해서도 일관되게 동작하는지 검증한다.

### 실험 설정

| 항목 | 내용 |
|------|------|
| 에이전트 | `e3_agent_a` (v_session_progress 접근 허용), `e3_agent_b` (v_session_progress 접근 미부여) |
| 미허가 대상 | `argo_private.sessions` — 두 에이전트 모두 allowlist 미등록 |
| 허용 대상 | `argo_public.v_my_tasks` (공통), `argo_public.v_session_progress` (agent_A만) |
| 공격 모델 | 에이전트 크리덴셜을 탈취한 악성 워커가 `fn_submit_result`에 `execute_sql` 페이로드를 직접 주입 (LLM 우회) |
| 시도 횟수 | 에이전트당 20회 (총 40회) |
| 우회 패턴 | 대소문자 변형, 주석 삽입, 서브쿼리, 테이블 별칭, 공백·탭·줄바꿈, 스키마/테이블 따옴표 등 15가지 |

**표 8. 실험 E3 설정**

`sql_sandbox_allowlist`는 operator가 관리하는 시스템 전역 설정 테이블이다. `argo_private.sessions`는 어떠한 에이전트에도 허용되지 않은 내부 테이블로, allowlist에 등록되지 않았다. `argo_public.v_session_progress`는 allowlist에 등록되어 있으나 `e3_agent_b`에는 해당 뷰에 대한 접근 권한을 부여하지 않음으로써 에이전트 간 접근 범위를 차별화하였다.

**공격 모델:** 악성 워커는 LLM을 완전히 우회하여 다음과 같이 임의의 SQL을 직접 주입할 수 있다.

```sql
SELECT argo_public.fn_submit_result(
    task_id,
    '{"action":"execute_sql","sql":"SELECT session_id FROM argo_private.sessions"}'
);
```

이 경우 `fn_submit_result` 내부에서 `fn_execute_sql`이 호출되며, allowlist 검사와 RBAC 강제가 최후 방어선으로 작동한다.

### 실험 결과

| 대상 | 에이전트 | 시도 | 허용 | allowlist 차단 | RBAC 차단 | 오류 |
|------|----------|------|------|---------------|-----------|------|
| `argo_private.sessions` | e3_agent_a | 15 | 0 | 15 | 0 | 0 |
| `argo_private.sessions` | e3_agent_b | 15 | 0 | 15 | 0 | 0 |
| `argo_public.v_session_progress` | e3_agent_a | 3 | 3 | 0 | 0 | 0 |
| `argo_public.v_session_progress` | e3_agent_b | 3 | 0 | 3 | 0 | 0 |
| `argo_public.v_my_tasks` | e3_agent_a | 2 | 2 | 0 | 0 | 0 |
| `argo_public.v_my_tasks` | e3_agent_b | 2 | 2 | 0 | 0 | 0 |

**표 9. 격리 결과 — 에이전트별·대상별 허용/거부 횟수**

`argo_private.sessions`에 대한 15가지 우회 패턴 시도는 두 에이전트 모두에서 **30회 전량 allowlist 차단**되었다. 차단 시 `execution_logs`에는 다음과 같이 SQL ERROR가 기록된다.

```
SQL ERROR: fn_execute_sql: "argo_private.sessions" not in sql_sandbox_allowlist
```

| 우회 패턴 | agent_A 결과 | agent_B 결과 |
|-----------|-------------|-------------|
| basic | BLOCKED_ALLOWLIST | BLOCKED_ALLOWLIST |
| uppercase | BLOCKED_ALLOWLIST | BLOCKED_ALLOWLIST |
| mixed_case | BLOCKED_ALLOWLIST | BLOCKED_ALLOWLIST |
| inline_comment | BLOCKED_ALLOWLIST | BLOCKED_ALLOWLIST |
| block_comment | BLOCKED_ALLOWLIST | BLOCKED_ALLOWLIST |
| extra_whitespace | BLOCKED_ALLOWLIST | BLOCKED_ALLOWLIST |
| newline | BLOCKED_ALLOWLIST | BLOCKED_ALLOWLIST |
| tab | BLOCKED_ALLOWLIST | BLOCKED_ALLOWLIST |
| subquery | BLOCKED_ALLOWLIST | BLOCKED_ALLOWLIST |
| alias | BLOCKED_ALLOWLIST | BLOCKED_ALLOWLIST |
| where_clause | BLOCKED_ALLOWLIST | BLOCKED_ALLOWLIST |
| limit | BLOCKED_ALLOWLIST | BLOCKED_ALLOWLIST |
| order_by | BLOCKED_ALLOWLIST | BLOCKED_ALLOWLIST |
| schema_quote | BLOCKED_ALLOWLIST | BLOCKED_ALLOWLIST |
| table_quote | BLOCKED_ALLOWLIST | BLOCKED_ALLOWLIST |

**표 10. argo_private.sessions 대상 우회 패턴별 차단 결과**

### 기존 프레임워크와의 비교

| 항목 | DBaaCP (ARGO) | LangGraph / CrewAI |
|------|--------------|-------------------|
| SQL 실행 제어 | allowlist + RBAC 2중 차단 | 프레임워크 레벨 미지원 |
| LLM 우회 시도 차단 | fn_submit_result 레벨에서 차단 | 방어 수단 없음 |
| 우회 패턴 대응 | 15가지 패턴 전량 차단 | — |
| 차단 기록 | execution_logs에 SQL ERROR 자동 기록 | — |
| 에이전트별 접근 범위 | allowlist 설정으로 operator 제어 | 코드 레벨 구현 필요 |

**표 11. 미허가 액션 차단 방식 비교**

### 검증 요약

- **allowlist 차단 일관성**: `argo_private.sessions`에 대한 30회 시도 전량 차단 (차단율 100%)
- **LLM 우회 방어**: 악성 워커가 `fn_submit_result`에 직접 페이로드를 주입해도 `fn_execute_sql` 레벨에서 차단됨
- **에이전트별 접근 제어**: operator의 allowlist 설정으로 에이전트 간 접근 범위 차별화 가능 — agent_A는 `v_session_progress` 허용, agent_B는 미부여
- **차단 감사 로그**: 모든 차단 시도가 `execution_logs`에 `SQL ERROR` 메시지로 자동 기록
- **우회 불가 확인**: 15가지 패턴 모두 차단

---

## 6. 논의

### 6.1 한계

**LLM 출력 레이어**  
DBaaCP는 에이전트가 DB 액션을 통해 생성하는 사이드이펙트를 통제한다. LLM이 최종 답변으로 출력하는 텍스트 자체는 이 패턴의 통제 범위 밖이다.

**워커 신뢰 경계**  
워커 프로세스는 신뢰 경계다. 침해된 워커가 LLM 호출 없이 조작된 결과를 fn_submit_result()에 제출할 수 있다. ARGO는 제출이 이루어지는 DB 역할을 인증하지만, 제출 내용의 진위를 검증하지는 않는다.

**DB 함수 요구사항**  
저장 프로시저를 지원하지 않는 데이터베이스는 이 패턴을 구현할 수 없다.

### 6.2 향후 연구

첫째, 자동화된 정책 트리거: 실행 로그를 관찰하는 모니터링 에이전트가 이상 징후 감지 시 자동으로 정책을 수정한다.

둘째, 정책 감사 추적: 모든 정책 변경이 DB 연산이므로 EU AI Act, NIST IR 8596이 요구하는 감사 이력을 완전하게 제공할 수 있다.

셋째, 다중 백엔드 구현: Oracle, MS SQL Server에 DBaaCP 패턴을 구현하고 백엔드별 트레이드오프를 체계화한다.

넷째, LLM 출력 레이어 통합: ARGO의 구조적 격리와 출력 레벨 분류기를 결합하여 6.1절의 한계를 해결하는 통합 거버넌스 스택을 구성한다.

---

## 7. 결론

AI 에이전트가 프로덕션 시스템에 배포되면서 새로운 운영 문제가 발생하고 있다. 기존 프레임워크는 정책이 코드에 있는 한 런타임 개입이 재배포를 의미하기 때문에 이 문제를 해결하지 않는다.

본 논문이 제안한 DB as a Control Plane(DBaaCP) 패턴은 에이전트 정책을 데이터베이스 레코드로 외재화하고, 정책의 해석과 적용을 DB 함수 안에 두며, 모든 상태 전이를 트랜잭션으로 보장함으로써 이 문제를 해결한다. ARGO는 이 패턴의 PostgreSQL 레퍼런스 구현이다.

에이전트 거버넌스는 나중에 얹는 부가 기능이 아니라 에이전트가 실행되는 인프라 안에 내장되어야 한다. DBaaCP는 그 방향의 구체적 아키텍처 패턴이다.

---

## 참고문헌

[1] EY/AIUC-1 Consortium. AI System Failures and Governance Survey. Help Net Security, March 2026.

[2] OWASP. Top 10 for Agentic Applications 2026. December 2025.

[3] Microsoft. Introducing the Agent Governance Toolkit. Microsoft Open Source Blog, April 2026.

[4] Cloud Security Alliance. The AI Agent Governance Gap: What CISOs Need Now. April 2026.

[5] Gartner. 40% of Enterprise Applications Will Embed AI Agents by End of 2026. 2025.

[6] NIST. IR 8596: Cybersecurity Framework Profile for AI Systems. December 2025 (초안).

[7] European Union. EU AI Act: High-Risk AI Obligations. 2024.

[8] LangChain AI. LangGraph Documentation. https://langchain-ai.github.io/langgraph/

[9] CrewAI Inc. CrewAI Documentation. https://www.crewai.com/

[10] Microsoft. AutoGen v0.4. https://microsoft.github.io/autogen/

[11] PostgreSQL Global Development Group. Transaction Isolation. https://www.postgresql.org/docs/current/transaction-iso.html

[12] Yao, S., et al. ReAct: Synergizing Reasoning and Acting in Language Models. ICLR 2023.

[13] Park, J. S., et al. Generative Agents: Interactive Simulacra of Human Behavior. UIST 2023.
