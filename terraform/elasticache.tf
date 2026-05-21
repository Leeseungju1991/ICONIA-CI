###############################################################################
# elasticache.tf — Redis Multi-AZ (Phase 6 신설).
#
# Server 의 RATE_LIMIT_BACKEND=redis + idempotencyCache + quotaStore +
# loginRateLimiter 가 본 클러스터에 의존. ASG 인스턴스 수가 늘면 in-memory
# 카운터 정합성이 깨지므로 Redis 가 필수.
#
# 구성:
#   - cache.t4g.small × 2 (primary + replica), automatic_failover, multi_az
#   - 암호화 at-rest (KMS managed) + in-transit (TLS) + AUTH token
#   - Subnet group: private subnet
#   - SG: ASG EC2 SG 만 6379
###############################################################################

# -----------------------------------------------------------------------------
# Subnet group — private subnet 만.
# -----------------------------------------------------------------------------
resource "aws_elasticache_subnet_group" "iconia_redis" {
  name        = "${local.name_prefix}-redis-subnet-group"
  description = "ICONIA Redis subnet group (private only)."
  subnet_ids  = local.private_subnet_ids
  tags        = var.tags
}

# -----------------------------------------------------------------------------
# Security Group — EC2 (ASG) SG 로부터 6379 만.
# -----------------------------------------------------------------------------
resource "aws_security_group" "redis" {
  name        = "${local.name_prefix}-redis-sg"
  description = "ICONIA Redis - 6379 from ASG EC2 SG only."
  vpc_id      = local.vpc_id

  egress {
    description = "All outbound (Redis rarely outbounds, allow for OS patches)."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-redis-sg" })
}

resource "aws_security_group_rule" "redis_from_ec2" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ec2.id
  security_group_id        = aws_security_group.redis.id
  description              = "Redis from ASG EC2 SG only."
}

# -----------------------------------------------------------------------------
# AUTH token — 랜덤 생성, Secrets Manager 에 저장.
# Server 가 본 secret 을 읽어 redis client 초기화.
# rotation 은 별도 라운드 (rotation 시 client 재시작 필요).
# -----------------------------------------------------------------------------
resource "random_password" "redis_auth" {
  length      = 32
  special     = false # ElastiCache AUTH 는 일부 특수문자 제한 — 알파넘 32 char 충분.
  min_lower   = 4
  min_upper   = 4
  min_numeric = 4
}

resource "aws_secretsmanager_secret" "redis_auth" {
  name                    = "iconia/${var.env}/redis/auth_token"
  description             = "ICONIA Redis AUTH token (terraform 관리)."
  recovery_window_in_days = var.env == "prod" ? 30 : 0
  tags                    = merge(var.tags, { component = "redis" })
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id = aws_secretsmanager_secret.redis_auth.id
  secret_string = jsonencode({
    auth_token = random_password.redis_auth.result
    endpoint   = aws_elasticache_replication_group.iconia_redis.primary_endpoint_address
    port       = 6379
  })
}

# -----------------------------------------------------------------------------
# Replication group — primary + 1 replica, Multi-AZ, encryption 모두 on.
# -----------------------------------------------------------------------------
resource "aws_elasticache_replication_group" "iconia_redis" {
  replication_group_id = "${local.name_prefix}-redis"
  description          = "ICONIA Redis rate-limit / idempotency / quota store. Multi-AZ."

  engine               = "redis"
  engine_version       = "7.1"
  node_type            = "cache.t4g.small"
  num_cache_clusters   = 2
  port                 = 6379
  parameter_group_name = "default.redis7"

  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name  = aws_elasticache_subnet_group.iconia_redis.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result

  # 일일 스냅샷 (prod 만).
  snapshot_retention_limit = var.env == "prod" ? 7 : 1
  snapshot_window          = "17:00-18:00" # UTC = KST 02:00-03:00.
  maintenance_window       = "sun:18:00-sun:19:00"

  apply_immediately = false

  tags = merge(var.tags, { Name = "${local.name_prefix}-redis" })

  lifecycle {
    ignore_changes = [auth_token] # rotation 은 별도 절차.
  }
}

# -----------------------------------------------------------------------------
# IAM — EC2 (ASG) 가 Redis AUTH secret 을 읽을 수 있도록 iam.tf 의 secrets 정책
# 범위에 자동 포함됨 (iconia/${env}/* prefix 와 정합).
# -----------------------------------------------------------------------------
