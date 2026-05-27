###############################################################################
# terraform/multi-region/route53-failover.tf
#
# Route53 health check + DNS failover record (primary/secondary).
#
# 활성화 조건: enable_multi_region=true AND route53_failover_enabled=true.
#
# 동작:
#   - api.<domain> 에 대해 PRIMARY (서울 ALB) / SECONDARY (도쿄 ALB) 두 alias record.
#   - PRIMARY record 는 health check 와 연결됨 — health check 실패 시 자동 SECONDARY 응답.
#   - 헬스체크는 /health?deep=1 을 30초 주기로 검사 (failure_threshold=3 → 약 90초 내 전환).
#
# RTO 산정 (DNS 전환):
#   - Route53 health check failover 자체: 약 90초 (3 × 30s).
#   - DNS TTL 60s — 클라이언트 캐시 영향 추가 최대 60s.
#   - 합계 RTO 약 2~3분 (서비스 가용성 측). 단, RDS promote 등은 별도 RTO.
###############################################################################

# -----------------------------------------------------------------------------
# Primary health check — 서울 region 의 deep health endpoint.
# us-east-1 에 생성 (Route53 health check 는 region-less — 어디서든 생성 가능).
# -----------------------------------------------------------------------------
resource "aws_route53_health_check" "primary" {
  count    = local.r53_enabled
  provider = aws.primary

  fqdn              = var.primary_alb_dns != "" ? var.primary_alb_dns : "api.${var.domain_name}"
  port              = 443
  type              = "HTTPS"
  resource_path     = var.failover_health_path
  failure_threshold = 3
  request_interval  = 30
  measure_latency   = true
  enable_sni        = true

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-primary-healthcheck"
    Purpose = "route53-failover-primary"
  })
}

# -----------------------------------------------------------------------------
# Secondary health check — 도쿄 region. SECONDARY record 자체는 health check
# 필수 아니나, secondary 도 dead 인 경우 응답 안 하도록 둠 (NXDOMAIN 정책).
# -----------------------------------------------------------------------------
resource "aws_route53_health_check" "secondary" {
  count    = local.r53_enabled
  provider = aws.primary

  fqdn              = var.secondary_alb_dns != "" ? var.secondary_alb_dns : "api-dr.${var.domain_name}"
  port              = 443
  type              = "HTTPS"
  resource_path     = var.failover_health_path
  failure_threshold = 3
  request_interval  = 30
  measure_latency   = true
  enable_sni        = true

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-secondary-healthcheck"
    Purpose = "route53-failover-secondary"
  })
}

# -----------------------------------------------------------------------------
# PRIMARY failover record — api.<domain> → 서울 ALB.
# -----------------------------------------------------------------------------
resource "aws_route53_record" "api_primary" {
  count    = local.r53_enabled
  provider = aws.primary

  zone_id = var.hosted_zone_id
  name    = "api.${var.domain_name}"
  type    = "A"

  set_identifier  = "primary-${var.primary_region}"
  health_check_id = aws_route53_health_check.primary[0].id

  failover_routing_policy {
    type = "PRIMARY"
  }

  alias {
    name                   = var.primary_alb_dns
    zone_id                = var.primary_alb_zone_id
    evaluate_target_health = true
  }
}

# -----------------------------------------------------------------------------
# SECONDARY failover record — api.<domain> → 도쿄 ALB.
# secondary_alb_dns 가 비어있으면 record 생성 안 함 (secondary 인프라 미준비 단계).
# -----------------------------------------------------------------------------
resource "aws_route53_record" "api_secondary" {
  count    = local.r53_enabled > 0 && var.secondary_alb_dns != "" ? 1 : 0
  provider = aws.primary

  zone_id = var.hosted_zone_id
  name    = "api.${var.domain_name}"
  type    = "A"

  set_identifier  = "secondary-${var.secondary_region}"
  health_check_id = aws_route53_health_check.secondary[0].id

  failover_routing_policy {
    type = "SECONDARY"
  }

  alias {
    name                   = var.secondary_alb_dns
    zone_id                = var.secondary_alb_zone_id
    evaluate_target_health = true
  }
}

# -----------------------------------------------------------------------------
# CloudWatch alarm — primary health check 실패 알림.
# Route53 health check metric 은 us-east-1 에서만 emit.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "primary_unhealthy" {
  count    = local.r53_enabled
  provider = aws.primary

  alarm_name          = "${local.name_prefix}-primary-region-unhealthy"
  alarm_description   = "ICONIA primary region health check failing — failover 발동 가능성. 운영팀 즉시 확인."
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    HealthCheckId = aws_route53_health_check.primary[0].id
  }

  tags = local.common_tags
}
