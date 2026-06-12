# ICONIA 출시 전 운영팀 액션 체크리스트 (OPS_HANDOFF)

이 문서는 **(주)숨코리아 운영팀 · 법무 · CTO** 가 ICONIA 정식 출시(GA, General
Availability) 직전 반드시 완료해야 할 7개 액션을 정리한다.

대상 독자: 비개발 운영팀. 명령어/엔지니어링 용어는 최소화하고, **누가 / 언제 /
어디에 입력 / 어떻게 확인** 4축으로 항목마다 명시한다.

- **표기 규약**:
  - SERVER = `2. SERVER` 레포 (Node.js API)
  - APP    = `4. APP`    레포 (Expo 모바일 앱)
  - ADMIN  = `5. ADMIN`  레포 (Next.js 관리 콘솔)
  - CI     = `6. CI`     레포 (본 레포 — 인프라/배포)
- **출시 D-day** = 정식 서비스 오픈일 (예: 2026-06-15).
- 모든 액션은 D-day **이전** 완료가 원칙. D+0 에 발견된 누락은
  `aws-deploy.ps1` 의 release-preflight 가 차단한다.

---

## 액션 1. 사업자 정보 입력 (D-7)

**누가**: 운영팀 (대표자 / 사업자등록 책임자)
**언제**: 출시 D-7 까지

### 입력 항목 (9종)

| 항목 | 형식 | 비고 |
|---|---|---|
| `BUSINESS_REGISTRATION_NUMBER` | `130-86-41024` | 국세청 발급 사업자등록번호 (확정) |
| `BUSINESS_MAIL_ORDER_NUMBER`   | `제 2026-서울XX-XXXX호` | 통신판매업 신고증 (관할 구청, 결제 도입 시 신고) |
| `BUSINESS_COMPANY_NAME`        | `(주)숨코리아` | 정식 법인명 (영문/한문 일관) |
| `BUSINESS_CEO_NAME`            | 한국 실명 | 법인등기부등본 대표자 |
| `BUSINESS_ADDRESS`             | 본사 도로명주소 | 등기부와 일치 |
| `BUSINESS_PHONE`               | `02-2038-2935` | 사업자 대표 전화 (확정) |
| `BUSINESS_SUPPORT_PHONE`       | `02-2038-2935` | 고객센터 전화 (확정) |
| `BUSINESS_EMAIL`               | `web@soomkorea.com` | 고객 응대 메일함 (실 운영) |
| `BUSINESS_KAKAO_CHANNEL`       | `@iconia` (선택) | 카카오톡 채널 ID |
| `BUSINESS_CS_HOURS`            | `평일 10:00-18:00` | 고객센터 운영시간 |
| `BUSINESS_DPO_NAME`            | `이승주` | 개인정보 보호책임자 성명 (확정) |

### 입력 위치

- **SERVER**: `2. SERVER/.env.prod` 의 `BUSINESS_*` 9개 환경변수
  - 권장: AWS Secrets Manager 의 `iconia/prod/server/business` 에 JSON 으로 저장
    → EC2 systemd unit 이 부팅 시 자동 fetch
  - 평문 `.env.prod` 커밋 금지 — `.gitignore` 에 포함

### 검증

- [ ] `pwsh scripts/preflight-placeholders.ps1 -RepoRoot <ICONIA root>` 실행 후
      "PASS" 출력 (LEGAL 패턴 4종 — `__TBD__` / `__PLACEHOLDER__` /
      `XXX-XX-XXXXX` / `Soom Korea Inc. (placeholder)` 모두 잔존 없음)
- [ ] ADMIN 콘솔 `https://admin.<root_domain>/settings/business` 접속 →
      "사업자 정보" 화면에 9개 값이 정상 표시
- [ ] APP 의 결제 화면 하단 footer 에 사업자번호 / 통신판매업 번호 정상 표시

---

## 액션 2. 개인정보 보호 책임자(DPO) 지정 (D-7)

**누가**: 운영팀 + CTO (DPO 직책자 결정)
**언제**: 출시 D-7 까지
**법적 근거**: 개인정보 보호법 (PIPA) §31 — 일정 규모 이상 사업자는 DPO 지정 의무

### 입력 항목

