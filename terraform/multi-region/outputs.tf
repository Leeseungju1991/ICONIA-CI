###############################################################################
# terraform/multi-region/outputs.tf
#
# 다른 stack (primary terraform/) 또는 운영 스크립트가 참조할 식별자 노출.
###############################################################################

output "enabled" {
  description = "본 multi-region 모듈이 활성화되어 있는지 여부."
  value       = var.enable_multi_region
}

output "primary_region" {
  description = "Primary region 식별자."
  value       = var.primary_region
}

output "secondary_region" {
  description = "Secondary region 식별자."
  value       = var.secondary_region
}

# -----------------------------------------------------------------------------
# RDS replica.
# -----------------------------------------------------------------------------
output "rds_replica_id" {
  description = "Cross-region RDS read replica identifier (disabled 시 null)."
  value       = local.rds_enabled > 0 ? aws_db_instance.cross_region_replica[0].identifier : null
}

output "rds_replica_arn" {
  description = "Cross-region RDS read replica ARN (disabled 시 null)."
  value       = local.rds_enabled > 0 ? aws_db_instance.cross_region_replica[0].arn : null
}

output "rds_replica_endpoint" {
  description = "Cross-region RDS read replica endpoint — secondary region 의 read-only endpoint."
  value       = local.rds_enabled > 0 ? aws_db_instance.cross_region_replica[0].endpoint : null
}

# -----------------------------------------------------------------------------
# S3 CRR.
# -----------------------------------------------------------------------------
output "s3_artifacts_replica_bucket" {
  description = "Secondary region artifacts replication destination bucket."
  value       = local.s3_enabled > 0 ? aws_s3_bucket.artifacts_replica[0].id : null
}

output "s3_artifacts_replica_arn" {
  description = "Secondary region artifacts replication destination bucket ARN. Primary stack 에서 replication_configuration.destination.bucket 에 주입."
  value       = local.s3_enabled > 0 ? aws_s3_bucket.artifacts_replica[0].arn : null
}

output "s3_events_replica_bucket" {
  description = "Secondary region events replication destination bucket."
  value       = local.s3_enabled > 0 ? aws_s3_bucket.events_replica[0].id : null
}

output "s3_events_replica_arn" {
  description = "Secondary region events replication destination bucket ARN."
  value       = local.s3_enabled > 0 ? aws_s3_bucket.events_replica[0].arn : null
}

output "s3_replication_role_arn" {
  description = "Primary region 의 S3 replication IAM role ARN — source bucket 에 주입."
  value       = local.s3_enabled > 0 ? aws_iam_role.replication[0].arn : null
}

# -----------------------------------------------------------------------------
# Route53 failover.
# -----------------------------------------------------------------------------
output "primary_health_check_id" {
  description = "Primary region Route53 health check ID."
  value       = local.r53_enabled > 0 ? aws_route53_health_check.primary[0].id : null
}

output "secondary_health_check_id" {
  description = "Secondary region Route53 health check ID."
  value       = local.r53_enabled > 0 ? aws_route53_health_check.secondary[0].id : null
}

# -----------------------------------------------------------------------------
# KMS multi-region.
# -----------------------------------------------------------------------------
output "kms_mr_primary_arn" {
  description = "Multi-region KMS primary key ARN."
  value       = local.kms_enabled > 0 ? aws_kms_key.mr_primary[0].arn : null
}

output "kms_mr_secondary_arn" {
  description = "Multi-region KMS replica key ARN (secondary region)."
  value       = local.kms_enabled > 0 ? aws_kms_replica_key.mr_secondary[0].arn : null
}

output "kms_mr_alias" {
  description = "Multi-region KMS key alias (양쪽 region 동일)."
  value       = local.kms_enabled > 0 ? aws_kms_alias.mr_primary[0].name : null
}

# -----------------------------------------------------------------------------
# 요약 — 운영 콘솔 / 스크립트에 적합한 단일 객체.
# -----------------------------------------------------------------------------
output "summary" {
  description = "Multi-region 활성화 상태 요약."
  value = {
    enabled                     = var.enable_multi_region
    primary_region              = var.primary_region
    secondary_region            = var.secondary_region
    rds_replica_enabled         = var.rds_replica_enabled
    s3_crr_enabled              = var.s3_crr_enabled
    route53_failover_enabled    = var.route53_failover_enabled
    secrets_replication_enabled = var.secrets_replication_enabled
    kms_multi_region_enabled    = var.kms_multi_region_enabled
    rto_target_minutes          = 60
    rpo_target_minutes          = 5
  }
}
