###############################################################################
# alarms.tf - main terraform stack 에서 deploy/aws/alarms.tf 모듈을 통합.
#
# 이전: deploy/aws 에서 별도 `terraform init/apply` 필요 → 운영자가 자주 누락.
# 변경: main terraform/ 의 `terraform apply` 한 번이 알람까지 만든다.
#
# 본 파일은 deploy/aws/alarms.tf 를 child module 로 호출만 한다. 알람 정의
# 자체는 deploy/aws/alarms.tf 가 정본 (CloudWatch alarm rule schema 는 IaC 도입
# 이전 cloudwatch-alarms.json 과 1:1 추적 중이라 그쪽에서 단일 source of truth
# 유지).
#
# child module 에서 사용할 수 없는 backend/provider/terraform 블록은 의도적으로
# 그쪽에 남겨둔 채(terraform module 은 본 블록 무시), 입력 변수만 주입.
###############################################################################

module "alarms" {
  source = "../deploy/aws"

  # alarms.tf 가 노출하는 변수들과 1:1 매핑.
  alarm_email          = var.alarm_email
  pagerduty_endpoint   = var.alarm_pagerduty_endpoint
  cloudwatch_namespace = var.alarm_cloudwatch_namespace
  audit_namespace      = var.alarm_audit_namespace
  alb_arn_suffix       = var.alarm_alb_arn_suffix

  # RDS identifier 는 main stack 의 rds.tf 출력에서 자동 주입.
  rds_instance_identifier = (
    length(aws_db_instance.postgres) > 0
    ? aws_db_instance.postgres[0].id
    : ""
  )

  redis_cluster_id                    = var.alarm_redis_cluster_id
  rds_freeable_memory_threshold_bytes = var.alarm_rds_freeable_memory_threshold_bytes

  tags = merge(var.tags, { service = "iconia-server", managed = "terraform" })
}

# -----------------------------------------------------------------------------
# 본 stack 의 alarm 관련 변수 - alarms.tf 와 같은 이름으로 prefix `alarm_` 만
# 다르게 노출 (변수 이름 충돌 방지).
# -----------------------------------------------------------------------------
variable "alarm_email" {
  description = "알람 SNS 구독 이메일."
  type        = string
  default     = ""
}

variable "alarm_pagerduty_endpoint" {
  description = "PagerDuty integration URL."
  type        = string
  default     = ""
  sensitive   = true
}

variable "alarm_cloudwatch_namespace" {
  description = "Server CloudWatch namespace."
  type        = string
  default     = "ICONIA/Server"
}

variable "alarm_audit_namespace" {
  description = "Audit namespace."
  type        = string
  default     = "ICONIA/Audit"
}

variable "alarm_alb_arn_suffix" {
  description = "ALB target ARN suffix (ALB 도입 후 채움)."
  type        = string
  default     = ""
}

variable "alarm_redis_cluster_id" {
  description = "ElastiCache redis cluster id (Redis 도입 후 채움)."
  type        = string
  default     = ""
}

variable "alarm_rds_freeable_memory_threshold_bytes" {
  description = "RDS FreeableMemory 임계 byte."
  type        = number
  default     = 838860800
}

output "alarms_sns_topic_arn" {
  description = "통합 SNS topic - 추가 알람 attach 시 참조."
  value       = module.alarms.sns_topic_arn
}

output "alarm_names" {
  description = "본 stack 에서 생성된 알람 이름."
  value       = module.alarms.alarm_names
}
