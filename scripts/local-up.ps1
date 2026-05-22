<#
.SYNOPSIS
  ICONIA localhost 전체 기동 — PostgreSQL 16 + SERVER + AI + ADMIN + APP.

.DESCRIPTION
  "localhost 에서 동작 확인" 경로의 단일 진입점.
  ICONIA 모노레포(1.HW ~ 6.CI)의 부모 폴더 기준으로 6개 컴포넌트 중
  서버 사이드 5개를 로컬에서 띄운다.

    1. PostgreSQL 16   : Docker 컨테이너 또는 기설치 로컬 서비스
    2. 2. SERVER       : Node.js Express  → http://127.0.0.1:8080
    3. 3. AI           : Node.js Genome   → http://127.0.0.1:3001
    4. 5. ADMIN        : Next.js dev      → http://127.0.0.1:3000
    5. 4. APP          : Expo dev server  (-IncludeApp 지정 시)
    6. 1. HW           : 펌웨어 — 로컬 기동 대상 아님 (별도 빌드 트랙)

  각 서비스는 별도 PowerShell 창에서 떠서 로그가 분리된다.
  단일 토글: 본 스크립트는 .env 의 DEPLOY_TARGET 을 'local' 로 강제하고
  각 서비스에 로컬 DATABASE_URL / AI_BASE_URL 을 주입한다.
  각 레포가 읽는 키로 주입: SERVER/AI/ADMIN 은 DEPLOY_TARGET, APP(Expo) 은
  EXPO_PUBLIC_DEPLOY_TARGET (Expo 는 EXPO_PUBLIC_ prefix 필수).

  종료: scripts/local-down.ps1

.PARAMETER RepoRoot
  ICONIA 모노레포 루트. 비우면 .env 의 ICONIA_REPO_ROOT, 그것도 비면 6.CI 의 ../...

.PARAMETER IncludeApp
  지정 시 4. APP (Expo) dev 서버도 기동.

.PARAMETER SkipInstall
  npm install / prisma 단계 생략 (이미 한 번 띄운 뒤 재기동용).

.PARAMETER SkipDb
  PostgreSQL 기동 단계 생략 (이미 떠 있는 경우).

.EXAMPLE
  Copy-Item .env.example .env      # 최초 1회
  pwsh -File scripts/local-up.ps1

.EXAMPLE
  pwsh -File scripts/local-up.ps1 -IncludeApp -SkipInstall
#>

[CmdletBinding()]
param(
  [string] $RepoRoot,
  [switch] $IncludeApp,
  [switch] $SkipInstall,
  [switch] $SkipDb
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ----- 경로 해석 -----
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ciRoot     = Split-Path -Parent $scriptRoot

function Import-DotEnv {
  param([string] $Path)
  $env_ = @{}
  if (Test-Path -LiteralPath $Path) {
    foreach ($raw in Get-Content -LiteralPath $Path) {
      $line = $raw.Trim()
      if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
      $idx = $line.IndexOf('=')
      if ($idx -lt 1) { continue }
      $k = $line.Substring(0, $idx).Trim()
      $v = $line.Substring($idx + 1).Trim()
      $env_[$k] = $v
    }
  }
  return $env_
}

$dotenv = Import-DotEnv (Join-Path $ciRoot '.env')

function Cfg {
  param([string] $Key, [string] $Default = '')
  if ($dotenv.ContainsKey($Key) -and $dotenv[$Key]) { return $dotenv[$Key] }
  $v = [Environment]::GetEnvironmentVariable($Key)
  if ($v) { return $v }
  return $Default
}

if (-not $RepoRoot) { $RepoRoot = Cfg 'ICONIA_REPO_ROOT' }
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $ciRoot }
if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
  throw "ICONIA repo root 를 찾을 수 없습니다: $RepoRoot  (-RepoRoot 또는 .env 의 ICONIA_REPO_ROOT 설정)"
}

# ----- 단일 토글: 로컬 강제 -----
$target = Cfg 'DEPLOY_TARGET' 'local'
if ($target -ne 'local') {
  Write-Warning ".env 의 DEPLOY_TARGET 이 '$target' 입니다. 로컬 기동을 위해 'local' 로 간주합니다."
}

$pgHost = Cfg 'LOCAL_PG_HOST'     '127.0.0.1'
$pgPort = Cfg 'LOCAL_PG_PORT'     '5432'
$pgUser = Cfg 'LOCAL_PG_USER'     'iconia'
$pgPass = Cfg 'LOCAL_PG_PASSWORD' 'iconia_local_dev'
$pgDb   = Cfg 'LOCAL_PG_DATABASE' 'iconia'
$pgDocker = (Cfg 'LOCAL_PG_USE_DOCKER' 'true') -eq 'true'

