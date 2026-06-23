###############################################################################
# alarms.tf - main terraform stack 에서 deploy/aws/alarms.tf 모듈을 통합.
#
# 이전: deploy/aws 에서 별도 `terraform init/apply` 필요 → 운영자가 자주 누락.
# 변경: main terraform/ 의 `terraform apply` 한 번이 알람까지 만든다.
#
# 본 파일은 deploy/aws/alarms.tf 를 child module 로 호출만 한다. 알람 정의
# 자체는 deploy/aws/alarms.tf 가 정본 (CloudWatch alarm rule schema 는 IaC 도입
# 이전 cloudwatch-alarms.json 과 1:1 추적 중이라 그쪽에서 단일 source of truth
# 유지).
#
# child module 에서 사용할 수 없는 backend/provider/terraform 블록은 의도적으로
# 그쪽에 남겨둔 채(terraform module 은 본 블록 무시), 입력 변수만 주입.
###############################################################################

module "alarms" {
  source = "../deploy/aws"

  # alarms.tf 가 노출하는 변수들과 1:1 매핑.
  alarm_email          = var.alarm_email
  pagerduty_endpoint   = var.alarm_pagerduty_endpoint
  cloudwatch_namespace = var.alarm_cloudwatch_namespace
  audit_namespace      = var.alarm_audit_namespace

  # Phase 6: ALB 도입 → ARN suffix 자동 주입. 변수가 비어 있으면 ALB 값 사용.
  alb_arn_suffix = var.alarm_alb_arn_suffix != "" ? var.alarm_alb_arn_suffix : aws_lb.iconia.arn_suffix

  # ALB 알람 활성. 본 stack 은 ALB 를 같은 stack 에서 생성 → 알람도 같이 생성.
  # boolean 으로 cardinality 를 plan-time 에 확정 (alb_arn_suffix 는 unknown 일 수
  # 있어 string-empty 비교로는 count 가 unknown).
  enable_alb_alarms = true

  # RDS identifier 는 main stack 의 rds.tf 출력에서 자동 주입.
  rds_instance_identifier = (
    length(aws_db_instance.postgres) > 0
    ? aws_db_instance.postgres[0].identifier
    : ""
  )

  # Phase 6: Redis 도입 → cluster id 자동 주입.
  redis_cluster_id = (
    var.alarm_redis_cluster_id != ""
    ? var.alarm_redis_cluster_id
    : aws_elasticache_replication_group.iconia_redis.id
  )

  # Redis 알람 활성. ALB 와 동일 — boolean 으로 plan-time cardinality 확정.
  enable_redis_alarms = true

  rds_freeable_memory_threshold_bytes = var.alarm_rds_freeable_memory_threshold_bytes

  tags = merge(var.tags, { service = "iconia-server", managed = "terraform" })
}

###############################################################################
# Phase 6 SLO 알람 — ALB/ASG 도입 후 3종 추가.
# 1) api_5xx_rate > 1% for 5min
# 2) api_latency_p95 > 3000ms for 10min
# 3) ai_fallback_rate > 10% for 5min (Server aiHealthTracker 가 publish)
#
# 모두 module.alarms 의 SNS topic 으로 라우팅 (이메일 + PagerDuty).
###############################################################################

# 1) ALB target 5xx 비율 > 1% (5분).
resource "aws_cloudwatch_metric_alarm" "slo_api_5xx_rate" {
  alarm_name          = "iconia-server-slo-5xx-rate-1pct"
  alarm_description   = "[SLO] ALB target 5xx 비율 > 1% (5분). 양산 운영 SLO 1차 게이트."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 1.0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [module.alarms.sns_topic_arn]
  ok_actions          = [module.alarms.sns_topic_arn]
  tags                = merge(var.tags, { slo = "true" })

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
      dimensions  = { LoadBalancer = aws_lb.iconia.arn_suffix }
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
      dimensions  = { LoadBalancer = aws_lb.iconia.arn_suffix }
    }
  }
}

# 2) API p95 latency > 3000ms (10분).
resource "aws_cloudwatch_metric_alarm" "slo_api_latency_p95" {
  alarm_name          = "iconia-server-slo-latency-p95-3s"
  alarm_description   = "[SLO] ALB target p95 latency > 3000ms (10분 연속). 사용자 체감 응답속도 SLO."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 2   # 5분 × 2 = 10분.
  threshold           = 3.0 # 초 단위 (TargetResponseTime).
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [module.alarms.sns_topic_arn]
  ok_actions          = [module.alarms.sns_topic_arn]
  tags                = merge(var.tags, { slo = "true" })

  dimensions = { LoadBalancer = aws_lb.iconia.arn_suffix }
}

