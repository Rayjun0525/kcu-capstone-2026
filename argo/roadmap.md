# ARGO v1.0 로드맵

> **DB as a Control Plane 패턴의 프로덕션 레디 오픈소스 구현을 향한 여정**
> 
> 문서 버전: 1.0 (계획 단계)
> 대상: 커뮤니티 공개 + Docker Compose / Kubernetes 원클릭 프로비저닝

-----

## 0. 이 문서의 목적과 원칙

### 0.1 왜 이 로드맵이 필요한가

현재 ARGO는 **캡스톤 논문의 PoC(Proof of Concept)** 수준이다. DBaaCP 패턴의 핵심 가설(런타임 정책 전파, 트랜잭셔널 장애 복구, 구조적 접근 차단)은 실험 E1~E3으로 검증되었다. 그러나 “실험에서 동작하는 것”과 “실제 운영 환경에서 신뢰할 수 있는 것” 사이에는 큰 간극이 있다.

이 로드맵은 그 간극을 체계적으로 메우는 계획이다. 최종 상태는 다음과 같다.

```bash
# 로컬 개발자
docker compose up

# Kubernetes 환경
helm install argo argo/argo
```

이 두 명령어로 ARGO를 바로 띄울 수 있는 것이 v1.0의 정의다.

### 0.2 초기 아이디어의 보호

이 로드맵 전체에서 **절대 변경하지 않을 원칙**이 있다. v1.0 개발 과정에서 편의를 위해 이 원칙을 희석시키려는 유혹이 반복적으로 나타날 것이다. 명시해둔다.

**불변 원칙:**

1. **컨트롤 로직은 DB 함수 안에 있다.** — 워커에 의사결정 로직을 옮기지 않는다. 성능 최적화 명목으로도 금지.
1. **정책은 데이터베이스 레코드다.** — 설정 파일, YAML, 환경변수로 정책을 분산시키지 않는다.
1. **모든 상태 전이는 단일 트랜잭션이다.** — 2PC, saga, eventual consistency로 도망가지 않는다.
1. **에이전트 격리는 DB RBAC + 뷰로 달성한다.** — 애플리케이션 레벨 권한 체크에 의존하지 않는다.
1. **외부 인프라 의존을 최소화한다.** — “PostgreSQL 하나면 된다”는 약속을 깨지 않는다. 필수 인프라 추가는 반드시 정당화되어야 한다.

**변경 가능한 것:**

- 구현 세부사항 (스키마 컬럼 추가, 함수 시그니처, 인덱스 전략)
- 배포 방식 (Docker, K8s, Operator)
- 관측 도구 (Prometheus, OpenTelemetry)
- LLM provider 추상화 방식
- 워커 언어/프레임워크

### 0.3 로드맵 구조

v1.0에 도달하기까지 5단계(Phase 0~4)로 나눈다. 각 단계는 다음 단계의 전제조건을 형성하며, 순서가 의미를 가진다.

- **Phase 0 — 거버넌스 기반 (1~2주)**: 라이선스, SemVer, 문서 구조
- **Phase 1 — 코어 안정화 (6~8주)**: 보안 기본선, 마이그레이션, LLM 추상화
- **Phase 2 — 패키징 (4~6주)**: Docker Compose, Helm Chart, 호환성 검증
- **Phase 3 — 운영성 확보 (4~6주)**: 관측 가능성, HITL, Tool RAG
- **Phase 4 — 오픈소스 런칭 (지속)**: 문서, 벤치마크, 커뮤니티

총 4~6개월 예상. 1인 기준 파트타임 작업 가정.

-----

## Phase 0 — 거버넌스 기반 (Foundation)

**목표:** 프로젝트가 오픈소스로 살아남기 위한 법적·구조적 기반을 세운다.

### 0.1 라이선스 전략 재검토

현재 MIT 라이선스는 최대한의 확산을 보장하지만, 클라우드 업체가 ARGO를 그대로 매니지드 서비스로 포장해 판매하는 것을 막을 수 없다. DBaaCP 패턴이 차별적 가치를 가질수록 이 리스크는 커진다.

**검토 대상:**

- **Apache 2.0**: 특허 방어 조항 포함. 엔터프라이즈 채택에 유리. 여전히 상업적 재판매 허용.
- **BSL 1.1 (Business Source License)**: MariaDB, HashiCorp 등이 채택. 일정 기간(보통 3~4년) 상업적 경쟁을 제한하고 이후 Apache 2.0으로 전환. 커뮤니티 반감 있음.
- **AGPL v3**: 클라우드 SaaS로 제공 시 소스 공개 강제. 엔터프라이즈 채택 저해. Grafana, MongoDB(구), Elasticsearch(구)가 겪은 논란의 원인.

**결정 포인트:** v1.0 출시 전까지 한 번만 결정할 수 있다. 이후 변경은 기여자 동의가 필요해 사실상 불가능하다.

**권장 방향:** 초기 커뮤니티 확산이 최우선이라면 **Apache 2.0**. 상업적 보호가 더 중요하다면 **BSL 1.1**. 본 로드맵은 Apache 2.0을 가정하되, Phase 0 종료 전 최종 결정을 요구한다.

### 0.2 Semantic Versioning 정책 수립

DB 함수 시그니처, 테이블 스키마, Extension 업그레이드 경로에 대한 SemVer 약속을 명문화한다.

**정의:**

- **MAJOR**: 공개 함수 시그니처 변경, 테이블 스키마 breaking change, 마이그레이션 경로 불연속
- **MINOR**: 새 함수 추가, 새 테이블 추가, 기존 동작 호환 유지
- **PATCH**: 버그 수정, 성능 개선, 문서 수정

**공개 API 경계 명확화:**

- **Public (SemVer 준수)**: `argo_public` 스키마의 모든 함수와 뷰
- **Internal (언제든 변경 가능)**: `argo_private` 스키마

