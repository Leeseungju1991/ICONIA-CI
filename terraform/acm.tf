###############################################################################
# acm.tf — ACM 인증서 자동 발급 + Route53 DNS validation (사용자 결정 2026-06-02).
#
# 두 리전 동시 발급 (CloudFront 가 us-east-1 인증서만 받기 때문):
#   - ap-northeast-2 (alb)        — ALB 443 listener 가 사용. alb.tf 가 참조.
#   - us-east-1     (cloudfront)  — CloudFront viewer cert. cloudfront.tf 가 참조.
#
# SAN 정책:
#   - <root_domain>                — 루트 도메인
#   - *.<root_domain>              — api/ai/admin/* 모든 서브도메인 한 인증서로 커버
#     (env=stage 일 때 prefix 가 변하더라도 wildcard 가 받음).
#
# 활성 조건: var.enable_acm_auto && var.root_domain != "" && local.zone_id != "".
# 비활성 시: 본 파일 전체가 count=0 → 기존 var.acm_certificate_arn 수동 입력 경로 100% 보존.
#
# 자동 갱신: ACM 은 DNS validation record 가 유지되는 한 만료 60일 전 자동 재발급/갱신.
###############################################################################

locals {
  acm_auto_enabled = var.enable_acm_auto && var.root_domain != "" && local.zone_id != ""
  acm_san_list = local.acm_auto_enabled ? [
    var.root_domain,
    "*.${var.root_domain}",
  ] : []
}

# -----------------------------------------------------------------------------
# ALB 용 ACM 인증서 (ap-northeast-2). 기본 provider 사용.
# -----------------------------------------------------------------------------
resource "aws_acm_certificate" "alb" {
  count                     = local.acm_auto_enabled ? 1 : 0
  domain_name               = var.root_domain
  subject_alternative_names = ["*.${var.root_domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name  = "${local.name_prefix}-alb-acm"
    scope = "alb-ap-northeast-2"
  })
}

# -----------------------------------------------------------------------------
# CloudFront 용 ACM 인증서 (us-east-1). main.tf 의 aws.us_east_1 alias provider.
# -----------------------------------------------------------------------------
resource "aws_acm_certificate" "cloudfront" {
  count                     = local.acm_auto_enabled ? 1 : 0
  provider                  = aws.us_east_1
  domain_name               = var.root_domain
  subject_alternative_names = ["*.${var.root_domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name  = "${local.name_prefix}-cloudfront-acm"
    scope = "cloudfront-us-east-1"
  })
}

# -----------------------------------------------------------------------------
# Route53 DNS validation records — ALB 인증서.
# domain_validation_options 가 wildcard + apex 를 합쳐 동일 CNAME 을 내놓으므로
# distinct() 로 중복 제거.
# -----------------------------------------------------------------------------
resource "aws_route53_record" "acm_alb_validation" {
  for_each = local.acm_auto_enabled ? {
    for dvo in aws_acm_certificate.alb[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id         = local.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "alb" {
  count                   = local.acm_auto_enabled ? 1 : 0
  certificate_arn         = aws_acm_certificate.alb[0].arn
  validation_record_fqdns = [for r in aws_route53_record.acm_alb_validation : r.fqdn]
}

# -----------------------------------------------------------------------------
# Route53 DNS validation records — CloudFront 인증서 (us-east-1).
# 동일 wildcard + apex 이므로 CNAME 자체는 ALB 인증서와 보통 일치하지만,
# ACM 은 cert 별로 별도 validation 토큰을 생성할 수 있으므로 별도 record 로 등록.
# -----------------------------------------------------------------------------
resource "aws_route53_record" "acm_cloudfront_validation" {
  for_each = local.acm_auto_enabled ? {
    for dvo in aws_acm_certificate.cloudfront[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id         = local.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cloudfront" {
  count                   = local.acm_auto_enabled ? 1 : 0
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cloudfront[0].arn
  validation_record_fqdns = [for r in aws_route53_record.acm_cloudfront_validation : r.fqdn]
}

# -----------------------------------------------------------------------------
# 외부 노출: 다른 .tf 가 참조하는 ACM ARN (자동 발급 비활성 시 var.acm_certificate_arn fallback).
# -----------------------------------------------------------------------------
locals {
  effective_alb_acm_arn = local.acm_auto_enabled ? (
    aws_acm_certificate_validation.alb[0].certificate_arn
  ) : var.acm_certificate_arn

  effective_cloudfront_acm_arn = local.acm_auto_enabled ? (
    aws_acm_certificate_validation.cloudfront[0].certificate_arn
  ) : ""
}
