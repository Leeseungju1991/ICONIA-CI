###############################################################################
# canary.tf — ALB weighted target group canary rollout (V1.x 라운드 신설).
#
# 목적: aws-deploy.ps1 -Canary <pct> 옵션이 실제 트래픽을 분배하도록 한다.
#       기존 단일 target group (aws_lb_target_group.server) 을 "primary" 로 두고
#       canary target group (aws_lb_target_group.server_canary) 신설.
#       ALB listener rule 가 두 TG 에 가중치 forward 한다.
#
# 흐름 (aws-deploy.ps1 와 정합):
#   1. -Canary 10  → canary TG 에 새 빌드 배포 (1 인스턴스 manual register)
#                    → ALB weight primary=90 / canary=10
#                    → 5분 헬스체크 → 통과 시 promote 권장
#   2. -PromoteCanary → canary 빌드를 primary TG 로 atomic swap, weight=100/0
#   3. -RollbackCanary → canary TG drain (deregister), weight=100/0 (이전 primary 유지)
#
# 가중치 자체는 SSM Parameter (terraform 관리 외) 로 저장 — aws-deploy.ps1 가
# `aws elbv2 modify-listener` 로 동적 갱신. terraform 은 "초기값" (100/0) 만 부여.
###############################################################################

# -----------------------------------------------------------------------------
# Canary toggle — 기본 false. true 로 두면 canary TG + listener rule 생성.
# 운영 시 항상 true 권장 (canary 미사용 시에도 weight=100/0 으로 무해).
# -----------------------------------------------------------------------------
variable "enable_canary" {
  description = "ALB weighted target group canary rollout 활성. false 면 canary TG 생성 안 함 (atomic swap 만)."
  type        = bool
  default     = true
}

variable "canary_initial_weight" {
  description = "canary listener rule 의 초기 canary weight (0..100). 운영 중 aws-deploy.ps1 가 동적 갱신. 기본 0 (전체 primary)."
  type        = number
  default     = 0
  validation {
    condition     = var.canary_initial_weight >= 0 && var.canary_initial_weight <= 100
    error_message = "canary_initial_weight must be 0..100."
  }
}

# -----------------------------------------------------------------------------
# Canary Target Group — primary 와 동일 health check / port / protocol.
# deregistration_delay 60s — canary rollback 시 in-flight 요청 drain.
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "server_canary" {
  count = var.enable_canary ? 1 : 0

  name                 = "${local.name_prefix}-tg-server-canary"
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = local.vpc_id
  target_type          = "instance"
  deregistration_delay = 60

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

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-tg-server-canary"
    role = "canary"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Canary Listener Rule — HTTPS 리스너에 weighted forward action.
# default_action(forward → primary) 를 덮어쓰지 않고, host_header 매칭 rule 로
# 같은 hostname (api.<root_domain>) 에 priority 100 으로 끼워넣는다.
# weight 는 초기 var.canary_initial_weight, 운영 중 aws-deploy.ps1 가
# `aws elbv2 modify-rule --actions ...` 로 동적 갱신.
# -----------------------------------------------------------------------------
resource "aws_lb_listener_rule" "server_canary_weighted" {
  count = var.enable_canary && var.acm_certificate_arn != "" ? 1 : 0

  listener_arn = aws_lb_listener.https[0].arn
  priority     = 100

  action {
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.server.arn
        weight = 100 - var.canary_initial_weight
      }
      target_group {
        arn    = aws_lb_target_group.server_canary[0].arn
        weight = var.canary_initial_weight
      }

      stickiness {
        enabled  = false
        duration = 60
      }
    }
  }

  condition {
    host_header {
      values = [
        var.root_domain != "" ? "${local.api_subdomain}.${var.root_domain}" : "*",
      ]
    }
  }

  # 운영 중 aws-deploy.ps1 가 weight 를 modify-rule 로 갱신하므로
  # terraform plan 이 의도치 않게 0/100 으로 되돌리지 않도록 무시.
  lifecycle {
    ignore_changes = [action]
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-listener-rule-canary"
  })
}

# -----------------------------------------------------------------------------
# Outputs — aws-deploy.ps1 가 참조.
# -----------------------------------------------------------------------------
output "canary_target_group_arn" {
  description = "canary TG ARN — aws-deploy.ps1 가 register-targets / modify-rule 의 forward 대상으로 사용. enable_canary=false 면 빈 문자열."
  value       = var.enable_canary ? aws_lb_target_group.server_canary[0].arn : ""
}

output "canary_listener_rule_arn" {
  description = "canary listener rule ARN — aws-deploy.ps1 가 modify-rule 로 weight 동적 갱신."
  value       = (var.enable_canary && var.acm_certificate_arn != "") ? aws_lb_listener_rule.server_canary_weighted[0].arn : ""
}

output "primary_target_group_arn" {
  description = "primary TG ARN — canary promote 시 register-targets 의 대상."
  value       = aws_lb_target_group.server.arn
}
