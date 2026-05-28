<#
.SYNOPSIS
  ICONIA 오픈소스 라이선스 자동 생성 (HD-16 처리).

.DESCRIPTION
  4개 Node 레포(SERVER, ADMIN, AI, APP)에서 `license-checker` 실행 → 통합 JSON +
  사람이 읽기 좋은 markdown 생성. HW 펌웨어 의존성은 `1. HW/docs/legal/oss-licenses.md` 정본 참조.

  결과:
    - 6. CI/docs/legal/licenses-{server,admin,ai,app}.json
    - 6. CI/docs/legal/open-source-notice-generated.md (자동 생성)

  본 script 는 출시 전 1회 + 신규 의존성 추가 시마다 실행.

.EXAMPLE
  pwsh -File "6. CI/scripts/generate-oss-notice.ps1"
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ciRoot = Split-Path -Parent $scriptRoot
$iconiaRoot = Split-Path -Parent $ciRoot

$repos = @{
  server = Join-Path $iconiaRoot '2. SERVER'
  ai     = Join-Path $iconiaRoot '3. AI'
  app    = Join-Path $iconiaRoot '4. APP'
  admin  = Join-Path $iconiaRoot '5. ADMIN'
}

$outDir = Join-Path $ciRoot 'docs/legal'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$allLicenses = @{}

foreach ($name in $repos.Keys) {
  $repoPath = $repos[$name]
  if (-not (Test-Path (Join-Path $repoPath 'package.json'))) {
    Write-Host "[$name] package.json not found — skipping"
    continue
  }
  Write-Host "[$name] running license-checker ..."

  Push-Location $repoPath
  try {
    # npx license-checker — production deps only
    $json = & npx --yes license-checker --production --json 2>&1
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "[$name] license-checker failed — skipping"
      continue
    }
    $outFile = Join-Path $outDir "licenses-$name.json"
    $json | Out-File -FilePath $outFile -Encoding UTF8
    Write-Host "[$name] saved → $outFile"
    $parsed = $json | ConvertFrom-Json
    $allLicenses[$name] = $parsed
  } finally {
    Pop-Location
  }
}

# Markdown 생성
$mdOut = Join-Path $outDir 'open-source-notice-generated.md'
$lines = @(
  '# ICONIA 오픈소스 라이선스 고지 (자동 생성)',
  '',
  '> 본 문서는 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + ' UTC 에 `generate-oss-notice.ps1` 가 생성. 출시 빌드 직전 갱신.',
  '',
  '## Summary',
  ''
)

foreach ($repo in $allLicenses.Keys) {
  $pkgs = $allLicenses[$repo].PSObject.Properties
  $count = ($pkgs | Measure-Object).Count
  $lines += "- **$repo**: $count packages"
}

$lines += ''
$lines += '## Detail'
$lines += ''

foreach ($repo in $allLicenses.Keys) {
  $lines += "### $repo"
  $lines += ''
  $lines += '| Package | Version | License | Repository |'
  $lines += '|---|---|---|---|'
  $pkgs = $allLicenses[$repo].PSObject.Properties
  foreach ($p in $pkgs) {
    $key = $p.Name  # e.g. "express@4.18.2"
    $info = $p.Value
    $license = if ($info.licenses) { $info.licenses } else { 'UNKNOWN' }
    $repository = if ($info.repository) { $info.repository } else { '' }
    $parts = $key -split '@'
    $name = if ($parts.Length -ge 2) { ($parts | Select-Object -SkipLast 1) -join '@' } else { $key }
    $version = if ($parts.Length -ge 2) { $parts[-1] } else { '' }
    $lines += "| $name | $version | $license | $repository |"
  }
  $lines += ''
}

$lines += '## HW (Firmware) — 정본'
$lines += ''
$lines += '`1. HW/docs/legal/oss-licenses.md` 참조 (펌웨어 의존성: esp-idf Apache-2.0, Arduino core LGPL-2.1, ArduinoJson MIT 등)'
$lines += ''
$lines += '## 본 문서 운영'
$lines += '- 출시 빌드 전 1회 자동 생성'
$lines += '- 신규 의존성 PR 시 CI 가 license-compliance 검사 (`license-compliance.yml`)'
$lines += '- GPL/AGPL 도입 시 사내 법무 검토 의무화'

$lines -join "`n" | Out-File -FilePath $mdOut -Encoding UTF8
Write-Host ""
Write-Host "Generated: $mdOut"
Write-Host "Done."
