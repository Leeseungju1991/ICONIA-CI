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
#     [--retries 10] [--interval 6] [--service all]
#
# Exit codes: 0 전부 통과 / 1 하나라도 실패 / 2 사용법 오류
###############################################################################
set -euo pipefail

ROOT_DOMAIN=""
ENV="prod"
RETRIES=10
INTERVAL=6
SERVICE="all"

while [ $# -gt 0 ]; do
  case "$1" in
    --root-domain) ROOT_DOMAIN="$2"; shift 2 ;;
    --env)         ENV="$2"; shift 2 ;;
    --retries)     RETRIES="$2"; shift 2 ;;
    --interval)    INTERVAL="$2"; shift 2 ;;
    --service)     SERVICE="$2"; shift 2 ;;
    -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERR: unknown arg $1" >&2; exit 2 ;;
  esac
done

[ -n "$ROOT_DOMAIN" ] || { echo "ERR: --root-domain 필요" >&2; exit 2; }

# prod 가 아니면 서브도메인에 env prefix (route53.tf 의 명명 규칙과 일치).
if [ "$ENV" = "prod" ]; then
  API="api.${ROOT_DOMAIN}"; AI="ai.${ROOT_DOMAIN}"; ADMIN="admin.${ROOT_DOMAIN}"
else
  API="${ENV}-api.${ROOT_DOMAIN}"; AI="${ENV}-ai.${ROOT_DOMAIN}"; ADMIN="${ENV}-admin.${ROOT_DOMAIN}"
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

log "대상 env=${ENV} root=${ROOT_DOMAIN} service=${SERVICE}"

# server: deep health (RDS / EFS / 외부 의존성까지 확인하는 경로).
if [ "$SERVICE" = "all" ] || [ "$SERVICE" = "server" ]; then
  probe "server-health"      "https://${API}/health"          200 || true
  probe "server-deep-health" "https://${API}/health?deep=1"    200 || true
fi
# ai: health.
if [ "$SERVICE" = "all" ] || [ "$SERVICE" = "ai" ]; then
  probe "ai-health" "https://${AI}/health" 200 || true
fi
# admin: Next.js root (로그인 페이지). 인증 리다이렉트 가능 → 2xx 만 요구.
if [ "$SERVICE" = "all" ] || [ "$SERVICE" = "admin" ]; then
  probe "admin-root" "https://${ADMIN}/" 2xx || true
fi

# HTTP -> HTTPS 리다이렉트가 살아있는지 (nginx 80 블록 검증).
probe "http-redirect" "http://${API}/health" 301 || true

if [ "$FAIL" -ne 0 ]; then
  log "스모크 테스트 실패 — 호스트 자동 롤백 로그 + CloudWatch ICONIA/Deploy 확인 필요"
  exit 1
fi
log "스모크 테스트 전부 통과"
exit 0
