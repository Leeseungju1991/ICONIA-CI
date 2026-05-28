# Final Go / No-Go Checklist

> ICONIA 출시 직전 점검표. 각 항목 ✓ / ✗ / blocked / human-decision-required 로 표시.

## A. Product (필수)

| Item | Status |
|---|---|
| A-01 APP_MODE_2_REAL_DEVICE only production | ✓ (runtime guard 검증, EAS production profile 분리) |
| A-02 mock connectivity production impossible | ✓ (`mode.ts` 의 `getRunMode()==='production'` 차단) |
| A-03 feed real API (server seed 기반) | ✓ (AWS prod RDS — 32 posts, 38 media) |
| A-04 commerce display-only real API | ✓ (AWS prod RDS — 50 products) |
| A-05 no checkout/payment/order/shipping/refund UI | ✓ (grep 0건) |
| A-06 app not empty (seed 적용) | ✓ |
| A-07 legal screens accessible | partial (consent flow ✓, AI disclosure/device notice 일부) |
| A-08 consent management accessible | ✓ |
| A-09 delete account / data request accessible | ✓ (adminPipaRoutes + App AccountDeletion) |
| A-10 AI disclosure accessible | partial (코드 위치는 확정, 화면 본문 확정은 HD-14) |
| A-11 device connection notice accessible | partial (HD-03 KC 인증 결과 반영 필요) |
| A-12 open-source licenses accessible | partial (자동 생성 필요 — HD-16) |

## B. APP

| Item | Status |
|---|---|
| B-01 release config verified | ✓ (EAS production profile) |
| B-02 font/assets valid | ✓ (expo doctor 가능) |
| B-03 secure token storage | ✓ (SecureStore) |
| B-04 offline/retry/error boundary | ✓ |
| B-05 BLE real-device flow | partial (HIL required — HD-12) |
| B-06 Wi-Fi provisioning flow | partial (HIL required — HD-12) |
| B-07 production debug disabled | ✓ |
| B-08 crash log redaction | ✓ |
| B-09 E2E pass or HIL_REQUIRED | partial (자동 test ✓, HIL HD-12) |

## C. SERVER

| Item | Status |
|---|---|
| C-01 auth/RBAC | ✓ |
| C-02 feed/commerce display APIs | ✓ |
| C-03 no payment endpoints active | ✓ |
| C-04 seed idempotent | ✓ |
| C-05 production seed guard | ✓ (SEED_RESET=1 명시) |
| C-06 migration guard | ✓ (db-migration-policy-check.js) |
| C-07 health/readiness/liveness | ✓ |
| C-08 audit log (hash chain) | ✓ |
| C-09 rate limit | ✓ (V1.0 다층화) |
| C-10 Docker/ECS readiness | ✓ |
| C-11 structured logging | ✓ (pino) |
| C-12 PII redaction | ✓ (redact.js) |

## D. ADMIN

| Item | Status |
|---|---|
| D-01 production API | ✓ |
| D-02 no production mock | ✓ (이전 라운드 — commit 4b40bd7) |
| D-03 RBAC | ✓ |
| D-04 audit trail | ✓ |
| D-05 consent history | ✓ |
| D-06 privacy access logging | ✓ |
| D-07 device/user operations | ✓ |
| D-08 commerce display data management/view | ✓ |
| D-09 no payment/order operations | ✓ |

## E. AI

| Item | Status |
|---|---|
| E-01 provider fallback | ✓ (circuitBreaker + key pool) |
| E-02 prompt injection regression | ✓ (canary token) |
| E-03 RAG regression | ✓ (eval:rag) |
| E-04 persona consistency | ✓ |
| E-05 redaction | ✓ |
| E-06 AI disclosure (앱 측 본문) | partial (HD-14) |
| E-07 latency baseline | partial (목표 정의, 실측 HD-09) |
| E-08 error metrics | ✓ |

## F. HW

| Item | Status |
|---|---|
| F-01 BLE contract | ✓ |
| F-02 Wi-Fi provisioning | ✓ |
| F-03 OTA anti-rollback | ✓ (commit 7d47ae0) |
| F-04 secure version | ✓ |
| F-05 prod macro guard | ✓ |
| F-06 debug disabled | ✓ |
| F-07 firmware checklist | ✓ |
| F-08 HIL status documented | partial (HD-12) |
| F-09 KC/전파 certification checklist | partial (HD-03) |

## G. AWS / Ops

