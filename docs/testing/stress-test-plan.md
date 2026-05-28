# Wide Stress Test Plan

## 1. 목표

- API/AI/DB/네트워크에서 발생 가능한 부하·장애 시나리오를 정형화하고, baseline 측정 + regression 가능하게 한다.
- Production traffic 에 부하 테스트를 절대 실행하지 않는다 (staging only).

## 2. 도구

| 도구 | 용도 |
|---|---|
| k6 | HTTP load test (SERVER, AI) |
| Artillery | scenario-driven test |
| Vitest / supertest | 통합 + 동시성 test |
| Playwright | ADMIN UI parallel session |
| Maestro / Detox | APP 시나리오 |
| Docker Compose | local staging-like env |

## 3. 시나리오 (20개)

| ID | 시나리오 | 도구 | 목표 / 임계 |
|---|---|---|---|
| ST-01 | API load test (feed/admin/auth) | k6 | p95 < 500ms @ 100 RPS |
| ST-02 | AI provider load + failure simulation | k6 + mock Gemini | fallback 정상 (in-character) |
| ST-03 | Feed/commerce read-heavy | k6 | error rate < 1% @ 200 RPS |
| ST-04 | Auth burst (login spike) | k6 | rate limit 정상 동작, no 5xx |
| ST-05 | Device provisioning burst | k6 + scripted | concurrent 50 devices |
| ST-06 | Admin concurrent operation | Playwright multi-tab | RBAC + audit 일관 |
| ST-07 | DB connection pool saturation | k6 | graceful queue / no crash |
| ST-08 | Rate limit test | k6 | 응답 429 정상, retry-after 헤더 |
| ST-09 | Retry storm | k6 + simulated client | circuit breaker 동작 |
| ST-10 | Offline-to-online app sync | Maestro | 데이터 손상 없음 |
| ST-11 | Slow network (3G) | Detox + traffic shaper | UX 정상, timeout 적정 |
| ST-12 | Timeout test (long requests) | k6 | server timeout 30s, 정상 |
| ST-13 | Cold start (server restart) | manual + curl loop | 30초 내 ready |
| ST-14 | Memory leak observation | soak test 24h | RSS 안정 |
| ST-15 | Long-running soak | 24h k6 | error rate stable |
| ST-16 | Malformed payload fuzz | restler / 자체 script | 5xx 없음, 4xx 정상 |
| ST-17 | Prompt injection batch | Vitest + canary | 100% canary 차단 |
| ST-18 | Audit log volume test | repeated mutation | hash chain 무결성 유지 |
| ST-19 | Seed idempotency repeated | repeated run | row count stable |
| ST-20 | Migration validation repeated | repeated prisma | no drift |

## 4. Baseline (초기 측정 결과 — Stage 6 실측 후 갱신)

| Metric | Target | Measured |
|---|---|---|
| SERVER p50 latency (feed list) | < 200ms | (pending Stage 6) |
| SERVER p95 latency (feed list) | < 500ms | (pending) |
| SERVER p99 latency (feed list) | < 1500ms | (pending) |
| SERVER error rate (일반 부하) | < 1% | (pending) |
| AI p95 latency (single response) | < 3000ms | (pending) |
| AI fallback rate (정상 운영) | < 5% | (pending) |
| ADMIN page load (cold) | < 2000ms | (pending) |
| APP cold start | < 3000ms | (pending) |

## 5. 실행 환경

- **로컬 dev**: Docker Compose 로 staging-like env (개발자 점검용)
- **Staging EC2**: GitHub Actions scheduled workflow (주간) — k6/artillery 실행 → CloudWatch metrics + report
- **Production**: 금지 (chaos 도 staging 만)

## 6. 결과 보관

- `6. CI/docs/testing/stress-test-report.md` 에 실측 결과 누적
- 매 stress 실행마다 baseline 비교 + regression 알람

## 7. Chaos / Resilience

- AI provider 강제 fail injection
- DB 연결 끊김 시뮬레이션
- 네트워크 latency 주입
- EC2 instance 강제 종료 (ASG 자동 복구 검증)

## 8. Performance Budget

| Component | Budget |
|---|---|
| ADMIN page bundle size | < 500KB gzipped per route |
| APP cold start memory | < 200MB |
| AI single request memory | < 100MB |

## 9. LEGAL / Cost

- 부하 테스트는 staging 만 (실 사용자 데이터 사용 금지)
- AI provider 비용 한도 (HD-11) 내 실행
- AWS 비용 알람 (`budgets.tf`) 활성

## 10. Stage 6 실행 우선순위

1. ST-01, ST-03 (가장 기본 — feed/commerce read load)
2. ST-04, ST-08 (auth + rate limit)
3. ST-02, ST-09 (AI + circuit breaker)
4. ST-17 (prompt injection batch)
5. ST-18 (audit log volume)
6. 나머지는 backlog
