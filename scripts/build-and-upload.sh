#!/usr/bin/env bash
###############################################################################
# build-and-upload.sh — Linux 빌드 + S3 artifacts 업로드.
#
# build-and-upload.ps1 (Windows 운영자용) 의 Linux/CI 등가물.
# GitHub Actions self-hosted/hosted runner 또는 운영자 Linux 셸에서 실행.
#
# 대상 서비스: SERVER (Node.js), AI (Node.js), ADMIN (Next.js).
# HW(펌웨어) / APP(Expo) 은 본 배포 대상 아님.
#
# 사용법:
#   scripts/build-and-upload.sh --service all --repo-root <ICONIA root> \
#     --bucket <artifacts bucket> [--region ap-northeast-2] \
#     [--version 20260520-101010Z] [--skip-npm] [--trigger-deploy]
#
# repo-root 하위 폴더 명명은 두 가지 레이아웃을 지원한다:
#   1) sibling repo 레이아웃: ICONIA-SERVER / ICONIA-AI / ICONIA-ADMIN
#   2) 숫자 폴더 레이아웃:     "2. SERVER" / "3. AI" / "5. ADMIN"
#
# 환경변수 fallback:
#   ICONIA_ARTIFACTS_BUCKET, ICONIA_REPO_ROOT, AWS_REGION
###############################################################################
set -euo pipefail

SERVICE="all"
REPO_ROOT="${ICONIA_REPO_ROOT:-}"
BUCKET="${ICONIA_ARTIFACTS_BUCKET:-}"
REGION="${AWS_REGION:-ap-northeast-2}"
VERSION=""
SKIP_NPM=0
TRIGGER_DEPLOY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --service)         SERVICE="$2"; shift 2 ;;
    --repo-root)       REPO_ROOT="$2"; shift 2 ;;
    --bucket)          BUCKET="$2"; shift 2 ;;
    --region)          REGION="$2"; shift 2 ;;
    --version)         VERSION="$2"; shift 2 ;;
    --skip-npm)        SKIP_NPM=1; shift ;;
    --trigger-deploy)  TRIGGER_DEPLOY=1; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERR: unknown arg $1" >&2; exit 2 ;;
  esac
done

[ -n "$BUCKET" ]    || { echo "ERR: --bucket (또는 ICONIA_ARTIFACTS_BUCKET) 필요" >&2; exit 2; }
[ -n "$REPO_ROOT" ] || { echo "ERR: --repo-root (또는 ICONIA_REPO_ROOT) 필요" >&2; exit 2; }
[ -d "$REPO_ROOT" ] || { echo "ERR: repo-root 없음: $REPO_ROOT" >&2; exit 2; }
case "$SERVICE" in server|ai|admin|all|_bootstrap) ;; *)
  echo "ERR: --service 는 server|ai|admin|all|_bootstrap" >&2; exit 2 ;; esac

command -v aws >/dev/null || { echo "ERR: aws CLI 필요" >&2; exit 1; }
command -v tar >/dev/null || { echo "ERR: tar 필요" >&2; exit 1; }

[ -n "$VERSION" ] || VERSION="$(date -u +%Y%m%d-%H%M%SZ)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_ROOT="$(dirname "$SCRIPT_DIR")"

log() { printf '[build %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

# 서비스별 소스 디렉토리 해석 — 두 레이아웃 지원.
resolve_src() {
  local svc="$1" a b
  case "$svc" in
    server) a="ICONIA-SERVER"; b="2. SERVER" ;;
    ai)     a="ICONIA-AI";     b="3. AI" ;;
    admin)  a="ICONIA-ADMIN";  b="5. ADMIN" ;;
    *)      echo ""; return ;;
  esac
  if   [ -d "${REPO_ROOT}/${a}" ]; then echo "${REPO_ROOT}/${a}"
  elif [ -d "${REPO_ROOT}/${b}" ]; then echo "${REPO_ROOT}/${b}"
  else echo ""
  fi
}

