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

# api/ai/admin alias — enable_cloudfront=true 시 CF distribution 으로, 아니면 ALB 직결.
# 두 경로의 alias.name/zone_id 만 다르고 record 자체는 동일하므로 locals 로 alias target 결정.
locals {
  # CloudFront alias zone_id 는 모든 distribution 공통: Z2FDTNDATAQYW2 (AWS 문서).
  cloudfront_zone_id = "Z2FDTNDATAQYW2"

  # admin 은 운영 CF (aws_cloudfront_distribution.admin) 가 항상 존재.
  # api/ai 는 var.enable_cloudfront 토글로 추가 분배(iconia[*]) 가 켜질 때만 CF 로.
  route53_alias_targets = {
    api = local.cloudfront_enabled ? {
      name    = aws_cloudfront_distribution.iconia["api"].domain_name
      zone_id = local.cloudfront_zone_id
      } : {
      name    = aws_lb.iconia.dns_name
      zone_id = aws_lb.iconia.zone_id
    }
    ai = local.cloudfront_enabled ? {
      name    = aws_cloudfront_distribution.iconia["ai"].domain_name
      zone_id = local.cloudfront_zone_id
      } : {
      name    = aws_lb.iconia.dns_name
      zone_id = aws_lb.iconia.zone_id
    }
    # admin 은 운영 CF 가 alias 없이 default cert 로 가동 중. 도메인 적용 단계가 오면
    # cloudfront.tf 의 admin distribution 에 aliases 추가 + ACM cert 교체 후
    # 아래 alias target 을 CF domain_name 으로 전환 (별도 라운드).
    admin = {
      name    = aws_lb.iconia.dns_name
      zone_id = aws_lb.iconia.zone_id
    }
  }
}

# api.<root> → CF distribution(enable_cloudfront=true) 또는 ALB alias.
resource "aws_route53_record" "api" {
  count   = var.create_route53_records && local.zone_id != "" && var.root_domain != "" ? 1 : 0
  zone_id = local.zone_id
  name    = "${local.api_subdomain}.${var.root_domain}"
  type    = "A"

  alias {
    name                   = local.route53_alias_targets["api"].name
    zone_id                = local.route53_alias_targets["api"].zone_id
    evaluate_target_health = !local.cloudfront_enabled # CF alias 는 health check 미지원
  }
}

# ai.<root> → CF distribution 또는 ALB alias.
resource "aws_route53_record" "ai" {
  count   = var.create_route53_records && local.zone_id != "" && var.root_domain != "" ? 1 : 0
  zone_id = local.zone_id
  name    = "${local.ai_subdomain}.${var.root_domain}"
  type    = "A"

  alias {
    name                   = local.route53_alias_targets["ai"].name
    zone_id                = local.route53_alias_targets["ai"].zone_id
    evaluate_target_health = !local.cloudfront_enabled
  }
}

# admin.<root> → ALB alias (현재). 운영 admin CF 에 alias/ACM 추가 후 CF 로 전환 예정.
resource "aws_route53_record" "admin" {
  count   = var.create_route53_records && local.zone_id != "" && var.root_domain != "" ? 1 : 0
  zone_id = local.zone_id
  name    = "${local.admin_subdomain}.${var.root_domain}"
  type    = "A"

  alias {
    name                   = local.route53_alias_targets["admin"].name
    zone_id                = local.route53_alias_targets["admin"].zone_id
    evaluate_target_health = true # ALB alias 는 health check 지원
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
