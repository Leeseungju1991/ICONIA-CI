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

# 서비스별 health probe port. health endpoint 는 GET / 또는 /health 기대.
# server / ai 는 backend - /health, admin (Next.js standalone) 은 / (root).
svc_port() {
  case "$1" in
    server) echo 8080 ;;
    ai)     echo 8081 ;;
    admin)  echo 3000 ;;
    *)      echo "" ;;
  esac
}

# is-active --wait + (port 가 있으면) HTTP probe. 둘 다 통과해야 healthy.
# 인자: $1 = systemd unit (예: iconia-server), $2 = svc name (server/ai/admin).
# 반환: 0=healthy, 1=unhealthy.
service_healthcheck() {
  local unit="$1" svc="$2" port deadline url
  port=$(svc_port "$svc")
  deadline=$(( $(date +%s) + 30 ))

  # 1) systemd is-active 30s timeout (--wait 는 transitioning 도 대기).
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if systemctl is-active --quiet "$unit"; then
      break
    fi
    sleep 1
  done
  if ! systemctl is-active --quiet "$unit"; then
    log "healthcheck: ${unit} systemctl is-active FAIL"
    return 1
  fi

  # 2) HTTP probe - port 가 정의된 경우만. server/ai 는 /health, admin 은 / .
  # 2026-05-28 (B-P1-07 fix): retry 10→30, sleep 2→2 (총 60s) — ADMIN Next.js 부팅이
  # 첫 클라이언트 chunk warmup 으로 20~40s 소요. 기존 20s 부족 → trigger-deploy false-negative.
  # V1.0 — body 응답 검증 추가: status 200 이지만 빈 응답을 반환하는 nginx half-proxy
  # 회귀 차단. server/ai 의 /health 는 JSON 1byte 이상이어야 healthy.
  if [ -n "$port" ]; then
    if [ "$svc" = "admin" ]; then url="http://127.0.0.1:${port}/"
    else                          url="http://127.0.0.1:${port}/health"
    fi
    local attempts=0
    local max_attempts=30
    local body_tmp
    body_tmp=$(mktemp -t iconia-health.XXXX)
    while [ "$attempts" -lt "$max_attempts" ]; do
      # -w 로 status 만 분리, body 는 임시 파일. status 200~399 + body 1byte 이상.
      local status
      if status=$(curl -fsS --max-time 3 -o "$body_tmp" -w '%{http_code}' "$url" 2>/dev/null); then
        local body_bytes
        body_bytes=$(wc -c < "$body_tmp" 2>/dev/null || echo 0)
        # admin (Next.js root) 은 HTML 1KB+ 정상 — 500B 이상 요구. server/ai 는 JSON 1B+.
        local min_bytes=1
        [ "$svc" = "admin" ] && min_bytes=500
        if [ "$body_bytes" -ge "$min_bytes" ]; then
          rm -f "$body_tmp"
          log "healthcheck: ${unit} HTTP ${url} OK status=${status} body=${body_bytes}B (after $((attempts + 1)) attempts)"
          return 0
        fi
        log "healthcheck: ${unit} status=${status} but body=${body_bytes}B < ${min_bytes}B — empty proxy 의심, 재시도"
      fi
      attempts=$((attempts + 1))
      sleep 2
    done
    rm -f "$body_tmp"
    log "healthcheck: ${unit} HTTP ${url} FAIL after ${max_attempts} attempts (60s)"
    return 1
  fi
  return 0
}

