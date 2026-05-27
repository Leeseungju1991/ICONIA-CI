# ICONIA Multi-AZ failover runbook

| 항목 | 값 |
|---|---|
| 상태 | **Accepted (정본)** |
| 날짜 | 2026-05-07 |
| 적용 범위 | AWS 운영 region (ap-northeast-2 Seoul, AZ-a/b/c) |
| 관련 문서 | `Server/docs/rto-rpo.md`, `Server/docs/deploy-aws.md`, `Server/docs/data-retention.md` |

본 runbook 은 **production AWS 환경에서 단일 AZ 장애가 발생했을 때 SRE 가 따라야 하는 단계별
절차**를 정의한다. RTO/RPO 정본 (`docs/rto-rpo.md` §1) 을 달성하기 위한 실제 명령과 의사결정 기준
이 본 문서의 책임이다.

---

## 0. 사고 인지 / 1차 분류 (T+0 ~ T+2분)

다음 중 하나가 발생하면 본 runbook 진입:

- CloudWatch Alarm `RDS-Primary-Unreachable` 발사
- ALB target group 의 healthy host 수가 50% 미만으로 5분 유지
- API 5xx 비율 1% 초과 5분 유지
- Route53 health check fail
- Sentry 에 `db_connection_lost` / `efs_mount_failed` 다수 발생

### 1차 의사결정

| 증상 | 추정 원인 | 진입 단계 |
|---|---|---|
| RDS write 실패 + read replica OK | RDS primary AZ 장애 | §1 RDS failover |
| API 5xx + EFS mount error | EFS AZ 장애 | §2 EFS failover |
| Redis 연결 거부 다수 | ElastiCache primary 장애 | §3 ElastiCache failover |
| API 자체 응답 0 | EC2 / ALB 문제 | §4 EC2/ALB failover |
| 모든 컴포넌트 갑자기 정상화 | 일시 장애 자체 복구 | 모니터링 유지 + post-mortem |

---

## 1. RDS Multi-AZ failover

**달성 목표**: RTO < 5분, RPO < 1분.

### 1.1 자동 failover 대기 (T+0 ~ T+2분)

RDS Multi-AZ 는 standby 로 자동 promote 한다. 평균 60-120초.

```bash
# 진행 상황 모니터링.
aws rds describe-db-instances \
  --db-instance-identifier iconia-prod \
  --query 'DBInstances[0].DBInstanceStatus'
# 출력: "failing-over" 또는 "available".
```

`available` 로 돌아오면 application 측 connection pool 이 자동으로 새 endpoint 에 연결.
이 단계에서 5xx 가 0 으로 회복되면 §1.4 검증으로 이동.

### 1.2 자동 failover 미동작 시 manual (T+2분 이후)

자동 promote 가 안 되면 manual reboot-with-failover:

```bash
aws rds reboot-db-instance \
  --db-instance-identifier iconia-prod \
  --force-failover
```

force-failover 는 standby 로 즉시 강제 전환. 약 60초 소요.

### 1.3 connection pool 재초기화 (필요 시)

prisma client 의 connection pool 이 stale endpoint 를 잡고 있을 가능성:

```bash
# AWS EC2 (ASG)
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name iconia-server-asg \
  --preferences MinHealthyPercentage=50
```

### 1.4 검증

1. `/health?deep=1` → 200 OK + `db_enabled: true` + `probes.db.healthy: true`.
2. `/api/v1/auth/login` 1건 성공 (e2e smoke).
3. CloudWatch RDS → `DatabaseConnections` 지표 정상 회복.

### 1.5 post-mortem

- failover 시점 / 자동 vs manual / 총 RTO 기록.
- standby AZ 가 새 primary — 다음 game day 에 다른 AZ 로 회전 검토.

---

## 2. EFS Multi-AZ failover

**달성 목표**: RTO < 10분, RPO < 24시간.

EFS Standard 는 자체 Multi-AZ 라 단일 AZ 장애 시 자동 복구. EC2 mount target 만 다른 AZ 로
재연결되면 정상 동작.

