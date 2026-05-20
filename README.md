# ICONIA-CI

ICONIA 의 1~5번 폴더(HW / SERVER / AI / APP / ADMIN)는 **로컬 전용** 코드 저장소다.
본 폴더(6번 = ICONIA-CI)는 그중 **SERVER / AI / ADMIN** 3개를 AWS 단일 EC2 호스트로
배포하는 인프라 코드, 배포 스크립트, CloudWatch / Sentry / Push 운영 정본을 담는다.
HW(펌웨어 OTA)와 APP(Expo EAS Build)은 별도 트랙이다.

AWS 구성: **Route53 + EC2 + S3 + RDB(PostgreSQL) + EFS** (5종).
원격: <https://github.com/Leeseungju1991/ICONIA-CI> (main 브랜치만)

---

## 1. 동작 순서도

```
[ 개발자 로컬 Windows ]                       [ AWS ]
   1~5번 폴더 (private)
        │
        │ pwsh -File "6. CI/scripts/build-and-upload.ps1" -Service all -TriggerDeploy
        ▼
   ┌──────────────────────────┐
   │ 1) build-and-upload.ps1  │
   │   - robocopy stage 복사  │
   │   - npm ci + (admin)     │
   │     next build standalone│
   │   - prisma generate      │
   │   - npm prune --omit=dev │
   │   - tar.gz + SHA256      │
   └──────────────────────────┘
        │
        ▼
   ┌──────────────────────────┐         ┌────────────────────────────────┐
   │ 2) aws s3 cp             │ ───────▶│ S3 artifacts bucket            │
   │   $svc/$version.tar.gz   │         │   server/<v>.tar.gz            │
   │   $svc/latest.tar.gz     │         │   ai/<v>.tar.gz                │
   │   $svc/latest.tar.gz.sha │         │   admin/<v>.tar.gz             │
   └──────────────────────────┘         │   _bootstrap/deploy.tar.gz     │
        │                                │   _bootstrap/ec2-pull-...sh   │
        │                                │   (private, SSE, versioning)  │
        ▼                                └────────────────────────────────┘
   ┌──────────────────────────┐                            │
   │ 3) trigger-deploy.ps1    │                            │
   │   aws ssm send-command   │ ─── SSM RunShellScript ──▶ │
   │   target=EC2 instance    │                            │
   └──────────────────────────┘                            ▼
                                          ┌──────────────────────────────┐
                                          │ EC2 /usr/local/bin/          │
                                          │   iconia-pull-and-restart.sh │
                                          │                              │
                                          │ a) inject_database_url       │
                                          │    (Secrets Manager fetch    │
                                          │     → /etc/iconia.*.env)     │
                                          │ b) aws s3 cp latest.tar.gz   │
                                          │    + sha256 검증             │
                                          │ c) atomic swap               │
                                          │    /opt/iconia/<svc>         │
                                          │    + .old.<ts> 백업          │
                                          │ d) prisma migrate deploy     │
                                          │    (server 만)               │
                                          │ e) systemctl restart         │
                                          │    iconia-<svc>              │
                                          │ f) systemd is-active +       │
                                          │    HTTP /health probe 30s    │
                                          │ g) 실패 시 .old.<ts> 자동    │
                                          │    swap-back + alarm metric  │
                                          └──────────────────────────────┘
                                                       │
                                          ┌────────────┼─────────────────┐
                                          ▼            ▼                 ▼
                                  systemd:server  systemd:ai      systemd:admin
                                   :8080 Express   :8081 Genome    :3000 Next.js
                                          │            │                 │
                                          └────────────┴──────┬──────────┘
                                                              │
                                                  nginx :443 (host header)
                                                       │
                                  Route53 A record (api/ai/admin → EIP)
                                                       │
                                              [ 사용자 트래픽 ]
```

**5단계 핵심 보장**:
1. **체크섬** — SHA256 사이드카로 부분 업로드/네트워크 손상 차단.
2. **원자 swap** — `mv` 한 번에 신/구 교체 (다운타임 < 1s).
3. **자동 롤백** — restart 후 30 초 내 healthy 아니면 직전 백업으로 swap-back, 그래도 실패 시 `ICONIA/Deploy/RollbackFailed` CloudWatch metric.
4. **nginx 보호** — `nginx -t` 실패 시 직전 conf 복원, 둘 다 실패 시 `NginxRestoreFailed` metric + 운영자 개입.
5. **Secrets 분리** — RDS password 는 본 폴더 평문 부재. Secrets Manager 의 `iconia/${env}/db/master_password` 에서 부팅 시 fetch.