사용자는 `argo_private`에 직접 접근하지 않도록 문서에 명시한다.

### 0.3 Deprecation 정책

기능 제거 시 최소 두 개의 MINOR 버전에 걸쳐 deprecation 경고를 유지한다. DB 함수의 경우 `RAISE WARNING` + 문서화로 예고한다.

### 0.4 문서 구조 확립

Phase 1 시작 전에 다음 문서 골격을 만든다. 내용은 Phase 진행 중 채운다.

```
docs/
├── getting-started/          # 5분 안에 실행하는 경험
├── concepts/                 # DBaaCP 패턴 설명, 논문 요약
├── reference/                # API, 스키마, 함수 레퍼런스
├── guides/                   # How-to (예: 에이전트 만들기, Tool 등록)
├── operations/               # 운영자용 (백업, 모니터링, 업그레이드)
└── contributing/             # 기여자용
```

### 0.5 기여 인프라

- **CODE_OF_CONDUCT.md** — Contributor Covenant 기반
- **CONTRIBUTING.md** — 이슈 템플릿, PR 프로세스
- **GOVERNANCE.md** — 의사결정 구조 (초기엔 BDFL, 이후 모델 명시)
- **SECURITY.md** — 취약점 신고 경로, PGP 키 (자체 운영 안 해도 email 제공)

### Phase 0 완료 기준

- [ ] 라이선스 확정 및 LICENSE 파일 갱신
- [ ] `docs/` 디렉토리 골격 존재
- [ ] CONTRIBUTING, CODE_OF_CONDUCT, GOVERNANCE, SECURITY 파일 존재
- [ ] GitHub Issue/PR 템플릿 존재
- [ ] SemVer 정책이 README에 명시됨

-----

## Phase 1 — 코어 안정화 (Core Hardening)

**목표:** 현재 PoC 코드를 프로덕션에서 신뢰할 수 있는 수준으로 끌어올린다. 외부 공개 전 반드시 해결해야 할 보안·안정성 문제를 처리한다.

### 1.1 보안 기본선 확립

논문의 실험 E3는 SQL 샌드박스 검증이었지만, 실제 프로덕션 환경의 공격면은 훨씬 넓다.

#### 1.1.1 Secret 관리

**현재 문제:** LLM API Key가 어디에 어떻게 저장되는지 명세가 없다.

**v1.0 요구사항:**

- 워커는 API Key를 환경변수에서 읽는 것을 기본으로 하되, **Secret Provider 추상화**를 갖는다.
- 지원 대상: 환경변수, HashiCorp Vault, AWS Secrets Manager, GCP Secret Manager, Kubernetes Secrets.
- DB에 평문으로 저장하지 않는 것을 원칙으로 한다. `llm_configs` 테이블에는 Secret 참조만 저장한다 (예: `vault://path/to/key`, `env://OPENAI_API_KEY`).

#### 1.1.2 Prompt Injection 방어 레이어

실험 E3는 에이전트 **크리덴셜 탈취** 시나리오를 다뤘다. 별개의 위협인 **프롬프트 인젝션**(사용자 입력에 악의적 지시가 포함되어 에이전트가 악용되는 공격)은 다루지 않았다.

**v1.0 요구사항:**

- `execution_logs`의 사용자 입력 블록을 LLM에 전달할 때 명확한 구분자(delimiter)로 감싸는 **표준 프롬프트 패턴**을 `fn_next_step()`에 내장한다.
- 에이전트가 생성한 DB 액션이 사용자 입력을 그대로 SQL로 쓰는 것을 금지하는 정적 검사를 `fn_execute_sql()`에 추가한다.
- 이 방어가 완벽하지 않다는 점을 문서에 명시한다. DBaaCP의 핵심 방어선은 구조적 격리(RBAC)이며, 프롬프트 인젝션 방어는 보조 수단임을 분명히 한다.

#### 1.1.3 감사 로그 변조 방지

**현재 문제:** `execution_logs`는 일반 테이블이라 DB 관리자가 수정/삭제할 수 있다. EU AI Act와 NIST IR 8596이 요구하는 감사 요구사항을 충족하지 못한다.

**v1.0 요구사항:**

- `execution_logs`에 대해 UPDATE/DELETE를 차단하는 트리거를 기본 제공한다.
- **해시 체인(hash chain)** 도입: 각 로그 엔트리에 이전 엔트리의 해시를 포함시켜 변조 시 탐지 가능하게 한다.
- 변조 방지가 절대적이지 않다는 점(슈퍼유저는 트리거를 우회할 수 있음)을 문서에 명시하고, 외부 감사 저장소로의 내보내기 기능을 제공한다.

#### 1.1.4 워커 인증

**현재 문제:** 워커가 어떻게 DB에 인증하는지, 워커와 에이전트 Role의 관계가 불명확하다.

**v1.0 요구사항:**

- 워커는 **system role**로 접속하고, `fn_next_step()` 내부에서 해당 태스크의 에이전트 Role로 `SET ROLE`을 수행한다.
- 워커 자체는 SCRAM-SHA-256 또는 client certificate로 인증한다.
- 워커 인증 정보는 Secret Provider로 관리한다.

### 1.2 마이그레이션 체계

**현재 문제:** `argo--0.1.sql` 단일 파일만 있다면, v0.1 → v0.2 업그레이드 시 다운타임 없는 마이그레이션이 불가능하다.

**v1.0 요구사항:**

- PostgreSQL Extension의 표준 마이그레이션 파일 명명 규칙 준수: `argo--0.1--0.2.sql` 형태의 `ALTER EXTENSION argo UPDATE` 지원.
- 모든 스키마 변경은 **online migration**을 원칙으로 한다. 대규모 테이블에 대한 `ALTER TABLE ADD COLUMN` 등은 기본값 없이 수행하고 백필을 별도 단계로 분리한다.
- 마이그레이션 실패 시 롤백 경로를 명시한다. 일부 변경은 본질적으로 비가역적임을 문서화한다.