# 3) AI fallback rate > 10% (5분). Server aiHealthTracker 가
#    IconiaAdmin/AiFallbackRate 로 publish (gauge, 0~100).
resource "aws_cloudwatch_metric_alarm" "slo_ai_fallback_rate" {
  alarm_name          = "iconia-server-slo-ai-fallback-rate-10pct"
  alarm_description   = "[SLO] AI fallback 비율 > 10% (5분). Gemini upstream 장애 또는 persona-ai 지연 의심."
  namespace           = "IconiaAdmin"
  metric_name         = "AiFallbackRate"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [module.alarms.sns_topic_arn]
  ok_actions          = [module.alarms.sns_topic_arn]
  tags                = merge(var.tags, { slo = "true" })
}

# -----------------------------------------------------------------------------
# 본 stack 의 alarm 관련 변수 - alarms.tf 와 같은 이름으로 prefix `alarm_` 만
# 다르게 노출 (변수 이름 충돌 방지).
# -----------------------------------------------------------------------------
variable "alarm_email" {
  description = "알람 SNS 구독 이메일."
  type        = string
  default     = ""
}

variable "alarm_pagerduty_endpoint" {
  description = "PagerDuty integration URL."
  type        = string
  default     = ""
  sensitive   = true
}

variable "alarm_cloudwatch_namespace" {
  description = "Server CloudWatch namespace."
  type        = string
  default     = "ICONIA/Server"
}

variable "alarm_audit_namespace" {
  description = "Audit namespace."
  type        = string
  default     = "ICONIA/Audit"
}

variable "alarm_alb_arn_suffix" {
  description = "ALB target ARN suffix (ALB 도입 후 채움)."
  type        = string
  default     = ""
}

variable "alarm_redis_cluster_id" {
  description = "ElastiCache redis cluster id (Redis 도입 후 채움)."
  type        = string
  default     = ""
}

variable "alarm_rds_freeable_memory_threshold_bytes" {
  description = "RDS FreeableMemory 임계 byte."
  type        = number
  default     = 838860800
}

output "alarms_sns_topic_arn" {
  description = "통합 SNS topic - 추가 알람 attach 시 참조."
  value       = module.alarms.sns_topic_arn
}

output "alarm_names" {
  description = "본 stack 에서 생성된 알람 이름."
  value       = module.alarms.alarm_names
}

###############################################################################
# Phase 8 #18 — Gemini cost CloudWatch alarms.
#
# Server cloudWatchCostPublisher 가 IconiaServer/AiCostUsdHourly namespace 로
# 5분 주기 PutMetricData. 다음 2종 알람으로 외부 API 비용 폭주 차단.
#
# 1) iconia_ai_cost_hourly_high — 시간당 cost > var.ai_cost_hourly_usd_threshold.
# 2) iconia_ai_cost_daily_high  — 일일 cost > var.ai_cost_daily_usd_threshold.
#
# 알람은 alarms 모듈의 동일 SNS topic 으로 라우팅 (PagerDuty 통합).
# Budgets 알림(budgets.tf 의 별도 topic) 과 채널 분리 — 운영 alarm 과 billing
# alert 의 노이즈를 섞지 않는다.
###############################################################################

variable "ai_cost_hourly_usd_threshold" {
  description = "시간당 AI(Gemini) 누적 비용 임계 (USD). 초과 시 SNS alert."
  type        = number
  default     = 20
}

variable "ai_cost_daily_usd_threshold" {
  description = "일일 AI(Gemini) 누적 비용 임계 (USD). 초과 시 SNS alert."
  type        = number
  default     = 200
}

# 시간당 — 12개 5분 datapoint Sum > threshold.
resource "aws_cloudwatch_metric_alarm" "iconia_ai_cost_hourly_high" {
  alarm_name          = "iconia-ai-cost-hourly-high"
  alarm_description   = "[COST] Gemini 시간당 누적 cost > $${var.ai_cost_hourly_usd_threshold}. 비용 폭주 의심."
  namespace           = "IconiaServer/AiCostUsdHourly"
  metric_name         = "AiCostUsdTotal"
  statistic           = "Sum"
  period              = 3600 # 1시간.
  evaluation_periods  = 1
  threshold           = var.ai_cost_hourly_usd_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [module.alarms.sns_topic_arn]
  ok_actions          = [module.alarms.sns_topic_arn]
  tags                = merge(var.tags, { purpose = "ai-cost-guard" })
}

