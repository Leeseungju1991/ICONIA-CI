###############################################################################
# ICONIA-SERVER — CloudWatch alarms IaC (H-2).
#
# 본 파일은 운영 알람 룰을 Terraform 으로 정의한다. 기존 deploy/aws/cloudwatch-
# alarms.json 은 AWS CLI 직접 적용용 정본이며, 본 파일은 IaC 도입(M+1) 후 정본을
# 흡수하기 위한 마이그레이션 단계의 source-of-truth 후보다.
#
# 적용 절차:
#   cd deploy/aws
#   terraform init
#   terraform plan -var "alarm_email=ops@example.com" \
#                  -var "pagerduty_endpoint=https://events.pagerduty.com/integration/XXX"
#   terraform apply
#
# 모든 알람은 단일 SNS topic("iconia-server-alarms") 으로 통합되며,
# topic 의 subscription 은 alarm_email + pagerduty_endpoint 두 placeholder 를
# 사용한다. Slack 라우팅은 PagerDuty 측 Service Integration 으로 위임 (이 IaC
# 에서는 Slack webhook 직접 subscription 추가 안 함 — secret 노출 위험).
#
# CloudWatch namespace 는 var.cloudwatch_namespace 가 정본 (기본 "ICONIA/Server").
# 본 변수는 Server 의 config.aws.cloudwatchNamespace 와 정확히 일치해야 함.
#
# 참고: AWS/RDS, AWS/ElastiCache 같은 AWS 표준 namespace 는 RDS/Redis 클러스터
# identifier 가 var 로 주입된다. var.rds_instance_identifier / var.redis_cluster_id
# 가 비어 있으면 해당 알람만 skip (count=0).
###############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# -----------------------------------------------------------------------------
# Variables (alarms 전용 — 상위 infra/terraform/variables.tf 와 충돌 없음).
# 운영팀이 -var 또는 tfvars 로 주입.
# -----------------------------------------------------------------------------
variable "alarm_email" {
  description = "운영 alarm SNS subscription email. 비워두면 email subscription 생성 안 함."
  type        = string
  default     = ""
}

variable "pagerduty_endpoint" {
  description = "PagerDuty Events API integration URL (https://events.pagerduty.com/integration/.../enqueue). 비우면 PagerDuty subscription 생성 안 함."
  type        = string
  default     = ""
  sensitive   = true
}

variable "cloudwatch_namespace" {
  description = "ICONIA Server CloudWatch custom namespace. config.aws.cloudwatchNamespace 와 일치해야 함."
  type        = string
  default     = "ICONIA/Server"
}

variable "audit_namespace" {
  description = "감사/IAM 누수 등 별도 namespace (logs metric filter 가 여기로 송출)."
  type        = string
  default     = "ICONIA/Audit"
}

variable "alb_arn_suffix" {
  description = "ALB target ARN suffix (app/iconia-prod-alb/abc123). 5xx 알람의 ApplicationELB dimension. 비우면 5xx 알람 비활성."
  type        = string
  default     = ""
}

variable "rds_instance_identifier" {
  description = "RDS DB instance identifier (예: iconia-prod-db). 비우면 RDS 알람 비활성."
  type        = string
  default     = ""
}

variable "redis_cluster_id" {
  description = "ElastiCache Redis cluster id 또는 replication group id. 비우면 Redis 알람 비활성."
  type        = string
  default     = ""
}

variable "tags" {
  description = "공통 태그."
  type        = map(string)
  default = {
    service = "iconia-server"
    managed = "terraform"
  }
}

# -----------------------------------------------------------------------------
# SNS topic — 모든 알람 통합 라우팅 진입점.
# Slack 라우팅은 PagerDuty 측 integration 으로 위임 (이 IaC 에서 Slack webhook 직접
# subscribe 시 webhook URL 이 IaC state 에 기록되어 secret 노출).
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "alarms" {
  name              = "iconia-server-alarms"
  display_name      = "ICONIA Server Alarms"
  kms_master_key_id = "alias/aws/sns" # SSE 활성. 운영 CMK 도입 시 alias/iconia-prod-data 로 교체.
  tags              = var.tags
}

