<#
.SYNOPSIS
  ICONIA 로컬 빌드 + S3 artifacts 업로드.

.DESCRIPTION
  ICONIA 루트(`C:\Users\user\Music\ICONIA`) 에서 실행. 1~5 번 폴더는 로컬 전용이고,
  본 스크립트가 빌드 산출물만 S3 artifacts 버킷으로 올린다. 그 후 EC2 가 pull.

  대상 서비스: 2.SERVER (Node.js), 3.AI (Node.js), 5.ADMIN (Next.js).
  1.HW(펌웨어)와 4.APP(Expo)은 본 배포 대상 아님 - 별도 OTA / EAS Build 트랙.

.PARAMETER Service
  server / ai / admin / all / _bootstrap

.PARAMETER ArtifactsBucket
  S3 버킷 이름. terraform output 'artifacts_bucket_name' 값.
  생략 시 환경변수 ICONIA_ARTIFACTS_BUCKET 사용.

.PARAMETER Region
  AWS region. 기본 ap-northeast-2.

.PARAMETER Version
  버전 라벨. 생략 시 yyyyMMdd-HHmmss UTC.

.PARAMETER SkipNpmInstall
  로컬 검증용. node_modules 없이 source 만 패키징.

.PARAMETER TriggerDeploy
  업로드 후 SSM Run Command 로 EC2 에서 ec2-pull-and-restart.sh 호출.

.EXAMPLE
  pwsh -File 6. CI\scripts\build-and-upload.ps1 -Service all -TriggerDeploy

.EXAMPLE
  $env:ICONIA_ARTIFACTS_BUCKET = "iconia-prod-artifacts-123456789012"
  pwsh -File "6. CI\scripts\build-and-upload.ps1" -Service server
#>

[CmdletBinding()]
param(
  [ValidateSet('server','ai','admin','all','_bootstrap')]
  [string] $Service = 'all',

  [string] $ArtifactsBucket = $env:ICONIA_ARTIFACTS_BUCKET,

  [string] $Region = 'ap-northeast-2',

  [string] $Version = (Get-Date -AsUTC).ToString('yyyyMMdd-HHmmss') + 'Z',

  [switch] $SkipNpmInstall,

  [switch] $TriggerDeploy
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $ArtifactsBucket) {
  throw "ArtifactsBucket 미지정. -ArtifactsBucket 또는 `$env:ICONIA_ARTIFACTS_BUCKET 설정 필요."
}

# 본 스크립트가 6. CI\scripts\ 안에 있다고 가정. ICONIA root 는 2 단계 위.
$scriptRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ciRoot       = Split-Path -Parent $scriptRoot
$iconiaRoot   = Split-Path -Parent $ciRoot

$paths = @{
  server = Join-Path $iconiaRoot '2. SERVER'
  ai     = Join-Path $iconiaRoot '3. AI'
  admin  = Join-Path $iconiaRoot '5. ADMIN'
}

function Test-AwsCli {
  if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw "aws CLI 가 PATH 에 없습니다. https://aws.amazon.com/cli/ 설치 후 'aws configure'."
  }
}

function Test-Tar {
  if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
    throw "tar 가 PATH 에 없습니다. Windows 10 1803+ 또는 Git for Windows 의 tar 필요."
  }
}

