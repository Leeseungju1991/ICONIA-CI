#!/usr/bin/env bash
###############################################################################
# post-deploy-smoke.sh — 배포 직후 외부 진입점(Route53 + nginx) 스모크 테스트.
#
# ec2-pull-and-restart.sh 의 healthcheck 는 EC2 호스트 *내부* (127.0.0.1) 에서
# is-active + HTTP probe 를 한다. 본 스크립트는 그 바깥 — Route53 FQDN + TLS +
# nginx 라우팅까지 통째로 검증하는 end-to-end gate 다.
#
# CD 워크플로우가 trigger-deploy 직후 호출. 하나라도 실패하면 exit 1 →
# 워크플로우 실패 → 운영자 즉시 인지. (호스트 내부 자동 롤백과 별개의 2차 그물.)
#
# 사용법:
#   scripts/post-deploy-smoke.sh --root-domain example.com [--env prod] \
#     [--mode fqdn|alb] [--retries 10] [--interval 6] [--service all]
#
# --mode fqdn (기본): https://api.<root-domain>/health — Route53 + TLS 전체 검증.
# --mode alb:        http://<alb-dns>/health  — 도메인 미구매/DNS 미연결 시 fallback.
#                    TLS 없이 ALB 헬스만 확인. HTTP 301 redirect 체크는 생략.
#
# Exit codes: 0 전부 통과 / 1 하나라도 실패 / 2 사용법 오류
###############################################################################
set -euo pipefail

ROOT_DOMAIN=""
ENV="prod"
MODE="fqdn"
RETRIES=10
INTERVAL=6
SERVICE="all"

while [ $# -gt 0 ]; do
  case "$1" in
    --root-domain) ROOT_DOMAIN="$2"; shift 2 ;;
    --env)         ENV="$2"; shift 2 ;;
    --mode)        MODE="$2"; shift 2 ;;
    --retries)     RETRIES="$2"; shift 2 ;;
    --interval)    INTERVAL="$2"; shift 2 ;;
    --service)     SERVICE="$2"; shift 2 ;;
    -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERR: unknown arg $1" >&2; exit 2 ;;
  esac
done

[ -n "$ROOT_DOMAIN" ] || { echo "ERR: --root-domain 필요" >&2; exit 2; }

# ALB 모드: 도메인 기반 서브도메인 대신 ALB DNS 직접 + HTTP (TLS 없음).
# 서버는 포트 8080, AI 는 8081, Admin 은 8082 에서 응답.
# nginx 가 뒤에 있으면 80 번 헬스는 그대로 proxy 됨.
if [ "$MODE" = "alb" ]; then
  API="${ROOT_DOMAIN}"
  AI="${ROOT_DOMAIN}"
  ADMIN="${ROOT_DOMAIN}"
  ALB_SCHEME="http"
  SERVER_PORT=":8080"
  AI_PORT=":8081"
  ADMIN_PORT=":8082"
elif [ "$ENV" = "prod" ]; then
  # prod 가 아니면 서브도메인에 env prefix (route53.tf 의 명명 규칙과 일치).
  API="api.${ROOT_DOMAIN}"; AI="ai.${ROOT_DOMAIN}"; ADMIN="admin.${ROOT_DOMAIN}"
  ALB_SCHEME="https"
  SERVER_PORT=""; AI_PORT=""; ADMIN_PORT=""
else
  API="${ENV}-api.${ROOT_DOMAIN}"; AI="${ENV}-ai.${ROOT_DOMAIN}"; ADMIN="${ENV}-admin.${ROOT_DOMAIN}"
  ALB_SCHEME="https"
  SERVER_PORT=""; AI_PORT=""; ADMIN_PORT=""
fi

log()  { printf '[smoke %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
FAIL=0

# 한 엔드포인트를 RETRIES 회 재시도. 2xx/3xx 면 OK.
probe() {
  local name="$1" url="$2" expect="${3:-200}" i code
  for i in $(seq 1 "$RETRIES"); do
    code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null || echo 000)"
    if [ "$code" = "$expect" ] || { [ "$expect" = "2xx" ] && [ "${code:0:1}" = "2" ]; }; then
      log "OK   ${name} ${url} -> ${code}"
      return 0
    fi
    log "wait ${name} ${url} -> ${code} (시도 ${i}/${RETRIES})"
    sleep "$INTERVAL"
  done
  log "FAIL ${name} ${url} -> 마지막 코드 ${code}"
  FAIL=1
  return 1
}

log "대상 env=${ENV} root=${ROOT_DOMAIN} mode=${MODE} service=${SERVICE}"

# server: deep health (RDS / EFS / 외부 의존성까지 확인하는 경로).
if [ "$SERVICE" = "all" ] || [ "$SERVICE" = "server" ]; then
  probe "server-health"      "${ALB_SCHEME}://${API}${SERVER_PORT}/health"       200 || true
  probe "server-deep-health" "${ALB_SCHEME}://${API}${SERVER_PORT}/health?deep=1" 200 || true
fi
# ai: health.
if [ "$SERVICE" = "all" ] || [ "$SERVICE" = "ai" ]; then
  probe "ai-health" "${ALB_SCHEME}://${AI}${AI_PORT}/health" 200 || true
fi
# admin: Next.js root (로그인 페이지). 인증 리다이렉트 가능 → 2xx 만 요구.
if [ "$SERVICE" = "all" ] || [ "$SERVICE" = "admin" ]; then
  probe "admin-root" "${ALB_SCHEME}://${ADMIN}${ADMIN_PORT}/" 2xx || true
fi

# HTTP -> HTTPS 리다이렉트가 살아있는지 (nginx 80 블록 검증).
# ALB 직접 모드에서는 TLS 가 없으므로 redirect 체크 생략.
if [ "$MODE" != "alb" ]; then
  probe "http-redirect" "http://${API}/health" 301 || true
fi

if [ "$FAIL" -ne 0 ]; then
  log "스모크 테스트 실패 — 호스트 자동 롤백 로그 + CloudWatch ICONIA/Deploy 확인 필요"
  exit 1
fi
log "스모크 테스트 전부 통과"
exit 0
