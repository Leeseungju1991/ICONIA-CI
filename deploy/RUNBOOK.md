# ICONIA 배포 Runbook (v1.0)

"로컬에서 한번 확인 → 배포 → 출시" 의 전 과정. SERVER / AI / ADMIN 3개 서비스를
단일 EC2 호스트로 무중단 배포한다. HW(OTA) / APP(EAS) 은 별도 트랙.

localhost ↔ AWS 전환은 `.env` 의 `DEPLOY_TARGET` 한 줄(`local` / `aws`)로 한다.

---

## 0-A. localhost 전체 기동 (배포 전 동작 확인)

```powershell
Copy-Item .env.example .env          # 최초 1회 — DEPLOY_TARGET=local 기본
pwsh -File scripts/local-up.ps1      # PG16 + SERVER + AI + ADMIN 일괄 기동
pwsh -File scripts/local-up.ps1 -IncludeApp   # APP(Expo) 까지
pwsh -File scripts/local-down.ps1    # 종료
```

Linux/macOS: `scripts/local-up.sh` / `scripts/local-down.sh`.
AWS 완전 자동 배포는 `scripts/aws-deploy.ps1` 단일 커맨드. 상세는 `README.md` §3·§4.

---

## 0. 1회성 사전 부트스트랩 (최초 1번)

| # | 작업 | 명령 |
|---|---|---|
| 1 | tfstate 버킷 + lock 테이블 | `pwsh -File scripts/bootstrap-aws.ps1` |
| 2 | DB master password 생성 → Secrets Manager | `pwsh -File scripts/seed-db-password.ps1` |
| 3 | `terraform.tfvars` 작성 | `terraform.tfvars.example` 복사 후 `root_domain` / `hosted_zone_id` 입력 |
| 4 | 인프라 생성 | `cd terraform && terraform init -backend-config=... && terraform apply` |
| 5 | Route53 NS 등록 | (zone 신규 생성 시) 도메인 등록처에 NS 4개 입력 |
| 6 | GitHub secrets 등록 | 아래 §5 표 |
| 7 | OIDC IAM 역할 생성 | GitHub Actions → AWS 신뢰 정책 (`token.actions.githubusercontent.com`) |

`terraform apply` 가 한 번에 만드는 것: VPC / EC2+EIP / RDS / S3 4종 / EFS /
Route53 / IAM / CloudWatch 알람(`alarms.tf` 모듈) / RDS 비밀회전 Lambda.

---

## 1. 일상 배포 — 자동 (권장)

### 1-A. Git 태그 푸시로 정식 출시

```bash
git tag v1.2.3 && git push origin v1.2.3
```

`deploy.yml` 워크플로우가 자동 실행:

```
preflight → test-gate → build → deploy → smoke
 placeholder  3서비스    빌드+   SSM      Route53
  검사        테스트     S3업로드  배포     E2E
```

- **하나라도 실패하면 다음 단계로 진행 안 함** → prod 보호.
- `build` / `deploy` / `smoke` 는 `environment: production` — 필요 시 GitHub
  Environment 에 reviewer 승인 게이트를 걸어 "원클릭 승인 배포" 로 운용.

### 1-B. 운영자 수동 실행 (workflow_dispatch)

GitHub Actions → `deploy` → Run workflow:
- `service`: all / server / ai / admin
- `dry_run`: true 면 빌드/업로드까지만 (deploy/smoke 생략 — 리허설용)

---

## 2. 일상 배포 — 로컬 (Windows 운영자, 폴백)

```powershell
# 로컬 확인: 빌드만 (배포 안 함)
pwsh -File scripts/build-and-upload.ps1 -Service all -SkipNpmInstall

# 출시: 빌드 + S3 업로드 + SSM 배포 트리거
$env:ICONIA_ARTIFACTS_BUCKET = "<terraform output artifacts_bucket_name>"
pwsh -File scripts/build-and-upload.ps1 -Service all -TriggerDeploy
```

Linux 셸에서:

