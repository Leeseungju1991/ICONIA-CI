###############################################################################
# cloudfront.tf — 운영 CloudFront 분배 + 선택적 추가 분배(api/ai).
#
# ── 운영 분배 (항상 존재, terraform import 로 state 흡수) ──────────────────
#   1) aws_cloudfront_distribution.admin        (E31RV3SRZ9E4UQ, d2yblvtzv3503d)
#      - 기존 운영 admin 분배 (유지, 사용자 결정 전까지 변경 없음).
#      - origin: ALB :8082  (admin Next.js standalone)
#      - cache_policy: CachingDisabled (Next.js SSR/SSG 응답은 별도 헤더 캐싱)
#      - origin_request_policy: AllViewer (Host 헤더 forward — ALB host routing 의존)
#      - viewer_cert: CloudFront 기본 인증서 (현재 alias 없음, 도메인 적용 전 단계)
#
#   2) aws_cloudfront_distribution.admin_new    (E2OEPN5AT2O67Z, dlfp1lyn34gcj)
#      - 신규 admin 분배 (2026-06-24 생성). 사용자 확인 후 (1) 을 대체 예정.
#      - origin: ALB :8082 (동일 ALB, http-only, CachingDisabled + AllViewer)
#
#   3) aws_cloudfront_distribution.policy       (EJTW5G0D050C6, dzq72tlftowz4)
#      - 신규 정책사이트 정본 분배 (2026-06-24 Wave 갱신, 멀티 LLM 명시 완료).
#      - origin: S3 iconia-prod-policy (REST endpoint + OAC)
#      - cache_policy: CachingOptimized
#      - response_headers_policy: CORS-With-Preflight (67f7725c-..., AWS managed)
#      - custom_error_response: 403/404 → /index.html (SPA fallback)
#      - viewer_cert: CloudFront 기본 인증서
#
#   [DISABLED] E16FUVKT0TW4S4 (djbwkk8r658e7) — 구 정책사이트 분배.
#      - 2026-06-24 disabled 처리. delete 는 사용자 결정 보류.
#      - Terraform state 에서 제거됨 (state rm 완료).
#
# ── 선택적 분배 (var.enable_cloudfront=true 시) ──────────────────────────────
#   4) aws_cloudfront_distribution.iconia[api/ai]  (optional)
#      - 도메인 + ACM 자동 발급이 준비되면 api.<root>/ai.<root> 를 CF 로 전환.
#      - admin 은 이미 (1)/(2) 가 담당하므로 for_each 키에서 제외.
#
# ── 정책 사이트 S3 버킷 (정합 흡수) ─────────────────────────────────────────
#   aws_s3_bucket.policy + public_access_block + versioning + SSE + bucket policy.
#   bucket policy 는 CloudFront OAC SourceArn 매칭 (신규 정본 EJTW5G0D050C6 기준).
###############################################################################

# -----------------------------------------------------------------------------
# 0) 정책 사이트 S3 버킷 + OAC (운영 import 대상).
# -----------------------------------------------------------------------------
locals {
  policy_bucket = "iconia-prod-policy-${local.account_id}"
}

resource "aws_s3_bucket" "policy" {
  bucket        = local.policy_bucket
  force_destroy = false # 정책 사이트는 prod/dev 모두 보존.
  tags          = merge(var.tags, { purpose = "policy-site" })
}

