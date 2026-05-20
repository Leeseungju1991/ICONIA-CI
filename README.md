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
| `cloudwatch-log-metric-filters.json` | PII 누출 감지 metric filter. email / KR phone / Bearer / WiFi PSK 패턴 → `ICONIA/Audit` namespace 송출. |
| `cloudwatch-agent-config.json` | **NEW**. CloudWatch Agent SSM fetch-config 정본. `/var/log/iconia/{server,ai,admin,audit}.log` + nginx access/error + user-data 로그 → `/iconia/${env}/*` log group, 14-365d retention. CPU/mem/disk/net/swap 지표 `ICONIA/Host` namespace. |
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
- PII 누출 metric filter (email / KR phone / Bearer / WiFi PSK)
- SNS topic `iconia-server-alarms` + email + PagerDuty subscription
- **CloudWatch Agent fetch-config 정본** (cloudwatch-agent-config.json) — Host 메트릭 + 8개 log group + retention 14/30/60/90/365일 분기

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

### 3.6 CI gate
- release-preflight workflow (tag v* 시 placeholder + soul catalog sync 검사, miss 시 release 차단)
- preflight scripts unit test (매 push)

---

## 4. 향후 작업 필요한 범위

### 4.1 진정한 IaC 흡수 (M+1)
- [ ] `deploy/aws/*.json` 의 CLI 정본을 모두 `terraform/` 로 흡수 (현재는 두 정본이 공존 — alarms.tf 가 일부 흡수했으나 metric filter / KMS / 일부 IAM 은 여전히 CLI 정본).
- [ ] `terraform/` 의 root module 이 `deploy/aws/alarms.tf` 를 module 로 호출하는 패턴을 standard module path 로 정리.
- [ ] CloudWatch Agent config 를 SSM Parameter Store 에 push 하는 Terraform 리소스 추가 (`aws_ssm_parameter "cloudwatch_agent_config"`).

### 4.2 ALB / ASG 도입
- [ ] 단일 EC2 → ALB + ASG 2+ (Multi-AZ) 전환. 현재는 EIP 하나 가리키기라 EC2 죽으면 다운.
- [ ] Target Group 두 개 (stable / canary) + listener rule weighted forwarding → 진정한 L7 canary.
- [ ] `canary-routing.md` 의 Route53 weighted 모드 deprecated 처리.
- [ ] **ALB sticky session** — `iconia-app` 의 BLE 페어링 세션이 ALB 거치면서 instance 간 잘 흩어지지 않도록. 다만 server 가 stateless 설계이므로 sticky 가 필요한 케이스 (websocket / SSE) 만 식별 후 enable.

### 4.3 다중 리전 / DR
- [ ] S3 Cross-Region Replication 활성 (events / exports / firmware 의 secondary region).
- [ ] RDS read replica 를 secondary region 에 (Aurora Global Database 검토).
- [ ] Route53 latency-based / failover routing 정책 추가 (`api.${root}` 가 primary region 다운 시 secondary 로 회수).
- [ ] CloudFront 진입 (App-측 정적 자산 + Admin Next.js static + 글로벌 사용자 latency).

### 4.4 Secrets / key 회전 운영화
- [ ] Secrets Manager 의 RDS password 회전 Lambda 활성 (`enable_rds_password_rotation=true` 디폴트화 — 현재는 안전상 off).
- [ ] Sentry DSN 4개의 자동 회전 — DSN 자체는 회전 안 하지만, 4 프로젝트가 단일 organization quota 공유라 quota 알람 자동화 필요.
- [ ] FCM service account JSON 의 6개월 만료 알림 (Sentry organization + Expo EAS credentials page 의 expiry 를 CloudWatch 의 외부 metric 으로 sync — Lambda + EAS GraphQL).
- [ ] APNs .p8 key 회전 D-30 알림.

### 4.5 카나리 자동화
- [ ] `canary-routing.md` §2.3 의 자동 weight 증가 / 회수 Lambda 구현. 현재는 manual.
- [ ] application-layer canary 의 진입 percent 를 SSM Parameter `iconia/${env}/canary/percent` 로 외부화 → admin 콘솔에서 조절.

### 4.6 운영 가시성
- [ ] CloudWatch Dashboard JSON (terraform `aws_cloudwatch_dashboard`) — Server 5xx / AI p95 / Push delivery rate / RDS CPU 의 단일 보드.
- [ ] CloudWatch Logs Insights saved query (PII 누출 패턴 / RAG 실패 / refresh token reuse 의 ad-hoc 조회) → `aws_cloudwatch_query_definition` 으로 IaC.
- [ ] SSM Document 자동화 — multi-az-failover-runbook 의 §1~§4 명령을 1-click runbook 으로 packaging.

### 4.7 HW / APP 트랙 (별도 폴더)
- HW 펌웨어 OTA: firmware S3 버킷에 운영자 PowerShell 업로드 + Server presign read-only — 본 폴더는 자동화 안 함, OTA scheduler 별도 라운드.
- APP: Expo EAS Build / Submit 별도 트랙 — 본 폴더는 무관. 단, push delivery 정본 (`deploy/aws/push-delivery-policy.md`) 만 본 폴더가 정본.

### 4.8 GitHub Actions 확장
- [ ] 현재는 release preflight 만. 본 폴더에 1~5 sibling repo 의 CI 호출 (matrix build / test) 미설치.
- [ ] tag 푸시 시 `build-and-upload.ps1` 의 GitHub-hosted Linux runner 변종 (`build-and-upload.sh`) 으로 GitHub Actions 가 빌드 → S3 업로드 → trigger-deploy 까지 자동화 가능. OIDC 로 AWS 권한 위임 (PIPA 차원에서 access key 정적 저장 회피).

---

**작업 폴더 외부 절대 건드리지 않음**. 본 README + `deploy/aws/{cloudwatch-agent-config.json, sentry-dsn-mapping.md, push-delivery-policy.md, canary-routing.md}` + `deploy/aws/cloudwatch-alarms.json` 의 4개 알람 추가만이 본 라운드 변경.
