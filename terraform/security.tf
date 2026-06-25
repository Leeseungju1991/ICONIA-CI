###############################################################################
# security.tf — V1.0 보안 베이스라인 (감사·추적·위협탐지).
#
# 4종 AWS 보안 서비스 + GuardDuty findings CloudWatch 알람:
#   1) VPC Flow Logs       (var.enable_vpc_flow_logs)
#   2) CloudTrail          (var.enable_cloudtrail)
#      - multi-region trail + log file integrity validation ON.
#   3) AWS Config          (var.enable_aws_config)
#   4) GuardDuty           (var.enable_guardduty)
#      - 30일 무료 트라이얼 후 GB 기반 과금.
#      - findings EventBridge → CloudWatch Alarm (GuardDutyHighFindings).
#
# 토글 OFF 시 plan diff 0 (멱등).
###############################################################################

# -----------------------------------------------------------------------------
# Toggles.
# -----------------------------------------------------------------------------
variable "enable_vpc_flow_logs" {
  description = "VPC Flow Logs (CloudWatch Logs 송출) 활성. 침해사고 추적·트래픽 audit 용. 비용은 ingest GB."
  type        = bool
  default     = false
}

variable "flow_logs_retention_days" {
  description = "VPC Flow Logs CloudWatch retention(일). prod 권장 30~90일."
  type        = number
  default     = 30
}

variable "enable_cloudtrail" {
  description = "본 계정 region CloudTrail trail 생성. 조직 trail 이 이미 있으면 false 유지."
  type        = bool
  default     = false
}

variable "cloudtrail_bucket_name" {
  description = "CloudTrail 로그 적재 S3 버킷. 비우면 iconia-<env>-cloudtrail-<account_id> 자동 생성."
  type        = string
  default     = ""
}

variable "cloudtrail_retention_days" {
  description = "CloudTrail S3 lifecycle expire(일). 한국 PIPA 권장 1~3년, audit 표준 365일."
  type        = number
  default     = 365
}

variable "enable_aws_config" {
  description = "AWS Config recorder + delivery channel 생성. Conformance Pack rule 은 별도 라운드."
  type        = bool
  default     = false
}

variable "enable_guardduty" {
  description = "GuardDuty detector 활성. 30일 trial 후 GB 단위 과금."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# 1) VPC Flow Logs — CloudWatch Logs.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  count             = var.enable_vpc_flow_logs && var.create_network ? 1 : 0
  name              = "/iconia/${var.env}/vpc-flow-logs"
  retention_in_days = var.flow_logs_retention_days
  tags              = merge(var.tags, { component = "security", purpose = "vpc-flow-logs" })
}

