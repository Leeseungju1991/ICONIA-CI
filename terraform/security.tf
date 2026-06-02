###############################################################################
# security.tf — V1.0 정식 출시 보안 베이스라인 (감사·추적·관측).
#
# 본 파일은 ICONIA V1.0 출시 시점에 "권장" 되는 4종 AWS 보안 서비스의 IaC
# 정의를 모은다. 운영 비용/계정 정책 영향이 있어 **기본값 모두 false** —
# 운영자가 명시적으로 토글:
#
#   1) VPC Flow Logs       (var.enable_vpc_flow_logs)
#      - VPC 진입/이탈 트래픽을 CloudWatch Logs 로 송출. 침해 사고 시
#        타임라인 재구성에 필수. 비용은 GB 단위 ingest fee.
#   2) CloudTrail (org/account trail) (var.enable_cloudtrail)
#      - IAM/콘솔/API 모든 변경 추적. 90일/감사 365일 표준.
#   3) AWS Config             (var.enable_aws_config)
#      - 리소스 변경 이력 + Conformance Pack(PCI/CIS). 운영 부담 큼 →
#        본 IaC 는 *recorder* + *delivery channel* 만 만들고 rule 은 별도.
#   4) GuardDuty              (var.enable_guardduty)
#      - 위협 탐지. 30일 무료 트라이얼 후 GB 기반 과금.
#
# Security Hub 는 GuardDuty/Config 통합 콘솔. CIS/PCI 자동평가가 필요한 경우
# 별도 라운드에서 활성. 본 IaC 는 미포함.
#
# 안전 설계:
#   - 모든 리소스 count=var.enable_* ? 1 : 0. 토글 OFF 면 plan diff 0.
#   - flow log 의 CW log group retention 은 var.flow_logs_retention_days (기본 30).
#   - CloudTrail S3 버킷은 별도 (var.cloudtrail_bucket_name 비우면 자동 생성).
#     기존 organization trail 이 있다면 enable_cloudtrail=false 로 두고 중복 회피.
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
  is_multi_region_trail         = false # multi-region/org trail 은 별도.
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
# 4) GuardDuty — detector. findings 는 자동으로 EventBridge 로 흐름.
# -----------------------------------------------------------------------------
resource "aws_guardduty_detector" "iconia" {
  count                        = var.enable_guardduty ? 1 : 0
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  tags                         = merge(var.tags, { component = "security" })
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