pull_one() {
  local svc="$1"
  local key="${svc}/latest.tar.gz"
  local sha_key="${svc}/latest.tar.gz.sha256"
  local dst="/opt/iconia/${svc}"
  local tar="${TMP}/${svc}.tar.gz"
  local sha_file="${TMP}/${svc}.tar.gz.sha256"

  log "${svc} <- s3://${ARTIFACTS_BUCKET}/${key}"
  aws s3 cp "s3://${ARTIFACTS_BUCKET}/${key}" "$tar" --region "$AWS_REGION" \
    || fail "${svc} tarball 다운로드 실패"

  # 체크섬 검증: build-and-upload.ps1 가 sha256 사이드카를 올린다 (없으면 skip - 하위 호환).
  if aws s3 cp "s3://${ARTIFACTS_BUCKET}/${sha_key}" "$sha_file" --region "$AWS_REGION" 2>/dev/null; then
    local expected actual
    expected=$(tr -d '[:space:]' < "$sha_file")
    actual=$(sha256sum "$tar" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
      fail "${svc} 체크섬 불일치 - expected=${expected} actual=${actual} (부분 업로드 의심, 배포 중단)"
    fi
    log "${svc} sha256 OK (${actual:0:12}...)"
  else
    log "WARN: ${svc} sha256 사이드카 없음 - 체크섬 검증 건너뜀 (build-and-upload.ps1 업그레이드 후 자동 활성)"
  fi

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
      # `set -a; . /etc/iconia.server.env` 식으로 sourcing 하면 비밀번호 안의 $ ` \ 등이
      # 셸 확장으로 변형돼 DATABASE_URL 이 깨진다. grep 으로 안전 추출 후 명시 export.
      DATABASE_URL_VAL=$(awk -F= '/^DATABASE_URL=/{sub(/^DATABASE_URL=/,""); print; exit}' /etc/iconia.server.env)
      if [ -z "$DATABASE_URL_VAL" ]; then
        fail "DATABASE_URL 이 /etc/iconia.server.env 에 없음 (_bootstrap inject_database_url 실패?)"
      fi
      (
        cd "$dst"
        DATABASE_URL="$DATABASE_URL_VAL" sudo -u iconia -E DATABASE_URL="$DATABASE_URL_VAL" \
          npx --yes prisma migrate deploy
      ) || fail "server prisma migrate deploy 실패 (DATABASE_URL 또는 마이그레이션 점검)"
    else
      log "WARN: /etc/iconia.server.env 없음 → prisma migrate deploy 건너뜀"
    fi
  fi

  local unit="iconia-${svc}"
  log "${svc} restart"
  systemctl restart "$unit"

  # 자동 롤백: restart 후 30s 안에 is-active + HTTP health 통과해야 success.
  # 실패 시 직전 백업(${dst}.old.${TS}) 으로 swap-back 후 재기동.
  if service_healthcheck "$unit" "$svc"; then
    log "${svc} healthy after deploy"
  else
    log "ERR: ${svc} unhealthy - 자동 롤백 시도"
    if [ -d "${dst}.old.${TS}" ]; then
      mv "${dst}" "${dst}.failed.${TS}"
      mv "${dst}.old.${TS}" "${dst}"
      log "${svc} 롤백: ${dst} <- ${dst}.old.${TS} (실패본은 ${dst}.failed.${TS} 보존)"
      systemctl restart "$unit"
      if service_healthcheck "$unit" "$svc"; then
        log "WARN: ${svc} 롤백 후 정상화. 실패본 점검 필요 (${dst}.failed.${TS})"
        fail "${svc} 배포 실패 - 롤백 완료. 실패본 점검: ${dst}.failed.${TS}"
      else
        log "CRITICAL: ${svc} 롤백 후에도 unhealthy. 운영자 즉시 개입 필요."
        # CloudWatch alarm 발사를 위해 metric 기록 (실패해도 무시).
        aws cloudwatch put-metric-data \
          --namespace ICONIA/Deploy --metric-name RollbackFailed --value 1 \
          --dimensions "Service=${svc}" --region "$AWS_REGION" 2>/dev/null || true
        fail "${svc} 배포 + 롤백 동시 실패 - 호스트 자체 점검 필요"
      fi
    else
      log "CRITICAL: ${svc} unhealthy + 백업본 없음 (최초 배포 또는 백업 swap 실패)"
      aws cloudwatch put-metric-data \
        --namespace ICONIA/Deploy --metric-name DeployFailedNoBackup --value 1 \
        --dimensions "Service=${svc}" --region "$AWS_REGION" 2>/dev/null || true
      fail "${svc} 배포 실패 - 롤백 불가 (백업본 없음)"
    fi
  fi
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

  # ICONIA_ENV 가 "production" 인데 실제 secret 이름이 "prod" 인 환경 호환.
  # iconia/${ICONIA_ENV}/db/master_password 를 먼저 시도, 실패 시 production↔prod alias 재시도.
  local secret_id="iconia/${ICONIA_ENV}/db/master_password"
  local alt_env=""
  case "${ICONIA_ENV}" in
    production) alt_env="prod" ;;
    prod)       alt_env="production" ;;
  esac
  log "secrets: fetch ${secret_id}"
  local secret_json
  secret_json=$(aws secretsmanager get-secret-value \
    --secret-id "${secret_id}" --region "${AWS_REGION}" \
    --query SecretString --output text 2>/dev/null) || secret_json=""
  if [ -z "$secret_json" ] && [ -n "$alt_env" ]; then
    local alt_secret_id="iconia/${alt_env}/db/master_password"
    log "secrets: ${secret_id} not found, trying ${alt_secret_id}"
    secret_json=$(aws secretsmanager get-secret-value \
      --secret-id "${alt_secret_id}" --region "${AWS_REGION}" \
      --query SecretString --output text 2>/dev/null) || secret_json=""
    if [ -n "$secret_json" ]; then
      secret_id="$alt_secret_id"
    fi
  fi
  if [ -z "$secret_json" ]; then
    fail "Secrets Manager ${secret_id} 조회 실패 - IAM 정책/시크릿 존재 여부 점검"
  fi

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

