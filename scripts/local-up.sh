#!/usr/bin/env bash
###############################################################################
# local-up.sh — ICONIA localhost 전체 기동 (Linux/macOS).
#
# local-up.ps1 (Windows 운영자용) 의 Linux 등가물.
# PostgreSQL 16 + SERVER + AI + ADMIN 을 로컬에서 띄운다. 각 서비스는
# nohup 백그라운드 프로세스로 떠서 PID 가 /tmp/iconia-local/*.pid 에 기록된다.
#
# 단일 토글: 본 스크립트는 ICONIA_TARGET=local 을 강제하고 각 서비스에
# 로컬 DATABASE_URL / AI_BASE_URL 을 주입한다.
#
# 사용법:
#   scripts/local-up.sh [--repo-root <ICONIA root>] [--include-app]
#                       [--skip-install] [--skip-db]
#
# 종료: scripts/local-down.sh
#
# .env 자동 로드: 6.CI 루트의 .env (있으면).
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_ROOT="$(dirname "$SCRIPT_DIR")"

REPO_ROOT=""
INCLUDE_APP=0
SKIP_INSTALL=0
SKIP_DB=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root)    REPO_ROOT="$2"; shift 2 ;;
    --include-app)  INCLUDE_APP=1; shift ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --skip-db)      SKIP_DB=1; shift ;;
    -h|--help)      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERR: unknown arg $1" >&2; exit 2 ;;
  esac
done

