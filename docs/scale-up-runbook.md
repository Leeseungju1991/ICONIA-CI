# Scale-up Runbook — ASG 시대의 ICONIA 배포·재시작·롤백

Phase 6 부터 Server / AI / Admin 은 단일 EC2 가 아닌 **ASG (desired=2~6)** 위에서
동작한다. 본 문서는 일상 배포 / 무중단 재시작 / 롤백 절차의 ASG 정합 가이드다.

## 1. 일상 배포 — `aws-deploy.ps1` 의 ASG 정합

`scripts/aws-deploy.ps1` 는 그동안 단일 `ICONIA_EC2_INSTANCE_ID` 를 SSM Run
Command 의 instance target 으로 사용했다. Phase 6 에서는 **ASG 이름**으로 target
을 잡고 SSM 이 ASG 내 모든 healthy 인스턴스에 fan-out 한다.

### 1.1 환경 변수

```powershell
# 기존 (단일 EC2)
$env:ICONIA_EC2_INSTANCE_ID = "i-0abcd..."   # 폐기 예정

# Phase 6 (ASG)
$env:ICONIA_ASG_NAME = (terraform -chdir=terraform output -raw asg_name)
```

### 1.2 SSM Run Command — ASG fan-out

`scripts/trigger-deploy.ps1` 가 다음 패턴으로 변경되어야 한다 (별도 Server/CI
라운드에서 작업). 본 문서는 인프라 정합 가이드만.

```powershell
aws ssm send-command `
  --document-name "AWS-RunShellScript" `
  --targets "Key=tag:aws:autoscaling:groupName,Values=$env:ICONIA_ASG_NAME" `
  --parameters "commands=['/usr/local/bin/iconia-pull-and-restart.sh all']" `
  --max-concurrency "50%" `
  --max-errors "1" `
  --region $env:AWS_REGION
```

핵심:
- `--max-concurrency 50%` — ASG 인스턴스의 절반씩 rolling. 나머지 절반은 ALB
  헬스체크 통과 상태로 트래픽 수용 → **무중단 배포**.
- `--max-errors 1` — 1개 실패 시 전체 중단. 자동 롤백 트리거.

### 1.3 ec2-pull-and-restart.sh 정합

기존 스크립트는 동일하게 동작한다 (atomic swap + 헬스체크 + 자동 롤백). 추가
고려:
- restart 직후 ALB target group 헬스체크가 unhealthy 처리되어 자동으로 트래픽
  drain (`deregistration_delay=30`) → 사용자 5xx 차단.
- 헬스 회복 후 ALB 가 다시 트래픽 라우팅.

## 2. Launch Template / AMI 변경 — Instance Refresh

코드 배포는 SSM, **AMI / instance_type 변경은 ASG instance refresh**.

```powershell
# (1) launch_template.tf 의 변경 사항 (예: AMI 갱신) terraform apply
cd "6. CI\terraform"
terraform apply -auto-approve

# (2) instance refresh 트리거 — terraform 의 lifecycle 이 자동 트리거하지만 수동도 가능
aws autoscaling start-instance-refresh `
  --auto-scaling-group-name (terraform output -raw asg_name) `
  --preferences "MinHealthyPercentage=90,InstanceWarmup=180"

# (3) 진행 상황 확인
aws autoscaling describe-instance-refreshes `
  --auto-scaling-group-name (terraform output -raw asg_name) `
  --max-records 1
```

`MinHealthyPercentage=90` — 신규 인스턴스가 healthy 가 된 뒤에야 구 인스턴스
종료. 평시 desired=2 면 신규 1개 추가 → healthy → 구 1개 종료 → 신규 1개 추가
→ healthy → 구 1개 종료 (총 ~10분).

## 3. 롤백

### 3.1 자동 롤백 (배포 실패 시)

