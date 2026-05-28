# Compliance Matrix

> 법령(legal-register.md) ↔ 제품 통제 ↔ 코드/문서/감사 증적 매핑.

| Control ID | Control Description | Legal Source | Implementation (Repo / File) | Evidence Source | Status |
|---|---|---|---|---|---|
| C-001 | 회원가입 시 이용약관 동의 수집 | L-02, L-03 | APP `src/screens/ConsentScreen.tsx`, SERVER `prisma/schema.prisma` (ConsentRecord) | SERVER `consent_records` 테이블 row | implemented |
| C-002 | 회원가입 시 개인정보 수집·이용 동의 | L-01, L-02 | APP `src/screens/ConsentScreen.tsx`, SERVER `additional_consents` JSONB | SERVER `users.additional_consents` | implemented |
| C-003 | 선택 마케팅 동의 분리 | L-02 | APP ConsentScreen, SERVER `users.marketing_opt_in` | DB column | implemented |
| C-004 | 14세 미만 / 미성년자 가입 제한 (성인 대상 제품) | L-12 | APP ConsentScreen `age_verification_19plus` | SERVER `additional_consents.age_verification_19plus` | partially (자가 확인) |
| C-005 | 제3자 제공 동의 (Gemini) | L-01, L-02 | APP ConsentScreen `third_party_gemini` | SERVER `additional_consents.third_party_gemini` | implemented |
| C-006 | 위치정보 동의 (사용 시) | L-04 | (조건부 — 현재 GPS 미사용) | — | n/a (현재) |
| C-007 | 동의 철회/탈퇴 경로 | L-01 | APP `src/screens/Settings/AccountDeletion.tsx`, SERVER `adminPipaRoutes` | audit log + pending_deletion_at | implemented |
| C-008 | 개인정보 보관 기간 정책 | L-01 | `docs/compliance/data-retention-policy.md` (draft) + SERVER `scripts/retention-apply.js` | retention runner log | partially |
| C-009 | 개인정보 처리 위탁 (제3자 processor) | L-01 | `docs/compliance/third-party-processors.md` | 위탁계약서 (외부) | partially |
| C-010 | 국외 이전 동의 (AWS region, Gemini US) | L-01 | `docs/compliance/cross-border-transfer-checklist.md` | 동의 화면 + audit | draft |
| C-011 | AI 응답 면책/리스크 안내 | L-09 | APP `src/screens/Settings/AiDisclosure.tsx` (or equivalent), AI service header | 화면 캡처 + audit | partially |
| C-012 | AI 학습 데이터 사용 동의 | L-01, L-09 | (현재 학습 미사용 — 운영자 정책 명시) | `docs/legal/ai-disclosure-policy-draft.md` | draft |
| C-013 | 디바이스 식별자 수집 고지 | L-01 | APP `src/screens/Settings/DeviceConnectionNotice.tsx` (or equivalent) | 화면 + audit | partially |
| C-014 | BLE/Wi-Fi 권한 사용 사유 명시 | L-02 + 모바일 OS 정책 | APP `Info.plist` / `AndroidManifest.xml` + 화면 안내 | manifest + 화면 | partially |
| C-015 | 운영자 권한·감사 로그 | L-01 (개인정보 접근통제), L-13 | SERVER `audit_logs` 테이블 + ADMIN `dashboard/ops/audit` | DB rows | implemented |
| C-016 | 운영자 MFA + 강제 정책 | 보안 정책 | SERVER `operator_totp` + ADMIN MFA flow | DB rows + UI | implemented |
| C-017 | KC 적합성평가 | L-07 | HW 양산 출하 전 외부 인증 | `docs/operations/device-certification-checklist.md` | draft |
| C-018 | OTA 펌웨어 anti-rollback | (보안 정책) | HW `iconia_config.h` SECURE_VERSION + SERVER `firmware_deployments` | OTA audit | implemented (commit 7d47ae0) |
| C-019 | 결제 기능 미구현 (display-only) | L-05 (현 시점 비적용) | UI 검증 — 결제/주문/배송 문구 grep | Stage 5 final scan | open (Stage 5 검증) |
| C-020 | 오픈소스 라이선스 고지 | L-11 | APP `src/screens/Settings/OpenSourceLicenses.tsx` (or equivalent) + 자동 생성 | npm-license-checker output | partially |
| C-021 | 운영 로그 PII 마스킹 | L-01 | SERVER `src/utils/redact.js` + AI `redactPii.js` | log review | implemented |
| C-022 | 백업·복구 정책 | (운영 + 개인정보보호법 안전성 확보 조치) | `docs/operations/backup-restore-runbook.md` + AWS RDS automated backup | RDS snapshot + runbook | partially |
| C-023 | 개인정보 침해사고 대응 절차 | L-01 (5일 이내 신고) | `docs/operations/personal-data-breach-runbook.md` | runbook | draft |
| C-024 | 정보주체 권리 요청 처리 | L-01 | SERVER `adminPipaRoutes` (export, finalize) + ADMIN `users/rights` 페이지 | audit log | implemented |

## Legend
- **implemented**: 코드/문서 모두 갖춰짐, 운영 가능
- **partially**: 일부 구현 — Stage 3 또는 Stage 7 에서 보강
- **draft**: 초안만 있음, 법무 검토 대기
- **n/a**: 현 시점 적용 불가 (조건부)

## LEGAL_REVIEW_REQUIRED
모든 control 의 implementation 적정성 + 사용자 노출 문구는 법무 검토 후 확정.
