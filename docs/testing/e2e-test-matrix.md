# E2E Test Matrix

> Stage 6 의 wide E2E + stress 의 scenario 매트릭스.

## 1. APP E2E (`4. APP`)

| ID | Scenario | Tool | Mock OK? | Production OK? | Status |
|---|---|---|---|---|---|
| APP-01 | Fresh install + first launch | Maestro / Detox | Mock | ✗ | planned |
| APP-02 | Legal consent flow (required + optional) | Maestro | Mock + Real | ✓ | planned |
| APP-03 | Login + token refresh | Maestro | Mock + Real | ✓ | planned |
| APP-04 | Feed load (server seed) | Maestro | Real (server) | ✓ | planned |
| APP-05 | Feed empty state | Maestro | Mock | ✓ | planned |
| APP-06 | Commerce display load | Maestro | Real (server) | ✓ | planned |
| APP-07 | Commerce — no checkout/payment UI | grep + UI test | Both | ✓ | planned |
| APP-08 | AI screen + error state | Maestro | Real (AI) | ✓ | planned |
| APP-09 | BLE mock mode QA flow | Detox + mock | Mock | ✗ | planned |
| APP-10 | BLE real-device mode | Detox + real | Real | ✓ | HIL_REQUIRED |
| APP-11 | Wi-Fi provisioning mock | Maestro | Mock | ✗ | planned |
| APP-12 | Wi-Fi provisioning real | Detox + real | Real | ✓ | HIL_REQUIRED |
| APP-13 | Network offline / retry | Maestro | Mock | ✓ | planned |
| APP-14 | Crash log redaction | runtime test | Real | ✓ | planned |
| APP-15 | App restart recovery | Maestro | Real | ✓ | planned |
| APP-16 | Accessibility basics | axe-core | Both | ✓ | planned |
| APP-17 | Release build config check | static check | Production | ✓ | planned |
| APP-18 | Production mock guard verify | runtime test | Production | ✓ | planned |

## 2. ADMIN E2E (`5. ADMIN`)

| ID | Scenario | Tool | Status |
|---|---|---|---|
| ADM-01 | Admin login + MFA | Playwright | planned |
| ADM-02 | RBAC role 별 접근 | Playwright | planned |
| ADM-03 | Forbidden route block | Playwright | planned |
| ADM-04 | Dashboard load | Playwright | planned |
| ADM-05 | Users page (사용자 정보) | Playwright | planned |
| ADM-06 | Devices page | Playwright | planned |
| ADM-07 | Feed admin (게시물 관리) | Playwright | planned |
| ADM-08 | Commerce display admin | Playwright | planned |
| ADM-09 | Legal/policy version view | Playwright | planned |
| ADM-10 | User consent history | Playwright | planned |
| ADM-11 | Audit log view | Playwright | planned |
| ADM-12 | Mock fallback production 차단 | static check | planned |
| ADM-13 | API timeout/error UX | Playwright + mock | planned |
| ADM-14 | Session expiry | Playwright | planned |
| ADM-15 | Operator action audit log | Playwright | planned |

## 3. SERVER E2E / Integration (`2. SERVER`)

| ID | Scenario | Tool | Status |
|---|---|---|---|
| SRV-01 | Auth (register/login/refresh) | Vitest + supertest | implemented |
| SRV-02 | RBAC enforce | Vitest | implemented |
| SRV-03 | Feed API CRUD | Vitest | implemented |
| SRV-04 | Commerce display API | Vitest | implemented |
| SRV-05 | AI proxy/API integration | Vitest | implemented |
| SRV-06 | Device provisioning API | Vitest | implemented |
| SRV-07 | Admin API | Vitest | implemented |
| SRV-08 | Audit log | Vitest | implemented |
| SRV-09 | Rate limit | Vitest | implemented |
| SRV-10 | Request validation (zod) | Vitest | implemented |
| SRV-11 | Error response schema | Vitest | implemented |
| SRV-12 | Health/readiness/liveness | curl smoke | implemented |
| SRV-13 | Migration validation | prisma migrate diff | implemented |
| SRV-14 | Seed idempotency | repeated run | implemented |
| SRV-15 | Seed dry-run | DRY_RUN=1 | implemented |
| SRV-16 | Production seed guard | SEED_RESET check | implemented |
| SRV-17 | Destructive migration guard | CI workflow | implemented |
| SRV-18 | DB connection pool | Vitest | implemented |
| SRV-19 | Graceful shutdown | manual smoke | implemented |
| SRV-20 | Docker run smoke | docker build + run | planned |