### 1.3 LLM Provider 추상화

**현재 문제:** 논문 실험은 로컬 Ollama로 수행되었다. 커뮤니티가 쓰려면 주요 provider를 모두 지원해야 한다.

**v1.0 요구사항:**

- 워커 레벨에서 **LiteLLM을 기본 어댑터**로 채택. LiteLLM이 OpenAI, Anthropic, Google, Bedrock, Azure, Ollama, vLLM을 통합 지원한다.
- `llm_configs` 테이블에 provider, model, endpoint, 토큰 한도 등을 저장한다. 구체적 파라미터는 `jsonb` 컬럼으로 확장성 확보.
- LiteLLM 의존이 싫은 사용자를 위해 어댑터 인터페이스를 노출하고, 직접 구현 가능하게 한다.

**원칙 확인:** LLM 호출은 워커(데이터 플레인)에서 일어난다. 이는 불변 원칙에 위배되지 않는다. DB는 “어떤 모델로 호출할지”를 명세하고, 워커는 그 명세를 따를 뿐이다.

### 1.4 워커 안정성

#### 1.4.1 Graceful Shutdown

**현재 문제:** 실험 E2는 SIGKILL 시 복구를 검증했다. 일반 운영에서는 SIGTERM으로 graceful shutdown이 기본이어야 한다.

**v1.0 요구사항:**

- SIGTERM 수신 시 현재 진행 중인 태스크를 완료하고 새 태스크를 받지 않는다.
- 완료가 불가능한 경우(예: LLM 호출 타임아웃) 설정된 grace period 후 강제 종료. 이 경우 트랜잭션 롤백으로 상태 일관성은 유지된다.

#### 1.4.2 동시성 및 워커 풀

**현재 문제:** 여러 워커가 동시에 실행될 때 동일 태스크를 중복 처리할 위험이 있다.

**v1.0 요구사항:**

- 태스크 획득 쿼리는 `SELECT ... FOR UPDATE SKIP LOCKED` 패턴을 사용한다.
- `fn_claim_next_task()` 공개 함수를 제공하여 워커가 원자적으로 태스크를 획득하게 한다.
- 워커 풀 내 자체 백프레셔: 처리 중인 태스크 수가 한계를 초과하면 신규 획득을 중단한다.

#### 1.4.3 에러 분류와 재시도

**현재 문제:** 모든 에러를 동일하게 처리하면 일시적 장애(rate limit, 네트워크)와 영구 장애(스키마 불일치, 권한 오류)를 구분할 수 없다.

**v1.0 요구사항:**

- 에러 분류 체계 정의: `RETRYABLE`, `NON_RETRYABLE`, `REQUIRES_HUMAN`.
- `agent_profiles.max_retries`가 재시도 한도를 결정하되, 에러 분류에 따라 재시도 여부 결정.
- 영구 장애 시 `human_approvals` 또는 전용 `dead_letter_queue` 테이블로 태스크를 격리한다.

### 1.5 테스트 체계

**현재 문제:** 실험 스크립트는 있으나 회귀 방지를 위한 자동화 테스트가 불명확하다.

**v1.0 요구사항:**

- **pgTAP**으로 DB 함수 단위 테스트. 각 공개 함수는 최소 3개 테스트(성공, 권한 거부, 잘못된 입력).
- **통합 테스트**: Docker Compose로 PostgreSQL + 워커를 띄우고 end-to-end 시나리오 실행.
- **보안 회귀 테스트**: 실험 E3의 15가지 우회 패턴을 CI에 포함하여 모든 PR에서 검증.
- CI는 GitHub Actions로 구성. 매트릭스 테스트로 PostgreSQL 14/15/16/17 지원 검증.

### 1.6 데이터 라이프사이클

**현재 문제:** `execution_logs`는 무한 증가한다. 장기 운영 시 성능 저하 불가피.

**v1.0 요구사항:**

- `execution_logs`와 `tasks` 테이블을 **월별 파티셔닝**하는 옵션 제공.
- 오래된 파티션을 S3 등 외부 저장소로 내보내는 CLI 유틸리티 제공 (v1.0에는 S3만 지원, 추후 확장).
- 기본 보관 정책: `execution_logs` 90일, `tasks` 1년. 설정 가능.

### Phase 1 완료 기준

- [ ] 모든 LLM API Key가 Secret Provider를 통해 관리됨
- [ ] 감사 로그 변조 방지 트리거 및 해시 체인 구현
- [ ] ALTER EXTENSION 기반 업그레이드 경로 검증
- [ ] LiteLLM 어댑터로 최소 3개 provider(OpenAI, Anthropic, Ollama) 검증
- [ ] SKIP LOCKED 기반 동시 워커 실행 검증
- [ ] pgTAP 테스트 커버리지 주요 공개 함수 100%
- [ ] GitHub Actions CI가 PostgreSQL 15, 16, 17에서 통과

-----

## Phase 2 — 패키징 (Distribution)

**목표:** “한 줄로 띄운다”는 약속을 실현한다. Docker Compose와 Helm Chart를 프로덕션 레디 수준으로 제공한다.

### 2.1 관리형 DB 호환성 사전 검증

이 검증은 Phase 2의 **첫 번째 작업**이다. 결과에 따라 이후 배포 전략이 달라진다.

**검증 대상:**

- AWS RDS (PostgreSQL)
- Google Cloud SQL (PostgreSQL)
- Azure Database for PostgreSQL
- Supabase
- Neon
- Aiven

**검증 항목:**

