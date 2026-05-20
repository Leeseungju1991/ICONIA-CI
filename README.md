# ICONIA-CI

ICONIA 시스템의 **6번 레포 = 통합 CI/CD·인프라 정본**.

ICONIA 는 6개 레포로 구성된다.

| # | 레포 | 역할 | 배포 트랙 |
|---|---|---|---|
| 1 | HW | 디바이스 펌웨어 | OTA (firmware S3 버킷, 별도 트랙) |
| 2 | SERVER | Node.js Express API | **본 레포가 AWS EC2 로 배포** |
| 3 | AI | Genome 추론 서비스 | **본 레포가 AWS EC2 로 배포** |
| 4 | APP | Expo 모바일 앱 | EAS Build / Submit (별도 트랙) |
| 5 | ADMIN | Next.js 관리 콘솔 | **본 레포가 AWS EC2 로 배포** |
| 6 | **CI** | **인프라(Terraform)·배포 파이프라인·운영 정본 — 본 레포** | — |

본 레포(ICONIA-CI)는 **SERVER / AI / ADMIN 3개를 AWS 단일 EC2 호스트로
무중단 배포**하는 Terraform IaC, 빌드·배포 스크립트, GitHub Actions 파이프라인,
CloudWatch / Sentry / Push 운영 정본을 담는다.

**설계 목표**: `localhost 동작 확인 → 아주 간단한 수정 → AWS 실배포 즉시 출시`.
localhost ↔ AWS 전환은 `.env` 의 **`DEPLOY_TARGET` 한 줄(`local` / `aws`)** 로 한다.

```
.env  →  DEPLOY_TARGET=local   →  scripts/local-up.ps1   (전체 로컬 기동)
      →  DEPLOY_TARGET=aws     →  scripts/aws-deploy.ps1 (실배포 → 출시)
```

원격: `https://github.com/Leeseungju1991/ICONIA-CI` (main 브랜치만).

---

## 1. 서버 설계 구조

AWS 인프라 전체와 6개 레포의 배포 대상 매핑.

```
                          [ 사용자 / 디바이스 / 운영자 ]
                                      │
                          Route53 (hosted zone)
              api.<domain>   ai.<domain>   admin.<domain>   ── A record → EIP
                                      │
                                health check: /health?deep=1
                                      │
┌─────────────────────────────────────────────────────────────────────────────┐
│ VPC 10.42.0.0/16  (ap-northeast-2)                                            │
│                                                                               │
│  ┌── Public Subnet (AZ-a) ───────────┐   ┌── Public Subnet (AZ-c) ─────────┐ │
│  │  Internet Gateway                  │   │                                 │ │
│  │  ┌──────────────────────────────┐  │   │   (Multi-AZ 예비 / ALB 도입시)  │ │
│  │  │ EC2  iconia-<env>-host  + EIP │  │   │                                 │ │
│  │  │  ┌────────────────────────┐  │  │   └─────────────────────────────────┘ │
│  │  │  │ nginx :80→:443 (TLS)   │  │  │                                       │
│  │  │  │  rate-limit / HSTS/CSP │  │  │   ┌── Private Subnet (AZ-a / AZ-c) ──┐ │
│  │  │  ├────────────────────────┤  │  │   │                                  │ │
│  │  │  │ systemd:                │  │  │   │  RDS PostgreSQL 16  (Multi-AZ)   │ │
│  │  │  │  iconia-server :8080 ◄──┼──┼──┼───┼──► (3.AI / 2.SERVER 공용)        │ │
│  │  │  │  iconia-ai     :8081    │  │  │   │                                  │ │
│  │  │  │  iconia-admin  :3000    │  │  │   │  EFS  persona  (encrypted)       │ │
│  │  │  └────────────────────────┘  │  │   │   access point server_root       │ │
│  │  │  CloudWatch Agent             │  │   │   /mnt/efs/iconia (NFS 2049)     │ │
│  │  └──────────────────────────────┘  │   └──────────────────────────────────┘ │
│  └────────────────────────────────────┘                                       │
│        │ NAT Gateway → IGW (outbound)                                          │
└─────────────────────────────────────────────────────────────────────────────┘
         │                                  │                         │
         ▼                                  ▼                         ▼
┌──────────────────┐         ┌───────────────────────────┐   ┌──────────────────┐
│ S3 (4 버킷)      │         │ Secrets Manager           │   │ CloudWatch       │
│  events          │         │  iconia/<env>/db/         │   │  /iconia/<env>/* │
│  exports         │         │   master_password         │   │   log group 7종  │
│  firmware  ◄─ 1.HW OTA     │  iconia/<env>/sentry/*    │   │  ICONIA/* metric │
│  artifacts ◄─ 배포 산출물  │  (회전 Lambda hook)        │   │  alarm + SNS     │
└──────────────────┘         └───────────────────────────┘   │  Dashboard       │
                                                              └──────────────────┘

배포 대상 매핑
  2. SERVER  ──build──▶  S3 artifacts/server/   ──EC2 pull──▶  systemd iconia-server :8080
  3. AI      ──build──▶  S3 artifacts/ai/       ──EC2 pull──▶  systemd iconia-ai     :8081
  5. ADMIN   ──build──▶  S3 artifacts/admin/    ──EC2 pull──▶  systemd iconia-admin  :3000
  6. CI      ──build──▶  S3 artifacts/_bootstrap/ ─────────▶  nginx + systemd unit 설치
  1. HW      ───────────────────────────────────────────────  firmware S3 (OTA, 별도 트랙)
  4. APP     ───────────────────────────────────────────────  Expo EAS Build (별도 트랙)
```