# Email subscription — alarm_email 비어 있으면 skip.
resource "aws_sns_topic_subscription" "alarm_email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# PagerDuty subscription — placeholder. 실제 endpoint 는 PagerDuty service 의 Events
# Integration URL. 보안: pagerduty_endpoint 변수는 sensitive 표시 — plan/state 에서 노출 최소화.
resource "aws_sns_topic_subscription" "alarm_pagerduty" {
  count                  = var.pagerduty_endpoint == "" ? 0 : 1
  topic_arn              = aws_sns_topic.alarms.arn
  protocol               = "https"
  endpoint               = var.pagerduty_endpoint
  endpoint_auto_confirms = true
}

# -----------------------------------------------------------------------------
# 1) 5xx 응답 비율 ≥ 5% (5분 sliding).
#    ALB 의 RequestCount 대비 HTTPCode_Target_5XX_Count 를 metric math 로 계산.
#    alb_arn_suffix 미주입 시 알람 생성 skip.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "http_5xx_rate" {
  count = var.alb_arn_suffix == "" ? 0 : 1

  alarm_name          = "iconia-server-5xx-rate-high"
  alarm_description   = "ALB target 5xx 비율 >= 5% (5분 sliding). 운영 장애 1차 신호."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = 5.0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  tags                = var.tags

  metric_query {
    id          = "ratio"
    expression  = "100 * (errors / IF(total > 0, total, 1))"
    label       = "5xx_rate_percent"
    return_data = true
  }

  metric_query {
    id          = "errors"
    return_data = false
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      stat        = "Sum"
      period      = 300
      dimensions = {
        LoadBalancer = var.alb_arn_suffix
      }
    }
  }

  metric_query {
    id          = "total"
    return_data = false
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      stat        = "Sum"
      period      = 300
      dimensions = {
        LoadBalancer = var.alb_arn_suffix
      }
    }
  }
}

# -----------------------------------------------------------------------------
# 1-B) 4xx 비율 ≥ 15% (5분) — 클라이언트 호출 오용 / 인증 토큰 만료 폭증 신호.
#      2026-06-15 (사용자 요청 — Pro 안정화 라운드) 신규.
#      ALB HTTPCode_Target_4XX_Count / RequestCount 기반 metric math.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "http_4xx_rate" {
  count = var.alb_arn_suffix == "" ? 0 : 1

  alarm_name          = "iconia-server-4xx-rate-high"
  alarm_description   = "ALB target 4xx 비율 >= 15% (5분 sliding). 인증 실패 폭증 / 클라이언트 회귀 신호."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2 # 연속 2주기 — false positive 차단.
  threshold           = 15.0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  tags                = var.tags

  metric_query {
    id          = "ratio"
    expression  = "100 * (errors / IF(total > 0, total, 1))"
    label       = "4xx_rate_percent"
    return_data = true
  }

  metric_query {
    id          = "errors"
    return_data = false
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_4XX_Count"
      stat        = "Sum"
      period      = 300
      dimensions = {
        LoadBalancer = var.alb_arn_suffix
      }
    }
  }

  metric_query {
    id          = "total"
    return_data = false
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      stat        = "Sum"
      period      = 300
      dimensions = {
        LoadBalancer = var.alb_arn_suffix
      }
    }
  }
}

# -----------------------------------------------------------------------------
# 1-C) Target Response Time P95 ≥ 3s (5분) — 백엔드 응답 지연 신호.
#      AI 호출과 분리 — 일반 API 의 응답 지연 자체.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "target_response_time_p95" {
  count = var.alb_arn_suffix == "" ? 0 : 1

  alarm_name          = "iconia-server-target-p95-latency-high"
  alarm_description   = "ALB Target Response Time P95 >= 3s (5분). 백엔드 응답 지연 — DB/외부 호출 검토."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 2
  threshold           = 3.0
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  tags                = var.tags

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }
}