1. `CREATE EXTENSION argo` 가능 여부 — 많은 관리형 DB가 Extension 화이트리스트 정책을 가진다.
1. `pgvector` 확장 지원 여부 — Phase 3의 Tool RAG 전제조건.
1. `CREATE ROLE`, `SET ROLE` 권한 — DBaaCP의 Role 기반 격리의 전제.
1. 저장 프로시저 내에서 `SET ROLE` 가능 여부.

**결정 포인트:**

- 주요 관리형 DB에서 Extension 설치가 막혀 있다면, **Extension 없이 동작하는 스키마 배포 모드**를 대안으로 제공해야 한다 (`CREATE EXTENSION argo` 대신 `\i argo_install.sql`).
- 이 경우 업그레이드 경로가 복잡해지므로, Phase 1의 마이그레이션 체계를 두 모드 모두 지원하도록 재설계 필요.

### 2.2 Docker Compose

**설계 원칙:**

- `docker compose up` 한 줄로 모든 것이 실행된다.
- 프로파일로 선택적 구성 요소 활성화 (`docker compose --profile observability up`).
- 데이터 영속성 기본 설정 (`volumes` 사용).

**구성:**

|서비스            |필수/선택                      |역할                                       |
|---------------|---------------------------|-----------------------------------------|
|`postgres`     |필수                         |pgvector 포함 커스텀 이미지, argo extension 사전 설치|
|`migrate`      |필수                         |초기 기동 시 `CREATE EXTENSION argo` 실행 후 종료  |
|`worker`       |필수                         |기본 1개, `--scale worker=N`으로 확장           |
|`litellm-proxy`|선택 (profile: llm-proxy)    |LiteLLM 중앙 프록시                           |
|`prometheus`   |선택 (profile: observability)|메트릭 수집                                   |
|`grafana`      |선택 (profile: observability)|대시보드, JSON 사전 임포트                        |
|`admin-ui`     |선택 (profile: admin)        |Phase 3에서 추가                             |

**설정:**

- `.env.example` 제공. `DB_PASSWORD`, `OPENAI_API_KEY` 등 명확한 예시.
- `docker-compose.override.yml`로 개발 환경 커스터마이징 지원.

### 2.3 Helm Chart

**설계 원칙:**

- `helm install argo argo/argo` 한 줄로 동작한다.
- `values.yaml`의 모든 설정에 주석 제공.
- 외부 PostgreSQL 사용 모드와 내장 PostgreSQL 모드 양쪽 지원.

**구성:**

```
charts/argo/
├── Chart.yaml
├── values.yaml
├── values.schema.json           # values 검증
├── templates/
│   ├── postgres/                # 내장 모드 시에만 활성화
│   │   ├── statefulset.yaml
│   │   └── service.yaml
│   ├── migration-job.yaml       # CREATE EXTENSION 실행
│   ├── worker-deployment.yaml
│   ├── worker-hpa.yaml          # 수평 오토스케일링
│   ├── secret-db.yaml           # External Secrets Operator 연동 옵션
│   ├── configmap-worker.yaml
│   ├── servicemonitor.yaml      # Prometheus Operator 연동
│   └── grafana-dashboard.yaml   # ConfigMap으로 제공
└── README.md
```

**주요 values:**

- `postgresql.mode`: `embedded` 또는 `external`
- `postgresql.external.existingSecret`: 외부 DB 사용 시 크리덴셜 참조
- `worker.replicas`: 기본 2
- `worker.llm.provider`: `openai`, `anthropic`, `ollama`, `litellm`
- `worker.llm.secretRef`: Secret 참조
- `observability.enabled`: Prometheus/Grafana 리소스 생성 여부
- `persistence.retentionDays`: 자동 정리 설정

**고려사항:**

- Managed DB 사용자를 위해 migration-job이 Extension 설치 권한 없이도 동작하는 모드 필요 (Phase 2.1 결과 반영).
- StatefulSet 대신 **CloudNativePG** 같은 Operator 연동 옵션도 제공 검토.

### 2.4 Helm Chart 검증

**검증 환경:**

- `kind` (로컬 K8s)
- `k3d` (경량 K8s)
- AWS EKS (실제 매니지드 환경)
- GKE 또는 AKS 중 하나

**검증 시나리오:**

1. 완전 새 설치 → 샘플 에이전트 실행 → 태스크 완료 확인
1. 버전 업그레이드 (v1.0.0 → v1.0.1) → 데이터 보존 확인
1. Worker 수평 확장 (`kubectl scale deployment/argo-worker --replicas=5`)
1. PostgreSQL Pod 재시작 시 복구 시간 측정
1. 완전 삭제 → 재설치 시 데이터 복원 가능 여부

### 2.5 이미지 공급망 보안

**v1.0 요구사항:**

- 모든 Docker 이미지는 **multi-stage build**로 최소화.
- **Distroless** 또는 Alpine 기반.
- **SBOM(Software Bill of Materials)** 생성: CycloneDX 또는 SPDX 포맷.
- **Cosign**으로 이미지 서명.
- **Trivy** 스캔을 CI에 통합.
- 이미지는 GitHub Container Registry(ghcr.io)에 배포.

### Phase 2 완료 기준

- [ ] 관리형 DB 최소 3개에서 Extension 설치 검증 완료
- [ ] `docker compose up` 5분 이내 완전 동작
- [ ] Helm chart가 kind, EKS 양쪽에서 검증됨
- [ ] 모든 이미지에 SBOM 및 서명 존재
- [ ] `values.yaml`의 모든 설정에 주석 존재
- [ ] Getting Started 문서로 신규 사용자가 10분 이내 첫 에이전트 실행 가능

-----

## Phase 3 — 운영성 확보 (Operability)

**목표:** 운영자가 ARGO를 블랙박스가 아닌 투명한 시스템으로 다룰 수 있게 한다. 장기 실행 환경에서 필수적인 기능을 완성한다.

### 3.1 관측 가능성 (Observability)

#### 3.1.1 메트릭

**v1.0 요구사항:**

