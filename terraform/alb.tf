###############################################################################
# alb.tf — Application Load Balancer (Phase 6 신설).
#
# 이전: 단일 EC2 + EIP + nginx (TLS 종단·라우팅을 nginx 가 담당).
# 변경: ALB 가 인터넷 진입점이자 TLS 종단. nginx 는 호스트 내부 라우팅만 (또는
#       단일 backend 인 경우 제거). EC2 는 private subnet 에 배치.
#
# 라우팅:
#   - api.<root_domain>   → target group (server :8080)
#   - ai.<root_domain>    → target group (ai :8081)  ← 본 라운드는 server 만 정의
#   - admin.<root_domain> → target group (admin :3000) ← 본 라운드는 server 만
#
# Phase 6 본 라운드는 ASG 가 monolith host (server+ai+admin 동일 인스턴스) 를
# 유지하므로 target group 도 server :8080 단일. ai/admin 분리는 향후 ECS/EKS
# 전환 시 별도 라운드.
###############################################################################

# -----------------------------------------------------------------------------
# ALB Security Group — 인터넷 0.0.0.0/0 80/443 만, outbound EC2 SG 로 한정.
# -----------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ICONIA ALB - public 80/443 inbound."
  vpc_id      = local.vpc_id

  tags = merge(var.tags, { Name = "${local.name_prefix}-alb-sg" })
}

resource "aws_security_group_rule" "alb_http_in" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = var.http_allowed_cidrs
  security_group_id = aws_security_group.alb.id
  description       = "HTTP (redirect to HTTPS)."
}

resource "aws_security_group_rule" "alb_https_in" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = var.http_allowed_cidrs
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS (TLS termination)."
}

resource "aws_security_group_rule" "alb_egress_to_ec2" {
  type                     = "egress"
  from_port                = 8080
  to_port                  = 8081
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ec2.id
  security_group_id        = aws_security_group.alb.id
  description              = "ALB to EC2 SG (server 8080 + ai 8081)."
}

resource "aws_security_group_rule" "alb_egress_to_ec2_admin" {
  type                     = "egress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ec2.id
  security_group_id        = aws_security_group.alb.id
  description              = "ALB to EC2 SG (admin 3000)."
}

# EC2 SG 인바운드: ALB SG 로부터 backend 포트 허용. nginx 인바운드(80/443)는
# ALB 도입과 함께 EC2 SG 에서 더 이상 직접 노출되지 않도록 별도 라운드에서
# network.tf 의 ec2_http / ec2_https 규칙을 제거 권장. 본 라운드는 backend
# port 추가만 (regression 차단).
resource "aws_security_group_rule" "ec2_from_alb_server" {
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.ec2.id
  description              = "Server :8080 from ALB SG only."
}

resource "aws_security_group_rule" "ec2_from_alb_ai" {
  type                     = "ingress"
  from_port                = 8081
  to_port                  = 8081
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.ec2.id
  description              = "AI :8081 from ALB SG only."
}

resource "aws_security_group_rule" "ec2_from_alb_admin" {
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.ec2.id
  description              = "Admin :3000 from ALB SG only."
}

# -----------------------------------------------------------------------------
# ALB — public subnet, internet-facing.
# -----------------------------------------------------------------------------
resource "aws_lb" "iconia" {
  name                       = "${local.name_prefix}-alb"
  internal                   = var.alb_internal
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = local.public_subnet_ids
  idle_timeout               = var.alb_idle_timeout_seconds
  enable_deletion_protection = var.env == "prod"
  enable_http2               = true
  drop_invalid_header_fields = true

  tags = merge(var.tags, { Name = "${local.name_prefix}-alb" })
}

# -----------------------------------------------------------------------------
# Target Group — server :8080.
# health_check 는 server 의 /api/v1/health (deep 미사용 — ALB 는 shallow 권장).
# deregistration_delay 30s — atomic swap 시 drain 대기.
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "server" {
  name                 = "${local.name_prefix}-tg-server"
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = local.vpc_id
  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    port                = "traffic-port"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  stickiness {
    enabled         = false
    type            = "lb_cookie"
    cookie_duration = 3600
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-tg-server" })

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Listener — 443 HTTPS (ACM cert) + 80 → 443 redirect.
# ACM cert ARN 미주입 시 listener 생성 skip.
# -----------------------------------------------------------------------------
resource "aws_lb_listener" "https" {
  count             = local.effective_alb_acm_arn != "" ? 1 : 0
  load_balancer_arn = aws_lb.iconia.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.effective_alb_acm_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.server.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.iconia.arn
  port              = 80
  protocol          = "HTTP"

  # 도메인+ACM 인증서가 있으면 443 으로 redirect, 없으면 backend 로 직접 forward (PoC/도메인 미보유 시).
  dynamic "default_action" {
    for_each = local.effective_alb_acm_arn != "" ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
  dynamic "default_action" {
    for_each = local.effective_alb_acm_arn == "" ? [1] : []
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.server.arn
    }
  }
}

# -----------------------------------------------------------------------------
# ADMIN 전용 노출 (도메인 미보유 PoC 한정).
# 별도 ALB port :8082 -> EC2 :3000 (admin Next.js standalone).
# 도메인+ACM 도입 후에는 nginx 의 admin.<domain> vhost 가 :443 으로 받게 되므로
# 본 listener 는 제거하거나 internal 전환 권장.
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "admin" {
  name                 = "${local.name_prefix}-tg-admin"
  port                 = 3000
  protocol             = "HTTP"
  vpc_id               = local.vpc_id
  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = "/"
    protocol            = "HTTP"
    port                = "traffic-port"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-tg-admin" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "admin_http" {
  # TODO: remove after admin_acm_arn + admin_domain are set in tfvars and CF distribution validated
  load_balancer_arn = aws_lb.iconia.arn
  port              = 8082
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.admin.arn
  }
}

resource "aws_security_group_rule" "alb_admin_in" {
  type              = "ingress"
  from_port         = 8082
  to_port           = 8082
  protocol          = "tcp"
  cidr_blocks       = var.http_allowed_cidrs
  security_group_id = aws_security_group.alb.id
  description       = "ADMIN PoC port (no domain)."
}