```bash
scripts/build-and-upload.sh --service all --repo-root <ICONIA root> \
  --bucket <artifacts bucket> --trigger-deploy
scripts/post-deploy-smoke.sh --root-domain <domain> --env prod
```

---

## 2-A. 시드 (최초 1회 자동 / 명시 수동)

운영 RDS 에 mock 데이터(SERVER 의 `prisma/seed-data/*.json` — APP 에이전트가 export)
를 주입한다. **시드 코드는 SERVER 의 `npm run seed:aws`** 가 표준이며, CI 는 다음 두
경로로 트리거한다.

```
운영자 콘솔 (aws-deploy.ps1)
   ├── 1차 (권장): SSM Run Command
   │     aws ssm send-command --document-name AWS-RunShellScript
   │       --instance-ids <EC2>
   │       --parameters '{"commands":["cd /app/server && npm run seed:aws"]}'
   │     → EC2 instance role 의 AmazonSSMManagedInstanceCore 가 수신
   │     → CloudWatch /aws/ssm/*/output 로그로 관찰
   └── 2차 (폴백): SERVER POST /v1/admin/seed/run
         ADMIN_SEED_ENABLED=1 + admin JWT 토큰 필요
         (SSM 경로가 막혔거나 SSM agent 미준비 시)
```

### 의사결정 매트릭스 (aws-deploy.ps1 switch 조합)

| Switch 조합 | 시드 실행? | 설명 |
|---|---|---|
| `(인자 없음)` | ❌ | 일반 배포 — 운영 중 데이터 보호 |
| `-ApplyInfra` | ✅ (자동, 1회) | `/v1/admin/seed/status` 의 `last_seeded_at == null` 이면 자동 시드 |
| `-ApplyInfra -NoSeed` | ❌ | 첫 배포지만 시드는 별도 운영 결정으로 수동 |
| `-Seed` | ✅ | 시드만 단독 실행 (인프라/빌드/배포 skip) |
| `-Seed -EssentialOnly` | ✅ (필수만) | feed/products/orders skip — `SEED_SKIP_NONESSENTIAL=1` |
| `-Reseed` | ✅ (truncate+시드) | 개발용 — `SEED_RESET=1` 전달, **운영 데이터 파괴** |
| `-DryRun -Seed` | ⚠️ echo만 | 명령만 출력, SSM SendCommand 안 함 |

### 사용 예

```powershell
# 첫 배포 — 인프라 + 코드 + 자동 시드 (테이블이 비어 있을 때만)
pwsh -File scripts/aws-deploy.ps1 -ApplyInfra -Service all

# 첫 배포지만 시드는 수동으로
pwsh -File scripts/aws-deploy.ps1 -ApplyInfra -NoSeed
pwsh -File scripts/aws-deploy.ps1 -Seed -EssentialOnly

# 시드만 단독 (인프라 안 건드림)
pwsh -File scripts/aws-deploy.ps1 -Seed

# 개발 DB 재시드 — 운영에서는 사용 금지
pwsh -File scripts/aws-deploy.ps1 -Reseed
```

### 시드 데이터 위치 (cross-repo 의존성)

| 경로 | 산출 주체 | 검증 |
|---|---|---|
| `ICONIA-SERVER/prisma/seed.js` | SERVER 에이전트 | `npm run seed:aws` 진입점 |
| `ICONIA-SERVER/prisma/seed-data/*.json` | APP 에이전트 (mock export) | `scripts/preflight-seed-data.ps1` 가 valid + 필수 카테고리 검증 |

필수 카테고리 (없으면 preflight ERROR): `users`, `characters`, `rooms`,
`legal-agreements`, `notices`. 비핵심 (`feed`, `products`, `orders`) 는
`-EssentialOnly` 와 함께 skip 가능.

### 트러블슈팅

