<#
.SYNOPSIS
  ICONIA AWS 실배포 완전 자동화 — terraform → 빌드·업로드 → SSM 배포 → 스모크 → (선택)Seed.

.DESCRIPTION
  "AWS 실배포 즉시 출시" 경로의 단일 진입점.
  로컬에서 동작 확인을 마친 뒤, 이 스크립트 한 번이면 인프라 정합 확인부터
  검증까지 끝난다. GitHub Actions(deploy.yml)가 표준 경로이고, 본 스크립트는
  운영자 로컬(Windows PowerShell)에서 동일 흐름을 수동 실행하는 폴백이다.

  단계:
    1. .env 로드 + DEPLOY_TARGET=aws 확인
    2. preflight — 6 레포 placeholder 검사 + (주)숨코리아 약관/사업자정보 LEGAL guard
       + seed-data preflight (cross-repo ICONIA-SERVER/prisma/seed-data/*.json)
    3. (-ApplyInfra) terraform init/plan/apply — 인프라 정합
    4. terraform output 으로 artifacts bucket / instance id / domain 해석
    5. build-and-upload.ps1 — 3개 서비스 + _bootstrap 빌드 → S3
       (-Seed 단독 실행 모드면 빌드·업로드 skip)
    6. trigger-deploy.ps1 — SSM RunShellScript → EC2 무중단 배포 + 자동 롤백
    7. post-deploy 검증 — Route53 FQDN 외부 스모크 (curl)
    8. (선택) Seed — SSM Run Command 로 EC2 위 `npm run seed:aws` 실행
       - -ApplyInfra 첫 배포 자동 감지: /v1/admin/seed/status 의 last_seeded_at == null 이면 자동 시드
       - -NoSeed 면 자동 시드 skip
       - 무인자 일반 배포는 시드 하지 않음 (운영 데이터 보호)

  무중단 / 테스트 게이트 / 자동 롤백 / 헬스체크는 EC2 호스트의
  ec2-pull-and-restart.sh 와 deploy.yml 의 test-gate 가 보장한다. 본 스크립트는
  그 파이프라인을 운영자 콘솔에서 한 번에 트리거한다.

.PARAMETER Service
  server / ai / admin / all. 기본 all.

.PARAMETER ApplyInfra
  terraform apply 까지 수행 (인프라 변경이 있을 때만). 미지정 시 빌드·배포만.

.PARAMETER DryRun
  빌드·업로드까지만 (SSM 배포/스모크/시드 생략) — 리허설용.
  -Seed 와 조합 시 시드 명령도 echo 만 하고 실행 안 함.

.PARAMETER Seed
  시드만 단독 실행 (인프라·코드 배포 생략). SSM Run Command 로 EC2 위 npm run seed:aws 호출.

.PARAMETER Reseed
  truncate + 시드 (개발용). SEED_RESET=1 env 전달. 운영 데이터 파괴 — 명시 동의 후에만 사용.

.PARAMETER NoSeed
  -ApplyInfra 흐름의 첫 배포 자동시드를 skip. 무인자 일반 배포는 원래 시드 안 함.

.PARAMETER EssentialOnly
  필수 카테고리만 시드 (feed / products / orders skip). SEED_SKIP_NONESSENTIAL=1 전달.

.PARAMETER RepoRoot
  ICONIA 모노레포 루트. 비우면 .env / 6.CI 상위 자동 추정.

.PARAMETER Canary
  Canary 배포 비율(%) — 1..50 사이. ALB weighted target group 으로 실제 트래픽 분배.
  흐름:
    1) 새 빌드를 canary TG (별도 인스턴스 1대) 에 배포
    2) ALB listener rule weight = (100-pct) / pct 로 갱신
    3) 5분 헬스체크 polling → 통과 시 promote 권장 메시지 출력 (수동 -PromoteCanary)
    4) 실패 시 -RollbackCanary 안내
  0 이면 일반 atomic swap (기존 무중단 배포). -Seed / -Reseed / -NoSeed 와 조합 불가.

.PARAMETER PromoteCanary
  canary TG 의 빌드를 primary TG 로 atomic swap. weight 100/0 으로 되돌리고
  canary TG 의 인스턴스를 primary 에 register, primary 의 기존 인스턴스를 deregister.
  -Canary 와 동시 사용 금지.

.PARAMETER RollbackCanary
  canary 실패 시 — canary TG drain (deregister-targets) + weight 100/0 으로 즉시 복원.
  primary TG 의 기존 빌드는 그대로 유지 (atomic swap 안 한 상태이므로 무사).
  -Canary / -PromoteCanary 와 동시 사용 금지.

.EXAMPLE
  Copy-Item .env.example .env       # DEPLOY_TARGET=aws 로 수정 + 값 채움
  pwsh -File scripts/aws-deploy.ps1 -Service all

.EXAMPLE
  # 첫 배포 — 인프라 + 코드 + 자동 시드 (테이블이 비어 있을 때만)
  pwsh -File scripts/aws-deploy.ps1 -ApplyInfra -Service all

.EXAMPLE
  # 첫 배포지만 시드는 수동으로 — 자동 시드 skip
  pwsh -File scripts/aws-deploy.ps1 -ApplyInfra -NoSeed
  pwsh -File scripts/aws-deploy.ps1 -Seed -EssentialOnly

.EXAMPLE
  # 개발 DB 재시드 (truncate + seed)
  pwsh -File scripts/aws-deploy.ps1 -Reseed
#>

[CmdletBinding()]
param(
  [ValidateSet('server','ai','admin','all')]
  [string] $Service = 'all',
  [switch] $ApplyInfra,
  [switch] $DryRun,
  [switch] $Seed,
  [switch] $Reseed,
  [switch] $NoSeed,
  [switch] $EssentialOnly,
  [string] $RepoRoot,
  [ValidateRange(0, 50)]
  [int] $Canary = 0,
  [switch] $PromoteCanary,
  [switch] $RollbackCanary
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
$target = Cfg 'DEPLOY_TARGET' 'aws'
if ($target -ne 'aws') {
  Write-Warning ".env 의 DEPLOY_TARGET 이 '$target' 입니다. AWS 배포를 계속하려면 'aws' 권장."
}

$region = Cfg 'AWS_REGION' 'ap-northeast-2'
if (-not $RepoRoot) { $RepoRoot = Cfg 'ICONIA_REPO_ROOT' }
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $ciRoot }

# ----- 시드 switch 사전 검증 (aws CLI 체크보다 먼저 — 빠른 실패) -----
# 상충 조합 차단.
if ($Seed -and $Reseed) {
  throw "-Seed 와 -Reseed 는 동시 사용 불가. -Reseed 가 truncate+seed 포함."
}
if ($Seed -and $NoSeed) {
  throw "-Seed 와 -NoSeed 는 상호 모순."
}
if ($Reseed -and $NoSeed) {
  throw "-Reseed 와 -NoSeed 는 상호 모순."
}
# 단독 시드 모드 = 빌드/배포 skip.
$seedOnlyMode = ($Seed -or $Reseed) -and (-not $ApplyInfra)

# ----- Canary switch 사전 검증 -----
# canary rollout 은 단독 흐름 — 시드/단독 시드와 혼용 불가.
$canaryFlagCount = 0
if ($Canary -gt 0)      { $canaryFlagCount++ }
if ($PromoteCanary)     { $canaryFlagCount++ }
if ($RollbackCanary)    { $canaryFlagCount++ }
if ($canaryFlagCount -gt 1) {
  throw "-Canary / -PromoteCanary / -RollbackCanary 는 상호 배타. 한 번에 하나만 사용."
}
$canaryMode = $canaryFlagCount -gt 0
if ($canaryMode -and ($Seed -or $Reseed)) {
  throw "canary rollout 중에는 시드 동시 실행 불가 — canary promote 완료 후 별도 호출."
}
if ($canaryMode -and $seedOnlyMode) {
  throw "canary 와 SEED-ONLY 모드 동시 사용 불가."
}
if ($canaryMode -and $ApplyInfra) {
  Write-Warning "[canary] -ApplyInfra 와 canary 흐름 동시 사용 — 인프라 변경은 canary 와 무관하므로 별도 호출 권장."
}

foreach ($t in @('aws')) {
  if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { throw "$t CLI 가 PATH 에 없습니다." }
}

Write-Host "================ ICONIA AWS 배포 ================" -ForegroundColor Cyan
Write-Host "  target    : aws"
Write-Host "  service   : $Service"
Write-Host "  region    : $region"
Write-Host "  applyInfra: $ApplyInfra   dryRun: $DryRun"
Write-Host "  seed      : Seed=$Seed Reseed=$Reseed NoSeed=$NoSeed EssentialOnly=$EssentialOnly"
Write-Host "  canary    : Canary=$Canary% Promote=$PromoteCanary Rollback=$RollbackCanary"
Write-Host "  repoRoot  : $RepoRoot"
if ($seedOnlyMode) {
  Write-Host "  *** SEED-ONLY MODE — 인프라/빌드/배포 skip, 시드만 실행 ***" -ForegroundColor Yellow
}
if ($canaryMode) {
  Write-Host "  *** CANARY MODE — ALB weighted TG (canary=$Canary% promote=$PromoteCanary rollback=$RollbackCanary) ***" -ForegroundColor Yellow
}
Write-Host "=================================================" -ForegroundColor Cyan

# ----- 0) preflight — 약관/사업자정보 placeholder 검사 -----
# (주)숨코리아 사업자등록번호 / 통신판매업 신고번호 / 대표자 등 placeholder 가
# prod 배포로 새는 사고 차단. 정본 갱신 절차는 docs/legal/business-info.md.
# 단독 시드 모드에서도 placeholder 자체는 검사 안 해도 되지만 (인프라 변동 X)
# seed-data preflight 는 반드시 통과해야 함.
if (-not $seedOnlyMode -and -not $canaryMode) {
  Write-Host "[preflight] 6 레포 placeholder + (주)숨코리아 약관/사업자정보 검사"
  $preflightPs1 = Join-Path $scriptRoot 'preflight-placeholders.ps1'
  if (Test-Path -LiteralPath $preflightPs1) {
    & pwsh -File $preflightPs1 -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) {
      throw "preflight 실패 — placeholder 잔존. docs/legal/business-info.md 갱신 후 재시도."
    }
  } else {
    Write-Warning "preflight-placeholders.ps1 누락 — 검사 skip (CI 의 release-preflight 가 최종 게이트)."
  }
}

# seed-data preflight (시드를 실제로 트리거할 가능성이 있을 때만 강제).
$willSeed = $Seed -or $Reseed -or ($ApplyInfra -and (-not $NoSeed))
if ($willSeed) {
  Write-Host "[preflight] seed-data (cross-repo ICONIA-SERVER/prisma/seed-data)"
  $seedPreflight = Join-Path $scriptRoot 'preflight-seed-data.ps1'
  if (Test-Path -LiteralPath $seedPreflight) {
    $spArgs = @('-File', $seedPreflight)
    if ($EssentialOnly) { $spArgs += '-EssentialOnly' }
    & pwsh @spArgs
    if ($LASTEXITCODE -ne 0) {
      throw "seed-data preflight 실패 — 필수 카테고리 결손. ICONIA-APP / ICONIA-SERVER 에이전트 산출물 확인."
    }
  } else {
    Write-Warning "preflight-seed-data.ps1 누락 — seed-data 검증 skip."
  }
}

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
if (-not $seedOnlyMode -and -not $canaryMode -and -not $artifactsBucket) {
  throw "artifacts bucket 미해석 — .env ICONIA_ARTIFACTS_BUCKET 또는 terraform output 필요."
}

$instanceId = Cfg 'ICONIA_EC2_INSTANCE_ID'
if (-not $instanceId) { $instanceId = Get-TfOutput 'ec2_instance_id' }

$rootDomain = Cfg 'ICONIA_ROOT_DOMAIN'
if (-not $rootDomain) { $rootDomain = Get-TfOutput 'api_fqdn' -replace '^api\.', '' }

Write-Host "[deploy] artifacts bucket = $artifactsBucket"
Write-Host "[deploy] ec2 instance     = $(if($instanceId){$instanceId}else{'(태그 자동조회)'})"
Write-Host "[deploy] root domain      = $(if($rootDomain){$rootDomain}else{'(스모크 생략)'})"

# ----- Seed 헬퍼 함수들 -----------------------------------------------------------

function Resolve-Ec2InstanceId {
  param(
    [string] $InstanceId,
    [string] $Region,
    [string] $NamePrefix = 'iconia-prod'
  )
  if ($InstanceId) { return $InstanceId }
  Write-Host "  [ssm] InstanceId 미지정 -> 태그(Name=$NamePrefix-host) 자동조회"
  $json = & aws ec2 describe-instances `
    --region $Region `
    --filters "Name=tag:Name,Values=$NamePrefix-host" "Name=instance-state-name,Values=running" `
    --query 'Reservations[].Instances[].InstanceId' `
    --output json
  if ($LASTEXITCODE -ne 0) { throw "EC2 조회 실패" }
  $ids = $json | ConvertFrom-Json
  if (-not $ids -or $ids.Count -eq 0) { throw "running 인스턴스를 찾지 못했습니다 (tag Name=$NamePrefix-host)" }
  if ($ids.Count -gt 1) { throw "여러 인스턴스 매칭 — -InstanceId 명시 필요: $($ids -join ', ')" }
  return $ids[0]
}

function Test-SeedNeeded {
  <#
    SERVER 의 /v1/admin/seed/status 호출 → last_seeded_at == null 이면 시드 필요.
    Route53 외부 도메인이 있을 때만 호출. 호출 실패 / 404 / 미배포면 보수적으로 $false 반환
    (자동 시드 발동 안 함 — 명시 -Seed 로만).
  #>
  param([string] $RootDomain)
  if (-not $RootDomain) { return $false }
  $url = "https://api.$RootDomain/v1/admin/seed/status"
  try {
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    if ($resp.StatusCode -ne 200) { return $false }
    $obj = $resp.Content | ConvertFrom-Json
    if ($obj.PSObject.Properties.Name -contains 'last_seeded_at') {
      return [string]::IsNullOrEmpty([string]$obj.last_seeded_at)
    }
  } catch {
    Write-Host "  [seed-status] 호출 실패 ($($_.Exception.Message)) — 자동 시드 안 함." -ForegroundColor Yellow
    return $false
  }
  return $false
}

function Invoke-Seed {
  <#
    EC2 위에서 `cd /app/server && npm run seed:aws` 를 SSM Run Command 로 실행한다.
    환경 변수:
      SEED_RESET=1               (Reseed 시 — truncate)
      SEED_SKIP_NONESSENTIAL=1   (EssentialOnly 시 — feed/products/orders skip)
      DRY_RUN=1                  (DryRun 시 — server seed 도 dry-run 모드)
    2차 폴백: SSM 호출 자체 실패 시 (예: instance 미준비) /v1/admin/seed/run endpoint 호출.
              ADMIN_SEED_ENABLED=1 + admin JWT 가 필요 — 본 스크립트는 토큰을 다루지 않으므로 안내만.
  #>
  param(
    [switch] $Reseed,
    [switch] $EssentialOnly,
    [switch] $DryRun,
    [Parameter(Mandatory=$true)][string] $InstanceId,
    [Parameter(Mandatory=$true)][string] $Region
  )

  if (-not $InstanceId) { throw "Invoke-Seed: InstanceId 필요" }
  if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { throw "Invoke-Seed: aws CLI 필요" }

  $envParts = @()
  if ($Reseed)        { $envParts += 'SEED_RESET=1' }
  if ($EssentialOnly) { $envParts += 'SEED_SKIP_NONESSENTIAL=1' }
  if ($DryRun)        { $envParts += 'DRY_RUN=1' }
  $envPrefix = if ($envParts.Count -gt 0) { ($envParts -join ' ') + ' ' } else { '' }

  $shellCmd = "cd /app/server && ${envPrefix}npm run seed:aws"
  Write-Host "  [seed] SSM 명령: $shellCmd"

  if ($DryRun) {
    Write-Host "  [seed] DryRun — SSM SendCommand 생략 (echo 만)." -ForegroundColor Yellow
    return $true
  }

  # SSM payload — trigger-deploy.ps1 와 동일하게 임시 파일 경유 (따옴표 이슈 회피).
  $paramsObj  = @{ commands = @($shellCmd) }
  $paramsJson = $paramsObj | ConvertTo-Json -Compress
  $paramsFile = Join-Path ([System.IO.Path]::GetTempPath()) "iconia-ssm-seed-$(Get-Random).json"
  Set-Content -Path $paramsFile -Value $paramsJson -Encoding ASCII -NoNewline

  $maxAttempts = 2
  $attempt = 0
  $success = $false
  $lastErr = ''
  try {
    while ($attempt -lt $maxAttempts -and -not $success) {
      $attempt++
      Write-Host "  [seed] SSM SendCommand attempt $attempt/$maxAttempts -> $InstanceId"
      try {
        $send = & aws ssm send-command `
          --region $Region `
          --document-name 'AWS-RunShellScript' `
          --instance-ids $InstanceId `
          --comment "ICONIA seed (Reseed=$Reseed EssentialOnly=$EssentialOnly)" `
          --parameters "file://$paramsFile" `
          --cloud-watch-output-config 'CloudWatchOutputEnabled=true' `
          --timeout-seconds 1800 `
          --output json
        if ($LASTEXITCODE -ne 0) { throw "ssm send-command 실패 (rc=$LASTEXITCODE)" }
        $cmdId = ($send | ConvertFrom-Json).Command.CommandId
        Write-Host "  [seed] CommandId=$cmdId"
        Write-Host "  [seed] 진행 추적: aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $InstanceId"

        # 결과 polling (시드는 최대 25분).
        $deadline = (Get-Date).AddMinutes(25)
        do {
          Start-Sleep -Seconds 10
          $inv = & aws ssm get-command-invocation `
            --region $Region `
            --command-id $cmdId `
            --instance-id $InstanceId `
            --output json 2>$null
          if ($LASTEXITCODE -eq 0 -and $inv) {
            $obj = $inv | ConvertFrom-Json
            Write-Host "    [seed] Status=$($obj.Status)"
            if ($obj.Status -in 'Success','Failed','Cancelled','TimedOut') {
              Write-Host ""
              Write-Host "    ==== seed STDOUT (tail) ===="
              $stdoutTail = if ($obj.StandardOutputContent) { ($obj.StandardOutputContent -split "`n" | Select-Object -Last 40) -join "`n" } else { '(empty)' }
              Write-Host $stdoutTail
              Write-Host "    ==== seed STDERR (tail) ===="
              $stderrTail = if ($obj.StandardErrorContent) { ($obj.StandardErrorContent -split "`n" | Select-Object -Last 40) -join "`n" } else { '(empty)' }
              Write-Host $stderrTail
              if ($obj.Status -eq 'Success') { $success = $true }
              else { $lastErr = "SSM Status=$($obj.Status)" }
              break
            }
          }
        } while ((Get-Date) -lt $deadline)

        if (-not $success -and -not $lastErr) {
          $lastErr = "polling deadline 25분 초과"
        }
      } catch {
        $lastErr = $_.Exception.Message
        Write-Host "  [seed] attempt $attempt 실패: $lastErr" -ForegroundColor Yellow
      }

      if (-not $success -and $attempt -lt $maxAttempts) {
        $backoff = [int][Math]::Pow(2, $attempt + 1)
        Write-Host "  [seed] $backoff 초 대기 후 재시도..." -ForegroundColor Yellow
        Start-Sleep -Seconds $backoff
      }
    }
  } finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $paramsFile
  }

  if (-not $success) {
    Write-Warning "[seed] SSM 경로 실패 ($lastErr)."
    Write-Warning "[seed] 2차 폴백: SERVER /v1/admin/seed/run endpoint 사용 (ADMIN_SEED_ENABLED=1 + admin JWT 필요)."
    Write-Warning "[seed] 수동 절차: curl -X POST https://api.<domain>/v1/admin/seed/run -H 'Authorization: Bearer <ADMIN_JWT>'"
    throw "Invoke-Seed: 2회 시도 모두 실패 — $lastErr"
  }

  Write-Host "  [seed] ✅ 완료" -ForegroundColor Green
  return $true
}

# ----- Canary 헬퍼 함수들 -----------------------------------------------------
# ALB weighted target group rollout — terraform/canary.tf 가 생성한
# canary TG + listener rule 의 weight 를 동적으로 갱신한다.
# terraform output: canary_target_group_arn / canary_listener_rule_arn / primary_target_group_arn

function Get-CanaryResources {
  <#
    terraform output 으로 canary 관련 ARN 3종 해석.
    enable_canary=false 또는 ACM cert 없으면 빈 문자열 반환 — 호출 측에서 throw.
  #>
  $result = @{
    PrimaryTgArn  = Get-TfOutput 'primary_target_group_arn'
    CanaryTgArn   = Get-TfOutput 'canary_target_group_arn'
    CanaryRuleArn = Get-TfOutput 'canary_listener_rule_arn'
  }
  return $result
}

function Set-CanaryWeight {
  <#
    ALB listener rule 의 forward action weight 를 (100-pct)/pct 로 갱신.
    aws elbv2 modify-rule --actions file://<json>
  #>
  param(
    [Parameter(Mandatory=$true)][string] $RuleArn,
    [Parameter(Mandatory=$true)][string] $PrimaryTgArn,
    [Parameter(Mandatory=$true)][string] $CanaryTgArn,
    [Parameter(Mandatory=$true)][int]    $CanaryPct,
    [Parameter(Mandatory=$true)][string] $Region
  )
  $primaryWeight = 100 - $CanaryPct
  $actionsObj = @(
    @{
      Type = 'forward'
      ForwardConfig = @{
        TargetGroups = @(
          @{ TargetGroupArn = $PrimaryTgArn; Weight = $primaryWeight },
          @{ TargetGroupArn = $CanaryTgArn;  Weight = $CanaryPct }
        )
        TargetGroupStickinessConfig = @{ Enabled = $false }
      }
    }
  )
  $actionsJson = $actionsObj | ConvertTo-Json -Depth 6 -Compress
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "iconia-canary-actions-$(Get-Random).json"
  Set-Content -Path $tmp -Value $actionsJson -Encoding ASCII -NoNewline
  try {
    Write-Host "  [canary] modify-rule weight primary=$primaryWeight / canary=$CanaryPct"
    & aws elbv2 modify-rule `
      --region $Region `
      --rule-arn $RuleArn `
      --actions "file://$tmp" `
      --output json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "aws elbv2 modify-rule 실패 (rc=$LASTEXITCODE)" }
  } finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $tmp
  }
}

function Wait-TgHealthy {
  <#
    target group 의 모든 등록 인스턴스가 healthy 가 될 때까지 polling.
    deadline 안에 다 healthy 면 $true, 아니면 $false.
  #>
  param(
    [Parameter(Mandatory=$true)][string] $TgArn,
    [Parameter(Mandatory=$true)][string] $Region,
    [int] $TimeoutSec = 300
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  do {
    Start-Sleep -Seconds 15
    $hjson = & aws elbv2 describe-target-health `
      --region $Region `
      --target-group-arn $TgArn `
      --output json 2>$null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "    [canary] describe-target-health 일시 실패 — 재시도" -ForegroundColor Yellow
      continue
    }
    $obj = $hjson | ConvertFrom-Json
    $states = @($obj.TargetHealthDescriptions | ForEach-Object { $_.TargetHealth.State })
    if ($states.Count -eq 0) {
      Write-Host "    [canary] TG 등록 인스턴스 없음 — 대기" -ForegroundColor Yellow
      continue
    }
    $unhealthy = @($states | Where-Object { $_ -ne 'healthy' })
    Write-Host "    [canary] TG health: total=$($states.Count) healthy=$($states.Count - $unhealthy.Count) other=[$($states -join ',')]"
    if ($unhealthy.Count -eq 0) { return $true }
  } while ((Get-Date) -lt $deadline)
  return $false
}

function Get-CanaryInstanceIds {
  <#
    canary 용으로 ASG 의 가장 새로운 인스턴스 1대를 선별해서 반환.
    미보유 시 사용자에게 안내 후 throw.
    실제 운영에서는 canary 전용 ASG 또는 standalone EC2 권장 — V1.x 다음 라운드 확장.
  #>
  param(
    [Parameter(Mandatory=$true)][string] $Region,
    [string] $NamePrefix = 'iconia-prod'
  )
  $json = & aws ec2 describe-instances `
    --region $Region `
    --filters "Name=tag:Name,Values=$NamePrefix-asg-host" "Name=instance-state-name,Values=running" `
    --query 'Reservations[].Instances[].{Id:InstanceId,Launch:LaunchTime}' `
    --output json
  if ($LASTEXITCODE -ne 0) { throw "EC2 조회 실패" }
  $arr = $json | ConvertFrom-Json
  if (-not $arr -or $arr.Count -eq 0) { throw "running 인스턴스 없음 — canary 대상 미보유 (ASG min_size 확인)" }
  # 최신 launch time 1대만 canary 로 (나머지는 primary 로 유지).
  $latest = $arr | Sort-Object Launch -Descending | Select-Object -First 1
  return @($latest.Id)
}

function Invoke-CanaryStart {
  param(
    [Parameter(Mandatory=$true)][int]    $CanaryPct,
    [Parameter(Mandatory=$true)][string] $Region,
    [Parameter(Mandatory=$true)][hashtable] $Resources
  )
  if (-not $Resources.CanaryTgArn) {
    throw "canary TG ARN 미해석 — terraform/canary.tf 가 enable_canary=true 로 apply 되었는지 확인 (canary_target_group_arn output)."
  }
  if (-not $Resources.CanaryRuleArn) {
    throw "canary listener rule ARN 미해석 — ACM 인증서가 등록되어 있어야 HTTPS listener + rule 가 생성됨."
  }
  Write-Host "[canary] 시작 — 신규 빌드를 canary TG 에 register, weight=$CanaryPct%"
  $canaryIds = Get-CanaryInstanceIds -Region $Region
  Write-Host "  [canary] 대상 인스턴스: $($canaryIds -join ', ')"
  # aws elbv2 register-targets --targets 는 Id=<id> 형태 인자 N개.
  $targetsArgs = @()
  foreach ($id in $canaryIds) { $targetsArgs += ('Id=' + $id) }
  & aws elbv2 register-targets `
    --region $Region `
    --target-group-arn $Resources.CanaryTgArn `
    --targets @targetsArgs | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "register-targets 실패" }
  Write-Host "  [canary] register-targets 완료 — health 대기 (최대 5분)"
  $healthy = Wait-TgHealthy -TgArn $Resources.CanaryTgArn -Region $Region -TimeoutSec 300
  if (-not $healthy) {
    Write-Warning "[canary] canary TG 가 5분 내 healthy 가 되지 않음 — weight 갱신 보류, RollbackCanary 권장"
    throw "canary health 실패"
  }
  Set-CanaryWeight -RuleArn $Resources.CanaryRuleArn `
                   -PrimaryTgArn $Resources.PrimaryTgArn `
                   -CanaryTgArn $Resources.CanaryTgArn `
                   -CanaryPct $CanaryPct `
                   -Region $Region
  Write-Host ""
  Write-Host "[canary] ✅ ALB weight 갱신 완료 (primary=$(100-$CanaryPct)% / canary=$CanaryPct%)" -ForegroundColor Green
  Write-Host "[canary] CloudWatch dashboard iconia_slo + ICONIA/Server/5xx 메트릭 5분간 모니터링 권장."
  Write-Host "[canary] 통과 시   : pwsh -File scripts/aws-deploy.ps1 -PromoteCanary"
  Write-Host "[canary] 회수 필요 : pwsh -File scripts/aws-deploy.ps1 -RollbackCanary"
}

function Invoke-CanaryPromote {
  param(
    [Parameter(Mandatory=$true)][string] $Region,
    [Parameter(Mandatory=$true)][hashtable] $Resources
  )
  if (-not $Resources.CanaryTgArn -or -not $Resources.PrimaryTgArn) {
    throw "TG ARN 미해석 — terraform output 확인."
  }
  Write-Host "[canary] PROMOTE — canary 인스턴스를 primary TG 로 atomic swap"
  $hjson = & aws elbv2 describe-target-health `
    --region $Region `
    --target-group-arn $Resources.CanaryTgArn `
    --output json
  if ($LASTEXITCODE -ne 0) { throw "describe-target-health 실패" }
  $obj = $hjson | ConvertFrom-Json
  $canaryIds = @($obj.TargetHealthDescriptions | ForEach-Object { $_.Target.Id })
  if ($canaryIds.Count -eq 0) { throw "canary TG 에 등록된 인스턴스 없음 — promote 대상 없음." }
  Write-Host "  [canary] promote 대상: $($canaryIds -join ', ')"
  $tArgs = @(); foreach ($id in $canaryIds) { $tArgs += ('Id=' + $id) }
  & aws elbv2 register-targets --region $Region --target-group-arn $Resources.PrimaryTgArn --targets @tArgs | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "primary TG register-targets 실패" }
  $healthy = Wait-TgHealthy -TgArn $Resources.PrimaryTgArn -Region $Region -TimeoutSec 180
  if (-not $healthy) { throw "promote 후 primary TG healthy 실패 — 수동 점검." }
  Set-CanaryWeight -RuleArn $Resources.CanaryRuleArn `
                   -PrimaryTgArn $Resources.PrimaryTgArn `
                   -CanaryTgArn $Resources.CanaryTgArn `
                   -CanaryPct 0 `
                   -Region $Region
  & aws elbv2 deregister-targets --region $Region --target-group-arn $Resources.CanaryTgArn --targets @tArgs | Out-Null
  Write-Host "[canary] ✅ promote 완료 — primary 100% / canary 0%, canary TG drain 시작" -ForegroundColor Green
}

function Invoke-CanaryRollback {
  param(
    [Parameter(Mandatory=$true)][string] $Region,
    [Parameter(Mandatory=$true)][hashtable] $Resources
  )
  if (-not $Resources.CanaryRuleArn) { throw "canary listener rule ARN 미해석." }
  Write-Host "[canary] ROLLBACK — weight 100/0 즉시 복원 + canary TG drain"
  Set-CanaryWeight -RuleArn $Resources.CanaryRuleArn `
                   -PrimaryTgArn $Resources.PrimaryTgArn `
                   -CanaryTgArn $Resources.CanaryTgArn `
                   -CanaryPct 0 `
                   -Region $Region
  $hjson = & aws elbv2 describe-target-health `
    --region $Region `
    --target-group-arn $Resources.CanaryTgArn `
    --output json 2>$null
  if ($LASTEXITCODE -eq 0) {
    $obj = $hjson | ConvertFrom-Json
    $canaryIds = @($obj.TargetHealthDescriptions | ForEach-Object { $_.Target.Id })
    if ($canaryIds.Count -gt 0) {
      $tArgs = @(); foreach ($id in $canaryIds) { $tArgs += ('Id=' + $id) }
      & aws elbv2 deregister-targets --region $Region --target-group-arn $Resources.CanaryTgArn --targets @tArgs | Out-Null
      Write-Host "  [canary] $($canaryIds.Count) 인스턴스 deregister"
    }
  }
  Write-Host "[canary] ✅ rollback 완료 — primary 의 기존 빌드 유지" -ForegroundColor Green
}

# Canary 흐름은 빌드/배포/시드 흐름과 직교 — 분기 즉시 실행 후 exit.
if ($canaryMode) {
  if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    Write-Warning "terraform 미설치 — canary 흐름은 terraform output 으로 ARN 해석. terraform 설치 후 재시도 권장."
  }
  $canaryRes = Get-CanaryResources
  Write-Host "[canary] resources:"
  Write-Host "  primary TG       = $($canaryRes.PrimaryTgArn)"
  Write-Host "  canary TG        = $($canaryRes.CanaryTgArn)"
  Write-Host "  listener rule    = $($canaryRes.CanaryRuleArn)"
  if ($DryRun) {
    Write-Host "[canary] DryRun — aws elbv2 호출 생략. resources 만 출력 후 종료." -ForegroundColor Yellow
    exit 0
  }
  if ($Canary -gt 0)         { Invoke-CanaryStart    -CanaryPct $Canary -Region $region -Resources $canaryRes }
  elseif ($PromoteCanary)    { Invoke-CanaryPromote                       -Region $region -Resources $canaryRes }
  elseif ($RollbackCanary)   { Invoke-CanaryRollback                      -Region $region -Resources $canaryRes }
  Write-Host ""
  Write-Host "================ Canary 흐름 완료 ================" -ForegroundColor Cyan
  exit 0
}

# ----- 3) 빌드 + S3 업로드 (단독 시드 모드면 skip) -----
if (-not $seedOnlyMode) {
  $buildScript = Join-Path $scriptRoot 'build-and-upload.ps1'
  Write-Host "[build] build-and-upload.ps1 -Service $Service"
  & pwsh -File $buildScript -Service $Service -ArtifactsBucket $artifactsBucket -Region $region
  if ($LASTEXITCODE -ne 0) { throw "build-and-upload 실패" }
} else {
  Write-Host "[build] SEED-ONLY 모드 — 빌드/업로드 skip"
}

if ($DryRun -and -not ($Seed -or $Reseed)) {
  Write-Host "[dry-run] 빌드·업로드 완료 — SSM 배포/스모크/시드 생략." -ForegroundColor Yellow
  exit 0
}

# ----- 4) SSM 배포 트리거 (단독 시드 모드면 skip) -----
if (-not $seedOnlyMode) {
  $triggerScript = Join-Path $scriptRoot 'trigger-deploy.ps1'
  $triggerArgs = @('-File', $triggerScript, '-Service', $Service, '-Region', $region)
  if ($instanceId) { $triggerArgs += @('-InstanceId', $instanceId) }
  Write-Host "[deploy] trigger-deploy.ps1"
  & pwsh @triggerArgs
  if ($LASTEXITCODE -ne 0) { throw "trigger-deploy 실패 — EC2 호스트가 자동 롤백을 수행했을 수 있음. CloudWatch ICONIA/Deploy 확인." }
}

# ----- 5) 외부 스모크 검증 (단독 시드 모드면 skip) -----
if (-not $seedOnlyMode -and $rootDomain) {
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
} elseif (-not $seedOnlyMode) {
  Write-Host "[smoke] root domain 미해석 — 외부 스모크 생략. ICONIA_ROOT_DOMAIN 설정 권장." -ForegroundColor Yellow
}

# ----- 6) Seed 단계 -----
# 의사결정 매트릭스:
#   -Seed              : 무조건 시드 (Reseed=false)
#   -Reseed            : 무조건 truncate+시드
#   -ApplyInfra +!NoSeed : 첫 배포 자동 감지 시 1회 자동 시드
#   (기타)             : 시드 안 함
$shouldSeed = $false
$seedReason = ''
if ($Reseed) {
  $shouldSeed = $true; $seedReason = '-Reseed 명시'
} elseif ($Seed) {
  $shouldSeed = $true; $seedReason = '-Seed 명시'
} elseif ($ApplyInfra -and -not $NoSeed) {
  Write-Host "[seed] -ApplyInfra 흐름 — 첫 배포 감지 시도 (/v1/admin/seed/status)"
  if (Test-SeedNeeded -RootDomain $rootDomain) {
    $shouldSeed = $true; $seedReason = '첫 배포 자동 감지 (last_seeded_at=null)'
  } else {
    Write-Host "[seed] 자동 시드 조건 미충족 — skip" -ForegroundColor Yellow
  }
} elseif ($NoSeed) {
  Write-Host "[seed] -NoSeed — 자동 시드 명시적으로 skip" -ForegroundColor Yellow
}

if ($shouldSeed) {
  Write-Host ""
  Write-Host "================ Seed 단계 ($seedReason) ================" -ForegroundColor Cyan
  $resolvedId = Resolve-Ec2InstanceId -InstanceId $instanceId -Region $region
  $seedOk = Invoke-Seed `
    -InstanceId $resolvedId `
    -Region $region `
    -Reseed:$Reseed `
    -EssentialOnly:$EssentialOnly `
    -DryRun:$DryRun
  if (-not $seedOk) { throw "시드 실패" }
}

Write-Host ""
Write-Host "================ AWS 배포 완료 ================" -ForegroundColor Cyan
Write-Host "  서비스: $Service"
Write-Host "  EC2 호스트가 atomic swap + 헬스체크 30s + 실패 시 자동 롤백 수행."
Write-Host "  시드: $(if($shouldSeed){"✅ 실행됨 ($seedReason)"}else{'skip'})"
Write-Host "  배포 가시성: CloudWatch ICONIA/Deploy namespace + /iconia/<env>/* 로그그룹"
Write-Host "===============================================" -ForegroundColor Cyan