### 2.1 mount target 재확인

```bash
aws efs describe-mount-targets \
  --file-system-id fs-xxxxx \
  --query 'MountTargets[].{AZ:AvailabilityZoneName,LifeCycle:LifeCycleState,IP:IpAddress}'
```

영향 받은 AZ 의 mount target 이 `available` 상태로 보존돼야 한다. 그렇지 않으면 §2.2.

### 2.2 EC2 측 EFS 재마운트

```bash
# EC2 SSM 으로 affected instance 에 진입
sudo umount -f /mnt/efs/iconia
sudo mount -t efs -o tls fs-xxxxx:/ /mnt/efs/iconia
ls /mnt/efs/iconia # 디렉토리 정상 노출 확인
```

### 2.3 application 영향 점검

- chatRoutes/voice — message persist 는 Postgres 라 영향 없음.
- ICONIA-AI 의 persona_state.json — EFS 의존. mount 복구 후 자동 회복.
- 이미지 캐시 — 7일 TTL 라 일시 빈 캐시 OK (S3 가 source-of-truth).

### 2.4 EFS 대규모 손상 시

EFS 자체 데이터 손실 의심 시 AWS Backup 에서 복구:

```bash
aws backup start-restore-job \
  --recovery-point-arn arn:aws:backup:.../recovery-point/efs-2026-05-07 \
  --metadata file-system-id=fs-NEW \
  --iam-role-arn arn:aws:iam::ACC:role/AWSBackupDefaultRole
# 복구 완료까지 30분-수시간. 별도 file system 으로 복원되므로 production 전환은 §2.5.
```

### 2.5 application 환경변수 swap

```bash
# EC2 user-data / launch template 에서 EFS mount 가 새 fs-id 를 가리키도록.
# 이후 §1.3 의 application restart.
```

---

## 3. ElastiCache (Redis) Multi-AZ failover

**달성 목표**: RTO < 2분, RPO N/A (캐시).

### 3.1 자동 failover 대기

ElastiCache 는 Multi-AZ 활성 시 약 30-60초 안에 replica 가 primary 로 promote.
`REDIS_URL` 이 reader endpoint 가 아니라 primary endpoint 를 가리켜야 함 (정본).

### 3.2 fallback 동작 확인

본 코드 베이스는 redisAdapter 가 ping 실패 시 자동으로 in-memory 로 fallback (단일 인스턴스
한정). 즉 Redis 가 죽어도 API 자체는 응답. 단:
- rate limit 이 인스턴스 별도로 동작 → brute-force 대응 약화 (5분 ~ 10분 한정 임시).
- idempotency 가 인스턴스 별도 → 같은 idempotency key 가 두 인스턴스에 동시 도달 시 dedup 실패 가능성.

이 fallback 은 임시. Redis 복구되면 자동 재연결되어야 한다.

### 3.3 Redis 복구 후 application

connection pool 자동 재연결. 명시적 재시작 불요. 검증:
- `/health` 응답 — 별도 redis health 표시는 없으나, login lockout / idempotency 회귀 테스트로 검증.

---

## 4. EC2 / ALB AZ failover

**달성 목표**: RTO < 5분, RPO 0.

### 4.1 ASG 가 자동으로 다른 AZ 에 instance 추가

ASG 가 Min/Desired 가 채워질 때까지 다른 AZ 에 EC2 추가. ALB health check 통과 후 트래픽 회복.

### 4.2 자동 healing 미동작 시 manual

```bash
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name iconia-server-asg \
  --desired-capacity 4
# 또는 specific AZ 만 capacity 늘리기
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names iconia-server-asg
```

---

## 5. S3 region 장애

**달성 목표**: RTO < 5분 (S3 자체 SLA), RPO 0 (CRR 활성 시).

### 5.1 S3 자체 SLA (99.99%) — 자체 복구 대기

대부분의 S3 incident 는 60분 이내 자체 복구. application 은 retry + dead-letter 큐로 회수.