| 항목 | 형식 | 권장 기본값 |
|---|---|---|
| `DPO_NAME`             | 실명 | 이승주 (확정) |
| `DPO_DEPARTMENT`       | 부서 / 직책 | 운영팀 확정 자리 |
| `DPO_CONTACT_EMAIL`    | 회사 도메인 메일 (개인 메일 금지) | 운영팀 확정 자리 |
| `DPO_CONTACT_PHONE`    | 대표 번호 또는 내선 | 운영팀 확정 자리 |

### 입력 위치

- SERVER `.env.prod` 또는 Secrets Manager `iconia/prod/server/dpo`
- 약관 본문 자동 반영: `docs/legal/privacy_policy.md` 의 `{{DPO_NAME}}` 토큰 치환

### 검증

- [ ] APP 회원가입 → 개인정보처리방침 모달 본문에 DPO 이름 + 연락처 노출
- [ ] ADMIN `/settings/privacy` 에서 DPO 정보가 노출
- [ ] 외부 메일 송신 테스트: `<DPO_CONTACT_EMAIL>` 로 더미 정보주체 권리행사 요청
      메일 송신 → 24h 내 회신 가능 여부 확인

---

## 액션 3. 약관 시행일 · 법무 검토 확정 (D-3)

**누가**: 법무 (외부 자문 변호사 + 사내 법무 담당)
**언제**: 출시 D-3 까지 (영문/중국어 번역 검토 포함)

### 작업 항목

#### 3.1 약관 시행일 결정

| 약관 | 위치 | 시행일 필드 |
|---|---|---|
| 서비스 이용약관 | `docs/legal/terms-of-service.md` | YAML front-matter `effective_date: __FILL_BY_LEGAL__` |
| 개인정보 처리방침 | `docs/legal/privacy-policy.md` | `effective_date: __FILL_BY_LEGAL__` |
| 마케팅 정보 수신 동의 | `docs/legal/marketing-consent.md` | `effective_date: __FILL_BY_LEGAL__` |

(위치정보 정책은 본 서비스에서 위치정보를 수집·이용하지 않으므로 적용 대상이 아닙니다.)

각 파일 헤더의 `__FILL_BY_LEGAL__` 토큰을 실제 시행일 (`2026-06-15` 형식) 로 교체.

#### 3.2 한국어 본문 법무 검토

- 4종 약관 한국어 본문에 외부 자문 변호사 서명·날인
- 검토 의견은 `docs/legal/legal_review/2026-06-XX-review.pdf` 로 보관 (gitignore)

#### 3.3 영문 / 중국어 번역 검토

- `APP/src/copy/terms/en/*.ts` (영문) — 글로벌 출시 1단계
- `APP/src/copy/terms/zh/*.ts` (중국어) — 글로벌 출시 2단계
- 번역체 검수: 원어민 변호사 또는 공인 번역업체 인증

### 검증

- [ ] APP 회원가입 화면에서 4종 약관 모달이 정상 표시 (한/영/중 모두)
- [ ] `pwsh scripts/preflight-placeholders.ps1` 가 `__FILL_BY_LEGAL__` 잔존 0 확인
- [ ] 약관 PDF export → 외부 자문 변호사 서명본 보관

---

## 액션 4. AWS Secrets Manager 11종 secret 등록 (D-3)

**누가**: 운영팀 (AWS 콘솔 접근 권한 보유자 — 보안 책임자)
**언제**: 출시 D-3 까지

### 등록 대상 11종

| Secret 경로 | 용도 | 형식 |
|---|---|---|
| `iconia/prod/server/db-password`               | RDS 마스터 비밀번호 | 32+ char (대소문자+숫자+특수) |
| `iconia/prod/server/jwt-private-key`           | JWT 발급 (RS256) | PEM (BEGIN PRIVATE KEY) |
| `iconia/prod/server/jwt-public-key`            | JWT 검증 (RS256) | PEM (BEGIN PUBLIC KEY) |
| `iconia/prod/server/pepper`                    | 비밀번호 hash pepper | 64 hex char |
| `iconia/prod/ai/gemini-api-key`                | Gemini API 호출 | 외부 발급 (Google AI Studio) |
| `iconia/prod/server/payment-key`               | 결제 게이트웨이 (TossPayments/PG) | 외부 발급 |
| `iconia/prod/server/internal-ingest-token`     | AI → SERVER 내부 ingest | 32+ hex char |
| `iconia/prod/server/age-verification-secret`   | 본인인증 토큰 서명 | 32+ hex char |
| `iconia/prod/server/sso-state-secret`          | SSO state HMAC | 32+ hex char |
| `iconia/prod/admin/totp-encryption-key`        | 운영자 TOTP seed 암호화 | 32 hex char (AES-256) |
| `iconia/prod/shared/audit-hmac-key`            | 감사 로그 hash chain | 64 hex char |

