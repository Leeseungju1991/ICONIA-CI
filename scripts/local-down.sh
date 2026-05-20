#!/usr/bin/env bash
###############################################################################
# local-down.sh — ICONIA localhost 종료 (Linux/macOS).
#
# local-up.sh 가 /tmp/iconia-local/*.pid 에 기록한 서비스 프로세스를 종료하고,
# (Docker 모드면) PostgreSQL 컨테이너를 정리한다.
#
# 사용법:
#   scripts/local-down.sh [--remove-db] [--keep-db]
#
#   --remove-db : iconia-pg 컨테이너 + iconia-pg-data 볼륨 완전 삭제 (데이터 초기화)
#   --keep-db   : PostgreSQL 은 건드리지 않음 (Node 프로세스만 종료)
###############################################################################
set -euo pipefail

RUN_DIR="/tmp/iconia-local"
REMOVE_DB=0
KEEP_DB=0

while [ $# -gt 0 ]; do
  case "$1" in
    --remove-db) REMOVE_DB=1; shift ;;
    --keep-db)   KEEP_DB=1; shift ;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERR: unknown arg $1" >&2; exit 2 ;;
  esac
done

log() { printf '[local-down %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

echo "================ ICONIA localhost 종료 ================"

# ----- 서비스 프로세스 종료 -----
if [ -d "$RUN_DIR" ]; then
  for pidf in "$RUN_DIR"/*.pid; do
    [ -f "$pidf" ] || continue
    name="$(basename "$pidf" .pid)"
    pid="$(cat "$pidf" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log "kill ${name} (PID ${pid}) + 자식 프로세스"
      # npm run dev 는 자식(node)을 띄우므로 프로세스 그룹 단위로 종료.
      pkill -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
    else
      log "${name}: 이미 종료됨"
    fi
    rm -f "$pidf"
  done
else
  log "실행 기록(${RUN_DIR}) 없음 — 포트 기반 정리로 폴백"
fi

# 포트 기반 폴백 정리 (PID 파일 유실 대비).
for port in 8080 3001 3000 8081 19000 19006; do
  if command -v lsof >/dev/null; then
    pids="$(lsof -ti tcp:"$port" 2>/dev/null || true)"
    for p in $pids; do
      log "kill port ${port} -> PID ${p}"
      kill "$p" 2>/dev/null || true
    done
  fi
done

# ----- PostgreSQL 컨테이너 -----
if [ "$KEEP_DB" -eq 0 ]; then
  if command -v docker >/dev/null; then
    if docker ps -a --filter 'name=iconia-pg' --format '{{.Names}}' | grep -qx 'iconia-pg'; then
      if [ "$REMOVE_DB" -eq 1 ]; then
        log "db: iconia-pg 컨테이너 + 볼륨 삭제 (--remove-db)"
        docker rm -f iconia-pg >/dev/null 2>&1 || true
        docker volume rm iconia-pg-data >/dev/null 2>&1 || true
      else
        log "db: iconia-pg 컨테이너 stop (데이터 보존)"
        docker stop iconia-pg >/dev/null 2>&1 || true
      fi
    fi
  fi
else
  log "db: --keep-db — PostgreSQL 그대로 둠"
fi

echo "================ 종료 완료 ================"