### 5.2 1시간 이상 지속 시 fallback

본 코드 베이스의 storageAdapter 는 S3 fail 시 EFS 로 fallback 하는 모드 미구현. 운영 정책:
- 사고 알림 → 운영자가 storage 우회 결정.
- 이미지 업로드 일시 중단 (HW deviceRoutes 가 503 응답).
- 사용자에게 in-character fallback ("나중에 다시 보여줄게") 표시.

### 5.3 cross-region replication 사용 시 (옵션)

CRR 을 활성한 경우 secondary region 의 bucket 으로 swap:

```bash
# .env.prod 에서 EVENT_IMAGE_BUCKET 변경 + application restart.
# CRR 이 동기 복제는 아니므로 RPO 약 15분.
```

---

## 6. 사고 후 post-mortem 템플릿

```markdown
# Incident YYYY-MM-DD: <one-line summary>

## Timeline (KST)
- T+0   : 사고 인지
- T+2   : 1차 분류 (영향 컴포넌트)
- T+N   : 1차 대응 시작
- T+N'  : 회복 확인
- T+M   : 모니터링 종료

## Affected
- 영향 사용자 수
- 데이터 손실 (실제 RPO)
- API 5xx / latency 그래프 첨부

## Root cause
<5-why 분석>

## RTO/RPO 측정
- 실제 RTO: NN분 (목표 < N분)
- 실제 RPO: NN초 (목표 < N분)

## Action items
- [ ] alarm 추가 (CloudWatch / Sentry)
- [ ] runbook 단계 갱신
- [ ] 자동화 (SSM document) 도입
- [ ] game day 시나리오 추가
```

## 7. SSM Document 자동화 (M+1 라운드)

위 §1 ~ §4 의 명령들을 AWS Systems Manager Document 로 packaging 해 1-click runbook 으로 만든다.
본 라운드는 manual 절차 정합. 자동화는 별도 라운드.

## 8. 전체 AZ 장애 (Single-AZ blackout)

**달성 목표**: RTO < 15분, RPO < 1분.

ap-northeast-2 의 단일 AZ (예: 2a) 가 완전히 다운된 경우. RDS / EFS / EC2 / ALB 가
동시에 영향받는 복합 시나리오.

### 8.1 즉시 진단

```bash
# 영향 AZ 식별 — health check 결과 비교.
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=iconia-prod-host" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{ID:InstanceId,AZ:Placement.AvailabilityZone,State:State.Name}'
# 영향 AZ 의 instance 가 모두 unreachable / impaired 상태.
```

### 8.2 ASG 가 healthy AZ 로 capacity 재분배

ASG 는 multi-AZ 로 설정되어 있어 (`terraform/asg.tf`) 정상 AZ 들에 자동으로 desired
capacity 를 채운다. 단, max_size 에 도달하면 추가 인스턴스 띄울 수 없으므로:

```bash
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name iconia-server-asg \
  --max-size 8 \
  --desired-capacity 4
```

### 8.3 RDS Multi-AZ — primary AZ 가 장애 AZ 면 §1 자동 failover

`backup_retention_period=30` (`terraform/rds.tf:68`) + Multi-AZ standby → §1 자동 failover.

### 8.4 EFS — mount target 이 정상 AZ 에 존재

EFS 는 region-scoped 라 단일 AZ blackout 에도 file system 자체는 살아있다.
정상 AZ 의 EC2 가 EFS mount target 으로 라우팅 — §2.2 의 재마운트 절차.

### 8.5 검증

- ALB `HealthyHostCount` 가 desired_capacity 회복
- `/health?deep=1` 응답 200 + 모든 probe healthy
- p95 latency < 평소 × 2

---

## 9. KMS / Secrets 키 분실 / 손상

**달성 목표**: RTO < 1시간 (재발급), RPO 0 (Secrets Manager 자체 versioning).

### 9.1 인지

- Server `getSecret()` 실패 → `KMS access denied` 또는 `secret not found`
- 알람 `iconia-server-secret-fetch-failed` (V1.x 추가 예정)