# 일일 — 24h period Sum > threshold. period 86400 은 CloudWatch 표준 (1일 metric math 없이도).
resource "aws_cloudwatch_metric_alarm" "iconia_ai_cost_daily_high" {
  alarm_name          = "iconia-ai-cost-daily-high"
  alarm_description   = "[COST] Gemini 일일 누적 cost > $${var.ai_cost_daily_usd_threshold}. 월간 budget 초과 임박 신호."
  namespace           = "IconiaServer/AiCostUsdHourly"
  metric_name         = "AiCostUsdTotal"
  statistic           = "Sum"
  period              = 86400 # 1일.
  evaluation_periods  = 1
  threshold           = var.ai_cost_daily_usd_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [module.alarms.sns_topic_arn]
  ok_actions          = [module.alarms.sns_topic_arn]
  tags                = merge(var.tags, { purpose = "ai-cost-guard" })
}

###############################################################################
# Phase 9 #1 — Device silent CloudWatch alarm.
#
# Server deviceSilenceMetric 가 IconiaServer/DeviceSilence namespace 로 5분 주기
# PutMetricData (DeviceSilent3hCount / DeviceSilent24hCount / DeviceSilent7dCount).
#
# 24h 이상 silent 인 활성 device 수가 임계 (기본 10대) 를 넘으면 SNS alert.
# HW multipart 업로드 실패 시 펌웨어가 로컬 저장 없이 포기하므로 (HW 명세 §5.3),
# 본 알람은 양산 fleet 의 silent 폭주 (Wi-Fi/펌웨어 회귀/서버 장애 모두 포괄적 신호) 를 잡는다.
#
# 5분 주기 datapoint Sum 통계는 의미가 없다 — 게이지에 가까운 metric.
# Average 통계로 1시간 평균이 임계 초과 시 trip.
###############################################################################

variable "device_silent_24h_threshold" {
  description = "24h 이상 silent 인 활성 device 수 임계 (대). 초과 시 SNS alert."
  type        = number
  default     = 10
}

resource "aws_cloudwatch_metric_alarm" "iconia_device_silent_24h_high" {
  alarm_name          = "iconia-device-silent-24h-high"
  alarm_description   = "[HW] 24h 이상 silent 인 활성 device 수 > ${var.device_silent_24h_threshold}대 (1h 평균). Wi-Fi 회귀 / 펌웨어 OTA 회귀 / 서버 ingest 다운 의심."
  namespace           = "IconiaServer/DeviceSilence"
  metric_name         = "DeviceSilent24hCount"
  statistic           = "Average"
  period              = 3600 # 1시간 평균 (5분 datapoint 12개 평균).
  evaluation_periods  = 1
  threshold           = var.device_silent_24h_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [module.alarms.sns_topic_arn]
  ok_actions          = [module.alarms.sns_topic_arn]
  tags                = merge(var.tags, { purpose = "device-silence-guard" })
}

###############################################################################
# V1.0 SLO 알람 — 인프라 리소스 포화 / 외부 시점 회귀 3종.
#
# 4) API p99 latency > 5000ms — p95 보다 긴 임계로 tail latency 폭주 감지.
# 5) RDS DatabaseConnections > 80 — db.t4g.medium 한계 87 의 90%.
# 6) Redis CacheHitRate < 80% — 캐시 효율 저하 (분산 일관성 / 동기화 회귀).
###############################################################################

# 4) API p99 latency > 5000ms (10분).
resource "aws_cloudwatch_metric_alarm" "slo_api_latency_p99" {
  alarm_name          = "iconia-server-slo-latency-p99-5s"
  alarm_description   = "[SLO] ALB target p99 latency > 5000ms (10분 연속). tail latency 폭주 — 일부 사용자 응답 지연 회귀."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p99"
  period              = 300
  evaluation_periods  = 2   # 5분 × 2 = 10분.
  threshold           = 5.0 # 초 단위.
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [module.alarms.sns_topic_arn]
  ok_actions          = [module.alarms.sns_topic_arn]
  tags                = merge(var.tags, { slo = "true" })

  dimensions = { LoadBalancer = aws_lb.iconia.arn_suffix }
}

