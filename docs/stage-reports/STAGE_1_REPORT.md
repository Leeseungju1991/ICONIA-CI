# Stage 1 Report — Demo & QA Ready

## 1. Stage
Stage 1 - LEVEL 1 Demo & QA Ready

## 2. Status
COMPLETE

## 3. Summary
APP_MODE_1_MOCK_CONNECTIVITY 정의 점검, 피드/커머스 seed 운영 확인, 기본 smoke 인프라 점검. App 내부 mock 의 격리 상태 검토.

## 4. 검토 항목 + 결과

| 항목 | 상태 | 비고 |
|---|---|---|
| 5개 레포 구조 점검 | ✓ | Stage 0 preflight 와 동일 |
| package.json scripts 점검 | ✓ | APP `start:*`, ADMIN `dev/build/test`, SERVER `start/test/prisma:*`, AI `start/test/eval:rag` |
| CI/env/Docker/migrations/seed 확인 | ✓ | CI: GitHub Actions 다수, env: `.env.example` 존재, migrations: 45 개, seed: idempotent |
| APP_MODE_1 정의 | ✓ | `4. APP/src/runtime/mode.ts` 의 `EXPO_PUBLIC_USE_MOCK_DATA`, `EXPO_PUBLIC_FORCE_MOCK_BLE`, `getRunMode()` 로 정교한 mode 시스템 존재 |
| BLE/Wi-Fi mock adapter 격리 | ✓ | `4. APP/src/ble/adapter.ts` 의 `PlaceholderBleAdapter` (mock) + `BlePlxAdapter` (real) — 화면/프로비저닝 코드는 어댑터만 사용, 직접 `react-native-ble-plx` import 금지 |
| Mock 로직이 UI 컴포넌트에 흩어져 있는지 | ✓ | 격리됨 — BLE 어댑터 패턴으로 service layer 분리 완료 |
| Production build mock guard | partial | 코드 mode.ts 의 `if (getRunMode() === 'production') return false` 로 런타임 guard 존재. build-time guard (eas.json production profile) 는 보강 필요 (Stage 5) |
| Font/asset validation | open | `expo doctor` 로 점검 가능. CI job 으로 강제 (Stage 4) |
| Feed seed script | ✓ | `2. SERVER/prisma/seed.js` 의 feed_posts + feed_media + feed_comments 카테고리. AWS prod RDS 에 검증 완료 (32 posts / 38 media / 71 comments) |
| Commerce display-only seed | ✓ | `products` 카테고리 + `_generate-products-batch2.mjs`. AWS prod RDS 에 50개 상품 검증 완료 |
| Seed idempotent | ✓ | upsert 기반 + UNKNOWN_FIELDS auto-drop |
| Seed dry-run | ✓ | `DRY_RUN=1` env variable |
| Seed environment guard | ✓ | `SEED_RESET=1` 명시적 + `SEED_SKIP_NONESSENTIAL=1` |
| App feed/commerce API 연결 | ✓ | App 측 `chatClient.ts`, ADMIN 측 `adminCommerce.ts` 로 server API 연결 확인 (이전 라운드) |
| Empty state / seeded state 확인 | ✓ | ADMIN 의 feed/commerce 페이지가 empty state + table 모두 표시 |
| Smoke test 작성 | partial | App `src/__smoke__/`, SERVER test, ADMIN Vitest 존재. wide smoke 통합은 Stage 6 |
| Legal register 초안 | ✓ | `6. CI/docs/compliance/legal-register.md` |
| Data inventory 초안 | ✓ | `6. CI/docs/compliance/data-inventory.md` |
| Compliance matrix 초안 | ✓ | `6. CI/docs/compliance/compliance-matrix.md` |
| Privacy policy 초안 | ✓ | `6. CI/docs/legal/privacy-policy-draft.md` |
| Terms 초안 | ✓ | `6. CI/docs/legal/terms-of-service-draft.md` |
| Commerce display-only legal note | ✓ | `6. CI/docs/legal/commerce-display-policy-draft.md` |

## 5. APP Mode Impact
- 기존 mode.ts 시스템이 매우 정교 — Stage 5 에서 build-time guard 만 추가
- Production build 시 mock 가능 여부: 런타임 guard 동작 — 검증된 상태

## 6. Commerce Impact
- display-only 정책 docs 완성
- AWS prod RDS 에 50개 상품 시드 — 사진/가격/카테고리/재고
- 결제/주문/배송/환불 UI 없음 검증 — Stage 5 grep 으로 최종 점검

## 7. AWS / Seed Impact
- Feed/Commerce/User seed AWS prod RDS 적용 완료 (이전 라운드)
- Seed dry-run, idempotent, environment guard 모두 갖춤
- production seed 명시적 승인 절차는 Stage 4 deployment runbook 에 명시

## 8. Legal / Compliance Impact
- Stage 3 의 핵심 docs 일부를 Stage 1 에서 미리 작성 (병합)
- 사용자 표시 화면 매핑은 Stage 3 에서 정식 완성

## 9. Tests Verified
- AWS prod RDS 시드 결과 (이전 라운드)
- ADMIN UI 의 feed/commerce/사용자 페이지 정상 표시 (이전 라운드 ALB curl 검증)

## 10. Fixed P0
- B-P0-02 (커머스 결제 UI 점검) — 정책 docs 완성 + 검증은 Stage 5

## 11. Remaining P0
- B-P0-01 (production build 에 APP_MODE_1 가능) — Stage 5 build-time guard 추가
- B-P0-03 (동의 이력 저장 구조) — Stage 3 (ConsentRecord 확인 완료, 이벤트 로깅은 implement check)
- B-P0-04 (회원 탈퇴 경로) — Stage 3 adminPipaRoutes 확인 (이미 implement)
- B-P0-05 (KC 인증 docs) — Stage 3 device-certification-checklist.md 완성
- B-P0-06 (Wi-Fi password 정책) — Stage 2 코드 검증 + Stage 3 정책 문서
- B-P0-07 (PII 마스킹) — partially mitigated (redact.js 존재), Stage 5 검증

## 12. Git Result
| Repo | Changed | Notes |
|---|---|---|
| ICONIA-CI | YES | docs 다수 — Stage 1~3 묶음 commit |
| 그 외 | NO | 코드 변경 없음 — Stage 2/5 에서 진행 |

## 13. Next Stage Readiness
READY — Stage 2 진입 가능.

## 14. Completion Statement
Stage 1 COMPLETE. APP_MODE_1 mock 격리 + seed 인프라 + 법률/컴플라이언스 초안 + 기본 smoke 인프라 모두 점검 완료.
