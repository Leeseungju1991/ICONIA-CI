###############################################################################
# cloudfront.tf — 3 서브도메인 (api / ai / admin) 각각 CloudFront distribution.
#
# 사용자 결정 (2026-06-02):
#   - api.<root>   → CF distribution → ALB origin (CachingDisabled, API 응답 캐시 X)
#   - ai.<root>    → CF distribution → ALB origin (CachingDisabled, streaming 응답)
#   - admin.<root> → CF distribution → ALB origin (Optimized, Next.js _next/static 캐시)
#
# 활성 조건: var.enable_cloudfront && local.acm_auto_enabled (CF는 us-east-1 ACM 필수).
# 비활성 시: route53.tf 가 alias 를 ALB DNS 로 직결 (기존 동작 100% 보존).
#
# Origin protocol: https-only (ALB 443 listener 가 ACM 인증서를 가질 때만 작동).
# Forwarded headers: Host 헤더 forward — ALB host-header 라우팅이 의존.
###############################################################################

locals {
  cloudfront_enabled = var.enable_cloudfront && local.acm_auto_enabled

  cf_subdomains = local.cloudfront_enabled ? {
    api = {
      fqdn         = "${local.api_subdomain}.${var.root_domain}"
      cache_policy = "CachingDisabled"
      response_hdr = null
      comment      = "ICONIA api endpoint — no cache (HTTP API, JSON, streaming)"
    }
    ai = {
      fqdn         = "${local.ai_subdomain}.${var.root_domain}"
      cache_policy = "CachingDisabled"
      response_hdr = null
      comment      = "ICONIA ai endpoint — no cache (Gemini streaming, persona 동적 응답)"
    }
    admin = {
      fqdn         = "${local.admin_subdomain}.${var.root_domain}"
      cache_policy = "CachingOptimized"
      response_hdr = null
      comment      = "ICONIA admin console (Next.js standalone) — static asset cache 활용"
    }
  } : {}

  # AWS managed cache policy IDs (모든 계정 공통, 변경 X)
  #   CachingDisabled:  4135ea2d-6df8-44a3-9df3-4b5a84be39ad
  #   CachingOptimized: 658327ea-f89d-4fab-a63d-7e88639e58f6
  cache_policy_ids = {
    CachingDisabled  = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    CachingOptimized = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # AWS managed origin request policy IDs
  #   AllViewer (Host 헤더 + 쿼리스트링 + 쿠키 모두 origin 전달):
  #     216adef6-5c7f-47e4-b989-5492eafa07d3
  #   AllViewerExceptHostHeader (Host 만 제외 — admin Next.js 적합):
  #     b689b0a8-53d0-40ab-baf2-68738e2966ac
  #
  # ALB host-header 라우팅이 의존하므로 AllViewer 사용 (Host 포함).
  origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3"
}

resource "aws_cloudfront_distribution" "iconia" {
  for_each = local.cf_subdomains

  enabled         = true
  is_ipv6_enabled = true
  comment         = each.value.comment
  price_class     = var.cloudfront_price_class
  aliases         = [each.value.fqdn]
  http_version    = "http2and3"

  origin {
    domain_name = aws_lb.iconia.dns_name
    origin_id   = "alb-${each.key}"

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_keepalive_timeout = 5
      origin_read_timeout      = 60
    }

    # ALB 가 Host 헤더로 api/ai/admin 라우팅 — CF 는 viewer Host 그대로 forward.
    # (origin_request_policy_id 가 AllViewer 이므로 Host 자동 포함.)
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb-${each.key}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    cache_policy_id          = local.cache_policy_ids[each.value.cache_policy]
    origin_request_policy_id = local.origin_request_policy_id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = local.effective_cloudfront_acm_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = var.cloudfront_min_protocol_version
  }

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-cf-${each.key}"
    subdomain = each.key
  })

  # 인증서 검증이 끝난 뒤 distribution 이 생성되도록 명시 의존.
  depends_on = [aws_acm_certificate_validation.cloudfront]
}
