###############################################################################
# observability.tf — 모니터링 가시성 IaC (README §4.1 / §4.6 흡수).
#
# 본 파일은 그동안 deploy/aws/*.json 의 "CLI 정본" 으로만 존재하던 운영 가시성
# 리소스를 Terraform 단일 정본으로 흡수한다. 흡수 대상:
#
#   §4.1  CloudWatch Logs metric filter (PII 누출 감시)
#         ← deploy/aws/cloudwatch-log-metric-filters.json
#   §4.1  CloudWatch Agent config 의 SSM Parameter Store push
#         ← deploy/aws/cloudwatch-agent-config.json
#   §4.6  CloudWatch Dashboard (Server 5xx / AI p95 / Push / RDS / Host 단일 보드)
#   §4.6  CloudWatch Logs Insights saved query (PII / RAG 실패 / refresh reuse 등)
#
# 모든 리소스는 main stack 의 `terraform apply` 한 번으로 생성된다 (별도 init/apply
# 불필요). log group 자체는 CloudWatch Agent 가 첫 송출 시 자동 생성하지만,
# metric filter / retention 을 IaC 가 책임지도록 본 파일이 log group 도 선언한다.
###############################################################################

# -----------------------------------------------------------------------------
# 0) CloudWatch Log Group — Agent 가 송출하는 8개 로그그룹을 IaC 로 선언.
#    cloudwatch-agent-config.json 의 collect_list 와 1:1. retention 도 그쪽
#    retention_in_days 와 정합. log group 을 IaC 가 소유해야 metric filter 의
#    log_group_name 참조가 깨지지 않고, retention 도 drift 없이 유지된다.
# -----------------------------------------------------------------------------
locals {
  # log group 이름 → retention(일). cloudwatch-agent-config.json 정본과 동기.
  log_groups = {
    server       = { name = "/iconia/${var.env}/server", retention = 30 }
    ai           = { name = "/iconia/${var.env}/ai", retention = 30 }
    admin        = { name = "/iconia/${var.env}/admin", retention = 14 }
    nginx_access = { name = "/iconia/${var.env}/nginx-access", retention = 30 }
    nginx_error  = { name = "/iconia/${var.env}/nginx-error", retention = 60 }
    deploy       = { name = "/iconia/${var.env}/deploy", retention = 90 }
    audit        = { name = "/iconia/${var.env}/audit", retention = 365 }
  }
}

resource "aws_cloudwatch_log_group" "iconia" {
  for_each          = var.create_log_groups ? local.log_groups : {}
  name              = each.value.name
  retention_in_days = each.value.retention
  tags              = merge(var.tags, { component = "observability" })
}

# -----------------------------------------------------------------------------
# 1) CloudWatch Agent config 를 SSM Parameter Store 에 push (README §4.1).
#
#    EC2 user-data 의 `amazon-cloudwatch-agent-ctl -a fetch-config
#    -c ssm:<parameter-name>` 가 본 파라미터를 읽는다. 그동안은 운영자가 수동으로
#    JSON 을 SSM 에 넣어야 했고 (cloudwatch-agent-config.json 의 _comment 참고),
#    이 수동 단계가 자주 누락됐다. 본 리소스가 `terraform apply` 에 흡수한다.
#
#    파라미터 이름은 CloudWatch Agent 관례인 `AmazonCloudWatch-` prefix 를 따른다.
#    JSON 안의 ${env} placeholder 는 templatefile 로 실제 env 로 치환한다.
# -----------------------------------------------------------------------------
resource "aws_ssm_parameter" "cloudwatch_agent_config" {
  name        = "/AmazonCloudWatch-iconia-${var.env}"
  description = "ICONIA CloudWatch Agent fetch-config 정본 (terraform 관리). EC2 가 amazon-cloudwatch-agent-ctl -a fetch-config -c ssm:<name> 로 적용."
  type        = "String"
  tier        = "Standard"

  # cloudwatch-agent-config.json 의 ${env} 토큰을 실제 env 로 치환.
  # JSON 은 deploy/aws/cloudwatch-agent-config.json 이 정본 — 본 리소스는 그것을
  # 그대로 읽어 SSM 에 싣기만 한다 (이중 정본 방지).
  value = replace(
    file("${path.module}/../deploy/aws/cloudwatch-agent-config.json"),
    "$${env}",
    var.env,
  )

  tags = merge(var.tags, { component = "observability" })
}