# -----------------------------------------------------------------------------
# 2) AI 호출 P95 latency >= 8s (5분).
#    aiHealthTracker 가 AiCallLatencyMs 로 송출. p95 extended statistic.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "ai_p95_latency_high" {
  alarm_name          = "iconia-server-ai-p95-latency-high"
  alarm_description   = "AI 호출 p95 latency >= 8000ms (5분). Gemini upstream 또는 persona-ai 지연 의심."
  namespace           = var.cloudwatch_namespace
  metric_name         = "AiCallLatencyMs"
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 1
  threshold           = 8000
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  tags                = var.tags
}

# -----------------------------------------------------------------------------
# 3) refresh_token_reuse_detected — 1건 이상 즉시.
#    authService 가 reuse 감지 시 family revoke. 본 알람을 위해 logger.warn 기반
#    metric filter 로 RefreshTokenReuseDetected count 를 audit_namespace 에 송출 필요
#    (별도 cloudwatch-log-metric-filters.json 에 정의). 없으면 missing → notBreaching.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "refresh_token_reuse" {
  alarm_name          = "iconia-server-refresh-token-reuse-detected"
  alarm_description   = "Refresh token reuse 감지 1건 이상 — 즉시 보안 인시던트로 분류."
  namespace           = var.audit_namespace
  metric_name         = "RefreshTokenReuseDetected"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  tags                = var.tags
}

# -----------------------------------------------------------------------------
# 4) Lifecycle finalizer 24시간 미실행.
#    finalizer cron (scripts/lifecycle-finalizer.js) 이 매 실행마다
#    "LifecycleFinalizerRun" 1 카운트를 namespace 로 송출해야 한다 (없으면
#    finalizer 측에 metric put 추가 필요 — 본 라운드 스코프 밖, 별도 위임).
#    24h sum < 1 → 알람.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "lifecycle_finalizer_stalled" {
  alarm_name          = "iconia-server-lifecycle-finalizer-stalled"
  alarm_description   = "Lifecycle finalizer 24시간 미실행 — pending_deletion 처리 정지. PIPA/GDPR 의무 위반 가능."
  namespace           = var.cloudwatch_namespace
  metric_name         = "LifecycleFinalizerRun"
  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  # 24시간 동안 데이터가 한 번도 안 들어오면 missing — breaching 으로 잡아야 한다.
  treat_missing_data = "breaching"
  alarm_actions      = [aws_sns_topic.alarms.arn]
  tags               = var.tags
}

# -----------------------------------------------------------------------------
# 5) Export job pending 1시간 이상 누적 >= 10건.
#    DataExportJob status=pending 카운트를 finalizer 또는 별도 cron 이
#    "DataExportJobsPending" gauge 로 송출해야 한다 (별도 위임 — 본 라운드는 알람
#    schema 만 정의).
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "export_jobs_pending_backlog" {
  alarm_name          = "iconia-server-export-jobs-pending-backlog"
  alarm_description   = "DataExport pending >= 10건이 1시간 이상 — finalizer 처리 지연 / S3 export 실패 의심."
  namespace           = var.cloudwatch_namespace
  metric_name         = "DataExportJobsPending"
  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  tags                = var.tags
}

# -----------------------------------------------------------------------------
# 6) DB CPU >= 80%.
#    AWS/RDS 의 CPUUtilization. rds_instance_identifier 미주입 시 skip.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  count = var.rds_instance_identifier == "" ? 0 : 1

  alarm_name          = "iconia-server-rds-cpu-high"
  alarm_description   = "RDS CPUUtilization >= 80% (5분). 쿼리 폭주 / 스케일업 신호."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  tags                = var.tags

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_identifier
  }
}