$serverPort = Cfg 'LOCAL_SERVER_PORT' '8080'
$aiPort     = Cfg 'LOCAL_AI_PORT'     '3001'
$adminPort  = Cfg 'LOCAL_ADMIN_PORT'  '3000'
$aiBaseUrl  = Cfg 'LOCAL_AI_BASE_URL' "http://127.0.0.1:$aiPort"
# 폰(EAS APK) / ESP32 펌웨어가 PC 의 SERVER 를 호출할 때 쓰는 LAN IP. .env 의 한 줄로 갱신.
# 127.0.0.1 은 폰 입장에서 자기 자신 — 같은 Wi-Fi 의 PC IP 가 필요.
$lanIp        = Cfg 'LOCAL_LAN_IP' '192.168.0.30'
$lanServerUrl = "http://${lanIp}:${serverPort}"
$lanAiUrl     = "http://${lanIp}:${aiPort}"

$databaseUrl = "postgresql://${pgUser}:${pgPass}@${pgHost}:${pgPort}/${pgDb}?schema=public"

# ICONIA 폴더 매핑 (sibling 레포 레이아웃 / 숫자 폴더 레이아웃 모두 지원).
function Resolve-ServiceDir {
  param([string] $SiblingName, [string] $NumberedName)
  $a = Join-Path $RepoRoot $SiblingName
  $b = Join-Path $RepoRoot $NumberedName
  if (Test-Path -LiteralPath $a -PathType Container) { return $a }
  if (Test-Path -LiteralPath $b -PathType Container) { return $b }
  return $null
}

$serverDir = Resolve-ServiceDir 'ICONIA-SERVER' '2. SERVER'
$aiDir     = Resolve-ServiceDir 'ICONIA-AI'     '3. AI'
$adminDir  = Resolve-ServiceDir 'ICONIA-ADMIN'  '5. ADMIN'
$appDir    = Resolve-ServiceDir 'ICONIA-APP'    '4. APP'

if (-not $serverDir) { throw "SERVER 폴더를 찾을 수 없습니다 (ICONIA-SERVER 또는 '2. SERVER')." }
if (-not $aiDir)     { throw "AI 폴더를 찾을 수 없습니다 (ICONIA-AI 또는 '3. AI')." }
if (-not $adminDir)  { throw "ADMIN 폴더를 찾을 수 없습니다 (ICONIA-ADMIN 또는 '5. ADMIN')." }

Write-Host "================ ICONIA localhost 기동 ================" -ForegroundColor Cyan
Write-Host "  target      : local"
Write-Host "  repo root   : $RepoRoot"
Write-Host "  SERVER      : $serverDir  -> http://127.0.0.1:$serverPort  (LAN: $lanServerUrl)"
Write-Host "  AI          : $aiDir  -> http://127.0.0.1:$aiPort  (LAN: $lanAiUrl)"
Write-Host "  ADMIN       : $adminDir  -> http://127.0.0.1:$adminPort"
Write-Host "  PostgreSQL  : ${pgHost}:${pgPort}/${pgDb}  (docker=$pgDocker)"
Write-Host "  LAN IP      : $lanIp  (phone/ESP32 → PC). 변경 시 6.CI/.env 의 LOCAL_LAN_IP."
Write-Host "=======================================================" -ForegroundColor Cyan

# ----- 1) PostgreSQL 16 -----
if (-not $SkipDb) {
  if ($pgDocker) {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
      throw "docker 가 PATH 에 없습니다. Docker Desktop 설치 또는 .env 의 LOCAL_PG_USE_DOCKER=false."
    }
    $existing = & docker ps -a --filter 'name=iconia-pg' --format '{{.Names}}'
    if ($existing -eq 'iconia-pg') {
      Write-Host "[db] 기존 iconia-pg 컨테이너 start"
      & docker start iconia-pg | Out-Null
    } else {
      Write-Host "[db] PostgreSQL 16 컨테이너 생성 (iconia-pg)"
      & docker run -d --name iconia-pg `
        -e POSTGRES_USER=$pgUser `
        -e POSTGRES_PASSWORD=$pgPass `
        -e POSTGRES_DB=$pgDb `
        -p "${pgPort}:5432" `
        -v iconia-pg-data:/var/lib/postgresql/data `
        postgres:16 | Out-Null
    }
    # readiness 대기 (pg_isready).
    Write-Host "[db] readiness 대기..."
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
      & docker exec iconia-pg pg_isready -U $pgUser -d $pgDb 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { $ready = $true; break }
      Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw "PostgreSQL 컨테이너가 준비되지 않았습니다 (60s timeout)." }
    Write-Host "[db] PostgreSQL 16 ready" -ForegroundColor Green
  } else {
    Write-Host "[db] LOCAL_PG_USE_DOCKER=false — 기설치 PostgreSQL 16 서비스를 사용합니다."
    Write-Host "[db] 서비스 확인: Get-Service postgresql* ; 미기동 시: Start-Service postgresql-x64-16"
  }
} else {
  Write-Host "[db] -SkipDb — PostgreSQL 기동 생략"
}

