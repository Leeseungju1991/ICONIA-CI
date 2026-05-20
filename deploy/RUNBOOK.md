# ICONIA 배포 Runbook (v1.0)

"로컬에서 한번 확인 → 배포 → 출시" 의 전 과정. SERVER / AI / ADMIN 3개 서비스를
단일 EC2 호스트로 무중단 배포한다. HW(OTA) / APP(EAS) 은 별도 트랙.

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

- [ ] `test-gate` 워크플로우 녹색 (SERVER/AI/ADMIN 테스트 통과)
- [ ] `preflight` 통과 — 미채운 PLACEHOLDER 없음
- [ ] DB 마이그레이션이 **하위 호환** (구버전 코드와 신 스키마 공존 가능 —
      롤백 시 신 스키마 + 구 코드가 떠야 하므로)
- [ ] `terraform plan` diff 검토 — 의도치 않은 인프라 변경 없음
- [ ] Secrets Manager `iconia/<env>/db/master_password` 존재 확인
- [ ] Route53 A record 가 EC2 EIP 를 가리키는지 확인
- [ ] CloudWatch 알람 SNS 구독(email/PagerDuty) confirmed 상태
- [ ] (메이저 변경 시) `dry_run=true` 로 빌드 리허설 1회

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