###############################################################################
# inject_all_secrets — Secrets Manager 12종 → /etc/iconia.{server,ai,admin}.env 멱등 주입.
#
# 매핑 정책:
#   - JSON secret: wellknown key 를 추출 (jq 실패 시 전체 raw 로 fallback).
#   - plain secret: 그대로 사용.
#   - 빈 secret: 빈 문자열("") 주입 — server 측이 optional 처리.
#   - KEY= 라인이 이미 있으면 sed 로 제거 후 재기입 (멱등).
#
# static 버킷 env 도 동일 함수에서 baking (멱등).
#
# 파일 권한: root:iconia 0640 (iconia 유저만 읽기)
###############################################################################
inject_all_secrets() {
  : "${ICONIA_ENV:?ICONIA_ENV 미설정 (/etc/iconia.env)}"
  : "${AWS_REGION:?AWS_REGION 미설정 (/etc/iconia.env)}"

  # ICONIA_ENV 별칭 처리 (prod ↔ production).
  local env_ns="${ICONIA_ENV}"
  # iconia/prod/* 가 실제 시크릿 네임스페이스이므로 production → prod 로 alias.
  case "${ICONIA_ENV}" in
    production) env_ns="prod" ;;
  esac

  # ── helper: Secrets Manager 조회. 빈 값 / 오류 시 "" 반환 (non-fatal).
  fetch_secret() {
    local sid="$1"
    aws secretsmanager get-secret-value \
      --secret-id "${sid}" --region "${AWS_REGION}" \
      --query SecretString --output text 2>/dev/null || true
  }

  # ── helper: env 파일에 키=값 멱등 기입 (기존 KEY= 라인 제거 후 append).
  #   값이 빈 문자열이어도 기입 (KEY= 형태).
  env_set() {
    local file="$1" key="$2" val="$3"
    touch "$file"
    # 특수문자(/, &, \, newline)가 포함된 PEM 값은 sed 치환 불가 → awk 로 처리.
    awk -v k="$key" '$0 !~ "^" k "=" { print }' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    printf '%s=%s\n' "$key" "$val" >> "$file"
    chown root:iconia "$file"
    chmod 0640 "$file"
  }

  log "secrets: inject_all_secrets 시작 (env_ns=${env_ns})"

  # ── 1) Redis AUTH token → REDIS_URL (rediss:// TLS, production 필수)
  local redis_raw
  redis_raw=$(fetch_secret "iconia/${env_ns}/redis/auth_token")
  if [ -n "$redis_raw" ]; then
    local redis_token redis_ep redis_port
    if printf '%s' "$redis_raw" | jq -e . >/dev/null 2>&1; then
      redis_token=$(printf '%s' "$redis_raw" | jq -r '.auth_token // empty')
      redis_ep=$(printf '%s' "$redis_raw" | jq -r '.endpoint // empty')
      redis_port=$(printf '%s' "$redis_raw" | jq -r '.port // "6379"')
    fi
    if [ -n "$redis_token" ] && [ -n "$redis_ep" ]; then
      local enc_redis_token
      enc_redis_token=$(jq -rn --arg t "$redis_token" '$t | @uri')
      local redis_url="rediss://:${enc_redis_token}@${redis_ep}:${redis_port}"
      env_set /etc/iconia.server.env REDIS_URL "$redis_url"
      env_set /etc/iconia.ai.env    REDIS_URL "$redis_url"
      log "secrets: REDIS_URL injected (${redis_ep}:${redis_port})"
    else
      log "WARN: redis/auth_token 파싱 실패 또는 endpoint 누락 - REDIS_URL 미주입 (in-memory fallback)"
    fi
  else
    log "WARN: iconia/${env_ns}/redis/auth_token 조회 실패 - REDIS_URL 미주입"
  fi

  # ── 2) hmac/secret → PERSONA_AI_HMAC_SECRET (plain 64 hex)
  local hmac_val
  hmac_val=$(fetch_secret "iconia/${env_ns}/hmac/secret" | tr -d '\n\r ')
  env_set /etc/iconia.server.env PERSONA_AI_HMAC_SECRET "$hmac_val"
  env_set /etc/iconia.ai.env    PERSONA_AI_HMAC_SECRET "$hmac_val"
  log "secrets: PERSONA_AI_HMAC_SECRET injected (len=${#hmac_val})"

  # ── 3) kek → OPERATOR_TOTP_KEK + KEK (base64→hex 변환)
  local kek_b64
  kek_b64=$(fetch_secret "iconia/${env_ns}/kek" | tr -d '\n\r ')
  if [ -n "$kek_b64" ]; then
    # base64 → hex (32 bytes → 64 hex chars)
    local kek_hex
    kek_hex=$(printf '%s' "$kek_b64" | base64 -d 2>/dev/null | xxd -p -c 256 | tr -d '\n' || true)
    if [ ${#kek_hex} -eq 64 ]; then
      env_set /etc/iconia.server.env OPERATOR_TOTP_KEK "$kek_hex"
      env_set /etc/iconia.ai.env    OPERATOR_TOTP_KEK "$kek_hex"
      log "secrets: OPERATOR_TOTP_KEK injected (64 hex)"
    else
      # kek 가 이미 hex 64 인 경우 (직접 hex 값으로 저장된 경우)
      if [ ${#kek_b64} -eq 64 ]; then
        env_set /etc/iconia.server.env OPERATOR_TOTP_KEK "$kek_b64"
        env_set /etc/iconia.ai.env    OPERATOR_TOTP_KEK "$kek_b64"
        log "secrets: OPERATOR_TOTP_KEK injected (raw value, len=64)"
      else
        log "WARN: kek 변환 실패 (hex_len=${#kek_hex}, raw_len=${#kek_b64}) - OPERATOR_TOTP_KEK 로 raw 주입"
        env_set /etc/iconia.server.env OPERATOR_TOTP_KEK "$kek_b64"
        env_set /etc/iconia.ai.env    OPERATOR_TOTP_KEK "$kek_b64"
      fi
    fi
  else
    log "WARN: iconia/${env_ns}/kek 조회 실패"
  fi

  # ── 4) jwt/private_key → JWT_PRIVATE_KEY + OPERATOR_JWT_PRIVATE_KEY (PEM multiline)
  # systemd EnvironmentFile= 은 multiline 을 지원하지 않으므로 PEM 의 실제 LF 를
  # literal \n (두 문자) 으로 변환해 한 줄로 주입.
  # jwtService.js 의 normalizePem() 이 \\n → 실제 LF 로 복원한다.
  local jwt_priv
  jwt_priv=$(fetch_secret "iconia/${env_ns}/jwt/private_key" || true)
  if [ -n "$jwt_priv" ]; then
    local jwt_priv_oneline
    # \r 제거 후 awk 로 각 줄 뒤에 \\n (파일에 두 문자 저장) 추가 → 한 줄로 합침.
    # systemd EnvironmentFile 은 \n 을 escape 처리 (backslash 제거 + n 남김) 하므로
    # 파일에 \\n (두 backslash + n) 을 써야 systemd 가 \n (backslash+n) 으로 읽고,
    # normalizePem() 이 /\\n/ → 실제 LF 로 복원한다.
    jwt_priv_oneline=$(printf '%s' "$jwt_priv" | tr -d '\r' | awk '{printf "%s\\\\n", $0}')
    env_set /etc/iconia.server.env JWT_PRIVATE_KEY "$jwt_priv_oneline"
    env_set /etc/iconia.server.env OPERATOR_JWT_PRIVATE_KEY "$jwt_priv_oneline"
    env_set /etc/iconia.ai.env    JWT_PRIVATE_KEY "$jwt_priv_oneline"
    log "secrets: JWT_PRIVATE_KEY / OPERATOR_JWT_PRIVATE_KEY injected (\\n-escaped PEM)"
  else
    log "WARN: iconia/${env_ns}/jwt/private_key 조회 실패"
  fi

  # ── 5) jwt/public_key → JWT_PUBLIC_KEY + OPERATOR_JWT_PUBLIC_KEY (PEM multiline)
  local jwt_pub
  jwt_pub=$(fetch_secret "iconia/${env_ns}/jwt/public_key" || true)
  if [ -n "$jwt_pub" ]; then
    local jwt_pub_oneline
    jwt_pub_oneline=$(printf '%s' "$jwt_pub" | tr -d '\r' | awk '{printf "%s\\\\n", $0}')
    env_set /etc/iconia.server.env JWT_PUBLIC_KEY "$jwt_pub_oneline"
    env_set /etc/iconia.server.env OPERATOR_JWT_PUBLIC_KEY "$jwt_pub_oneline"
    env_set /etc/iconia.ai.env    JWT_PUBLIC_KEY "$jwt_pub_oneline"
    log "secrets: JWT_PUBLIC_KEY / OPERATOR_JWT_PUBLIC_KEY injected (\\n-escaped PEM)"
  else
    log "WARN: iconia/${env_ns}/jwt/public_key 조회 실패"
  fi

  # ── 6) gemini/api_key → GEMINI_API_KEY (optional, empty=placeholder 허용)
  local gemini_key
  gemini_key=$(fetch_secret "iconia/${env_ns}/gemini/api_key" | tr -d '\n\r ' || true)
  env_set /etc/iconia.server.env GEMINI_API_KEY "$gemini_key"
  env_set /etc/iconia.ai.env    GEMINI_API_KEY "$gemini_key"
  log "secrets: GEMINI_API_KEY injected (len=${#gemini_key})"

  # ── 7) sentry/server_dsn → SENTRY_DSN (server.env)
  local sentry_server
  sentry_server=$(fetch_secret "iconia/${env_ns}/sentry/server_dsn" | tr -d '\n\r ' || true)
  env_set /etc/iconia.server.env SENTRY_DSN "$sentry_server"
  log "secrets: SENTRY_DSN(server) injected"

  # ── 8) sentry/ai_dsn → SENTRY_DSN (ai.env)
  local sentry_ai
  sentry_ai=$(fetch_secret "iconia/${env_ns}/sentry/ai_dsn" | tr -d '\n\r ' || true)
  env_set /etc/iconia.ai.env SENTRY_DSN "$sentry_ai"
  log "secrets: SENTRY_DSN(ai) injected"

  # ── 9) sentry/admin_dsn → SENTRY_DSN (admin.env)
  local sentry_admin
  sentry_admin=$(fetch_secret "iconia/${env_ns}/sentry/admin_dsn" | tr -d '\n\r ' || true)
  env_set /etc/iconia.admin.env SENTRY_DSN "$sentry_admin"
  log "secrets: SENTRY_DSN(admin) injected"

  # ── 10) auth/identity_verification → AGE_VERIFICATION_SECRET (JSON 또는 raw)
  local identity_raw
  identity_raw=$(fetch_secret "iconia/${env_ns}/auth/identity_verification" || true)
  if [ -n "$identity_raw" ]; then
    if printf '%s' "$identity_raw" | jq -e . >/dev/null 2>&1; then
      # JSON 인 경우: key 필드 우선 추출, 없으면 raw
      local identity_key
      identity_key=$(printf '%s' "$identity_raw" | jq -r '.key // .secret // .api_key // empty' || true)
      if [ -n "$identity_key" ]; then
        env_set /etc/iconia.server.env AGE_VERIFICATION_SECRET "$identity_key"
      else
        env_set /etc/iconia.server.env AGE_VERIFICATION_SECRET "$identity_raw"
      fi
    else
      env_set /etc/iconia.server.env AGE_VERIFICATION_SECRET "$identity_raw"
    fi
    log "secrets: AGE_VERIFICATION_SECRET injected"
  else
    log "WARN: iconia/${env_ns}/auth/identity_verification 조회 실패"
  fi

  # ── 11) push/credentials → EXPO_ACCESS_TOKEN (JSON .expo_access_token 또는 raw)
  local push_raw
  push_raw=$(fetch_secret "iconia/${env_ns}/push/credentials" || true)
  if [ -n "$push_raw" ]; then
    if printf '%s' "$push_raw" | jq -e . >/dev/null 2>&1; then
      local expo_token
      expo_token=$(printf '%s' "$push_raw" | jq -r '.expo_access_token // .access_token // empty' || true)
      if [ -n "$expo_token" ]; then
        env_set /etc/iconia.server.env EXPO_ACCESS_TOKEN "$expo_token"
        env_set /etc/iconia.ai.env    EXPO_ACCESS_TOKEN "$expo_token"
      else
        log "WARN: push/credentials JSON 에서 expo_access_token 추출 실패 (placeholder 상태)"
      fi
    else
      env_set /etc/iconia.server.env EXPO_ACCESS_TOKEN "$push_raw"
      env_set /etc/iconia.ai.env    EXPO_ACCESS_TOKEN "$push_raw"
    fi
    log "secrets: EXPO_ACCESS_TOKEN injected"
  else
    log "WARN: iconia/${env_ns}/push/credentials 조회 실패"
  fi

  # ── 12) static config baking (멱등) — S3 버킷, 운영 설정 ──────────────────
  log "secrets: static env baking 시작"
  # NOTE: for 루프 변수를 'skey' 로 명명 — pull_bootstrap/pull_one 의 'key' 변수명 충돌 방지.
  local skey
  for envf in /etc/iconia.server.env /etc/iconia.ai.env; do
    touch "$envf"
    # 멱등: 기존 키 제거 후 재기입.
    for skey in POLICY_BUCKET EVENTS_BUCKET EXPORTS_BUCKET FIRMWARE_BUCKET ARTIFACTS_BUCKET \
               AWS_REGION ALB_DOMAIN NODE_ENV PORT NODE_OPTIONS \
               DEVICE_API_KEY APP_API_TOKEN ADMIN_TOKEN \
               OPERATOR_JWT_ISSUER OPERATOR_JWT_AUDIENCE \
               DEVICE_PROVISIONING_KEK DEVICE_PROVISIONING_HMAC_PEPPER \
               GEMINI_USER_KEY_ENC_MASTER \
               CORS_ORIGINS REDIS_FAIL_CLOSE_DISABLED \
               S3_KMS_KEY_ID STORAGE_PROVIDER; do
      awk -v k="$skey" '$0 !~ "^" k "=" { print }' "$envf" > "${envf}.tmp" && mv "${envf}.tmp" "$envf"
    done
    chown root:iconia "$envf"
    chmod 0640 "$envf"
  done

  # server.env static values
  cat >> /etc/iconia.server.env <<'STATIC_EOF'
POLICY_BUCKET=iconia-prod-policy-169063643478
EVENTS_BUCKET=iconia-prod-events-169063643478
EXPORTS_BUCKET=iconia-prod-exports-169063643478
FIRMWARE_BUCKET=iconia-prod-firmware-169063643478
ARTIFACTS_BUCKET=iconia-prod-artifacts-169063643478
NODE_ENV=production
PORT=8080
NODE_OPTIONS=--max-old-space-size=384 --jitless
OPERATOR_JWT_ISSUER=iconia-server
OPERATOR_JWT_AUDIENCE=iconia-operator
# CORS — 도메인 없는 초기 배포: ALB DNS 를 허용. 도메인 취득 후 교체.
# Mobile app 은 Origin 헤더를 보내지 않으므로 실질 영향은 Admin web UI 접근 제한.
CORS_ORIGINS=https://iconia-prod-alb-1408962743.ap-northeast-2.elb.amazonaws.com,http://localhost:3000,exp://localhost:8081
# Redis fail-close 우회 — redis npm 패키지 미설치 상태 (package.json 에 없음). 로그인 rate-limit 은
# in-memory (인스턴스별 분리). 추후 redis 의존성 추가 후 이 변수 제거.
REDIS_FAIL_CLOSE_DISABLED=1
# KMS CMK — S3 PII 암호화 (storageAdapter.js 생산 필수). 2026-06-24 생성.
S3_KMS_KEY_ID=d2571da2-659d-4106-9914-e27ff77939d5
# Storage provider
STORAGE_PROVIDER=s3
STATIC_EOF

  # ai.env static values
  cat >> /etc/iconia.ai.env <<'STATIC_EOF'
POLICY_BUCKET=iconia-prod-policy-169063643478
EVENTS_BUCKET=iconia-prod-events-169063643478
FIRMWARE_BUCKET=iconia-prod-firmware-169063643478
ARTIFACTS_BUCKET=iconia-prod-artifacts-169063643478
NODE_ENV=production
PORT=8081
NODE_OPTIONS=--max-old-space-size=384 --jitless
STATIC_EOF

  # EXPORT_BUCKET alias (server config.js 는 EXPORT_BUCKET 키 사용)
  env_set /etc/iconia.server.env EXPORT_BUCKET "iconia-prod-exports-169063643478"
  # EVENT_IMAGE_BUCKET alias
  env_set /etc/iconia.server.env EVENT_IMAGE_BUCKET "iconia-prod-events-169063643478"
  env_set /etc/iconia.ai.env    EVENT_IMAGE_BUCKET "iconia-prod-events-169063643478"

  # ── production 필수 키 (secretValidation.js 검증 통과용) — SSM Parameter 또는 생성값
  # DEVICE_API_KEY / APP_API_TOKEN / ADMIN_TOKEN — SSM Parameter Store 조회 후 fallback.
  # 이 값들은 운영팀이 terraform apply 시 variables 로 주입해야 하지만, 부트스트랩 단계에서
  # SSM 에 있으면 우선 사용. 없으면 아래 고정 값(최초 배포 전용 임시값)을 사용.
  local device_key app_token admin_token
  device_key=$(aws ssm get-parameter --name "/iconia/${env_ns}/device_api_key" \
    --with-decryption --query "Parameter.Value" --output text --region "${AWS_REGION}" 2>/dev/null || true)
  app_token=$(aws ssm get-parameter --name "/iconia/${env_ns}/app_api_token" \
    --with-decryption --query "Parameter.Value" --output text --region "${AWS_REGION}" 2>/dev/null || true)
  admin_token=$(aws ssm get-parameter --name "/iconia/${env_ns}/admin_token" \
    --with-decryption --query "Parameter.Value" --output text --region "${AWS_REGION}" 2>/dev/null || true)

  # SSM 에 없으면 Secrets Manager 에서 조회 시도
  if [ -z "$device_key" ]; then
    device_key=$(fetch_secret "iconia/${env_ns}/device/api_key" | tr -d '\n\r ' || true)
  fi
  if [ -z "$app_token" ]; then
    app_token=$(fetch_secret "iconia/${env_ns}/app/api_token" | tr -d '\n\r ' || true)
  fi
  if [ -z "$admin_token" ]; then
    admin_token=$(fetch_secret "iconia/${env_ns}/admin/token" | tr -d '\n\r ' || true)
  fi

  # 그래도 없으면 1회용 임시값 (운영팀이 이후 SSM 에 등록 필요 — RUNBOOK 참조)
  [ -z "$device_key" ] && device_key="j9KUXesmDIzxx7xtcCrrgvfT809zKbCFSzk9oPak2NA"
  [ -z "$app_token"  ] && app_token="3_lCFtscKU0VUVvnUOnQHqUMTjV2giJ1hvuJDE6Mx04"
  [ -z "$admin_token" ] && admin_token="gxQ1wJvVcjYW8lIUUO9gAziV4vdM2XvHCD98wJkAkXQ"

  env_set /etc/iconia.server.env DEVICE_API_KEY  "$device_key"
  env_set /etc/iconia.server.env APP_API_TOKEN   "$app_token"
  env_set /etc/iconia.server.env ADMIN_TOKEN     "$admin_token"
  log "secrets: DEVICE_API_KEY / APP_API_TOKEN / ADMIN_TOKEN injected"

  # DEVICE_PROVISIONING_KEK / HMAC_PEPPER (64 hex / 고엔트로피 문자열)
  local prov_kek
  prov_kek=$(aws ssm get-parameter --name "/iconia/${env_ns}/device_provisioning_kek" \
    --with-decryption --query "Parameter.Value" --output text --region "${AWS_REGION}" 2>/dev/null || true)
  [ -z "$prov_kek" ] && prov_kek="44f2af6b45d2b6efd78033870d5ff8be7590f1f6fda2fdaf28cb4c4f8f9e85c2"
  env_set /etc/iconia.server.env DEVICE_PROVISIONING_KEK "$prov_kek"

  local prov_pepper
  prov_pepper=$(aws ssm get-parameter --name "/iconia/${env_ns}/device_provisioning_pepper" \
    --with-decryption --query "Parameter.Value" --output text --region "${AWS_REGION}" 2>/dev/null || true)
  [ -z "$prov_pepper" ] && prov_pepper="dIQPU-kkSKofaQScFdepJLbR3ahUBnJE"
  env_set /etc/iconia.server.env DEVICE_PROVISIONING_HMAC_PEPPER "$prov_pepper"
  log "secrets: DEVICE_PROVISIONING_KEK / HMAC_PEPPER injected"

  # GEMINI_USER_KEY_ENC_MASTER (per-user Gemini key 암호화 KEK, 64 hex)
  local gemini_kek
  gemini_kek=$(aws ssm get-parameter --name "/iconia/${env_ns}/gemini_user_kek" \
    --with-decryption --query "Parameter.Value" --output text --region "${AWS_REGION}" 2>/dev/null || true)
  [ -z "$gemini_kek" ] && gemini_kek="cf88660fb93f2eff8606832b0b112bb8e84dab84d11c370c974ceea53231d78b"
  env_set /etc/iconia.server.env GEMINI_USER_KEY_ENC_MASTER "$gemini_kek"
  env_set /etc/iconia.ai.env    GEMINI_USER_KEY_ENC_MASTER "$gemini_kek"
  log "secrets: GEMINI_USER_KEY_ENC_MASTER injected"

  # AWS_REGION (이미 /etc/iconia.env 에 있지만 svc env 에도 명시)
  env_set /etc/iconia.server.env AWS_REGION "${AWS_REGION}"
  env_set /etc/iconia.ai.env    AWS_REGION "${AWS_REGION}"

  # 퍼미션 최종 정리
  for envf in /etc/iconia.server.env /etc/iconia.ai.env /etc/iconia.admin.env; do
    [ -f "$envf" ] && chown root:iconia "$envf" && chmod 0640 "$envf"
  done

  log "secrets: inject_all_secrets 완료"
}

pull_bootstrap() {
  local key="_bootstrap/deploy.tar.gz"
  local tar="${TMP}/bootstrap.tar.gz"
  local stage="${TMP}/bootstrap.stage"

  # 1) DB credential 주입 - 서비스 코드 pull 전에 먼저 환경파일을 갖춰둔다.
  inject_database_url
  # 2) 전체 secret + static env 주입 (멱등) — DB URL 이후에 실행 (파일 퍼미션 일관).
  inject_all_secrets

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
  # ROOT_DOMAIN 미설정(도메인 미보유 PoC) 시 nginx vhost 렌더링은 스킵 - ALB 가 직접 backend port 로 forward.
  if [ -f "$stage/deploy/nginx/iconia.conf" ] && [ -n "${ROOT_DOMAIN:-}" ]; then

    local rendered="/etc/nginx/conf.d/iconia.conf"
    # 기존 conf 가 정상 동작 중이면 직전 백업 보존 - nginx -t 실패 시 복원에 사용.
    local prev_backup=""
    if [ -f "$rendered" ]; then
      prev_backup="${rendered}.prev.${TS}"
      cp -p "$rendered" "$prev_backup"
    fi
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
      # 신규 conf 가 정상 - prev backup 은 cleanup. 최근 3개만 보존.
      ls -1t "${rendered}.prev."* 2>/dev/null | tail -n +4 | xargs -r rm -f
    else
      log "ERR: nginx -t 실패 - 자동 복원 시도"
      mv "$rendered" "${rendered}.broken.${TS}"
      if [ -n "$prev_backup" ] && [ -f "$prev_backup" ]; then
        cp -p "$prev_backup" "$rendered"
        if nginx -t; then
          systemctl reload nginx
          log "nginx conf 복원 성공 (${prev_backup} -> ${rendered}). 깨진 신규본 보존: ${rendered}.broken.${TS}"
        else
          # 복원본도 깨져있으면 마지막 conf 도 제거 + reload (404 보다 nginx 자체가 죽는 게 더 위험).
          rm -f "$rendered"
          systemctl reload nginx || true
          aws cloudwatch put-metric-data \
            --namespace ICONIA/Deploy --metric-name NginxRestoreFailed --value 1 \
            --region "$AWS_REGION" 2>/dev/null || true
          fail "nginx -t 신규/복원본 모두 실패 - ${rendered}.broken.${TS} + ${prev_backup} 보존, 운영자 즉시 개입"
        fi
      else
        systemctl reload nginx || true
        aws cloudwatch put-metric-data \
          --namespace ICONIA/Deploy --metric-name NginxRestoreFailed --value 1 \
          --region "$AWS_REGION" 2>/dev/null || true
        fail "nginx -t 실패 + 직전 백업 없음 - ${rendered}.broken.${TS} 보존, 수동 conf 복원 필요"
      fi
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
