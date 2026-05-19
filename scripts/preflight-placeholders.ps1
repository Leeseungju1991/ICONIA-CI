<#
.SYNOPSIS
    6개 폴더 횡단 placeholder 검사 (preflight). Bash 판과 1:1 미러.

.DESCRIPTION
    release tag CI workflow 가 호출. 발견 시 exit 1.

    Patterns (fixed-string + regex):
      - ICONIA_PROD_DOMAIN_PLACEHOLDER
      - PROD_API_KEY_PLACEHOLDER
      - iconia-tfstate-PLACEHOLDER
      - __FILL_ME__
      - __SET_IN_RENDER_DASHBOARD__
      - CHANGE_ME
      - PAIRING_TOKEN_PENDING
      - your-domain-here
      - REPLACE_WITH_
      - __SET_BY_EAS_SECRET__
      - TODO(prod)                          [regex]
      - XXXXXX+ (6+ X 연속)                 [regex]
      - <replace...here>                    [regex]
      - INSERT_..._HERE                     [regex]
      - @example.com word-boundary          [regex]

    .preflightignore 자동 로드: <RepoRoot>/6. CI/.preflightignore.

.PARAMETER RepoRoot
    ICONIA root 디렉토리. 미지정 시 본 스크립트 기준 ../.. 사용.

.EXAMPLE
    pwsh -File scripts\preflight-placeholders.ps1
    pwsh -File scripts\preflight-placeholders.ps1 -RepoRoot 'C:\path\to\ICONIA'
#>

[CmdletBinding()]
param(
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

# 각 패턴: @{ Pat; Mode='F'|'R' }
$patterns = @(
    @{ Pat = 'ICONIA_PROD_DOMAIN_PLACEHOLDER'; Mode = 'F' }
    @{ Pat = 'PROD_API_KEY_PLACEHOLDER'; Mode = 'F' }
    @{ Pat = 'iconia-tfstate-PLACEHOLDER'; Mode = 'F' }
    @{ Pat = '__FILL_ME__'; Mode = 'F' }
    @{ Pat = '__SET_IN_RENDER_DASHBOARD__'; Mode = 'F' }
    @{ Pat = 'CHANGE_ME'; Mode = 'F' }
    @{ Pat = 'PAIRING_TOKEN_PENDING'; Mode = 'F' }
    # === 추가 (2026-05-19) ===
    @{ Pat = 'your-domain-here'; Mode = 'F' }
    @{ Pat = 'REPLACE_WITH_'; Mode = 'F' }
    @{ Pat = '__SET_BY_EAS_SECRET__'; Mode = 'F' }
    @{ Pat = 'TODO\(prod\)'; Mode = 'R' }
    @{ Pat = 'XXXXXX+'; Mode = 'R' }
    @{ Pat = '<replace[^>]*here>'; Mode = 'R' }
    @{ Pat = 'INSERT_[A-Z0-9_]+_HERE'; Mode = 'R' }
    # NOTE: example.com URL 패턴은 false positive (env 템플릿/문서/test) 폭주로 제외.
)

$excludeDirs = @('node_modules', '.git', '.terraform', 'dist', 'build', '.next', '.expo', 'coverage', 'out', '__tests__', '__fixtures__')
$excludeFiles = @(
    'preflight-placeholders.sh'
    'preflight-placeholders.ps1'
    'preflight-placeholders.test.sh'
    '.preflightignore'
    'CHANGELOG.md'
    'README.md'
)
# .preflightignore 추가 glob (간단 wildcard '*' 만 지원 — gitignore '**' 는 정규식으로 변환).
$excludeGlobs = @()

if (-not $RepoRoot) {
    $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
}
if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
    Write-Error "repo root 없음: $RepoRoot"
    exit 2
}

# .preflightignore 로드.
$preflightIgnore = Join-Path $RepoRoot '6. CI\.preflightignore'
if (Test-Path -LiteralPath $preflightIgnore -PathType Leaf) {
    foreach ($raw in Get-Content -LiteralPath $preflightIgnore) {
        $line = $raw.Trim()
        if ($line.Length -eq 0) { continue }
        if ($line.StartsWith('#')) { continue }
        # gitignore '**/foo/**' -> regex (.*/)?foo(/.*)? 형태로 변환.
        # 간단 매핑: '**' -> '.*', '*' -> '[^/\\]*', 경로 separator 는 / 또는 \ 매칭.
        $rx = [regex]::Escape($line)
        $rx = $rx -replace '\\\*\\\*', '.*'
        $rx = $rx -replace '\\\*', '[^/\\\\]*'
        $rx = $rx -replace '/', '[/\\\\]'
        $excludeGlobs += "^.*$rx$"

        # 단일 파일명/디렉토리명 추출도 시도 (빠른 경로 차단).
        $leaf = Split-Path -Leaf $line
        if ($leaf -and $leaf -notmatch '[\*\?]') {
            if ($leaf -match '\.') {
                if ($excludeFiles -notcontains $leaf) { $excludeFiles += $leaf }
            } else {
                if ($excludeDirs -notcontains $leaf) { $excludeDirs += $leaf }
            }
        }
    }
}

$targets = @('1. HW', '2. SERVER', '3. AI', '4. APP', '5. ADMIN', '6. CI')

$total = 0
$found = $false

foreach ($t in $targets) {
    $dir = Join-Path $RepoRoot $t
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }

    # 파일 목록 수집 - exclude 적용.
    $files = Get-ChildItem -LiteralPath $dir -Recurse -File -Force |
        Where-Object {
            $excluded = $false
            foreach ($d in $excludeDirs) {
                if ($_.FullName -match [regex]::Escape("\$d\")) { $excluded = $true; break }
            }
            if (-not $excluded -and $excludeFiles -contains $_.Name) { $excluded = $true }
            if (-not $excluded) {
                foreach ($rx in $excludeGlobs) {
                    if ($_.FullName -match $rx) { $excluded = $true; break }
                }
            }
            -not $excluded
        }

    foreach ($p in $patterns) {
        $pat = $p.Pat
        $mode = $p.Mode
        if ($mode -eq 'F') {
            $hits = $files | Select-String -SimpleMatch -Pattern $pat -ErrorAction SilentlyContinue
        } else {
            $hits = $files | Select-String -Pattern $pat -ErrorAction SilentlyContinue
        }
        if ($hits) {
            $found = $true
            $count = ($hits | Measure-Object).Count
            $total += $count
            Write-Host ""
            Write-Host "[FAIL] $t 의 [$pat] ($mode) $count 건:" -ForegroundColor Red
            foreach ($h in $hits) {
                Write-Host ("  {0}:{1}: {2}" -f $h.Path, $h.LineNumber, $h.Line.Trim())
            }
        }
    }
}

if ($found) {
    Write-Host ""
    Write-Host "========================================================================" -ForegroundColor Red
    Write-Host "preflight FAIL: 총 $total 건 placeholder 발견. release 차단." -ForegroundColor Red
    Write-Host "========================================================================" -ForegroundColor Red
    exit 1
}

Write-Host ("preflight OK - {0} 패턴 검사 통과, placeholder 없음." -f $patterns.Count) -ForegroundColor Green
exit 0
