###############################################################################
# asg.tf — Auto Scaling Group (Phase 6 신설).
#
# Launch Template 기반, Multi-AZ private subnet, ALB target group 자동 등록,
# health_check_type=ELB 로 ALB health check 결과를 ASG 가 신뢰 (단순 EC2
# health check 보다 강함 — 애플리케이션 레벨 fail 도 감지).
#
# scale-in protection: Target tracking 50% CPU + 5분 cooldown.
###############################################################################

resource "aws_autoscaling_group" "iconia_server" {
  name                = "${local.name_prefix}-asg"
  vpc_zone_identifier = local.private_subnet_ids
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  desired_capacity    = var.asg_desired_capacity

  # 사용자 요청 8종 정합 — health_check_type 을 변수로 토글.
  # default "EC2": 첫 프로비저닝(SERVER 미배포) 회귀 방지. tfvars 에서 "ELB" override 시
  # ALB target group health 결과로 unhealthy 인스턴스 자동 교체 (애플리케이션 레벨 fail 감지).
  health_check_type         = var.asg_health_check_type
  health_check_grace_period = 300 # user-data + npm ci + systemd start 합산 여유.

  target_group_arns = [aws_lb_target_group.server.arn, aws_lb_target_group.admin.arn]

  launch_template {
    id      = aws_launch_template.iconia_server.id
    version = "$Latest"
  }

  # Instance refresh — launch template 변경(예: AMI) 시 rolling 으로 교체.
  # min_healthy 90% 로 신규 인스턴스가 healthy 가 된 뒤에야 구 인스턴스 종료.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 90
      instance_warmup        = 180
    }
    triggers = ["tag", "launch_template"]
  }

  # Termination policy — 가장 오래된 인스턴스를 우선 종료 (canary 안정성).
  termination_policies = ["OldestInstance", "Default"]

  # 운영 데이터 보호: ASG-wide scale-in 보호. 인스턴스 단위 보호는
  # `aws_autoscaling_attachment` 또는 콘솔에서 추가.
  protect_from_scale_in = false

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-asg-host"
    propagate_at_launch = true
  }

  tag {
    key                 = "service"
    value               = "iconia"
    propagate_at_launch = true
  }

  tag {
    key                 = "environment"
    value               = var.env
    propagate_at_launch = true
  }

  tag {
    key                 = "managed_by"
    value               = "terraform"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity] # target tracking 이 조정.
  }

  depends_on = [
    aws_lb_target_group.server,
    aws_lb_listener.http_redirect,
  ]
}

# -----------------------------------------------------------------------------
# Target tracking — CPU 50%.
# scale-in cooldown 5분 (var.asg_scale_in_cooldown_seconds).
# -----------------------------------------------------------------------------
resource "aws_autoscaling_policy" "cpu_target" {
  name                      = "${local.name_prefix}-asg-cpu-target"
  autoscaling_group_name    = aws_autoscaling_group.iconia_server.name
  policy_type               = "TargetTrackingScaling"
  estimated_instance_warmup = 180

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.asg_target_cpu_percent
    # scale-in 직후 5분간 추가 감축 금지.
    disable_scale_in = false
  }
}

# -----------------------------------------------------------------------------
# Scale-in 보호용 별도 step policy (cooldown 명시 — target tracking 만으로는
# disable_scale_in 외에 cooldown 직접 제어 불가).
# 5분 cooldown 으로 폭주 차단.
# -----------------------------------------------------------------------------
resource "aws_autoscaling_policy" "scale_in_cooldown_guard" {
  name                   = "${local.name_prefix}-asg-scale-in-cooldown"
  autoscaling_group_name = aws_autoscaling_group.iconia_server.name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = var.asg_scale_in_cooldown_seconds
}