function New-ServiceTarball {
  param([string] $Svc)
  $src = $paths[$Svc]
  if (-not (Test-Path $src)) { throw "$Svc source not found: $src" }

  $stage = Join-Path $env:TEMP "iconia-build-$Svc-$Version"
  if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
  New-Item -ItemType Directory -Path $stage | Out-Null

  Write-Host "[$Svc] copy source -> $stage"
  # robocopy 가 PowerShell 의 큰 디렉터리 복사에 훨씬 빠르다.
  # 제외 패턴: node_modules, .next/cache, dist, build, tests output, .env*, .git
  # & 직접 호출 — Start-Process 의 ArgumentList 가 공백 포함 path("2. SERVER") 를 분리해 버림.
  & robocopy $src $stage `
    /MIR `
    /XD node_modules .next .expo .git coverage tmp .turbo `
    /XF .env .env.* *.log *.tsbuildinfo `
    /NFL /NDL /NJH /NJS /NP | Out-Host
  $rcCode = $LASTEXITCODE
  # robocopy 종료코드 0~7 은 성공(8+ 가 에러).
  if ($rcCode -ge 8) { throw "robocopy 실패 ($Svc) exit=$rcCode" }

  if (-not $SkipNpmInstall) {
    Write-Host "[$Svc] npm ci --omit=dev"
    Push-Location $stage
    try {
      # 빌드용 의존성 설치. 운영 EC2 에서도 npm ci 하지만, 빌드 단계가 있는 admin(Next.js) 은
      # 여기서 빌드 산출물(.next/) 까지 만들어 올려야 EC2 부담이 줄어든다.
      & npm ci | Out-Host
      if ($LASTEXITCODE -ne 0) { throw "npm ci 실패 ($Svc)" }

      if ($Svc -eq 'admin') {
        # CSP: upgrade-insecure-requests 비활성화 (HTTPS 미도입 PoC 한정).
        # 현재 ALB(:8082) 가 HTTP only — 디렉티브 활성 시 브라우저가 모든 자산을 HTTPS 로
        # 강제 변환해 CSS/JS 가 모두 차단되어 unstyled 화면이 됨. ALB+ACM HTTPS 도입 후
        # `$env:DISABLE_UPGRADE_INSECURE=$null` 로 해제하거나 본 라인 삭제.
        # 호출자가 명시적으로 설정해두면(`$env:DISABLE_UPGRADE_INSECURE`) 그 값을 존중.
        if (-not $env:DISABLE_UPGRADE_INSECURE) {
          $env:DISABLE_UPGRADE_INSECURE = '1'
          Write-Host "[admin] DISABLE_UPGRADE_INSECURE=1 (HTTPS 미도입 임시 우회 — next.config.mjs:55 정합)"
        } else {
          Write-Host "[admin] DISABLE_UPGRADE_INSECURE=$($env:DISABLE_UPGRADE_INSECURE) (호출자 지정값 존중)"
        }

        Write-Host "[admin] npm run build (Next.js)"
        & npm run build | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "next build 실패" }

        # Next.js standalone 산출물에는 .next/static 과 public/ 가 포함되지 않으므로
        # systemd unit 의 WorkingDirectory(.next/standalone) 안으로 수동 복사한다.
        # 안 하면 운영에서 정적 자산(/_next/static/*)이 모두 404.
        $standalone = Join-Path $stage '.next/standalone'
        if (-not (Test-Path $standalone)) {
          throw "[admin] .next/standalone 산출물이 없습니다. next.config.mjs 의 output:'standalone' 확인 필요"
        }
        $staticSrc  = Join-Path $stage '.next/static'
        $publicSrc  = Join-Path $stage 'public'
        $staticDst  = Join-Path $standalone '.next/static'
        $publicDst  = Join-Path $standalone 'public'
        if (Test-Path $staticSrc) {
          Write-Host "[admin] copy .next/static -> standalone/.next/static"
          New-Item -ItemType Directory -Force -Path (Split-Path $staticDst) | Out-Null
          Copy-Item -Recurse -Force $staticSrc $staticDst
        }
        if (Test-Path $publicSrc) {
          Write-Host "[admin] copy public -> standalone/public"
          Copy-Item -Recurse -Force $publicSrc $publicDst
        }
      }

      # Prisma client 사전 생성 (server 한정 - ai/admin 은 prisma 호출 불필요).
      # generated client(@prisma/client 안의 .prisma/) 를 tarball 에 포함해야
      # 운영 EC2 가 prisma CLI 없이 부팅 가능 (devDependencies prune 후에도 동작).
      if ($Svc -eq 'server' -and (Test-Path (Join-Path $stage 'prisma/schema.prisma'))) {
        Write-Host "[server] npx prisma generate"
        & npx --yes prisma generate | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "prisma generate 실패 (server)" }
      }

      # 운영용으로 다시 prune (devDependencies 제거).
      Write-Host "[$Svc] npm prune --omit=dev"
      & npm prune --omit=dev | Out-Host
    } finally { Pop-Location }
  }

  $tar = Join-Path $env:TEMP "iconia-$Svc-$Version.tar.gz"
  if (Test-Path $tar) { Remove-Item $tar -Force }

  Write-Host "[$Svc] tar -> $tar"
  # tar 의 -C 로 stage 안으로 들어가 .gitignore 무시하고 통째로 패키징.
  & tar -czf $tar -C $stage '.' | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "tar 실패 ($Svc)" }

  return [pscustomobject]@{
    Service = $Svc
    Stage   = $stage
    Tarball = $tar
  }
}