**구성 요소**

| 계층 | 리소스 | Terraform |
|---|---|---|
| 진입 | Route53 hosted zone + api/ai/admin A record + deep health check | `route53.tf` |
| 네트워크 | VPC / public·private subnet × 2 AZ / IGW / NAT GW / SG | `network.tf` |
| 컴퓨트 | EC2 단일 호스트(Server+AI+Admin systemd) + EIP + user-data | `ec2.tf` / `ec2-bootstrap/` |
| 데이터 | RDS PostgreSQL 16 (instance / Aurora Serverless v2 분기, Multi-AZ on prod) | `rds.tf` |
| 영속성 | EFS persona (encrypted, IA 30d, backup) + access point | `efs.tf` |
| 저장소 | S3 events / exports / firmware / artifacts (SSE + BlockPublicAccess) | `s3.tf` |
| 권한 | EC2 instance role (S3 / Secrets / CW / EFS / RDS connect) | `iam.tf` |
| 가시성 | log group 7종 / PII metric filter / Dashboard / Logs Insights | `observability.tf` / `alarms.tf` |
| DR | Multi-AZ failover SSM Automation Document 2종 | `ssm-runbook.tf` |

---

## 2. 동작 시나리오

### 2.1 정상 배포 시나리오 (코드 push → 출시)

