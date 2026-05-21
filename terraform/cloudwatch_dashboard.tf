###############################################################################
# cloudwatch_dashboard.tf — Phase 6 SLO 대시보드.
#
# 기존 observability.tf 의 iconia_ops 대시보드는 단일 EC2 + nginx 시절 위젯.
# 본 보드는 ASG / ALB / RDS Proxy / ElastiCache / AI fallback rate 가 추가된
# Phase 6 운영 정본. 두 보드를 병존시켜 마이그레이션 기간 동안 운영자가 양쪽
# 모두 확인 가능 (구버전은 단일 인스턴스 metric 보존).
###############################################################################

resource "aws_cloudwatch_dashboard" "iconia_slo" {
  dashboard_name = "iconia-${var.env}-slo"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 1
        properties = {
          markdown = "# ICONIA ${var.env} SLO 대시보드 — ALB / ASG / RDS Proxy / Redis / AI"
        }
      },

      # --- ALB target 5xx 비율 ---
      {
        type   = "metric"
        x      = 0
        y      = 1
        width  = 8
        height = 6
        properties = {
          title  = "ALB target 5xx 비율 (%) — SLO < 1%"
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
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.iconia.arn_suffix, { id = "m5xx", visible = false }],
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.iconia.arn_suffix, { id = "mreq", visible = false }],
          ]
          yAxis       = { left = { min = 0, max = 5 } }
          annotations = { horizontal = [{ label = "SLO 1%", value = 1 }] }
        }
      },

      # --- ALB latency p50/p95/p99 ---
      {
        type   = "metric"
        x      = 8
        y      = 1
        width  = 8
        height = 6
        properties = {
          title  = "ALB target latency p50/p95/p99 (s) — SLO p95 < 3s"
          region = var.region
          view   = "timeSeries"
          period = 300
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.iconia.arn_suffix, { stat = "p50", label = "p50" }],
            ["...", { stat = "p95", label = "p95" }],
            ["...", { stat = "p99", label = "p99" }],
          ]
          annotations = { horizontal = [{ label = "SLO p95 3s", value = 3 }] }
        }
      },

      # --- ASG 인스턴스 수 + CPU ---
      {
        type   = "metric"
        x      = 16
        y      = 1
        width  = 8
        height = 6
        properties = {
          title  = "ASG 인스턴스 수 + 평균 CPU (%)"
          region = var.region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", aws_autoscaling_group.iconia_server.name, { stat = "Average", label = "InService" }],
            ["AWS/AutoScaling", "GroupDesiredCapacity", "AutoScalingGroupName", aws_autoscaling_group.iconia_server.name, { stat = "Average", label = "Desired" }],
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.iconia_server.name, { stat = "Average", label = "CPU %", yAxis = "right" }],
          ]
        }
      },

      # --- RDS Proxy connections in-use ---
      {
        type   = "metric"
        x      = 0
        y      = 7
        width  = 12
        height = 6
        properties = {
          title  = "RDS Proxy connections in-use / borrow latency"
          region = var.region
          view   = "timeSeries"
          period = 60
          metrics = length(aws_db_proxy.iconia_pg) > 0 ? [
            ["AWS/RDS", "ClientConnections", "ProxyName", aws_db_proxy.iconia_pg[0].name, { stat = "Average", label = "ClientConnections" }],
            ["AWS/RDS", "DatabaseConnections", "ProxyName", aws_db_proxy.iconia_pg[0].name, { stat = "Average", label = "DatabaseConnections" }],
            ["AWS/RDS", "DatabaseConnectionsBorrowLatency", "ProxyName", aws_db_proxy.iconia_pg[0].name, { stat = "Average", label = "BorrowLatency", yAxis = "right" }],
          ] : []
        }
      },

      # --- Redis CPU / 메모리 / 명령어 latency ---
      {
        type   = "metric"
        x      = 12
        y      = 7
        width  = 12
        height = 6
        properties = {
          title  = "Redis CPU / mem / latency"
          region = var.region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/ElastiCache", "EngineCPUUtilization", "ReplicationGroupId", aws_elasticache_replication_group.iconia_redis.id, { stat = "Average", label = "Engine CPU %" }],
            ["AWS/ElastiCache", "DatabaseMemoryUsagePercentage", "ReplicationGroupId", aws_elasticache_replication_group.iconia_redis.id, { stat = "Average", label = "Mem %" }],
            ["AWS/ElastiCache", "StringBasedCmdsLatency", "ReplicationGroupId", aws_elasticache_replication_group.iconia_redis.id, { stat = "Average", label = "cmd latency (us)", yAxis = "right" }],
          ]
        }
      },

      # --- IconiaAdmin/AiFallbackRate (Server publish) ---
      {
        type   = "metric"
        x      = 0
        y      = 13
        width  = 12
        height = 6
        properties = {
          title  = "AI fallback rate (%) — SLO < 10%"
          region = var.region
          view   = "timeSeries"
          period = 300
          metrics = [
            ["IconiaAdmin", "AiFallbackRate", { stat = "Average", label = "fallback %" }],
          ]
          yAxis       = { left = { min = 0, max = 100 } }
          annotations = { horizontal = [{ label = "SLO 10%", value = 10 }] }
        }
      },

      # --- ALB request count + healthy hosts ---
      {
        type   = "metric"
        x      = 12
        y      = 13
        width  = 12
        height = 6
        properties = {
          title  = "ALB RequestCount / Healthy hosts"
          region = var.region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.iconia.arn_suffix, { stat = "Sum", label = "RequestCount" }],
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", aws_lb.iconia.arn_suffix, "TargetGroup", aws_lb_target_group.server.arn_suffix, { stat = "Average", label = "Healthy", yAxis = "right" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", aws_lb.iconia.arn_suffix, "TargetGroup", aws_lb_target_group.server.arn_suffix, { stat = "Average", label = "Unhealthy", yAxis = "right" }],
          ]
        }
      },
    ]
  })
}

output "cloudwatch_slo_dashboard_name" {
  description = "Phase 6 SLO 대시보드 이름."
  value       = aws_cloudwatch_dashboard.iconia_slo.dashboard_name
}
