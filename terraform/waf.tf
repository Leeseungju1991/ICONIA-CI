###############################################################################
# waf.tf — ALB WAFv2 (Regional).
#
# Rules (우선순위 순):
#   1) rate-limit-ip-5min     : IP 당 5분 2000req 초과 → BLOCK 429
#   2) AWSManagedRulesCommonRuleSet (CRS)   : BLOCK (SizeRestrictions_BODY=COUNT)
#   3) AWSManagedRulesKnownBadInputsRuleSet : BLOCK
#   4) AWSManagedRulesSQLiRuleSet           : BLOCK
#   5) AWSManagedRulesAmazonIpReputationList: BLOCK
#
# 토글: var.enable_waf (tfvars 에서 true 설정 필요).
# 비용: Web ACL $5 + Rule $5 + 요청 $0.60/1M (ap-northeast-2).
###############################################################################

variable "enable_waf" {
  description = "WAFv2 Web ACL 활성화 토글. true 로 변경 후 terraform apply 로 실 적용."
  type        = bool
  default     = false
}

variable "waf_rate_limit_5min" {
  description = "5분 윈도우당 IP 요청 제한 (초과 시 차단). 기본 2000 (분당 ~400)."
  type        = number
  default     = 2000
}

# -----------------------------------------------------------------------------
# 1) Regional Web ACL — ALB 앞단 (서비스 백엔드 보호)
# -----------------------------------------------------------------------------
resource "aws_wafv2_web_acl" "alb_regional" {
  count       = var.enable_waf ? 1 : 0
  name        = "${local.name_prefix}-alb-regional-acl"
  description = "ICONIA ALB WAF — rate-limit + AWS Managed Core/SQLi/KnownBad."
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # --- Rule 1: Rate-based (IP 별 5분 윈도우) ---
  rule {
    name     = "rate-limit-ip-5min"
    priority = 1

    action {
      block {
        custom_response {
          response_code = 429
        }
      }
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-ip-5min"
    }
  }

  # --- Rule 2: AWS Managed Core Rule Set ---
  rule {
    name     = "AWS-ManagedRulesCommonRuleSet"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "AWS-ManagedRulesCommonRuleSet"
    }
  }

  # --- Rule 3: AWS Managed Known Bad Inputs ---
  rule {
    name     = "AWS-ManagedRulesKnownBadInputsRuleSet"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "AWS-ManagedRulesKnownBadInputsRuleSet"
    }
  }

  # --- Rule 4: AWS Managed SQLi ---
  rule {
    name     = "AWS-ManagedRulesSQLiRuleSet"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesSQLiRuleSet"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "AWS-ManagedRulesSQLiRuleSet"
    }
  }

  # --- Rule 5: AWS Managed Amazon IP Reputation ---
  rule {
    name     = "AWS-ManagedRulesAmazonIpReputationList"
    priority = 40

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "AWS-ManagedRulesAmazonIpReputationList"
    }
  }

  visibility_config {
    sampled_requests_enabled   = true
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-alb-regional-acl"
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-alb-regional-acl"
  })
}

# Web ACL → ALB 연결.
resource "aws_wafv2_web_acl_association" "alb" {
  count        = var.enable_waf ? 1 : 0
  resource_arn = aws_lb.iconia.arn
  web_acl_arn  = aws_wafv2_web_acl.alb_regional[0].arn
}

# -----------------------------------------------------------------------------
# 2) (선택) CloudFront 분배 보호 — global scope WAF 는 us-east-1 provider 필요.
#    CF 분배 ADMIN(d7gw1fdjnkghz) 보호는 별도 us-east-1 provider alias 가
#    필요해 본 라운드에선 scaffold 만 제공.
# -----------------------------------------------------------------------------
# resource "aws_wafv2_web_acl" "cloudfront_global" {
#   provider = aws.us_east_1
#   ...
# }

# -----------------------------------------------------------------------------
# CloudWatch Alarm — WAF 차단 폭증 감지.
#   5분 윈도우에 100건 이상 BLOCK 발생 시 알람.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "waf_block_spike" {
  count               = var.enable_waf ? 1 : 0
  alarm_name          = "${local.name_prefix}-waf-block-spike"
  alarm_description   = "WAFv2 BLOCK 응답이 5분 100건 초과. DDoS 또는 오탐 점검 필요."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 100
  metric_name         = "BlockedRequests"
  namespace           = "AWS/WAFV2"
  period              = 300
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = aws_wafv2_web_acl.alb_regional[0].name
    Region = var.region
    Rule   = "ALL"
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-waf-block-spike"
  })
}

output "waf_alb_acl_id" {
  description = "ALB Regional WAFv2 Web ACL ID (enable_waf=true 시 생성)."
  value       = var.enable_waf ? aws_wafv2_web_acl.alb_regional[0].id : null
}
