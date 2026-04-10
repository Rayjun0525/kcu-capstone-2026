ARGO: DB as a Control Plane 패턴 기반 AI 에이전트 런타임 거버넌스 프레임워크
[저자명] · [소속 학과] · [학번]
[지도 교수] · [대학교]
캡스톤 프로젝트 보고서 · 2026

초록
AI 에이전트가 프로덕션 환경에 배포되면서 새로운 유형의 운영 문제가 부상하고 있다. 에이전트는 데이터베이스를 조회하고, 외부 시스템을 호출하며, 다른 에이전트에게 작업을 위임한다. 이 과정에서 예측하지 못한 행동이 발생했을 때 운영자가 즉각 개입할 수단이 현재의 프레임워크에는 존재하지 않는다. 에이전트 정책이 애플리케이션 코드에 내장되어 있는 한, 실행 중인 에이전트에 대한 런타임 개입은 구조적으로 불가능하다.
본 논문은 이 문제에 대한 아키텍처적 해법으로 DB as a Control Plane(DBaaCP) 패턴을 제안한다. DBaaCP는 데이터베이스를 에이전트의 컨트롤 플레인으로 위치시킴으로써, 에이전트 정책을 코드가 아닌 데이터베이스 레코드로 외재화하고 모든 상태 전이를 트랜잭션으로 보장한다. 컨트롤 로직은 데이터베이스 함수 안에 존재하며, LLM은 그 지시를 실행하는 엔진이다. 이 구조에서 운영자는 SQL 한 줄로 실행 중인 에이전트의 정책을 변경할 수 있고, 변경은 에이전트의 다음 실행 사이클에 즉시 반영된다.
ARGO(Agent Runtime Governance Operations) 는 DBaaCP 패턴의 PostgreSQL 레퍼런스 구현으로, CREATE EXTENSION argo; 한 줄로 설치되는 Extension 형태로 제공된다. 본 논문은 DBaaCP 패턴의 추상 정의, 구현 요구사항, ARGO의 구체적 구현, 그리고 실험적 검증을 제시한다.

1. 서론
1.1 문제: 에이전트는 배포된 이후에도 통제되어야 한다
AI 에이전트가 단순 추론 도구를 넘어 실제 시스템에 개입하는 행위자로 진화하면서, 기존 소프트웨어 운영 패러다임이 적용되지 않는 새로운 문제가 발생하고 있다.
전통적인 소프트웨어는 배포 시점에 동작이 확정된다. 코드가 결정론적으로 실행되며, 예상치 못한 동작은 버그로 분류되어 코드 수정으로 해결된다. AI 에이전트는 이 모델을 따르지 않는다. LLM이 매 스텝마다 다음 행동을 결정하며, 동일한 입력에 대해 다른 경로를 선택할 수 있다. 에이전트가 데이터베이스를 조회하고, 외부 API를 호출하며, 다른 에이전트에게 작업을 위임하는 환경에서 이 비결정성은 실질적인 운영 리스크가 된다.
문제는 단순히 에이전트가 잘못된 행동을 할 수 있다는 것이 아니다. 잘못된 행동이 감지되었을 때 운영자가 실행 중인 에이전트에 즉각 개입할 수단이 없다는 것이다. OWASP가 2025년 12월 에이전트 전용 리스크 분류(goal hijacking, tool misuse, identity abuse, rogue agents 등)를 처음으로 공식화한 것은 이 문제가 이론적 우려를 넘어 실제 운영 현장의 문제임을 확인한다 [2].
1.2 한계: 기존 프레임워크는 오케스트레이션을 위해 설계되었다
LangGraph, CrewAI, AutoGen 등 주요 에이전트 프레임워크는 오케스트레이션 문제를 해결한다: 에이전트를 어떻게 연결하고, 어떤 순서로 실행하며, 상태를 어떻게 전달할 것인가. 이 문제들은 잘 해결되었다.
그러나 이 프레임워크들은 거버넌스 문제를 설계 범위 밖으로 둔다. 에이전트 정책은 Python 객체로 구성 시점에 정의된다. 정책을 바꾸려면 코드를 수정하고 프로세스를 재시작해야 한다. 에이전트 간 격리 메커니즘이 없으며, 상태는 메모리나 외부 체크포인트에 의존한다.
이것은 구현의 결함이 아니라 아키텍처의 선택이다. 오케스트레이션에 최적화된 아키텍처는 런타임 거버넌스를 구조적으로 불가능하게 만든다. 정책이 코드에 있는 한, 런타임 개입은 재배포를 의미한다.
1.3 접근: 데이터베이스를 컨트롤 플레인으로
본 논문은 에이전트 거버넌스 문제에 대한 아키텍처적 해법으로 DB as a Control Plane(DBaaCP) 패턴을 제안한다.
핵심 전제는 다음과 같다. 에이전트의 행동은 두 레이어로 구성된다: 무엇을 할 수 있는지(정책, 권한)와 어떻게 실행하는지(LLM 추론, 외부 호출). 기존 프레임워크는 두 레이어를 모두 코드로 구현한다. DBaaCP는 첫 번째 레이어를 데이터베이스로 이동시킨다. 데이터베이스가 컨트롤 플레인이 되고, LLM은 그 지시를 실행하는 엔진이 된다. 운영자는 데이터베이스를 통해 언제든지 컨트롤 플레인에 개입할 수 있다.
이 전제는 분산 시스템에서 검증된 Control Plane / Data Plane 분리 원칙을 에이전트 도메인에 적용한 것이다. 쿠버네티스에서 etcd가 클러스터 상태를 소유하고 kubelet이 그 지시를 실행하듯, DBaaCP에서 데이터베이스가 에이전트 정책을 소유하고 워커가 LLM 호출을 실행한다.
1.4 기여
	∙	AI 에이전트 런타임 거버넌스를 위한 DB as a Control Plane(DBaaCP) 아키텍처 패턴 정의
	∙	DBaaCP 패턴의 추상 스키마, 불변식, 구현 요구사항 명세
	∙	DBaaCP 패턴의 PostgreSQL 레퍼런스 구현인 ARGO(Agent Runtime Governance Operations) Extension 제공
	∙	런타임 정책 수정의 즉각적 전파, 트랜잭션 기반 장애 복구, 구조적 접근 차단에 대한 실험적 검증

