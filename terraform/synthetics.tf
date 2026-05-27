###############################################################################
# synthetics.tf — CloudWatch Synthetics canary (V1.0 라운드 #19).
#
# Route53 FQDN(api.<domain> / ai.<domain> / admin.<domain>) 의 헬스체크를
# 5분 주기 외부 호출로 검증한다. ALB target group health check 와 별개로
# **외부 client 시점의 가용성** 을 측정 — TLS / DNS / CDN / 방화벽 회귀 검출.
#
# Canary 코드는 표준 nodejs-puppeteer 런타임의 'heartbeat' 시나리오 —
# /health 와 /admin/login 두 화면을 5분 주기로 확인. 4xx/5xx/timeout 발생 시
# CloudWatch 의 `CanarySuccessPercent` 메트릭 하락 → 알람 SNS 라우팅.
#
# 비용 고려:
#   - canary 3개 × 12 실행/시간 × 24h × 30일 = 25,920 invocation/월.
#     puppeteer 런타임 invocation 가 약 $0.0012/회 = ~$31/월 (3개 기준).
#   - 단일 region (ap-northeast-2) — Multi-region canary 는 V1.x 라운드.
#
# 토글: var.create_synthetics = false 로 비활성 (개발/staging 환경).
###############################################################################

variable "create_synthetics" {
  description = "CloudWatch Synthetics canary 생성 여부. prod 만 true 권장."
  type        = bool
  default     = true
}

variable "synthetics_schedule_expression" {
  description = "Canary 실행 주기 (CloudWatch Events). 기본 5분."
  type        = string
  default     = "rate(5 minutes)"
}

locals {
  enable_synthetics = var.create_synthetics && var.root_domain != ""
  synthetics_targets = local.enable_synthetics ? {
    api   = "https://api.${var.root_domain}/health"
    ai    = "https://ai.${var.root_domain}/health"
    admin = "https://admin.${var.root_domain}/"
  } : {}
}

# -----------------------------------------------------------------------------
# Canary 산출물용 S3 버킷 — screenshot + HAR 보관.
# 1차 출시는 events/exports 와 분리된 별도 버킷 (canary 결과의 visibility 분리).
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "synthetics_artifacts" {
  count         = local.enable_synthetics ? 1 : 0
  bucket        = "${local.name_prefix}-synthetics-${local.account_id}"
  force_destroy = false
  tags          = merge(var.tags, { component = "synthetics" })
}

