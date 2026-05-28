# 개인정보 보관 기간 정책 (Draft — DPO Review Required)

> 본 정책은 ICONIA 가 수집한 데이터의 보관·익명화·폐기 일정을 정의한다. 법령상 의무 보관 기간 + 운영 필요성 + 최소 수집 원칙을 균형.

## 1. 보관 기간 매트릭스

| 카테고리 | 데이터 | 보관 기간 | 보관 후 처리 | 법령 근거 |
|---|---|---|---|---|
| 회원 정보 | email, password_hash, display_name | 탈퇴 시 즉시 익명화 + 24개월 후 완전 폐기 | DELETE row | 개인정보보호법 (불필요 시 폐기) |
| 동의 이력 | consent_records, additional_consents | 5년 | DELETE row | 정보통신망법 권고 |
| 결제·청구 기록 | (해당 없음 — display-only) | — | — | 전자상거래법 (해당 없음) |
| 접속 로그 (개인정보 접근) | audit_logs (개인정보 접근 카테고리) | 5년 | DELETE row | 개인정보보호법 안전성 확보 조치 |
| 일반 운영 로그 | request_id, correlation_id 기반 application log | 30일 | CloudWatch retention | — |
| AI 대화 내용 | chat_messages (PII redaction 후) | 90일 | DELETE row → 익명 통계만 보존 | 최소 수집 |
| AI provider 호출 로그 | Gemini 요청/응답 (redact 후) | 30일 | DELETE row | — |
| 피드 게시물·댓글 | feed_posts, feed_comments (활성) | 사용자가 삭제 또는 takedown 시까지 | takedown 후 30일 후 DELETE | 자기 정보결정권 |
| 피드 신고 데이터 | feed_reports | 처리 완료 후 1년 | DELETE row | — |
| 디바이스 데이터 | devices, user_device_links | 페어링 해제 시 익명화 + 24개월 후 완전 폐기 | DELETE row | 최소 수집 |
| 디바이스 진단 로그 | telemetry, BLE 진단 | 30일 | CloudWatch retention | — |
| 펌웨어 배포 이력 | firmware_deployments | 영구 | — | 안전성 추적 (anti-rollback) |
| Push token | push_tokens | revoked_at + 90일 후 폐기 | DELETE row | — |

## 2. 자동 보관/폐기 운영

- **Retention runner**: `2. SERVER/scripts/retention-apply.js` 실행 — 일간 cron (CloudWatch Events)
  - chat_messages: created_at < now - 90d → DELETE
  - audit_logs: created_at < now - 5y → DELETE
  - 회원 탈퇴 후 24개월 경과: scheduled_purge_at 기반 DELETE
- **Backup**: AWS RDS automated backup 7일 + 주간 snapshot 4주 보관
- **삭제 인증**: deletion certificate 발급 — `2. SERVER/src/services/deletionCertificate.js`

## 3. 익명화 정책

- email: SHA-256 해시 + salt 로 비복원 변환
- display_name: NULL 처리
- device_id, hw_device_id (MAC): 익명 식별자로 변환 (운영 통계용)
- chat_messages.content: PII redact 후 보존 (학습/통계용)

## 4. 사용자 권리 행사 시

| 권리 | 처리 방법 | SLA |
|---|---|---|
| 열람 | 앱 설정 > 내 정보 + ADMIN 운영자가 수동 발급 | 즉시 (앱) / 10일 이내 (수동) |
| 정정 | 앱 설정 + 고객지원 문의 | 즉시 |
| 처리 정지 | 고객지원 문의 → pending_deletion_at | 10일 이내 |
| 삭제 | 앱 설정 > 회원 탈퇴 → adminPipaRoutes finalize | 즉시 익명화 + 24개월 후 완전 폐기 |
| 동의 철회 | 앱 설정 > 동의 내역 관리 | 즉시 |

## 5. LEGAL_REVIEW_REQUIRED (HD-17)

각 보관 기간의 법적 적정성은 DPO + 법무 검토 후 확정.