워커가 Prometheus 메트릭 엔드포인트(`/metrics`)를 노출한다.

**핵심 메트릭:**

- `argo_tasks_total{status, agent_role}` — counter
- `argo_task_duration_seconds{agent_role}` — histogram
- `argo_step_duration_seconds{agent_role, phase}` — histogram (phase: `fn_next_step`, `llm_call`, `fn_submit_result`)
- `argo_llm_tokens_total{provider, model, type}` — counter (type: `input`, `output`)
- `argo_llm_cost_usd_total{provider, model}` — counter
- `argo_policy_changes_total{agent_role}` — counter (실험 E1의 정책 변경 추적)
- `argo_security_blocks_total{block_type}` — counter (allowlist 차단 등)
- `argo_worker_active_tasks` — gauge

**DB 내부 메트릭** (별도 exporter로 수집):

- 테이블 크기, 파티션 상태
- 활성 세션/태스크 수
- 가장 오래된 running 태스크의 age (워커 장애 조기 탐지)

#### 3.1.2 로깅

**v1.0 요구사항:**

- 모든 워커 로그는 JSON 구조화 로그.
- 필드 표준: `timestamp`, `level`, `trace_id`, `session_id`, `task_id`, `agent_role`, `event`, `message`, `error`.
- DB 함수 내부에서도 `RAISE NOTICE` 대신 전용 `fn_log()` 함수로 구조화 로그를 `execution_logs`에 남긴다.

#### 3.1.3 분산 추적

**v1.0 요구사항:**

- OpenTelemetry 지원. 워커가 OTLP로 trace를 송출.
- trace 경계: `fn_next_step` 호출 → LLM 요청 → `fn_submit_result`.
- 선택 사항(기본 비활성화), 활성화 시 Jaeger나 Tempo로 수집.

#### 3.1.4 Grafana 대시보드

**v1.0 요구사항:**

- 다음 대시보드를 JSON으로 제공:
1. **Overview** — 전체 시스템 건강 상태 (태스크 처리량, 에러율, 활성 에이전트)
1. **Agent Performance** — 에이전트별 지연, 토큰 사용량, 비용
1. **Security** — 차단된 액션, 정책 변경 이력, 인증 실패
1. **LLM Economics** — provider별 토큰, 비용, 지연
- 모든 대시보드는 Helm Chart에 ConfigMap으로 포함되어 자동 프로비저닝.

### 3.2 Human-in-the-Loop (HITL) 인터페이스

**현재 문제:** 스키마에 `human_approvals`, `human_interventions`가 있지만 실제 휴먼 인터페이스가 없다.

**v1.0 요구사항:**

#### 3.2.1 Approval 알림 채널

- **Webhook** (기본): 승인 요청 생성 시 설정된 URL로 POST.
- **Slack 연동**: Slack Block Kit으로 인터랙티브 승인 UI.
- **Email** (선택): SMTP 기반 링크형 승인.
- 채널은 플러그인 방식으로 확장 가능.

#### 3.2.2 Admin UI (최소 기능 셋)

전체 운영 UI를 만드는 것은 v1.0 범위를 초과한다. 대신 **최소한의 승인 처리 UI**만 포함한다.

- 간단한 Next.js/Vue 앱, DB와 직접 통신 (backend-less).
- 기능:
  - Pending approvals 목록 및 상세
  - Approve/Reject + 이유 입력
  - 최근 intervention 이력
- 전체 UI는 Phase 4 또는 v1.1로 미룬다.

#### 3.2.3 CLI 도구

`argoctl` CLI 제공. 운영자가 SQL 직접 작성 없이 정책을 변경할 수 있게 한다.

**v1.0에 포함할 명령:**

- `argoctl agent list` / `agent describe <name>`
- `argoctl policy update <agent> --prompt <file>` — 정책 변경
- `argoctl policy history <agent>` — 변경 이력
- `argoctl task list --status running`
- `argoctl task describe <id>`
- `argoctl task cancel <id>`
- `argoctl approval list` / `approval grant <id>` / `approval deny <id>`
- `argoctl tool list` / `tool register -f tool.yaml`

**원칙 확인:** CLI는 DB에 대해 일반 SQL을 실행할 뿐이다. 정책의 진실 공급원(source of truth)은 여전히 DB다. CLI는 편의 레이어에 불과하다.

### 3.3 Tool RAG 통합

Phase 3에 배치한 이유: 초기 사용자는 툴 1~5개로 시작한다. 이 단계에서는 Tool RAG 없이도 충분하다. 그러나 운영 환경에서 툴이 수십 개로 늘어날 때 필수가 된다.

**v1.0 요구사항:**

- `tool_registry` 테이블에 `description_embedding vector(1536)`, `usage_examples text` 컬럼 추가.
- `fn_search_tools(agent_id, query_embedding, top_k)` 함수 제공.
  - 에이전트의 tool permission과 JOIN하여 권한 있는 툴만 반환.
  - pgvector 코사인 유사도 기반.
- `fn_next_step()` 시그니처에 `query_embedding` 옵셔널 파라미터 추가 (하위 호환).
  - `NULL`이면 기존처럼 모든 허용 툴 반환.
  - 값이 있으면 TOP-K만 반환.
- 워커는 현재 태스크 컨텍스트(최근 N턴 + 현재 입력)를 임베딩하여 전달.
- 임베딩 provider도 LLM provider 추상화에 포함 (LiteLLM 지원).

**인덱스 전략:**

- 툴 수가 적을 때는 인덱스 없이 시퀀셜 스캔.
- 100개 이상부터 IVFFlat 또는 HNSW 인덱스.
- 자동 인덱스 생성은 하지 않고, 문서로 안내 (운영자 결정 영역).

**이 기능이 왜 불변 원칙과 합치하는가:**

