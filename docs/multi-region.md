# ICONIA V1.x Multi-region 운영 가이드

> 본 문서는 **V1.x Multi-region 스캐폴드** (`terraform/multi-region/`) 의 적용 절차,
> RTO/RPO 목표, failover/DR test 절차, 비용 추정을 다룬다.
> **V1.0 은 ap-northeast-2 (서울) 단일 region Multi-AZ** — 본 스캐폴드는 *향후* 확장을 위한 골격이다.

---

## 1. 개요

| 항목 | 값 |
|---|---|
| Primary region | `ap-northeast-2` (서울) |
| Secondary region | `ap-northeast-1` (도쿄) |
| 적용 조건 | 운영팀 의사결정 — 비용/규정 검토 후 `enable_multi_region=true` 토글 |
| 기본 상태 | **disabled** (apply 해도 secondary region 리소스 0개) |
| Terraform 스택 위치 | `terraform/multi-region/` |
| 별도 state | `s3://iconia-tfstate-<acct>/iconia/multi-region/terraform.tfstate` |

본 스캐폴드는 다음 5개 영역의 골격을 제공한다:

| 영역 | Terraform 파일 | 활성화 토글 |
|---|---|---|
| RDS cross-region read replica + 전용 KMS 키 + replica lag alarm | `rds-replica.tf` | `rds_replica_enabled` |
| S3 Cross-Region Replication (artifacts / events) + replication IAM role | `s3-crr.tf` | `s3_crr_enabled` |
| Route53 health check + PRIMARY/SECONDARY failover record + alarm | `route53-failover.tf` | `route53_failover_enabled` |
| Secrets Manager replica region 권한/감사 로그 | `secrets-replication.tf` | `secrets_replication_enabled` |
| KMS multi-region key + replica | `kms-multi-region.tf` | `kms_multi_region_enabled` |

모든 리소스에 공통 태그 적용 — `Project=ICONIA`, `Environment=<env>`, `MultiRegion=true`, `ManagedBy=terraform`, `Owner=soomkorea`, `Module=multi-region`.

---

## 2. 적용 절차

### 2.1 사전 준비

운영팀 의사결정 항목:

1. **비용 승인** — §6 비용 추정 검토 (월 +$400~$700 예상).
2. **Secondary region 인프라** — 도쿄 region 의 VPC/Subnet/SG/ALB/EC2 stack 별도 준비 필요.
   본 스캐폴드는 **네트워크/컴퓨트는 생성하지 않음** — 데이터 복제 + DNS failover 골격만.
3. **Primary 자산 식별자 수집** — RDS instance ARN, S3 bucket 이름, ALB DNS/zone, Route53 hosted zone ID.

### 2.2 Init

```bash
terraform -chdir=terraform/multi-region init \
  -backend-config="bucket=iconia-tfstate-<acct>" \
  -backend-config="key=iconia/multi-region/terraform.tfstate" \
  -backend-config="region=ap-northeast-2" \
  -backend-config="dynamodb_table=iconia-tfstate-lock"
```

> 본 stack 은 primary stack(`terraform/`) 과 **별도 state** 를 사용한다. state 키는
> `iconia/multi-region/terraform.tfstate` — primary 의 `iconia/terraform.tfstate` 와 분리.

### 2.3 단계적 활성화 (권장)

#### Phase 1: KMS multi-region key 만

```bash
terraform -chdir=terraform/multi-region apply \
  -var enable_multi_region=true \
  -var kms_multi_region_enabled=true
```

- 가장 안전 — KMS 키 생성만, 운영 영향 0.
- secondary region 의 KMS replica key 가 동일 KeyId 로 가용해짐.

#### Phase 2: S3 CRR destination 버킷 + replication role

```bash
terraform -chdir=terraform/multi-region apply \
  -var enable_multi_region=true \
  -var kms_multi_region_enabled=true \
  -var s3_crr_enabled=true \
  -var primary_s3_artifacts_bucket=iconia-prod-artifacts-<acct> \
  -var primary_s3_events_bucket=iconia-prod-events-<acct>
```

- secondary region 에 destination 버킷 생성 + primary 의 source 버킷에 replication 설정 추가 필요.
- source 측 `replication_configuration` 은 primary stack 의 `terraform/s3.tf` 에서 본 모듈의 outputs 를 참조하여 별도 라운드에 추가.

#### Phase 3: RDS cross-region read replica

```bash
terraform -chdir=terraform/multi-region apply \
  -var enable_multi_region=true \
  -var kms_multi_region_enabled=true \
  -var s3_crr_enabled=true \
  -var rds_replica_enabled=true \
  -var primary_db_instance_arn=arn:aws:rds:ap-northeast-2:<acct>:db:iconia-prod-db
```

- RDS read replica 가 도쿄에 생성됨 (생성 시간 약 20~30분, 첫 동기화 추가).
- replica lag CloudWatch alarm 자동 생성 — 300초 (5분) 임계.

