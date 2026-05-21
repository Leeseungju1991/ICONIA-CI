###############################################################################
# outputs.tf - 운영자/배포 스크립트가 참조할 값.
###############################################################################

# -----------------------------------------------------------------------------
# ASG / ALB / Network — Phase 6.
# -----------------------------------------------------------------------------
output "asg_name" {
  description = "ASG 이름 — aws-deploy.ps1 가 SSM Run Command 의 target 으로 사용 (tag:aws:autoscaling:groupName)."
  value       = aws_autoscaling_group.iconia_server.name
}

output "asg_target_group_arn" {
  description = "ALB target group ARN — 외부 health check / 배포 스크립트 참조."
  value       = aws_lb_target_group.server.arn
}

output "alb_dns_name" {
  description = "ALB public DNS — Route53 alias 의 대상. 단독 검증 시에도 사용."
  value       = aws_lb.iconia.dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID — Route53 alias 가 참조."
  value       = aws_lb.iconia.zone_id
}

output "alb_arn_suffix" {
  description = "alarms.tf 의 var.alarm_alb_arn_suffix 에 그대로 주입할 값."
  value       = aws_lb.iconia.arn_suffix
}

output "vpc_id" {
  value = local.vpc_id
}

output "public_subnet_ids" {
  value = local.public_subnet_ids
}

output "private_subnet_ids" {
  value = local.private_subnet_ids
}

# -----------------------------------------------------------------------------
# S3 buckets.
# -----------------------------------------------------------------------------
output "artifacts_bucket_name" {
  description = "scripts/build-and-upload.ps1 가 업로드할 S3 버킷."
  value       = aws_s3_bucket.artifacts.bucket
}

output "events_bucket_name" {
  description = "EVENT_IMAGE_BUCKET 에 그대로 주입할 값."
  value       = aws_s3_bucket.events.bucket
}

output "exports_bucket_name" {
  description = "EXPORT_BUCKET 에 그대로 주입할 값. events 와 분리 필수."
  value       = aws_s3_bucket.exports.bucket
}

output "firmware_bucket_name" {
  description = "OTA_FIRMWARE_BUCKET 에 주입할 값."
  value       = aws_s3_bucket.firmware.bucket
}

# -----------------------------------------------------------------------------
# EFS.
# -----------------------------------------------------------------------------
output "efs_id" {
  value = aws_efs_file_system.persona.id
}

output "efs_access_point_id" {
  value = aws_efs_access_point.server_root.id
}

# -----------------------------------------------------------------------------
# RDS.
# -----------------------------------------------------------------------------
output "rds_endpoint" {
  description = "RDS 직접 endpoint. 진단/마이그레이션 전용. Server 는 rds_proxy_endpoint 우선."
  value = (
    length(aws_db_instance.postgres) > 0
    ? aws_db_instance.postgres[0].endpoint
    : (length(aws_rds_cluster.aurora) > 0 ? aws_rds_cluster.aurora[0].endpoint : "")
  )
}

output "rds_proxy_endpoint" {
  description = "RDS Proxy endpoint. Server .env 의 DATABASE_URL 에 본 값을 넣을 것 (connection multiplexing)."
  value = (
    length(aws_db_proxy.iconia_pg) > 0
    ? aws_db_proxy.iconia_pg[0].endpoint
    : ""
  )
}

output "database_url_template" {
  description = "Server 가 .env.aws 에 그대로 쓸 DATABASE_URL 템플릿 (password 부분만 Secrets Manager 에서 주입)."
  value = (
    length(aws_db_proxy.iconia_pg) > 0
    ? "postgresql://${var.db_username}:<<PASSWORD>>@${aws_db_proxy.iconia_pg[0].endpoint}:5432/${var.db_name}?sslmode=require"
    : ""
  )
  sensitive = false
}

output "rds_port" {
  value = 5432
}

output "rds_database_name" {
  value = var.db_name
}

output "rds_username" {
  value = var.db_username
}

output "rds_security_group_id" {
  value = aws_security_group.rds.id
}

# -----------------------------------------------------------------------------
# IAM.
# -----------------------------------------------------------------------------
output "ec2_iam_role_arn" {
  value = aws_iam_role.ec2.arn
}

output "ec2_instance_profile_name" {
  value = aws_iam_instance_profile.ec2.name
}

# -----------------------------------------------------------------------------
# Route53.
# -----------------------------------------------------------------------------
output "route53_zone_id" {
  description = "사용된 hosted zone ID (신규 또는 기존)."
  value       = local.zone_id
}

output "api_fqdn" {
  description = "Server API 진입 FQDN."
  value       = var.root_domain != "" ? "${local.api_subdomain}.${var.root_domain}" : ""
}

output "ai_fqdn" {
  description = "AI 서비스 진입 FQDN."
  value       = var.root_domain != "" ? "${local.ai_subdomain}.${var.root_domain}" : ""
}

output "admin_fqdn" {
  description = "Admin 콘솔 진입 FQDN."
  value       = var.root_domain != "" ? "${local.admin_subdomain}.${var.root_domain}" : ""
}

# -----------------------------------------------------------------------------
# 기타.
# -----------------------------------------------------------------------------
output "name_prefix" {
  description = "iconia-<env>."
  value       = local.name_prefix
}

# -----------------------------------------------------------------------------
# Redis (Phase 6).
# -----------------------------------------------------------------------------
output "redis_primary_endpoint" {
  description = "ElastiCache Redis primary endpoint. Server REDIS_URL 에 rediss://:<auth>@<endpoint>:6379 형태로 주입."
  value       = aws_elasticache_replication_group.iconia_redis.primary_endpoint_address
}

output "redis_reader_endpoint" {
  description = "ElastiCache Redis reader endpoint."
  value       = aws_elasticache_replication_group.iconia_redis.reader_endpoint_address
}

output "redis_replication_group_id" {
  description = "alarms.tf 의 var.alarm_redis_cluster_id 에 그대로 주입."
  value       = aws_elasticache_replication_group.iconia_redis.id
}

output "redis_auth_secret_arn" {
  description = "AUTH token 이 저장된 Secrets Manager ARN. Server 가 GetSecretValue 로 읽어 client init."
  value       = aws_secretsmanager_secret.redis_auth.arn
}
