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

  identifier                            = "${local.name_prefix}-db"
  engine                                = "postgres"
  engine_version                        = "16" # major-only - AWS RDS 가 가용 최신 minor 자동 매칭 (16.4 deprecated 회피).
  instance_class                        = var.db_instance_class
  allocated_storage                     = var.db_allocated_storage_gb
  max_allocated_storage                 = min(50, var.db_allocated_storage_gb * 4)
  storage_type                          = "gp3"
  storage_encrypted                     = true
  db_name                               = var.db_name
  username                              = var.db_username
  password                              = var.db_password
  db_subnet_group_name                  = aws_db_subnet_group.main[0].name
  vpc_security_group_ids                = [aws_security_group.rds.id]
  multi_az                              = var.rds_multi_az # Free Plan 비가용. terraform.tfvars 에 rds_multi_az=true 로 전환.
  publicly_accessible                   = false
  backup_retention_period               = var.rds_backup_retention_days # Free Plan 기본 1, Paid 전환 시 7~35 권장.
  backup_window                         = "17:00-18:00"                 # UTC = KST 02:00-03:00.
  maintenance_window                    = "sun:18:00-sun:19:00"         # UTC = KST 일 03:00-04:00.
  deletion_protection                   = var.rds_deletion_protection   # Free Plan / PoC false. V1.0 prod 에서는 true 권장.
  skip_final_snapshot                   = !var.rds_deletion_protection  # deletion_protection 과 정합 (둘 다 prod 에서 보호).
  final_snapshot_identifier             = var.rds_deletion_protection ? "${local.name_prefix}-db-final-${formatdate("YYYYMMDD", timestamp())}" : null
  copy_tags_to_snapshot                 = true
  apply_immediately                     = false
  iam_database_authentication_enabled   = true
  performance_insights_enabled          = var.rds_performance_insights            # db.t3.micro 미지원. Paid 전환 시 true.
  performance_insights_retention_period = var.rds_performance_insights ? 7 : null # 7일 무료.
  enabled_cloudwatch_logs_exports       = ["postgresql"]

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
  engine_version                      = "16" # major-only - 가용 최신 minor 자동 매칭.
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

# -----------------------------------------------------------------------------
# RDS Proxy (Phase 6 신설).
#
# ASG 인스턴스 수가 늘면 Server / AI 가 각자 PG connection pool 을 들고 있어
# RDS 최대 connection 한계 (db.t4g.medium ≈ 87) 를 초과한다. Proxy 가 backend
# pool 을 공유 + multiplex 해 위험 차단.
#
# 인증: Secrets Manager 의 master password (seed-db-password.ps1 이 생성).
# RDS Proxy 가 secret 을 GetSecretValue 로 읽어 backend DB 에 로그인.
# 클라이언트(EC2)는 IAM auth 또는 동일 secret 으로 Proxy 에 접속.
# require_tls=true — Proxy → DB 와 클라이언트 → Proxy 모두 TLS 강제.
#
# instance 모드일 때만 활성 (Aurora 는 read replica + writer endpoint 로 충분).
# -----------------------------------------------------------------------------

# Proxy 가 사용할 secret. seed-db-password.ps1 이 생성한 이름과 정합.
# Secrets Manager ARN 의 6자리 random suffix 는 data source 로 정확 lookup.
data "aws_secretsmanager_secret" "rds_master" {
  count = var.db_engine_mode == "instance" ? 1 : 0
  name  = "iconia/${var.env}/db/master_password"
}

locals {
  # IAM 권한용 wildcard ARN (suffix 미정 시).
  rds_master_secret_arn_pattern = "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:iconia/${var.env}/db/master_password*"
}