resource "aws_s3_bucket_public_access_block" "policy" {
  bucket                  = aws_s3_bucket.policy.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "policy" {
  bucket = aws_s3_bucket.policy.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "policy" {
  bucket = aws_s3_bucket.policy.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# OAC — CloudFront 만 GetObject 할 수 있도록 SigV4 서명 강제.
resource "aws_cloudfront_origin_access_control" "policy" {
  name                              = "iconia-policy-oac"
  description                       = "OAC for ${local.policy_bucket}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_bucket_policy" "policy" {
  bucket = aws_s3_bucket.policy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontServicePrincipalReadOnly"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.policy.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.policy.arn
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# 사용자 요청 8종 정합 — 운영 CF 분배 alias / ACM / origin-protocol 토글 locals.
# 변수가 비어있으면 기존 동작 보존 (default CF cert + TLSv1 + http-only).
# 도메인/ACM 이 모두 채워졌을 때만 alias + TLSv1.2_2021 prod 톤 활성.
# -----------------------------------------------------------------------------
locals {
  # admin: cloudfront_admin_acm_arn 우선, 미설정 시 enable_acm_auto 의 us-east-1 cert fallback.
  admin_effective_acm_arn  = var.cloudfront_admin_acm_arn != "" ? var.cloudfront_admin_acm_arn : local.effective_cloudfront_acm_arn
  policy_effective_acm_arn = var.cloudfront_policy_acm_arn != "" ? var.cloudfront_policy_acm_arn : local.effective_cloudfront_acm_arn

  admin_alias_enabled  = var.admin_domain != "" && local.admin_effective_acm_arn != ""
  policy_alias_enabled = var.policy_domain != "" && local.policy_effective_acm_arn != ""
}

# -----------------------------------------------------------------------------
# 1) ADMIN distribution — 기존 운영 분배 (유지). terraform import 흡수.
#    import: terraform import aws_cloudfront_distribution.admin E31RV3SRZ9E4UQ
#    domain: d2yblvtzv3503d.cloudfront.net
# -----------------------------------------------------------------------------
resource "aws_cloudfront_distribution" "admin" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "ICONIA admin site (ALB origin :8082)"
  price_class         = "PriceClass_200"
  http_version        = "http2"
  default_root_object = ""
  # 사용자 요청 8종 정합 — admin_domain + ACM cert 모두 설정 시에만 alias 활성, 미설정 시 기존 [] 유지.
  aliases = local.admin_alias_enabled ? [var.admin_domain] : []

  origin {
    domain_name = "iconia-prod-alb-1408962743.ap-northeast-2.elb.amazonaws.com"
    origin_id   = "iconia-prod-alb-admin"

    custom_origin_config {
      http_port  = 8082
      https_port = 443
      # 사용자 요청 8종 정합 — cloudfront_admin_origin_https=true 시 https-only 강제.
      # 기본 false: ALB :8082 HTTP 회귀 방지 (ALB 8443 HTTPS 리스너 정합 후 옵트인).
      origin_protocol_policy   = var.cloudfront_admin_origin_https ? "https-only" : "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_keepalive_timeout = 5
      origin_read_timeout      = 30
    }
  }

  default_cache_behavior {
    target_origin_id       = "iconia-prod-alb-admin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["HEAD", "DELETE", "POST", "GET", "OPTIONS", "PUT", "PATCH"]
    cached_methods         = ["HEAD", "GET"]
    compress               = true

    # CachingDisabled + AllViewer (origin-request — Host 포함).
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # 사용자 요청 8종 정합 — admin_domain + ACM cert 둘다 설정 시 ACM alias + TLSv1.2_2021.
  # 미설정 시 기존 default CF cert + TLSv1 fallback (호환 보존).
  viewer_certificate {
    cloudfront_default_certificate = local.admin_alias_enabled ? null : true
    acm_certificate_arn            = local.admin_alias_enabled ? local.admin_effective_acm_arn : null
    ssl_support_method             = local.admin_alias_enabled ? "sni-only" : "vip"
    minimum_protocol_version       = local.admin_alias_enabled ? "TLSv1.2_2021" : "TLSv1"
  }

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-cf-admin"
    subdomain = "admin"
  })
}

# -----------------------------------------------------------------------------
# 1-B) ADMIN NEW distribution — 신규 (2026-06-24 생성). 사용자 전환 결정 대기.
#      import: terraform import aws_cloudfront_distribution.admin_new E2OEPN5AT2O67Z
#      domain: dlfp1lyn34gcj.cloudfront.net
# -----------------------------------------------------------------------------
resource "aws_cloudfront_distribution" "admin_new" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "ICONIA admin site NEW (ALB origin :8082)"
  price_class         = "PriceClass_200"
  http_version        = "http2"
  default_root_object = ""
  aliases             = []

  origin {
    domain_name = "iconia-prod-alb-1408962743.ap-northeast-2.elb.amazonaws.com"
    origin_id   = "iconia-prod-alb-admin-new"

    custom_origin_config {
      http_port                = 8082
      https_port               = 443
      origin_protocol_policy   = "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_keepalive_timeout = 5
      origin_read_timeout      = 30
    }
  }

  default_cache_behavior {
    target_origin_id       = "iconia-prod-alb-admin-new"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["HEAD", "DELETE", "POST", "GET", "OPTIONS", "PUT", "PATCH"]
    cached_methods         = ["HEAD", "GET"]
    compress               = true

    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
    ssl_support_method             = "vip"
    minimum_protocol_version       = "TLSv1"
  }

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-cf-admin-new"
    subdomain = "admin"
    note      = "created-2026-06-24 pending-user-switchover"
  })
}

