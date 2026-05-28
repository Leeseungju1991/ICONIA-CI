# Consent Matrix

> 사용자에게 받는 동의 항목 ↔ 화면 ↔ DB 저장 ↔ 철회 경로.

| Consent ID | 항목 | 필수/선택 | 화면 | DB 저장 위치 | 철회 경로 | 거부 시 영향 | 법령 근거 |
|---|---|---|---|---|---|---|---|
| CN-01 | 이용약관 동의 | 필수 | ConsentScreen | `users.consent_terms_version`, `consent_records` | 회원 탈퇴만 가능 | 가입 불가 | 약관규제법 |
| CN-02 | 개인정보 수집·이용 동의 | 필수 | ConsentScreen | `users.consent_privacy_version`, `consent_records` | 회원 탈퇴만 가능 | 가입 불가 | 개인정보보호법 |
| CN-03 | 만 19세 이상 본인 확인 | 필수 | ConsentScreen | `additional_consents.age_verification_19plus` | 회원 탈퇴만 가능 | 가입 불가 | 청소년보호법 |
| CN-04 | 제3자 제공 동의 (Google Gemini) | 필수 (AI 사용 시) | ConsentScreen | `additional_consents.third_party_gemini` | 설정 > 동의 내역 관리 | AI 페르소나 응답 사용 불가 | 개인정보보호법 |
| CN-05 | 국외 이전 동의 (Gemini US) | 필수 (AI 사용 시) | ConsentScreen | `additional_consents.cross_border` | 설정 > 동의 내역 관리 | AI 페르소나 응답 사용 불가 | 개인정보보호법 |
| CN-06 | 마케팅 정보 수신 동의 | 선택 | ConsentScreen + 설정 | `users.marketing_opt_in` | 설정 > 마케팅 수신 | 마케팅 알림 미수신 | 정보통신망법 |
| CN-07 | 분석·서비스 개선 동의 | 선택 | ConsentScreen | `additional_consents.analytics_improvement` | 설정 > 동의 내역 관리 | 익명 분석 미활용 | — |
| CN-08 | 위치정보 이용 동의 | 조건부 (현재 미사용) | (해당 시 추가) | (해당 시) `additional_consents.location` | 설정 > 권한 | 위치 기능 미사용 | 위치정보법 |
| CN-09 | BLE 권한 (모바일 OS) | 필수 (디바이스 페어링 시) | OS 권한 prompt | OS managed | OS 설정에서 회수 | 디바이스 페어링 불가 | OS 정책 |
| CN-10 | Wi-Fi 권한 (모바일 OS) | 필수 (디바이스 프로비저닝 시) | OS 권한 prompt | OS managed | OS 설정에서 회수 | 프로비저닝 불가 | OS 정책 |
| CN-11 | 알림 권한 (푸시) | 선택 | OS 권한 prompt + 설정 | `push_tokens` 테이블 | 설정 > 알림 | 푸시 미수신 | OS 정책 + 마케팅법 |
| CN-12 | 재동의 (약관/방침 개정 시) | 필수 | ReconsentModal | `consent_records` 신규 row | 회원 탈퇴 | 서비스 사용 제한 | 개인정보보호법 |

## 동의 이력 보관 정책

- 모든 동의·철회 이력은 `consent_records` 테이블에 `text_hash`, `ip`, `user_agent`, `created_at` 와 함께 영구 기록 (5년 권고).
- 동의 철회는 새 `granted=false` row 로 기록되며, 기존 row 는 수정·삭제하지 않는다 (감사 무결성).
- 사용자가 탈퇴 시 5년 보관 기간 만료 후 완전 폐기.

## 검증 (Stage 6 E2E)

- ConsentScreen → 필수 동의 거부 시 가입 불가 (UI test)
- 회원 가입 후 `consent_records` row 자동 생성
- 설정 > 동의 내역 관리 → 모든 항목 표시
- 동의 철회 → 새 row 자동 추가 + AI 기능 비활성
- 약관/방침 개정 시 ReconsentModal 자동 표시 + 미동의 시 진입 차단