log() { printf '[local-up %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

# ----- .env 로드 -----
if [ -f "${CI_ROOT}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${CI_ROOT}/.env"
  set +a
fi

cfg() { eval "v=\${$1:-}"; [ -n "${v:-}" ] && printf '%s' "$v" || printf '%s' "${2:-}"; }

[ -n "$REPO_ROOT" ] || REPO_ROOT="$(cfg ICONIA_REPO_ROOT "$(dirname "$CI_ROOT")")"
[ -d "$REPO_ROOT" ] || { echo "ERR: ICONIA repo root 없음: $REPO_ROOT" >&2; exit 1; }

PG_HOST="$(cfg LOCAL_PG_HOST 127.0.0.1)"
PG_PORT="$(cfg LOCAL_PG_PORT 5432)"
PG_USER="$(cfg LOCAL_PG_USER iconia)"
PG_PASS="$(cfg LOCAL_PG_PASSWORD iconia_local_dev)"
PG_DB="$(cfg LOCAL_PG_DATABASE iconia)"
PG_DOCKER="$(cfg LOCAL_PG_USE_DOCKER true)"

SERVER_PORT="$(cfg LOCAL_SERVER_PORT 8080)"
AI_PORT="$(cfg LOCAL_AI_PORT 3001)"
ADMIN_PORT="$(cfg LOCAL_ADMIN_PORT 3000)"
AI_BASE_URL="$(cfg LOCAL_AI_BASE_URL "http://127.0.0.1:${AI_PORT}")"

DATABASE_URL="postgresql://${PG_USER}:${PG_PASS}@${PG_HOST}:${PG_PORT}/${PG_DB}?schema=public"

RUN_DIR="/tmp/iconia-local"
mkdir -p "$RUN_DIR"

# 서비스 소스 디렉토리 해석 — sibling / 숫자 폴더 두 레이아웃 지원.
resolve_dir() {
  local a="$1" b="$2"
  if   [ -d "${REPO_ROOT}/${a}" ]; then echo "${REPO_ROOT}/${a}"
  elif [ -d "${REPO_ROOT}/${b}" ]; then echo "${REPO_ROOT}/${b}"
  else echo ""
  fi
}

SERVER_DIR="$(resolve_dir 'ICONIA-SERVER' '2. SERVER')"
AI_DIR="$(resolve_dir 'ICONIA-AI' '3. AI')"
ADMIN_DIR="$(resolve_dir 'ICONIA-ADMIN' '5. ADMIN')"
APP_DIR="$(resolve_dir 'ICONIA-APP' '4. APP')"

[ -n "$SERVER_DIR" ] || { echo "ERR: SERVER 폴더 없음 (ICONIA-SERVER / '2. SERVER')" >&2; exit 1; }
[ -n "$AI_DIR" ]     || { echo "ERR: AI 폴더 없음 (ICONIA-AI / '3. AI')" >&2; exit 1; }
[ -n "$ADMIN_DIR" ]  || { echo "ERR: ADMIN 폴더 없음 (ICONIA-ADMIN / '5. ADMIN')" >&2; exit 1; }

echo "================ ICONIA localhost 기동 ================"
echo "  target     : local"
echo "  repo root  : $REPO_ROOT"
echo "  SERVER     : $SERVER_DIR -> http://127.0.0.1:${SERVER_PORT}"
echo "  AI         : $AI_DIR -> http://127.0.0.1:${AI_PORT}"
echo "  ADMIN      : $ADMIN_DIR -> http://127.0.0.1:${ADMIN_PORT}"
echo "  PostgreSQL : ${PG_HOST}:${PG_PORT}/${PG_DB} (docker=${PG_DOCKER})"
echo "======================================================="

# ----- 1) PostgreSQL 16 -----
if [ "$SKIP_DB" -eq 0 ]; then
  if [ "$PG_DOCKER" = "true" ]; then
    command -v docker >/dev/null || { echo "ERR: docker 필요 (또는 .env LOCAL_PG_USE_DOCKER=false)" >&2; exit 1; }
    if docker ps -a --filter 'name=iconia-pg' --format '{{.Names}}' | grep -qx 'iconia-pg'; then
      log "db: 기존 iconia-pg 컨테이너 start"
      docker start iconia-pg >/dev/null
    else
      log "db: PostgreSQL 16 컨테이너 생성 (iconia-pg)"
      docker run -d --name iconia-pg \
        -e POSTGRES_USER="$PG_USER" \
        -e POSTGRES_PASSWORD="$PG_PASS" \
        -e POSTGRES_DB="$PG_DB" \
        -p "${PG_PORT}:5432" \
        -v iconia-pg-data:/var/lib/postgresql/data \
        postgres:16 >/dev/null
    fi
    log "db: readiness 대기..."
    ready=0
    for _ in $(seq 1 30); do
      if docker exec iconia-pg pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then ready=1; break; fi
      sleep 2
    done
    [ "$ready" -eq 1 ] || { echo "ERR: PostgreSQL 컨테이너 미준비 (60s timeout)" >&2; exit 1; }
    log "db: PostgreSQL 16 ready"
  else
    log "db: LOCAL_PG_USE_DOCKER=false — 기설치 PostgreSQL 16 서비스를 사용"
  fi
else
  log "db: --skip-db — PostgreSQL 기동 생략"
fi

# 서비스 백그라운드 기동 헬퍼.
start_service() {
  local name="$1" dir="$2" cmd="$3"
  shift 3
  local logf="${RUN_DIR}/${name}.log"
  local pidf="${RUN_DIR}/${name}.pid"
  log "${name}: 기동 ($cmd) -> ${logf}"
  ( cd "$dir" && env "$@" nohup bash -lc "$cmd" >"$logf" 2>&1 & echo $! >"$pidf" )
  log "${name}: PID $(cat "$pidf")"
}

# ----- 2) SERVER -----
if [ "$SKIP_INSTALL" -eq 0 ]; then
  log "server: npm install"
  ( cd "$SERVER_DIR" && npm install )
  if [ -f "${SERVER_DIR}/prisma/schema.prisma" ]; then
    log "server: prisma generate + migrate deploy"
    ( cd "$SERVER_DIR" && DATABASE_URL="$DATABASE_URL" npx --yes prisma generate )
    ( cd "$SERVER_DIR" && DATABASE_URL="$DATABASE_URL" npx --yes prisma migrate deploy ) \
      || log "WARN: prisma migrate deploy 실패 — 최초 스키마면 'prisma migrate dev' 수동 1회"
  fi
fi
start_service server "$SERVER_DIR" "npm run dev" \
  ICONIA_TARGET=local NODE_ENV=development PORT="$SERVER_PORT" \
  DATABASE_URL="$DATABASE_URL" AI_BASE_URL="$AI_BASE_URL"

# ----- 3) AI -----
if [ "$SKIP_INSTALL" -eq 0 ]; then
  log "ai: npm install"
  ( cd "$AI_DIR" && npm install )
fi
start_service ai "$AI_DIR" "npm run dev" \
  ICONIA_TARGET=local NODE_ENV=development PORT="$AI_PORT" \
  DATABASE_URL="$DATABASE_URL"

# ----- 4) ADMIN -----
if [ "$SKIP_INSTALL" -eq 0 ]; then
  log "admin: npm install"
  ( cd "$ADMIN_DIR" && npm install )
fi
start_service admin "$ADMIN_DIR" "npm run dev -- --port ${ADMIN_PORT}" \
  ICONIA_TARGET=local NODE_ENV=development PORT="$ADMIN_PORT" \
  NEXT_PUBLIC_API_BASE_URL="http://127.0.0.1:${SERVER_PORT}"

# ----- 5) APP (선택) -----
if [ "$INCLUDE_APP" -eq 1 ]; then
  if [ -n "$APP_DIR" ]; then
    if [ "$SKIP_INSTALL" -eq 0 ]; then
      log "app: npm install"
      ( cd "$APP_DIR" && npm install )
    fi
    start_service app "$APP_DIR" "npx expo start" \
      ICONIA_TARGET=local EXPO_PUBLIC_API_BASE_URL="http://127.0.0.1:${SERVER_PORT}"
  else
    log "WARN: APP 폴더 없음 — --include-app 건너뜀"
  fi
fi

echo ""
echo "================ 기동 완료 ================"
echo "  SERVER  http://127.0.0.1:${SERVER_PORT}/health"
echo "  AI      http://127.0.0.1:${AI_PORT}/health"
echo "  ADMIN   http://127.0.0.1:${ADMIN_PORT}/"
echo "  로그    tail -f ${RUN_DIR}/<service>.log"
echo "  종료    scripts/local-down.sh"
echo "==========================================="
