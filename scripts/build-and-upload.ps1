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
  $rcArgs = @(
    $src, $stage,
    '/MIR',
    '/XD', 'node_modules', '.next', '.expo', '.git', 'coverage', 'tmp', '.turbo',
    '/XF', '.env', '.env.*', '*.log', '*.tsbuildinfo',
    '/NFL','/NDL','/NJH','/NJS','/NP'
  )
  $rc = Start-Process -FilePath 'robocopy' -ArgumentList $rcArgs -NoNewWindow -Wait -PassThru
  # robocopy 종료코드 0~7 은 성공(8+ 가 에러).
  if ($rc.ExitCode -ge 8) { throw "robocopy 실패 ($Svc) exit=$($rc.ExitCode)" }

  if (-not $SkipNpmInstall) {
    Write-Host "[$Svc] npm ci --omit=dev"
    Push-Location $stage
    try {
      # 빌드용 의존성 설치. 운영 EC2 에서도 npm ci 하지만, 빌드 단계가 있는 admin(Next.js) 은
      # 여기서 빌드 산출물(.next/) 까지 만들어 올려야 EC2 부담이 줄어든다.
      & npm ci
      if ($LASTEXITCODE -ne 0) { throw "npm ci 실패 ($Svc)" }

      if ($Svc -eq 'admin') {
        Write-Host "[admin] npm run build (Next.js)"
        & npm run build
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

      # 운영용으로 다시 prune (devDependencies 제거).
      Write-Host "[$Svc] npm prune --omit=dev"
      & npm prune --omit=dev
    } finally { Pop-Location }
  }

  $tar = Join-Path $env:TEMP "iconia-$Svc-$Version.tar.gz"
  if (Test-Path $tar) { Remove-Item $tar -Force }

  Write-Host "[$Svc] tar -> $tar"
  # tar 의 -C 로 stage 안으로 들어가 .gitignore 무시하고 통째로 패키징.
  & tar -czf $tar -C $stage '.'
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

  Write-Host "[$Svc] upload -> s3://$ArtifactsBucket/$versionKey"
  & aws s3 cp $Tarball "s3://$ArtifactsBucket/$versionKey" --region $Region
  if ($LASTEXITCODE -ne 0) { throw "S3 업로드 실패 ($versionKey)" }

  Write-Host "[$Svc] copy -> $latestKey"
  & aws s3 cp "s3://$ArtifactsBucket/$versionKey" "s3://$ArtifactsBucket/$latestKey" --region $Region
  if ($LASTEXITCODE -ne 0) { throw "S3 latest 복사 실패 ($Svc)" }
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
