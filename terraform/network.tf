###############################################################################
# network.tf - VPC / Subnet / IGW / NAT / Route table / Security Group.
#
# var.create_network=true (기본) 면 신규 VPC 풀세트 생성.
# false 면 기존 vpc_id / private_subnet_ids / public_subnet_ids 사용.
###############################################################################

# -----------------------------------------------------------------------------
# VPC.
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  count                = var.create_network ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${local.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "main" {
  count  = var.create_network ? 1 : 0
  vpc_id = aws_vpc.main[0].id
  tags   = merge(var.tags, { Name = "${local.name_prefix}-igw" })
}

# -----------------------------------------------------------------------------
# Public subnet (EC2 EIP, NAT GW 가 위치).
# -----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count                   = var.create_network ? length(var.azs) : 0
  vpc_id                  = aws_vpc.main[0].id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-public-${var.azs[count.index]}"
    tier = "public"
  })
}

resource "aws_route_table" "public" {
  count  = var.create_network ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[0].id
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = var.create_network ? length(var.azs) : 0
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

# -----------------------------------------------------------------------------
# Private subnet (EFS mount targets, 향후 ECS/RDS 확장 대비).
# 본 배포는 EC2 를 public subnet 에 두므로 private 은 EFS 와 미래 확장 용.
# -----------------------------------------------------------------------------
resource "aws_subnet" "private" {
  count             = var.create_network ? length(var.azs) : 0
  vpc_id            = aws_vpc.main[0].id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-private-${var.azs[count.index]}"
    tier = "private"
  })
}

# NAT GW (EIP 1개) - private subnet 의 outbound (예: yum update, npm install) 용.
# 단일 NAT 로 비용 절감. prod 고가용성 필요 시 AZ 별 NAT 로 확장.
resource "aws_eip" "nat" {
  count  = var.create_network ? 1 : 0
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${local.name_prefix}-nat-eip" })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  count         = var.create_network ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(var.tags, { Name = "${local.name_prefix}-nat" })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "private" {
  count  = var.create_network ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[0].id
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-private-rt" })
}

resource "aws_route_table_association" "private" {
  count          = var.create_network ? length(var.azs) : 0
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}

# -----------------------------------------------------------------------------
# Security Group - EC2 (Server/AI/Admin 통합 인스턴스).
# Inbound:
#   - 80, 443: 일반 사용자 (http_allowed_cidrs)
#   - 22 (옵션): ec2_key_pair_name 가 있고 ssh_allowed_cidrs 가 비어있지 않을 때만
#                 (SSM Session Manager 사용 권장 - SSH 차단이 기본)
# Outbound: 전체 허용 (S3 download, Secrets fetch, Gemini API 등).
# -----------------------------------------------------------------------------
resource "aws_security_group" "ec2" {
  name        = "${local.name_prefix}-ec2-sg"
  description = "ICONIA EC2 host (Server + AI + Admin)"
  vpc_id      = local.vpc_id

  egress {
    description = "All outbound."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-ec2-sg" })
}

resource "aws_security_group_rule" "ec2_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = var.http_allowed_cidrs
  security_group_id = aws_security_group.ec2.id
  description       = "HTTP (redirect to HTTPS via nginx)."
}

resource "aws_security_group_rule" "ec2_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = var.http_allowed_cidrs
  security_group_id = aws_security_group.ec2.id
  description       = "HTTPS - nginx reverse proxy."
}

resource "aws_security_group_rule" "ec2_ssh" {
  count             = var.ec2_key_pair_name != "" && length(var.ssh_allowed_cidrs) > 0 ? 1 : 0
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = var.ssh_allowed_cidrs
  security_group_id = aws_security_group.ec2.id
  description       = "SSH (운영자 한정 - 비권장, SSM 사용 권장)."
}

# -----------------------------------------------------------------------------
# Security Group - EFS.
# Inbound 2049 (NFS) from EC2 SG only.
# -----------------------------------------------------------------------------
resource "aws_security_group" "efs" {
  name        = "${local.name_prefix}-efs-sg"
  description = "ICONIA EFS - NFS 2049 from EC2 SG only."
  vpc_id      = local.vpc_id

  egress {
    description = "All outbound."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-efs-sg" })
}

resource "aws_security_group_rule" "efs_from_ec2" {
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ec2.id
  security_group_id        = aws_security_group.efs.id
  description              = "NFS from EC2 SG only."
}
