<#
.SYNOPSIS
  ICONIA HW 통합 테스트용 HTTPS 리버스 프록시(caddy) 기동.

.DESCRIPTION
  ESP32 펌웨어는 HTTPS 만 호출하므로 PC 의 :8443(HTTPS) → :8080(HTTP) 프록시 필요.
  caddy reverse-proxy + tls internal 로 self-signed cert 자동 발급.
  그 local CA 의 rootCA.pem 을 펌웨어 dev.h 의 ICONIA_SERVER_ROOT_CA_PEM 에 pin 해야
  ESP32 가 cert 를 신뢰한다.

  ★ 최초 1회 셋업:
      1) winget install caddyserver   # 또는 choco install caddy
      2) 관리자 PowerShell 1회:  caddy trust   # Windows 신뢰 저장소 등록
      3) 본 스크립트 실행 → 새 창에서 caddy 가 떠 있음
      4) rootCA.pem 위치 출력 확인 → 펌웨어 dev.h 의 PEM 매크로에 paste
      5) 펌웨어 재빌드 + flash

  ★ 일상 실행:
      pwsh -File scripts/start-hw-proxy.ps1
      (이미 떠 있으면 종료 후 재기동 권장 — config 변경 시.)

.PARAMETER ServerPort
  대상 SERVER 포트 (기본 8080, .env 의 LOCAL_SERVER_PORT 와 일치).

.PARAMETER ProxyPort
  caddy 가 listen 할 HTTPS 포트 (기본 8443).
#>

[CmdletBinding()]
param(
	[int] $ServerPort = 8080,
	[int] $ProxyPort  = 8443
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$caddyfile   = Join-Path $scriptRoot 'Caddyfile.hw-proxy'

if (-not (Test-Path -LiteralPath $caddyfile)) {
	throw "Caddyfile 없음: $caddyfile"
}

# caddy 설치 확인.
$caddyCmd = Get-Command caddy -ErrorAction SilentlyContinue
if (-not $caddyCmd) {
	Write-Host "================ caddy 미설치 ================" -ForegroundColor Red
	Write-Host "  설치 (택 1):"
	Write-Host "    winget install caddyserver"
	Write-Host "    choco install caddy"
	Write-Host "  설치 후:"
	Write-Host "    1. 관리자 PowerShell 1회:  caddy trust"
	Write-Host "    2. 본 스크립트 재실행"
	throw 'caddy not found in PATH'
}

# 포트 사용 확인.
$listener = Get-NetTCPConnection -LocalPort $ProxyPort -State Listen -ErrorAction SilentlyContinue
if ($listener) {
	Write-Warning "포트 $ProxyPort 가 이미 사용 중 (PID $($listener[0].OwningProcess)). 기존 caddy 가 떠 있을 수 있음."
	Write-Warning "종료 후 재기동:  Stop-Process -Id $($listener[0].OwningProcess)"
}

# Caddyfile 의 ServerPort/ProxyPort 가 인자와 다르면 경고.
$caddyfileContent = Get-Content -LiteralPath $caddyfile -Raw
if ($ServerPort -ne 8080 -and $caddyfileContent -notmatch "localhost:$ServerPort") {
	Write-Warning "Caddyfile 은 :8080 으로 박혀있음. -ServerPort $ServerPort 사용하려면 Caddyfile 도 수정."
}
if ($ProxyPort -ne 8443 -and $caddyfileContent -notmatch ":$ProxyPort") {
	Write-Warning "Caddyfile 은 :8443 으로 박혀있음. -ProxyPort $ProxyPort 사용하려면 Caddyfile 도 수정."
}

Write-Host "================ HW HTTPS 프록시 기동 ================" -ForegroundColor Cyan
Write-Host "  proxy   : https://0.0.0.0:$ProxyPort  →  http://localhost:$ServerPort"
Write-Host "  caddyfile: $caddyfile"
Write-Host "======================================================"

# 새 창에서 caddy 기동 (로그 분리).
$inner = "Set-Location '$scriptRoot'; Write-Host '[HW-PROXY] caddy run --config Caddyfile.hw-proxy' -ForegroundColor Yellow; caddy run --config '$caddyfile'"
Start-Process pwsh -ArgumentList '-NoExit', '-Command', $inner | Out-Null
Write-Host "[HW-PROXY] 새 창에서 기동 (Ctrl+C 로 종료)" -ForegroundColor Green

# rootCA.pem 위치 안내. Windows 의 caddy 는 %APPDATA% (Roaming) 을 사용.
$caddyData = Join-Path $env:APPDATA 'Caddy\pki\authorities\local'
$rootCa    = Join-Path $caddyData 'root.crt'
$rootKey   = Join-Path $caddyData 'root.key'

Write-Host ""
Write-Host "================ 펌웨어 dev.h 갱신 ================" -ForegroundColor Cyan
Write-Host "  local CA root cert (caddy 가 발급한 self-signed CA):"
Write-Host "    $rootCa"
Write-Host ""
Write-Host "  내용 확인 (caddy 가 처음 떠야 생성됨, 5-10초 대기):"
Write-Host "    Get-Content '$rootCa' -Raw"
Write-Host ""
Write-Host "  이 PEM 을 펌웨어의 다음 매크로에 paste:"
Write-Host "    1. HW/ICONIA Firmware/build_profiles/dev.h"
Write-Host "    ICONIA_SERVER_ROOT_CA_PEM"
Write-Host ""
Write-Host "  최초 1회 — Windows 신뢰 저장소 등록 (관리자 권한 필요):"
Write-Host "    caddy trust   # 폰/PC 브라우저가 cert 를 신뢰하도록"
Write-Host "==================================================" -ForegroundColor Cyan