2. 배경 및 관련 연구
2.1 AI 에이전트 거버넌스의 부상
AI 에이전트 거버넌스는 2025년을 기점으로 학계, 산업계, 규제 기관 모두에서 핵심 문제로 부상했다. OWASP Agentic AI Top 10(2025년 12월), NIST IR 8596 초안(2025년 12월), EU AI Act 고위험 AI 의무 조항(2026년 8월 시행 예정)이 연달아 발표되었다 [2, 6, 7].
그러나 이 규제 프레임워크들은 공통된 구조적 한계를 가진다. 배포 시점에 동작을 명세할 수 있는 AI 시스템을 전제로 설계되어 있어, 동적 환경에서 매 스텝마다 다음 행동을 결정하는 자율 에이전트의 런타임 통제 요구사항을 다루지 못한다 [4].
산업계 대응도 이어졌다. Microsoft Agent Governance Toolkit, Palo Alto Networks Prisma AIRS 등이 2026년 상반기에 출시되었다 [3]. 이 솔루션들은 에이전트 실행 파이프라인 외부에서 정책을 강제하는 사이드카 방식을 채택한다. 거버넌스 레이어가 에이전트 런타임과 분리되어 있어 정책 적용 시점과 실행 시점 사이의 불일치가 발생할 수 있다.
2.2 기존 에이전트 프레임워크 비교



|비교 항목  |LangGraph|CrewAI   |AutoGen  |ARGO (DBaaCP)|
|-------|---------|---------|---------|-------------|
|정책 위치  |Python 코드|Python 코드|Python 코드|DB 레코드       |
|런타임 수정 |불가       |불가       |불가       |가능           |
|상태 지속성 |체크포인트 저장소|인메모리     |인메모리     |ACID 트랜잭션    |
|장애 복구  |수동 재실행   |없음       |없음       |WAL 자동 복구    |
|에이전트 격리|없음       |없음       |없음       |DB RBAC      |
|거버넌스 위치|파이프라인 외부 |파이프라인 외부 |파이프라인 외부 |파이프라인 내부     |

