###############################################################################
# budgets.tf — Phase 8 #18.
#
# AWS Budgets 는 AWS 서비스(EC2/S3/EFS/...) 비용을 추적한다. Gemini API 같은 외부
# SaaS 비용은 못 본다 → 별도 CloudWatch alarm (alarms.tf 의 iconia_ai_cost_*)
# 으로 보강한다.
#
# 본 파일은:
#   1) AWS 월간 비용 budget (한도 = var.monthly_budget_usd, 기본 500 USD).
#      threshold 50% / 80% / 100% 도달 시 SNS topic 으로 알림.
#   2) Budgets 전용 SNS topic 생성 + email/Slack(SNS https) subscription.
#      이미 있는 alarms.tf 의 SNS topic 과 분리 — Budgets 알림과 운영 alarm 의
#      라우팅을 분리해야 PagerDuty noise 가 안 섞인다.
#
# 적용:
#   terraform apply -var "monthly_budget_usd=500" \
#                   -var "budgets_alert_email=billing@example.com"
#
# 주의 (가드레일):
#   - Budgets 자체는 액션을 못 멈춘다 (notification 만). 강제 차단은 Server
#     quotaStore.shouldForceFlash 가 처리 (Phase 8 #28).
#   - threshold 100% 도달 시 운영 자동 대응은 별도 runbook (인스턴스 다운/quota 강제 등).
#     실 운영 자동화는 사용자가 별도 라운드에서 결정.
###############################################################################

# -----------------------------------------------------------------------------
# 변수.
# -----------------------------------------------------------------------------
variable "monthly_budget_usd" {
  description = "월간 AWS 비용 한도 (USD). 50/80/100% 도달 시 SNS 알림."
  type        = number
  default     = 500
}

variable "budgets_alert_email" {
  description = "AWS Budgets 알림용 이메일. 비우면 email subscription 생성 안 함."
  type        = string
  default     = ""
}

variable "budgets_alert_slack_webhook_url" {
  description = "AWS Budgets 알림용 Slack incoming webhook (https). 비우면 subscription 생성 안 함."
  type        = string
  default     = ""
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Budgets 전용 SNS topic.
#   - alarms.tf 의 운영 SNS 와 분리 — Budgets 는 billing alert 채널.
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "budgets" {
  name              = "${local.name_prefix}-budgets-alerts"
  display_name      = "ICONIA AWS Budgets Alerts"
  kms_master_key_id = "alias/aws/sns"
  tags              = merge(var.tags, { purpose = "aws-budgets-notifications" })
}

resource "aws_sns_topic_subscription" "budgets_email" {
  count     = var.budgets_alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.budgets.arn
  protocol  = "email"
  endpoint  = var.budgets_alert_email
}

# Slack 라우팅 — AWS Chatbot 또는 SNS→Lambda→Slack webhook 패턴.
# 본 IaC 는 https subscription 만 등록 (Lambda forwarder 는 별도 라운드에서).
# webhook URL 직접 노출 위험을 의식 — 운영자가 Chatbot 권장 시 본 subscription 은 빈 채로 두고
# Chatbot 의 SNS attach 만 별도로 한다.
resource "aws_sns_topic_subscription" "budgets_slack" {
  count                  = var.budgets_alert_slack_webhook_url == "" ? 0 : 1
  topic_arn              = aws_sns_topic.budgets.arn
  protocol               = "https"
  endpoint               = var.budgets_alert_slack_webhook_url
  endpoint_auto_confirms = true
}

# -----------------------------------------------------------------------------
# AWS 월간 비용 Budget — 50 / 80 / 100% threshold 알림.
# -----------------------------------------------------------------------------
resource "aws_budgets_budget" "iconia_monthly_usd" {
  name              = "${local.name_prefix}-monthly-usd"
  budget_type       = "COST"
  limit_amount      = tostring(var.monthly_budget_usd)
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-01-01_00:00"

  cost_types {
    include_credit             = false
    include_discount           = true
    include_other_subscription = true
    include_recurring          = true
    include_refund             = false
    include_subscription       = true
    include_support            = true
    include_tax                = true
    include_upfront            = true
    use_amortized              = false
    use_blended                = false
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 50
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budgets.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budgets.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budgets.arn]
  }

  # FORECASTED — 월 예측치 기준. ACTUAL 도달 전에 선제 알림.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.budgets.arn]
  }

  tags = merge(var.tags, { purpose = "monthly-budget-aws" })
}

# -----------------------------------------------------------------------------
# Budgets 가 SNS topic 에 publish 하려면 topic policy 가 필요하다.
# -----------------------------------------------------------------------------
resource "aws_sns_topic_policy" "budgets_publish_policy" {
  arn = aws_sns_topic.budgets.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowBudgetsPublish"
        Effect    = "Allow"
        Principal = { Service = "budgets.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.budgets.arn
      },
    ]
  })
}

output "budgets_sns_topic_arn" {
  description = "AWS Budgets 알림 라우팅 SNS topic ARN."
  value       = aws_sns_topic.budgets.arn
}

output "budgets_monthly_budget_name" {
  description = "월간 USD budget 이름 (콘솔 검색용)."
  value       = aws_budgets_budget.iconia_monthly_usd.name
}
