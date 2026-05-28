# Admin Operation Policy

> 운영자의 ICONIA Admin Console 접근·권한·감사·생명주기 정책.

## 1. 운영자 분류

| Role | 권한 범위 | MFA | 정기 review |
|---|---|---|---|
| `superadmin` | 전체 (사용자 삭제, secret rotate, terms 발행 등) | 필수 | 분기 |
| `secops` | 보안 통제 (감사 로그, IP allowlist, 키 회전) | 필수 | 분기 |
| `sre` | 운영 (배포, 알람, 인시던트) | 필수 | 분기 |
| `cs` | 고객 응대 (사용자 조회, 동의 이력 조회, 신고 처리) | 필수 | 반기 |
| `viewer` | 읽기 전용 | 권장 | 연 1회 |

## 2. 계정 발급 절차

1. 인사 부서 → IT/보안 부서 의뢰 (직책·기간 명시)
2. ADMIN `dashboard/operators` 에서 신규 운영자 생성
3. 초대 이메일 → 신규 운영자가 비밀번호 + TOTP 설정
4. **첫 로그인 시 MFA 강제 등록**
5. 발급 일자/사유 → `audit_logs` 자동 기록

## 3. 운영자 lifecycle (HD-19)

### 3.1 입사 시
- 위 발급 절차 + 직무 교육 (개인정보 보호, AI 안전, 인시던트 대응)

### 3.2 직책 변경 시
- 새 role 부여 + 이전 role revoke
- `audit_logs` 에 변경 사유 기록 (5자 이상)
- 새 권한 범위 7일 점검 (사고 확인)

### 3.3 퇴사 시 (반드시 수행)
- [ ] **즉시**: 운영자 계정 비활성화 (ADMIN `operators/:id/pause`)
- [ ] **즉시**: refresh token 전부 revoke
- [ ] **24시간 이내**: 운영자 계정 영구 삭제 또는 archive
- [ ] **TOTP secret 폐기**
- [ ] **IP allowlist 에서 제거** (해당 시)
- [ ] **백업 시스템 (BitWarden 등) 의 공유 항목 회수**
- [ ] **퇴사 처리 → `audit_logs` 기록 + 인사부 통지**

### 3.4 장기 미접속 (90일 이상)
- 자동 알람 → `secops` 가 검토
- 필요 시 비활성화 → 본인 확인 후 재활성

## 4. 운영자 접근 통제

| 항목 | 정책 |
|---|---|
| 비밀번호 정책 | 12자 이상, 영문 대소문자 + 숫자 + 특수문자 + 사전 단어 차단 |
| 비밀번호 변경 주기 | 90일 권장 |
| 세션 timeout | 60분 무활동 시 자동 로그아웃 |
| Concurrent session | 최대 3개 |
| IP allowlist | 회사 사무실 + VPN IP 만 허용 (HD-09 확정 후) |
| TOTP MFA | superadmin/secops/sre/cs 필수 |
| Backup code | 10개 발급, 1회용 |

## 5. 운영 작업 감사

ADMIN 의 모든 mutate 작업은 `audit_logs` 에 자동 기록:
- 작업 시각, 운영자 ID, role, IP, User-Agent
- 변경 사유 (5자 이상 강제)
- target 리소스 (user_id, device_id, post_id 등)
- 결과 (success/failed/queued)
- hash chain 으로 변조 방지

## 6. 정기 review

- **분기 1회 (superadmin/secops/sre)**: 권한 적정성 검토
- **반기 1회 (cs/viewer)**: 활성 운영자 점검
- **연 1회**: 전체 정책 갱신

## 7. 외부 감사 대응

- 개인정보 보호위원회 점검 요청 시 `audit_logs` export 가능
- ADMIN `dashboard/ops/audit` 에서 CSV export
- 5년 이상 보관

## 8. LEGAL_REVIEW_REQUIRED

- HD-19: 퇴사 시 lifecycle 의 사내 인사·보안 정책 일치 확인
- HD-15: 본인 확인 절차 (성인 대상 제품 - 운영자도 적용)
