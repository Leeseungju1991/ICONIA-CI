<#
.SYNOPSIS
    Seed data preflight - cross-repo ICONIA-SERVER/prisma/seed-data/*.json 검증.

.DESCRIPTION
    aws-deploy.ps1 의 -Seed / -Reseed / -ApplyInfra(첫 배포 자동시드) 흐름이
    실제로 시드를 트리거하기 전, SERVER 레포에 mock 데이터 JSON 이 살아 있고
    스키마가 깨지지 않았는지 검증한다.

    검사 단계:
      1) seed-data 디렉토리 존재 (없으면 WARN — 빈 DB 출시 허용)
      2) 각 *.json 이 Get-Content | ConvertFrom-Json 으로 valid 한지
      3) 필수 카테고리 존재 (users / characters / rooms / legal-agreements / notices)
         - 없으면 ERROR (exit 1)
      4) 비핵심 카테고리 (feed / products / orders) 가 있을 경우 1/3 샘플링 검증
         - "sampling": true 필드 또는 size 점검만 — 결손이어도 WARN
      5) 결과 요약 (✅/⚠️/❌ 표) + exit code

.PARAMETER ServerRoot
    ICONIA-SERVER 레포 루트. 기본 ../../ICONIA-SERVER (cross-repo sibling 가정).

.PARAMETER EssentialOnly
    -EssentialOnly 시드 흐름과 정합 — 비핵심 카테고리 결손은 WARN 으로만.

.EXAMPLE
    pwsh -File scripts/preflight-seed-data.ps1
    pwsh -File scripts/preflight-seed-data.ps1 -ServerRoot C:\proj\ICONIA-SERVER
    pwsh -File scripts/preflight-seed-data.ps1 -EssentialOnly
#>

[CmdletBinding()]
param(
    [string]$ServerRoot,
    [switch]$EssentialOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ciRoot     = Split-Path -Parent $scriptRoot

if (-not $ServerRoot) {
    # CI root 의 sibling 으로 ICONIA-SERVER 추정 — monorepo 와 sibling-repo 모두 시도.
    $candidates = @(
        (Join-Path (Split-Path -Parent $ciRoot) 'ICONIA-SERVER')
        (Join-Path (Split-Path -Parent $ciRoot) '2. SERVER')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Container) { $ServerRoot = $c; break }
    }
}

if (-not $ServerRoot -or -not (Test-Path -LiteralPath $ServerRoot -PathType Container)) {
    Write-Host "[seed-preflight] ⚠️  ICONIA-SERVER 레포를 찾지 못함 (cross-repo). 검사 skip." -ForegroundColor Yellow
    Write-Host "  -ServerRoot 로 명시하거나 sibling 디렉토리에 배치 권장."
    exit 0
}

$seedDir = Join-Path $ServerRoot 'prisma/seed-data'
Write-Host "[seed-preflight] seed-data root = $seedDir"

if (-not (Test-Path -LiteralPath $seedDir -PathType Container)) {
    Write-Host "[seed-preflight] ⚠️  seed-data 디렉토리 없음 — 빈 DB 출시로 진행 가능." -ForegroundColor Yellow
    Write-Host "  APP 에이전트가 prisma/seed-data/*.json 으로 mock 데이터 export 중일 수 있음."
    exit 0
}

# 필수 / 비핵심 카테고리 매핑 (파일명 stem 기준).
$essential   = @('users', 'characters', 'rooms', 'legal-agreements', 'notices')
$nonEssential = @('feed', 'products', 'orders')

# 별칭 허용 (서버 측 export 가 카테고리명을 약간 다르게 쓸 수 있음).
$aliases = @{
    'users'             = @('users', 'user')
    'characters'        = @('characters', 'character', 'personas')
    'rooms'             = @('rooms', 'room', 'spaces')
    'legal-agreements'  = @('legal-agreements', 'legal_agreements', 'agreements', 'legal')
    'notices'           = @('notices', 'notice', 'announcements')
    'feed'              = @('feed', 'posts')
    'products'          = @('products', 'product', 'catalog')
    'orders'            = @('orders', 'order')
}

$jsonFiles = Get-ChildItem -LiteralPath $seedDir -Filter '*.json' -File -ErrorAction SilentlyContinue
if (-not $jsonFiles -or $jsonFiles.Count -eq 0) {
    Write-Host "[seed-preflight] ⚠️  seed-data 디렉토리는 있으나 *.json 0개." -ForegroundColor Yellow
    exit 0
}

Write-Host "[seed-preflight] $($jsonFiles.Count) 개 JSON 파일 발견"

$errors  = @()
$warnings = @()
$ok      = @()

# JSON valid 검증.
$parsed = @{}  # stem -> object
foreach ($f in $jsonFiles) {
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name).ToLowerInvariant()
    try {
        $obj = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $parsed[$stem] = $obj
        $ok += "JSON valid: $($f.Name)"
    } catch {
        $errors += "JSON parse 실패: $($f.Name) — $($_.Exception.Message)"
    }
}

function Resolve-Category {
    param([string]$Canonical, [hashtable]$Parsed, [hashtable]$Aliases)
    foreach ($alias in $Aliases[$Canonical]) {
        if ($Parsed.ContainsKey($alias)) { return $alias }
    }
    return $null
}

# 필수 카테고리 — 결손 시 ERROR.
foreach ($cat in $essential) {
    $found = Resolve-Category -Canonical $cat -Parsed $parsed -Aliases $aliases
    if ($found) {
        $obj = $parsed[$found]
        $n = if ($obj -is [System.Array]) { $obj.Count } elseif ($obj.PSObject.Properties.Name -contains 'items') { $obj.items.Count } else { 1 }
        $ok += "필수 카테고리 ✓ $cat (file=$found.json, n=$n)"
    } else {
        $errors += "필수 카테고리 결손: $cat (허용 별칭: $($aliases[$cat] -join ', '))"
    }
}

# 비핵심 카테고리 — 1/3 샘플링 검증.
foreach ($cat in $nonEssential) {
    $found = Resolve-Category -Canonical $cat -Parsed $parsed -Aliases $aliases
    if (-not $found) {
        if ($EssentialOnly) {
            $warnings += "비핵심 카테고리 미존재: $cat (EssentialOnly 이므로 OK)"
        } else {
            $warnings += "비핵심 카테고리 미존재: $cat (배포는 계속 — 시드 단계가 skip)"
        }
        continue
    }
    $obj = $parsed[$found]
    # sampling 필드 확인 (서버측 mock export 가 1/3 샘플임을 명시할 수 있음).
    $hasSampling = $false
    if ($obj -isnot [System.Array] -and $obj.PSObject.Properties.Name -contains 'sampling') {
        $hasSampling = [bool]$obj.sampling
    }
    $size = if ($obj -is [System.Array]) { $obj.Count }
            elseif ($obj.PSObject.Properties.Name -contains 'items') { $obj.items.Count }
            else { 1 }
    if ($hasSampling) {
        $ok += "비핵심 카테고리 ✓ $cat (file=$found.json, sampling=true, n=$size)"
    } else {
        $warnings += "비핵심 카테고리 $cat 에 'sampling' 필드 없음 (full export 일 수 있음, n=$size)"
    }
}

Write-Host ""
Write-Host "================ seed-data preflight 결과 ================" -ForegroundColor Cyan
foreach ($m in $ok)       { Write-Host "  ✅ $m" -ForegroundColor Green }
foreach ($m in $warnings) { Write-Host "  ⚠️  $m" -ForegroundColor Yellow }
foreach ($m in $errors)   { Write-Host "  ❌ $m" -ForegroundColor Red }
Write-Host "==========================================================" -ForegroundColor Cyan

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "seed-data preflight FAIL: 필수 카테고리 $($errors.Count) 건 결손." -ForegroundColor Red
    Write-Host "ICONIA-APP / ICONIA-SERVER 에이전트의 mock export 산출물 확인 필요." -ForegroundColor Red
    exit 1
}

Write-Host "seed-data preflight OK — 필수 $($essential.Count) 카테고리 모두 present, warnings=$($warnings.Count)" -ForegroundColor Green
exit 0