# ----- 서비스 기동 헬퍼 -----
# 각 서비스를 별도 창에서 띄운다. 환경변수는 자식 프로세스에 주입.
function Start-Service-Window {
  param(
    [string] $Title,
    [string] $WorkDir,
    [string] $StartCmd,
    [hashtable] $EnvVars
  )
  $envSetup = ($EnvVars.GetEnumerator() | ForEach-Object {
    "`$env:$($_.Key)='$($_.Value)'"
  }) -join '; '
  $inner = "Set-Location '$WorkDir'; $envSetup; Write-Host '[$Title] $StartCmd' -ForegroundColor Yellow; $StartCmd"
  Start-Process pwsh -ArgumentList '-NoExit', '-Command', $inner | Out-Null
  Write-Host "[$Title] 새 창에서 기동: $StartCmd" -ForegroundColor Green
}

# ----- 2) SERVER 준비 + 기동 -----
# 로컬 dev 전용 고정 토큰 (prefix 로 dev 임을 명시 — 실수로 prod 유출 시 즉시 식별 가능).
# SERVER ↔ AI 양쪽에 동일 값 주입해야 Server→AI 호출이 인증 통과.
$localInternalToken = 'iconia_local_dev_internal_token_do_not_use_in_prod_aaaaaaaa'
# Server/AI 양쪽 .env 가 이미 보유한 HMAC 값. local-up 이 명시 주입해서 .env 의 placeholder 함정 차단.
$localHmacSecret    = '078b5b1564caeb2f1979a760f524250745cda1822210ead6790fcc71e6f0a5a1'

$serverEnv = @{
  DEPLOY_TARGET             = 'local'
  NODE_ENV                  = 'development'
  PORT                      = $serverPort
  DATABASE_URL              = $databaseUrl
  # SERVER → AI 호출은 같은 PC 내 localhost (LAN IP 불필요, 더 빠름).
  AI_BASE_URL               = $aiBaseUrl
  PERSONA_AI_BASE_URL       = $aiBaseUrl
  PERSONA_AI_INTERNAL_TOKEN = $localInternalToken
  PERSONA_AI_HMAC_SECRET    = $localHmacSecret
  # SERVER 의 self URL — 펌웨어/폰에 callback URL(presigned upload, OTA manifest) 발급 시 사용.
  # 폰/ESP32 가 다시 SERVER 로 콜백하려면 LAN IP 여야 함 (127.0.0.1 은 디바이스 자기 자신).
  SERVER_BASE_URL           = $lanServerUrl
  # CORS — ADMIN 브라우저(PC localhost:3000) + LAN 접근 모두 허용.
  # APK 는 native 라 Origin 헤더 미전송, CORS 무관 (브라우저만 해당).
  CORS_ORIGINS              = "http://localhost:${adminPort},http://127.0.0.1:${adminPort},http://${lanIp}:${adminPort},http://${lanIp}:${serverPort}"
  # CloudWatch / SNS publisher 들이 AWS credentials 없이 PutMetricData 호출하지 않게 차단.
  # config.js: CLOUDWATCH_ENABLED=false → metrics.client=null → cost/device_silence publisher dryRun.
  CLOUDWATCH_ENABLED        = 'false'
  AWS_REGION                = 'ap-northeast-2'
}
if (-not $SkipInstall) {
  Push-Location $serverDir
  try {
    Write-Host "[server] npm install"
    & npm install
    if ($LASTEXITCODE -ne 0) { throw "server npm install 실패" }
    if (Test-Path (Join-Path $serverDir 'prisma/schema.prisma')) {
      Write-Host "[server] prisma generate + migrate deploy"
      $env:DATABASE_URL = $databaseUrl
      & npx --yes prisma generate
      if ($LASTEXITCODE -ne 0) { throw "server prisma generate 실패" }
      & npx --yes prisma migrate deploy
      if ($LASTEXITCODE -ne 0) {
        Write-Warning "prisma migrate deploy 실패 — 최초 스키마면 'prisma migrate dev' 를 한 번 수동 실행하세요."
      }
    }
  } finally { Pop-Location }
}
Start-Service-Window -Title 'SERVER' -WorkDir $serverDir `
  -StartCmd 'npm run dev' -EnvVars $serverEnv

# ----- 3) AI 준비 + 기동 -----
$aiEnv = @{
  DEPLOY_TARGET             = 'local'
  NODE_ENV                  = 'development'
  PORT                      = $aiPort
  DATABASE_URL              = $databaseUrl
  # SERVER 와 동일 값 주입 — .env 의 placeholder(CHANGE_ME_INTERNAL_TOKEN) 덮어쓰기.
  PERSONA_AI_INTERNAL_TOKEN = $localInternalToken
  PERSONA_AI_HMAC_SECRET    = $localHmacSecret
  # NODE_ENV=development 라 32자 강제는 안 걸리지만, 안전망으로 32자 이상 dev 토큰 주입.
  AI_METRICS_TOKEN          = 'iconia_local_dev_metrics_token_32chars_min_aaaaaaaaaa'
}
if (-not $SkipInstall) {
  Push-Location $aiDir
  try {
    Write-Host "[ai] npm install"
    & npm install
    if ($LASTEXITCODE -ne 0) { throw "ai npm install 실패" }
  } finally { Pop-Location }
}
Start-Service-Window -Title 'AI' -WorkDir $aiDir `
  -StartCmd 'npm run dev' -EnvVars $aiEnv

