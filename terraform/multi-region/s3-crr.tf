###############################################################################
# terraform/multi-region/s3-crr.tf
#
# S3 Cross-Region Replication (CRR).
# 활성화 조건: enable_multi_region=true AND s3_crr_enabled=true.
#
# 대상 버킷:
#   - artifacts (배포 산출물 — DR 시 빠른 재기동)
#   - events (이벤트 스토어 백업 — 사용자 데이터 무손실)
#
# 본 모듈은 secondary region 의 *destination* 버킷과 *replication role* 만 생성.
# Primary 버킷의 replication_configuration 은 primary stack(terraform/s3.tf)
# 에서 본 모듈의 outputs 를 참조하여 설정한다 (운영팀이 별도 라운드에 연결).
#
# RPO < 15min (S3 CRR SLA — 99.99% 객체가 15분 이내 복제, 대부분 < 1분).
###############################################################################

# -----------------------------------------------------------------------------
# Secondary region destination bucket — artifacts.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts_replica" {
  count    = local.s3_enabled
  provider = aws.secondary

  bucket = "${local.name_prefix}-artifacts-replica-${local.account_id}"

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-artifacts-replica"
    Purpose = "s3-crr-destination"
    Source  = var.primary_s3_artifacts_bucket
  })
}

resource "aws_s3_bucket_versioning" "artifacts_replica" {
  count    = local.s3_enabled
  provider = aws.secondary

  bucket = aws_s3_bucket.artifacts_replica[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts_replica" {
  count    = local.s3_enabled
  provider = aws.secondary

  bucket = aws_s3_bucket.artifacts_replica[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts_replica" {
  count    = local.s3_enabled
  provider = aws.secondary

  bucket                  = aws_s3_bucket.artifacts_replica[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# Secondary region destination bucket — events (사용자 이벤트 스토어 백업).
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "events_replica" {
  count    = local.s3_enabled
  provider = aws.secondary

  bucket = "${local.name_prefix}-events-replica-${local.account_id}"

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-events-replica"
    Purpose = "s3-crr-destination"
    Source  = var.primary_s3_events_bucket
  })
}

resource "aws_s3_bucket_versioning" "events_replica" {
  count    = local.s3_enabled
  provider = aws.secondary

  bucket = aws_s3_bucket.events_replica[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "events_replica" {
  count    = local.s3_enabled
  provider = aws.secondary

  bucket = aws_s3_bucket.events_replica[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "events_replica" {
  count    = local.s3_enabled
  provider = aws.secondary

  bucket                  = aws_s3_bucket.events_replica[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# Replication role — primary region 에서 source bucket 이 assume.
# Primary stack 의 s3.tf 에서 source bucket replication_configuration.role 로
# 본 ARN 을 주입.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "replication_assume" {
  count = local.s3_enabled

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "replication" {
  count    = local.s3_enabled
  provider = aws.primary

  name               = "${local.name_prefix}-s3-replication-role"
  assume_role_policy = data.aws_iam_policy_document.replication_assume[0].json

  tags = local.common_tags
}

data "aws_iam_policy_document" "replication" {
  count = local.s3_enabled

  # Source bucket — read 권한.
  statement {
    sid = "SourceRead"
    actions = [
      "s3:GetReplicationConfiguration",
      "s3:ListBucket",
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging",
    ]
    resources = [
      "arn:aws:s3:::${var.primary_s3_artifacts_bucket}",
      "arn:aws:s3:::${var.primary_s3_artifacts_bucket}/*",
      "arn:aws:s3:::${var.primary_s3_events_bucket}",
      "arn:aws:s3:::${var.primary_s3_events_bucket}/*",
    ]
  }

  # Destination bucket — write 권한.
  statement {
    sid = "DestinationWrite"
    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags",
    ]
    resources = [
      "${aws_s3_bucket.artifacts_replica[0].arn}/*",
      "${aws_s3_bucket.events_replica[0].arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "replication" {
  count    = local.s3_enabled
  provider = aws.primary

  name   = "${local.name_prefix}-s3-replication-policy"
  role   = aws_iam_role.replication[0].id
  policy = data.aws_iam_policy_document.replication[0].json
}