```
[개발자]                [GitHub Actions / deploy.yml]              [AWS]
   │
   │ 1) localhost 동작 확인
   │    pwsh -File scripts/local-up.ps1
   │    → SERVER/AI/ADMIN 로컬 기동, 동작 검증
   │
   │ 2) 간단한 수정 (True/false 수준) + git push
   │ 3) git tag v1.2.3 && git push origin v1.2.3
   ▼
   ┌──────────────────────────────────────────────────────┐
   │ deploy.yml 자동 실행 (5단계 게이트)                   │
   │                                                       │
   │  ① preflight  : 6레포 placeholder 검사               │
   │                 (미채운 PLACEHOLDER 가 prod 로 새는   │
   │                  사고 차단) — 실패 시 전체 중단       │
   │                                                       │
   │  ② test-gate  : SERVER/AI/ADMIN 단위·lint·typecheck  │
   │                 + CI 자체 검증(shell/terraform)       │
   │                 → 하나라도 실패 시 배포 차단          │
   │                                                       │
   │  ③ build      : 3서비스 + _bootstrap tarball 빌드     │
   │                 robocopy/rsync → npm ci → admin       │
   │                 next build standalone → prisma        │
   │                 generate → npm prune → tar + SHA256   │
   │                 → S3 artifacts/<svc>/latest.tar.gz    │
   │                                                       │
   │  ④ deploy     : SSM RunShellScript → EC2             │
   │                 ec2-pull-and-restart.sh              │
   │                                                       │
   │  ⑤ smoke      : Route53 FQDN 외부 E2E 검증           │
   └──────────────────────────────────────────────────────┘
                              │
                              ▼ (④ EC2 호스트 내부 동작)
   ┌──────────────────────────────────────────────────────┐
   │ a) inject_database_url                                │
   │    Secrets Manager → /etc/iconia.{server,ai}.env     │
   │ b) latest.tar.gz pull + SHA256 검증                   │
   │    (부분 업로드 / 네트워크 손상 차단)                 │
   │ c) atomic swap — mv 한 번에 신/구 교체 (다운타임 <1s) │
   │    + .old.<ts> 백업 (최근 3개 보존)                   │
   │ d) npm ci --omit=dev                                  │
   │ e) prisma migrate deploy (server 한정, 순차 마이그레)  │
   │ f) systemctl restart iconia-<svc>                     │
   │ g) 헬스 프로브 30s — is-active + HTTP /health         │
   │    → healthy 면 배포 성공                             │
   └──────────────────────────────────────────────────────┘
                              │ healthy
                              ▼
   ⑤ Route53 FQDN E2E: /health, /health?deep=1, admin root,
      HTTP→HTTPS 리다이렉트 → 전부 2xx/3xx → 출시 완료 ✅
```

**무중단 보장 5계층**

1. **체크섬** — SHA256 사이드카로 부분 업로드 차단.
2. **원자 swap** — `mv` 한 번에 신/구 교체, 다운타임 < 1s.
3. **테스트 게이트** — `test-gate.yml` 실패 시 배포 잡 진입 자체 차단.
4. **헬스체크** — restart 후 30s 내 `is-active` + HTTP `/health` 통과 필수.
5. **자동 롤백** — 헬스체크 실패 시 `.old.<ts>` 로 swap-back 후 재기동.

### 2.2 롤백 시나리오

```
배포 ④ 후 헬스체크 실패 (restart 30s 내 is-active/HTTP 미통과)
   │
   ▼
ec2-pull-and-restart.sh 자동 롤백:
   1. mv /opt/iconia/<svc>        → /opt/iconia/<svc>.failed.<ts>  (실패본 보존)
   2. mv /opt/iconia/<svc>.old.<ts> → /opt/iconia/<svc>            (직전본 복원)
   3. systemctl restart iconia-<svc>
   4. 재헬스체크
        ├─ healthy  → 롤백 성공. 워크플로우는 실패 종료(운영자 인지) +
        │             실패본은 .failed.<ts> 로 점검 가능
        └─ unhealthy→ CRITICAL. CloudWatch ICONIA/Deploy/RollbackFailed
                      메트릭 송출 → 알람 → 운영자 즉시 개입
   │
   ▼
⑤ smoke 단계도 Route53 FQDN 에서 2차로 실패 감지 → 워크플로우 실패
```

**수동 롤백** (특정 버전으로 되돌릴 때): S3 의 과거 `<version>.tar.gz` 를
`latest.tar.gz` 로 복사 후 재배포 트리거.

```bash
aws s3 cp s3://<bucket>/server/<version>.tar.gz        s3://<bucket>/server/latest.tar.gz
aws s3 cp s3://<bucket>/server/<version>.tar.gz.sha256 s3://<bucket>/server/latest.tar.gz.sha256
scripts/trigger-deploy.sh --service server
```

장애 유형별(RDS/EFS/EC2 AZ) 상세 절차: `deploy/aws/multi-az-failover-runbook.md`
및 SSM Automation Document(`terraform/ssm-runbook.tf`).

