###############################################################################
# terraform/multi-region/rds-replica.tf
#
# Cross-region RDS read replica (primary ap-northeast-2 → secondary ap-northeast-1).
#
# 활성화 조건: enable_multi_region=true AND rds_replica_enabled=true.
# 비활성화시 count=0 — 어떤 리소스도 생성되지 않음.
#
# RPO < 5min 목표:
#   - PostgreSQL physical replication (async) — 일반적 lag < 1s, RPO < 5min 안정 달성.
#   - storage_encrypted=true, kms_key_id 는 secondary region 키 사용 필수.
#
# 운영 절차 (failover):
#   1) 운영팀 의사결정 (primary down 확인, RPO 허용 손실 수용).
#   2) aws rds promote-read-replica --db-instance-identifier iconia-prod-db-replica
#      (또는 콘솔 Promote — 본 IaC 가 promote 자동화는 하지 않음 — 의도된 안전장치).
#   3) Route53 failover record 가 health check 실패 → secondary 로 자동 전환.
#   4) docs/multi-region.md §failover 절차 참조.
###############################################################################

# -----------------------------------------------------------------------------
# Secondary region 의 replica 전용 KMS 키 — 암호화 정책 분리.
# (kms-multi-region.tf 의 multi-region key 와 별개로, replica 전용 키를 둠으로써
#  primary 키 컴프로마이즈 시 secondary 영향 격리.)
# -----------------------------------------------------------------------------
resource "aws_kms_key" "rds_replica" {
  count    = local.rds_enabled
  provider = aws.secondary

  description             = "ICONIA ${var.env} RDS cross-region read replica encryption key."
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-rds-replica-key"
    Purpose = "rds-cross-region-replica"
  })
}

resource "aws_kms_alias" "rds_replica" {
  count    = local.rds_enabled
  provider = aws.secondary

  name          = "alias/${local.name_prefix}-rds-replica"
  target_key_id = aws_kms_key.rds_replica[0].id
}

# -----------------------------------------------------------------------------
# Cross-region read replica.
# - replicate_source_db: primary instance ARN (cross-region 인 경우 ARN 필수).
# - vpc / subnet group: secondary region 의 별도 VPC/Subnet group 가 사전 존재해야 함
#   (본 스캐폴드는 VPC/Subnet 은 생성하지 않음 — 운영자가 별도 stack 으로 secondary
#    network 을 준비. 단순 골격 단계에서 secondary VPC 생성까지 자동화하면 비용/실수
#    위험 큼.).
# -----------------------------------------------------------------------------
resource "aws_db_instance" "cross_region_replica" {
  count    = local.rds_enabled
  provider = aws.secondary

  identifier          = "${local.name_prefix}-db-replica"
  replicate_source_db = var.primary_db_instance_arn

  instance_class             = var.rds_replica_instance_class
  allocated_storage          = var.rds_replica_storage_gb
  storage_type               = "gp3"
  storage_encrypted          = true
  kms_key_id                 = aws_kms_key.rds_replica[0].arn
  publicly_accessible        = false
  auto_minor_version_upgrade = true

  # backup_retention_period 는 replica 에서도 설정 가능 — promotion 후 PITR 가능.
  backup_retention_period = 7
  copy_tags_to_snapshot   = true
  deletion_protection     = var.env == "prod"
  skip_final_snapshot     = var.env != "prod"

  performance_insights_enabled = false
  monitoring_interval          = 0

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-db-replica"
    Purpose = "rds-cross-region-replica"
    Source  = "primary-${var.primary_region}"
  })

  lifecycle {
    # replicate_source_db 변경은 replica 재생성 — 운영자 명시 확인 필요.
    ignore_changes = [
      replicate_source_db,
    ]
  }
}

# -----------------------------------------------------------------------------
# CloudWatch alarm — replica lag.
# RPO 위반 (5분 = 300초) 사전 감지.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "replica_lag" {
  count    = local.rds_enabled
  provider = aws.secondary

  alarm_name          = "${local.name_prefix}-db-replica-lag"
  alarm_description   = "ICONIA RDS cross-region replica lag > 300s (RPO 5분 임계). 운영팀 확인 필요."
  namespace           = "AWS/RDS"
  metric_name         = "ReplicaLag"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 300
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.cross_region_replica[0].identifier
  }

  tags = local.common_tags
}
