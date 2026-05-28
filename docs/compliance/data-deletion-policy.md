# 개인정보 삭제 정책 (Draft — DPO Review Required)

## 1. 사용자 권리 행사 (열람·정정·삭제·이전)

근거: 개인정보 보호법 제35조~제37조 + 제35조의2 (자동화된 결정에 대한 권리)

## 2. 사용자 측 삭제 경로

### 2.1 회원 탈퇴 (전체 삭제)

- **경로**: 앱 설정 > 회원 탈퇴
- **확인**: 비밀번호 재입력 + "DELETE" 확인 문구
- **즉시 처리**: `users.account_status = 'pending_deletion'`, `pending_deletion_at = now()`
- **30일 grace period**: 사용자가 마음을 바꾸어 재로그인 시 복구 가능
- **30일 경과 후**: `adminPipaRoutes` finalize 자동 실행 → 익명화
- **24개월 후**: scheduled_purge_at 도래 → 완전 폐기 (DELETE row)
- **증적**: `audit_logs` 에 모든 단계 기록 + deletion certificate 발급

### 2.2 부분 삭제 (특정 데이터)

- **피드 게시물**: 게시물 우측 메뉴 > 삭제 → 즉시 soft delete (`removed_at`) + 30일 후 hard delete
- **댓글**: 동일
- **AI 대화 내역**: 설정 > AI 기록 관리 > 전체 삭제 (90일 retention 보다 빠르게)
- **디바이스 페어링 해제**: 설정 > 디바이스 > 해제 → `user_device_links` row 익명화

### 2.3 동의 철회

- **경로**: 설정 > 동의 내역 관리
- **즉시 처리**: `consent_records` 에 `granted=false` 신규 row 추가 + 관련 기능 비활성
- **재동의**: 동일 화면에서 다시 동의 가능 (새 row)

## 3. 운영자 측 삭제 처리 (정보주체 권리 요청 응대)

### 3.1 요청 접수
- 고객지원 이메일 (privacy_officer_email — HD-01) 로 접수
- ADMIN `dashboard/users/rights` 페이지로 등록

### 3.2 처리 절차
1. 요청자 본인 확인 (이메일 인증 또는 회원 정보 일치)
2. `adminPipaRoutes /api/v1/admin/users/:id/pipa/export` 호출 → 사용자 데이터 export (열람·이전 요청 시)
3. `adminPipaRoutes /api/v1/admin/users/:id/pipa/finalize` 호출 → 삭제 (삭제 요청 시)
4. deletion certificate 발급 + 사용자에게 이메일 통지
5. `audit_logs` 에 처리 결과 기록

### 3.3 SLA
- 접수 후 **10일 이내** 처리 완료 (개인정보 보호법 권고)
- 복잡한 경우 사용자에게 사유 통지 + 추가 20일 연장 가능

## 4. 자동 삭제 운영

`2. SERVER/scripts/retention-apply.js` 가 매일 실행:

- `chat_messages` 90일 초과 → DELETE
- `audit_logs` 5년 초과 → DELETE
- `users.scheduled_purge_at` 도래 → DELETE
- `feed_posts.removed_at + 30d` → DELETE
- `push_tokens.revoked_at + 90d` → DELETE

## 5. 백업에서의 삭제

- **AWS RDS automated backup**: 7일 retention — 사용자 삭제 후 7일 후 자동 만료
- **Manual snapshot**: 사용자 삭제 요청 시 별도 검토 — 필요 시 snapshot 에서도 데이터 제거 (특수 경우)

## 6. LEGAL_REVIEW_REQUIRED

- 30일 grace period 의 법적 적정성 (DPO 확인)
- 5년 audit_log 보관의 법적 근거 (개인정보 보호법 시행령 등)
- HD-01 (개인정보 보호책임자 연락처) 확정
