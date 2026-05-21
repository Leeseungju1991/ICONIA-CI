###############################################################################
# route53.tf — hosted zone + api/ai/admin A record alias → ALB (Phase 6).
#
# 이전: EIP 직결 A record (단일 EC2). 본 라운드부터 ALB DNS 의 alias.
# Alias 는 TTL 비용 없이 ALB health 따라 자동 페일오버.
###############################################################################

# Hosted zone — 기존 zone 사용 시 var.hosted_zone_id 주입.
resource "aws_route53_zone" "main" {
  count = var.hosted_zone_id == "" && var.root_domain != "" ? 1 : 0
  name  = var.root_domain

  tags = merge(var.tags, { Name = "${local.name_prefix}-zone" })
}

locals {
  zone_id = var.hosted_zone_id != "" ? var.hosted_zone_id : (
    length(aws_route53_zone.main) > 0 ? aws_route53_zone.main[0].zone_id : ""
  )

  api_subdomain   = var.env == "prod" ? "api" : "${var.env}-api"
  ai_subdomain    = var.env == "prod" ? "ai" : "${var.env}-ai"
  admin_subdomain = var.env == "prod" ? "admin" : "${var.env}-admin"
}

# api.<root> → ALB alias.
resource "aws_route53_record" "api" {
  count   = var.create_route53_records && local.zone_id != "" && var.root_domain != "" ? 1 : 0
  zone_id = local.zone_id
  name    = "${local.api_subdomain}.${var.root_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.iconia.dns_name
    zone_id                = aws_lb.iconia.zone_id
    evaluate_target_health = true
  }
}

# ai.<root> → 동일 ALB alias (ALB host-header 라우팅 또는 단일 target group).
resource "aws_route53_record" "ai" {
  count   = var.create_route53_records && local.zone_id != "" && var.root_domain != "" ? 1 : 0
  zone_id = local.zone_id
  name    = "${local.ai_subdomain}.${var.root_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.iconia.dns_name
    zone_id                = aws_lb.iconia.zone_id
    evaluate_target_health = true
  }
}

# admin.<root> → 동일 ALB alias.
resource "aws_route53_record" "admin" {
  count   = var.create_route53_records && local.zone_id != "" && var.root_domain != "" ? 1 : 0
  zone_id = local.zone_id
  name    = "${local.admin_subdomain}.${var.root_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.iconia.dns_name
    zone_id                = aws_lb.iconia.zone_id
    evaluate_target_health = true
  }
}

# Health check — ALB 가 1차 health, 본 health check 는 외부 page 진단용.
resource "aws_route53_health_check" "api_deep" {
  count = var.create_route53_records && var.root_domain != "" ? 1 : 0

  fqdn              = "${local.api_subdomain}.${var.root_domain}"
  port              = 443
  type              = "HTTPS"
  resource_path     = "/api/v1/health?deep=1"
  failure_threshold = 3
  request_interval  = 10

  tags = merge(var.tags, { Name = "${local.name_prefix}-api-deep-health" })
}
