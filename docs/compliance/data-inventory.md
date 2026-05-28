# Data Inventory

> ICONIA 가 수집/처리/저장하는 모든 데이터의 분류·목적·보관기간·처리자.

## 1. Identity / Account Data

| Field | 분류 | 수집 시점 | 목적 | 보관 기간 | 저장 위치 | 제3자 제공 |
|---|---|---|---|---|---|---|
| email | 개인정보 | 회원가입 | 로그인, 알림 | 탈퇴 시 즉시 익명화 + 24개월 보관 후 폐기 | RDS `users.email` | 없음 |
| password_hash | 보안정보 | 회원가입 | 인증 | 동일 | RDS `users.password_hash` (bcrypt) | 없음 |
| display_name | 일반정보 | 회원가입/설정 | UX 표시 | 동일 | RDS `users.display_name` | 없음 |
| user_id (UUID) | 식별자 | 자동 | 내부 PK | 동일 | RDS `users.id` | 없음 |
| account_status | 운영 데이터 | 자동 | active/paused/pending_deletion | 동일 | RDS `users.account_status` | 없음 |

## 2. Consent / Legal Data

| Field | 분류 | 수집 시점 | 목적 | 보관 기간 | 저장 위치 |
|---|---|---|---|---|---|
| consent_terms_version | 동의 이력 | 회원가입/재동의 | 약관 동의 증거 | 5년 (정보통신망법 권고) | RDS `users` + `consent_records` |
| consent_privacy_version | 동의 이력 | 동일 | 개인정보 동의 증거 | 5년 | 동일 |
| marketing_opt_in | 선택 동의 | 회원가입/설정 | 마케팅 발송 권한 | 동의 철회 시 즉시 무효 | RDS `users` |
| additional_consents (JSONB) | 동의 이력 | ConsentScreen | age_verification_19plus, third_party_gemini, analytics_improvement | 5년 | RDS `users.additional_consents` |
| consent_records.* | 동의 이력 | 변경 시마다 | 동의/철회 변경 이력 | 5년 | RDS `consent_records` 테이블 |

## 3. Device / HW Data

| Field | 분류 | 수집 시점 | 목적 | 보관 기간 | 저장 위치 |
|---|---|---|---|---|---|
| device_id (UUID) | 식별자 | 페어링 | 디바이스-사용자 매핑 | 페어링 해제 시 익명화 | RDS `devices.id` |
| serial | 식별자 | 양산 | AS, 인증 | 영구 (제품 lifecycle) | RDS `device_serials` |
| firmware_version | 운영 | OTA | 호환성, 롤백 | 영구 | RDS `devices.firmware_version` |
| last_seen_at | 운영 | 자동 | 디바이스 살아있음 모니터링 | 30일 | RDS `devices.last_seen_at` |
| last_battery_percent | 운영 | telemetry | 사용자 알림 | 30일 | RDS `devices.last_battery_percent` |
| hw_device_id (BLE MAC) | 식별자 | 페어링 | BLE 재연결 | 페어링 해제 시 폐기 | RDS `user_device_links` |
| BLE 진단 (RSSI, error code) | 진단 | telemetry | 운영 (개인 비식별) | 30일 | CloudWatch logs |

## 4. Wi-Fi Provisioning Data

| Field | 분류 | 수집 시점 | 목적 | 보관 기간 | 저장 위치 |
|---|---|---|---|---|---|
| SSID | 일반정보 | 프로비저닝 | 사용자 자기 정보 | (조건부) — 서버 저장 여부 결정 필요 | (HD-09 결정) |
| **Wi-Fi password** | **민감정보** | 프로비저닝 | 인형 Wi-Fi 연결 | **서버 비저장 (BLE 전송 후 사용자 디바이스에만 보관) — 코드 검증 후 정책 확정** | (확인 필요 — HD-09) |
| provisioning_status | 운영 | 자동 | 디버그 | 7일 | CloudWatch logs |

## 5. Chat / AI Data

| Field | 분류 | 수집 시점 | 목적 | 보관 기간 | 저장 위치 |
|---|---|---|---|---|---|
| chat_message.role | 운영 | 채팅 시마다 | 대화 흐름 | 90일 | RDS `chat_messages` |
| chat_message.content | 잠재적 민감 (사용자 입력) | 채팅 시마다 | AI 응답 + 컨텍스트 | 90일 | RDS `chat_messages` (PII redaction 적용) |
| chat_message.persona_id | 운영 | 자동 | 페르소나 일관성 | 동일 | RDS `chat_messages` |
| AI provider request/response | 운영 | API 호출 시 | 디버그, 비용 | 30일 (redact 후) | CloudWatch logs |
| persona memories (RAG) | 운영 | 자동 | 페르소나 기억 | 사용자 탈퇴 시 폐기 | EFS / S3 (AI side) |

## 6. Feed / UGC / Commerce Data

| Field | 분류 | 수집 시점 | 목적 | 보관 기간 | 저장 위치 |
|---|---|---|---|---|---|
| feed_posts.content | 사용자 입력 | 게시 시 | 피드 표시 | 게시물 삭제 시 30일 후 폐기 | RDS `feed_posts` |
| feed_media.url | 운영 | 게시 시 | 사진/영상 노출 | 게시물과 동일 | RDS `feed_media` + S3 |
| feed_comments.content | 사용자 입력 | 댓글 시 | 표시 | 동일 | RDS `feed_comments` |
| products.* | 운영 데이터 | 상품 등록 | display-only | 영구 (운영자 관리) | RDS `products` |

## 7. Audit / Operational Logs

| Field | 분류 | 수집 시점 | 목적 | 보관 기간 | 저장 위치 |
|---|---|---|---|---|---|
| audit_logs.* | 감사 | 운영자 mutate 시 | 개인정보 접근 통제 (L-01) | **5년** | RDS `audit_logs` (hash chain) |
| operator_sessions.* | 보안 | 운영자 로그인 | 세션 추적 | 90일 | RDS `operator_sessions` |
| request_id / correlation_id | 운영 | 자동 | 장애 추적 | 30일 | CloudWatch logs |

## 8. 제3자 Processor 처리 데이터

| Processor | 처리 데이터 | 처리 목적 | 위치 | 동의/위탁 |
|---|---|---|---|---|
| AWS (RDS, S3, EFS, CloudWatch, ECR, EC2) | 모든 운영 데이터 | 서비스 운영 | ap-northeast-2 | 위탁 (cross-border 없음) |
| Google (Gemini API) | 사용자 입력 + 페르소나 컨텍스트 | AI 응답 생성 | US region | 사용자 동의 (HD-02), 국외이전 동의 (HD-18) |
| (선택) Sentry / Datadog | 에러/메트릭 (redact 후) | 운영 가시성 | 결정 필요 (HD-13) | — |

## LEGAL_REVIEW_REQUIRED
모든 보관 기간, 익명화 시점, 폐기 절차는 DPO + 법무 검토 필요. 본 inventory 는 초안.
