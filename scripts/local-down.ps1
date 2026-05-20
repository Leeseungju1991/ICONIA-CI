<#
.SYNOPSIS
  ICONIA localhost 전체 종료 — local-up.ps1 로 띄운 컴포넌트를 정리.

.DESCRIPTION
  로컬 기동한 SERVER / AI / ADMIN / APP 의 Node 프로세스와 (Docker 모드면)
  PostgreSQL 컨테이너를 정리한다.

  기본은 PostgreSQL 컨테이너를 stop 만 한다 (데이터 보존).
  -RemoveDb 지정 시 컨테이너 + 볼륨까지 삭제 (데이터 초기화).

.PARAMETER RemoveDb
  iconia-pg 컨테이너와 iconia-pg-data 볼륨을 완전 삭제.

.PARAMETER KeepDb
  PostgreSQL 은 건드리지 않고 Node 프로세스만 종료.

.EXAMPLE
  pwsh -File scripts/local-down.ps1
  pwsh -File scripts/local-down.ps1 -RemoveDb
#>

[CmdletBinding()]
param(
  [switch] $RemoveDb,
  [switch] $KeepDb
)

$ErrorActionPreference = 'Continue'

Write-Host "================ ICONIA localhost 종료 ================" -ForegroundColor Cyan

# ----- 로컬 기동 포트를 점유한 프로세스 종료 -----
# local-up 이 쓰는 포트: SERVER 8080 / AI 3001 / ADMIN 3000 / Expo 8081·19000·19006.
$ports = @(8080, 3001, 3000, 8081, 19000, 19006)
foreach ($port in $ports) {
  try {
    $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $conns) {
      $procId = $c.OwningProcess
      $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
      if ($proc) {
        Write-Host "[kill] port $port -> PID $procId ($($proc.ProcessName))"
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
      }
    }
  } catch {
    Write-Host "[skip] port $port 점검 실패: $_"
  }
}

# ----- PostgreSQL 컨테이너 -----
if (-not $KeepDb) {
  if (Get-Command docker -ErrorAction SilentlyContinue) {
    $existing = & docker ps -a --filter 'name=iconia-pg' --format '{{.Names}}' 2>$null
    if ($existing -eq 'iconia-pg') {
      if ($RemoveDb) {
        Write-Host "[db] iconia-pg 컨테이너 + 볼륨 삭제 (-RemoveDb)"
        & docker rm -f iconia-pg 2>$null | Out-Null
        & docker volume rm iconia-pg-data 2>$null | Out-Null
      } else {
        Write-Host "[db] iconia-pg 컨테이너 stop (데이터 보존)"
        & docker stop iconia-pg 2>$null | Out-Null
      }
    }
  }
} else {
  Write-Host "[db] -KeepDb — PostgreSQL 은 그대로 둠"
}

Write-Host "================ 종료 완료 ================" -ForegroundColor Cyan
Write-Host "  서비스 창은 수동으로 닫아 주세요 (각 npm run dev 창)."