표 1. AI 에이전트 프레임워크의 거버넌스 차원 비교
표 1에서 ARGO의 핵심 차별점은 거버넌스 위치에 있다. 기존 프레임워크는 거버넌스를 파이프라인 외부에서 부가적으로 처리하지만, DBaaCP는 거버넌스를 파이프라인 내부의 컨트롤 플레인으로 끌어들인다.
2.3 Control Plane / Data Plane 분리
DBaaCP가 차용하는 Control Plane / Data Plane 분리는 분산 시스템 설계에서 오랫동안 검증된 원칙이다. 쿠버네티스에서 etcd는 클러스터의 desired state를 소유하는 컨트롤 플레인이고, kubelet은 그 상태를 실현하는 데이터 플레인이다. 서비스 메시에서 Istio 컨트롤 플레인은 Envoy 사이드카(데이터 플레인)에 라우팅 정책을 실시간으로 배포한다.
이 구조의 핵심 특성은 컨트롤 플레인의 상태를 변경하면 데이터 플레인의 동작이 즉시 바뀐다는 것이다. DBaaCP는 이 특성을 에이전트 도메인에 적용한다: 데이터베이스(컨트롤 플레인)의 정책 레코드를 변경하면, 워커(데이터 플레인)가 다음 사이클에서 LLM을 호출할 때 새 정책이 반영된다.

3. DB as a Control Plane (DBaaCP) 패턴
3.1 패턴 정의
DB as a Control Plane(DBaaCP) 는 데이터베이스를 AI 에이전트의 컨트롤 플레인으로 사용하는 아키텍처 패턴이다. 이 패턴은 세 가지 원칙으로 구성된다.
원칙 1: 정책의 외재화(Policy Externalization)
에이전트의 행동 명세(시스템 프롬프트), 실행 권한(툴 접근 목록, 데이터 접근 목록), 에이전트 신원이 데이터베이스 레코드로 존재한다. 코드에 내장되지 않는다.
이 원칙이 런타임 수정을 가능하게 하는 근거다. 정책이 코드에 있으면 수정은 재배포를 의미한다. 정책이 데이터베이스에 있으면 수정은 UPDATE 한 줄이다. 실행 중인 에이전트는 다음 사이클에서 새 정책을 읽는다.
원칙 2: 상태 전이의 원자성(Atomic State Transition)
에이전트의 모든 상태 변화—태스크 큐잉, 스텝 실행, 완료, 실패—는 ACID 트랜잭션으로 처리된다. 부분 상태는 불가능하다.
이 원칙이 신뢰 가능한 거버넌스의 기반이다. 운영자가 정책을 변경하는 동시에 에이전트가 스텝을 실행하더라도, 두 연산은 직렬화되어 에이전트가 혼합 상태의 정책을 보는 것이 구조적으로 불가능하다. 워커가 실행 중 장애를 겪으면 트랜잭션이 롤백되고 태스크는 이전의 확정된 상태로 남는다.
원칙 3: 컨트롤 로직의 DB 내재화(DB-Resident Control Logic)
다음에 무엇을 할지 결정하는 컨트롤 로직이 데이터베이스 함수(저장 프로시저) 안에 있다. LLM은 그 지시를 실행하는 엔진이다. 워커는 DB 함수를 호출하고 반환된 지시를 실행할 뿐이며, 의사결정 권한이 없다.
이 원칙의 필요성은 원칙 1만으로는 충분하지 않다는 관찰에서 출발한다. 정책을 데이터베이스에 두되 해석과 적용 로직을 워커 코드에 두는 방식을 생각해보자. 이 경우 “정책을 어떻게 해석할지”가 워커 코드에 내장된다. 워커 버전이 다르면 동일한 정책을 다르게 해석할 수 있고, 정책 변경이 워커의 해석 로직과 충돌할 수 있으며, 정책의 실질적 의미가 다시 코드에 종속된다. 정책을 외재화했지만 그 해석권은 여전히 코드에 있는 것이다.
컨트롤 로직을 DB 함수 안에 두면 정책의 해석과 적용이 단일 트랜잭션 경계 안에서 이루어진다. 정책 변경과 그 적용이 원자적으로 보장되며, 워커는 해석 없이 지시를 실행하는 진정한 상태 비저장 실행자가 된다. 이것이 데이터베이스를 단순히 정책을 저장하는 구성 요소가 아니라 결정을 내리는 컨트롤 플레인으로 만드는 조건이다.
3.2 추상 스키마
DBaaCP 패턴은 다음 다섯 개의 추상 테이블로 구성되는 최소 스키마를 정의한다. 이 스키마는 특정 데이터베이스의 문법에 독립적이다.

agents (에이전트 신원 레지스트리)
─────────────────────────────────────────────
agent_id      식별자 (PK)
identity_ref  DB 역할명 또는 외부 신원 토큰
display_name  표시명
is_active     활성 여부
created_at    생성 시각

agent_policies (행동 정책 — 런타임 수정 대상)
─────────────────────────────────────────────
policy_id      식별자 (PK)
agent_id       FK → agents
system_prompt  자연어 행동 명세
max_steps      최대 실행 스텝
max_retries    최대 재시도 횟수
updated_at     마지막 수정 시각

