###############################################################################
# ec2.tf - 단일 EC2 인스턴스 (Server + AI + Admin 통합).
#
# 부트스트랩 흐름:
#   1) user-data.sh : Node.js / nginx / amazon-efs-utils / awscli / cloudwatch agent 설치
#   2) EFS 마운트 (/mnt/efs/iconia)
#   3) /opt/iconia/{server,ai,admin} 디렉토리 생성
#   4) S3 artifacts 버킷에서 최신 tarball pull -> /opt/iconia/<svc>
#   5) systemd unit (iconia-server / iconia-ai / iconia-admin) enable & start
#   6) nginx reload (deploy/nginx/iconia.conf)
#
# 운영 중 갱신은 SSM Run Command 로 ec2-pull-and-restart.sh 호출 (scripts/).
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
  user_data = templatefile("${path.module}/../ec2-bootstrap/user-data.sh.tftpl", {
    region            = var.region
    env               = var.env
    efs_id            = aws_efs_file_system.persona.id
    efs_ap_id         = aws_efs_access_point.server_root.id
    artifacts_bucket  = aws_s3_bucket.artifacts.bucket
    events_bucket     = aws_s3_bucket.events.bucket
    exports_bucket    = aws_s3_bucket.exports.bucket
    firmware_bucket   = aws_s3_bucket.firmware.bucket
    name_prefix       = local.name_prefix
    rds_endpoint = (
      length(aws_db_instance.postgres) > 0
      ? aws_db_instance.postgres[0].endpoint
      : (length(aws_rds_cluster.aurora) > 0 ? aws_rds_cluster.aurora[0].endpoint : "")
    )
    rds_database_name = var.db_name
    rds_username      = var.db_username
  })
}

resource "aws_instance" "main" {
  ami                    = local.ec2_ami_id
  instance_type          = var.ec2_instance_type
  subnet_id              = local.public_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  key_name               = var.ec2_key_pair_name != "" ? var.ec2_key_pair_name : null

  associate_public_ip_address = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.ec2_root_volume_size_gb
    encrypted             = true
    delete_on_termination = false  # 운영 데이터 보호. 인스턴스 교체 시 수동 정리.
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 강제.
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2 # docker/containerd 대비.
    instance_metadata_tags      = "enabled"
  }

  user_data = local.user_data
  user_data_replace_on_change = false # user-data 변경만으로 인스턴스 교체 금지 (운영 데이터 보호).

  monitoring = true

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-host"
    role = "app-monolith"
  })

  lifecycle {
    # 운영자 실수 방어. AMI/instance_type 변경은 별도 절차 (blue-green).
    ignore_changes = [user_data, ami]
  }

  depends_on = [
    aws_efs_mount_target.persona,
    aws_iam_role_policy.ec2_inline,
    aws_db_instance.postgres,
    aws_rds_cluster_instance.aurora_writer,
  ]
}

# Elastic IP - Route53 A record 가 이 IP 를 가리킨다.
resource "aws_eip" "main" {
  domain   = "vpc"
  instance = aws_instance.main.id

  tags = merge(var.tags, { Name = "${local.name_prefix}-host-eip" })

  depends_on = [aws_instance.main]
}
