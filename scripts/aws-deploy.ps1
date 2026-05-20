<#
.SYNOPSIS
  ICONIA AWS 실배포 완전 자동화 — terraform → 빌드·업로드 → SSM 배포 → 스모크.

.DESCRIPTION
  "AWS 실배포 즉시 출시" 경로의 단일 진입점.
  로컬에서 동작 확인을 마친 뒤, 이 스크립트 한 번이면 인프라 정합 확인부터
  검증까지 끝난다. GitHub Actions(deploy.yml)가 표준 경로이고, 본 스크립트는
  운영자 로컬(Windows PowerShell)에서 동일 흐름을 수동 실행하는 폴백이다.

  단계:
    1. .env 로드 + ICONIA_TARGET=aws 확인
    2. (-ApplyInfra) terraform init/plan/apply — 인프라 정합
    3. terraform output 으로 artifacts bucket / instance id / domain 해석
    4. build-and-upload.ps1 — 3개 서비스 + _bootstrap 빌드 → S3
    5. trigger-deploy.ps1 — SSM RunShellScript → EC2 무중단 배포 + 자동 롤백
    6. post-deploy 검증 — Route53 FQDN 외부 스모크 (curl)

  무중단 / 테스트 게이트 / 자동 롤백 / 헬스체크는 EC2 호스트의
  ec2-pull-and-restart.sh 와 deploy.yml 의 test-gate 가 보장한다. 본 스크립트는
  그 파이프라인을 운영자 콘솔에서 한 번에 트리거한다.

.PARAMETER Service
  server / ai / admin / all. 기본 all.

.PARAMETER ApplyInfra
  terraform apply 까지 수행 (인프라 변경이 있을 때만). 미지정 시 빌드·배포만.

.PARAMETER DryRun
  빌드·업로드까지만 (SSM 배포/스모크 생략) — 리허설용.

.PARAMETER RepoRoot
  ICONIA 모노레포 루트. 비우면 .env / 6.CI 상위 자동 추정.

.EXAMPLE
  Copy-Item .env.example .env       # ICONIA_TARGET=aws 로 수정 + 값 채움
  pwsh -File scripts/aws-deploy.ps1 -Service all

.EXAMPLE
  pwsh -File scripts/aws-deploy.ps1 -ApplyInfra -Service all
#>

[CmdletBinding()]
param(
  [ValidateSet('server','ai','admin','all')]
  [string] $Service = 'all',
  [switch] $ApplyInfra,
  [switch] $DryRun,
  [string] $RepoRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ciRoot     = Split-Path -Parent $scriptRoot
$tfDir      = Join-Path $ciRoot 'terraform'

function Import-DotEnv {
  param([string] $Path)
  $h = @{}
  if (Test-Path -LiteralPath $Path) {
    foreach ($raw in Get-Content -LiteralPath $Path) {
      $line = $raw.Trim()
      if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
      $idx = $line.IndexOf('=')
      if ($idx -lt 1) { continue }
      $h[$line.Substring(0, $idx).Trim()] = $line.Substring($idx + 1).Trim()
    }
  }
  return $h
}
$dotenv = Import-DotEnv (Join-Path $ciRoot '.env')
function Cfg { param([string]$K,[string]$D='')
  if ($dotenv.ContainsKey($K) -and $dotenv[$K]) { return $dotenv[$K] }
  $v = [Environment]::GetEnvironmentVariable($K); if ($v) { return $v }; return $D
}

# ----- 단일 토글 확인 -----
$target = Cfg 'ICONIA_TARGET' 'aws'
if ($target -ne 'aws') {
  Write-Warning ".env 의 ICONIA_TARGET 이 '$target' 입니다. AWS 배포를 계속하려면 'aws' 권장."
}

$region = Cfg 'AWS_REGION' 'ap-northeast-2'
if (-not $RepoRoot) { $RepoRoot = Cfg 'ICONIA_REPO_ROOT' }
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $ciRoot }

foreach ($t in @('aws')) {
  if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { throw "$t CLI 가 PATH 에 없습니다." }
}

Write-Host "================ ICONIA AWS 배포 ================" -ForegroundColor Cyan
Write-Host "  target    : aws"
Write-Host "  service   : $Service"
Write-Host "  region    : $region"
Write-Host "  applyInfra: $ApplyInfra   dryRun: $DryRun"
Write-Host "=================================================" -ForegroundColor Cyan

# ----- 1) terraform (선택) -----
if ($ApplyInfra) {
  if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    throw "terraform 이 PATH 에 없습니다."
  }
  $backend = Join-Path $tfDir 'backend.hcl'
  Push-Location $tfDir
  try {
    Write-Host "[tf] init"
    if (Test-Path $backend) {
      & terraform init -input=false -backend-config="$backend"
    } else {
      Write-Warning "backend.hcl 없음 — backend.hcl.example 참고해 작성 권장. partial init 시도."
      & terraform init -input=false
    }
    if ($LASTEXITCODE -ne 0) { throw "terraform init 실패" }
    Write-Host "[tf] validate"
    & terraform validate
    if ($LASTEXITCODE -ne 0) { throw "terraform validate 실패" }
    Write-Host "[tf] plan"
    & terraform plan -input=false -out=tfplan
    if ($LASTEXITCODE -ne 0) { throw "terraform plan 실패" }
    Write-Host "[tf] apply"
    & terraform apply -input=false tfplan
    if ($LASTEXITCODE -ne 0) { throw "terraform apply 실패" }
  } finally { Pop-Location }
}