# Proxy 가 Secrets Manager 에서 master password 를 읽을 수 있도록 별도 role.
data "aws_iam_policy_document" "rds_proxy_assume" {
  count = var.db_engine_mode == "instance" ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_proxy" {
  count              = var.db_engine_mode == "instance" ? 1 : 0
  name               = "${local.name_prefix}-rds-proxy-role"
  assume_role_policy = data.aws_iam_policy_document.rds_proxy_assume[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "rds_proxy_secret" {
  count = var.db_engine_mode == "instance" ? 1 : 0

  statement {
    sid       = "GetMasterSecret"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [local.rds_master_secret_arn_pattern]
  }
}

resource "aws_iam_role_policy" "rds_proxy_secret" {
  count  = var.db_engine_mode == "instance" ? 1 : 0
  name   = "${local.name_prefix}-rds-proxy-secret"
  role   = aws_iam_role.rds_proxy[0].id
  policy = data.aws_iam_policy_document.rds_proxy_secret[0].json
}

# Proxy 전용 Security Group — EC2 SG 로부터 5432 만.
resource "aws_security_group" "rds_proxy" {
  count       = var.db_engine_mode == "instance" ? 1 : 0
  name        = "${local.name_prefix}-rds-proxy-sg"
  description = "ICONIA RDS Proxy - 5432 from EC2 SG only."
  vpc_id      = local.vpc_id

  tags = merge(var.tags, { Name = "${local.name_prefix}-rds-proxy-sg" })
}

# RDS Proxy SG egress — RDS SG 만 5432 허용 (0.0.0.0/0 차단). 별도 rule 로 순환참조 방지.
resource "aws_security_group_rule" "rds_proxy_egress_to_rds" {
  count                    = var.db_engine_mode == "instance" ? 1 : 0
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.rds.id
  security_group_id        = aws_security_group.rds_proxy[0].id
  description              = "RDS Proxy to backend RDS SG (5432 only)."
}

resource "aws_security_group_rule" "rds_proxy_from_ec2" {
  count                    = var.db_engine_mode == "instance" ? 1 : 0
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ec2.id
  security_group_id        = aws_security_group.rds_proxy[0].id
  description              = "Postgres from EC2 (ASG) SG only."
}

# RDS SG 에 Proxy SG 추가 허용 (Proxy → backend DB).
resource "aws_security_group_rule" "rds_from_proxy" {
  count                    = var.db_engine_mode == "instance" ? 1 : 0
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.rds_proxy[0].id
  security_group_id        = aws_security_group.rds.id
  description              = "Postgres from RDS Proxy SG."
}

resource "aws_db_proxy" "iconia_pg" {
  # Free Plan: RDS Proxy 미가용. Paid 전환 시 var.enable_rds_proxy=true 로.
  count = var.enable_rds_proxy && var.db_engine_mode == "instance" && length(aws_db_instance.postgres) > 0 ? 1 : 0

  name                   = "${local.name_prefix}-pg-proxy"
  engine_family          = "POSTGRESQL"
  idle_client_timeout    = 1800
  require_tls            = true
  role_arn               = aws_iam_role.rds_proxy[0].arn
  vpc_subnet_ids         = local.private_subnet_ids
  vpc_security_group_ids = [aws_security_group.rds_proxy[0].id]
  debug_logging          = false

  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = data.aws_secretsmanager_secret.rds_master[0].arn
    description = "Master credentials from Secrets Manager."
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-pg-proxy" })
}

resource "aws_db_proxy_default_target_group" "iconia_pg" {
  # 부모 aws_db_proxy.iconia_pg 와 동일 조건 (length(...) 는 plan-time 미정 → static 조건 사용).
  count         = var.enable_rds_proxy && var.db_engine_mode == "instance" ? 1 : 0
  db_proxy_name = aws_db_proxy.iconia_pg[0].name

  connection_pool_config {
    max_connections_percent      = 80
    max_idle_connections_percent = 20
    connection_borrow_timeout    = 120
    # PG 명령어 중 pinning 강제 trigger (예: SET, prepared statement) — 모두 안전 동작.
    init_query = "SET application_name = 'iconia-via-rdsproxy'"
  }
}

resource "aws_db_proxy_target" "iconia_pg" {
  count                  = var.enable_rds_proxy && var.db_engine_mode == "instance" ? 1 : 0
  db_instance_identifier = aws_db_instance.postgres[0].identifier
  db_proxy_name          = aws_db_proxy.iconia_pg[0].name
  target_group_name      = aws_db_proxy_default_target_group.iconia_pg[0].name
}

# -----------------------------------------------------------------------------
# Read replica — 별도 backup 인스턴스 (same-region, db.t4g.small).
#
# 목적: 7일 PITR 백업을 primary 와 독립 보존 + AWS Backup plan 의 추가 snapshot
#       target 으로 활용. replica 는 primary 와 같은 AZ/region 에 생성된다.
# 비용: db.t4g.small ~$0.028/h ≈ $20/월 (스토리지 별도).
# 주의: same-region replica 는 source 의 encrypted key 를 그대로 상속한다.
#        kms_key_id 를 별도로 지정하면 key mismatch 오류가 발생하므로 생략.
# REQ#3-1.
# -----------------------------------------------------------------------------
resource "aws_db_instance" "postgres_backup" {
  count = var.db_engine_mode == "instance" && length(aws_db_instance.postgres) > 0 ? 1 : 0

  identifier = "iconia-prod-db-backup"
  # ARN 사용 필수: db_subnet_group_name 을 함께 지정하면 AWS API 가 ARN 요구.
  # same-region replica 는 db_subnet_group_name 을 source 에서 상속하므로 별도 지정 불필요.
  replicate_source_db = aws_db_instance.postgres[0].arn
  instance_class      = "db.t4g.small"

  # same-region replica 는 source 의 KMS key 를 상속 (별도 kms_key_id 지정 불필요).
  storage_encrypted = true

  backup_retention_period   = 7
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "iconia-prod-db-backup-final-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"
  publicly_accessible       = false
  vpc_security_group_ids    = [aws_security_group.rds.id]

  auto_minor_version_upgrade = true

  tags = merge(var.tags, {
    Name    = "iconia-prod-db-backup"
    Role    = "backup-replica"
    Purpose = "iconia-prod-backup"
  })

  lifecycle {
    # final_snapshot_identifier 에 timestamp() 가 있어 매 plan 마다 drift 유발.
    ignore_changes = [final_snapshot_identifier]
  }
}