---

## 2. 세부 항목 기능

### 2.1 IaC (`terraform/`)

| 파일 | 책임 |
|---|---|
| `main.tf` | provider, backend (S3 tfstate + DynamoDB lock), `local.name_prefix=iconia-${env}` |
| `variables.tf` | env / region / VPC CIDR / EC2 type / RDS mode / S3 버킷명 / root_domain |
| `network.tf` | VPC, public/private subnet x 2 AZ, IGW, NAT GW 1개, EC2 SG (80/443), EFS SG (2049 from EC2) |
| `s3.tf` | events (90d→Glacier_IR, 455d 만료) / exports (7d 만료) / firmware / artifacts (90d 만료 + 무한 versioning) — 모두 BlockPublicAccess + DenyInsecureTransport + SSE-S3 |
| `rds.tf` | PostgreSQL 16.4, instance(db.t4g.medium) 또는 Aurora Serverless v2 분기, Multi-AZ on prod, IAM DB auth, 30d backup, `ignore_changes=[password]` |
| `efs.tf` | persona EFS (encrypted + IA 30d 전환 + backup ON) + AP `server_root` (posix 1000:1000) + AZ 별 mount target |
| `iam.tf` | EC2 instance role. Artifacts Get/List, Events PutGet `iconia/{events,voice}/*`, Exports PutGet `iconia/exports/*`, Firmware Get `firmware/*`, Secrets `iconia/${env}/*`, CW metric `ICONIA/{Server,AI,Admin,Audit}`, CW logs `/iconia/${env}/*`, EFS AP 한정 mount, RDS `rds-db:connect` |
| `route53.tf` | hosted zone (옵션 신규) + api/ai/admin A → EIP + `api_deep` health check (`/health?deep=1`, interval 10s, threshold 3) |
| `observability.tf` | **NEW**. `/iconia/${env}/*` 로그그룹 7종 (retention IaC 소유) + PII metric filter 4종 (`cloudwatch-log-metric-filters.json` 흡수) + CloudWatch Agent config 의 SSM Parameter push (`cloudwatch-agent-config.json` 흡수) + CloudWatch 운영 Dashboard + Logs Insights saved query 4종. |
| `ssm-runbook.tf` | **NEW**. `multi-az-failover-runbook.md` §1~§4 의 manual 절차를 SSM Automation Document 2종 (`rds-multi-az-failover` / `failover-diagnostics`) 으로 packaging. apply 는 Document 만 만들고 실행은 운영자가 사고 시 명시 호출. |
| `outputs.tf` | artifacts_bucket / ec2_instance_id / EIP / rds_endpoint / efs_id / api_fqdn 등 |
| `terraform.tfvars.example` | 운영자가 복사 후 `root_domain` / `hosted_zone_id` 채움 |

### 2.2 EC2 부트스트랩 (`ec2-bootstrap/`)