| 증상 | 확인 |
|---|---|
| SSM SendCommand `InvalidInstanceId` | EC2 SSM agent 가 active 한가 (`systemctl status amazon-ssm-agent`), instance role 에 `AmazonSSMManagedInstanceCore` 있는가 |
| SSM Status=`Failed` 즉시 종료 | CommandId 로 `aws ssm get-command-invocation` → STDERR 확인, JSON 형식 오류일 가능성 (preflight 통과 못한 채 trigger) |
| 시드 후 테이블이 여전히 비어 보임 | `last_seeded_at` 갱신 확인, prisma 트랜잭션 롤백 여부, RLS / 권한 오류 (SERVER 로그) |
| `seed:aws` 자체가 없음 | SERVER 에이전트 산출물 누락 — `package.json` 의 `scripts.seed:aws` 확인 |
| 자동 시드가 안 트리거됨 | `/v1/admin/seed/status` 가 200 + `last_seeded_at: null` 반환하는지 확인 — 그 외에는 보수적으로 skip |
| 권한 오류 (`AccessDenied`) | 발행 측 OIDC IAM role 에 `ssm:SendCommand` + `ssm:GetCommandInvocation` 있는지 (수신 측 EC2 role 은 본 레포 `terraform/iam.tf` 에서 보장) |

### 필요한 IAM (발행 측 — OIDC GitHub Actions / 운영자 콘솔)

