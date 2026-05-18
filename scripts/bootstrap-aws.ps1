<#
.SYNOPSIS
  Terraform 사전 부트스트랩 - tfstate 버킷 + DynamoDB lock 테이블 1회 생성.

.DESCRIPTION
  본 폴더의 terraform/main.tf 가 사용하는 remote state backend (S3 + DynamoDB lock) 의
  pre-existing 리소스 2개를 idempotent 하게 생성한다.

    1) S3 bucket: iconia-tfstate-<ACCOUNT_ID>
       versioning on, BlockPublicAccess all on, SSE-S3.
    2) DynamoDB: iconia-tfstate-lock (PK LockID:String, PAY_PER_REQUEST).

  이미 존재하면 NoOp 으로 통과. 첫 실행 후 README 가 안내하는 'terraform init' 의
  -backend-config 인자를 그대로 출력한다.

.PARAMETER Region
  AWS region. 기본 ap-northeast-2.

.PARAMETER AccountId
  생략 시 aws sts get-caller-identity 로 자동 조회.

.EXAMPLE
  pwsh -File 6. CI\scripts\bootstrap-aws.ps1
#>

[CmdletBinding()]
param(
  [string] $Region = 'ap-northeast-2',
  [string] $AccountId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
  throw "aws CLI 가 PATH 에 없습니다."
}

if (-not $AccountId) {
  Write-Host "AccountId 조회 중..."
  $AccountId = (& aws sts get-caller-identity --query Account --output text 2>&1).Trim()
  if ($LASTEXITCODE -ne 0 -or -not $AccountId) {
    throw "aws sts get-caller-identity 실패 - 'aws configure' 후 다시 실행"
  }
  Write-Host "AccountId = $AccountId"
}

$bucket = "iconia-tfstate-$AccountId"
$table  = "iconia-tfstate-lock"

# ---------- 1) S3 bucket ----------
Write-Host "`n[1/2] S3 bucket: $bucket"
$exists = & aws s3api head-bucket --bucket $bucket --region $Region 2>&1
if ($LASTEXITCODE -eq 0) {
  Write-Host "  already exists - skip"
} else {
  if ($Region -eq 'us-east-1') {
    & aws s3api create-bucket --bucket $bucket --region $Region | Out-Null
  } else {
    & aws s3api create-bucket --bucket $bucket --region $Region `
      --create-bucket-configuration "LocationConstraint=$Region" | Out-Null
  }
  if ($LASTEXITCODE -ne 0) { throw "S3 create-bucket 실패" }
  Write-Host "  created."
}

Write-Host "  enable versioning..."
& aws s3api put-bucket-versioning --bucket $bucket --region $Region `
  --versioning-configuration "Status=Enabled" | Out-Null

Write-Host "  block public access..."
& aws s3api put-public-access-block --bucket $bucket --region $Region `
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" | Out-Null

Write-Host "  SSE (AES256)..."
$sse = @"
{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}
"@
$sse | Out-File -FilePath "$env:TEMP\iconia-tfstate-sse.json" -Encoding ASCII
& aws s3api put-bucket-encryption --bucket $bucket --region $Region `
  --server-side-encryption-configuration "file://$env:TEMP\iconia-tfstate-sse.json" | Out-Null

# ---------- 2) DynamoDB lock table ----------
Write-Host "`n[2/2] DynamoDB table: $table"
$descr = & aws dynamodb describe-table --table-name $table --region $Region 2>&1
if ($LASTEXITCODE -eq 0) {
  Write-Host "  already exists - skip"
} else {
  & aws dynamodb create-table --region $Region `
    --table-name $table `
    --attribute-definitions "AttributeName=LockID,AttributeType=S" `
    --key-schema "AttributeName=LockID,KeyType=HASH" `
    --billing-mode PAY_PER_REQUEST | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "DynamoDB create-table 실패" }
  Write-Host "  created - waiting ACTIVE..."
  & aws dynamodb wait table-exists --table-name $table --region $Region | Out-Null
}

# ---------- 안내 ----------
Write-Host "`n========================================"
Write-Host "Bootstrap 완료. 다음 단계:"
Write-Host ""
Write-Host "  cd '6. CI/terraform'"
Write-Host "  Copy-Item terraform.tfvars.example terraform.tfvars"
Write-Host "  # terraform.tfvars 의 root_domain / hosted_zone_id 등 채우기"
Write-Host ""
Write-Host "  terraform init ``"
Write-Host "    -backend-config=`"bucket=$bucket`" ``"
Write-Host "    -backend-config=`"key=iconia/terraform.tfstate`" ``"
Write-Host "    -backend-config=`"region=$Region`" ``"
Write-Host "    -backend-config=`"dynamodb_table=$table`""
Write-Host ""
Write-Host "  # DB password 등록 (Secrets Manager 자동 생성):"
Write-Host "  pwsh -File ..\scripts\seed-db-password.ps1"
Write-Host ""
Write-Host "  terraform plan -out=tfplan -var `"db_password=`$(Get-Secret iconia/prod/db/password)`""
Write-Host "  terraform apply tfplan"
Write-Host "========================================"