### 9.2 KMS CMK 손상 / 비활성화

```bash
# CMK 상태 확인.
aws kms describe-key --key-id alias/iconia-prod-data \
  --query 'KeyMetadata.{State:KeyState,Enabled:Enabled}'
# 'PendingDeletion' / 'Disabled' 면 즉시:
aws kms cancel-key-deletion --key-id alias/iconia-prod-data
aws kms enable-key --key-id alias/iconia-prod-data
```

### 9.3 Secrets Manager — 키 ARN 변경

Secrets Manager 의 secret 이 다른 KMS 로 재암호화되어야 한다면:

```bash
# 1) 새 CMK 생성 (콘솔 또는 terraform).
# 2) 영향받는 secret 의 KMS 키 교체.
aws secretsmanager update-secret \
  --secret-id iconia/prod/db/master_password \
  --kms-key-id alias/iconia-prod-data-v2
# 3) Server 재시작 — Secrets Manager 의 keyId 캐시 갱신.
aws ssm send-command \
  --document-name AWS-RunShellScript \
  --targets "Key=tag:aws:autoscaling:groupName,Values=iconia-server-asg" \
  --parameters 'commands=["sudo systemctl restart iconia-server iconia-ai iconia-admin"]'
```

### 9.4 Secrets 자체 분실 (예: 운영자 실수로 delete)

```bash
# Secrets Manager 는 default 30일 recovery window — 그 안에 복구 가능.
aws secretsmanager restore-secret --secret-id iconia/prod/db/master_password
# 30일 초과 후 분실이면 신규 secret 생성 + RDS master_user_password 재설정
# (rds_password_rotator.py 의 manual rotation 트리거).
```

### 9.5 펌웨어 서명 키 분실 (cosign / KMS)

- KMS ECDSA-P256 키가 분실되면 새 키 생성 → 펌웨어 빌드 + 서명 → OTA 배포.
- **단**, 기존 출시된 펌웨어의 trusted cert 는 ESP32 부트로더에 임베드된 옛 public key 라
  새 키로 서명한 firmware 는 거부된다 → 키 회전은 **부트로더 OTA 동반 필요**.
- V1.x 라운드에 dual-key trust roll (옛 + 새 둘 다 신뢰) 후 옛 키 폐기 절차 도입.

---

## 10. 전 region 장애 (ap-northeast-2 full outage)

**달성 목표**: V1.0 라운드는 **수동 통지 + 사후 복구** — 자동 cross-region failover 미적용.

V1.0 정책: 단일 region (ap-northeast-2) 만 운영. Multi-region active-active 또는
warm standby 는 V1.x 라운드 (Aurora Global DB / Route53 health-check failover /
S3 CRR / EFS replication 도입 결정 + 비용 모델 확정 후).

### 10.1 사고 통지

- 운영팀 슬랙 #iconia-incident 채널 즉시 통지
- 사용자 공지: dollsoom.com 상태 페이지 + APP push notification ("점검 중")

### 10.2 S3 CRR 백업 — 사후 복구 시 사용

`terraform/s3.tf` 에 CRR 정의돼 있으면 secondary region 의 bucket 에 events / firmware
사본이 보존됨. region 복구 후 또는 신 region 배포 시 source 로 활용.

### 10.3 DR 시점 의사결정

- region 장애 < 2시간: 자체 복구 대기 (S3 SLA 99.99% — 대부분 빠르게 회복)
- 2시간 이상: 슬랙에서 운영팀 의사결정 — 신 region (us-east-1 또는 ap-northeast-1)
  에서 terraform apply 수행 (별도 가이드 — V1.x 라운드 정본화 예정)

---

## 11. 변경 이력

| 날짜 | 변경 | 작성자 |
|---|---|---|
| 2026-05-07 | 초기 정본 (P1 #5) | sre-team |
| 2026-05-27 | §8 AZ blackout / §9 KMS·Secrets 분실 / §10 전 region 장애 추가 (V1.0) | (주)숨코리아 운영팀 |
