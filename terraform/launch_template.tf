###############################################################################
# launch_template.tf — ASG 가 사용할 Launch Template.
#
# 신규 인스턴스 부팅 시:
#   1) user-data.sh.tftpl 실행 (Node.js / nginx / amazon-efs-utils / awscli /
#      cloudwatch agent 설치, EFS 마운트, /opt/iconia/* 생성, S3 latest.tar.gz
#      pull, systemd unit enable & start)
#   2) ASG target group 에 자동 등록 → ALB 헬스체크 통과 후 트래픽 수용
#
# Launch Template version 이 변경되면 ASG instance refresh 가 rolling 으로
# 신규 인스턴스를 띄우고 구 인스턴스는 ALB drain 후 종료한다.
###############################################################################

# 최신 Ubuntu 22.04 AMI 자동 조회 (var.ec2_ami_id 비어있을 때).
data "aws_ami" "ubuntu_2204" {
  count       = var.ec2_ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical.

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ec2_ami_id = var.ec2_ami_id != "" ? var.ec2_ami_id : data.aws_ami.ubuntu_2204[0].id

  # user-data 에 주입할 변수.
  # ASG 에서는 RDS Proxy endpoint 를 우선 주입 (rds.tf 의 aws_db_proxy 참조).
  user_data = templatefile("${path.module}/../ec2-bootstrap/user-data.sh.tftpl", {
    region           = var.region
    env              = var.env
    efs_id           = aws_efs_file_system.persona.id
    efs_ap_id        = aws_efs_access_point.server_root.id
    artifacts_bucket = aws_s3_bucket.artifacts.bucket
    events_bucket    = aws_s3_bucket.events.bucket
    exports_bucket   = aws_s3_bucket.exports.bucket
    firmware_bucket  = aws_s3_bucket.firmware.bucket
    name_prefix      = local.name_prefix
    # RDS Proxy endpoint 우선. Proxy 미생성 시 RDS 직접 endpoint 로 fallback.
    rds_endpoint = (
      length(aws_db_proxy.iconia_pg) > 0
      ? aws_db_proxy.iconia_pg[0].endpoint
      : (
        length(aws_db_instance.postgres) > 0
        ? aws_db_instance.postgres[0].endpoint
        : (length(aws_rds_cluster.aurora) > 0 ? aws_rds_cluster.aurora[0].endpoint : "")
      )
    )
    rds_database_name  = var.db_name
    rds_username       = var.db_username
    root_domain        = var.root_domain
    cw_agent_ssm_param = aws_ssm_parameter.cloudwatch_agent_config.name
    # Server claim/lease + event store backend (server.js:849~850 정합).
    # INSTANCE_ID 는 user-data 에서 IMDSv2 로 직접 fetch (terraform 으로 주입 불가 — 인스턴스별 다름).
    event_store_backend     = var.event_store_backend
    analysis_claim_lease_ms = var.analysis_claim_lease_ms
  })
}

resource "aws_launch_template" "iconia_server" {
  name_prefix   = "${local.name_prefix}-lt-"
  image_id      = local.ec2_ami_id
  instance_type = var.ec2_instance_type
  key_name      = var.ec2_key_pair_name != "" ? var.ec2_key_pair_name : null

  # SG 는 network_interfaces 블록 안에만 둠 (top-level vpc_security_group_ids 와 동시 정의 시 AWS API 거부).

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  user_data = base64encode(local.user_data)

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_type           = "gp3"
      volume_size           = var.ec2_root_volume_size_gb
      encrypted             = true
      delete_on_termination = true # ASG 인스턴스는 ephemeral. 영속 데이터는 EFS/RDS.
    }
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 강제.
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true # detailed monitoring (1분).
  }

  # ASG 가 private subnet 에 인스턴스 배치 → public IP 불필요.
  # ALB 가 인터넷 진입. private subnet 의 NAT GW 로 outbound.
  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.ec2.id]
    delete_on_termination       = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${local.name_prefix}-asg-host"
      role = "app-monolith"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${local.name_prefix}-asg-root" })
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-lt" })

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_efs_mount_target.persona,
    aws_iam_role_policy.ec2_inline,
    aws_db_instance.postgres,
    aws_rds_cluster_instance.aurora_writer,
  ]
}
