<#
.SYNOPSIS
  RDS master password 를 강력 랜덤으로 생성해 AWS Secrets Manager 에 저장.

.DESCRIPTION
  terraform apply 직전 한 번 실행. db_password 평문이 디스크/리포에 절대 남지 않도록
  Secrets Manager 에서만 보관한다.

  생성한 시크릿 ARN 을 출력 → 운영자가 그 값을 terraform apply 의 -var 로 fetch.

.PARAMETER Region
  기본 ap-northeast-2.

.PARAMETER Env
  prod / staging / dev (Secret 경로 prefix).

.PARAMETER SecretName
  기본 iconia/<env>/db/master_password. 변경 시 IAM 정책 (iconia.tf 의
  iconia/${env}/* 패턴) 와 정합 확인.

.PARAMETER Length
  비밀번호 길이. 기본 32 (RDS 정책 한도 41 자 미만).

.PARAMETER ForceRotate
  기존 secret 이 있어도 새 값으로 덮어쓴다 (PutSecretValue). 평소엔 NoOp.

.EXAMPLE
  pwsh -File seed-db-password.ps1 -Env prod
#>

[CmdletBinding()]
param(
  [string] $Region = 'ap-northeast-2',
  [ValidateSet('prod','staging','dev')]
  [string] $Env = 'prod',
  [string] $SecretName,
  [int]    $Length = 32,
  [switch] $ForceRotate
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
  throw "aws CLI 가 PATH 에 없습니다."
}
if (-not $SecretName) { $SecretName = "iconia/$Env/db/master_password" }

# ----- 강력 랜덤 비밀번호 생성 -----
# RDS Postgres 허용 문자: 인쇄 가능 ASCII 중 / @ " 공백 제외.
# 안전 문자만 사용 (정책 단순화): A-Z a-z 0-9 + 보조 기호 #$%&*-_=+?
$alphabet = [char[]]('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789#$%&*-_=+?')
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$buf = New-Object byte[] ($Length * 2)
$rng.GetBytes($buf)
$pwd = -join (0..($Length - 1) | ForEach-Object {
  $idx = [int]([System.BitConverter]::ToUInt16($buf, $_ * 2) % $alphabet.Length)
  $alphabet[$idx]
})

Write-Host "Generated password length=$Length (cryptographic RNG)"

# ----- 시크릿 존재 확인 -----
$exists = $false
try {
  $desc = & aws secretsmanager describe-secret --secret-id $SecretName --region $Region 2>$null
  if ($LASTEXITCODE -eq 0 -and $desc) { $exists = $true }
} catch {}

if ($exists -and -not $ForceRotate) {
  Write-Host "Secret '$SecretName' 이 이미 존재합니다. 회전하려면 -ForceRotate."
  Write-Host ""
  Write-Host "기존 시크릿 ARN:"
  & aws secretsmanager describe-secret --secret-id $SecretName --region $Region --query ARN --output text
  exit 0
}

$payload = @{ username = "iconia_admin"; password = $pwd } | ConvertTo-Json -Compress

if ($exists) {
  Write-Host "Rotating secret '$SecretName' (ForceRotate=true)..."
  & aws secretsmanager put-secret-value --region $Region `
    --secret-id $SecretName --secret-string $payload | Out-Null
} else {
  Write-Host "Creating secret '$SecretName'..."
  & aws secretsmanager create-secret --region $Region `
    --name $SecretName --secret-string $payload `
    --description "ICONIA RDS master password ($Env)" | Out-Null
}
if ($LASTEXITCODE -ne 0) { throw "Secrets Manager 호출 실패" }

$arn = & aws secretsmanager describe-secret --secret-id $SecretName --region $Region --query ARN --output text

Write-Host ""
Write-Host "========================================"
Write-Host "Secret ARN: $arn"
Write-Host ""
Write-Host "다음 단계 - terraform apply 에 fetch 해서 주입:"
Write-Host ""
Write-Host '  $pwd = aws secretsmanager get-secret-value `'
Write-Host "          --secret-id $SecretName --region $Region ``"
Write-Host '          --query SecretString --output text | ConvertFrom-Json | % password'
Write-Host '  terraform apply -var "db_password=$pwd"'
Write-Host ""
Write-Host "또는 EC2 부팅 시 secretsLoader 가 직접 GetSecretValue 호출 (권장)."
Write-Host "========================================"