- 임베딩은 DB에 저장되고 검색도 DB 안에서 일어난다.
- 워커는 쿼리 임베딩을 계산해 DB에 건네줄 뿐 의사결정을 하지 않는다.
- 툴 선택 로직은 SQL 함수 안에 있다.

### 3.4 백업 및 복구

**v1.0 요구사항:**

- 운영 가이드에 PostgreSQL 표준 백업 절차 문서화: `pg_dump`, WAL 아카이빙, PITR.
- Helm Chart에 CloudNativePG Operator 연동 예시 포함.
- 재해 복구 시나리오별 절차 문서: 워커 장애, DB 장애, 데이터 손상.

### Phase 3 완료 기준

- [ ] Prometheus 메트릭 엔드포인트 노출 및 핵심 메트릭 수집 검증
- [ ] Grafana 대시보드 4종이 Helm으로 자동 프로비저닝됨
- [ ] Slack 승인 워크플로우 end-to-end 검증
- [ ] `argoctl` CLI가 주요 운영 시나리오를 커버
- [ ] Tool RAG 기반 툴 검색이 100개 툴 환경에서 p95 < 50ms
- [ ] 재해 복구 시나리오 문서화 및 1회 이상 시뮬레이션

-----

## Phase 4 — 오픈소스 런칭 (Launch & Sustain)

**목표:** ARGO를 살아있는 오픈소스 프로젝트로 전환한다. 코드 이상의 것이 필요하다.

### 4.1 문서 완성

#### 4.1.1 Getting Started (최우선)

신규 사용자가 **10분 이내** 첫 에이전트를 실행할 수 있어야 한다. 이것은 오픈소스 성공의 1차 관문이다.

**목표 경험:**

1. Docker Compose 다운로드 및 실행 (2분)
1. OpenAI API Key 설정 (1분)
1. 예제 에이전트 정의 파일 복사 (2분)
1. 에이전트 실행 명령 (1분)
1. 결과 확인 및 다음 단계 안내 (1분)

#### 4.1.2 Concepts 문서

DBaaCP 패턴 자체에 대한 심층 설명. 논문을 기반으로 하되 엔지니어 친화적인 언어로 재작성.

- Why Control Plane / Data Plane separation?
- What makes ARGO different from LangGraph/CrewAI?
- When should you *not* use ARGO? (중요: 모든 상황에 맞는 도구가 아님을 명시)

#### 4.1.3 Architecture Deep Dive

- 전체 시스템 다이어그램
- 각 테이블의 역할과 관계 (ERD)
- `fn_next_step` / `fn_submit_result`의 상세 동작
- 보안 모델 (3중 격리: RBAC + Allowlist + Application-level)
- Trust boundary 명시

#### 4.1.4 Reference

- SQL 공개 함수 전체 레퍼런스 (시그니처, 파라미터, 반환, 예제)
- 공개 뷰 레퍼런스
- 메트릭 레퍼런스
- 환경변수 레퍼런스
- Helm values 레퍼런스 (자동 생성)

#### 4.1.5 Operations Guide

- 설치 및 업그레이드
- 백업 및 복구
- 보안 강화 체크리스트
- 성능 튜닝
- 트러블슈팅 (일반적인 문제와 해결)

### 4.2 벤치마크 저장소

**현재 문제:** 논문의 실험 E1~E3는 학술적 검증이지 마케팅 자료가 아니다. 잠재 사용자는 “왜 LangGraph가 아닌 ARGO?“에 대한 답을 원한다.

**v1.0 요구사항:**

별도 리포 `argo-benchmarks`를 운영한다.

**벤치마크 항목:**

1. **정책 전파 지연** — ARGO vs LangGraph (재시작 포함)
1. **장애 복구 시간** — SIGKILL 후 재개 지점 및 손실 스텝
1. **동시 에이전트 확장성** — 1, 10, 100 에이전트 처리량
1. **툴 100개 환경에서의 선택 정확도** — Tool RAG on/off 비교
1. **보안 회귀 테스트** — 15가지 우회 패턴 차단율

**원칙:**

- 재현 가능성이 최우선. 모든 벤치마크는 Docker Compose로 실행 가능.
- 결과는 CI에서 주기적으로 갱신.
- 경쟁 프레임워크를 폄하하지 않는다. “이런 문제에서는 ARGO가 유리하다”를 정직하게 보여준다.

### 4.3 예제 에이전트 카탈로그

단순한 Hello World를 넘어, 실제 유스케이스를 보여주는 예제 3~5개.

**후보:**

1. **Data Analyst Agent** — 샘플 DB에 대해 SQL로 분석 수행. DBaaCP의 SQL 샌드박스 시연.
1. **Multi-Agent Workflow** — Researcher → Writer → Reviewer 체인. 태스크 위임 시연.
1. **Human-in-the-Loop Approval Agent** — 민감한 액션 전 승인 요청. HITL 시연.
1. **Runtime Policy Change Demo** — 실행 중 페르소나 변경. 실험 E1 재현 가능한 형태로.

각 예제는 독립된 디렉토리로 제공. README, 에이전트 정의 SQL, 실행 스크립트 포함.

### 4.4 커뮤니티 인프라

#### 4.4.1 의사소통 채널

- **GitHub Discussions** — Q&A, 기능 제안 (기본)
- **Discord 또는 Slack** — 실시간 대화 (2차)
- **Mailing list** — 보안 공지용 (필수)

#### 4.4.2 정기 릴리즈 리듬

- **Patch** (v1.0.x): 필요 시 수시
- **Minor** (v1.x.0): 6~8주 주기
- **Major**: 1년 이상 간격

각 릴리즈는 명확한 릴리즈 노트, 마이그레이션 가이드, 블로그 포스트 동반.

#### 4.4.3 기여자 온보딩

- **Good first issue** 라벨 상시 유지 (최소 10개)
- **CONTRIBUTING.md** 에 개발 환경 셋업, 테스트 실행 방법 명시
- PR에 대한 SLA: 1주 이내 첫 리뷰

