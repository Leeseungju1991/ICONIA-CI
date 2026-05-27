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
- AWS 완전 자동 배포 (`aws-deploy.ps1`) — terraform → 빌드 → SSM → 스모크 → (선택)Seed 단일 진입점. switch: `-ApplyInfra` / `-DryRun` / `-Seed` / `-Reseed` / `-NoSeed` / `-EssentialOnly` — 첫 배포 시 `/v1/admin/seed/status` 의 `last_seeded_at == null` 자동 감지로 mock 데이터 1회 자동 시드 (운영 데이터 보호: 무인자 일반 배포는 시드 안 함)
- 빌드 + S3 업로드 (`build-and-upload.ps1` / `.sh`) — robocopy/rsync + npm + next build + prisma generate + tar + SHA256
- SSM RunShellScript 트리거 (`trigger-deploy.ps1` / `.sh`)
- EC2 호스트 pull-and-restart (`ec2-pull-and-restart.sh`) — atomic swap + prisma migrate deploy + 헬스체크 30s + 자동 롤백
- Route53 FQDN 외부 스모크 (`post-deploy-smoke.sh`)
- 최초 1회 인프라 부트스트랩 (`bootstrap-aws.ps1`, `seed-db-password.ps1`)
- 6레포 placeholder 검사 게이트 (`preflight-placeholders.{sh,ps1}`) — 도메인/시크릿 14패턴 + (주)숨코리아 약관/사업자정보 4패턴 (`docs/legal/`, `src/config/legal.*`, `src/legal/`, `app.config.*`, `README.md` 강제 스캔)
- seed-data 검증 (`preflight-seed-data.ps1`) — cross-repo `ICONIA-SERVER/prisma/seed-data/*.json` valid + 필수 카테고리(users / characters / rooms / legal-agreements / notices) 존재 + 비핵심 카테고리 sampling 점검
- SERVER ↔ AI soul catalog lockstep 검증 (`check-soul-catalog-sync.js`)
- HW 로컬 프록시 Caddy (`Caddyfile.hw-proxy`, `start-hw-proxy.ps1`)

### 3.5 GitHub Actions 파이프라인 (`.github/workflows/`)
- `release-preflight` — 6레포 placeholder 검사 + (주)숨코리아 약관/사업자정보 LEGAL guard (미채운 PLACEHOLDER · 약관 placeholder 가 prod 로 새는 사고 차단 — 정본 `docs/legal/business-info.md`)
- `test-gate` — SERVER/AI/ADMIN 단위·lint·typecheck + CI 자체 검증
- `deploy` — 빌드 → S3 업로드 → SSM 무중단 배포 → Route53 외부 스모크 (5단계 게이트)
- `cross-repo-e2e` — Server local-up + Admin smoke + App jest + Server full test + AI test 직렬
- `api-contract-lint` — `ADMIN/docs/api_contract.md` 의 `❌ 미구현` baseline ratchet
- **V1.0 라운드 추가**:
  - `sbom` — syft 로 SPDX + CycloneDX SBOM (push/tag 시 산출물, tag 시 GitHub Release 첨부)
  - `vuln-scan` — trivy fs SARIF + npm audit (push/PR/weekly schedule, GitHub Security 탭)
  - `license-compliance` — license-checker production 의존성 summary (V1.1 차단 게이트 승격)
  - `coverage-gate` — SERVER 80 / AI 75 / ADMIN 70 % lines coverage (V1.0 warning / V1.1 차단)
  - `dr-restore-dryrun` — monthly schedule + manual full-drill (RDS PITR / EFS Backup / S3 lifecycle 점검)
  - `firmware-sign` — KMS-backed cosign sign-blob → S3 `firmware/*.sig` (HW OTA 신뢰 체인)
  - `changelog` — tag v* 시 CHANGELOG.md auto-prepend + GitHub Release notes 생성
  - `actions-sha-pin-audit` — 3rd-party action @SHA pin 누락 감지 (supply-chain 가드)

### 3.6 무중단 보장 5계층
1. **체크섬** — SHA256 사이드카로 부분 업로드 차단
2. **원자 swap** — `mv` 한 번에 신/구 교체, 다운타임 < 1s
3. **테스트 게이트** — `test-gate.yml` 실패 시 배포 잡 진입 자체 차단
4. **헬스체크** — restart 후 30s 내 `is-active` + HTTP `/health` 통과 필수
5. **자동 롤백** — 헬스체크 실패 시 `.old.<ts>` 로 swap-back 후 재기동