| 파일 | 책임 |
|---|---|
| `user-data.sh.tftpl` | 최초 부팅 시 1회. apt install (nginx / certbot / amazon-efs-utils / Node 20 / CloudWatch Agent), AWS CLI v2 공식 zip, `iconia` user 생성, `/opt/iconia/{server,ai,admin}` 디렉토리, EFS fstab + mount, `/etc/iconia.env` 작성 (DB password 제외), `_bootstrap/ec2-pull-and-restart.sh` fetch + 첫 실행, certbot --nginx (Let's Encrypt) HTTP-01 발급, certbot.timer 활성 |

### 2.3 systemd unit (`deploy/systemd/`)

| 파일 | port | WorkingDirectory | EnvironmentFile |
|---|---|---|---|
| `iconia-server.service` | 8080 | `/opt/iconia/server` | `/etc/iconia.env` + `-/etc/iconia.server.env` |
| `iconia-ai.service` | 8081 | `/opt/iconia/ai` | `/etc/iconia.env` + `-/etc/iconia.ai.env` |
| `iconia-admin.service` | 3000 | `/opt/iconia/admin/.next/standalone` | `/etc/iconia.env` + `/etc/iconia.admin.env` |

공통 hardening: `User=iconia`, `NoNewPrivileges`, `ProtectSystem=strict`, `ReadWritePaths=/opt/iconia/<svc> /mnt/efs/iconia /var/log/iconia /tmp`, `MemoryDenyWriteExecute`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`, `Restart=always`.

### 2.4 nginx (`deploy/nginx/`)

| 파일 | 책임 |
|---|---|
| `iconia.conf` | 80→443 redirect, ACME http-01 location, api/ai/admin 3 server 블록. HSTS/CSP/Permissions-Policy, TLS 1.2+, rate limit zone (`iconia_device_ip` 60r/m, `iconia_device_key` 12r/m, `iconia_app` 60r/m, `iconia_admin` 120r/m), `/api/event` 멀티파트 10MB, `/api/v1/devices/*/messages/voice` 6MB |
| `snippets-iconia-proxy.conf` | 공통 `proxy_set_header` (X-Forwarded-For, X-Real-IP, X-Forwarded-Proto, Connection upgrade for ws, X-Iconia-Canary 통과) |

### 2.5 AWS 운영 정본 (`deploy/aws/`)

| 파일 | 책임 |
|---|---|
| `alarms.tf` | **CloudWatch alarm IaC**. 5xx rate / AI p95 latency 8s / refresh-token reuse / lifecycle finalizer 24h stall / data export pending 10 backlog / RDS CPU 80% / RDS FreeableMemory / Redis connection error / Redis no-connections. SNS topic `iconia-server-alarms` + email / PagerDuty subscription. `terraform/` 최상위 stack 이 module 로 흡수. |
| `cloudwatch-alarms.json` | 위 IaC 의 CLI 변종 (직접 적용용). + AI timeout rate / push delivery rate / push token invalidated spike / push latency p95 / Gemini cache hit rate |
| `cloudwatch-log-metric-filters.json` | PII 누출 감지 metric filter 정본. email / KR phone / Bearer / WiFi PSK 패턴 → `ICONIA/Audit` namespace 송출. **`terraform/observability.tf` 가 IaC 로 흡수** — 본 JSON 은 패턴 reference 로 유지. |
| `cloudwatch-agent-config.json` | CloudWatch Agent fetch-config 정본. `/var/log/iconia/{server,ai,admin,audit}.log` + nginx access/error + user-data 로그 → `/iconia/${env}/*` log group. CPU/mem/disk/net/swap 지표 `ICONIA/Host` namespace. **`terraform/observability.tf` 가 본 JSON 을 그대로 읽어 SSM Parameter Store 에 push** (이중 정본 방지 — JSON 이 단일 source). |
| `sentry-dsn-mapping.md` | **NEW**. iconia-server / -ai / -admin / -app 4개 프로젝트, DSN 저장은 Secrets Manager (`iconia/${env}/sentry/<svc>_dsn`) + Expo EAS Secret. environment 태그, release 식별자, PII 마스킹 (`beforeSend`), 90d retention + PIPA 국외 이전 동의 연결. |
| `push-delivery-policy.md` | **NEW**. Expo push token 라이프사이클, receipts 15분 cron, `ICONIA/Push` namespace 메트릭 정본, FCM 서비스계정 JSON 6개월 / APNs .p8 12개월 회전 정책, EAS managed credentials 흐름. |
| `canary-routing.md` | **NEW**. 현 단계: application-layer canary (`X-Iconia-Canary` 헤더 + user_id modulo). 옵션: Route53 weighted A record (stable 95 / canary 5 → 25 → 50 → 100). 자동 회수 trigger (5xx >= 1% → Weight=0). ALB 도입 시 deprecated. |
| `multi-az-failover-runbook.md` | RDS / EFS / ElastiCache / EC2 AZ 장애 시 단계별 manual 절차. RTO/RPO 목표, 자동 failover 대기 vs force-failover, post-mortem 템플릿. |
| `iam_policy_device_provisioning.json` / `iam_policy_secret_rotation.json` | 디바이스 프로비저닝 + 비밀 회전 Lambda 의 별도 IAM 정책 (참고). |
| `s3-*.json` / `iam-ec2-*.json` / `kms-key-policy.json` | terraform 도입 이전의 정본. CDK/Terraform 으로 흡수됨 (reference). |

### 2.6 PowerShell / shell 스크립트 (`scripts/`)

| 파일 | 책임 |
|---|---|
| `bootstrap-aws.ps1` | **1회**. S3 tfstate 버킷 + DynamoDB lock 테이블 생성 (idempotent). `terraform init -backend-config=...` 명령 출력. |
| `seed-db-password.ps1` | **1회**. RDS master password 랜덤 (32자) 생성 → Secrets Manager `iconia/${env}/db/master_password` (JSON `{username, password}`) 등록. |
| `build-and-upload.ps1` | 로컬 빌드 (robocopy → npm ci → admin: next build standalone + static 복사 → prisma generate → npm prune) + SHA256 + S3 업로드 (`server/$ver.tar.gz`, `server/latest.tar.gz`, `server/latest.tar.gz.sha256`). `_bootstrap` 모드는 systemd unit + nginx conf + 본 스크립트 자체를 묶어 `_bootstrap/deploy.tar.gz` + `_bootstrap/ec2-pull-and-restart.sh` 업로드. |
| `trigger-deploy.ps1` | `aws ssm send-command --document-name AWS-RunShellScript` 로 EC2 의 `iconia-pull-and-restart.sh` 호출. `--cloud-watch-output-config` 활성. 5분 polling 후 STDOUT/STDERR 출력. |
| `ec2-pull-and-restart.sh` | EC2 host 에서 실행. inject_database_url (Secrets Manager → `/etc/iconia.{server,ai}.env`), tarball pull + SHA256 검증, atomic swap + `.old.<ts>` 백업, npm ci prod-only, prisma migrate deploy (server 한정), systemctl restart, 30s healthcheck (`is-active --wait` + `curl /health`), 실패 시 자동 swap-back + CW metric. `_bootstrap` 단계는 systemd unit / nginx conf 설치 + 인증서 부재 시 443 server 블록 임시 비활성. |
| `preflight-placeholders.{sh,ps1}` | 6 폴더 횡단 placeholder (`PLACEHOLDER` / `TODO` / `EXAMPLE_DOMAIN` 등) 검사. release tag 푸시 시 GH Actions 가 호출. |
| `check-soul-catalog-sync.js` | Server `SOUL_CATALOG_V1_IDS` ↔ AI `CATALOG_V1_IDS` lockstep 검증. |
| `preflight-placeholders.test.sh` / `check-soul-catalog-sync.test.sh` | 위 스크립트 자체의 회귀 차단 unit test (GH Actions 매 push 마다). |

### 2.7 GitHub Actions (`.github/workflows/`)

| 파일 | trigger | 책임 |
|---|---|---|
| `release-preflight.yml` | tag `v*` 푸시 + 매 push (테스트만) | 6 폴더 placeholder 검사 + soul catalog sync (sibling repo 있을 때) + 두 스크립트 unit test |
| `test-gate.yml` | 매 push / PR / `workflow_call` | **테스트 게이트**. CI 리포 자체 검증(shell 문법 + shellcheck + terraform fmt/validate + preflight unit test) + SERVER/AI/ADMIN 단위·lint·typecheck 테스트. 하나라도 실패 시 배포 차단. `deploy.yml` 이 재사용 호출. |
| `deploy.yml` | tag `v*` 푸시 / `workflow_dispatch` | **v1.0 자동 배포 파이프라인**. preflight → test-gate → build(3서비스+_bootstrap → S3) → deploy(SSM) → smoke(Route53 E2E). OIDC 로 AWS 인증 (정적 키 미저장). `concurrency` 로 동시 배포 race 차단. `dry_run` 옵션. |

### 2.8 배포 스크립트 — Linux/CI 변종 (`scripts/`)

| 파일 | 책임 |
|---|---|
| `build-and-upload.sh` | `build-and-upload.ps1` 의 Linux 등가물. rsync stage + npm ci + admin next build standalone + prisma generate + npm prune + tar + SHA256 + S3 업로드. sibling(`ICONIA-SERVER`) / 숫자 폴더(`2. SERVER`) 두 레이아웃 지원. GitHub Actions runner 에서 동작. |
| `trigger-deploy.sh` | `trigger-deploy.ps1` 의 Linux 등가물. SSM `AWS-RunShellScript` 발사 + polling. |
| `post-deploy-smoke.sh` | 배포 후 **외부 end-to-end 스모크 테스트**. ec2-pull-and-restart.sh 의 호스트-내부 healthcheck 와 별개로, Route53 FQDN + TLS + nginx 라우팅까지 검증. `/health`, `/health?deep=1`, admin root, HTTP→HTTPS 리다이렉트. 실패 시 워크플로우 실패 → 운영자 즉시 인지. |

### 2.9 배포 Runbook (`deploy/RUNBOOK.md`)
1회성 부트스트랩 / 자동 배포(태그·dispatch) / 로컬 배포 / 호스트 동작 / 출시 전 체크리스트 / GitHub secrets / 수동 롤백 / 트러블슈팅.

---

## 3. 작업 완료된 범위

### 3.1 IaC (Terraform — Route53 + EC2 + S3 + RDS + EFS + IAM)
- VPC / Subnet / IGW / NAT / EC2 SG / EFS SG (network.tf)
- EC2 + EIP + user-data 템플릿 (ec2.tf + ec2-bootstrap/)
- S3 4 버킷 (events / exports / firmware / artifacts) + lifecycle + BlockPublicAccess + SSE + DenyInsecureTransport
- RDS PostgreSQL 16.4 (instance / Aurora Serverless v2 분기) + Multi-AZ on prod + IAM DB auth
- EFS + access point + AZ별 mount target + backup ON + IA 30일 전환
- Route53 hosted zone + 3 A record + `/health?deep=1` health check
- EC2 instance profile (S3 prefix 한정 / Secrets `iconia/${env}/*` / CW metric+logs namespace 한정 / EFS AP 한정 / RDS connect)
- tfstate S3 + DynamoDB lock 부트스트랩 스크립트 (idempotent)

### 3.2 배포 파이프라인 (로컬 → S3 → EC2)
- PowerShell `build-and-upload.ps1` (robocopy + npm ci + Next.js standalone + prisma generate + npm prune + tar + SHA256)
- `trigger-deploy.ps1` (SSM RunShellScript + 5분 polling + CloudWatch output)
- EC2 `ec2-pull-and-restart.sh` — Secrets Manager fetch / SHA256 검증 / atomic swap / `.old.<ts>` 백업 / prisma migrate deploy / systemd + HTTP health 30s probe / **자동 swap-back 롤백** / nginx conf 자동 복원 / 실패 시 `ICONIA/Deploy/*` metric
- systemd 3 unit (server/ai/admin) — hardening 풀세트 (NoNewPrivileges / ProtectSystem strict / ReadWritePaths / MemoryDenyWriteExecute / RestrictAddressFamilies)
- nginx 3 server block + rate limit zone 4종 + HSTS/CSP/Referrer-Policy + Let's Encrypt 자동 발급 + 인증서 부재 시 443 블록 임시 비활성 데드락 방지

### 3.3 모니터링 / 로그
- CloudWatch alarms.tf — 5xx rate / AI p95 latency / refresh-token reuse / finalizer 24h stall / export pending backlog / RDS CPU / RDS memory / Redis connection error / Redis no-connections (9개)
- CloudWatch alarms.json — 위 + AI timeout rate / push delivery rate / push token invalidated / push p95 latency / Gemini cache hit rate (총 14개)
- **PII 누출 metric filter IaC 흡수** (`observability.tf`) — email / KR phone / Bearer / WiFi PSK 4종을 `aws_cloudwatch_log_metric_filter` 로. `cloudwatch-log-metric-filters.json` 은 패턴 reference.
- SNS topic `iconia-server-alarms` + email + PagerDuty subscription
- CloudWatch Agent fetch-config 정본 (cloudwatch-agent-config.json) — Host 메트릭 + 7개 log group + retention 14/30/60/90/365일 분기
- **CloudWatch Agent config → SSM Parameter Store push IaC** (`observability.tf` `aws_ssm_parameter`) — user-data 가 `fetch-config -c ssm:<param>` 로 자동 적용. 운영자 수동 SSM 등록 단계 제거.
- **로그그룹 7종 IaC 소유** (`observability.tf` `aws_cloudwatch_log_group`) — `/iconia/${env}/*` retention drift 방지.
- **CloudWatch 운영 Dashboard** (`observability.tf` `aws_cloudwatch_dashboard`) — Server 5xx / AI p95 / Push / RDS CPU·메모리 / Host CPU·메모리 / 배포·롤백 단일 보드.
- **CloudWatch Logs Insights saved query 4종** (`observability.tf` `aws_cloudwatch_query_definition`) — PII 누출 / RAG 실패 / refresh token reuse / 배포 실패 timeline.

### 3.4 보안 / 비밀
- Secrets Manager: DB master password 자동 생성 + 회전 Lambda hook (`iconia-${env}-rds-password-rotator`, 활성화 옵션 `-var enable_rds_password_rotation=true`)
- KMS key policy (회전 활성) + S3 SSE
- `.gitignore` 의 `.env*` / `*.pem` / `*.key` / `id_rsa*` / `*.p12` 차단
- Sentry DSN 4개 프로젝트 매핑 정본 + Secrets Manager 저장 경로 + EAS Secrets

### 3.5 운영 문서
- Multi-AZ failover runbook (RDS / EFS / ElastiCache / EC2 / S3, RTO/RPO 명세 + force-failover 명령)
- Canary 라우팅 정본 (application-layer + Route53 weighted 옵션 + 자동 회수)
- Push delivery 정본 (Expo 토큰 라이프사이클 + FCM JSON 6m / APNs .p8 12m 회전)
- Sentry DSN 매핑 (4 프로젝트 + environment / release / PII 마스킹 + 90d retention + PIPA 국외 이전)
- **DR runbook 자동화** (`ssm-runbook.tf`) — `multi-az-failover-runbook.md` §1~§4 의 manual 절차를 SSM Automation Document 2종으로 packaging. `rds-multi-az-failover` (진단 → 옵션 force-failover → available 대기 → SNS 통지), `failover-diagnostics` (EFS/RDS 1차 분류). apply 는 Document 만 생성 — 실행은 운영자가 사고 시 명시 호출.

### 3.6 CI/CD — 완전 자동 배포 (v1.0)
- **테스트 게이트** (`test-gate.yml`): SERVER/AI/ADMIN 단위·lint·typecheck 테스트 + CI 리포 자체 검증(shell 문법 / shellcheck / terraform fmt+validate / preflight unit test). 실패 시 배포 차단.
- **CD 파이프라인** (`deploy.yml`): tag `v*` 또는 수동 dispatch → preflight → test-gate → build → deploy → smoke 의 5단계. 한 단계라도 실패 시 후속 중단.
- **OIDC 인증**: 정적 AWS access key 를 리포에 저장하지 않음 (PIPA — `id-token: write` + `AWS_DEPLOY_ROLE_ARN`).
- **동시 배포 차단**: `concurrency: iconia-deploy-prod`.
- **외부 스모크 테스트** (`post-deploy-smoke.sh`): 배포 직후 Route53 FQDN E2E 검증 — 호스트 내부 자동 롤백과 별개의 2차 그물.
- Linux 빌드/배포 스크립트 (`build-and-upload.sh` / `trigger-deploy.sh`) — Windows PowerShell 의존 제거.
- release-preflight workflow (tag v* 시 placeholder + soul catalog sync 검사, miss 시 release 차단)
- preflight scripts unit test (매 push)
- 배포 Runbook (`deploy/RUNBOOK.md`) — 1회성 부트스트랩 / 자동·수동 배포 / 체크리스트 / 롤백.

---

## 4. 향후 작업 필요한 범위

### 4.1 진정한 IaC 흡수 (M+1) — ✅ 대부분 완료
- [x] CloudWatch Logs metric filter (PII 누출 4종) 를 `terraform/observability.tf` 의 `aws_cloudwatch_log_metric_filter` 로 흡수. `cloudwatch-log-metric-filters.json` 은 패턴 reference 로 유지.
- [x] CloudWatch Agent config 를 SSM Parameter Store 에 push 하는 `aws_ssm_parameter "cloudwatch_agent_config"` 추가. user-data 가 `fetch-config -c ssm:<param>` 로 자동 적용 — 운영자 수동 SSM 등록 단계 제거.
- [x] `/iconia/${env}/*` 로그그룹 7종을 `aws_cloudwatch_log_group` 으로 IaC 소유 (retention drift 방지).
- 남은 과제(🔴): `kms-key-policy.json` / `s3-*.json` / `iam-ec2-*.json` 의 잔여 CLI 정본은 **실제 운영 KMS CMK·기존 버킷이 이미 존재하는 상태에서의 `terraform import` 가 필요** — apply/import 권한 부재로 본 환경에서 불가. 신규 환경은 이미 `s3.tf`/`iam.tf` 가 IaC 정본이므로 reference 상태로 유지.
- 남은 과제(🔴): `alarms.tf` 를 standard module path(레지스트리/별도 repo)로 분리하는 것은 module 게시 인프라 결정 사항 — 현재 `../deploy/aws` relative path module 로 동작 정상, 구조 변경은 운영 결정 후.

### 4.2 ALB / ASG 도입 — 🔴 README 유지
- [ ] 단일 EC2 → ALB + ASG 2+ (Multi-AZ) 전환. 현재는 EIP 하나 가리키기라 EC2 죽으면 다운.
- [ ] Target Group 두 개 (stable / canary) + listener rule weighted forwarding → 진정한 L7 canary.
- [ ] `canary-routing.md` 의 Route53 weighted 모드 deprecated 처리.
- [ ] **ALB sticky session** — websocket / SSE 케이스만 식별 후 enable.
- 사유: ALB/ASG 전환은 단순 terraform 코드 추가가 아니라 **부트스트랩 모델(user-data 1회 → launch template + instance refresh) / 배포 경로(SSM 단일 instance → ASG fleet) / EIP→ALB DNS / certbot→ACM** 의 동시 재설계를 요구한다. 코드만 추가하고 검증 없이 두면 `ec2.tf`/`ec2-pull-and-restart.sh`/`deploy.yml` 과 정합이 깨진 죽은 코드가 된다. 실 ALB/ASG 프로비저닝(apply)과 무중단 cutover 리허설이 동반돼야 하므로 별도 라운드로 유지.

### 4.3 다중 리전 / DR — 🔴 README 유지
- [ ] S3 Cross-Region Replication 활성 (events / exports / firmware 의 secondary region).
- [ ] RDS read replica 를 secondary region 에 (Aurora Global Database 검토).
- [ ] Route53 latency-based / failover routing 정책 추가.
- [ ] CloudFront 진입 (정적 자산 + 글로벌 latency).
- 사유: secondary region provider alias / 대상 region 의 실 버킷·KMS·VPC 가 필요하고, CRR 의 IAM replication role 과 RDS cross-region replica 는 실 apply 없이는 정합 검증 불가. 다중 리전 비용/RPO 정책 결정이 선행돼야 함.

### 4.4 Secrets / key 회전 운영화 — 🔴 README 유지
- [ ] Secrets Manager 의 RDS password 회전 Lambda 활성 (`enable_rds_password_rotation=true` 디폴트화 — 현재는 안전상 off).
- [ ] Sentry DSN 4개 organization quota 알람 자동화.
- [ ] FCM service account JSON 6개월 만료 알림 (Expo EAS GraphQL sync).
- [ ] APNs .p8 key 회전 D-30 알림.
- 사유: 회전 디폴트화는 **운영 정책 결정 사항** (회전 중 짧은 단절 허용 여부) — 코드는 이미 `rds-password-rotation.tf` 에 존재, 변수 1개만 운영팀이 토글하면 됨. Sentry/EAS quota·만료 sync 는 외부 SaaS GraphQL token 과 실 Lambda 배포가 필요.

### 4.5 카나리 자동화 — 🔴 README 유지
- [ ] `canary-routing.md` §2.3 의 자동 weight 증가 / 회수 Lambda 구현. 현재는 manual.
- [ ] application-layer canary 진입 percent 를 SSM Parameter 로 외부화 → admin 콘솔 조절.
- 사유: 자동 weight Lambda 는 §4.2 ALB target group 도입을 전제로 한다 (Route53 weighted 모드는 ALB 도입 시 deprecated 예정 — canary-routing.md §4). ALB 라운드와 묶어 진행해야 중복 작업 방지.

### 4.6 운영 가시성 — ✅ 완료
- [x] CloudWatch Dashboard (`terraform/observability.tf` `aws_cloudwatch_dashboard`) — Server 5xx / AI p95 / Push / RDS CPU·메모리 / Host / 배포·롤백 단일 보드.
- [x] CloudWatch Logs Insights saved query 4종 (`aws_cloudwatch_query_definition`) — PII 누출 / RAG 실패 / refresh token reuse / 배포 실패 timeline.
- [x] SSM Document 자동화 (`terraform/ssm-runbook.tf`) — `multi-az-failover-runbook.md` §1~§4 명령을 SSM Automation Document 2종(`rds-multi-az-failover`, `failover-diagnostics`)으로 packaging. apply 는 Document 생성만, 실행은 운영자 명시 호출.

### 4.7 HW / APP 트랙 (별도 폴더)
- HW 펌웨어 OTA: firmware S3 버킷에 운영자 PowerShell 업로드 + Server presign read-only — 본 폴더는 자동화 안 함, OTA scheduler 별도 라운드.
- APP: Expo EAS Build / Submit 별도 트랙 — 본 폴더는 무관. 단, push delivery 정본 (`deploy/aws/push-delivery-policy.md`) 만 본 폴더가 정본.

### 4.8 GitHub Actions 확장 — ✅ v1.0 완료
- [x] `test-gate.yml` — SERVER/AI/ADMIN 의 단위·lint·typecheck 테스트를 sibling repo checkout 후 실행 (배포 게이트).
- [x] `build-and-upload.sh` (Linux runner 변종) + `deploy.yml` — 빌드 → S3 업로드 → SSM 배포 → 스모크 테스트 자동화.
- [x] OIDC 로 AWS 권한 위임 (access key 정적 저장 회피).
- 남은 운영 과제(🔴 환경 한계로 본 라운드 불가):
  - GitHub Environment `production` reviewer 승인 게이트 — **레포 Settings > Environments 의 설정 항목**이라 코드(워크플로우 YAML)로 표현 불가. `deploy.yml` 의 `build`/`deploy` 잡은 이미 `environment: production` 을 선언하므로, 운영자가 레포 설정에서 reviewer 만 추가하면 즉시 승인 게이트가 활성된다. 조직 정책 결정 후 1회 설정.
  - sibling repo (SERVER/AI/ADMIN) 자체 CI 워크플로우 분산 설치 — **본 리포(ICONIA-CI) 작업 범위 밖의 다른 레포 파일 생성**. 본 리포는 통합 CI 정본이며, sibling 레포 워크플로우는 각 레포 라운드에서 추가. (현재 `test-gate.yml` 이 sibling 3개를 checkout 해 배포 게이트로 검증 중이므로 배포 안전성은 이미 확보됨.)

---

**작업 폴더 외부 절대 건드리지 않음**. 본 라운드(향후 항목 IaC 흡수) 변경:
- 신규 `terraform/observability.tf` — 로그그룹 7종 / PII metric filter 4종 / CloudWatch Agent SSM Parameter / 운영 Dashboard / Logs Insights query 4종 (README §4.1·§4.6 흡수).
- 신규 `terraform/ssm-runbook.tf` — Multi-AZ failover SSM Automation Document 2종 (README §4.6 / `multi-az-failover-runbook.md` §7 흡수).
- `ec2-bootstrap/user-data.sh.tftpl` — CloudWatch Agent `fetch-config -c ssm:<param>` 호출 추가.
- `terraform/ec2.tf` — user-data 에 `cw_agent_ssm_param` 주입.
- `terraform/network.tf` — SG rule description 을 ASCII 로 교정 (AWS API 제약 — `terraform validate` 가 검출한 기존 결함).
- 본 README §2.1·§2.5·§3.3·§3.5·§4 갱신.

검증: `terraform fmt -check -recursive` 통과, `terraform validate` 통과 (로컬 provider mirror), `bash -n` shell 문법 / YAML 워크플로우 무변경. 실 `terraform apply` 는 본 환경 권한 부재로 미수행 — CI 의 `test-gate.yml` connected runner 가 매 push 마다 fmt+validate 재검증.
