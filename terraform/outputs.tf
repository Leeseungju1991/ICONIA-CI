###############################################################################
# outputs.tf - 운영자/배포 스크립트가 참조할 값.
###############################################################################

# -----------------------------------------------------------------------------
# EC2 / Network.
# -----------------------------------------------------------------------------
output "ec2_instance_id" {
  description = "EC2 instance ID - SSM Run Command target."
  value       = aws_instance.main.id
}

output "ec2_public_ip" {
  description = "EC2 EIP - Route53 A record target. 사용자 트래픽 진입점."
  value       = aws_eip.main.public_ip
}

output "ec2_private_ip" {
  description = "EC2 private IP - VPC 내부 진단용."
  value       = aws_instance.main.private_ip
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