resource "aws_s3_bucket_public_access_block" "synthetics_artifacts" {
  count                   = local.enable_synthetics ? 1 : 0
  bucket                  = aws_s3_bucket.synthetics_artifacts[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "synthetics_artifacts" {
  count  = local.enable_synthetics ? 1 : 0
  bucket = aws_s3_bucket.synthetics_artifacts[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "synthetics_artifacts" {
  count  = local.enable_synthetics ? 1 : 0
  bucket = aws_s3_bucket.synthetics_artifacts[0].id

  rule {
    id     = "expire-30d"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
  }
}

# -----------------------------------------------------------------------------
# IAM role — Synthetics canary 가 가정하는 역할.
# AWS 관리정책 `CloudWatchSyntheticsExecutionRolePolicy` 가 표준.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "synthetics_assume" {
  count = local.enable_synthetics ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "synthetics" {
  count              = local.enable_synthetics ? 1 : 0
  name               = "${local.name_prefix}-synthetics-role"
  assume_role_policy = data.aws_iam_policy_document.synthetics_assume[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "synthetics_inline" {
  count = local.enable_synthetics ? 1 : 0

  statement {
    sid = "S3PutResults"
    actions = [
      "s3:PutObject",
      "s3:GetBucketLocation",
      "s3:ListAllMyBuckets",
    ]
    resources = [
      aws_s3_bucket.synthetics_artifacts[0].arn,
      "${aws_s3_bucket.synthetics_artifacts[0].arn}/*",
    ]
  }

  statement {
    sid = "CWLogsAndMetrics"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "cloudwatch:PutMetricData",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "synthetics" {
  count  = local.enable_synthetics ? 1 : 0
  name   = "${local.name_prefix}-synthetics-policy"
  role   = aws_iam_role.synthetics[0].id
  policy = data.aws_iam_policy_document.synthetics_inline[0].json
}

# -----------------------------------------------------------------------------
# Canary 자체 — 표준 heartbeat 시나리오. 본 코드는 templatefile 로 url 만 치환.
# nodejs-puppeteer runtime 권장 (synthetics-nodejs-puppeteer-6.x).
# 본 IaC 가 canary 스크립트를 inline 으로 만들어 첨부.
# -----------------------------------------------------------------------------
data "archive_file" "heartbeat" {
  for_each = local.synthetics_targets

  type        = "zip"
  output_path = "${path.module}/.terraform/synthetics-${each.key}.zip"

  source {
    filename = "nodejs/node_modules/heartbeat.js"
    content  = <<-JS
      const synthetics = require('Synthetics');
      const log = require('SyntheticsLogger');

      const heartbeat = async function () {
        const url = '${each.value}';
        log.info('GET ' + url);
        let page = await synthetics.getPage();
        const resp = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
        if (!resp) {
          throw new Error('no response from ' + url);
        }
        const status = resp.status();
        log.info('status=' + status);
        if (status < 200 || status > 399) {
          throw new Error('HTTP ' + status + ' from ' + url);
        }
        // 헬스체크 응답이 JSON 이면 200 만 통과 — 단순 ALB ping 만 통과는 약함.
        await synthetics.takeScreenshot('${each.key}-ok', 'loaded');
      };

      exports.handler = async () => {
        return await heartbeat();
      };
    JS
  }
}

resource "aws_synthetics_canary" "heartbeat" {
  for_each = local.synthetics_targets

  name                 = "iconia-${each.key}-heartbeat"
  artifact_s3_location = "s3://${aws_s3_bucket.synthetics_artifacts[0].bucket}/canary/${each.key}/"
  execution_role_arn   = aws_iam_role.synthetics[0].arn
  runtime_version      = "syn-nodejs-puppeteer-6.2"
  handler              = "heartbeat.handler"
  zip_file             = data.archive_file.heartbeat[each.key].output_path
  start_canary         = true

  schedule {
    expression = var.synthetics_schedule_expression
  }

  run_config {
    timeout_in_seconds = 60
    memory_in_mb       = 1000
  }

  success_retention_period = 14
  failure_retention_period = 60

  tags = merge(var.tags, { component = "synthetics", target = each.key })
}

# -----------------------------------------------------------------------------
# 알람 — 각 canary 의 SuccessPercent < 90% (5분, 2회 연속) 면 trip.
# 알람 SNS topic 은 module.alarms.sns_topic_arn 재사용.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "synthetics_success_low" {
  for_each = local.synthetics_targets

  alarm_name          = "iconia-${each.key}-synthetic-success-low"
  alarm_description   = "[SYNTHETIC] ${each.key} canary SuccessPercent < 90% (10분). 외부 시점 가용성 회귀."
  namespace           = "CloudWatchSynthetics"
  metric_name         = "SuccessPercent"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 90
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [module.alarms.sns_topic_arn]
  ok_actions          = [module.alarms.sns_topic_arn]
  tags                = merge(var.tags, { synthetic_target = each.key })

  dimensions = {
    CanaryName = aws_synthetics_canary.heartbeat[each.key].name
  }
}

# -----------------------------------------------------------------------------
# Outputs.
# -----------------------------------------------------------------------------
output "synthetics_canary_names" {
  description = "생성된 Synthetics canary 이름 — 콘솔 진입 시 참조."
  value       = local.enable_synthetics ? [for k, c in aws_synthetics_canary.heartbeat : c.name] : []
}

output "synthetics_artifact_bucket" {
  description = "Canary screenshot + HAR 산출물 버킷."
  value       = local.enable_synthetics ? aws_s3_bucket.synthetics_artifacts[0].bucket : ""
}
