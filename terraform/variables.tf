###############################################################################
# variables.tf — ICONIA AWS infra 공통 변수.
#
# 구성: Route53 + EC2 + S3 + EFS 4종 (RDS 제외 결정 — 2026-05-18).
# 운영자가 terraform apply 시 -var 또는 *.tfvars 로 주입.
###############################################################################

variable "env" {
  description = "배포 환경 식별자. dev / staging / prod 중 하나. AWS 리소스 이름 관례용 (prod/dev/staging). ICONIA_ENV 환경변수로 주입 시 user-data.sh.tftpl 이 production/development/staging 으로 변환 (lib/env.ts 요구사항)."
  type        = string
  default     = "prod"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "env must be one of: dev, staging, prod."
  }
}

variable "region" {
  description = "주 AWS region. 단일 region (ap-northeast-2) 가정."
  type        = string
  default     = "ap-northeast-2"
}

# -----------------------------------------------------------------------------
# 네트워크 — 기본 모드는 신규 VPC 생성 (network.tf). 기존 VPC 재사용시 vpc_id 주입.
# -----------------------------------------------------------------------------
variable "create_network" {
  description = "true 면 network.tf 가 VPC/Subnet/IGW/NAT/RouteTable 생성. false 면 기존 vpc_id 사용."
  type        = bool
  default     = true
}

variable "vpc_id" {
  description = "create_network=false 일 때 사용할 기존 VPC ID."
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "create_network=true 시 신규 VPC CIDR."
  type        = string
  default     = "10.42.0.0/16"
}

