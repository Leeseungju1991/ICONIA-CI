# Stage 2 Report — Real Device Core Ready

## 1. Stage
Stage 2 - LEVEL 2 Real Device Core Ready

## 2. Status
COMPLETE

## 3. Summary
APP_MODE_2_REAL_DEVICE 흐름 점검. APP-HW BLE contract 일치 확인. Wi-Fi provisioning flow 검토. SERVER device provisioning API contract. ADMIN device 운영 흐름.

## 4. 검토 항목 + 결과

| 항목 | 상태 | 비고 |
|---|---|---|
| APP_MODE_2_REAL_DEVICE 정의 | ✓ | `4. APP/src/runtime/mode.ts` 의 production = real device, 다른 모든 모드는 development/preview |
| Release/prod app 이 real-device only | partial | 코드 런타임 guard 동작. EAS production profile 강제 (Stage 5) |
| Production mock 활성 시 fail | partial | mode.ts 가 production 에서 mock 거부, build-time fail 은 Stage 5 |
| APP BLE service UUID | ✓ | `4. APP/src/ble/contracts.ts` 의 SERVICE_UUID |
| HW BLE service UUID | ✓ | `1. HW/ICONIA Firmware/ICONIA_Firmware/iconia_protocol.h` |
| APP/HW characteristic UUID 비교 | ✓ | Stage 2 contract review (양측 일치) |
| APP/HW payload schema 비교 | ✓ | provisioning, status notify 등 schema 일치 |
| APP-HW BLE contract 문서 | partial | `4. APP/src/ble/contracts.ts` + `1. HW/ICONIA Firmware/.../iconia_protocol.h` 가 contract 의 실질적 정본. `docs/contracts/ble-contract.md` 작성은 Stage 6 wide test 시 |
| Wi-Fi provisioning flow sequence | partial | `4. APP/src/ble/provisioning.ts` + HW provisioning code — 별도 sequence diagram 은 Stage 6 |
| BLE scan/connect/pair/provision/status/disconnect | ✓ | App + HW 양측 구현됨 (commit 7d47ae0 의 안전 강화 포함) |
| Provisioning timeout/retry/backoff | ✓ | `4. APP/src/ble/provisioning.ts` 에 PROVISIONING_TIMEOUT_MS + retry |
| Device_id 처리 정책 | ✓ | UUID + factory seed + HMAC pairing token (`pairHmac.ts`) |
| Pairing token / factory seed / salt | ✓ | HMAC 기반 — `4. APP/src/ble/pairHmac.ts`, `1. HW/.../iconia_pair.cpp` |
| Wi-Fi credential 처리 경로 | ✓ | BLE 로 인형에 전송, 인형 내 보안 영역에 저장. **서버 비저장** (코드 검증 결과 — HD-09 의 잠정 결정) |
| **Wi-Fi password 서버 저장 여부** | ✓ (잠정) | `2. SERVER/prisma/schema.prisma` 의 `devices`/`user_device_links` 에 wifi_password 같은 컬럼 없음. SERVER 코드에서 wifi credential 수신/저장 라우트 없음. **검증 결과 비저장**. 최종 확정은 DPO (HD-09) |
| 서버 저장 시 P0 분류 | n/a | 서버 비저장 확인됨 |
| SERVER device provisioning API contract | ✓ | adminUserRoutes + provisioningService 의 contract — APP 측과 일치 |
| ADMIN 에서 device/user 상태 흐름 | ✓ | `5. ADMIN/app/dashboard/devices`, `dashboard/user-360` 페이지 — server API 연결 |
| AI API 실제 연결 | ✓ | App chatClient → SERVER → AI service 의 chain 동작 (preview1/2 검증) |
| APP/SERVER/HW contract test | partial | App 측 `handshake.test.ts`, `provisioning.test.ts` 존재. SERVER 측 test 다수. HW host test 존재. Cross-repo contract test 는 Stage 6 |
| Offline/retry/error boundary test | ✓ | App 측 offlineState.test.ts, AppErrorBoundary.test.tsx |
| Core smoke scenario | partial | App `src/__smoke__/` 존재. wide smoke 는 Stage 6 |

## 5. APP Mode Impact
- production = real device only (mode.ts 가 강제)
- preview/dev = 다양한 mock 조합 가능 (BLE-only mock, full mock, real backend + BLE mock)

## 6. Commerce Impact
- 변경 없음 (display-only 유지)

## 7. AWS / Seed Impact
- 변경 없음

## 8. Legal / Compliance Impact
- Wi-Fi password 서버 비저장 잠정 확인 — privacy policy 및 device-connection-policy 의 §2 정합
- HD-09 의 잠정 결정: "회사 서버에 저장되지 않음" — DPO 최종 확인 필요

## 9. Tests Verified
- App BLE/Wi-Fi 코드 + HW 펌웨어 contract 일치
- Server provisioning API 와 일치

## 10. Fixed P0
- B-P0-06 (Wi-Fi password 정책) — 코드 검증 결과 잠정 결정 + 문서화

## 11. Remaining P0
- B-P0-01 (production build mock guard) — Stage 5
- B-P0-03 (동의 이력 저장) — Stage 3 (확인 완료 → mitigated)
- B-P0-04 (회원 탈퇴 경로) — Stage 3 (이미 implement)
- B-P0-05 (KC 인증) — Stage 3 docs (완성됨)
- B-P0-07 (PII 마스킹 검증) — Stage 5

## 12. Git Result
- 변경 없음 — Stage 2 는 검토 위주 + docs 작성은 Stage 1/3 batch 에 포함

## 13. Next Stage Readiness
READY — Stage 3 진입 가능.

## 14. Completion Statement
Stage 2 COMPLETE. Real device 흐름 + APP-HW contract + Wi-Fi password 비저장 정책 검증 완료.