### 입력 위치

- AWS 콘솔 → Secrets Manager (ap-northeast-2) → "Store a new secret"
- 형식: 위 표 그대로 — Key/value pairs 가 아니라 **Plaintext** 권장 (단일 값)
- 권장: `scripts/seed-db-password.ps1` 가 DB 비밀번호 1종은 자동 생성·등록.
  나머지 10종은 콘솔에서 수동 등록.

### 검증

- [ ] AWS CLI: `aws secretsmanager list-secrets --region ap-northeast-2 --query
      'SecretList[?starts_with(Name, \`iconia/prod\`)].Name'` → 11개 노출
- [ ] EC2 인스턴스 시작 직후 `journalctl -u iconia-server` 에 "secrets loaded
      (11/11)" 라인 출력
- [ ] AI 서비스 부팅 후 `/v1/admin/secrets/health` (관리자 전용) → `{"loaded":
      11, "missing": []}` 응답
- [ ] Gemini API 호출 더미 요청 → 401 이 아닌 정상 응답 코드 (200 / 4xx-business)

### 보안 주의

- Secret 값 평문이 슬랙·메일·티켓에 절대 노출되지 않도록 운영팀 1인이
  AWS 콘솔에서 직접 입력
- 입력 후 즉시 KMS 키 회전 정책 확인 (`iconia/prod/db-password` 는
  Lambda rotator 가 30일 자동 회전 — `terraform/rds-password-rotation.tf`)

---

## 액션 5. APP 크래시 추적 (Sentry) 연결 (D-3)

**누가**: 운영팀 (Sentry 계정 보유자) + APP 빌드 담당
**언제**: 출시 D-3 까지 (preview3 빌드 직전)

### 단계

1. Sentry 계정 생성 (`https://sentry.io/signup/`) — 회사 메일로 가입
2. 조직 (Organization) 이름: `soom-korea-inc`
3. 새 프로젝트 추가:
   - 플랫폼: React Native (APP)
   - 별도 프로젝트 추가: Node.js (SERVER), Next.js (ADMIN)
4. 각 프로젝트의 **DSN** 복사 (`https://<hash>@<org>.ingest.sentry.io/<id>`)

### EAS Secret 등록 (APP)

```
eas secret:create --name EXPO_PUBLIC_SENTRY_DSN \
  --value <APP_DSN>            --scope project --type string
eas secret:create --name SENTRY_AUTH_TOKEN \
  --value <internal token>     --scope project --type string  (source-map 업로드)
```

SERVER / ADMIN 의 Sentry DSN 은 AWS Secrets Manager `iconia/prod/sentry/*` 로
별도 등록 권장 (`SENTRY_DSN_SERVER`, `SENTRY_DSN_ADMIN`).

### 검증

- [ ] EAS preview3 빌드 (`eas build --profile preview3 --platform all`) 산출물에서
      `eas secret:list` → `EXPO_PUBLIC_SENTRY_DSN` 노출 확인
- [ ] APP 실행 후 의도적으로 throw → Sentry Issues 페이지에 1분 내 이벤트 도착
- [ ] SERVER `/health?test=sentry` 호출 (관리자 전용) → 5초 내 Sentry Issues 도착
- [ ] release-preflight: `aws-deploy.ps1` 의 placeholder 검사가 `SENTRY_DSN_*` 빈 값 차단

---

## 액션 6. AWS GitHub Actions OIDC 권한 등록 (D-7)

**누가**: 운영팀 (AWS IAM 관리자 권한)
**언제**: 출시 D-7 까지 (CI/CD 파이프라인 검증 가능 시점)

### 단계

#### 6.1 IAM Identity Provider 등록 (계정당 1회)

AWS 콘솔 → IAM → Identity providers → "Add provider":
- Provider type: `OpenID Connect`
- Provider URL: `https://token.actions.githubusercontent.com`
- Audience: `sts.amazonaws.com`
- Thumbprint: AWS docs 가 안내하는 GitHub 인증서 thumbprint (자동 인식)