function Send-ToS3 {
  param([string] $Svc, [string] $Tarball)
  $versionKey = "$Svc/$Version.tar.gz"
  $latestKey  = "$Svc/latest.tar.gz"
  $sha256Key  = "$Svc/latest.tar.gz.sha256"

  # 체크섬 사이드카: EC2 의 ec2-pull-and-restart.sh 가 tar 풀기 전에 검증.
  # 부분 업로드 / 네트워크 손상이 EC2 의 깨진 배포로 이어지지 않게 한다.
  $sha = (Get-FileHash -Algorithm SHA256 $Tarball).Hash.ToLower()
  $shaFile = "$Tarball.sha256"
  Set-Content -Path $shaFile -Value $sha -Encoding ASCII -NoNewline

  Write-Host "[$Svc] upload -> s3://$ArtifactsBucket/$versionKey (sha256=$sha)"
  & aws s3 cp $Tarball "s3://$ArtifactsBucket/$versionKey" --region $Region
  if ($LASTEXITCODE -ne 0) { throw "S3 업로드 실패 ($versionKey)" }

  # latest 는 atomic 한 update 가 아니므로 sha256 을 먼저 올리지 말고 tarball 다음에 올린다.
  # ec2-pull-and-restart.sh 는 latest.tar.gz 받은 후 .sha256 받아 검증.
  Write-Host "[$Svc] copy -> $latestKey"
  & aws s3 cp "s3://$ArtifactsBucket/$versionKey" "s3://$ArtifactsBucket/$latestKey" --region $Region
  if ($LASTEXITCODE -ne 0) { throw "S3 latest 복사 실패 ($Svc)" }

  Write-Host "[$Svc] upload -> $sha256Key"
  & aws s3 cp $shaFile "s3://$ArtifactsBucket/$sha256Key" --region $Region
  if ($LASTEXITCODE -ne 0) { throw "S3 sha256 업로드 실패 ($Svc)" }
}

function Publish-Bootstrap {
  # _bootstrap 은 systemd/nginx 설정 + ec2-pull-and-restart.sh 스크립트 자체를 묶어 올린다.
  # EC2 user-data 가 부팅 시 받아 /etc/systemd/system 과 /etc/nginx 에 설치.
  $stage = Join-Path $env:TEMP "iconia-bootstrap-$Version"
  if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
  New-Item -ItemType Directory -Path "$stage/deploy/systemd" -Force | Out-Null
  New-Item -ItemType Directory -Path "$stage/deploy/nginx/snippets"   -Force | Out-Null
  New-Item -ItemType Directory -Path "$stage/scripts"        -Force | Out-Null

  Copy-Item (Join-Path $ciRoot 'deploy/systemd/iconia-server.service') "$stage/deploy/systemd/iconia-server.service"
  Copy-Item (Join-Path $ciRoot 'deploy/systemd/iconia-ai.service')     "$stage/deploy/systemd/iconia-ai.service"
  Copy-Item (Join-Path $ciRoot 'deploy/systemd/iconia-admin.service')  "$stage/deploy/systemd/iconia-admin.service"
  Copy-Item (Join-Path $ciRoot 'deploy/nginx/iconia.conf')             "$stage/deploy/nginx/iconia.conf"
  Copy-Item (Join-Path $ciRoot 'deploy/nginx/snippets-iconia-proxy.conf') "$stage/deploy/nginx/snippets/iconia-proxy.conf"
  Copy-Item (Join-Path $ciRoot 'scripts/ec2-pull-and-restart.sh')      "$stage/scripts/ec2-pull-and-restart.sh"

  $tar = Join-Path $env:TEMP "iconia-bootstrap-$Version.tar.gz"
  if (Test-Path $tar) { Remove-Item $tar -Force }
  & tar -czf $tar -C $stage '.'
  if ($LASTEXITCODE -ne 0) { throw "_bootstrap tar 실패" }

  $versionKey = "_bootstrap/deploy-$Version.tar.gz"
  $latestKey  = "_bootstrap/deploy.tar.gz"
  $scriptKey  = "_bootstrap/ec2-pull-and-restart.sh"

  & aws s3 cp $tar "s3://$ArtifactsBucket/$versionKey" --region $Region
  & aws s3 cp "s3://$ArtifactsBucket/$versionKey" "s3://$ArtifactsBucket/$latestKey" --region $Region
  # user-data 가 곧장 받는 스크립트도 따로 올림.
  & aws s3 cp (Join-Path $ciRoot 'scripts/ec2-pull-and-restart.sh') "s3://$ArtifactsBucket/$scriptKey" --region $Region

  Write-Host "[_bootstrap] uploaded -> $versionKey, $latestKey, $scriptKey"
}