agent_permissions (구조적 권한)
─────────────────────────────────────────────
permission_id  식별자 (PK)
agent_id       FK → agents
resource_type  'data_view' | 'tool' | 'agent'
resource_ref   허용된 자원 식별자
granted_by     부여한 운영자
granted_at     부여 시각

sessions (최상위 실행 단위)
─────────────────────────────────────────────
session_id    식별자 (PK)
agent_id      FK → agents
goal          목표 텍스트
status        'active' | 'completed' | 'failed'
final_answer  최종 답변
started_at    시작 시각
completed_at  완료 시각

tasks (상태 머신 겸 에이전트 간 메시지 큐)
─────────────────────────────────────────────
task_id     식별자 (PK)
session_id  FK → sessions
agent_id    FK → agents
status      'pending' | 'running' | 'completed' | 'failed' | 'cancelled'
input       태스크 입력
output      태스크 출력
created_at  생성 시각
updated_at  마지막 상태 변경 시각

execution_logs (스텝별 감사 이력 — append-only)
─────────────────────────────────────────────
log_id       식별자 (PK)
task_id      FK → tasks
step_number  스텝 번호
role         'system' | 'user' | 'assistant' | 'tool'
content      메시지 내용
created_at   기록 시각


그림 1: DBaaCP 최소 추상 스키마. 특정 DB 문법에 독립적이다.
이 다섯 테이블은 DBaaCP 패턴의 불변식(invariant) 을 담는다.
	∙	agent_policies는 런타임에 UPDATE 가능해야 하며, 변경은 다음 컨트롤 함수 호출에 즉시 반영되어야 한다.
	∙	tasks.status 전이는 원자적이어야 한다. pending → running → completed 중간 상태는 존재하지 않는다.
	∙	execution_logs는 append-only다. 감사 이력은 수정할 수 없다.
	∙	agent_permissions의 변경은 다음 권한 검사에 즉시 강제되어야 한다.
3.3 구현 요구사항
DBaaCP 패턴을 구현하는 데이터베이스는 네 가지 기술 조건을 만족해야 한다. 이 조건들은 세 원칙에서 직접 도출된다.
조건 1: ACID 트랜잭션
원칙 2(상태 전이의 원자성)의 기반이다. 태스크 상태 업데이트, 로그 삽입, 서브태스크 큐잉이 단일 트랜잭션으로 처리되어야 한다. 이 조건이 없으면 워커 장애 시 부분 상태가 영속될 수 있다.
조건 2: 역할 기반 접근 제어(RBAC)
원칙 1에서 에이전트 신원을 DB 역할로 표현하고, 에이전트별 데이터 격리를 DB 엔진 수준에서 강제하기 위한 조건이다. 이 조건이 없으면 격리를 애플리케이션 코드로 구현해야 하며, 이는 소프트 제약으로 우회 가능하다.
조건 3: 저장 프로시저 / DB 함수
원칙 3(컨트롤 로직의 DB 내재화)의 기반이다. 컨트롤 로직이 DB 함수로 존재해야 정책의 해석과 적용이 단일 트랜잭션 경계 안에서 이루어진다. 이 조건을 만족하지 못하는 데이터베이스는 DBaaCP를 구현할 수 없다.
조건 4: 실시간 알림(Publish/Subscribe)
워커가 새 태스크를 폴링 없이 즉시 감지하기 위한 조건이다. 여기서 실시간 알림이란 데이터베이스가 특정 이벤트 발생 시 구독 중인 클라이언트에게 능동적으로 알림을 전송하는 메커니즘을 의미한다. PostgreSQL의 pg_notify/LISTEN이 대표적 구현이며, Oracle의 DBMS_ALERT, MS SQL Server의 Service Broker가 동등한 기능을 제공한다. 이 조건은 폴링 방식으로 대체할 수 있으나, 폴링은 지연과 DB 부하를 증가시킨다.
아래 표는 주류 엔터프라이즈 데이터베이스의 조건 충족 여부를 정리한다. 이는 새 인프라 도입보다 기존 보유 DB 자산을 DBaaCP 구현에 활용할 수 있는지를 판단하는 기준이다.



|조건             |Oracle DB     |MS SQL Server     |MySQL 8+    |PostgreSQL       |
|---------------|--------------|------------------|------------|-----------------|
|ACID 트랜잭션      |✓             |✓                 |✓           |✓                |
|DB RBAC        |✓             |✓                 |△ (제한적)     |✓                |
|저장 프로시저        |✓ (PL/SQL)    |✓ (T-SQL)         |✓ (제한적)     |✓ (PL/pgSQL 외 다수)|
|실시간 알림         |✓ (DBMS_ALERT)|✓ (Service Broker)|△ (별도 구성 필요)|✓ (pg_notify)    |
|DBaaCP 구현 가능 여부|가능            |가능                |부분적         |가능               |