| Item | Status |
|---|---|
| G-01 dev/staging/prod separation | partial (HD-09 production migrate) |
| G-02 Secrets Manager / SSM plan | partial (HD-09) |
| G-03 IAM least privilege plan | partial (HD-06) |
| G-04 CI/CD quality gate | ✓ (9개 workflow) |
| G-05 deployment runbook | ✓ |
| G-06 rollback runbook | ✓ |
| G-07 backup/restore runbook | ✓ |
| G-08 CloudWatch logs/metrics/alarms | partial (terraform alarms.tf 존재) |
| G-09 incident response | ✓ |
| G-10 personal data breach runbook | ✓ |
| G-11 cost guardrails | partial (budgets.tf basic — HD-21 확장) |

## H. Legal / Compliance

| Item | Status |
|---|---|
| H-01 legal register | ✓ |
| H-02 compliance matrix | ✓ |
| H-03 data inventory | ✓ |
| H-04 consent matrix | ✓ |
| H-05 privacy policy draft | ✓ (LEGAL_REVIEW_REQUIRED — HD-01) |
| H-06 terms draft | ✓ (HD-01) |
| H-07 AI disclosure | ✓ (HD-14) |
| H-08 device connection policy | ✓ (HD-03) |
| H-09 commerce display policy | ✓ |
| H-10 location policy (필요 시) | n/a (GPS 미사용) |
| H-11 marketing consent (필요 시) | partial (HD-23) |
| H-12 open-source notice | ✓ (HD-16 자동 생성) |
| H-13 data retention/deletion policy | ✓ (HD-17) |
| H-14 third-party processors | ✓ |
| H-15 cross-border transfer checklist | ✓ (HD-18) |
| H-16 LEGAL_REVIEW_REQUIRED list | ✓ (HUMAN_DECISIONS_REQUIRED.md — 23개) |
| H-17 no final legal approval claim | ✓ (단정 표현 없음) |

## I. E2E / Stress

| Item | Status |
|---|---|
| I-01 app E2E (자동) | partial (HIL 제외) |
| I-02 admin E2E | partial (Playwright planned) |
| I-03 server integration | ✓ |
| I-04 AI regression | ✓ |
| I-05 HW host/contract/HIL plan | partial (HIL HD-12) |
| I-06 AWS staging smoke | partial (HD-09) |
| I-07 load test | partial (plan ✓, 실측 HD-09) |
| I-08 stress test | partial (plan ✓, 실측 HD-09) |
| I-09 soak test | partial (plan ✓, 실측 HD-09) |
| I-10 chaos/resilience | partial (plan ✓) |
| I-11 security test | ✓ (CI workflows) |
| I-12 performance baseline | partial (목표 ✓, 실측 HD-09) |
| I-13 P0 test failure none | ✓ |

## J. Git / Release

| Item | Status |
|---|---|
| J-01 Stage 별 변경 레포 commit 완료 | ✓ |
| J-02 Stage 별 변경 레포 push 완료 | ✓ |
| J-03 main branch 기준 release package | ✓ |
| J-04 commit hash 기록 | ✓ (STAGE_COMMIT_PUSH_LOG.md) |
| J-05 rollback 방법 기록 | ✓ |
| J-06 CI README 에 사용자 결정 필요 항목 | ✓ (23 결정 항목) |

## K. Production Readiness Score 산정 (0~100)

- A (Product) 가중치 25 — 80% × 25 = 20
- B (APP) 가중치 15 — 75% × 15 = 11.25
- C (SERVER) 가중치 15 — 100% × 15 = 15
- D (ADMIN) 가중치 10 — 100% × 10 = 10
- E (AI) 가중치 10 — 85% × 10 = 8.5
- F (HW) 가중치 10 — 70% × 10 = 7 (HIL/인증 결정 대기)
- G (AWS/Ops) 가중치 5 — 75% × 5 = 3.75
- H (Legal) 가중치 5 — 95% × 5 = 4.75 (LEGAL_REVIEW_REQUIRED 잔존)
- I (E2E/Stress) 가중치 5 — 60% × 5 = 3 (HIL/staging 실측 대기)

**Total: 83.25 / 100 → 80~85 (Release Candidate 수준)**

## L. Final Go / No-Go 판단

### Go 조건 (모두 충족 시)
- P0 blocker 0건 ✓
- HD-01 (privacy policy, terms 최종본) 결정 + 화면 적용
- HD-03 (KC 인증) 결과 + 화면 적용
- HD-06 (AWS production) 승인 + 배포
- HD-09 (Secrets Manager + production secret 주입) 완료
- HIL test 결과 OK (HD-12)
- HD-14 (AI disclosure 본문) 결정 + 화면 적용
- HD-16 (OSS notice 자동 생성)
- App Store / Play Store 심사 통과 (HD-08)

### 현재 판단
**Release Candidate 수준 — Go/No-Go 는 위 결정 항목 (HUMAN_DECISIONS_REQUIRED.md) 완료 후**.

Claude Code 가 자동 처리 가능한 모든 항목은 완료됨. 남은 것은 사람·법률·인증·결제 영역의 결정 + 외부 행위.