---

## 3. localhost 기준 프로젝트 전체 동작 PowerShell 커맨드

Windows PowerShell 기준. ICONIA 모노레포(`1. HW` ~ `6. CI`)를 한 부모 폴더에
둔 상태를 가정한다. 직전 통합테스트에서 검증된 절차
(PostgreSQL 16 + SERVER :8080 + AI :3001 + ADMIN :3000 + APP)를 그대로 표현.

### 3.1 최초 1회 — `.env` 작성 (단일 토글)

```powershell
# 6. CI 폴더로 이동
cd "C:\Users\user\Music\ICONIA\6. CI"

# .env 생성 (DEPLOY_TARGET=local 이 기본값)
Copy-Item .env.example .env

# .env 편집 — 로컬 기동에 필요한 키 확인/수정
#   DEPLOY_TARGET=local
#   ICONIA_REPO_ROOT=C:\Users\user\Music\ICONIA   (비우면 자동 추정)
#   LOCAL_PG_USE_DOCKER=true                       (Docker Desktop 사용 시)
#   LOCAL_SERVER_PORT=8080 / LOCAL_AI_PORT=3001 / LOCAL_ADMIN_PORT=3000
notepad .env
```

### 3.2 전체 기동 — 단일 커맨드 (권장)

```powershell
# PostgreSQL 16 + SERVER + AI + ADMIN 을 한 번에 기동
# (각 서비스는 별도 PowerShell 창에서 떠서 로그가 분리된다)
pwsh -File scripts\local-up.ps1

# APP(Expo) 까지 포함해 6개 컴포넌트 전부 기동
pwsh -File scripts\local-up.ps1 -IncludeApp

# 두 번째 기동부터는 npm install / prisma 생략으로 빠르게
pwsh -File scripts\local-up.ps1 -SkipInstall
```

`local-up.ps1` 이 자동 수행하는 일:

1. **PostgreSQL 16** — `iconia-pg` Docker 컨테이너 기동(`postgres:16`) + `pg_isready` 대기
   (`LOCAL_PG_USE_DOCKER=false` 면 기설치 로컬 서비스 사용).
2. **SERVER** — `npm install` → `prisma generate` + `prisma migrate deploy` →
   `npm run dev` (`PORT=8080`, `DATABASE_URL` 로컬 주입, `AI_BASE_URL=http://127.0.0.1:3001`).
3. **AI** — `npm install` → `npm run dev` (`PORT=3001`, `DATABASE_URL` 주입).
4. **ADMIN** — `npm install` → `npm run dev -- --port 3000`
   (`NEXT_PUBLIC_API_BASE_URL=http://127.0.0.1:8080`).
5. **APP** (`-IncludeApp`) — `npm install` → `npx expo start`.
6. **HW** — 로컬 기동 대상 아님(별도 펌웨어 빌드 트랙).

SERVER/AI/ADMIN 에 `DEPLOY_TARGET=local`, APP(Expo) 에 `EXPO_PUBLIC_DEPLOY_TARGET=local`
이 각각 주입돼 sibling 끼리 127.0.0.1 로 통신한다.

### 3.3 동작 확인

```powershell
# SERVER / AI 헬스 체크
Invoke-RestMethod http://127.0.0.1:8080/health
Invoke-RestMethod http://127.0.0.1:3001/health

# ADMIN 콘솔 — 브라우저로 열기
Start-Process "http://127.0.0.1:3000/"

# PostgreSQL 접속 확인 (Docker 모드)
docker exec -it iconia-pg psql -U iconia -d iconia -c "\dt"
```

### 3.4 수동 단계별 기동 (스크립트 없이, 디버깅용)