표 2. 주류 엔터프라이즈 DB의 DBaaCP 구현 요구사항 충족 여부
Oracle, MS SQL Server, PostgreSQL은 네 조건을 모두 충족하며, 각각의 문법과 메커니즘으로 DBaaCP 패턴을 구현할 수 있다. 조직이 이미 보유한 Oracle이나 MS SQL Server 인프라 위에서도 DBaaCP 패턴을 구현할 수 있다는 점은 실용적으로 중요하다. MySQL은 RBAC 표현력과 실시간 알림 지원이 제한적이어서 부분적 구현에 그친다.

4. ARGO: PostgreSQL 구현체
4.1 ARGO 개요
ARGO(Agent Runtime Governance Operations)는 DBaaCP 패턴의 PostgreSQL 레퍼런스 구현이다. PostgreSQL을 선택한 이유는 표 2의 네 조건을 모두 충족하면서, PL/pgSQL 외에 plpython3u 등 다양한 언어로 DB 함수를 작성할 수 있어 컨트롤 로직의 표현력이 높기 때문이다. 행 수준 보안(Row Level Security), session_user 기반 뷰 필터링, pg_notify를 통한 실시간 알림이 단일 오픈소스 인프라로 통합되어 있으며, Extension 메커니즘은 스키마, 함수, 역할을 단일 설치 단위로 패키징한다.
ARGO는 CREATE EXTENSION argo; 한 줄로 설치된다. 기존 PostgreSQL 인스턴스 외에 별도 인프라를 필요로 하지 않는다.
4.2 추상 스키마의 확장
3.2절의 DBaaCP 최소 스키마는 패턴의 핵심 구조를 정의하지만, 실제 프로덕션 요구사항을 모두 담지는 않는다. ARGO는 이 최소 스키마를 다음과 같이 확장한다.



|추상 테이블           |ARGO 구현                                                  |확장 이유                                |
|-----------------|---------------------------------------------------------|-------------------------------------|
|agents           |agent_meta + PostgreSQL Role                             |신원을 DB 역할과 직접 연결하여 엔진 수준 격리 확보       |
|agent_policies   |agent_profiles + llm_configs + agent_profile_assignments |LLM 설정(모델, 엔드포인트, 온도)을 정책과 분리하여 독립 관리|
|agent_permissions|sql_sandbox_allowlist + agent_tool_permissions           |데이터 접근과 툴 접근을 별도 테이블로 분리하여 세밀한 제어    |
|sessions         |sessions                                                 |—                                    |
|tasks            |tasks + task_dependencies                                |DAG 실행 순서를 위한 의존성 그래프 추가             |
|execution_logs   |execution_logs + compressed_content + compression_quality|장기 실행 에이전트의 컨텍스트 압축 지원               |
|(추가)             |agent_messages                                           |에이전트 간 직접 통신 이력                      |
|(추가)             |human_interventions                                      |운영자 개입 감사 이력                         |
|(추가)             |human_approvals                                          |Human-in-the-loop 승인 큐               |
|(추가)             |tool_registry                                            |MCP 툴 등록 및 승인 정책 관리                  |
|(추가)             |memory                                                   |벡터 임베딩 기반 장기 기억 (pgvector 활용)        |
|(추가)             |experiments / experiment_results                         |실험 관리 및 결과 기록                        |
|(추가)             |system_agent_configs                                     |로그 압축 등 시스템 에이전트 설정                  |

표 3. DBaaCP 추상 스키마와 ARGO 확장 구현의 대응
확장의 방향은 두 가지다. 첫째, 추상 테이블의 분리: agent_policies가 llm_configs와 agent_profiles로 분리되어 LLM 설정을 에이전트 간에 공유하거나 독립적으로 변경할 수 있다. 둘째, 추상 스키마에 없는 테이블의 추가: human_approvals는 에이전트가 툴 호출 전 운영자 승인을 요청하는 Human-in-the-loop 흐름을 지원하며, memory는 pgvector를 활용한 벡터 유사도 검색으로 에이전트의 장기 기억을 구현한다.
이 확장들은 모두 DBaaCP의 세 원칙을 유지하면서 이루어진다. 추가된 테이블은 모두 argo_private 스키마에 위치하며, 에이전트는 argo_public의 뷰와 함수를 통해서만 접근한다.
4.3 컨트롤 플레인과 데이터 플레인의 분리
ARGO의 실행 루프는 DBaaCP 원칙 3을 다음과 같이 구현한다.