# -----------------------------------------------------------------------------
# 2) POLICY distribution — 신규 정본 (2026-06-24 Wave 갱신). terraform import 흡수.
#    import: terraform import aws_cloudfront_distribution.policy EJTW5G0D050C6
#    domain: dzq72tlftowz4.cloudfront.net
#    구 분배 E16FUVKT0TW4S4 (djbwkk8r658e7) 는 disabled (delete 보류).
# -----------------------------------------------------------------------------
resource "aws_cloudfront_distribution" "policy" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "ICONIA policy site (S3 + OAC)"
  price_class         = "PriceClass_200"
  http_version        = "http2"
  default_root_object = "index.html"
  # 사용자 요청 8종 정합 — policy_domain + ACM cert 모두 설정 시에만 alias 활성, 미설정 시 기존 [] 유지.
  aliases = local.policy_alias_enabled ? [var.policy_domain] : []

  origin {
    domain_name              = aws_s3_bucket.policy.bucket_regional_domain_name
    origin_id                = "S3-iconia-prod-policy"
    origin_access_control_id = aws_cloudfront_origin_access_control.policy.id

    # S3 REST origin — empty OAI (OAC 사용).
    s3_origin_config {
      origin_access_identity = ""
    }
  }

  default_cache_behavior {
    target_origin_id       = "S3-iconia-prod-policy"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["HEAD", "GET"]
    cached_methods         = ["HEAD", "GET"]
    compress               = true

    # CachingOptimized + CORS-With-Preflight response headers (AWS managed).
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    response_headers_policy_id = "67f7725c-6f97-4210-82d7-5512b31e9d03"
  }

  # SPA fallback — 403/404 모두 /index.html 200 응답.
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }
  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # 사용자 요청 8종 정합 — policy_domain + ACM cert 둘다 설정 시 ACM alias + TLSv1.2_2021.
  # 미설정 시 기존 default CF cert + TLSv1 fallback (호환 보존).
  viewer_certificate {
    cloudfront_default_certificate = local.policy_alias_enabled ? null : true
    acm_certificate_arn            = local.policy_alias_enabled ? local.policy_effective_acm_arn : null
    ssl_support_method             = local.policy_alias_enabled ? "sni-only" : "vip"
    minimum_protocol_version       = local.policy_alias_enabled ? "TLSv1.2_2021" : "TLSv1"
  }

  tags = merge(var.tags, {
    Name    = "${local.name_prefix}-cf-policy"
    purpose = "policy-site"
  })
}

# -----------------------------------------------------------------------------
# 3) (선택) 추가 분배 — var.enable_cloudfront=true + ACM 자동 발급 시 api/ai.
#    admin 은 위 (1) 운영 분배가 담당하므로 키에서 제외.
#    도메인/ACM 정합되면 활성화: terraform.tfvars 에 enable_cloudfront=true.
# -----------------------------------------------------------------------------
locals {
  cloudfront_enabled = var.enable_cloudfront && local.acm_auto_enabled

  cf_subdomains = local.cloudfront_enabled ? {
    api = {
      fqdn         = "${local.api_subdomain}.${var.root_domain}"
      cache_policy = "CachingDisabled"
      comment      = "ICONIA api endpoint — no cache (HTTP API, JSON, streaming)"
    }
    ai = {
      fqdn         = "${local.ai_subdomain}.${var.root_domain}"
      cache_policy = "CachingDisabled"
      comment      = "ICONIA ai endpoint — no cache (Gemini streaming, persona 동적 응답)"
    }
  } : {}

  # AWS managed cache policy IDs (모든 계정 공통).
  cache_policy_ids = {
    CachingDisabled  = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    CachingOptimized = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # AllViewer origin request policy (Host 헤더 forward — ALB host routing 의존).
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

  depends_on = [aws_acm_certificate_validation.cloudfront]
}