data "aws_iam_policy_document" "vpc_flow_logs_assume" {
  count = var.enable_vpc_flow_logs && var.create_network ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vpc_flow_logs" {
  count              = var.enable_vpc_flow_logs && var.create_network ? 1 : 0
  name               = "${local.name_prefix}-vpc-flow-logs-role"
  assume_role_policy = data.aws_iam_policy_document.vpc_flow_logs_assume[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "vpc_flow_logs_inline" {
  count = var.enable_vpc_flow_logs && var.create_network ? 1 : 0

  statement {
    sid = "VpcFlowLogsAppend"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = [
      "${aws_cloudwatch_log_group.vpc_flow_logs[0].arn}:*",
    ]
  }
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  count  = var.enable_vpc_flow_logs && var.create_network ? 1 : 0
  name   = "${local.name_prefix}-vpc-flow-logs-inline"
  role   = aws_iam_role.vpc_flow_logs[0].id
  policy = data.aws_iam_policy_document.vpc_flow_logs_inline[0].json
}

resource "aws_flow_log" "vpc" {
  count                    = var.enable_vpc_flow_logs && var.create_network ? 1 : 0
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.vpc_flow_logs[0].arn
  iam_role_arn             = aws_iam_role.vpc_flow_logs[0].arn
  traffic_type             = "ALL"
  vpc_id                   = aws_vpc.main[0].id
  max_aggregation_interval = 60

  tags = merge(var.tags, { component = "security", Name = "${local.name_prefix}-vpc-flow-logs" })
}

# -----------------------------------------------------------------------------
# 2) CloudTrail — region trail (multi-region 옵션은 organization trail 권장).
# -----------------------------------------------------------------------------
locals {
  cloudtrail_bucket_effective = (
    var.cloudtrail_bucket_name != ""
    ? var.cloudtrail_bucket_name
    : "${local.name_prefix}-cloudtrail-${local.account_id}"
  )
}

resource "aws_s3_bucket" "cloudtrail" {
  count         = var.enable_cloudtrail && var.cloudtrail_bucket_name == "" ? 1 : 0
  bucket        = local.cloudtrail_bucket_effective
  force_destroy = false # audit 로그 보존.
  tags          = merge(var.tags, { component = "security", purpose = "cloudtrail" })
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  count                   = var.enable_cloudtrail && var.cloudtrail_bucket_name == "" ? 1 : 0
  bucket                  = aws_s3_bucket.cloudtrail[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  count  = var.enable_cloudtrail && var.cloudtrail_bucket_name == "" ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  count  = var.enable_cloudtrail && var.cloudtrail_bucket_name == "" ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  count  = var.enable_cloudtrail && var.cloudtrail_bucket_name == "" ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id

  rule {
    id     = "cloudtrail-archive-then-expire"
    status = "Enabled"
    filter { prefix = "" }
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    expiration { days = var.cloudtrail_retention_days }
    noncurrent_version_expiration { noncurrent_days = 30 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

# CloudTrail 가 본 버킷에 PutObject 할 수 있도록 bucket policy.
data "aws_iam_policy_document" "cloudtrail_bucket" {
  count = var.enable_cloudtrail && var.cloudtrail_bucket_name == "" ? 1 : 0

  statement {
    sid     = "AWSCloudTrailAclCheck"
    effect  = "Allow"
    actions = ["s3:GetBucketAcl"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    resources = [aws_s3_bucket.cloudtrail[0].arn]
  }

  statement {
    sid     = "AWSCloudTrailWrite"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    resources = ["${aws_s3_bucket.cloudtrail[0].arn}/AWSLogs/${local.account_id}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  # HTTPS 강제 (다른 버킷과 동일).
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    resources = [
      aws_s3_bucket.cloudtrail[0].arn,
      "${aws_s3_bucket.cloudtrail[0].arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  count  = var.enable_cloudtrail && var.cloudtrail_bucket_name == "" ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id
  policy = data.aws_iam_policy_document.cloudtrail_bucket[0].json
}

resource "aws_cloudtrail" "iconia" {
  count                         = var.enable_cloudtrail ? 1 : 0
  name                          = "${local.name_prefix}-trail"
  s3_bucket_name                = local.cloudtrail_bucket_effective
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  tags                          = merge(var.tags, { component = "security" })

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# -----------------------------------------------------------------------------
# 3) AWS Config — recorder + delivery channel (rule 없음).
#    rule 은 conformance pack 또는 organization config 로 별도 적용.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "aws_config" {
  count         = var.enable_aws_config ? 1 : 0
  bucket        = "${local.name_prefix}-aws-config-${local.account_id}"
  force_destroy = false
  tags          = merge(var.tags, { component = "security", purpose = "aws-config" })
}

resource "aws_s3_bucket_public_access_block" "aws_config" {
  count                   = var.enable_aws_config ? 1 : 0
  bucket                  = aws_s3_bucket.aws_config[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "aws_config" {
  count  = var.enable_aws_config ? 1 : 0
  bucket = aws_s3_bucket.aws_config[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "aws_config_assume" {
  count = var.enable_aws_config ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "aws_config" {
  count              = var.enable_aws_config ? 1 : 0
  name               = "${local.name_prefix}-aws-config-role"
  assume_role_policy = data.aws_iam_policy_document.aws_config_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "aws_config_managed" {
  count      = var.enable_aws_config ? 1 : 0
  role       = aws_iam_role.aws_config[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

data "aws_iam_policy_document" "aws_config_s3" {
  count = var.enable_aws_config ? 1 : 0

  statement {
    sid       = "AllowConfigS3Put"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.aws_config[0].arn}/AWSLogs/${local.account_id}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    sid       = "AllowConfigS3GetBucketAcl"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.aws_config[0].arn]
  }
}

resource "aws_iam_role_policy" "aws_config_s3" {
  count  = var.enable_aws_config ? 1 : 0
  name   = "${local.name_prefix}-aws-config-s3"
  role   = aws_iam_role.aws_config[0].id
  policy = data.aws_iam_policy_document.aws_config_s3[0].json
}

resource "aws_config_configuration_recorder" "iconia" {
  count    = var.enable_aws_config ? 1 : 0
  name     = "${local.name_prefix}-config-recorder"
  role_arn = aws_iam_role.aws_config[0].arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "iconia" {
  count          = var.enable_aws_config ? 1 : 0
  name           = "${local.name_prefix}-config-delivery"
  s3_bucket_name = aws_s3_bucket.aws_config[0].bucket
  depends_on     = [aws_config_configuration_recorder.iconia]
}

resource "aws_config_configuration_recorder_status" "iconia" {
  count      = var.enable_aws_config ? 1 : 0
  name       = aws_config_configuration_recorder.iconia[0].name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.iconia]
}

# -----------------------------------------------------------------------------
# 4) GuardDuty — detector + findings → CloudWatch Alarm.
# -----------------------------------------------------------------------------
resource "aws_guardduty_detector" "iconia" {
  count                        = var.enable_guardduty ? 1 : 0
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  tags                         = merge(var.tags, { component = "security" })
}

variable "guardduty_high_findings_threshold" {
  description = "GuardDuty HIGH/CRITICAL severity findings 수 임계 (1시간). 초과 시 SNS alert."
  type        = number
  default     = 1
}

resource "aws_cloudwatch_metric_alarm" "guardduty_high_findings" {
  count               = var.enable_guardduty ? 1 : 0
  alarm_name          = "${local.name_prefix}-guardduty-high-findings"
  alarm_description   = "[SECURITY] GuardDuty HIGH/CRITICAL findings >= ${var.guardduty_high_findings_threshold} (1h). 즉시 조사 필요."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = var.guardduty_high_findings_threshold
  metric_name         = "FindingCount"
  namespace           = "AWS/GuardDuty"
  period              = 3600
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DetectorId = aws_guardduty_detector.iconia[0].id
    Severity   = "HIGH"
  }

  tags = merge(var.tags, { component = "security", purpose = "guardduty-alert" })
}

# -----------------------------------------------------------------------------
# Outputs.
# -----------------------------------------------------------------------------
output "vpc_flow_logs_log_group" {
  description = "VPC Flow Logs CloudWatch Log Group 이름. enable_vpc_flow_logs=true 시에만 비어있지 않음."
  value       = length(aws_cloudwatch_log_group.vpc_flow_logs) > 0 ? aws_cloudwatch_log_group.vpc_flow_logs[0].name : ""
}

output "cloudtrail_name" {
  description = "CloudTrail trail 이름. enable_cloudtrail=true 시에만 비어있지 않음."
  value       = length(aws_cloudtrail.iconia) > 0 ? aws_cloudtrail.iconia[0].name : ""
}

output "cloudtrail_bucket_name" {
  description = "CloudTrail 로그 적재 S3 버킷 이름."
  value       = var.enable_cloudtrail ? local.cloudtrail_bucket_effective : ""
}

output "aws_config_recorder_name" {
  description = "AWS Config recorder 이름."
  value       = length(aws_config_configuration_recorder.iconia) > 0 ? aws_config_configuration_recorder.iconia[0].name : ""
}

output "guardduty_detector_id" {
  description = "GuardDuty detector ID."
  value       = length(aws_guardduty_detector.iconia) > 0 ? aws_guardduty_detector.iconia[0].id : ""
}