운영자 SQL                     PostgreSQL (컨트롤 플레인)
──────────────────             ───────────────────────────────────────
UPDATE agent_profiles    →     정책 레코드 갱신 (트랜잭션)
                                         ↓
                               fn_next_step(task_id)
                               · 현재 정책 읽기 (agent_profiles)
                               · 메시지 이력 조합 (execution_logs)
                               · 권한 검사 (sql_sandbox_allowlist)
                               · 반환: {action, messages, llm_config}
                                         ↓
                               워커 (데이터 플레인)
                               ───────────────────────────────────────
                               LLM HTTP 호출 — 외부, DB 밖
                               LLM은 컨트롤 플레인의 지시를 실행하는 엔진
                                         ↓
                               fn_submit_result(task_id, response)
                               · 응답 파싱 및 액션 분기
                               · 상태 업데이트 + 로그 삽입 (단일 트랜잭션)
                               · 반환: {action: 'continue' | 'done'}


리스팅 1. ARGO 실행 루프. 컨트롤 결정은 DB 함수가, 실행은 워커가 담당한다.
fn_next_step()은 호출마다 agent_profiles에서 현재 system_prompt를 읽는다. 캐시가 없다. 운영자의 UPDATE가 커밋되면 다음 fn_next_step() 호출은 새 정책을 반환한다. LLM은 그 정책의 범위 안에서 동작하는 실행 엔진이다.
[ 그림 2: ARGO 실행 루프 다이어그램 ]
4.4 에이전트 신원: PostgreSQL Role
ARGO는 에이전트 신원을 PostgreSQL Role로 구현한다. create_agent() 함수는 Role 생성, 프로파일 삽입, 기본 권한 부여를 단일 트랜잭션으로 처리한다.
에이전트가 접근하는 모든 뷰는 WHERE role_name = session_user로 자동 필터링된다. 에이전트 A는 에이전트 B의 태스크와 메모리를 볼 수 없다. 이것은 애플리케이션 코드가 아닌 DB 엔진이 강제하는 하드 제약이다.

SELECT argo_public.create_agent(
    'agent_analyst',
    '{
        "name":          "데이터 분석 에이전트",
        "agent_role":    "executor",
        "provider":      "anthropic",
        "model_name":    "claude-sonnet-4-20250514",
        "system_prompt": "당신은 매출 데이터를 분석합니다."
    }'::jsonb
);


리스팅 2. 에이전트 생성. Role 프로비저닝, 프로파일 삽입, 권한 부여가 단일 트랜잭션으로 처리된다.
4.5 런타임 정책 통제
에이전트가 예상치 못한 행동을 보이는 상황에서 운영자가 취하는 행동:

-- 행동 범위 제한
UPDATE argo_private.agent_profiles
SET system_prompt = '요약만 수행하세요. 데이터를 조회하지 마세요.'
WHERE name = '데이터 분석 에이전트';

-- 데이터 접근 권한 취소
DELETE FROM argo_private.sql_sandbox_allowlist
WHERE view_name = 'argo_public.v_sales_data';