#### 4.4.4 국제화

한국 프로젝트지만 커뮤니티 공개는 영어 우선.

- 모든 코드 주석, 커밋 메시지, 문서는 영어.
- 한국어 문서는 별도 `ko/` 디렉토리로 커뮤니티 번역 허용.
- 논문은 별도 자산으로 유지 (프로젝트 정체성의 일부).

### 4.5 런칭 전략

#### 4.5.1 Soft Launch (v0.9)

v1.0 직전 v0.9로 먼저 공개.

- 초기 사용자 10~20명 확보 (지인, 관심 커뮤니티)
- 피드백 수집 및 critical 이슈 해결
- 4~6주 진행

#### 4.5.2 Public Launch (v1.0)

- **Hacker News Show HN** 게시
- **r/programming, r/LocalLLaMA, r/PostgreSQL** 등 관련 서브레딧
- 한국 커뮤니티: OKKY, GeekNews
- 기술 블로그 포스트: DBaaCP 패턴 소개 + ARGO 소개
- **논문 공개**: arXiv 또는 개인 블로그. 프로젝트의 지적 자산임을 명확히.

### Phase 4 완료 기준 (v1.0 출시)

- [ ] Getting Started가 첫 방문자 10분 이내 성공 기준 충족 (5명 이상 사용자 테스트)
- [ ] 문서 4개 영역(Concepts, Reference, Operations, Guides) 완성
- [ ] 벤치마크 저장소 운영 중, 주요 지표 경쟁 프레임워크 대비 제시
- [ ] 예제 에이전트 3개 이상 동작 검증
- [ ] GitHub Discussions 개설 및 FAQ 시드
- [ ] SECURITY.md 및 취약점 신고 경로 운영 중
- [ ] v0.9 soft launch 후 4주 이상 안정성 검증
- [ ] v1.0 릴리즈 노트 및 마이그레이션 가이드 작성

-----

## 횡단 관심사 (Cross-Cutting Concerns)

아래는 특정 Phase에 귀속되지 않고 모든 단계에 걸쳐 지켜야 할 원칙들이다.

### A. 불변 원칙의 지속적 검증

매 Phase 종료 시 **Architecture Review**를 수행한다. 체크리스트:

- [ ] 정책은 여전히 DB 레코드인가?
- [ ] 컨트롤 로직은 여전히 DB 함수 안에 있는가?
- [ ] 상태 전이는 여전히 단일 트랜잭션인가?
- [ ] 에이전트 격리가 RBAC + 뷰로 달성되는가?
- [ ] 필수 외부 인프라가 늘어나지는 않았는가?

이 체크리스트에서 하나라도 ‘아니오’가 나오면 해당 Phase는 완료로 간주되지 않는다.

### B. 논문 자산의 가치 유지

ARGO의 지적 자산은 DBaaCP 패턴 그 자체다. v1.0 개발이 진행되면서 실용주의적 타협으로 이 자산이 희석되지 않도록 주의한다.

- **논문의 핵심 다이어그램과 용어를 문서에서 일관되게 사용**: “Control Plane”, “Data Plane”, “Agent Runtime Governance”.
- **블로그와 컨퍼런스 발표에서 패턴 자체를 먼저 소개**, ARGO는 그 구현체로 포지셔닝.
- **경쟁자와의 비교에서 구현 디테일보다 아키텍처 차이를 강조**.

### C. 과잉 엔지니어링 회피

“프로덕션 레디”를 위해 필요한 것과 “엔터프라이즈 티어”로 이미 넘어간 것을 구분한다.

**v1.0 범위:**

- Docker Compose + Helm Chart 기본 배포
- 단일 테넌트 내 RBAC 격리
- 기본 관측 가능성
- 운영자 CLI

**v1.0 범위 밖 (v1.x 또는 v2.0):**

- 완전한 웹 기반 운영 UI
- 멀티 클러스터 / 멀티 리전 복제
- 고급 SAML/OIDC 연동
- 멀티테넌시 (tenant = DB가 아닌 논리적 tenant)
- 워크플로우 시각 편집기

### D. 하위 호환성 약속

v1.0 이후의 모든 변경은 SemVer를 엄격히 준수한다. 이 약속이 지켜지지 않으면 커뮤니티는 ARGO를 신뢰하지 않는다.

- 공개 함수 시그니처 변경은 반드시 새 함수 추가로 처리, 기존 함수는 최소 2 MINOR 버전 유지.
- 스키마 변경은 ALTER EXTENSION 마이그레이션으로 해결 가능한 형태로만 허용.

### E. 보안 책임의 명확화

DBaaCP는 **구조적 보안**을 제공한다. 프롬프트 레벨 공격, 애플리케이션 버그, 잘못된 권한 설정은 여전히 사용자의 책임이다.

- 문서에 **책임 경계(Responsibility Matrix)** 를 명시.
- 샘플 설정에 안전한 기본값 사용.
- 위험한 설정 변경 시 CLI와 로그에서 경고.

-----

## 리스크와 의사결정 포인트

v1.0 도달 과정에서 중대한 의사결정이 필요한 지점들.

### R1. 관리형 DB에서 Extension 설치 불가 시 (Phase 2.1)

**리스크:** 주요 관리형 DB가 `argo` Extension 설치를 허용하지 않으면, “한 줄 설치” 약속이 절반의 사용자에게만 유효해진다.

**완화:**

- Extension 없이 동작하는 **순수 스키마 모드** 제공.
- 이 경우 `CREATE EXTENSION argo` 대신 스크립트 실행으로 설치.
- 기능적 차이는 거의 없지만, 업그레이드 경로가 복잡해진다.

### R2. 라이선스 선택의 장기 영향 (Phase 0)