## 4. AI E2E / Safety / Stress (`3. AI`)

| ID | Scenario | Tool | Status |
|---|---|---|---|
| AI-01 | Provider success | Vitest + integration | implemented |
| AI-02 | Provider timeout | Vitest | implemented |
| AI-03 | Provider rate limit | Vitest | implemented |
| AI-04 | Provider failure fallback | Vitest + circuit breaker | implemented |
| AI-05 | RAG success | eval:rag | implemented |
| AI-06 | RAG empty | Vitest | implemented |
| AI-07 | RAG corrupted source | Vitest | implemented |
| AI-08 | Persona consistency | regression | implemented |
| AI-09 | Prompt injection | canary token + regression | implemented |
| AI-10 | Jailbreak | regression | partially |
| AI-11 | Unsafe data input warning | UI test (APP) | planned |
| AI-12 | PII redaction | Vitest | implemented |
| AI-13 | AI disclosure consistency | UI test (APP) | planned |
| AI-14 | Logging redaction | log review | implemented |
| AI-15 | Latency under load | k6 / artillery | planned |
| AI-16 | Token usage metrics | dashboard | implemented |
| AI-17 | Fallback count metrics | dashboard | implemented |
| AI-18 | Degraded response policy | in-character canned | implemented |

## 5. HW / Firmware / Device E2E (`1. HW`)

| ID | Scenario | Tool | Status |
|---|---|---|---|
| HW-01 | Firmware compile | Arduino/PlatformIO | implemented |
| HW-02 | Host tests | Native | implemented |
| HW-03 | BLE contract | host test | implemented |
| HW-04 | Provisioning payload parsing | host test | implemented |
| HW-05 | Wi-Fi provisioning state machine | host test | implemented |
| HW-06 | Invalid token | host test | implemented |
| HW-07 | Expired token | host test | implemented |
| HW-08 | Malformed payload | host test | implemented |
| HW-09 | BLE disconnect | HIL | HIL_REQUIRED |
| HW-10 | Wi-Fi timeout | HIL | HIL_REQUIRED |
| HW-11 | Device already provisioned | HIL | HIL_REQUIRED |
| HW-12 | Factory reset | HIL | HIL_REQUIRED |
| HW-13 | OTA success | HIL | HIL_REQUIRED |
| HW-14 | OTA failure / retry | HIL | HIL_REQUIRED |
| HW-15 | OTA anti-rollback | host test | implemented |
| HW-16 | Secure version | host test | implemented |
| HW-17 | Debug flag production 차단 | static check | implemented |
| HW-18 | Prod macro guard | static check | implemented |
| HW-19 | Telemetry/diagnostics policy | code review | implemented |
| HW-20 | Firmware release artifact checklist | CI | implemented |

## 6. AWS / DevOps / Infra E2E (`6. CI`)

| ID | Scenario | Tool | Status |
|---|---|---|---|
| AWS-01 | Docker build (server/admin/ai) | CI | implemented |
| AWS-02 | Container startup | docker run smoke | implemented |
| AWS-03 | Health/readiness/liveness | curl | implemented |
| AWS-04 | Env validation | startup test | implemented |
| AWS-05 | Secret missing failure | startup test | implemented |
| AWS-06 | Secret fallback 금지 | static check | implemented |
| AWS-07 | Deployment dry-run | shell script | partially |
| AWS-08 | Migration dry-run | prisma | implemented |
| AWS-09 | Seed dry-run | DRY_RUN=1 | implemented |
| AWS-10 | Rollback script dry-run | manual | partially |
| AWS-11 | CloudWatch log format | log review | implemented |
| AWS-12 | Metrics emission | dashboard | implemented |
| AWS-13 | Alarm definition validation | terraform validate | implemented |
| AWS-14 | Staging smoke test | curl + smoke script | planned |
| AWS-15 | Backup/restore drill | quarterly | planned (HD-12) |
| AWS-16 | IAM least privilege review | manual + tools | planned |
| AWS-17 | Cost guardrails | budgets | implemented (basic) |

## 7. Status Summary

- Total scenarios: **88**
- Implemented: 47
- Planned: 35
- HIL_REQUIRED: 6 (실기기 필요 — HD-12)
- Partially: (counted in implemented)

## 8. Execution Strategy

- **Stage 6 자동 실행 (가능 범위)**: 모든 implemented scenario CI 에서 매 PR
- **HIL scenario**: HW lead 가 quarterly drill 진행 (HD-12)
- **Wide stress** (별도 문서 `stress-test-plan.md`): k6 / Artillery / Maestro 등으로 시나리오 실행