#### Phase 4: Route53 failover

```bash
terraform -chdir=terraform/multi-region apply \
  -var enable_multi_region=true \
  -var kms_multi_region_enabled=true \
  -var s3_crr_enabled=true \
  -var rds_replica_enabled=true \
  -var route53_failover_enabled=true \
  -var hosted_zone_id=Z<...> \
  -var domain_name=iconia.example \
  -var primary_alb_dns=<primary-alb-dns> \
  -var primary_alb_zone_id=<primary-alb-zone> \
  -var secondary_alb_dns=<secondary-alb-dns> \
  -var secondary_alb_zone_id=<secondary-alb-zone>
```

> `secondary_alb_dns` 가 비어있으면 SECONDARY record 는 생성되지 않는다 — secondary
> 컴퓨트 stack 이 준비된 후 채워서 다시 apply.

### 2.4 비활성화 (롤백)

```bash
terraform -chdir=terraform/multi-region apply -var enable_multi_region=false
```

→ 모든 secondary 리소스 destroy. RDS replica 는 final snapshot 옵션 따라 보존.

---

## 3. RTO / RPO 목표

| 지표 | 목표 | 산정 근거 |
|---|---|---|
| **RTO** (서비스 가용성 복구) | **< 1 시간** | Route53 DNS failover 2~3분 + RDS promote 5~10분 + 컴퓨트 cutover 10~20분 + 검증 |
| **RPO** (데이터 손실 허용) | **< 5 분** | RDS async physical replication lag (일반 < 1s, 알람 임계 300s) |

세분 RTO/RPO:

| 컴포넌트 | RTO | RPO | 비고 |
|---|---|---|---|
| Route53 DNS 전환 | 2~3분 | — | health check 90s + TTL 60s |
| RDS read replica → primary promote | 5~10분 | < 5분 | `aws rds promote-read-replica` (수동 또는 SSM Automation) |
| S3 객체 (artifacts / events) | 즉시 사용 가능 | < 15분 | CRR SLA 99.99% 객체 15분 내, 대부분 < 1분 |
| Secrets Manager | 즉시 | ~0 | 동기 복제 |
| KMS multi-region key | 즉시 | ~0 | KeyId 동일, 양쪽 가용 |
| EFS persona | **별도 백업 복원** | < 24h | AWS Backup cross-region copy (별도 라운드) |
| ElastiCache Redis | **재기동 후 빈 캐시** | N/A | 캐시 — 영속성 데이터 아님 |

> RTO 1시간 = SLA. 실제 운영 목표는 **< 30분**. 분기 1회 DR drill 로 검증.

---

## 4. Failover 절차

### 4.1 자동 (DNS failover)

Primary ALB 의 `/health?deep=1` 가 3회 연속(약 90초) 실패하면 Route53 health check 가 unhealthy → SECONDARY record 자동 응답.

```
[운영팀 알림] CloudWatch Alarm: iconia-prod-primary-region-unhealthy
       ↓
[Route53 자동] SECONDARY record 응답 (api.iconia.example → 도쿄 ALB)
       ↓
[클라이언트] DNS TTL 60s 만료 후 도쿄로 트래픽 전환
```

이 단계에서 **DB 는 여전히 primary 가 down 상태** — secondary 의 RDS 는 read-only replica.

### 4.2 수동 (DB promote + 본격 전환)

primary region 이 일시 장애가 아닌 *지속 장애*로 판단되면 운영팀이 다음 절차 수행:

```bash
# 1) RDS replica promote (수동 실행 — 의도된 안전장치)
aws rds promote-read-replica \
  --db-instance-identifier iconia-prod-db-replica \
  --region ap-northeast-1

# 2) secondary EC2 의 /etc/iconia.env 의 DB endpoint 갱신 (Secrets Manager replicated secret 의 endpoint 필드)
aws secretsmanager update-secret \
  --secret-id iconia/prod/db/master_password \
  --secret-string '{...,"host":"iconia-prod-db-replica.<...>.ap-northeast-1.rds.amazonaws.com"}' \
  --region ap-northeast-1

# 3) secondary EC2 서비스 재기동 (SSM Run Command)
aws ssm send-command \
  --document-name AWS-RunShellScript \
  --targets Key=tag:service,Values=iconia \
  --parameters 'commands=["systemctl restart iconia-server iconia-ai iconia-admin"]' \
  --region ap-northeast-1

# 4) 외부 스모크
curl -fsS https://api.iconia.example/health?deep=1
```

### 4.3 Failback (primary 복구 후)

> 운영팀 의사결정 필수. 다음 조건 충족 시에만 failback:
> 1) Primary region 인프라 완전 복구 확인.
> 2) Primary RDS 재구성 (이전 primary 는 promote 된 secondary 의 replica 가 됨 — 역방향 복제 설정).
> 3) 무중단 cutover 윈도우 확보 (사용자 영향 최소화 새벽 시간대).
> 4) RPO 손실 0 확인 (양쪽 동기 완료).

