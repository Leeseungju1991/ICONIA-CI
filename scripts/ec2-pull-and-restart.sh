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

###############################################################################
# DB credential 주입.
#
# Secrets Manager 의 iconia/${ICONIA_ENV}/db/master_password
# (seed-db-password.ps1 가 생성. JSON { username, password }) 에서 password 만
# 꺼내 /etc/iconia.server.env, /etc/iconia.ai.env 에 DATABASE_URL / RDS_PASSWORD
# 라인을 멱등하게 작성. 실패 시 fatal (부팅 무한루프 방지).
#
# 호출 시점: pull_bootstrap 의 첫 단계. 서비스 코드 풀 전에 secret 이 정합해야
# server 가 prisma migrate deploy 를 돌릴 수 있다.
###############################################################################
inject_database_url() {
  : "${ICONIA_ENV:?ICONIA_ENV 미설정 (/etc/iconia.env)}"
  : "${RDS_ENDPOINT:?RDS_ENDPOINT 미설정 (/etc/iconia.env)}"
  : "${RDS_PORT:?RDS_PORT 미설정 (/etc/iconia.env)}"
  : "${RDS_DATABASE:?RDS_DATABASE 미설정 (/etc/iconia.env)}"
  : "${RDS_USERNAME:?RDS_USERNAME 미설정 (/etc/iconia.env)}"

  local secret_id="iconia/${ICONIA_ENV}/db/master_password"
  log "secrets: fetch ${secret_id}"
  local secret_json
  secret_json=$(aws secretsmanager get-secret-value \
    --secret-id "${secret_id}" --region "${AWS_REGION}" \
    --query SecretString --output text 2>/dev/null) \
    || fail "Secrets Manager ${secret_id} 조회 실패 - IAM 정책/시크릿 존재 여부 점검"

  local pwd
  pwd=$(printf '%s' "$secret_json" | jq -er .password) \
    || fail "Secret ${secret_id} 의 .password 필드 누락 또는 JSON 파싱 실패"

  # PostgreSQL connection URL — RDS 의 sslmode=require (rds.tf 의 storage_encrypted 와 별개로
  # 전송 구간 TLS). 비밀번호는 URL 인코딩 필요한 특수문자가 있을 수 있으므로 인코딩.
  local enc_pwd
  enc_pwd=$(jq -rn --arg p "$pwd" '$p | @uri')
  # Endpoint 가 "host:port" 형태로 끝나는 경우(RDS instance) 대비, port 분리.
  local host="${RDS_ENDPOINT%%:*}"
  local url="postgresql://${RDS_USERNAME}:${enc_pwd}@${host}:${RDS_PORT}/${RDS_DATABASE}?sslmode=require"

  for envf in /etc/iconia.server.env /etc/iconia.ai.env; do
    # 기존 파일 보존 + 두 키만 멱등 갱신.
    touch "$envf"
    # DATABASE_URL/RDS_PASSWORD 라인 제거 후 재기입.
    sed -i '/^DATABASE_URL=/d;/^RDS_PASSWORD=/d' "$envf"
    {
      printf 'DATABASE_URL=%s\n' "$url"
      printf 'RDS_PASSWORD=%s\n' "$pwd"
    } >> "$envf"
    chown root:iconia "$envf"
    chmod 0640 "$envf"
  done
  log "secrets: DATABASE_URL/RDS_PASSWORD injected -> /etc/iconia.{server,ai}.env"
}

pull_bootstrap() {
  local key="_bootstrap/deploy.tar.gz"
  local tar="${TMP}/bootstrap.tar.gz"
  local stage="${TMP}/bootstrap.stage"

  # 1) DB credential 주입 - 서비스 코드 pull 전에 먼저 환경파일을 갖춰둔다.
  inject_database_url

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

  # nginx 메인 conf - ${ROOT_DOMAIN} 치환 + 인증서 존재 시에만 TLS server 블록 활성.
  if [ -f "$stage/deploy/nginx/iconia.conf" ]; then
    : "${ROOT_DOMAIN:?ROOT_DOMAIN 미설정 (/etc/iconia.env 에 ROOT_DOMAIN 추가 필요)}"

    local rendered="/etc/nginx/conf.d/iconia.conf"
    sed "s/\${ROOT_DOMAIN}/${ROOT_DOMAIN}/g" "$stage/deploy/nginx/iconia.conf" > "$rendered"
    chmod 0644 "$rendered"

    # certbot 이 아직 인증서를 발급하지 못한 상태에서 reload 하면
    # `cannot load certificate /etc/letsencrypt/...` 로 nginx 가 침묵 실패한다.
    # 그러면 80 도 같이 죽어서 certbot http-01 challenge 도 못 통과하는
    # 데드락 발생. 인증서 부재 시 TLS server 블록 전체를 주석으로 마킹해 둔다.
    # certbot --nginx 가 발급 성공 시 자기 자신이 인증서 경로를 쓰는 conf 를
    # 재작성하므로, 다음 _bootstrap pull 때 sed 가 다시 정리한다.
    if [ ! -f "/etc/letsencrypt/live/api.${ROOT_DOMAIN}/fullchain.pem" ]; then
      log "WARN: api.${ROOT_DOMAIN} TLS cert 부재 - iconia.conf 의 443 server 블록을 임시 비활성"
      # `listen 443 ssl` 로 시작하는 server 블록을 모두 주석 처리.
      # 단순 접근: ssl_certificate 줄을 #로 prefix → nginx -t 가 cert 못 찾으면 죽으므로
      # 차라리 listen 443 서버 블록 전체를 비활성화. awk 로 블록 구분.
      awk '
        BEGIN { depth=0; tls_block=0; buf="" }
        /^server[[:space:]]*\{/ { in_server=1; depth=1; buf=$0 "\n"; tls_block=0; next }
        in_server {
          buf = buf $0 "\n"
          n = gsub(/\{/, "{")
          m = gsub(/\}/, "}")
          depth += n - m
          if ($0 ~ /listen[[:space:]]+(\[::\]:)?443[[:space:]]+ssl/) tls_block=1
          if (depth == 0) {
            if (tls_block) {
              # 블록 전체에 # prefix.
              n_lines = split(buf, lines, "\n")
              for (i=1; i<=n_lines; i++) {
                if (lines[i] == "" && i == n_lines) continue
                print "# (tls-disabled) " lines[i]
              }
            } else {
              printf "%s", buf
            }
            in_server=0; buf=""
          }
          next
        }
        { print }
      ' "$rendered" > "${rendered}.tmp" && mv "${rendered}.tmp" "$rendered"
      chmod 0644 "$rendered"
    fi

    if nginx -t; then
      systemctl reload nginx
    else
      log "ERR: nginx -t 실패 - 설정 점검 필요. 이전 conf 로의 rollback 권장."
      # nginx 가 죽지 않도록 깨진 conf 를 비활성화.
      mv "$rendered" "${rendered}.broken.${TS}"
      systemctl reload nginx || true
      fail "nginx -t 실패 - ${rendered}.broken.${TS} 보존"
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
