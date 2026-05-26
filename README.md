# ICONIA CI (인프라 · 배포 · 운영 정본)

ICONIA 시스템의 **6번 레포 = 통합 CI/CD · AWS 인프라 · 운영 정본**.

ICONIA 는 6개 레포로 구성된다.

| # | 레포 | 역할 | 배포 트랙 |
|---|---|---|---|
| 1 | HW | 디바이스 펌웨어 | OTA (firmware S3 버킷, 별도 트랙) |
| 2 | SERVER | Node.js Express API | **본 레포가 AWS EC2 로 배포** |
| 3 | AI | Genome / Gemini 추론 서비스 | **본 레포가 AWS EC2 로 배포** |
| 4 | APP | Expo 모바일 앱 | EAS Build / Submit (별도 트랙) |
| 5 | ADMIN | Next.js 관리 콘솔 | **본 레포가 AWS EC2 로 배포** |
| 6 | **CI** | **인프라(Terraform) · 배포 파이프라인 · 운영 정본 — 본 레포** | — |

설계 목표: **`localhost 동작 확인 → 아주 간단한 수정 → AWS 실배포 즉시 출시`**.
전환은 `.env` 의 **`DEPLOY_TARGET` 한 줄 (`local` / `aws`)** 로 한다.

---

## 1. 구조도

```
                          [ 사용자 / 디바이스 / 운영자 ]
                                      │
                          Route53 (hosted zone)
              api.<domain>   ai.<domain>   admin.<domain>   ── A record → EIP
                                      │
                                health check: /health?deep=1
                                      │
┌─────────────────────────────────────────────────────────────────────────────┐
│ VPC 10.42.0.0/16  (ap-northeast-2)                                          │
│                                                                             │
│  ┌── Public Subnet (AZ-a) ───────────┐   ┌── Public Subnet (AZ-c) ─────────┐│
│  │  Internet Gateway                  │   │                                 ││
│  │  ┌──────────────────────────────┐  │   │   (Multi-AZ 예비 / ALB 도입시)  ││
│  │  │ EC2  iconia-<env>-host  + EIP │  │   │                                 ││
│  │  │  ┌────────────────────────┐  │  │   └─────────────────────────────────┘│
│  │  │  │ nginx :80→:443 (TLS)   │  │  │                                       │
│  │  │  │  rate-limit / HSTS/CSP │  │  │   ┌── Private Subnet (AZ-a / AZ-c) ──┐│
│  │  │  ├────────────────────────┤  │  │   │                                  ││
│  │  │  │ systemd:                │  │  │   │  RDS PostgreSQL 16  (Multi-AZ)   ││
│  │  │  │  iconia-server :8080 ◄──┼──┼──┼───┼──► (3.AI / 2.SERVER 공용)        ││
│  │  │  │  iconia-ai     :8081    │  │  │   │                                  ││
│  │  │  │  iconia-admin  :3000    │  │  │   │  EFS  persona  (encrypted)       ││
│  │  │  └────────────────────────┘  │  │   │   access point per-user-space    ││
│  │  │  CloudWatch Agent             │  │   │   /mnt/efs/iconia (NFS 2049)     ││
│  │  └──────────────────────────────┘  │   └──────────────────────────────────┘│
│  └────────────────────────────────────┘                                       │
│        │ NAT Gateway → IGW (outbound)                                         │
└─────────────────────────────────────────────────────────────────────────────┘
         │                                  │                         │
         ▼                                  ▼                         ▼
┌──────────────────┐         ┌───────────────────────────┐   ┌──────────────────┐
│ S3 (4 버킷)      │         │ Secrets Manager           │   │ CloudWatch       │
│  events          │         │  iconia/<env>/db/         │   │  /iconia/<env>/* │
│  exports         │         │   master_password (Lambda │   │   log group 7종  │
│  firmware  ◄─ 1.HW OTA     │   rotator: rds_password_  │   │  ICONIA/* metric │
│  artifacts ◄─ 배포 산출물  │   rotator.py)             │   │  alarm + SNS     │
└──────────────────┘         │  iconia/<env>/sentry/*    │   │  Dashboard       │
                              └───────────────────────────┘   └──────────────────┘
                                            │
                                            ▼
                              ┌───────────────────────────┐
                              │ Quotas Auto-Lift Lambda    │
                              │ (quotas-auto-lift.tf)      │
                              │ + EFS Userspace Lambda     │
                              │ (efs-user-access-points.tf)│
                              └───────────────────────────┘

배포 대상 매핑
  2. SERVER  ──build──▶  S3 artifacts/server/   ──EC2 pull──▶  systemd iconia-server :8080
  3. AI      ──build──▶  S3 artifacts/ai/       ──EC2 pull──▶  systemd iconia-ai     :8081
  5. ADMIN   ──build──▶  S3 artifacts/admin/    ──EC2 pull──▶  systemd iconia-admin  :3000
  6. CI      ──build──▶  S3 artifacts/_bootstrap/ ─────────▶  nginx + systemd unit 설치
  1. HW      ───────────────────────────────────────────────  firmware S3 (OTA, 별도 트랙)
  4. APP     ───────────────────────────────────────────────  Expo EAS Build (별도 트랙)
```