# -----------------------------------------------------------------------------
# 2) CloudWatch Logs metric filter — PII 누출 감시 (README §4.1).
#
#    그동안 deploy/aws/cloudwatch-log-metric-filters.json 의 CLI 정본으로만
#    존재. 본 리소스가 Terraform 단일 정본으로 흡수한다.
#
#    원본 JSON 의 logGroupName 은 "/iconia/server" (env 없는 구버전 경로) 였으나,
#    본 IaC 는 cloudwatch-agent-config.json / iam.tf 와 정합되도록
#    "/iconia/${env}/server" 경로로 통일한다.
#
#    4개 패턴(email / KR phone / Bearer·api-key / WiFi PSK)을 ICONIA/Audit
#    namespace 의 metric 으로 송출 → alarms.tf 가 해당 metric 으로 알람.
# -----------------------------------------------------------------------------
locals {
  # filter_name → { 패턴, metric 이름 }. cloudwatch-log-metric-filters.json 정본.
  pii_metric_filters = {
    email = {
      pattern     = "%[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}%"
      metric_name = "PIIEmailInLogs"
    }
    phone_kr = {
      pattern     = "%(010|011|016|017|018|019)[0-9]{7,8}%"
      metric_name = "PIIPhoneInLogs"
    }
    secret_bearer = {
      pattern     = "%(Bearer\\s+[A-Za-z0-9_\\-]{40,}|x-api-key:\\s*[A-Za-z0-9_\\-]{20,})%"
      metric_name = "SecretLikeStringInLogs"
    }
    wifi_psk = {
      pattern     = "%(psk|password|passphrase)\\s*[:=]\\s*[^\\s]{6,}%"
      metric_name = "WiFiPskInLogs"
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "pii_leak" {
  for_each = var.create_log_groups ? local.pii_metric_filters : {}

  name           = "iconia-pii-${each.key}-leak"
  log_group_name = aws_cloudwatch_log_group.iconia["server"].name
  pattern        = each.value.pattern

  metric_transformation {
    name          = each.value.metric_name
    namespace     = var.alarm_audit_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# -----------------------------------------------------------------------------
# 3) CloudWatch Dashboard — 단일 운영 보드 (README §4.6).
#
#    Server 5xx / AI p95 latency / Push delivery / RDS CPU·메모리 / Host CPU·메모리
#    를 한 화면으로. 운영자가 콘솔 진입 즉시 시스템 상태를 본다.
#
#    위젯은 metric 이 실제 송출돼야 데이터가 차지만, 위젯/보드 자체는 metric
#    부재와 무관하게 생성된다 (= apply 가 metric 존재에 의존하지 않음).
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "iconia_ops" {
  count          = var.create_dashboard ? 1 : 0
  dashboard_name = "iconia-${var.env}-ops"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 1
        properties = {
          markdown = "# ICONIA ${var.env} 운영 대시보드 — Server / AI / Push / RDS / Host"
        }
      },
      # --- Server 5xx 비율 (alb_arn_suffix 주입 시 데이터) ---
      {
        type   = "metric"
        x      = 0
        y      = 1
        width  = 12
        height = 6
        properties = {
          title  = "Server 5xx 비율 (%)"
          region = var.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            [{
              expression = "100 * (m5xx / IF(mreq > 0, mreq, 1))"
              label      = "5xx_rate_percent"
              id         = "e1"
            }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alarm_alb_arn_suffix, { id = "m5xx", visible = false }],
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alarm_alb_arn_suffix, { id = "mreq", visible = false }],
          ]
          yAxis = { left = { min = 0, max = 100 } }
        }
      },
      # --- AI 호출 p95 latency ---
      {
        type   = "metric"
        x      = 12
        y      = 1
        width  = 12
        height = 6
        properties = {
          title  = "AI 호출 p95 latency (ms)"
          region = var.region
          view   = "timeSeries"
          period = 300
          metrics = [
            [var.alarm_cloudwatch_namespace, "AiCallLatencyMs", { stat = "p95", label = "p95" }],
            [var.alarm_cloudwatch_namespace, "AiCallLatencyMs", { stat = "p50", label = "p50" }],
          ]
          annotations = { horizontal = [{ label = "p95 알람 임계 8s", value = 8000 }] }
        }
      },
      # --- Push delivery / token invalidated ---
      {
        type   = "metric"
        x      = 0
        y      = 7
        width  = 12
        height = 6
        properties = {
          title  = "Push 전송 / 토큰 무효화"
          region = var.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["ICONIA/Push", "PushDelivered", { label = "전송 성공" }],
            ["ICONIA/Push", "PushFailed", { label = "전송 실패" }],
            ["ICONIA/Push", "PushTokenInvalidated", { label = "토큰 무효화" }],
          ]
        }
      },
      # --- RDS CPU / FreeableMemory ---
      {
        type   = "metric"
        x      = 12
        y      = 7
        width  = 12
        height = 6
        properties = {
          title  = "RDS CPU(%) / FreeableMemory(MB)"
          region = var.region
          view   = "timeSeries"
          period = 300
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "${local.name_prefix}-db", { stat = "Average", label = "CPU %" }],
            [{
              expression = "freemem / 1048576"
              label      = "FreeableMemory MB"
              id         = "fm"
              yAxis      = "right"
            }],
            ["AWS/RDS", "FreeableMemory", "DBInstanceIdentifier", "${local.name_prefix}-db", { id = "freemem", stat = "Average", visible = false }],
          ]
          annotations = { horizontal = [{ label = "CPU 알람 임계 80%", value = 80 }] }
        }
      },
      # --- Host CPU / mem (CloudWatch Agent — ICONIA/Host) ---
      {
        type   = "metric"
        x      = 0
        y      = 13
        width  = 12
        height = 6
        properties = {
          title  = "EC2 Host CPU idle / mem used (%)"
          region = var.region
          view   = "timeSeries"
          stat   = "Average"
          period = 300
          metrics = [
            ["ICONIA/Host", "cpu_usage_idle", { label = "CPU idle %" }],
            ["ICONIA/Host", "mem_used_percent", { label = "mem used %" }],
            ["ICONIA/Host", "swap_used_percent", { label = "swap used %" }],
          ]
          yAxis = { left = { min = 0, max = 100 } }
        }
      },
      # --- 배포 / 롤백 메트릭 ---
      {
        type   = "metric"
        x      = 12
        y      = 13
        width  = 12
        height = 6
        properties = {
          title  = "배포 / 롤백 (ICONIA/Deploy)"
          region = var.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["ICONIA/Deploy", "RollbackPerformed", { label = "자동 롤백" }],
            ["ICONIA/Deploy", "RollbackFailed", { label = "롤백 실패" }],
            ["ICONIA/Deploy", "NginxRestoreFailed", { label = "nginx 복원 실패" }],
          ]
        }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# 4) CloudWatch Logs Insights saved query (README §4.6).