# ----- 2) terraform output / .env 로 배포 좌표 해석 -----
function Get-TfOutput {
  param([string] $Name)
  if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) { return '' }
  try {
    $v = & terraform -chdir="$tfDir" output -raw $Name 2>$null
    if ($LASTEXITCODE -eq 0 -and $v) { return $v.Trim() }
  } catch {}
  return ''
}

$artifactsBucket = Cfg 'ICONIA_ARTIFACTS_BUCKET'
if (-not $artifactsBucket) { $artifactsBucket = Get-TfOutput 'artifacts_bucket_name' }
if (-not $artifactsBucket) { throw "artifacts bucket 미해석 — .env ICONIA_ARTIFACTS_BUCKET 또는 terraform output 필요." }

$instanceId = Cfg 'ICONIA_EC2_INSTANCE_ID'
if (-not $instanceId) { $instanceId = Get-TfOutput 'ec2_instance_id' }

$rootDomain = Cfg 'ICONIA_ROOT_DOMAIN'
if (-not $rootDomain) { $rootDomain = Get-TfOutput 'api_fqdn' -replace '^api\.', '' }

Write-Host "[deploy] artifacts bucket = $artifactsBucket"
Write-Host "[deploy] ec2 instance     = $(if($instanceId){$instanceId}else{'(태그 자동조회)'})"
Write-Host "[deploy] root domain      = $(if($rootDomain){$rootDomain}else{'(스모크 생략)'})"

# ----- 3) 빌드 + S3 업로드 -----
$buildScript = Join-Path $scriptRoot 'build-and-upload.ps1'
Write-Host "[build] build-and-upload.ps1 -Service $Service"
& pwsh -File $buildScript -Service $Service -ArtifactsBucket $artifactsBucket -Region $region
if ($LASTEXITCODE -ne 0) { throw "build-and-upload 실패" }

if ($DryRun) {
  Write-Host "[dry-run] 빌드·업로드 완료 — SSM 배포/스모크 생략." -ForegroundColor Yellow
  exit 0
}

# ----- 4) SSM 배포 트리거 (호스트에서 무중단 swap + 자동 롤백) -----
$triggerScript = Join-Path $scriptRoot 'trigger-deploy.ps1'
$triggerArgs = @('-File', $triggerScript, '-Service', $Service, '-Region', $region)
if ($instanceId) { $triggerArgs += @('-InstanceId', $instanceId) }
Write-Host "[deploy] trigger-deploy.ps1"
& pwsh @triggerArgs
if ($LASTEXITCODE -ne 0) { throw "trigger-deploy 실패 — EC2 호스트가 자동 롤백을 수행했을 수 있음. CloudWatch ICONIA/Deploy 확인." }

# ----- 5) 외부 스모크 검증 -----
if ($rootDomain) {
  if ($Service -eq 'all' -or $Service -eq 'server') {
    Write-Host "[smoke] https://api.$rootDomain/health"
    try {
      $r = Invoke-WebRequest -Uri "https://api.$rootDomain/health" -UseBasicParsing -TimeoutSec 15
      Write-Host "  server -> $($r.StatusCode)" -ForegroundColor Green
    } catch { Write-Warning "server 스모크 실패: $_" }
  }
  if ($Service -eq 'all' -or $Service -eq 'ai') {
    Write-Host "[smoke] https://ai.$rootDomain/health"
    try {
      $r = Invoke-WebRequest -Uri "https://ai.$rootDomain/health" -UseBasicParsing -TimeoutSec 15
      Write-Host "  ai -> $($r.StatusCode)" -ForegroundColor Green
    } catch { Write-Warning "ai 스모크 실패: $_" }
  }
  if ($Service -eq 'all' -or $Service -eq 'admin') {
    Write-Host "[smoke] https://admin.$rootDomain/"
    try {
      $r = Invoke-WebRequest -Uri "https://admin.$rootDomain/" -UseBasicParsing -TimeoutSec 15
      Write-Host "  admin -> $($r.StatusCode)" -ForegroundColor Green
    } catch { Write-Warning "admin 스모크 실패: $_" }
  }
} else {
  Write-Host "[smoke] root domain 미해석 — 외부 스모크 생략. ICONIA_ROOT_DOMAIN 설정 권장." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "================ AWS 배포 완료 ================" -ForegroundColor Cyan
Write-Host "  서비스: $Service"
Write-Host "  EC2 호스트가 atomic swap + 헬스체크 30s + 실패 시 자동 롤백 수행."
Write-Host "  배포 가시성: CloudWatch ICONIA/Deploy namespace + /iconia/<env>/* 로그그룹"
Write-Host "===============================================" -ForegroundColor Cyan