#### 6.2 신뢰 정책 (deploy 역할)

- 역할 이름: `iconia-deploy-from-github` (또는 동의어)
- 신뢰 정책 JSON 은 `deploy/RUNBOOK.md` §9.2 참조
- `sub` 조건: `repo:Leeseungju1991/ICONIA-CI:*` (본 레포 한정)

#### 6.3 최소 권한 정책

`deploy/RUNBOOK.md` §9.3 의 6개 IAM action 만 허용:
- `ssm:SendCommand`, `ssm:GetCommandInvocation`, `ssm:ListCommandInvocations`
- `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` (artifacts bucket 한정)
- `ec2:DescribeInstances` (태그 기반 자동조회)
- `cloudwatch:PutMetricData` (배포 메트릭)
- `iam:PassRole` (대상: ec2 instance profile 만)
- **`elasticloadbalancing:*` (canary rollout 추가)** — `modify-rule`,
  `register-targets`, `deregister-targets`, `describe-target-health`

별도 역할 (read-only) — `iconia-dr-restore`, `iconia-firmware-sign` 도 같은
방식으로 등록.

### 검증

- [ ] GitHub Settings → Secrets → `AWS_DEPLOY_ROLE_ARN` 에 역할 ARN 등록
- [ ] `deploy.yml` 워크플로우 수동 트리거 (workflow_dispatch + dry_run=true) →
      `Configure AWS credentials` 스텝이 OIDC 단명 토큰으로 성공
- [ ] CloudTrail 에서 `AssumeRoleWithWebIdentity` 이벤트 1건 확인 → Source =
      GitHub Actions

---

## 액션 7. 본인인증 업체(PASS / NICE) 계약 + 어댑터 연결 (D-7)

**누가**: 운영팀 (계약 담당) + 법무 (개인정보 위탁계약)
**언제**: 출시 D-7 까지
**법적 근거**: PIPA §22-2 (만 14세 미만 보호) + 성인 콘텐츠 제공 시 본인확인 의무

### 단계

1. PASS 또는 NICE 평가정보 중 1개 업체와 계약 (또는 둘 다 — fallback 권장)
2. 계약 완료 후 업체로부터 발급:
   - Client ID
   - Client Secret
   - 가맹점 식별번호
   - 콜백 URL 화이트리스트 등록 (`https://api.<root_domain>/v1/auth/age/callback`)

### 입력 위치

- AWS Secrets Manager:
  - `iconia/prod/age-verification/pass-client-id`
  - `iconia/prod/age-verification/pass-client-secret`
  - `iconia/prod/age-verification/nice-client-id` (fallback)
  - `iconia/prod/age-verification/nice-client-secret`
- SERVER `.env.prod`:
  - `AGE_VERIFICATION_PROVIDER=pass` (또는 `nice`)
  - `AGE_VERIFICATION_FALLBACK_PROVIDER=nice` (선택)

### 어댑터 코드 활성

- SERVER 의 `ICONIA-SERVER/src/services/ageVerificationProviders/pass.js` /
  `nice.js` 어댑터를 기본 활성화
- `featureFlags.js` 의 `AGE_VERIFICATION_ENABLED=true` 토글

### 검증

- [ ] APP 회원가입 → 본인인증 화면 진입 → PASS 앱으로 redirect 정상
- [ ] 본인인증 완료 후 SERVER `/v1/auth/age/callback` 200 응답
- [ ] DB `users.age_verified_at` 컬럼 갱신
- [ ] 미성년자 (만 18세 미만) 인증 시도 → 가입 차단 + 안내 메시지
- [ ] 위탁계약서 사본 `docs/legal/contracts/age-verification-2026.pdf` 보관 (gitignore)

---

# 출시 D-day 체크리스트

D-day 당일 (또는 D-1 저녁) 운영팀 / 법무 / CTO 가 함께 다음을 확인 후 release tag 푸시.

## 액션 1~7 완료 확인