세부 절차는 분기별 DR drill 로 운영팀이 별도 runbook 정리 (V1.x).

---

## 5. DR Test 절차 (분기 1회 권장)

### 5.1 Scope

분기마다 다음 중 1개를 선택해 실행:

| 분기 | 시나리오 | 검증 항목 |
|---|---|---|
| Q1 | **DNS failover only** | Route53 health check + record 동작, RTO 측정 |
| Q2 | **RDS replica promote test** (staging) | promote 시간, application connection 갱신 |
| Q3 | **S3 CRR consistency** | 객체 100개 무작위 샘플 — primary/secondary 동일성 |
| Q4 | **Full DR drill** | 전 영역 — RTO/RPO 실측 vs 목표 비교 |

### 5.2 운영 절차

```bash
# 1) DR drill 시작 — Slack #ops 공지 + 알람 일시 mute
# 2) 시나리오별 스크립트 실행 (예: Q1 DNS failover test)
#    - primary ALB 의 health endpoint 일시 차단 (NACL 또는 security group)
#    - Route53 health check unhealthy 확인 (CloudWatch metric)
#    - 외부 curl 로 secondary 응답 확인
#    - RTO 측정 (장애 시작 → secondary 응답)
# 3) 결과 기록 → docs/multi-region.md §6 부록 표 갱신
# 4) 정상 복구 — primary 차단 해제, health check 정상화 대기
# 5) Slack 종료 공지
```

DR drill 결과는 분기 운영 리뷰에 안건 포함.

---

## 6. 비용 추정 (월 단위, USD)

> 추정치 — 실제 트래픽/스토리지/리전 가격에 따라 변동.
> 환율/AWS 가격 변동은 별도 라운드에 갱신.

| 영역 | 항목 | 월 추정 비용 |
|---|---|---|
| **RDS replica** | db.t4g.medium (도쿄) | $80 |
| | 100GB gp3 storage | $12 |
| | Cross-region data transfer (replication, 평균 100GB/월 가정) | $9 |
| | 백업 (7일 × 100GB) | $7 |
| **S3 CRR** | artifacts replica storage (50GB) | $1 |
| | events replica storage (100GB, IA 30d 분기) | $2 |
| | replication transfer (월 150GB) | $14 |
| | replication PUT 요청 (월 100k) | $0.5 |
| **Route53** | health check (HTTPS × 2, latency on) | $1 |
| | failover record 추가 query | $0.4 |
| **Secrets Manager** | replicated secret (4개 가정) | $1.6 |
| | API call (월 10k) | $0.05 |
| **KMS** | multi-region key (primary + replica) | $2 |
| | RDS replica 전용 키 | $1 |
| | API call (월 50k) | $0.15 |
| **Cross-region 추가 데이터 전송** | 컴퓨트 → DB / S3 등 (예비 50GB) | $4.5 |
| **합계 (최소)** | RDS + S3 CRR + Route53 만 활성화 | **약 $130/월** |
| **합계 (전체)** | 위 모든 항목 + secondary EC2/ALB/EFS *별도* 비용 | **약 $400~$700/월** |

> **secondary region 의 EC2/ALB/EFS/ElastiCache 는 본 스캐폴드 범위 밖** — 별도
> stack 으로 준비 시 추가 비용 발생 (서비스 hot standby 라면 primary 와 비슷한 수준).
>
> Pilot light 전략 (secondary 는 RDS replica + DNS만, 컴퓨트는 평시 off → 장애 시 ASG 기동) 으로 운영 시 $100~$200/월 수준으로 압축 가능.

---

## 7. 미구현 / V1.x 후속 라운드

본 스캐폴드 범위 밖 — 별도 의사결정 / 라운드 필요:

| 항목 | 사유 |
|---|---|
| Secondary region VPC/Subnet/SG/ALB/EC2 stack | 컴퓨트 비용 영향 큼 — pilot light vs hot standby 운영 정책 결정 필요 |
| EFS cross-region backup (AWS Backup) | AWS Backup 추가 stack 필요 — 일일 RPO 별도 |
| RDS automated failback (primary 복구 후 역방향 복제) | 운영 정책 + 검증 필요 — drill 거친 후 자동화 |
| Aurora Global Database 전환 | Aurora 전제 — 현재 RDS instance 모드, 마이그레이션 비용 별개 |
| Active-active multi-region (양쪽 동시 서비스) | conflict resolution / event ordering 설계 필요 — V2.0 |
| Secondary region 의 CloudWatch Synthetics canary | 모니터링 redundancy — 활성화 후 추가 |
| Secondary region 의 SSM Runbook (multi-AZ failover 대응) | primary `ssm-runbook.tf` 미러링 — 활성화 후 추가 |