```powershell
$root = "C:\Users\user\Music\ICONIA"

# 1) PostgreSQL 16
docker run -d --name iconia-pg `
  -e POSTGRES_USER=iconia -e POSTGRES_PASSWORD=iconia_local_dev -e POSTGRES_DB=iconia `
  -p 5432:5432 -v iconia-pg-data:/var/lib/postgresql/data postgres:16
$env:DATABASE_URL = "postgresql://iconia:iconia_local_dev@127.0.0.1:5432/iconia?schema=public"

# 2) SERVER (:8080)  — 새 창
Push-Location "$root\2. SERVER"
npm install
npx prisma generate; npx prisma migrate deploy
$env:DEPLOY_TARGET="local"; $env:PORT="8080"; $env:AI_BASE_URL="http://127.0.0.1:3001"
Start-Process pwsh -ArgumentList '-NoExit','-Command','npm run dev'
Pop-Location

# 3) AI (:3001) — 새 창
Push-Location "$root\3. AI"
npm install
$env:DEPLOY_TARGET="local"; $env:PORT="3001"
Start-Process pwsh -ArgumentList '-NoExit','-Command','npm run dev'
Pop-Location

# 4) ADMIN (:3000) — 새 창
Push-Location "$root\5. ADMIN"
npm install
$env:DEPLOY_TARGET="local"; $env:NEXT_PUBLIC_API_BASE_URL="http://127.0.0.1:8080"
Start-Process pwsh -ArgumentList '-NoExit','-Command','npm run dev -- --port 3000'
Pop-Location

# 5) APP (Expo) — 새 창
Push-Location "$root\4. APP"
npm install
$env:EXPO_PUBLIC_DEPLOY_TARGET="local"; $env:EXPO_PUBLIC_API_BASE_URL="http://127.0.0.1:8080"
Start-Process pwsh -ArgumentList '-NoExit','-Command','npx expo start'
Pop-Location
```

### 3.5 전체 종료

```powershell
# Node 프로세스 종료 + PostgreSQL 컨테이너 stop (데이터 보존)
pwsh -File scripts\local-down.ps1

# DB 까지 완전 초기화 (컨테이너 + 볼륨 삭제)
pwsh -File scripts\local-down.ps1 -RemoveDb
```

---

## 4. 실사용(AWS) 서버 완전 자동화 배포 PowerShell 커맨드

Windows PowerShell 기준. localhost 에서 동작 확인을 마친 코드를 AWS 로 실배포한다.
사전 도구: `aws` CLI(`aws configure` 완료), `terraform`, `pwsh`, `git`, `tar`.

### 4.1 최초 1회 — 인프라 부트스트랩

```powershell
cd "C:\Users\user\Music\ICONIA\6. CI"

# (1) tfstate S3 버킷 + DynamoDB lock 테이블 생성 (idempotent)
pwsh -File scripts\bootstrap-aws.ps1

# (2) RDS master password 랜덤 생성 → Secrets Manager 등록
pwsh -File scripts\seed-db-password.ps1

# (3) terraform.tfvars 작성 — root_domain / hosted_zone_id 등 입력
cd terraform
Copy-Item terraform.tfvars.example terraform.tfvars
notepad terraform.tfvars

# (4) backend.hcl 작성 (bootstrap-aws.ps1 출력의 -backend-config 값)
Copy-Item backend.hcl.example backend.hcl
notepad backend.hcl

# (5) 인프라 생성 — VPC/EC2/RDS/S3/EFS/Route53/IAM/CloudWatch 일괄
terraform init -backend-config="backend.hcl"
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
cd ..

# (6) .env 작성 — 단일 토글을 aws 로
Copy-Item .env.example .env
notepad .env
#   DEPLOY_TARGET=aws
#   ICONIA_ARTIFACTS_BUCKET=<terraform output artifacts_bucket_name>
#   ICONIA_EC2_INSTANCE_ID =<terraform output ec2_instance_id>
#   ICONIA_ROOT_DOMAIN     =<운영 도메인>
```

terraform output 값을 `.env` 로 그대로 옮기는 도우미:

```powershell
$tf = "terraform output -raw"
"ICONIA_ARTIFACTS_BUCKET=$(terraform -chdir=terraform output -raw artifacts_bucket_name)"
"ICONIA_EC2_INSTANCE_ID=$(terraform -chdir=terraform output -raw ec2_instance_id)"
"ICONIA_ROOT_DOMAIN=$((terraform -chdir=terraform output -raw api_fqdn) -replace '^api\.','')"
```