- [ ] **액션 1**: 사업자 정보 9종 등록 + ADMIN 정상 표시
- [ ] **액션 2**: DPO 지정 + 약관 본문 자동 반영
- [ ] **액션 3**: 4종 약관 시행일 확정 + 법무 검토 서명본 보관
- [ ] **액션 4**: Secrets Manager 11종 등록 + EC2 부팅 시 "secrets loaded (11/11)"
- [ ] **액션 5**: Sentry DSN 등록 + EAS preview3 빌드 산출물 검증
- [ ] **액션 6**: AWS OIDC role 등록 + workflow_dispatch dry_run 통과
- [ ] **액션 7**: PASS/NICE 계약 + APP 본인인증 흐름 정상

## 마지막 검증 명령

```powershell
# 1) 6 레포 placeholder 검사 (사업자정보 / 약관 / DPO / Secrets / Sentry 잔존 0)
pwsh -File scripts/preflight-placeholders.ps1 -RepoRoot <ICONIA root>

# 2) seed-data preflight (필수 카테고리 5종 검증)
pwsh -File scripts/preflight-seed-data.ps1

# 3) terraform plan diff 검토 (의도치 않은 변경 없음 확인)
cd terraform && terraform plan -input=false

# 4) dry-run 배포 리허설 (artifact 업로드까지만)
pwsh -File scripts/aws-deploy.ps1 -DryRun -Service all
```

위 4개 모두 PASS → release tag 푸시:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

`deploy.yml` 워크플로우가 preflight → test-gate → build → deploy → smoke 까지
자동 진행. **하나라도 실패하면 다음 단계 진입 차단.**

## 출시 직후 1시간 (T+0 ~ T+60min)

- [ ] CloudWatch dashboard `iconia_slo` 6 widget 모두 녹색
- [ ] Synthetics canary 3종 (api/ai/admin) `SuccessPercent ≥ 95%`
- [ ] Sentry Issues 페이지 신규 이벤트 P0/P1 없음
- [ ] APP 스토어 (Google Play / App Store) 다운로드 가능 확인
- [ ] 첫 사용자 회원가입 → 본인인증 → 결제까지 e2e 흐름 1건 성공

## Canary rollout 권장 (메이저 변경 시)

태그 푸시로 자동 배포 대신, 운영자 콘솔에서 canary 10% 분배:

```powershell
pwsh -File scripts/aws-deploy.ps1 -Canary 10
# (5분 관찰 — CloudWatch + Sentry)
pwsh -File scripts/aws-deploy.ps1 -PromoteCanary   # 통과 시
pwsh -File scripts/aws-deploy.ps1 -RollbackCanary  # 실패 시
```

상세는 `deploy/RUNBOOK.md` §3.5.

---

## 부록 A. 책임자 / 연락처 (출시 라운드별 갱신)

| 역할 | 담당 | 연락처 |
|---|---|---|
| 대표 / CEO        | (D-7 까지 확정) | |
| CTO               | | |
| DPO (액션 2)      | | |
| 운영팀 리드        | | |
| 법무 담당         | | |
| 외부 자문 변호사 (액션 3) | | |
| AWS 콘솔 관리자 (액션 4, 6) | | |
| Sentry 관리자 (액션 5) | | |
| PASS/NICE 계약 담당 (액션 7) | | |
| On-call (D-day) | | |

## 부록 B. 일정 마일스톤 예시

| 날짜 | 액션 | 책임 |
|---|---|---|
| D-7  | 액션 1 (사업자정보) 완료 | 운영팀 |
| D-7  | 액션 2 (DPO 지정) 완료   | CTO |
| D-7  | 액션 6 (OIDC) 완료      | 운영팀 |
| D-7  | 액션 7 (본인인증 계약) 완료 | 운영팀 |
| D-3  | 액션 3 (약관 시행일) 완료 | 법무 |
| D-3  | 액션 4 (Secrets 등록) 완료 | 운영팀 |
| D-3  | 액션 5 (Sentry) 완료     | 운영팀 |
| D-1  | 출시 리허설 + dry-run    | 전체 |
| D-day | release tag 푸시        | CTO |

---

본 체크리스트는 정본이다. 변경 시 git commit + PR 리뷰 — 단순 typo 도
공식 변경 절차를 따른다.

관련 문서:
- `deploy/RUNBOOK.md` — 배포 절차 / 트러블슈팅
- `docs/legal/business-info.md` — (주)숨코리아 사업자 정보 갱신 절차
- `README.md` §3.5 — 약관 placeholder guard 정책