# ----- Main -----
Test-AwsCli
Test-Tar

# 2026-05-28 (PRE-01 fix) — preflight 통합. 기본은 warning, $env:REQUIRE_PREFLIGHT=1 일 때 fail.
# release tag 배포는 release-preflight.yml 가 별도 강제.
$preflightSh = Join-Path $ciRoot 'scripts/preflight-placeholders.sh'
if (Test-Path -LiteralPath $preflightSh) {
  Write-Host "`n[preflight] placeholder/legal guard scan..."
  $preflightExit = 0
  try {
    & bash $preflightSh $iconiaRoot 2>&1 | Tee-Object -Variable preflightOut | Out-Null
    $preflightExit = $LASTEXITCODE
  } catch {
    Write-Warning "[preflight] bash 실행 실패 — 검사 skip (Windows 환경)"
    $preflightExit = 0
  }
  if ($preflightExit -ne 0) {
    $count = @($preflightOut | Select-String -Pattern '^\[FAIL').Count
    if ($env:REQUIRE_PREFLIGHT -eq '1') {
      throw "[preflight] FAIL — $count 건 placeholder 잔존. release tag 배포는 차단됨. `$env:REQUIRE_PREFLIGHT=0 로 일시 우회 가능."
    } else {
      Write-Warning "[preflight] WARN — $count 건 placeholder 잔존. dev/staging 배포는 진행 (release tag 시점에는 차단됨)."
      Write-Warning "  → 강제 차단 원하시면: `$env:REQUIRE_PREFLIGHT=1; build-and-upload.ps1 ..."
    }
  } else {
    Write-Host "[preflight] OK — placeholder 없음."
  }
} else {
  Write-Warning "[preflight] 스크립트 누락: $preflightSh — 검사 skip."
}

$services = switch ($Service) {
  'all'        { @('_bootstrap','server','ai','admin') }
  '_bootstrap' { @('_bootstrap') }
  default      { @($Service) }
}

foreach ($svc in $services) {
  if ($svc -eq '_bootstrap') {
    Publish-Bootstrap
    continue
  }

  # 2026-05-28 (DEPLOY-02 fix) — admin 빌드 전 .next 캐시 강제 삭제.
  # Next.js incremental build 가 stale chunk 를 가져가 옛 코드로 배포되는 사고 차단.
  if ($svc -eq 'admin') {
    $nextDir = Join-Path $paths['admin'] '.next'
    if (Test-Path -LiteralPath $nextDir) {
      Write-Host "[admin] .next/ 캐시 삭제 (stale chunk 차단)"
      Remove-Item -Recurse -Force -LiteralPath $nextDir -ErrorAction SilentlyContinue
    }
  }

  $r = New-ServiceTarball -Svc $svc
  Send-ToS3 -Svc $svc -Tarball $r.Tarball
}

Write-Host "`nVersion: $Version"
Write-Host "Uploaded to: s3://$ArtifactsBucket/"

if ($TriggerDeploy) {
  $triggerScript = Join-Path $ciRoot 'scripts/trigger-deploy.ps1'
  $target = if ($Service -eq '_bootstrap') { 'all' } else { $Service }
  & pwsh -File $triggerScript -Service $target -Region $Region
}