본 레포 `terraform/iam.tf` 는 **수신 측(EC2)** 만 관리한다. 발행 측 OIDC IAM role
은 별도 stack (RUNBOOK §0 #7) — 다음 actions 가 필요:

```
ssm:SendCommand
ssm:GetCommandInvocation
ssm:ListCommandInvocations
ec2:DescribeInstances           (태그 기반 자동조회 시)
```

리소스 스코프 권장: `arn:aws:ec2:<region>:<account>:instance/<i-...>` +
`arn:aws:ssm:<region>::document/AWS-RunShellScript`.

---

## 3. 배포 중 호스트에서 일어나는 일 (ec2-pull-and-restart.sh)

1. `inject_database_url` — Secrets Manager 에서 DB 비밀 fetch → `/etc/iconia.{server,ai}.env`
2. `latest.tar.gz` pull + **SHA256 검증** (부분 업로드 차단)
3. **atomic swap** — `mv` 한 번에 신/구 교체 (다운타임 < 1s) + `.old.<ts>` 백업
4. `npm ci --omit=dev`
5. **`prisma migrate deploy`** (server 한정) — 안전한 순차 마이그레이션
6. `systemctl restart`
7. **헬스 프로브 30s** — `is-active` + HTTP `/health`
8. 실패 시 **자동 롤백** — `.old.<ts>` 로 swap-back, 그래도 실패 시
   `ICONIA/Deploy/RollbackFailed` CloudWatch 메트릭 → 알람

→ 무중단 배포 + 테스트 게이트 + 자동 롤백이 코드 레벨에서 보장됨.

---

## 4. 출시 전 체크리스트

### 4-A. 운영 / 인프라

- [ ] `test-gate` 워크플로우 녹색 (SERVER/AI/ADMIN 테스트 통과)
- [ ] `preflight` 통과 — 미채운 PLACEHOLDER 없음 (도메인/시크릿 + 약관 placeholder 모두 포함)
- [ ] DB 마이그레이션이 **하위 호환** (구버전 코드와 신 스키마 공존 가능 —
      롤백 시 신 스키마 + 구 코드가 떠야 하므로)
- [ ] `terraform plan` diff 검토 — 의도치 않은 인프라 변경 없음
- [ ] Secrets Manager `iconia/<env>/db/master_password` 존재 확인
- [ ] Route53 A record 가 EC2 EIP 를 가리키는지 확인
- [ ] CloudWatch 알람 SNS 구독(email/PagerDuty) confirmed 상태
- [ ] (메이저 변경 시) `dry_run=true` 로 빌드 리허설 1회

### 4-B. (주)숨코리아 사업자 정보 / 약관 (PIPA · 전자상거래법)

본 블록은 **release-preflight 의 LEGAL_PATTERNS 가 강제 검사**한다 — 잔존 시
prod 배포 자체가 차단된다. 정본은 `docs/legal/business-info.md`.

- [ ] **실 사업자등록번호** 확정 — `4. APP/src/config/legal.ts` `COMPANY_BUSINESS_NUMBER`
      에 실값 (xxx-xx-xxxxx 형식, 사업자 placeholder 패턴 잔존 금지)
- [ ] **통신판매업 신고번호** 확정 — `COMPANY_MAIL_ORDER_NUMBER` 실값
      (전자상거래법 §13 — 결제약관 본문에 등장)
- [ ] **약관 본문 검토** — `4. APP/src/copy/terms/ko/*.ts` 7종 (termsOfService,
      privacyPolicy, paymentTerms, sensorDataPolicy, aiServiceTerms,
      communityPolicy, externalLinkPolicy) 의 회사명·연락처·시행일 일관성
- [ ] **청소년 보호** — 만 18세 이상 검증 게이트(생년월일 입력) 정상 동작 + 청소년
      유해성 검토 회사명 (주)숨코리아 로 통일
- [ ] **개인정보 보호 책임자(DPO)** 확정 — `DPO_NAME`, 전화·이메일
- [ ] **KC·FCC 인증** — `1. HW/docs/safety-certification-roadmap.md` 에 제조사
      (주)숨코리아 + 인증번호 채움 (한국 출시 시 KC 필수, 미국 진출 시 FCC Part 15)
- [ ] **처리방침 정본 시행일** — `2. SERVER/docs/legal/privacy_policy.md` 의
      "시행일" 확정 (현재 법무 검토 토큰 잔존 시 차단)
- [ ] **WooCommerce (dollsoom.com)** 약관·연락처가 본 정본과 동기화 — 별도 트랙

---

## 5. GitHub secrets

| Secret | 값 | 용도 |
|---|---|---|
| `AWS_DEPLOY_ROLE_ARN` | OIDC IAM 역할 ARN | 정적 키 없이 AWS 인증 |
| `ICONIA_ARTIFACTS_BUCKET` | `terraform output artifacts_bucket_name` | 빌드 산출물 업로드 |
| `ICONIA_EC2_INSTANCE_ID` | `terraform output ec2_instance_id` | SSM 배포 대상 (비우면 태그 조회) |
| `ICONIA_ROOT_DOMAIN` | 운영 도메인 | 스모크 테스트 대상 |
| `ICONIA_REPO_TOKEN` | org-scoped PAT / GitHub App token | sibling private repo checkout |

---

## 6. 롤백 (수동)

자동 롤백이 실패했거나 직전 버전이 아닌 특정 버전으로 되돌릴 때:

```bash
# 1) 특정 버전을 latest 로 되돌리기
aws s3 cp s3://<bucket>/server/<version>.tar.gz s3://<bucket>/server/latest.tar.gz
aws s3 cp s3://<bucket>/server/<version>.tar.gz.sha256 s3://<bucket>/server/latest.tar.gz.sha256
# 2) 재배포 트리거
scripts/trigger-deploy.sh --service server
```

EC2 호스트의 `/opt/iconia/<svc>.old.<ts>` 백업으로 즉시 복귀하려면 SSM Session
Manager 접속 후 디렉토리 swap + `systemctl restart`.

장애 유형별(RDS/EFS/EC2 AZ 등) 상세 절차는 `deploy/aws/multi-az-failover-runbook.md`.

---

## 7. 트러블슈팅

| 증상 | 확인 |
|---|---|
| 배포 후 502 | `journalctl -u iconia-<svc>` / `nginx -t` |
| 스모크 테스트 실패 | CloudWatch `ICONIA/Deploy` 메트릭, `/iconia/<env>/*` 로그그룹 |
| `prisma migrate deploy` 실패 | `/etc/iconia.server.env` 의 `DATABASE_URL`, RDS SG |
| `RollbackFailed` 알람 | 호스트 자체 점검 — `.failed.<ts>` 디렉토리 보존됨 |
| certbot 인증서 미발급 | Route53 A record 가 EIP 로 전파됐는지, 80 포트 개방 |
| 시드 단계 SSM 실패 / 시드 데이터 결손 | §2-A 의 시드 트러블슈팅 표 참조 (preflight-seed-data.ps1 + /v1/admin/seed/status) |
