#!/usr/bin/env bash
###############################################################################
# ec2-pull-and-restart.sh - EC2 호스트에서 실행.
#
# 호출 방식:
#   1) user-data.sh 최초 부팅 시
#   2) SSM Run Command (trigger-deploy.ps1 가 발사)
#   3) 운영자가 SSM Session Manager 로 들어와 수동 실행
#
# 사용법:
#   /usr/local/bin/iconia-pull-and-restart.sh server         # server 만
#   /usr/local/bin/iconia-pull-and-restart.sh ai             # ai 만
#   /usr/local/bin/iconia-pull-and-restart.sh admin          # admin 만
#   /usr/local/bin/iconia-pull-and-restart.sh all            # 전부
#   /usr/local/bin/iconia-pull-and-restart.sh _bootstrap     # nginx/systemd 설정만 (서비스 재시작 없음)
#
# 환경: /etc/iconia.env (user-data.sh 가 생성. ARTIFACTS_BUCKET, AWS_REGION 등).
#
# 동작:
#   - s3://<artifacts>/<svc>/latest.tar.gz 를 받아 /opt/iconia/<svc> 에 풀고
#     systemctl restart iconia-<svc>.
#   - _bootstrap 은 s3://<artifacts>/_bootstrap/deploy.tar.gz 를 받아 nginx/systemd
#     설정만 갱신 (다른 svc 들의 코드는 건드리지 않음).
###############################################################################
set -euo pipefail

ENV_FILE=/etc/iconia.env
[ -f "$ENV_FILE" ] || { echo "ERR: $ENV_FILE 없음"; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"

: "${ARTIFACTS_BUCKET:?ARTIFACTS_BUCKET 미설정}"
: "${AWS_REGION:?AWS_REGION 미설정}"

SERVICE="${1:-all}"
TS=$(date -u +%Y%m%dT%H%M%SZ)
TMP=$(mktemp -d -t iconia-deploy.XXXX)
trap 'rm -rf "$TMP"' EXIT

log()  { printf '[iconia-deploy %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
fail() { log "ERR: $*"; exit 1; }

pull_one() {
  local svc="$1"
  local key="${svc}/latest.tar.gz"
  local dst="/opt/iconia/${svc}"
  local tar="${TMP}/${svc}.tar.gz"

  log "${svc} <- s3://${ARTIFACTS_BUCKET}/${key}"
  aws s3 cp "s3://${ARTIFACTS_BUCKET}/${key}" "$tar" --region "$AWS_REGION" \
    || fail "${svc} tarball 다운로드 실패"

  # 원자 교체. 풀어둔 폴더를 한 번에 swap.
  local stage="${TMP}/${svc}.stage"
  mkdir -p "$stage"
  tar -xzf "$tar" -C "$stage"

  # 권한 정리.
  chown -R iconia:iconia "$stage"

  if [ -d "${dst}" ]; then
    mv "${dst}" "${dst}.old.${TS}"
  fi
  mv "$stage" "$dst"

  # 의존성 설치 (npm ci - lockfile 정확 매칭).
  if [ -f "${dst}/package-lock.json" ]; then
    log "${svc} npm ci (production only)"
    (cd "$dst" && sudo -u iconia npm ci --omit=dev)
  fi

  # 오래된 백업 cleanup (최근 3개만 유지).
  ls -1dt "${dst}.old."* 2>/dev/null | tail -n +4 | xargs -r rm -rf

  # Prisma migrate deploy - server svc 한정. ai/admin 은 prisma 호출 불필요.
  # /etc/iconia.server.env 에 DATABASE_URL 이 채워져 있어야 함 (_bootstrap 단계에서 주입).
  if [ "$svc" = "server" ] && [ -f "${dst}/prisma/schema.prisma" ]; then
    if [ -f /etc/iconia.server.env ]; then
      log "server prisma migrate deploy"
      # set -a 로 export, 실행 후 set +a 로 해제. DATABASE_URL 누락이면 prisma 가 즉시 실패.
      (
        set -a
        # shellcheck disable=SC1091
        . /etc/iconia.server.env
        set +a
        cd "$dst"
        sudo -u iconia -E npx --yes prisma migrate deploy
      ) || fail "server prisma migrate deploy 실패 (DATABASE_URL 또는 마이그레이션 점검)"
    else
      log "WARN: /etc/iconia.server.env 없음 → prisma migrate deploy 건너뜀"
    fi
  fi

  log "${svc} restart"
  systemctl restart "iconia-${svc}"
}

pull_bootstrap() {
  local key="_bootstrap/deploy.tar.gz"
  local tar="${TMP}/bootstrap.tar.gz"
  local stage="${TMP}/bootstrap.stage"

  log "_bootstrap <- s3://${ARTIFACTS_BUCKET}/${key}"
  aws s3 cp "s3://${ARTIFACTS_BUCKET}/${key}" "$tar" --region "$AWS_REGION" \
    || fail "_bootstrap tarball 다운로드 실패"

  mkdir -p "$stage"
  tar -xzf "$tar" -C "$stage"

  # 이 tarball 의 구조 (build-and-upload.ps1 의 _bootstrap 단계 산출물):
  #   deploy/systemd/iconia-server.service
  #   deploy/systemd/iconia-ai.service
  #   deploy/systemd/iconia-admin.service
  #   deploy/nginx/iconia.conf                   (원본 - ${ROOT_DOMAIN} placeholder 포함)
  #   deploy/nginx/snippets/iconia-proxy.conf
  #   scripts/ec2-pull-and-restart.sh
  install -m 0755 "$stage/scripts/ec2-pull-and-restart.sh" /usr/local/bin/iconia-pull-and-restart.sh

  for unit in iconia-server iconia-ai iconia-admin; do
    src="$stage/deploy/systemd/${unit}.service"
    if [ -f "$src" ]; then
      install -m 0644 "$src" "/etc/systemd/system/${unit}.service"
    fi
  done
  systemctl daemon-reload

  # nginx snippet.
  mkdir -p /etc/nginx/snippets
  if [ -f "$stage/deploy/nginx/snippets/iconia-proxy.conf" ]; then
    install -m 0644 "$stage/deploy/nginx/snippets/iconia-proxy.conf" /etc/nginx/snippets/iconia-proxy.conf
  fi

  # nginx 메인 conf - ${ROOT_DOMAIN} 치환.
  if [ -f "$stage/deploy/nginx/iconia.conf" ]; then
    : "${ROOT_DOMAIN:?ROOT_DOMAIN 미설정 (/etc/iconia.env 에 ROOT_DOMAIN 추가 필요)}"
    sed "s/\${ROOT_DOMAIN}/${ROOT_DOMAIN}/g" "$stage/deploy/nginx/iconia.conf" > /etc/nginx/conf.d/iconia.conf
    chmod 0644 /etc/nginx/conf.d/iconia.conf
    if nginx -t; then
      systemctl reload nginx
    else
      log "WARN: nginx -t 실패 - 설정 점검 필요. 이전 conf 유지를 위해 rollback 권장."
    fi
  fi

  log "_bootstrap 완료"
}

case "$SERVICE" in
  server|ai|admin) pull_one "$SERVICE" ;;
  all)
    pull_bootstrap
    pull_one server
    pull_one ai
    pull_one admin
    ;;
  _bootstrap) pull_bootstrap ;;
  *) fail "unknown service: $SERVICE (server|ai|admin|all|_bootstrap)" ;;
esac

log "done"