build_one() {
  local svc="$1" src stage tar sha
  src="$(resolve_src "$svc")"
  [ -n "$src" ] || { echo "ERR: ${svc} 소스 폴더 없음 (repo-root=${REPO_ROOT})" >&2; exit 1; }

  stage="$(mktemp -d -t "iconia-build-${svc}.XXXX")"
  log "${svc} stage <- ${src}"
  # node_modules / .next / .git / 빌드 캐시 / .env 제외 복사.
  rsync -a --delete \
    --exclude 'node_modules' --exclude '.next' --exclude '.expo' \
    --exclude '.git' --exclude 'coverage' --exclude 'tmp' --exclude '.turbo' \
    --exclude '.env' --exclude '.env.*' --exclude '*.log' --exclude '*.tsbuildinfo' \
    "${src}/" "${stage}/"

  if [ "$SKIP_NPM" -eq 0 ]; then
    log "${svc} npm ci"
    ( cd "$stage" && npm ci )

    if [ "$svc" = "admin" ]; then
      log "admin next build"
      ( cd "$stage" && npm run build )
      [ -d "${stage}/.next/standalone" ] \
        || { echo "ERR: admin .next/standalone 부재 — next.config 의 output:'standalone' 필요" >&2; exit 1; }
      # standalone 산출물에는 static / public 이 빠져있으므로 수동 복사.
      if [ -d "${stage}/.next/static" ]; then
        mkdir -p "${stage}/.next/standalone/.next"
        cp -r "${stage}/.next/static" "${stage}/.next/standalone/.next/static"
      fi
      [ -d "${stage}/public" ] && cp -r "${stage}/public" "${stage}/.next/standalone/public"
    fi

    if [ "$svc" = "server" ] && [ -f "${stage}/prisma/schema.prisma" ]; then
      log "server prisma generate"
      ( cd "$stage" && npx --yes prisma generate )
    fi

    log "${svc} npm prune --omit=dev"
    ( cd "$stage" && npm prune --omit=dev )
  fi

  tar="$(mktemp -t "iconia-${svc}-${VERSION}.XXXX").tar.gz"
  log "${svc} tar -> ${tar}"
  tar -czf "$tar" -C "$stage" .
  sha="$(sha256sum "$tar" | awk '{print $1}')"
  log "${svc} sha256=${sha}"

  log "${svc} upload -> s3://${BUCKET}/${svc}/${VERSION}.tar.gz"
  aws s3 cp "$tar" "s3://${BUCKET}/${svc}/${VERSION}.tar.gz" --region "$REGION"
  aws s3 cp "s3://${BUCKET}/${svc}/${VERSION}.tar.gz" "s3://${BUCKET}/${svc}/latest.tar.gz" --region "$REGION"
  printf '%s' "$sha" > "${tar}.sha256"
  aws s3 cp "${tar}.sha256" "s3://${BUCKET}/${svc}/latest.tar.gz.sha256" --region "$REGION"

  rm -rf "$stage" "$tar" "${tar}.sha256"
}

build_bootstrap() {
  local stage tar
  stage="$(mktemp -d -t iconia-bootstrap.XXXX)"
  mkdir -p "${stage}/deploy/systemd" "${stage}/deploy/nginx/snippets" "${stage}/scripts"
  cp "${CI_ROOT}/deploy/systemd/iconia-server.service" "${stage}/deploy/systemd/"
  cp "${CI_ROOT}/deploy/systemd/iconia-ai.service"     "${stage}/deploy/systemd/"
  cp "${CI_ROOT}/deploy/systemd/iconia-admin.service"  "${stage}/deploy/systemd/"
  cp "${CI_ROOT}/deploy/nginx/iconia.conf"             "${stage}/deploy/nginx/iconia.conf"
  cp "${CI_ROOT}/deploy/nginx/snippets-iconia-proxy.conf" "${stage}/deploy/nginx/snippets/iconia-proxy.conf"
  cp "${CI_ROOT}/scripts/ec2-pull-and-restart.sh"      "${stage}/scripts/"

  tar="$(mktemp -t "iconia-bootstrap-${VERSION}.XXXX").tar.gz"
  tar -czf "$tar" -C "$stage" .
  log "_bootstrap upload -> s3://${BUCKET}/_bootstrap/deploy.tar.gz"
  aws s3 cp "$tar" "s3://${BUCKET}/_bootstrap/deploy-${VERSION}.tar.gz" --region "$REGION"
  aws s3 cp "s3://${BUCKET}/_bootstrap/deploy-${VERSION}.tar.gz" "s3://${BUCKET}/_bootstrap/deploy.tar.gz" --region "$REGION"
  aws s3 cp "${CI_ROOT}/scripts/ec2-pull-and-restart.sh" "s3://${BUCKET}/_bootstrap/ec2-pull-and-restart.sh" --region "$REGION"
  rm -rf "$stage" "$tar"
}

case "$SERVICE" in
  all)        build_bootstrap; build_one server; build_one ai; build_one admin ;;
  _bootstrap) build_bootstrap ;;
  *)          build_one "$SERVICE" ;;
esac

log "version=${VERSION} uploaded to s3://${BUCKET}/"

if [ "$TRIGGER_DEPLOY" -eq 1 ]; then
  local_target="$SERVICE"
  [ "$SERVICE" = "_bootstrap" ] && local_target="all"
  log "trigger-deploy -> ${local_target}"
  "${SCRIPT_DIR}/trigger-deploy.sh" --service "$local_target" --region "$REGION"
fi