# ----- 4) ADMIN 준비 + 기동 -----
$adminEnv = @{
  DEPLOY_TARGET           = 'local'
  NODE_ENV                = 'development'
  PORT                    = $adminPort
  NEXT_PUBLIC_API_BASE_URL = "http://127.0.0.1:$serverPort"
}
if (-not $SkipInstall) {
  Push-Location $adminDir
  try {
    Write-Host "[admin] npm install"
    & npm install
    if ($LASTEXITCODE -ne 0) { throw "admin npm install 실패" }
  } finally { Pop-Location }
}
Start-Service-Window -Title 'ADMIN' -WorkDir $adminDir `
  -StartCmd "npm run dev -- --port $adminPort" -EnvVars $adminEnv

# ----- 5) APP (선택) -----
if ($IncludeApp) {
  if (-not $appDir) {
    Write-Warning "APP 폴더를 찾을 수 없어 -IncludeApp 을 건너뜁니다."
  } else {
    # Expo dev server (`npx expo start` + QR scan) 경로 — 폰이 PC LAN IP 로 SERVER 호출.
    # EAS Custom Dev Client APK 빌드 경로는 4. APP/eas.json 의 development profile env 가 정본.
    # 양쪽 동일 키/값 → QR 경로와 APK 경로 동작 일치.
    $appEnv = @{
      EXPO_PUBLIC_DEPLOY_TARGET        = 'local'
      EXPO_PUBLIC_API_BASE_URL         = $lanServerUrl
      EXPO_PUBLIC_PERSONA_AI_BASE_URL  = $lanAiUrl
      EXPO_PUBLIC_LAN_IP               = $lanIp
    }
    if (-not $SkipInstall) {
      Push-Location $appDir
      try {
        Write-Host "[app] npm install"
        & npm install
        if ($LASTEXITCODE -ne 0) { throw "app npm install 실패" }
      } finally { Pop-Location }
    }
    Start-Service-Window -Title 'APP' -WorkDir $appDir `
      -StartCmd 'npx expo start' -EnvVars $appEnv
  }
}

Write-Host ""
Write-Host "================ 기동 완료 ================" -ForegroundColor Cyan
Write-Host "  SERVER  http://127.0.0.1:$serverPort/health   (LAN: $lanServerUrl/health)"
Write-Host "  AI      http://127.0.0.1:$aiPort/health     (LAN: $lanAiUrl/health)"
Write-Host "  ADMIN   http://127.0.0.1:$adminPort/"
if ($IncludeApp -and $appDir) { Write-Host "  APP     Expo dev server (QR 코드는 APP 창 참조)" }
Write-Host ""
Write-Host "  헬스 확인:"
Write-Host "    Invoke-RestMethod http://127.0.0.1:$serverPort/health"
Write-Host "    Invoke-RestMethod http://127.0.0.1:$aiPort/health"
Write-Host ""
Write-Host "  종료: pwsh -File scripts/local-down.ps1" -ForegroundColor Yellow
Write-Host "===========================================" -ForegroundColor Cyan
