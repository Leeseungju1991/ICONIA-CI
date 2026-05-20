###############################################################################
# rds.tf - PostgreSQL RDS.
#
# 기본 모드 (db_engine_mode="instance"): db.t4g.medium 단일 인스턴스
#   + Multi-AZ standby (env=prod 일 때 자동).
# 대체 모드 (db_engine_mode="aurora-serverless-v2"): Aurora PostgreSQL serverless v2.
#
# 본 stack 은 두 모드를 모두 정의하고 var.db_engine_mode 로 분기 (count).
###############################################################################

# Subnet group - private subnet 만 (외부 노출 절대 금지).
resource "aws_db_subnet_group" "main" {
  count       = length(local.private_subnet_ids) >= 2 ? 1 : 0
  name        = "${local.name_prefix}-rds-subnet-group"
  description = "ICONIA ${var.env} RDS subnet group (private only)."
  subnet_ids  = local.private_subnet_ids
  tags        = var.tags
}

# Security group - EC2 SG 로부터의 5432 만 허용.
resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "ICONIA RDS - Postgres 5432 from EC2 SG only."
  vpc_id      = local.vpc_id

  egress {
    description = "All outbound (RDS rarely outbounds, but allow for OS patches via NAT if needed)."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-rds-sg" })
}

resource "aws_security_group_rule" "rds_from_ec2" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ec2.id
  security_group_id        = aws_security_group.rds.id
  description              = "Postgres from EC2 SG only."
}

# -----------------------------------------------------------------------------
# 1) Instance 모드 (default - db.t4g.medium).
# -----------------------------------------------------------------------------
resource "aws_db_instance" "postgres" {
  count = var.db_engine_mode == "instance" && length(aws_db_subnet_group.main) > 0 ? 1 : 0

  identifier                          = "${local.name_prefix}-db"
  engine                              = "postgres"
  engine_version                      = "16.4"
  instance_class                      = var.db_instance_class
  allocated_storage                   = var.db_allocated_storage_gb
  max_allocated_storage               = var.db_allocated_storage_gb * 4
  storage_type                        = "gp3"
  storage_encrypted                   = true
  db_name                             = var.db_name
  username                            = var.db_username
  password                            = var.db_password
  db_subnet_group_name                = aws_db_subnet_group.main[0].name
  vpc_security_group_ids              = [aws_security_group.rds.id]
  multi_az                            = var.env == "prod"
  publicly_accessible                 = false
  backup_retention_period             = var.env == "prod" ? 30 : 7
  deletion_protection                 = var.env == "prod"
  skip_final_snapshot                 = var.env != "prod"
  copy_tags_to_snapshot               = true
  apply_immediately                   = false
  iam_database_authentication_enabled = true
  performance_insights_enabled        = var.env == "prod"
  enabled_cloudwatch_logs_exports     = ["postgresql"]

  tags = merge(var.tags, { Name = "${local.name_prefix}-db" })

  lifecycle {
    # 운영자 실수 방어. password 변경은 별도 절차.
    ignore_changes = [password]
  }
}

# -----------------------------------------------------------------------------
# 2) Aurora Serverless v2 모드 (선택).
# -----------------------------------------------------------------------------
resource "aws_rds_cluster" "aurora" {
  count = var.db_engine_mode == "aurora-serverless-v2" && length(aws_db_subnet_group.main) > 0 ? 1 : 0

  cluster_identifier                  = "${local.name_prefix}-aurora"
  engine                              = "aurora-postgresql"
  engine_mode                         = "provisioned"
  engine_version                      = "16.4"
  database_name                       = var.db_name
  master_username                     = var.db_username
  master_password                     = var.db_password
  db_subnet_group_name                = aws_db_subnet_group.main[0].name
  vpc_security_group_ids              = [aws_security_group.rds.id]
  storage_encrypted                   = true
  backup_retention_period             = var.env == "prod" ? 30 : 7
  deletion_protection                 = var.env == "prod"
  skip_final_snapshot                 = var.env != "prod"
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql"]

  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = var.env == "prod" ? 8.0 : 2.0
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-aurora" })

  lifecycle {
    ignore_changes = [master_password]
  }
}

resource "aws_rds_cluster_instance" "aurora_writer" {
  count = var.db_engine_mode == "aurora-serverless-v2" && length(aws_rds_cluster.aurora) > 0 ? 1 : 0

  identifier                   = "${local.name_prefix}-aurora-writer"
  cluster_identifier           = aws_rds_cluster.aurora[0].id
  instance_class               = "db.serverless"
  engine                       = aws_rds_cluster.aurora[0].engine
  engine_version               = aws_rds_cluster.aurora[0].engine_version
  publicly_accessible          = false
  performance_insights_enabled = var.env == "prod"
}