#
#    운영자가 사고 시 콘솔에서 자주 치는 ad-hoc 쿼리를 저장 쿼리로 IaC 화.
#    PII 누출 / RAG 실패 / refresh token reuse / 배포 실패 4종.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_query_definition" "pii_leak_scan" {
  count = var.create_log_groups ? 1 : 0
  name  = "iconia-${var.env}/PII 누출 패턴 스캔"

  log_group_names = [
    aws_cloudwatch_log_group.iconia["server"].name,
    aws_cloudwatch_log_group.iconia["ai"].name,
  ]

  query_string = <<-QUERY
    fields @timestamp, @logStream, @message
    | filter @message like /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/
        or @message like /(010|011|016|017|018|019)[0-9]{7,8}/
        or @message like /Bearer\s+[A-Za-z0-9_\-]{40,}/
    | sort @timestamp desc
    | limit 100
  QUERY
}

resource "aws_cloudwatch_query_definition" "rag_failure" {
  count = var.create_log_groups ? 1 : 0
  name  = "iconia-${var.env}/RAG 실패 추적"

  log_group_names = [aws_cloudwatch_log_group.iconia["ai"].name]

  query_string = <<-QUERY
    fields @timestamp, @logStream, @message
    | filter @message like /rag/ and (@message like /fail/ or @message like /error/ or @message like /timeout/)
    | sort @timestamp desc
    | limit 100
  QUERY
}

resource "aws_cloudwatch_query_definition" "refresh_token_reuse" {
  count = var.create_log_groups ? 1 : 0
  name  = "iconia-${var.env}/Refresh token reuse 감지"

  log_group_names = [aws_cloudwatch_log_group.iconia["server"].name]

  query_string = <<-QUERY
    fields @timestamp, @logStream, @message
    | filter @message like /refresh_token_reuse_detected/ or @message like /RefreshTokenReuse/
    | sort @timestamp desc
    | limit 100
  QUERY
}

resource "aws_cloudwatch_query_definition" "deploy_failures" {
  count = var.create_log_groups ? 1 : 0
  name  = "iconia-${var.env}/배포 실패 / 롤백 timeline"

  log_group_names = [aws_cloudwatch_log_group.iconia["deploy"].name]

  query_string = <<-QUERY
    fields @timestamp, @logStream, @message
    | filter @message like /ERROR/ or @message like /rollback/ or @message like /RollbackFailed/ or @message like /swap-back/
    | sort @timestamp desc
    | limit 200
  QUERY
}

# -----------------------------------------------------------------------------
# 5) 토글 변수.
# -----------------------------------------------------------------------------
variable "create_log_groups" {
  description = "true 면 /iconia/<env>/* 로그그룹 + metric filter + saved query 를 IaC 가 소유. 운영자가 이미 수동 생성한 환경에서는 false 로 두고 import 권장."
  type        = bool
  default     = true
}

variable "create_dashboard" {
  description = "CloudWatch 운영 대시보드 생성 여부."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# 6) Outputs.
# -----------------------------------------------------------------------------
output "cloudwatch_agent_ssm_parameter" {
  description = "CloudWatch Agent fetch-config 가 참조할 SSM Parameter 이름. EC2 user-data 의 -c ssm:<name> 에 사용."
  value       = aws_ssm_parameter.cloudwatch_agent_config.name
}

output "cloudwatch_dashboard_name" {
  description = "운영 대시보드 이름. 콘솔: CloudWatch > Dashboards."
  value       = var.create_dashboard ? aws_cloudwatch_dashboard.iconia_ops[0].dashboard_name : ""
}

output "log_group_names" {
  description = "IaC 가 소유하는 CloudWatch 로그그룹 이름 목록."
  value       = var.create_log_groups ? [for k, v in aws_cloudwatch_log_group.iconia : v.name] : []
}