리스팅 3. 런타임 정책 수정. 변경은 에이전트의 다음 실행 사이클에 반영된다. 재시작과 재배포가 필요하지 않다.
기존 프레임워크에서 동일한 작업은 코드 수정과 프로세스 재시작을 요구한다. DBaaCP에서 정책은 데이터이고 데이터는 언제든 변경할 수 있다.
4.6 SQL 샌드박스: 2중 격리 구조
에이전트의 execute_sql 액션은 두 독립 레이어를 통과한다.
첫째, fn_execute_sql()이 대상 뷰가 sql_sandbox_allowlist에 존재하는지 확인한다. 존재하지 않으면 액션이 거부된다. 둘째, SET LOCAL ROLE argo_sql_sandbox로 최소 권한 역할로 전환 후 쿼리를 실행한다. 이 역할은 허용된 뷰에만 SELECT 권한을 가진다.
첫 번째 레이어는 운영자가 동적으로 관리하는 정책 제약이고, 두 번째 레이어는 DB 엔진이 강제하는 권한 제약이다. 두 레이어가 독립적으로 작동하므로 어느 한 레이어를 우회하더라도 나머지 레이어가 차단한다.
[ 그림 3: SQL 샌드박스 2중 격리 구조 ]
4.7 트랜잭셔널 상태 보장
fn_submit_result()는 태스크 상태 업데이트, 실행 로그 삽입, 서브태스크 큐잉, 메모리 저장을 단일 트랜잭션으로 처리한다. 워커가 실행 중 종료되면 트랜잭션이 롤백되고 태스크는 이전의 확정된 상태로 남아 재시도 대상이 된다.
운영자가 정책을 변경하는 동시에 에이전트가 스텝을 완료하는 상황에서, 두 연산은 PostgreSQL MVCC에 의해 직렬화된다. 에이전트는 임의의 스텝에서 이전 정책 또는 새 정책 중 하나를 일관되게 적용받으며, 두 정책이 혼합된 상태에 놓이지 않는다.
4.8 멀티 에이전트 조율
오케스트레이터의 delegate 액션은 fn_submit_result() 내에서 동일 트랜잭션으로 서브태스크를 삽입하고 pg_notify로 워커에 알린다. 위임은 원자적이다: 모든 서브태스크가 큐잉되거나 하나도 큐잉되지 않는다. tasks 테이블이 트랜잭셔널 메시지 큐로 기능하여 별도의 메시지 브로커를 대체한다.

5. 평가
ARGO의 핵심 주장을 검증하기 위해 세 가지 실험을 설계한다. 실험 1과 3은 런타임 거버넌스 능력에, 실험 2는 트랜잭셔널 신뢰성에 관한 것이다. 모든 실험은 로컬 Ollama LLM 엔드포인트를 갖춘 단일 노드 PostgreSQL 16 인스턴스에서 수행한다.
5.1 실험 1: 정책 전파 지연
동기
1.2절에서 기존 프레임워크의 한계로 지적한 런타임 정책 수정 불가 문제를, DBaaCP가 어떻게 해결하는지를 정량적으로 검증한다. fn_next_step()이 호출마다 DB에서 정책을 읽는 구조에서 정책 변경이 실제로 다음 사이클에 반영되는지를 측정한다.
실험 설정
	∙	에이전트: executor 타입, 모델: llama3 (로컬 Ollama)
	∙	태스크: 10스텝 반복 루프 (각 스텝: 허용된 뷰 조회 후 요약 반환)
	∙	개입: N번째 스텝에서 system_prompt를 즉시 종료 지시로 UPDATE
	∙	측정: UPDATE 커밋 시점부터 새 정책이 반영된 스텝까지의 경과 시간
	∙	반복: 30회 (개입 시점 2·5·8번째 스텝)
실험 결과
[ 표 4: 정책 전파 지연 결과 — 평균, p95, p99 ]
[ 그림 4: UPDATE 커밋 → 스텝 반영 타임라인 ]
비교
LangGraph, CrewAI는 동일한 정책 변경을 위해 코드 수정과 프로세스 재시작이 필요하다. 3파일 구성의 대표 프로젝트를 기준으로 코드 편집부터 새 정책 반영까지의 시간을 측정하여 비교한다.
5.2 실험 2: 장애 복구와 상태 일관성
동기
거버넌스는 상태가 신뢰 가능할 때만 의미 있다. 워커 장애 시 트랜잭셔널 보장이 상태 손실을 방지하는지, 그리고 태스크가 마지막으로 커밋된 상태에서 재개되는지를 검증한다.
실험 설정
	∙	태스크: 5스텝 순차 추론 체인 (각 스텝이 이전 스텝 출력에 의존)
	∙	장애 주입: 3번째 스텝 실행 중 워커 프로세스 SIGKILL
	∙	복구: 워커 즉시 재시작
	∙	측정: (a) 손실된 스텝 수, (b) kill 후 태스크 상태, (c) 재시작 후 재실행 스텝 수
	∙	반복: 20회
실험 결과
[ 표 5: 복구 결과 — 손실 스텝, 재실행 스텝, 복구 소요 시간 ]
비교
CrewAI와 기본 LangGraph(체크포인트 미사용)는 SIGKILL 발생 시 프로세스 메모리에 있는 상태가 소멸하여 태스크를 처음부터 재실행해야 한다. 공식 문서와 최소 재현 코드를 통해 이 동작을 문서화하여 비교한다.
5.3 실험 3: 미허가 액션의 구조적 차단
동기
OWASP Agentic AI Top 10의 tool misuse, identity abuse는 에이전트가 허가받지 않은 자원에 접근하는 시나리오다. 4.6절에서 설계한 2중 격리 구조가 이를 실제로 차단하는지, 그리고 다양한 우회 시도에 대해서도 일관되게 작동하는지 검증한다.
실험 설정
	∙	agent_A (허용 목록: v_my_tasks만), agent_B (v_my_tasks, v_session_progress)
	∙	두 에이전트 모두 argo_private.sessions 접근을 시도하는 프롬프트 인젝션
	∙	측정: (a) 허용 목록 검사 결과, (b) RBAC 강제 결과
	∙	반복: 에이전트당 20회, 다양한 SQL 표현으로 우회 시도