| 계층 | 리소스 | Terraform 파일 |
|---|---|---|
| 진입 | Route53 hosted zone + api/ai/admin A record + deep health check | `route53.tf` |
| 네트워크 | VPC / public·private subnet × 2 AZ / IGW / NAT GW / SG | `network.tf` |
| 컴퓨트 | EC2 단일 호스트(Server+AI+Admin systemd) + EIP + user-data | `ec2.tf` / `ec2-bootstrap/` |
| 컴퓨트 (확장) | ASG / ALB / launch template — 단일 EC2 호환 토글 유지 | `asg.tf` / `alb.tf` / `launch_template.tf` |
| 데이터 | RDS PostgreSQL 16 (instance / Aurora Serverless v2 분기, Multi-AZ on prod) + RDS Proxy | `rds.tf` |
| 캐시 | ElastiCache Redis Multi-AZ (Server 의 quota/idempotency/rate 외부화 정합) | `elasticache.tf` |
| 영속성 | EFS persona (encrypted, IA 30d, backup) + 사용자별 access point | `efs.tf` / `efs-user-access-points.tf` |
| 저장소 | S3 events / exports / firmware / artifacts (SSE + BlockPublicAccess) | `s3.tf` |
| 권한 | EC2 instance role (S3 / Secrets / CW / EFS / RDS connect) | `iam.tf` |
| 가시성 | log group 7종 / PII metric filter / Dashboard / Logs Insights / Budgets | `observability.tf` / `alarms.tf` / `cloudwatch_dashboard.tf` / `budgets.tf` |
| Lambda 운영 자산 | RDS password rotator / EFS userspace provisioner / GCP quotas auto-lift | `lambda/` + `rds-password-rotation.tf` / `quotas-auto-lift.tf` |
| DR | Multi-AZ failover SSM Automation Document 2종 | `ssm-runbook.tf` |

---

## 2. 동작 설명 (5줄)

- 코드 push → tag 만 붙이면 GitHub Actions 가 6개 레포 placeholder 검사 (도메인/시크릿 + **(주)숨코리아 약관/사업자정보 placeholder** — `__TBD__` / `__PLACEHOLDER__` / `XXX-XX-XXXXX` / `Soom Korea Inc. (placeholder)`) → 테스트 → 빌드 → S3 업로드 → EC2 무중단 swap → Route53 외부 스모크까지 자동 진행한다.
- EC2 한 호스트 위에 SERVER · AI · ADMIN 세 서비스가 systemd 로 떠 있고 nginx 가 앞단에서 TLS 종단과 라우팅을 담당한다.
- 데이터는 RDS(PostgreSQL) · ElastiCache(Redis) · EFS(페르소나) · S3(이미지/펌웨어/배포 산출물) 로 분리되고 모두 암호화 + 백업이 적용된다.
- 배포 실패 시 5단계 가드(체크섬·atomic swap·테스트 게이트·헬스체크 30초·자동 롤백) 가 다운타임 1초 이내로 직전 버전을 복원한다.
- 로컬에서는 `pwsh scripts/local-up.ps1` 한 번으로 PostgreSQL 16 컨테이너 + SERVER + AI + ADMIN (+APP) 이 한꺼번에 뜬다.

> preflight 의 약관/사업자정보 강제 검사는 docs/README ignore 와 별개로 `docs/legal/`,
> `src/config/legal.{ts,js,tsx}`, `src/legal/`, `app.config.{ts,js}`, `README.md` 만
> 직격 스캔한다. 정본은 `docs/legal/business-info.md` — 운영팀 갱신 절차 포함.

---

## 3. 기능