### 4.2 일상 배포 — 완전 자동 (단일 커맨드)

```powershell
cd "C:\Users\user\Music\ICONIA\6. CI"

# 빌드 → S3 업로드 → SSM 무중단 배포 → Route53 외부 스모크 검증까지 한 번에
pwsh -File scripts\aws-deploy.ps1 -Service all

# 인프라 변경이 있을 때 — terraform apply 까지 포함
pwsh -File scripts\aws-deploy.ps1 -ApplyInfra -Service all

# 특정 서비스만
pwsh -File scripts\aws-deploy.ps1 -Service server

# 리허설 — 빌드/업로드까지만 (SSM 배포·스모크 생략)
pwsh -File scripts\aws-deploy.ps1 -Service all -DryRun
```

`aws-deploy.ps1` 이 자동 수행하는 일:

1. `.env` 로드 + `DEPLOY_TARGET=aws` 확인.
2. (`-ApplyInfra`) `terraform init / validate / plan / apply` — 인프라 정합.
3. `terraform output` / `.env` 로 artifacts bucket·instance·domain 해석.
4. `build-and-upload.ps1` — 3서비스 + `_bootstrap` 빌드 → S3 업로드(SHA256 포함).
5. `trigger-deploy.ps1` — SSM RunShellScript → EC2 `ec2-pull-and-restart.sh`
   (호스트에서 atomic swap + `prisma migrate deploy` + 헬스체크 30s + 자동 롤백).
6. Route53 FQDN 외부 스모크 — `api/ai/admin.<domain>` 의 `/health` 검증.

### 4.3 GitHub Actions 표준 경로 (권장 — 태그 푸시 출시)

운영 표준은 GitHub Actions `deploy.yml` 이다. 로컬 PowerShell 은 폴백.

```powershell
# 코드 push 후 버전 태그 → deploy.yml 이 preflight→test-gate→build→deploy→smoke 자동 실행
git tag v1.2.3
git push origin v1.2.3
```

또는 GitHub Actions 콘솔 → `deploy` 워크플로우 → Run workflow
(`service` / `dry_run` 선택).

### 4.4 개별 단계 수동 실행 (디버깅 / 부분 배포)

```powershell
$env:ICONIA_ARTIFACTS_BUCKET = (terraform -chdir=terraform output -raw artifacts_bucket_name)

# 빌드 + S3 업로드만
pwsh -File scripts\build-and-upload.ps1 -Service all

# 빌드 + 업로드 + 배포 트리거를 한 번에
pwsh -File scripts\build-and-upload.ps1 -Service all -TriggerDeploy

# 이미 올라간 artifact 로 배포만 트리거
pwsh -File scripts\trigger-deploy.ps1 -Service all
```

### 4.5 배포 검증 / 롤백

```powershell
$domain = (terraform -chdir=terraform output -raw api_fqdn) -replace '^api\.',''

# 외부 스모크 — Route53 FQDN + TLS + nginx 라우팅 E2E
Invoke-WebRequest "https://api.$domain/health"          -UseBasicParsing
Invoke-WebRequest "https://api.$domain/health?deep=1"   -UseBasicParsing
Invoke-WebRequest "https://ai.$domain/health"           -UseBasicParsing
Invoke-WebRequest "https://admin.$domain/"              -UseBasicParsing

# 특정 버전으로 수동 롤백 (예: server)
$bucket = (terraform -chdir=terraform output -raw artifacts_bucket_name)
aws s3 cp "s3://$bucket/server/20260520-101010Z.tar.gz"        "s3://$bucket/server/latest.tar.gz"
aws s3 cp "s3://$bucket/server/20260520-101010Z.tar.gz.sha256" "s3://$bucket/server/latest.tar.gz.sha256"
pwsh -File scripts\trigger-deploy.ps1 -Service server
```