# 5) RDS connection pool exhaustion 임박 — DatabaseConnections > var.rds_max_connections_threshold.
variable "rds_max_connections_threshold" {
  description = "RDS DatabaseConnections 임계. db.t4g.medium(max ≈ 87) 의 90% 기본."
  type        = number
  default     = 80
}

resource "aws_cloudwatch_metric_alarm" "slo_rds_connections_high" {
  count               = length(aws_db_instance.postgres) > 0 ? 1 : 0
  alarm_name          = "iconia-rds-connections-high"
  alarm_description   = "[SLO] RDS DatabaseConnections > ${var.rds_max_connections_threshold} (5분 평균). connection pool exhaustion 임박 — RDS Proxy 활성 또는 인스턴스 upgrade 필요."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.rds_max_connections_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [module.alarms.sns_topic_arn]
  ok_actions          = [module.alarms.sns_topic_arn]
  tags                = merge(var.tags, { slo = "true", resource = "rds" })

  dimensions = { DBInstanceIdentifier = aws_db_instance.postgres[0].identifier }
}

# 6) Redis CacheHitRate < 80% — cache miss 폭주 (warmup 외 시간대).
#    ElastiCache 표준 metric 은 CacheHits/CacheMisses 의 합. metric_math 로 비율 계산.
variable "redis_cache_hit_ratio_min" {
  description = "Redis cache hit ratio 최소값(%). 미만 시 알람."
  type        = number
  default     = 80
}

resource "aws_cloudwatch_metric_alarm" "slo_redis_cache_hit_low" {
  alarm_name          = "iconia-redis-cache-hit-low"
  alarm_description   = "[SLO] Redis CacheHitRatio < ${var.redis_cache_hit_ratio_min}% (10분 연속). 캐시 효율 저하 — quota/idempotency store key churn 의심."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  threshold           = var.redis_cache_hit_ratio_min
  treat_missing_data  = "notBreaching"
  alarm_actions       = [module.alarms.sns_topic_arn]
  ok_actions          = [module.alarms.sns_topic_arn]
  tags                = merge(var.tags, { slo = "true", resource = "redis" })

  metric_query {
    id          = "ratio"
    expression  = "100 * (hits / IF((hits + misses) > 0, (hits + misses), 1))"
    label       = "cache_hit_ratio_percent"
    return_data = true
  }

  metric_query {
    id          = "hits"
    return_data = false
    metric {
      namespace   = "AWS/ElastiCache"
      metric_name = "CacheHits"
      stat        = "Sum"
      period      = 300
      dimensions  = { ReplicationGroupId = aws_elasticache_replication_group.iconia_redis.id }
    }
  }

  metric_query {
    id          = "misses"
    return_data = false
    metric {
      namespace   = "AWS/ElastiCache"
      metric_name = "CacheMisses"
      stat        = "Sum"
      period      = 300
      dimensions  = { ReplicationGroupId = aws_elasticache_replication_group.iconia_redis.id }
    }
  }
}

# 7) RDS Storage Free Space < 20% — disk full 임박.
variable "rds_free_storage_threshold_bytes" {
  description = "RDS FreeStorageSpace 임계 byte. 기본 10GB (db_allocated_storage_gb 50 의 20%)."
  type        = number
  default     = 10737418240 # 10 GB.
}

resource "aws_cloudwatch_metric_alarm" "slo_rds_storage_low" {
  count               = length(aws_db_instance.postgres) > 0 ? 1 : 0
  alarm_name          = "iconia-rds-storage-low"
  alarm_description   = "[SLO] RDS FreeStorageSpace < ${var.rds_free_storage_threshold_bytes} byte (1h 평균). disk full 임박 — auto-scaling 또는 수동 확장 필요."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  period              = 3600 # 1시간.
  evaluation_periods  = 1
  threshold           = var.rds_free_storage_threshold_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [module.alarms.sns_topic_arn]
  ok_actions          = [module.alarms.sns_topic_arn]
  tags                = merge(var.tags, { slo = "true", resource = "rds" })

  dimensions = { DBInstanceIdentifier = aws_db_instance.postgres[0].identifier }
}
