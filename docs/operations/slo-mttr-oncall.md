# SLO · MTTR · On-Call Rotation

> ICONIA 운영 SLO, 복구 시간 목표(MTTR), on-call 순번 표준.
> 본 문서는 `incident-response-runbook.md`의 SEV 매트릭스를 정량 SLO로 확장한다.
> 갱신일: 2026-06-02 (Beta 0.5.0 시점).

---

## 1. 서비스 수준 목표 (SLO)

각 서비스는 30일 롤링 윈도우 기준으로 가용성(Availability)·지연(Latency)·정확성(Correctness) 3축 SLO를 갖는다.
초과·미달 시 자동 알람 → on-call 호출.

### 1.1 API (api.<root> / Server :8080)

| 지표 | 목표(SLO) | 측정 | 알람 임계 | 비고 |
|---|---|---|---|---|
| 가용성 | 99.5% | ALB 5xx ÷ 총요청, 5분 윈도우 | 5분 동안 5xx ≥ 1% | RDS write 단일 노드 의존 |
| p95 응답 | ≤ 800ms | pino-http, /api/v1/* | 5분 p95 ≥ 1500ms | event ingest 제외 |
| p99 응답 | ≤ 1500ms | 동일 | 5분 p99 ≥ 2500ms | |
| 디바이스 ingest 성공률 | 99.0% | /api/v1/event 200 응답 ÷ 시도 | 10분 95% 미만 | OTA·이미지 multipart |
| Error budget | 30일당 0.5% (≈3.6h) | 5xx 누적 | 70% 소진 시 release freeze | |

### 1.2 AI (ai.<root> / Persona :8081)

| 지표 | 목표(SLO) | 측정 | 알람 임계 | 비고 |
|---|---|---|---|---|
| 가용성 | 99.0% | /health 200 + degradation ≠ unhealthy | 5분 unhealthy | Gemini 외부 의존 |
| p95 응답 | ≤ 1500ms | metricsBuffer | 5분 p95 ≥ 2000ms | `PERSONA_AI_P99_TARGET_MS` 정합 |
| p99 응답 | ≤ 2500ms | metricsBuffer | 5분 p99 ≥ 3500ms | webhook fire |
| Fallback rate | ≤ 5% | fallbackClassifier | 5분 ≥ 20% | 5분 80% 시 /health 503 |
| 환각 제어 | grounding 점수 ≥ 0.6 | RAGAS faithfulness | 일 평균 < 0.5 | 일일 quality:regression |

### 1.3 ADMIN (admin.<root> / Next.js :3000)

| 지표 | 목표(SLO) | 측정 | 알람 임계 | 비고 |
|---|---|---|---|---|
| 가용성 | 99.5% | nginx 5xx | 5분 5xx ≥ 1% | |
| TTFB | ≤ 600ms | nginx response time | 5분 p95 ≥ 1500ms | Server Action 포함 |
| 로그인 성공률 | 99.0% (정합 요청만) | operatorLoginStep1 / Step2 | 1시간 < 90% | MFA brute-force 가능성 |

### 1.4 인프라 (RDS · ElastiCache · ALB)

| 지표 | 목표 | 알람 | 비고 |
|---|---|---|---|
| RDS CPU | ≤ 70% | 5분 ≥ 85% | Multi-AZ failover 준비 |
| RDS FreeStorage | ≥ 20% | < 15% | max_allocated_storage 자동 확장 |
| RDS connections | ≤ 80% of max | ≥ 90% | RDS Proxy 권장 |
| Redis CPU | ≤ 60% | 5분 ≥ 80% | |
| ALB unhealthy host | 0 | ≥ 1 host 5분 | health check /health?deep=1 |

---

## 2. 복구 시간 목표 (MTTR · RPO)

각 Severity 별 복구 목표. `incident-response-runbook.md` Phase A/B/C와 정합.

### 2.1 MTTR (Mean Time To Recovery)

| Severity | Detect | Acknowledge | Mitigate | Resolve | 누적 MTTR 목표 |
|---|---|---|---|---|---|
| SEV-1 | ≤ 3분 (자동 알람) | ≤ 10분 | ≤ 30분 | ≤ 2h | **≤ 2시간** |
| SEV-2 | ≤ 5분 | ≤ 20분 | ≤ 1h | ≤ 4h | **≤ 4시간** |
| SEV-3 | ≤ 30분 | ≤ 1h | ≤ 4h | ≤ 24h | **≤ 24시간** |
| SEV-4 | 일일 review | — | — | 다음 sprint | **다음 release** |

### 2.2 RPO (Recovery Point Objective)

| 데이터 | RPO 목표 | 실측 메커니즘 |
|---|---|---|
| RDS (PostgreSQL) | ≤ 5분 | 자동 백업 5분 단위 + WAL PITR |
| EFS (persona state) | ≤ 1분 | NFS atomic rename + Redis lock |
| S3 (events·exports·firmware·artifacts) | 0 (versioning) | bucket versioning + CRR(toggle) |
| Redis (cache·session) | 즉시 손실 허용 | Multi-AZ failover, 영속 안 함 |

### 2.3 RTO (Recovery Time Objective)

| 시스템 | RTO 목표 | 절차 |
|---|---|---|
| RDS instance fail | ≤ 5분 | Multi-AZ failover 자동 |
| EC2/ASG fail | ≤ 10분 | ASG self-heal + ALB 자동 deregister |
| 단일 region fail | ≤ 4h | multi-region IaC manual promote |
| Gemini API 장애 | ≤ 즉시 | DeepSeek/Vertex/Bedrock factory swap |

---

## 3. On-Call Rotation

### 3.1 순번 정책

- **주기**: 주간(Mon 09:00 KST → 다음 Mon 09:00 KST)
- **인원**: 최소 2명(primary + secondary)
- **handoff**: 매주 월 09:00 KST 인수인계 미팅(15분) — 미해결 인시던트·진행 중 변경·예정 배포 공유
- **대체**: 사전 24시간 통보로 swap 허용 — Slack `#oncall-swap` 채널 기록

### 3.2 역할

| 역할 | 책임 | 응답 SLA |
|---|---|---|
| Primary on-call | 1차 알람 수신·triage·Incident Commander 후보 | SEV-1/2: 10분 / SEV-3: 1h |
| Secondary on-call | Primary 부재·중복 인시던트 시 fallback | SEV-1: 20분 / SEV-2: 30분 |
| SEV-1 Escalation | 1시간 미해결 시 CEO + DPO 자동 통지 | — |

### 3.3 연락 체계

- **1차 채널**: Slack `#alerts` → `#incident-{ID}` (자동 생성)
- **음성**: SNS topic `iconia-oncall-${env}` → PagerDuty/Opsgenie [추정: 아직 미연결, 토글 필요]
- **백업**: 등록 휴대전화 SMS (SNS subscription)
- **SEV-1 immediate**: CEO·DPO 핸드폰 직통

### 3.4 권한

On-call 인원은 인시던트 기간 한정으로 다음 권한을 자동 부여:
- `superadmin` 또는 `sre` IAM role (TOTP 2FA 강제)
- RDS read replica fail-over 트리거
- ASG 수동 scaling
- nginx rate-limit 임시 조정
- 모든 작업은 audit_log 영구 기록

### 3.5 인계 체크리스트 (주간 handoff)

- [ ] 미해결 SEV-1/2 인시던트 인수
- [ ] 진행 중인 변경(canary 배포, RDS 패치, 보안 토글 변경) 공유
- [ ] 예정된 배포·OTA 일정 공유
- [ ] 지난 주 alarm fatigue 분석 (false positive ≥ 30% 시 threshold 조정)
- [ ] error budget 잔여 확인 (소진율 70% 시 release freeze 검토)

---

## 4. SLO 위반 시 대응

### 4.1 자동 조치

- 5xx ≥ 1% (5분) → `#alerts` 알람 + on-call 호출
- Error budget 70% 소진 → `#release-freeze` 자동 공지 + 신규 PR 머지 금지
- AI fallback rate ≥ 80% (5분) → `/health` 503 → ALB 트래픽 회수 → degradation manager가 recovery 시도

### 4.2 수동 조치

- SLO 미달 2주 연속 → `#sre-weekly`에서 root-cause 분석 + remediation plan 작성
- MTTR 목표 초과 → incident-response-runbook 의 Phase C postmortem 의무 (72시간 이내)

---

## 5. 메트릭 출처

| 메트릭 | 위치 | 갱신 주기 |
|---|---|---|
| API 5xx / latency | CloudWatch `iconia_slo` dashboard | 1분 |
| AI metrics | `/v1/metrics/snapshot` + Prometheus `/metrics` | 실시간 |
| RDS / Redis | CloudWatch namespace `AWS/RDS`·`AWS/ElastiCache` | 1분 |
| ALB target health | CloudWatch `AWS/ApplicationELB` | 30초 |
| Error budget | 별도 Lambda 집계 → CloudWatch custom metric | 1시간 |

---

## 6. 변경 이력

| 일자 | 변경 | 작성자 |
|---|---|---|
| 2026-06-02 | 초안. Beta 0.5.0 점검 결과 반영. PagerDuty/Opsgenie 연결은 후속. | 이승주 |
