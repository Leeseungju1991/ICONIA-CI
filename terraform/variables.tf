###############################################################################
# variables.tf — ICONIA AWS infra 공통 변수.
#
# 구성: Route53 + EC2 + S3 + EFS 4종 (RDS 제외 결정 — 2026-05-18).
# 운영자가 terraform apply 시 -var 또는 *.tfvars 로 주입.
###############################################################################

variable "env" {
  description = "배포 환경 식별자. dev / staging / prod 중 하나."
  type        = string
  default     = "prod"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "env must be one of: dev, staging, prod."
  }
}

variable "region" {
  description = "주 AWS region. 단일 region (ap-northeast-2) 가정."
  type        = string
  default     = "ap-northeast-2"
}

# -----------------------------------------------------------------------------
# 네트워크 — 기본 모드는 신규 VPC 생성 (network.tf). 기존 VPC 재사용시 vpc_id 주입.
# -----------------------------------------------------------------------------
variable "create_network" {
  description = "true 면 network.tf 가 VPC/Subnet/IGW/NAT/RouteTable 생성. false 면 기존 vpc_id 사용."
  type        = bool
  default     = true
}

variable "vpc_id" {
  description = "create_network=false 일 때 사용할 기존 VPC ID."
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "create_network=true 시 신규 VPC CIDR."
  type        = string
  default     = "10.42.0.0/16"
}

variable "azs" {
  description = "사용할 가용영역 목록. ap-northeast-2 기준 a/c 권장."
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDR. azs 와 길이 일치."
  type        = list(string)
  default     = ["10.42.1.0/24", "10.42.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDR (EC2/EFS). azs 와 길이 일치."
  type        = list(string)
  default     = ["10.42.11.0/24", "10.42.12.0/24"]
}

variable "private_subnet_ids" {
  description = "create_network=false 시 사용할 기존 private subnet ID 목록 (Multi-AZ >=2)."
  type        = list(string)
  default     = []
}

variable "public_subnet_ids" {
  description = "create_network=false 시 사용할 기존 public subnet ID 목록."
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# EC2 — 단일 인스턴스에 Server/AI/Admin 3개 systemd 서비스 + nginx 리버스 프록시.
# -----------------------------------------------------------------------------
variable "ec2_instance_type" {
  description = "운영 EC2 인스턴스 타입. AI(Genome) 추론 부하 고려. prod 는 m6i.large 이상 권장."
  type        = string
  default     = "t3.large"
}

variable "ec2_root_volume_size_gb" {
  description = "EC2 root EBS gp3 크기 GB."
  type        = number
  default     = 30
}

variable "ec2_key_pair_name" {
  description = "SSH 접속용 키페어 이름. 비우면 SSM Session Manager 만 허용 (권장)."
  type        = string
  default     = ""
}

variable "ec2_ami_id" {
  description = "EC2 AMI ID. 비우면 최신 Ubuntu 22.04 LTS (ap-northeast-2) 자동 조회."
  type        = string
  default     = ""
}

variable "ssh_allowed_cidrs" {
  description = "SSH(22) 허용 CIDR. ec2_key_pair_name 가 비어있으면 무시. 운영 권장은 [] + SSM 전용."
  type        = list(string)
  default     = []
}

variable "http_allowed_cidrs" {
  description = "HTTP/HTTPS 허용 CIDR. 일반적으로 [\"0.0.0.0/0\"]."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# -----------------------------------------------------------------------------
# RDS (PostgreSQL).
# -----------------------------------------------------------------------------
variable "db_engine_mode" {
  description = "RDS 엔진 모드: 'instance' (db.t4g.medium 단일) 또는 'aurora-serverless-v2'."
  type        = string
  default     = "instance"
  validation {
    condition     = contains(["instance", "aurora-serverless-v2"], var.db_engine_mode)
    error_message = "db_engine_mode must be 'instance' or 'aurora-serverless-v2'."
  }
}

variable "db_password" {
  description = "RDS master password. Secrets Manager 참조 권장. -var 또는 terraform.tfvars(gitignore) 로 주입."
  type        = string
  sensitive   = true
  default     = ""
}

variable "db_name" {
  description = "RDS 초기 DB name."
  type        = string
  default     = "iconia"
}

variable "db_username" {
  description = "RDS master username."
  type        = string
  default     = "iconia_admin"
}

variable "db_instance_class" {
  description = "instance 모드일 때 사용할 인스턴스 클래스."
  type        = string
  default     = "db.t4g.medium"
}

variable "db_allocated_storage_gb" {
  description = "instance 모드 storage GB. gp3."
  type        = number
  default     = 50
}

# -----------------------------------------------------------------------------
# S3.
# -----------------------------------------------------------------------------
variable "events_bucket_name" {
  description = "Events (HW 이미지/음성) 버킷 이름. 글로벌 유니크. 비우면 자동 명명."
  type        = string
  default     = ""
}

variable "exports_bucket_name" {
  description = "DataExport (PIPA/GDPR) 버킷 이름. events 와 분리 필수."
  type        = string
  default     = ""
}

variable "firmware_bucket_name" {
  description = "OTA 펌웨어 binary 버킷 이름."
  type        = string
  default     = ""
}

variable "artifacts_bucket_name" {
  description = "로컬에서 빌드한 server/ai/admin tarball 업로드 위치. EC2 가 pull."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# EFS.
# -----------------------------------------------------------------------------
variable "efs_throughput_mode" {
  description = "EFS throughput mode. bursting / provisioned / elastic."
  type        = string
  default     = "elastic"
}

# -----------------------------------------------------------------------------
# Route53.
# -----------------------------------------------------------------------------
variable "root_domain" {
  description = "운영 root domain. terraform.tfvars 에 실제 값 주입."
  type        = string
  default     = ""
}

variable "create_route53_records" {
  description = "Route53 A record 생성 여부. EC2 EIP 가 준비된 뒤 true 로 전환."
  type        = bool
  default     = true
}

variable "hosted_zone_id" {
  description = "기존 Route53 hosted zone ID. 비우면 route53.tf 가 zone 신규 생성."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# 공통 태그.
# -----------------------------------------------------------------------------
variable "tags" {
  description = "추가 공통 태그. provider default_tags 와 병합."
  type        = map(string)
  default     = {}
}