### 3.7 V1.0 컨테이너 / 보안 / DR 정책 (보고서 정본)
- **컨테이너 미사용 정책** — ICONIA 는 EC2 + systemd 배포 모델. Dockerfile / K8s manifest 는
  생성하지 않는다. 격리는 systemd hardening 풀세트(`deploy/systemd/*.service` 의 `NoNewPrivileges`,
  `ProtectSystem=strict`, `ReadOnlyPaths` 등) 로 달성. K8s 전환은 ICONIA fleet 1만대 이상 또는
  multi-tenancy 요구 시 V1.x 라운드에서 결정.
- **SBOM / 취약점 / 라이선스** — `.github/workflows/{sbom,vuln-scan,license-compliance}.yml` 로
  공급망 가시성 확보. V1.0 은 정보 수집 / GitHub Security 탭 SARIF — V1.1 라운드에 release
  차단 게이트로 승격.
- **DR** — 단일 region (ap-northeast-2) Multi-AZ. RDS Multi-AZ (RTO < 5분 / RPO < 1분),
  EFS region-scoped Multi-AZ (RTO < 10분), ElastiCache Multi-AZ (RTO < 2분), ASG cross-AZ.
  `dr-restore-dryrun.yml` 이 매월 1회 자동 점검 + 분기 1회 운영팀 full-drill.
  Multi-region active-active 는 V1.x.
- **Synthetics** — `terraform/synthetics.tf` 가 CloudWatch Synthetics canary 3종 (api/ai/admin)
  을 5분 주기로 외부 호출. `SuccessPercent < 90%` 면 SNS 알람.
- **펌웨어 OTA 신뢰 체인** — KMS-backed cosign signing (`firmware-sign.yml`). 부트로더가
  ECDSA-P256 public key 로 검증 — 미서명 펌웨어 거부.
- **OIDC 정적 키 제거** — `deploy.yml` / `dr-restore-dryrun.yml` / `firmware-sign.yml` 모두
  long-lived access key 금지 — OIDC `AssumeRoleWithWebIdentity` 단명 토큰만 사용. 신뢰
  정책은 `deploy/RUNBOOK.md` §9.
- **deploy approval gate** — `build` / `deploy` / `smoke` 는 `environment: production` —
  GitHub Settings 에서 reviewer 승인 + 5분 wait timer + audit log.

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
| AWS 첫 배포 mock 데이터 자동 시드 | `aws-deploy.ps1 -ApplyInfra` 가 `/v1/admin/seed/status` 의 `last_seeded_at` 으로 첫 배포 감지 → SSM Run Command 로 EC2 위 `npm run seed:aws` 1회 실행. `-Seed`/`-Reseed`/`-NoSeed`/`-EssentialOnly` switch + cross-repo `preflight-seed-data.ps1` 가드 + RUNBOOK §2-A 시드 의사결정 매트릭스 | SERVER 의 `prisma/seed.js` + `npm run seed:aws` 진입점 + `/v1/admin/seed/status` endpoint, APP 의 `prisma/seed-data/*.json` mock export 가 cross-repo 의존성 — 본 레포는 트리거/가드만 담당. |

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
| Kubernetes (EKS) | EC2 + ASG + ALB 로 N=2+ 운영 가능. K8s 는 fleet 1만대 이상 / multi-tenancy 시 V1.x. |
| Canary 배포 (트래픽 분배) | atomic swap + 자동 롤백으로 V1.0 충분. ALB weighted TG 도입은 V1.x — `aws-deploy.ps1 -Canary` 인자만 reserve. |
| Pact / OpenAPI 본격 contract test broker | `api-contract-lint.yml` baseline ratchet 으로 V1.0 cover. broker 운영은 V1.x. |
| AWS FIS (chaos automation) | `docs/chaos-test-plan.md` 의 manual 3종 시나리오로 V1.0 cover. 자동화는 V1.x. |
| dual-key firmware trust roll | 단일 KMS 키로 V1.0 — 키 회전은 부트로더 OTA 동반 필요라 V1.x. |

> V1.x K8s 전환 스캐폴드는 `k8s/` 디렉토리. 단계적 적용 절차는 `docs/k8s-migration.md`.
> V1.x Multi-region 스캐폴드는 `terraform/multi-region/`. 적용 절차는 `docs/multi-region.md`.

---

