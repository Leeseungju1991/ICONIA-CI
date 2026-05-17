###############################################################################
# ICONIA - Terraform IaC entry.
#
# 구성: Route53 + EC2 + S3 + EFS (4종, RDS 제외).
# 배포 모델: 로컬 빌드 -> S3 artifacts -> EC2 pull.
#
# 디렉토리 구성:
#   main.tf       provider, region, backend (S3 state + DynamoDB lock)
#   variables.tf  공통 변수
#   network.tf    VPC / Subnet / IGW / NAT / Route table / Security Group
#   ec2.tf        EC2 instance + user_data + EIP
#   s3.tf         events / exports / firmware / artifacts 버킷
#   efs.tf        Persona persistence 용 EFS + access point
#   iam.tf        EC2 instance role (S3 / Secrets / CloudWatch / EFS / SSM)
#   route53.tf    hosted zone + api/ai/admin A record
#   outputs.tf    운영자 콘솔/스크립트에 노출
###############################################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # ---------------------------------------------------------------------------
  # Remote state - S3 + DynamoDB lock.
  # 사전 1회 수동 부트스트랩:
  #   1) S3 bucket: iconia-tfstate-<account_id>
  #      versioning on, BlockPublicAccess all on, SSE-S3 (또는 KMS).
  #   2) DynamoDB table: iconia-tfstate-lock (PK LockID:String, PAY_PER_REQUEST).
  #
  # backend.hcl 또는 `terraform init -backend-config=bucket=...` 로 주입.
  # ---------------------------------------------------------------------------
  backend "s3" {
    bucket         = "iconia-tfstate-PLACEHOLDER"
    key            = "iconia/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "iconia-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      service     = "iconia"
      environment = var.env
      managed_by  = "terraform"
    }
  }
}

# 향후 CloudFront/ACM 추가 시 us-east-1 ACM 필요해서 alias 미리 정의.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = {
      service     = "iconia"
      environment = var.env
      managed_by  = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  name_prefix = "iconia-${var.env}"

  # Subnet IDs (신규 생성 또는 기존 주입).
  private_subnet_ids = var.create_network ? aws_subnet.private[*].id : var.private_subnet_ids
  public_subnet_ids  = var.create_network ? aws_subnet.public[*].id  : var.public_subnet_ids
  vpc_id             = var.create_network ? aws_vpc.main[0].id       : var.vpc_id
}
