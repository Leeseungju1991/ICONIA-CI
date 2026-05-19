<#
.SYNOPSIS
  EC2 인스턴스에 SSM Run Command 로 ec2-pull-and-restart.sh 호출.

.DESCRIPTION
  build-and-upload.ps1 이 S3 에 올린 최신 artifact 를 EC2 가 pull + restart 하게 한다.
  SSM Run Command (AWS-RunShellScript) 를 사용 - SSH 불필요.

.PARAMETER Service
  server / ai / admin / all

.PARAMETER InstanceId
  EC2 instance ID. 생략 시 환경변수 ICONIA_EC2_INSTANCE_ID 또는 태그 기반 자동 조회.

.PARAMETER Region
  AWS region. 기본 ap-northeast-2.

.PARAMETER NamePrefix
  태그 기반 조회 시 사용 (Name=iconia-<env>-host). 기본 iconia-prod.

.EXAMPLE
  pwsh -File trigger-deploy.ps1 -Service all
#>

[CmdletBinding()]
param(
  [ValidateSet('server','ai','admin','all')]
  [string] $Service = 'all',

  [string] $InstanceId = $env:ICONIA_EC2_INSTANCE_ID,

  [string] $Region = 'ap-northeast-2',

  [string] $NamePrefix = 'iconia-prod'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
  throw "aws CLI 가 PATH 에 없습니다."
}

if (-not $InstanceId) {
  Write-Host "InstanceId 미지정 -> 태그(Name=$NamePrefix-host) 로 조회"
  $json = & aws ec2 describe-instances `
    --region $Region `
    --filters "Name=tag:Name,Values=$NamePrefix-host" "Name=instance-state-name,Values=running" `
    --query 'Reservations[].Instances[].InstanceId' `
    --output json
  if ($LASTEXITCODE -ne 0) { throw "EC2 조회 실패" }
  $ids = $json | ConvertFrom-Json
  if ($ids.Count -eq 0) { throw "running 인스턴스를 찾지 못했습니다 (tag Name=$NamePrefix-host)" }
  if ($ids.Count -gt 1) { throw "여러 인스턴스가 매칭됩니다. -InstanceId 명시 필요: $($ids -join ', ')" }
  $InstanceId = $ids[0]
  Write-Host "Resolved InstanceId=$InstanceId"
}

# SSM 화이트리스트: Service 는 [ValidateSet] 으로 server|ai|admin|all 만 허용되므로 셸 인젝션 안전.
$cmd = "/usr/local/bin/iconia-pull-and-restart.sh $Service"

# --parameters 의 JSON 을 PowerShell 따옴표/이스케이프 지옥 없이 전달하려고 임시 파일 경유.
# (이전 구현은 System.Web.HttpUtility 의존 + '^|$' regex 가 잘못된 인용 생성으로 SSM 호출 실패.)
$paramsObj  = @{ commands = @($cmd) }
$paramsJson = $paramsObj | ConvertTo-Json -Compress
$paramsFile = Join-Path $env:TEMP "iconia-ssm-params-$(Get-Random).json"
Set-Content -Path $paramsFile -Value $paramsJson -Encoding ASCII -NoNewline

Write-Host "SSM SendCommand -> $InstanceId : $cmd"
try {
  $send = & aws ssm send-command `
    --region $Region `
    --document-name 'AWS-RunShellScript' `
    --instance-ids $InstanceId `
    --comment "ICONIA deploy: $Service" `
    --parameters "file://$paramsFile" `
    --cloud-watch-output-config 'CloudWatchOutputEnabled=true' `
    --output json
} finally {
  Remove-Item -Force -ErrorAction SilentlyContinue $paramsFile
}

if ($LASTEXITCODE -ne 0) { throw "SSM SendCommand 실패" }

$cmdId = ($send | ConvertFrom-Json).Command.CommandId
Write-Host "CommandId: $cmdId"
Write-Host "진행 추적: aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $InstanceId"
Write-Host ""
Write-Host "결과 polling (최대 5분)..."

$deadline = (Get-Date).AddMinutes(5)
do {
  Start-Sleep -Seconds 5
  $inv = & aws ssm get-command-invocation `
    --region $Region `
    --command-id $cmdId `
    --instance-id $InstanceId `
    --output json 2>$null
  if ($LASTEXITCODE -eq 0 -and $inv) {
    $obj = $inv | ConvertFrom-Json
    Write-Host "  Status=$($obj.Status)"
    if ($obj.Status -in 'Success','Failed','Cancelled','TimedOut') {
      Write-Host ""
      Write-Host "==== STDOUT ===="
      Write-Host $obj.StandardOutputContent
      Write-Host "==== STDERR ===="
      Write-Host $obj.StandardErrorContent
      if ($obj.Status -ne 'Success') { exit 1 }
      exit 0
    }
  }
} while ((Get-Date) -lt $deadline)

Write-Warning "5분 초과 - 콘솔에서 직접 확인 필요"
exit 2