### 3.1 인프라 (Terraform)
- VPC / Subnet / NAT / SG 전체 설계 (`network.tf`)
- EC2 단일 호스트(현재 운영) + ASG/ALB launch template (확장 토글) (`ec2.tf`, `asg.tf`, `alb.tf`, `launch_template.tf`)
- RDS PostgreSQL 16 Multi-AZ + RDS Proxy (`rds.tf`)
- ElastiCache Redis Multi-AZ (`elasticache.tf`)
- EFS Standard + IA 30일 정책 + 사용자별 Access Point (`efs.tf`, `efs-user-access-points.tf`)
- S3 4 버킷(events / exports / firmware / artifacts) + SSE + BlockPublicAccess + lifecycle (`s3.tf`)
- Route53 hosted zone + 3 A record + deep health check (`route53.tf`)
- IAM EC2 instance role (S3 / Secrets / CW / EFS / RDS connect 최소 권한) (`iam.tf`)
- CloudWatch log group 7종 + dashboard `iconia_slo` 6 widget + Logs Insights (`observability.tf`, `cloudwatch_dashboard.tf`)
- 알람 정의 (5xx / p95 / fallback / Gemini cost hourly·daily / device silent / OTA / BLE / 배터리) (`alarms.tf`)
- AWS Budgets (`budgets.tf`)
- SSM Automation Document — Multi-AZ failover 2종 (`ssm-runbook.tf`)

### 3.2 Lambda 운영 자산
- **RDS password rotator** (`lambda/rds_password_rotator.py`, `rds-password-rotation.tf`)
- **EFS userspace provisioner** (`lambda/efs_userspace_provisioner.py`, `efs-user-access-points.tf`) — 사용자별 SOUL 격리 정합
- **GCP Quotas auto-lift** (`lambda/gcp_quotas_auto_lift.py`, `quotas-auto-lift.tf`) — Gemini API 한도 사전 상향

### 3.3 systemd / nginx 운영 자산
- systemd unit 3종 (`deploy/systemd/iconia-server.service` / `iconia-ai.service` / `iconia-admin.service`) — hardening 풀세트 + `EnvironmentFile=/etc/iconia.env`
- nginx 리버스 프록시 conf + 공통 proxy snippet (`deploy/nginx/`)
- EFS tmp janitor service + timer (daily 03:00 KST)
- 운영 정본 (CloudWatch / Sentry / Push / Canary / DR) (`deploy/aws/`)
- 배포 runbook (`deploy/RUNBOOK.md`, `deploy/aws/multi-az-failover-runbook.md`)

### 3.4 빌드·배포 스크립트 (`scripts/`)
- 로컬 전체 기동/종료 (`local-up.ps1` / `local-up.sh` / `local-down.ps1` / `local-down.sh`) — PG16 + SERVER + AI + ADMIN (+APP)
- AWS 완전 자동 배포 (`aws-deploy.ps1`) — terraform → 빌드 → SSM → 스모크 단일 진입점
- 빌드 + S3 업로드 (`build-and-upload.ps1` / `.sh`) — robocopy/rsync + npm + next build + prisma generate + tar + SHA256
- SSM RunShellScript 트리거 (`trigger-deploy.ps1` / `.sh`)
- EC2 호스트 pull-and-restart (`ec2-pull-and-restart.sh`) — atomic swap + prisma migrate deploy + 헬스체크 30s + 자동 롤백
- Route53 FQDN 외부 스모크 (`post-deploy-smoke.sh`)
- 최초 1회 인프라 부트스트랩 (`bootstrap-aws.ps1`, `seed-db-password.ps1`)
- 6레포 placeholder 검사 게이트 (`preflight-placeholders.{sh,ps1}`) — 도메인/시크릿 14패턴 + (주)숨코리아 약관/사업자정보 4패턴 (`docs/legal/`, `src/config/legal.*`, `src/legal/`, `app.config.*`, `README.md` 강제 스캔)
- SERVER ↔ AI soul catalog lockstep 검증 (`check-soul-catalog-sync.js`)
- HW 로컬 프록시 Caddy (`Caddyfile.hw-proxy`, `start-hw-proxy.ps1`)

### 3.5 GitHub Actions 파이프라인 (`.github/workflows/`)
- `release-preflight` — 6레포 placeholder 검사 + (주)숨코리아 약관/사업자정보 LEGAL guard (미채운 PLACEHOLDER · 약관 placeholder 가 prod 로 새는 사고 차단 — 정본 `docs/legal/business-info.md`)
- `test-gate` — SERVER/AI/ADMIN 단위·lint·typecheck + CI 자체 검증
- `deploy` — 빌드 → S3 업로드 → SSM 무중단 배포 → Route53 외부 스모크 (5단계 게이트)

### 3.6 무중단 보장 5계층
1. **체크섬** — SHA256 사이드카로 부분 업로드 차단
2. **원자 swap** — `mv` 한 번에 신/구 교체, 다운타임 < 1s
3. **테스트 게이트** — `test-gate.yml` 실패 시 배포 잡 진입 자체 차단
4. **헬스체크** — restart 후 30s 내 `is-active` + HTTP `/health` 통과 필수
5. **자동 롤백** — 헬스체크 실패 시 `.old.<ts>` 로 swap-back 후 재기동

