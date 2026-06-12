###############################################################################
# wbs.tf - WBS-SYS 배포 (ICONIA 와 같은 VPC 안에서 경로 분리).
#
# 2026-06-05 - 신규.
# 사용자 결정:
#   1) 공존 방식: 경로 분리 (/wbs/* on same CloudFront).
#   2) 백엔드: 새 EC2 + Docker.
#   3) DB: RDS 독립 인스턴스.
#
# 본 파일이 추가하는 리소스:
#   - aws_db_instance.wbs (PostgreSQL 16 db.t3.micro)
#   - aws_db_subnet_group.wbs (private subnets)
#   - aws_security_group.wbs_rds (5432 from wbs_ec2 SG only)
#   - aws_security_group.wbs_ec2 (3000+8080 from iconia EC2 SG, outbound any)
#   - aws_secretsmanager_secret.wbs_db (DB password)
#   - aws_secretsmanager_secret.wbs_jwt (JWT signing secret)
#   - random_password.wbs_db (32-char strong)
#   - random_password.wbs_jwt (64-char strong)
#   - aws_iam_role.wbs_ec2 + instance_profile (SSM + Secrets Manager read)
#   - aws_instance.wbs_ec2 (t3.small Amazon Linux 2023, Docker bootstrap user_data)
#
# nginx 라우팅은 ICONIA EC2 쪽에 추가 (별도 SSM 작업).
###############################################################################

# ---------------------------------------------------------------------------
# 1) 비밀번호 / JWT secret 자동 생성.
# ---------------------------------------------------------------------------
resource "random_password" "wbs_db" {
  length  = 32
  special = false # RDS master 비밀번호 제약: 일부 특수문자 금지. 영숫자만 안전.
}

resource "random_password" "wbs_jwt" {
  length  = 64
  special = true
}

resource "aws_secretsmanager_secret" "wbs_db" {
  name                    = "wbs/${var.env}/db"
  description             = "WBS-SYS RDS master password"
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "wbs_db" {
  secret_id     = aws_secretsmanager_secret.wbs_db.id
  secret_string = random_password.wbs_db.result
}

resource "aws_secretsmanager_secret" "wbs_jwt" {
  name                    = "wbs/${var.env}/jwt"
  description             = "WBS-SYS backend JWT signing secret"
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "wbs_jwt" {
  secret_id     = aws_secretsmanager_secret.wbs_jwt.id
  secret_string = random_password.wbs_jwt.result
}

# ---------------------------------------------------------------------------
# 2) RDS - PostgreSQL 16.
# ---------------------------------------------------------------------------
resource "aws_db_subnet_group" "wbs" {
  name       = "wbs-${var.env}-db-subnet"
  subnet_ids = local.private_subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "wbs_rds" {
  name        = "wbs-${var.env}-rds-sg"
  description = "WBS RDS - allow 5432 from WBS EC2 only"
  vpc_id      = local.vpc_id

  ingress {
    description     = "PostgreSQL from WBS EC2"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.wbs_ec2.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_db_instance" "wbs" {
  identifier        = "wbs-${var.env}-db"
  engine            = "postgres"
  engine_version    = "16.14"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "wbs"
  username = "wbs"
  password = random_password.wbs_db.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.wbs.name
  vpc_security_group_ids = [aws_security_group.wbs_rds.id]
  publicly_accessible    = false

  backup_retention_period   = 0 # free tier 한도. 프로덕션 강화 시 7 이상 + AWS 유료 플랜.
  maintenance_window        = "Mon:17:00-Mon:18:00"
  deletion_protection       = false # 데모 환경. 프로덕션 강화 시 true.
  skip_final_snapshot       = true
  final_snapshot_identifier = null
  apply_immediately         = true

  performance_insights_enabled = false
  monitoring_interval          = 0

  tags = merge(var.tags, { purpose = "wbs-app-db" })
}

# ---------------------------------------------------------------------------
# 3) WBS EC2 (Docker host).
# ---------------------------------------------------------------------------
resource "aws_security_group" "wbs_ec2" {
  name        = "wbs-${var.env}-ec2-sg"
  description = "WBS EC2 - 3000/8080 from ICONIA EC2 SG, outbound any"
  vpc_id      = local.vpc_id

  ingress {
    description     = "Frontend (Next.js) from ICONIA EC2"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  ingress {
    description     = "Backend (Spring Boot) from ICONIA EC2"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

data "aws_iam_policy_document" "wbs_ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "wbs_ec2" {
  name               = "wbs-${var.env}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.wbs_ec2_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "wbs_ec2_ssm" {
  role       = aws_iam_role.wbs_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "wbs_ec2_cloudwatch" {
  role       = aws_iam_role.wbs_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "wbs_ec2_secrets" {
  statement {
    sid    = "ReadWbsSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      aws_secretsmanager_secret.wbs_db.arn,
      aws_secretsmanager_secret.wbs_jwt.arn,
    ]
  }
}

resource "aws_iam_policy" "wbs_ec2_secrets" {
  name   = "wbs-${var.env}-ec2-secrets"
  policy = data.aws_iam_policy_document.wbs_ec2_secrets.json
}

resource "aws_iam_role_policy_attachment" "wbs_ec2_secrets" {
  role       = aws_iam_role.wbs_ec2.name
  policy_arn = aws_iam_policy.wbs_ec2_secrets.arn
}

resource "aws_iam_instance_profile" "wbs_ec2" {
  name = "wbs-${var.env}-ec2-instance-profile"
  role = aws_iam_role.wbs_ec2.name
}

# Amazon Linux 2023 AMI (latest).
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_instance" "wbs_ec2" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.small"
  subnet_id                   = local.private_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.wbs_ec2.id]
  iam_instance_profile        = aws_iam_instance_profile.wbs_ec2.name
  associate_public_ip_address = false

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/wbs-user-data.sh.tftpl", {
    db_endpoint    = aws_db_instance.wbs.address
    db_port        = aws_db_instance.wbs.port
    db_name        = aws_db_instance.wbs.db_name
    db_username    = aws_db_instance.wbs.username
    db_secret_arn  = aws_secretsmanager_secret.wbs_db.arn
    jwt_secret_arn = aws_secretsmanager_secret.wbs_jwt.arn
    aws_region     = var.region
    iconia_cf_host = "d7gw1fdjnkghz.cloudfront.net"
  })

  user_data_replace_on_change = true

  tags = merge(var.tags, {
    Name    = "wbs-${var.env}-ec2"
    purpose = "wbs-app-host"
  })

  depends_on = [aws_db_instance.wbs]
}

# ---------------------------------------------------------------------------
# 4) Outputs.
# ---------------------------------------------------------------------------
output "wbs_ec2_instance_id" {
  description = "WBS EC2 instance ID (SSM target)."
  value       = aws_instance.wbs_ec2.id
}

output "wbs_ec2_private_ip" {
  description = "WBS EC2 private IP (ICONIA nginx proxy_pass 대상)."
  value       = aws_instance.wbs_ec2.private_ip
}

output "wbs_rds_endpoint" {
  description = "WBS RDS endpoint."
  value       = aws_db_instance.wbs.endpoint
}

output "wbs_rds_address" {
  description = "WBS RDS hostname only."
  value       = aws_db_instance.wbs.address
}

output "wbs_db_secret_arn" {
  description = "WBS DB password secret ARN."
  value       = aws_secretsmanager_secret.wbs_db.arn
}

output "wbs_jwt_secret_arn" {
  description = "WBS JWT signing secret ARN."
  value       = aws_secretsmanager_secret.wbs_jwt.arn
}
