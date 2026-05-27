###############################################################################
# terraform/multi-region/main.tf
#
# ICONIA V1.x Multi-region 스캐폴드 — primary(ap-northeast-2 서울)
# + secondary(ap-northeast-1 도쿄) provider 분리.
#
# 본 모듈은 *골격*이다 — 기본값 `enable_multi_region = false` 로 apply 해도
# secondary region 리소스는 0개 생성된다 (모든 secondary 리소스 count = 0).
# 실제 활성화는 운영팀이 별도 결정 후 다음과 같이 수행:
#
#   terraform -chdir=terraform/multi-region init
#   terraform -chdir=terraform/multi-region apply \
#     -var enable_multi_region=true \
#     -var rds_replica_enabled=true \
#     -var primary_db_instance_arn=arn:aws:rds:ap-northeast-2:<acct>:db:iconia-prod-db \
#     -var primary_s3_artifacts_bucket=iconia-prod-artifacts-<acct> \
#     -var primary_alb_dns=<alb-dns> \
#     -var hosted_zone_id=<zone-id> \
#     -var domain_name=iconia.example
#
# RTO/RPO 목표: RTO < 1h / RPO < 5min (docs/multi-region.md 참조).
###############################################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# -----------------------------------------------------------------------------
# Provider 분리 — primary(서울) / secondary(도쿄) 별칭.
#
# 본 stack 은 stand-alone 으로 -chdir=terraform/multi-region 에서 init/apply
# 가능. AWS 자격증명은 환경변수(AWS_PROFILE 등)로 주입.
#
# primary stack(terraform/) 의 root provider 와 충돌하지 않도록 본 stack 은
# 별도 state(backend) 를 사용한다. backend 설정은 운영자가 init 시 주입:
#
#   terraform -chdir=terraform/multi-region init \
#     -backend-config="bucket=iconia-tfstate-<acct>" \
#     -backend-config="key=iconia/multi-region/terraform.tfstate" \
#     -backend-config="region=ap-northeast-2" \
#     -backend-config="dynamodb_table=iconia-tfstate-lock"
# -----------------------------------------------------------------------------
provider "aws" {
  alias  = "primary"
  region = var.primary_region

  default_tags {
    tags = {
      service     = "iconia"
      environment = var.env
      managed_by  = "terraform"
      owner       = "soomkorea"
      company     = "soom-korea-inc"
      module      = "multi-region"
    }
  }
}

provider "aws" {
  alias  = "secondary"
  region = var.secondary_region

  default_tags {
    tags = {
      service     = "iconia"
      environment = var.env
      managed_by  = "terraform"
      owner       = "soomkorea"
      company     = "soom-korea-inc"
      module      = "multi-region"
    }
  }
}

# -----------------------------------------------------------------------------
# data sources — 활성화 시점에 양쪽 region 의 account/region 확인.
# -----------------------------------------------------------------------------
data "aws_caller_identity" "primary" {
  provider = aws.primary
}

data "aws_caller_identity" "secondary" {
  provider = aws.secondary
}

data "aws_region" "primary" {
  provider = aws.primary
}

data "aws_region" "secondary" {
  provider = aws.secondary
}

locals {
  account_id = data.aws_caller_identity.primary.account_id

  # 모든 secondary 리소스 생성 게이트. enable_multi_region=false 면 0.
  enabled     = var.enable_multi_region ? 1 : 0
  rds_enabled = var.enable_multi_region && var.rds_replica_enabled ? 1 : 0
  s3_enabled  = var.enable_multi_region && var.s3_crr_enabled ? 1 : 0
  r53_enabled = var.enable_multi_region && var.route53_failover_enabled ? 1 : 0
  sm_enabled  = var.enable_multi_region && var.secrets_replication_enabled ? 1 : 0
  kms_enabled = var.enable_multi_region && var.kms_multi_region_enabled ? 1 : 0

  name_prefix = "iconia-${var.env}"

  common_tags = merge(
    {
      Project     = "ICONIA"
      Environment = var.env
      MultiRegion = "true"
      ManagedBy   = "terraform"
      Owner       = "soomkorea"
      Module      = "multi-region"
    },
    var.tags,
  )
}