---

## 4. 추가 개발 항목

### 4.1 부분 가능 (현재 보유 IaC/Lambda 위에서 확장 가능)

| 항목 | 현재 상태 | 부분 가능 이유 |
|---|---|---|
| ASG N=2+ cutover (단일 EC2 → fleet) | `asg.tf` / `alb.tf` / `launch_template.tf` 정의됨, `asg_desired_capacity=1` | tfvars 토글 + `EVENT_STORE_BACKEND=prisma` cutover → 실제 N=2+ 운영 검증 필요 (`docs/scale-up-runbook.md`, `docs/event-store-cutover.md`) |
| Quotas auto-lift 정책 확장 | `gcp_quotas_auto_lift.py` 가 GCP/Gemini 한도 상향. AWS 측 quota(예: SES 발송, SQS 처리량) 자동 상향은 별도 람다 추가 필요 | 패턴은 동일 (`rds_password_rotator` 와 같은 운영 자산 추가). |
| EFS 사용자별 SOUL 격리 강화 | `efs-user-access-points.tf` + provisioner 람다 — 디렉토리 / Access Point per user | 페르소나 결정화 기억의 백업 정책(AWS Backup) 일일 스냅샷 / 7일 보관 강화는 별도 라운드. |
| Budget 알람 세분화 | `budgets.tf` 월간 USD + Gemini cost hourly/daily 정의. **사용자당 비용 추적 알람**은 미정의 | SERVER 의 `perUserCostService` 가 emit 할 메트릭이 정의되면 그에 맞춰 알람 추가 가능. |
| SLO 보드 widget 추가 | `cloudwatch_dashboard.tf` 의 `iconia_slo` 6 widget. **사용자당 비용 추세 / Cost Anomaly Detection** widget 추가 가능 | 메트릭 emit 라운드와 정합. |
| Sentry / Push / Slack 알람 채널 | `deploy/aws/` 운영 정본에 가이드. 알람 SNS → Slack webhook 연결은 manual | webhook URL 만 secret 으로 주입하면 됨. |
| HW 로컬 프록시 (개발 편의) | `Caddyfile.hw-proxy`, `start-hw-proxy.ps1` 보유 | TLS 자체 서명 인증서 자동 갱신·신뢰 등록은 별도 OS 정책. |
| (주)숨코리아 약관/사업자정보 placeholder guard | `scripts/preflight-placeholders.{sh,ps1}` 의 LEGAL 패턴 4종 (`__TBD__` / `__PLACEHOLDER__` / `XXX-XX-XXXXX` / `Soom Korea Inc. (placeholder)`) + `docs/legal/business-info.md` 정본 + `aws-deploy.ps1` 의 출시 전 placeholder 갱신 단계 | 운영팀 갱신 절차는 `docs/legal/business-info.md` §4 — 실 사업자등록번호 / 통신판매업 신고번호 / DPO 확정 후 release tag. |

### 4.2 당장 불가능 (외부 인프라 / 운영 결정 / 다른 레포 영역)

| 항목 | 이유 |
|---|---|
| Route53 다중 리전 페일오버 promote | 도메인 인수·다중 리전 인프라(서울 외 + 도쿄/버지니아) 확장 결정 필요. 비용 영향 큼. |
| RDS Aurora Global Database | 다중 리전 운영 결정 + 비용 모델 확정 필요. 현재 Aurora Serverless v2 단일 리전. |
| Sentry tracesSampleRate 단계적 ramp-up | Sentry plan 한도·운영 결정 영역. |
| 펌웨어 OTA 트랙 (`1. HW` 빌드 산출물) | 본 레포 범위 밖. `1. HW` 의 ESP-IDF 빌드 시스템과 firmware S3 버킷 lifecycle 정책만 본 레포가 제공. |
| Expo EAS Build / Submit (`4. APP`) | EAS 자체 인프라 + Apple/Google 계정 영역. 본 레포는 환경변수 (LOCAL_LAN_IP, API base URL) 만 전파. |
| 운영 시크릿(Secrets Manager 의 db/JWT/HMAC/KEK 실값) | 운영팀이 직접 입력 — IaC 는 "secret 컨테이너" 만 생성, 실값은 `seed-db-password.ps1` 또는 콘솔. |
| AWS 계정 결제·서비스 한도 직접 상향 | AWS Support Case · 비즈니스 계약 영역. |

---

