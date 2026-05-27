###############################################################################
# terraform/multi-region/kms-multi-region.tf
#
# KMS multi-region key — primary 에서 생성, secondary 에서 replica.
#
# 활성화 조건: enable_multi_region=true AND kms_multi_region_enabled=true.
#
# 용도:
#   - S3 객체 / EBS 볼륨 / Secrets Manager replicated secret 등 *동일 키 ID 로*
#     양쪽 region 에서 복호화해야 하는 자산이 늘어날 때 활용.
#   - 단, RDS replica 는 region 별 다른 KMS 키 사용 권장 (rds-replica.tf 참조).
#
# 비용: multi-region key 자체는 region 당 $1/월 — 운영 영향 미미.
###############################################################################

# -----------------------------------------------------------------------------
# Primary region — multi-region primary key.
# -----------------------------------------------------------------------------
resource "aws_kms_key" "mr_primary" {
  count    = local.kms_enabled
  provider = aws.primary

  description             = "ICONIA ${var.env} multi-region primary key (S3 / Secrets / generic)."
  multi_region            = true
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-mr-primary"
    Purpose = "kms-multi-region-primary"
    Region  = "primary"
  })
}

resource "aws_kms_alias" "mr_primary" {
  count    = local.kms_enabled
  provider = aws.primary

  name          = "alias/${local.name_prefix}-mr"
  target_key_id = aws_kms_key.mr_primary[0].id
}

# -----------------------------------------------------------------------------
# Secondary region — multi-region replica key.
# 동일 KeyId 로 양쪽 region 에서 복호화 가능.
# -----------------------------------------------------------------------------
resource "aws_kms_replica_key" "mr_secondary" {
  count    = local.kms_enabled
  provider = aws.secondary

  description             = "ICONIA ${var.env} multi-region replica key (mirror of mr-primary in ${var.primary_region})."
  primary_key_arn         = aws_kms_key.mr_primary[0].arn
  deletion_window_in_days = 30

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-mr-secondary"
    Purpose = "kms-multi-region-replica"
    Region  = "secondary"
  })
}

resource "aws_kms_alias" "mr_secondary" {
  count    = local.kms_enabled
  provider = aws.secondary

  name          = "alias/${local.name_prefix}-mr"
  target_key_id = aws_kms_replica_key.mr_secondary[0].key_id
}