variable "azs" {
  description = "사용할 가용영역 목록. ap-northeast-2 기준 a/c 권장."
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDR. azs 와 길이 일치."
  type        = list(string)
  default     = ["10.42.1.0/24", "10.42.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDR (EC2/EFS). azs 와 길이 일치."
  type        = list(string)
  default     = ["10.42.11.0/24", "10.42.12.0/24"]
}

variable "private_subnet_ids" {
  description = "create_network=false 시 사용할 기존 private subnet ID 목록 (Multi-AZ >=2)."
  type        = list(string)
  default     = []
}

variable "public_subnet_ids" {
  description = "create_network=false 시 사용할 기존 public subnet ID 목록."
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# EC2 / ASG — Phase 6 부터는 launch template + ASG + ALB. nginx 는 제거되고
# ALB 가 TLS 종단·라우팅을 담당한다 (admin/ai/api 모두 단일 ALB hostname 라우팅).
# -----------------------------------------------------------------------------
variable "ec2_instance_type" {
  description = "ASG launch template 의 인스턴스 타입. Phase 6: t3.medium 권장 (×2 minimum)."
  type        = string
  default     = "t3.medium"
}

variable "asg_min_size" {
  description = "ASG 최소 인스턴스 수. 가용성 위해 2 (Multi-AZ) 권장."
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "ASG 최대 인스턴스 수. 양산 트래픽 대비."
  type        = number
  default     = 6
}

variable "asg_desired_capacity" {
  description = "ASG 평시 desired. min 과 동일 권장 (target tracking 이 위로 끌어올림)."
  type        = number
  default     = 2
}

variable "asg_target_cpu_percent" {
  description = "Target tracking CPU utilization 임계 (%)."
  type        = number
  default     = 50
}

variable "asg_scale_in_cooldown_seconds" {
  description = "Scale-in 보호 cooldown (초). 스케일-인 직후 5분간은 추가 감축 금지 (warm 인스턴스 stale 방지)."
  type        = number
  default     = 300
}

# 사용자 요청 8종 정합 — ASG health_check_type 토글.
# default "EC2": 첫 프로비저닝 (SERVER 미배포) 단계에서 /api/v1/health 미응답 회귀 방지.
# tfvars 에서 "ELB" 로 override: ALB target group health check 결과로 unhealthy 인스턴스 자동 교체.
variable "asg_health_check_type" {
  description = "ASG health check 모드. 'EC2' (기본, instance lifecycle 만 검사) 또는 'ELB' (ALB target group health 신뢰, 애플리케이션 레벨 fail 감지). SERVER 배포 + /api/v1/health 안정화 후 'ELB' 권장."
  type        = string
  default     = "EC2"
  validation {
    condition     = contains(["EC2", "ELB"], var.asg_health_check_type)
    error_message = "asg_health_check_type must be 'EC2' or 'ELB'."
  }
}

variable "acm_certificate_arn" {
  description = "ALB HTTPS listener 가 사용할 ACM 인증서 ARN (ap-northeast-2 리전). 비우면 ACM lookup 또는 listener 비활성. enable_acm_auto=true 시 acm.tf 가 자동 발급한 인증서가 우선."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# ACM 자동 발급 + CloudFront (사용자 결정 2026-06-02 — 3 서브도메인 각각 CF + ACM 자동).
# -----------------------------------------------------------------------------
variable "enable_acm_auto" {
  description = "true 이면 acm.tf 가 ALB(ap-northeast-2)/CloudFront(us-east-1) ACM 인증서를 SAN `*.<root_domain>` + `<root_domain>` 로 자동 발급하고 Route53 DNS validation 까지 처리. 인증서 만료 자동 갱신. root_domain 미설정 또는 hosted_zone_id 비어있으면 무시 (manual 모드 유지)."
  type        = bool
  default     = false
}

variable "enable_cloudfront" {
  description = "true 이면 cloudfront.tf 가 api/ai/admin 3개 서브도메인 각각에 CloudFront distribution 을 만들고 Route53 alias 를 ALB 직결 대신 CF 로 전환. ACM 인증서는 enable_acm_auto=true 가 us-east-1 인증서를 자동 발급해 함께 묶임."
  type        = bool
  default     = false
}

variable "cloudfront_min_protocol_version" {
  description = "CloudFront viewer TLS 최소 버전. 기본 TLSv1.2_2021. 호환성 강제 시 TLSv1.2_2018 권장 안 함 (보안 약화)."
  type        = string
  default     = "TLSv1.2_2021"
}

# 사용자 요청 8종 정합 — 운영 admin/policy CloudFront 분배 ACM alias 적용용 변수.
# admin_domain / policy_domain / cloudfront_admin_acm_arn / cloudfront_policy_acm_arn 모두
# 빈 문자열 default — 비어있으면 기존 cloudfront_default_certificate=true + TLSv1 fallback 유지.
variable "admin_domain" {
  description = "admin CloudFront 분배에 적용할 FQDN. 예: admin.iconia.com. 비우면 기존 default CF 인증서 + aliases=[] 유지 (호환 보존)."
  type        = string
  default     = ""
}

variable "policy_domain" {
  description = "policy CloudFront 분배에 적용할 FQDN. 예: policy.iconia.com. 비우면 기존 default CF 인증서 + aliases=[] 유지 (호환 보존)."
  type        = string
  default     = ""
}

variable "cloudfront_admin_acm_arn" {
  description = "admin CloudFront 분배가 사용할 ACM 인증서 ARN (us-east-1). admin_domain 과 함께 설정 시에만 활성. 비우면 enable_acm_auto 가 발급한 cert 가 우선, 없으면 default CF cert fallback."
  type        = string
  default     = ""
}

variable "cloudfront_policy_acm_arn" {
  description = "policy CloudFront 분배가 사용할 ACM 인증서 ARN (us-east-1). policy_domain 과 함께 설정 시에만 활성. 비우면 enable_acm_auto 가 발급한 cert 가 우선, 없으면 default CF cert fallback."
  type        = string
  default     = ""
}

variable "cloudfront_admin_origin_https" {
  description = "true 면 admin CF 분배 → ALB origin 을 https-only 로 강제 (TLSv1.2). 기본 false — 기존 http-only 동작 보존 (ALB :8082 HTTP). ALB 8443 HTTPS 리스너 정합 후 true 권장."
  type        = bool
  default     = false
}

variable "cloudfront_price_class" {
  description = "CloudFront price class. 'PriceClass_100' (NA+EU only, 최저), 'PriceClass_200' (NA+EU+SEA/한국 권장), 'PriceClass_All' (전 세계)."
  type        = string
  default     = "PriceClass_200"
}

variable "alb_idle_timeout_seconds" {
  description = "ALB idle timeout. 인형/앱의 streaming 응답 최대 길이 고려."
  type        = number
  default     = 60
}

variable "alb_internal" {
  description = "ALB 내부/외부. 기본은 외부(false)."
  type        = bool
  default     = false
}

variable "ec2_root_volume_size_gb" {
  description = "EC2 root EBS gp3 크기 GB."
  type        = number
  default     = 30
}

variable "ec2_key_pair_name" {
  description = "SSH 접속용 키페어 이름. 비우면 SSM Session Manager 만 허용 (권장)."
  type        = string
  default     = ""
}

variable "ec2_ami_id" {
  description = "EC2 AMI ID. 비우면 최신 Ubuntu 22.04 LTS (ap-northeast-2) 자동 조회."
  type        = string
  default     = ""
}

variable "ssh_allowed_cidrs" {
  description = "SSH(22) 허용 CIDR. ec2_key_pair_name 가 비어있으면 무시. 운영 권장은 [] + SSM 전용."
  type        = list(string)
  default     = []
}

variable "http_allowed_cidrs" {
  description = "HTTP/HTTPS 허용 CIDR. 일반적으로 [\"0.0.0.0/0\"]."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# -----------------------------------------------------------------------------
# RDS (PostgreSQL).
# -----------------------------------------------------------------------------
variable "db_engine_mode" {
  description = "RDS 엔진 모드: 'instance' (db.t4g.medium 단일) 또는 'aurora-serverless-v2'."
  type        = string
  default     = "instance"
  validation {
    condition     = contains(["instance", "aurora-serverless-v2"], var.db_engine_mode)
    error_message = "db_engine_mode must be 'instance' or 'aurora-serverless-v2'."
  }
}

variable "db_password" {
  description = "RDS master password. Secrets Manager 참조 권장. -var 또는 terraform.tfvars(gitignore) 로 주입."
  type        = string
  sensitive   = true
  default     = ""
}

variable "db_name" {
  description = "RDS 초기 DB name."
  type        = string
  default     = "iconia"
}

variable "db_username" {
  description = "RDS master username."
  type        = string
  default     = "iconia_admin"
}

variable "db_instance_class" {
  description = "instance 모드일 때 사용할 인스턴스 클래스."
  type        = string
  default     = "db.t4g.medium"
}

variable "db_allocated_storage_gb" {
  description = "instance 모드 storage GB. gp3."
  type        = number
  default     = 50
}

variable "enable_rds_proxy" {
  description = "RDS Proxy 생성 여부. Free Plan 은 미지원이라 false. Paid 전환 후 true 권장 (connection multiplexing)."
  type        = bool
  default     = true
}

variable "rds_multi_az" {
  description = "RDS instance Multi-AZ standby 활성화. 운영 안정성 강화 시 true. Free Plan 비대상 (db.t3.micro 등). Paid 전환 시 true 권장."
  type        = bool
  default     = false
}

variable "rds_backup_retention_days" {
  description = "RDS 자동 백업 보존 기간(일) — PITR window. Free Plan 1, V1.0 prod 권장 7~35 (PIPA + RPO 정합)."
  type        = number
  default     = 1
  validation {
    condition     = var.rds_backup_retention_days >= 0 && var.rds_backup_retention_days <= 35
    error_message = "rds_backup_retention_days must be between 0 and 35."
  }
}

variable "rds_deletion_protection" {
  description = "RDS deletion protection + skip_final_snapshot 정합. V1.0 prod 는 반드시 true. PoC/dev false."
  type        = bool
  default     = false
}

variable "rds_performance_insights" {
  description = "RDS Performance Insights 활성. db.t3.micro 미지원 — Paid 인스턴스(db.t4g.medium+) 에서 true."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# S3.
# -----------------------------------------------------------------------------
variable "events_bucket_name" {
  description = "Events (HW 이미지/음성) 버킷 이름. 글로벌 유니크. 비우면 자동 명명."
  type        = string
  default     = ""
}

variable "exports_bucket_name" {
  description = "DataExport (PIPA/GDPR) 버킷 이름. events 와 분리 필수."
  type        = string
  default     = ""
}

variable "firmware_bucket_name" {
  description = "OTA 펌웨어 binary 버킷 이름."
  type        = string
  default     = ""
}

variable "artifacts_bucket_name" {
  description = "로컬에서 빌드한 server/ai/admin tarball 업로드 위치. EC2 가 pull."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# EFS.
# -----------------------------------------------------------------------------
variable "efs_throughput_mode" {
  description = "EFS throughput mode. bursting / provisioned / elastic."
  type        = string
  default     = "elastic"
}

# -----------------------------------------------------------------------------
# Route53.
# -----------------------------------------------------------------------------
variable "root_domain" {
  description = "운영 root domain. terraform.tfvars 에 실제 값 주입."
  type        = string
  default     = ""
}

variable "create_route53_records" {
  description = "Route53 A record 생성 여부. EC2 EIP 가 준비된 뒤 true 로 전환."
  type        = bool
  default     = true
}

variable "hosted_zone_id" {
  description = "기존 Route53 hosted zone ID. 비우면 route53.tf 가 zone 신규 생성."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Server application-side runtime — claim/lease, event store backend.
# server.js:849~850 의 INSTANCE_ID / ANALYSIS_CLAIM_LEASE_MS / EVENT_STORE_BACKEND
# 환경변수를 user-data 가 /etc/iconia.env 에 주입. INSTANCE_ID 자체는 EC2 instance-id
# 를 IMDSv2 로 받아 user-data 가 채우므로 여기서는 변수 없음.
# -----------------------------------------------------------------------------
variable "event_store_backend" {
  description = "Server EventStore 백엔드. 'fs' (단일 EC2 / EFS atomic 파일) | 'prisma' (ASG N 인스턴스 race-free Postgres event_store)."
  type        = string
  default     = "fs"
  validation {
    condition     = contains(["fs", "prisma"], var.event_store_backend)
    error_message = "event_store_backend must be 'fs' or 'prisma'."
  }
}

variable "analysis_claim_lease_ms" {
  description = "Server analysis claim lease 시간(ms). 인스턴스가 죽으면 다른 인스턴스가 이 시간 이후 event 재claim. 기본 300000(5분)."
  type        = number
  default     = 300000
  validation {
    condition     = var.analysis_claim_lease_ms >= 30000 && var.analysis_claim_lease_ms <= 3600000
    error_message = "analysis_claim_lease_ms must be between 30000 (30s) and 3600000 (1h)."
  }
}

# -----------------------------------------------------------------------------
# certbot — Let's Encrypt 발급 이메일.
# user-data.sh.tftpl 의 certbot --nginx -m 인자로 주입.
# 기본값: web@soomkorea.com (운영팀 이메일). 환경별 override 가능.
# -----------------------------------------------------------------------------
variable "certbot_email" {
  description = "Let's Encrypt / certbot 인증서 발급 통지 이메일. user-data.sh.tftpl 의 -m 인자로 주입. 기본 web@soomkorea.com."
  type        = string
  default     = "web@soomkorea.com"
}

# -----------------------------------------------------------------------------
# 공통 태그.
# -----------------------------------------------------------------------------
variable "tags" {
  description = "추가 공통 태그. provider default_tags 와 병합."
  type        = map(string)
  default     = {}
}