배포 가시성: CloudWatch `ICONIA/Deploy` namespace, `/iconia/<env>/*` 로그그룹,
운영 Dashboard(`terraform/observability.tf`).

---

## 부록 A — 디렉토리 구성

| 경로 | 내용 |
|---|---|
| `terraform/` | AWS 인프라 IaC (VPC/EC2/RDS/S3/EFS/Route53/IAM/CloudWatch/SSM) |
| `ec2-bootstrap/` | EC2 user-data 템플릿 (최초 부팅 시 1회) |
| `deploy/systemd/` | systemd unit 3종 (server/ai/admin) — hardening 풀세트 |
| `deploy/nginx/` | nginx 리버스 프록시 conf + 공통 proxy snippet |
| `deploy/aws/` | CloudWatch/Sentry/Push/Canary/DR 운영 정본 |
| `deploy/RUNBOOK.md` | 배포 runbook (부트스트랩 / 자동·수동 배포 / 롤백 / 트러블슈팅) |
| `scripts/` | 빌드·배포·로컬 오케스트레이션 스크립트 (PowerShell + bash) |
| `.github/workflows/` | GitHub Actions — test-gate / deploy / release-preflight |
| `.env.example` | 단일 토글(`DEPLOY_TARGET`) 포함 로컬·AWS 공용 설정 템플릿 |

## 부록 B — scripts/ 목록

| 스크립트 | 용도 |
|---|---|
| `local-up.ps1` / `local-up.sh` | **localhost 전체 기동** — PG16 + SERVER + AI + ADMIN (+APP) |
| `local-down.ps1` / `local-down.sh` | localhost 전체 종료 |
| `aws-deploy.ps1` | **AWS 완전 자동 배포** — terraform→빌드→SSM→스모크 단일 진입점 |
| `build-and-upload.ps1` / `.sh` | 빌드(robocopy/rsync + npm + next build + prisma) + S3 업로드 |
| `trigger-deploy.ps1` / `.sh` | SSM RunShellScript 로 EC2 배포 트리거 |
| `ec2-pull-and-restart.sh` | EC2 호스트 실행 — pull + atomic swap + 헬스체크 + 자동 롤백 |
| `post-deploy-smoke.sh` | 배포 후 Route53 FQDN 외부 E2E 스모크 |
| `bootstrap-aws.ps1` | 최초 1회 — tfstate S3 버킷 + DynamoDB lock 생성 |
| `seed-db-password.ps1` | 최초 1회 — RDS password 생성 → Secrets Manager 등록 |
| `preflight-placeholders.{sh,ps1}` | 6레포 placeholder 검사 (release 차단 게이트) |
| `check-soul-catalog-sync.js` | SERVER↔AI soul catalog lockstep 검증 |

## 부록 C — 단일 토글 (`DEPLOY_TARGET`)

`.env` 의 `DEPLOY_TARGET` 한 줄이 localhost ↔ AWS 를 가른다. 레포가 동일 키를
읽도록 정합한다 — SERVER/AI/ADMIN/CI 는 `DEPLOY_TARGET`, APP(Expo) 만
`EXPO_PUBLIC_` prefix 가 필수라 `EXPO_PUBLIC_DEPLOY_TARGET` 을 읽는다(의도된 차이).

| 값 | 진입 스크립트 | 서비스 통신 | 데이터 |
|---|---|---|---|
| `local` | `scripts/local-up.ps1` | 127.0.0.1 sibling 포트 | 로컬 PostgreSQL 16 |
| `aws` | `scripts/aws-deploy.ps1` | Route53 FQDN (api/ai/admin) | RDS PostgreSQL 16 |

> **포트 주의** — 로컬은 SERVER:8080 / AI:3001 / ADMIN:3000 (개발 관례).
> AWS 측 systemd 는 SERVER:8080 / AI:8081 / ADMIN:3000 이며 nginx 가 앞단에서
> TLS 종단 + 라우팅을 담당한다. AI 포트 차이는 로컬/운영 의도된 분리다.
