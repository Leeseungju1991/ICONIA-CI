###############################################################################
# route53.tf - hosted zone + api/ai/admin A record (EIP 가리키기).
#
# 본 인프라는 ALB 없이 단일 EC2 호스트 + nginx 에서 호스트 헤더 기반 라우팅.
# 따라서 모든 서브도메인을 동일 EIP 에 매핑한다.
#
# var.hosted_zone_id 가 비어 있으면 신규 hosted zone 생성.
# var.create_route53_records=false 면 record 생성 skip (DNS 검증 단계 분리용).
###############################################################################

# Hosted zone - 기존 zone 사용 시 var.hosted_zone_id 주입.
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

# api.<root> -> EC2 EIP.
resource "aws_route53_record" "api" {
  count   = var.create_route53_records && local.zone_id != "" && var.root_domain != "" ? 1 : 0
  zone_id = local.zone_id
  name    = "${local.api_subdomain}.${var.root_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.main.public_ip]
}

# ai.<root> -> 동일 EC2 EIP (nginx 가 호스트 헤더로 라우팅).
resource "aws_route53_record" "ai" {
  count   = var.create_route53_records && local.zone_id != "" && var.root_domain != "" ? 1 : 0
  zone_id = local.zone_id
  name    = "${local.ai_subdomain}.${var.root_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.main.public_ip]
}

# admin.<root> -> 동일 EC2 EIP.
resource "aws_route53_record" "admin" {
  count   = var.create_route53_records && local.zone_id != "" && var.root_domain != "" ? 1 : 0
  zone_id = local.zone_id
  name    = "${local.admin_subdomain}.${var.root_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.main.public_ip]
}

# Health check - api endpoint deep health.
resource "aws_route53_health_check" "api_deep" {
  count = var.create_route53_records && var.root_domain != "" ? 1 : 0

  fqdn              = "${local.api_subdomain}.${var.root_domain}"
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health?deep=1"
  failure_threshold = 3
  request_interval  = 10

  tags = merge(var.tags, { Name = "${local.name_prefix}-api-deep-health" })
}