`ec2-pull-and-restart.sh` 가 헬스체크 실패 시 `.old.<ts>` 백업으로 swap-back.
ASG 시대에는 다음이 추가된다:
- 한 인스턴스에서 swap-back 이 실패하면 ALB 가 해당 인스턴스를 unhealthy 처리
  → ASG `health_check_type=ELB` 가 인스턴스를 종료 → launch template 으로 신규
  인스턴스 생성 → S3 의 직전 (또는 임의 안정) artifact 로 부팅 (`user-data` 가
  `latest.tar.gz` pull).
- 따라서 **S3 의 `latest.tar.gz` 가 항상 안정 버전이어야 한다**. 실패본을
  업로드한 직후 자동 롤백을 원하면 다음 절차로 S3 의 `latest.tar.gz` 를 직전
  버전으로 되돌린다.

```powershell
$bucket = (terraform -chdir=terraform output -raw artifacts_bucket_name)
aws s3 cp "s3://$bucket/server/<known-good>.tar.gz"        "s3://$bucket/server/latest.tar.gz"
aws s3 cp "s3://$bucket/server/<known-good>.tar.gz.sha256" "s3://$bucket/server/latest.tar.gz.sha256"

# 모든 ASG 인스턴스 재배포
aws ssm send-command `
  --document-name "AWS-RunShellScript" `
  --targets "Key=tag:aws:autoscaling:groupName,Values=$(terraform output -raw asg_name)" `
  --parameters "commands=['/usr/local/bin/iconia-pull-and-restart.sh server']" `
  --max-concurrency "50%"
```

### 3.2 수동 인스턴스 격리

특정 인스턴스만 의심될 때:
```powershell
# (1) ALB target group 에서 detach
aws elbv2 deregister-targets `
  --target-group-arn (terraform output -raw asg_target_group_arn) `
  --targets Id=i-0abcd

# (2) ASG 가 healthy 미만이면 신규 인스턴스 생성 → 트래픽 영향 없음
# (3) 격리된 인스턴스에서 SSM Session Manager 로 진단
aws ssm start-session --target i-0abcd
```

## 4. RDS Proxy 운영 주의

- Server 의 `DATABASE_URL` 은 RDS Proxy endpoint 로 향한다. `prisma migrate
  deploy` 는 **direct connection 권장** (Proxy 가 일부 DDL 에서 pinning).
  → Prisma `directUrl` 에 `aws_db_instance.postgres[0].endpoint` 주입,
  `url` 에 `aws_db_proxy.iconia_pg[0].endpoint` 주입.
- Proxy 의 `idle_client_timeout=1800` (30분) — Server 의 connection pool idle
  timeout 보다 크게 유지.
- TLS 강제 (`require_tls=true`) — 클라이언트는 `?sslmode=require` 필수.

## 5. Redis 운영 주의

- AUTH token 은 `aws_secretsmanager_secret.redis_auth` 에. Server 는
  `iconia/<env>/redis/auth_token` secret 의 JSON 의 `auth_token` 필드를
  사용해 `rediss://:<token>@<endpoint>:6379` 형태로 연결.
- TLS 강제 (`transit_encryption_enabled=true`) — `rediss://` (s 추가).
- 페일오버 발생 시 primary endpoint 가 자동 갱신 (CNAME) — Server 의 redis
  client 가 reconnect on error 로 복구.

## 6. 비용 알람 / 일일 점검

- CloudWatch 대시보드 `iconia-<env>-slo` — 첫 화면 확인.
- ASG 인스턴스 수가 평시 desired (2) 초과로 며칠 유지되면 spec 재평가.
- RDS Proxy `DatabaseConnections` 가 backend max 80% 도달하면 Server connection
  pool size 축소 또는 RDS instance_class 업그레이드 검토.

## 7. 참고

- 인프라 변경 단일 명령: `terraform/README.md` §1
- 펌웨어/디바이스 측 페일오버: `1. HW/` (별도 트랙)
- 사용자 데이터 격리 (페르소나 SOUL): `terraform/efs.tf` + access point
