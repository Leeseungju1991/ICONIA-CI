# ICONIA Terraform IaC

ICONIA AWS 인프라 단일 정본. `terraform apply` 한 번으로 VPC / ASG / ALB /
RDS(+Proxy) / ElastiCache / EFS / S3 / Route53 / IAM / CloudWatch 일괄 생성.

## Phase 6 (양산 직전) 추가 리소스

| 영역 | 신규/변경 | 파일 |
|---|---|---|
| ASG | `aws_autoscaling_group.iconia_server` (min=2, max=6, desired=2, ELB health) | `asg.tf` |
| ALB | `aws_lb.iconia` 외부, `aws_lb_target_group.server` (HTTP:8080 /api/v1/health), `aws_lb_listener` 443+80 redirect | `alb.tf` |
| Launch Template | `aws_launch_template.iconia_server` (private subnet, IMDSv2, gp3) | `launch_template.tf` |
| RDS Proxy | `aws_db_proxy.iconia_pg` (idle 1800s, require_tls, secret auth) | `rds.tf` |
| Redis | `aws_elasticache_replication_group.iconia_redis` (t4g.small × 2, Multi-AZ, TLS, AUTH) | `elasticache.tf` |
| SLO Dashboard | `aws_cloudwatch_dashboard.iconia_slo` | `cloudwatch_dashboard.tf` |
| SLO Alarms | 5xx>1%, p95>3s, ai_fallback>10% | `alarms.tf` |
| Route53 | A record → ALB alias (EIP 직결 폐기) | `route53.tf` |
| EC2 | 단일 인스턴스 정의 제거 | `ec2.tf` |

## 적용 절차

### 1. 단일 명령 적용 (변경 후)

```powershell
cd "C:\Users\user\Music\ICONIA\6. CI\terraform"

# 변경 영향 검토
terraform init -backend-config=backend.hcl
terraform validate
terraform plan -out=tfplan

# 적용 — apply 한 번에 ASG/ALB/Proxy/Redis 일괄 생성
terraform apply tfplan
```

### 2. 마이그레이션 — 단일 인스턴스 → ASG (사용자 직접)

기존 `aws_instance.main` + `aws_eip.main` 가 state 에 남아 있다면 신규 ASG
인스턴스와 별개로 살아 있어 중복 결제된다. 다음을 **본 apply 직전** 수행.

```powershell
cd "C:\Users\user\Music\ICONIA\6. CI\terraform"

# (1) 단일 인스턴스 state 에서만 분리 (실제 인스턴스는 콘솔에서 종료할 때까지 살아 있음)
terraform state rm aws_instance.main
terraform state rm aws_eip.main

# (2) terraform apply — ASG/ALB 신규 생성. Route53 A record 는 ALB alias 로 자동 전환
terraform apply tfplan

# (3) ALB target group 의 healthy host 가 2개 확인되면 (5분 정도 소요)
#     콘솔 또는 CLI 로 구 인스턴스 종료 + EIP release
aws ec2 terminate-instances --instance-ids <old-id>
aws ec2 release-address --allocation-id <old-eip-alloc>
```

**중요**: `terraform state mv aws_instance.main aws_launch_template.iconia_server`
는 리소스 schema 가 달라 절대 사용 금지. 반드시 `state rm` 후 신규 생성.

### 3. 필수 사전 조건

- **ACM 인증서 ARN** (`var.acm_certificate_arn`): ap-northeast-2 리전에서 발급한
  `*.<root_domain>` (또는 ALB FQDN) 인증서. 미주입 시 443 listener 가 생성되지 않고
  ALB 가 HTTP redirect 만 받게 된다.
- **Server 의 `RATE_LIMIT_BACKEND=redis`**: Phase5-A 가 이미 wiring 완료.
  ASG 도입 시점에 in-memory 카운터는 부정합 → Redis 가 필수.
- **Secrets Manager `iconia/<env>/db/master_password`** 존재: `seed-db-password.ps1`
  로 미리 생성. RDS Proxy 가 본 secret 으로 backend DB 로그인.

### 4. .env 갱신 — DATABASE_URL → RDS Proxy

```powershell
# terraform output 으로 신규 endpoint 확인
terraform output -raw rds_proxy_endpoint
terraform output -raw redis_primary_endpoint
terraform output -raw alb_dns_name
terraform output -raw asg_name
```

Server 의 `.env.aws` (또는 EC2 user-data 의 inject_database_url) 가 본 값을 사용
하도록 `aws-deploy.ps1` 의 `ICONIA_DATABASE_URL_HOST` 를 RDS Proxy endpoint 로
교체. `database_url_template` output 이 그대로 사용할 수 있는 템플릿을 제공.

## SLO 임계 (양산 기준)

| SLO | 임계 | 알람 |
|---|---|---|
| API 5xx 비율 | < 1% (5분) | `iconia-server-slo-5xx-rate-1pct` |
| API p95 latency | < 3000ms (10분) | `iconia-server-slo-latency-p95-3s` |
| AI fallback 비율 | < 10% (5분) | `iconia-server-slo-ai-fallback-rate-10pct` |

대시보드: CloudWatch > Dashboards > `iconia-<env>-slo`

## 운영 변경 시 참고

- Launch Template 변경 → ASG `instance_refresh` 가 rolling 으로 신규 인스턴스 교체.
  - 배포는 launch template 갱신이 아닌 S3 artifact + SSM Run Command 사용
    (`scripts/aws-deploy.ps1`). instance refresh 는 AMI / instance_type 변경 시만.
- 배포 절차는 `docs/scale-up-runbook.md` 참조.
- 비상 페일오버 / 롤백: `deploy/aws/multi-az-failover-runbook.md`,
  `deploy/RUNBOOK.md`.