**리스크:** Apache 2.0 선택 시 클라우드 업체의 fork 상업화 가능. BSL 선택 시 초기 커뮤니티 확산 저해.

**완화:**

- 선택 전 유사 프로젝트(Temporal, Hasura, Supabase 등) 사례 연구.
- Phase 0에서 한 번 결정하면 되돌리지 않는다.

### R3. LiteLLM 의존도 (Phase 1.3)

**리스크:** LiteLLM에 보안 이슈 발생 시 ARGO 생태계 전체 영향.

**완화:**

- LiteLLM을 번들 제공하지 않고, 어댑터 인터페이스만 제공.
- 사용자가 LiteLLM 버전을 선택하거나 대체 구현 가능.

### R4. Tool RAG 임베딩 provider 선택 (Phase 3.3)

**리스크:** 임베딩 모델 선택이 lock-in을 만든다. 모델 변경 시 전체 재임베딩 필요.

**완화:**

- `tool_registry`에 `embedding_model` 컬럼 포함.
- 마이그레이션 유틸리티 제공.
- 문서에 모델 변경 비용 명시.

### R5. 첫 외부 기여자 확보 (Phase 4)

**리스크:** 오픈소스는 단일 유지보수자가 운영할 수 없다. 첫 10명의 외부 기여자가 없으면 프로젝트가 죽는다.

**완화:**

- Good first issue 상시 유지.
- 학부/대학원 수업 프로젝트 대상으로 “ARGO 예제 만들기” 과제 홍보.
- 초기 기여자에게 공개적 감사 표시.

-----

## 성공 기준: v1.0의 정의

ARGO v1.0은 다음을 모두 충족할 때 릴리즈된다.

**기능적:**

- [ ] Docker Compose 및 Helm Chart로 원클릭 배포
- [ ] OpenAI, Anthropic, Ollama 최소 3개 provider 지원
- [ ] 실험 E1~E3의 속성이 프로덕션 구성에서도 성립
- [ ] Tool RAG로 100개 툴 환경에서 동작
- [ ] HITL 승인 워크플로우 (Slack + Webhook)
- [ ] 감사 로그 변조 방지 및 해시 체인

**운영적:**

- [ ] `argoctl` CLI로 주요 운영 시나리오 커버
- [ ] Prometheus + Grafana 대시보드 자동 프로비저닝
- [ ] SemVer 기반 업그레이드 경로 검증
- [ ] 백업/복구 절차 문서화 및 1회 이상 시뮬레이션

**커뮤니티:**

- [ ] Getting Started 10분 이내 성공률 80% 이상 (5명 이상 테스트)
- [ ] 주요 문서 영역 완성
- [ ] 벤치마크 저장소 운영
- [ ] 예제 에이전트 3개 이상
- [ ] 최소 5명의 외부 기여 (PR merged)

**지적 자산:**

- [ ] DBaaCP 패턴이 코드, 문서, 마케팅에서 일관되게 중심에 있음
- [ ] 논문이 공개되고 프로젝트와 연결되어 있음
- [ ] 불변 원칙 5개가 모두 유지됨

-----

## 부록 A. Phase별 예상 일정

각 Phase는 **1인 파트타임 작업** 기준. 전담 인력 또는 여러 기여자가 있으면 단축 가능.

|Phase                     |최소     |예상     |최대     |
|--------------------------|-------|-------|-------|
|Phase 0 — Foundation      |1주     |2주     |3주     |
|Phase 1 — Core Hardening  |4주     |6주     |10주    |
|Phase 2 — Distribution    |3주     |5주     |8주     |
|Phase 3 — Operability     |4주     |6주     |10주    |
|Phase 4 — Launch & Sustain|4주     |8주     |지속     |
|**총 v1.0 도달**             |**16주**|**27주**|**41주**|

중간에 의사결정 포인트에서 방향 전환이 필요할 수 있다. 일정보다 원칙 준수가 우선이다.

-----

## 부록 B. “하지 않을 일” 목록

v1.0 범위를 명확히 하기 위해, 의식적으로 **하지 않을 것**을 명시한다.

- ❌ 완전한 웹 기반 운영 UI — CLI와 최소 승인 UI로 충분
- ❌ 자체 LLM inference 서버 — LiteLLM/Ollama에 위임
- ❌ 에이전트 마켓플레이스 — 예제 카탈로그로 충분
- ❌ 자동 에이전트 생성 (Agent builder) — 범위 초과
- ❌ 다중 DB 지원 (Oracle, MSSQL) — 논문의 향후 연구로 남김
- ❌ 시각적 워크플로우 편집기 — SQL이 진실 공급원
- ❌ 모든 공격에 대한 완벽한 방어 — 구조적 격리에 집중
- ❌ 실시간 협업 편집 — 범위 초과

이 목록은 v1.x에서 재검토한다. v2.0에서 일부가 추가될 수 있다.

-----

## 마무리

이 로드맵은 **ARGO를 논문의 PoC에서 커뮤니티가 실제로 쓸 수 있는 오픈소스로 전환**하기 위한 지도다. 핵심은 다음 세 가지다.

1. **DBaaCP 패턴의 불변 원칙을 끝까지 지킨다.** 이것이 ARGO의 차별점이자 존재 이유다.
1. **커뮤니티 사용자의 첫 경험(Getting Started)에 집착한다.** 오픈소스의 생존은 여기서 결정된다.
1. **너무 많은 것을 약속하지 않는다.** v1.0은 잘 작동하는 코어이고, 확장은 v1.x에서 한다.

“DB를 컨트롤 플레인으로” 라는 처음의 아이디어가 로드맵 전체를 관통하도록 한다. 그것이 퇴색하는 순간 v1.0은 의미가 없다.

-----

*문서 끝. 로드맵은 살아있는 문서이며, 각 Phase 완료 시 다음 Phase의 세부를 재검토한다.*