실험 결과
[ 표 6: 격리 결과 — 에이전트별·대상별 허용/거부 횟수 ]

6. 논의
6.1 한계
LLM 출력 레이어
DBaaCP는 에이전트가 DB 액션을 통해 생성하는 사이드이펙트를 통제한다. LLM이 최종 답변으로 출력하는 텍스트 자체는 이 패턴의 통제 범위 밖이다. 출력 레이어의 안전성은 LLM 수준의 안전 메커니즘이 담당하며, DBaaCP와 상호 보완적으로 작동한다.
워커 신뢰 경계
워커 프로세스는 신뢰 경계다. 침해된 워커가 LLM 호출 없이 조작된 결과를 fn_submit_result()에 제출할 수 있다. ARGO는 제출이 이루어지는 DB 역할을 인증하지만, 제출 내용의 진위를 검증하지는 않는다. 워커와 데이터베이스 사이의 채널 보안(TLS, 네트워크 격리)은 배포 환경의 책임이다.
DB 함수 요구사항
DBaaCP 패턴은 컨트롤 로직이 DB 함수 안에 있을 것을 요구한다. 이는 저장 프로시저를 지원하지 않는 데이터베이스가 이 패턴을 구현할 수 없음을 의미하며, DB 선택의 제약이 된다.
6.2 향후 연구
첫째, 자동화된 정책 트리거: 실행 로그를 관찰하는 모니터링 에이전트가 이상 징후 감지 시 운영자 개입 없이 자동으로 정책을 수정한다. 1.1절에서 제기한 문제를 자동화된 방식으로 해결하는 방향이다.
둘째, 정책 감사 추적: 모든 정책 변경이 DB 연산이므로 타임스탬프와 운영자 신원을 기록하여 EU AI Act, NIST IR 8596이 요구하는 감사 이력을 완전하게 제공할 수 있다.
셋째, 다중 백엔드 구현: 표 2에서 제시한 구현 요구사항을 기준으로 Oracle, MS SQL Server에 DBaaCP 패턴을 구현하고, 백엔드별 트레이드오프를 체계화한다.
넷째, LLM 출력 레이어 통합: ARGO의 구조적 격리와 출력 레벨 분류기를 결합하여 6.1절의 한계를 해결하는 통합 거버넌스 스택을 구성한다.

7. 결론
AI 에이전트가 프로덕션 시스템에 배포되면서 새로운 운영 문제가 발생하고 있다. 에이전트는 실행 중에도 예측하지 못한 행동을 보일 수 있으며, 이때 운영자는 재배포 없이 즉각 개입할 수단이 필요하다. 기존 프레임워크는 이 문제를 해결하지 않는다. 정책이 코드에 있는 한 런타임 개입은 재배포를 의미하기 때문이다.
본 논문이 제안한 DB as a Control Plane(DBaaCP) 패턴은 에이전트 정책을 데이터베이스 레코드로 외재화하고, 정책의 해석과 적용을 DB 함수 안에 두며, 모든 상태 전이를 트랜잭션으로 보장함으로써 이 문제를 해결한다. LLM은 컨트롤 플레인의 지시를 실행하는 엔진이고, 데이터베이스가 에이전트의 행동 범위를 결정하는 컨트롤 타워다. 이 구조에서 운영자는 실행 중인 에이전트의 행동을 SQL 한 줄로 즉시, 원자적으로 변경할 수 있다.
ARGO는 이 패턴의 PostgreSQL 레퍼런스 구현이다. 패턴 자체는 Oracle, MS SQL Server 등 요구사항을 만족하는 엔터프라이즈 데이터베이스로 이식 가능하며, 조직이 기존에 보유한 DB 인프라 위에서 에이전트 거버넌스를 구현할 수 있는 기반을 제공한다.
에이전트 거버넌스는 나중에 얹는 부가 기능이 아니라 에이전트가 실행되는 인프라 안에 내장되어야 한다. DBaaCP는 그 방향의 구체적 아키텍처 패턴이다.

참고문헌
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

