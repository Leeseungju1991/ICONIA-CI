###############################################################################
# s3.tf — events / exports / firmware 버킷 (분리, lifecycle 다름).
#
# H-5 의 코드 측 강제(EXPORT_BUCKET != EVENT_IMAGE_BUCKET) 와 정합:
#   events  prefix iconia/events/ 90일 후 Glacier_IR + 455일 만료
#   exports 7일 만료 (DataExport zip 은 사용자 다운로드 후 즉시 폐기)
#   firmware 별도 버킷, public 차단, OTA 펌웨어 read-only.
###############################################################################

locals {
  events_bucket    = var.events_bucket_name != "" ? var.events_bucket_name : "${local.name_prefix}-events-${local.account_id}"
  exports_bucket   = var.exports_bucket_name != "" ? var.exports_bucket_name : "${local.name_prefix}-exports-${local.account_id}"
  firmware_bucket  = var.firmware_bucket_name != "" ? var.firmware_bucket_name : "${local.name_prefix}-firmware-${local.account_id}"
  artifacts_bucket = var.artifacts_bucket_name != "" ? var.artifacts_bucket_name : "${local.name_prefix}-artifacts-${local.account_id}"
}

# -----------------------------------------------------------------------------
# Events bucket.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "events" {
  bucket        = local.events_bucket
  force_destroy = var.env != "prod" # prod 는 false — 실수 방어.
  tags          = merge(var.tags, { purpose = "events" })
}

resource "aws_s3_bucket_public_access_block" "events" {
  bucket                  = aws_s3_bucket.events.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "events" {
  bucket = aws_s3_bucket.events.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "events" {
  bucket = aws_s3_bucket.events.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # CMK 도입 시 KMS 로 교체.
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "events" {
  bucket = aws_s3_bucket.events.id

  rule {
    id     = "events-archive-glacier-then-expire"
    status = "Enabled"
    filter { prefix = "iconia/events/" }
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    expiration { days = 455 }
    noncurrent_version_expiration { noncurrent_days = 30 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }

  # Phase 8 #24 — voice 를 in/out 으로 분리. legacy "iconia/voice/" prefix 의 30일 정책은
  # 호환을 위해 유지하되 신규 흐름은 in (7일) / out (30일) 두 정책이 적용된다.
  # filter prefix 가 더 길고 구체적인 rule 이 lifecycle 평가에서 우선 — S3 evaluation order
  # 는 prefix length 가 아니라 모든 매칭 rule 의 합집합 동작이므로 prefix 가 겹치지 않도록
  # "iconia/voice/in/" / "iconia/voice/out/" 와 "iconia/voice/" (in/out 제외) 가 자연 분리됨.
  # (S3 lifecycle 은 prefix 가 *exact* match — "iconia/voice/" 는 "iconia/voice/in/..." 도
  # 포괄하므로, 명시적으로 별도 expiration 을 둔 in/out 의 짧은/긴 정책이 추가 적용된다.
  # 짧은 expiration 이 항상 이기는 구조 → in=7일 우선.)
  rule {
    id     = "voice-legacy-30day-expire"
    status = "Enabled"
    filter { prefix = "iconia/voice/" }
    expiration { days = 30 }
    noncurrent_version_expiration { noncurrent_days = 7 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }

  # voice in (STT 입력 사용자 원본) — 7일 후 즉시 만료. STT 변환 후 보존 가치 낮음.
  rule {
    id     = "voice-in-7day-expire"
    status = "Enabled"
    filter { prefix = "iconia/voice/in/" }
    expiration { days = 7 }
    noncurrent_version_expiration { noncurrent_days = 1 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }

  # voice out (TTS 응답 산출물) — 30일 유지. presigned URL 만료/재생 보장 윈도우 커버.
  rule {
    id     = "voice-out-30day-expire"
    status = "Enabled"
    filter { prefix = "iconia/voice/out/" }
    expiration { days = 30 }
    noncurrent_version_expiration { noncurrent_days = 7 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

resource "aws_s3_bucket_policy" "events" {
  bucket = aws_s3_bucket.events.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.events.arn,
          "${aws_s3_bucket.events.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Exports bucket — 별도 lifecycle (7일 만료) + 별도 IAM (iam.tf).
# events 와 절대 합치지 말 것 (config.js H-5 가 prod 에서 throw).
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "exports" {
  bucket        = local.exports_bucket
  force_destroy = var.env != "prod"
  tags          = merge(var.tags, { purpose = "data-export" })
}

resource "aws_s3_bucket_public_access_block" "exports" {
  bucket                  = aws_s3_bucket.exports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "exports" {
  bucket = aws_s3_bucket.exports.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "exports" {
  bucket = aws_s3_bucket.exports.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "exports" {
  bucket = aws_s3_bucket.exports.id
  rule {
    id     = "exports-7day-expire"
    status = "Enabled"
    filter { prefix = "iconia/exports/" }
    expiration { days = 7 }
    noncurrent_version_expiration { noncurrent_days = 1 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

resource "aws_s3_bucket_policy" "exports" {
  bucket = aws_s3_bucket.exports.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.exports.arn,
          "${aws_s3_bucket.exports.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Firmware bucket — OTA 전용. PutObject 는 운영자/CI 만, EC2 role 은 GetObject 한정.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "firmware" {
  bucket        = local.firmware_bucket
  force_destroy = false # 펌웨어 binary 는 prod/dev 모두 보존.
  tags          = merge(var.tags, { purpose = "firmware" })
}

resource "aws_s3_bucket_public_access_block" "firmware" {
  bucket                  = aws_s3_bucket.firmware.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "firmware" {
  bucket = aws_s3_bucket.firmware.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "firmware" {
  bucket = aws_s3_bucket.firmware.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "firmware" {
  bucket = aws_s3_bucket.firmware.id

  rule {
    id     = "firmware-noncurrent-expire"
    status = "Enabled"
    filter { prefix = "" }
    noncurrent_version_expiration { noncurrent_days = 90 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

# -----------------------------------------------------------------------------
# Artifacts bucket - 로컬에서 빌드한 server/ai/admin tarball 업로드 위치.
# EC2 host 의 ec2-pull-and-restart.sh 가 pull 한다.
# 구조:
#   s3://<artifacts>/server/<version>.tar.gz
#   s3://<artifacts>/server/latest.tar.gz       (always overwritten)
#   s3://<artifacts>/ai/<version>.tar.gz
#   s3://<artifacts>/ai/latest.tar.gz
#   s3://<artifacts>/admin/<version>.tar.gz
#   s3://<artifacts>/admin/latest.tar.gz
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  bucket        = local.artifacts_bucket
  force_destroy = false # 운영 아티팩트 보존.
  tags          = merge(var.tags, { purpose = "deploy-artifacts" })
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-old-noncurrent-versions"
    status = "Enabled"
    filter { prefix = "" }
    noncurrent_version_expiration { noncurrent_days = 30 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }

  rule {
    id     = "expire-old-versioned-objects"
    status = "Enabled"
    filter { prefix = "" }
    expiration { days = 90 } # 90일 지난 버전 만료. latest 는 항상 overwrite 되어 영향 없음.
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })
}
