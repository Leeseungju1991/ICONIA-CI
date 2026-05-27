###############################################################################
# terraform/multi-region/variables.tf
#
# ICONIA V1.x Multi-region 모듈 변수.
# 기본값은 disabled — apply 해도 secondary 리소스 0개.
###############################################################################

variable "env" {
  description = "배포 환경. multi-region 은 prod 만 권장."
  type        = string
  default     = "prod"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "env must be one of: dev, staging, prod."
  }
}

# -----------------------------------------------------------------------------
# 마스터 토글 — false 면 모든 secondary 리소스 0개 생성.
# -----------------------------------------------------------------------------
variable "enable_multi_region" {
  description = "true 면 secondary region 리소스 생성. false (default) 면 스캐폴드만 존재하고 0개 생성."
  type        = bool
  default     = false
}

variable "primary_region" {
  description = "Primary region — 현재 운영 region (V1.0 단일 region)."
  type        = string
  default     = "ap-northeast-2"
}

variable "secondary_region" {
  description = "Secondary region — DR 대상. 도쿄 권장 (지연 < 50ms, 동일 KR 컴플라이언스 권역)."
  type        = string
  default     = "ap-northeast-1"
}

# -----------------------------------------------------------------------------
# 개별 기능 토글 — 단계적 활성화용.
# -----------------------------------------------------------------------------
variable "rds_replica_enabled" {
  description = "secondary region RDS read replica 생성 여부. enable_multi_region 과 함께 true 여야 활성화."
  type        = bool
  default     = false
}

variable "s3_crr_enabled" {
  description = "S3 Cross-Region Replication (primary → secondary) 활성화 여부."
  type        = bool
  default     = false
}

variable "route53_failover_enabled" {
  description = "Route53 health check + failover record (primary/secondary) 활성화 여부."
  type        = bool
  default     = false
}

variable "secrets_replication_enabled" {
  description = "Secrets Manager replica region 활성화 여부."
  type        = bool
  default     = false
}

variable "kms_multi_region_enabled" {
  description = "KMS multi-region key + replica 활성화 여부."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Primary 자산 식별자 — secondary 리소스가 참조해야 함. 활성화 시 운영자가 주입.
# -----------------------------------------------------------------------------
variable "primary_db_instance_arn" {
  description = "Primary region RDS instance ARN (cross-region read replica source). enable=true 시 필수."
  type        = string
  default     = ""
}

variable "primary_db_kms_key_arn" {
  description = "Primary RDS KMS key ARN. cross-region replica 용 secondary KMS 키와 분리."
  type        = string
  default     = ""
}

variable "primary_s3_artifacts_bucket" {
  description = "Primary region artifacts S3 bucket 이름 (CRR source)."
  type        = string
  default     = ""
}

variable "primary_s3_events_bucket" {
  description = "Primary region events S3 bucket 이름 (CRR source — 이벤트 스토어 백업)."
  type        = string
  default     = ""
}

variable "primary_alb_dns" {
  description = "Primary ALB DNS — Route53 primary failover target."
  type        = string
  default     = ""
}

variable "primary_alb_zone_id" {
  description = "Primary ALB hosted zone ID — alias record 용."
  type        = string
  default     = ""
}

variable "secondary_alb_dns" {
  description = "Secondary ALB DNS — Route53 secondary failover target. secondary 인프라 활성화 후 주입."
  type        = string
  default     = ""
}

variable "secondary_alb_zone_id" {
  description = "Secondary ALB hosted zone ID."
  type        = string
  default     = ""
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID — failover record 생성 대상."
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "Route53 zone 의 도메인 (예: iconia.example). API failover record 는 api.<domain>."
  type        = string
  default     = ""
}

variable "failover_health_path" {
  description = "Route53 health check 가 GET 할 경로 (deep health)."
  type        = string
  default     = "/health?deep=1"
}

# -----------------------------------------------------------------------------
# RDS replica 세부 — 활성화 시점에만 의미.
# -----------------------------------------------------------------------------
variable "rds_replica_instance_class" {
  description = "Cross-region read replica instance class."
  type        = string
  default     = "db.t4g.medium"
}

variable "rds_replica_storage_gb" {
  description = "Replica allocated storage (GB)."
  type        = number
  default     = 100
}

# -----------------------------------------------------------------------------
# Secrets Manager 복제 대상 — 운영자가 명시 (실값은 본 모듈 외부에서 관리).
# -----------------------------------------------------------------------------
variable "replicated_secret_arns" {
  description = "secondary region 으로 복제할 primary Secrets Manager ARN 목록."
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# 사용자 정의 추가 태그.
# -----------------------------------------------------------------------------
variable "tags" {
  description = "추가 태그. 기본 태그(Project/Environment/MultiRegion) 위에 merge."
  type        = map(string)
  default     = {}
}