# -----------------------------------------------------------------------------
# 7) DB Memory <= 20% free  (= 80% 사용).
#    AWS/RDS 의 FreeableMemory 는 절대 byte. 임계는 인스턴스 클래스 메모리의 20%.
#    인스턴스 클래스가 다양해서 절대 byte 임계는 운영팀이 -var 로 조정.
# -----------------------------------------------------------------------------
variable "rds_freeable_memory_threshold_bytes" {
  description = "RDS FreeableMemory 임계 (byte). 인스턴스 메모리의 ~20% 권장. db.t4g.medium(4GB) 이면 800MB ≈ 838860800."
  type        = number
  default     = 838860800
}

resource "aws_cloudwatch_metric_alarm" "rds_memory_low" {
  count = var.rds_instance_identifier == "" ? 0 : 1

  alarm_name          = "iconia-server-rds-memory-low"
  alarm_description   = "RDS FreeableMemory 가 임계 이하 — 메모리 사용률 ~80% 초과 의심."
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.rds_freeable_memory_threshold_bytes
  comparison_operator = "LessThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  tags                = var.tags

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_identifier
  }
}

# -----------------------------------------------------------------------------
# 8) Redis 연결 실패 1건 이상.
#    호출자(loginRateLimiter / idempotencyCache / quotaStore) 가 client error 를
#    "RedisConnectionError" 로 audit_namespace 에 push 해야 알람 동작.
#    AWS/ElastiCache 의 EngineCPUUtilization / NetworkConnTracked 는 보조 신호.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "redis_connection_error" {
  alarm_name          = "iconia-server-redis-connection-error"
  alarm_description   = "Redis 연결 실패 metric 1건 이상. multi-instance 카운터 정합성 위협."
  namespace           = var.audit_namespace
  metric_name         = "RedisConnectionError"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  tags                = var.tags
}

# 보조: ElastiCache CurrConnections 0 — 클러스터 자체가 응답 안 함.
resource "aws_cloudwatch_metric_alarm" "redis_no_connections" {
  count = var.redis_cluster_id == "" ? 0 : 1

  alarm_name          = "iconia-server-redis-no-connections"
  alarm_description   = "ElastiCache Redis 클러스터 연결 수가 0 — 클러스터 다운 또는 SG 차단."
  namespace           = "AWS/ElastiCache"
  metric_name         = "CurrConnections"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  tags                = var.tags

  dimensions = {
    CacheClusterId = var.redis_cluster_id
  }
}

# -----------------------------------------------------------------------------
# Outputs.
# -----------------------------------------------------------------------------
output "sns_topic_arn" {
  description = "운영 알람 SNS topic ARN. 다른 모듈에서 추가 알람 attach 시 참조."
  value       = aws_sns_topic.alarms.arn
}

output "alarm_names" {
  description = "본 모듈이 생성한 알람 이름 목록."
  value = compact([
    length(aws_cloudwatch_metric_alarm.http_5xx_rate) > 0 ? aws_cloudwatch_metric_alarm.http_5xx_rate[0].alarm_name : "",
    aws_cloudwatch_metric_alarm.ai_p95_latency_high.alarm_name,
    aws_cloudwatch_metric_alarm.refresh_token_reuse.alarm_name,
    aws_cloudwatch_metric_alarm.lifecycle_finalizer_stalled.alarm_name,
    aws_cloudwatch_metric_alarm.export_jobs_pending_backlog.alarm_name,
    length(aws_cloudwatch_metric_alarm.rds_cpu_high) > 0 ? aws_cloudwatch_metric_alarm.rds_cpu_high[0].alarm_name : "",
    length(aws_cloudwatch_metric_alarm.rds_memory_low) > 0 ? aws_cloudwatch_metric_alarm.rds_memory_low[0].alarm_name : "",
    aws_cloudwatch_metric_alarm.redis_connection_error.alarm_name,
    length(aws_cloudwatch_metric_alarm.redis_no_connections) > 0 ? aws_cloudwatch_metric_alarm.redis_no_connections[0].alarm_name : "",
  ])
}
