#!/usr/bin/env bash
# safe-migrate-deploy.sh — production-safe prisma migrate deploy wrapper.
#
# 1. RDS manual snapshot (rollback 안전망)
# 2. snapshot 완료 대기
# 3. prisma migrate deploy
# 4. snapshot ID 출력 (실패 시 복구 reference)
#
# 사용: SSH 또는 SSM 으로 EC2 에서 실행
#   sudo bash /opt/iconia/server/scripts/safe-migrate-deploy.sh

set -euo pipefail

DB_INSTANCE="${RDS_INSTANCE_ID:-iconia-prod-db}"
REGION="${AWS_REGION:-ap-northeast-2}"
TS=$(date -u +%Y%m%dT%H%M%SZ)
SNAP_ID="pre-migrate-${TS}"
DST="${SERVER_DIR:-/opt/iconia/server}"

echo "[safe-migrate] $(date -u) — start"
echo "[safe-migrate] DB: $DB_INSTANCE, region: $REGION"
echo "[safe-migrate] snapshot: $SNAP_ID"

# 1. Snapshot 생성
aws rds create-db-snapshot \
  --db-instance-identifier "$DB_INSTANCE" \
  --db-snapshot-identifier "$SNAP_ID" \
  --region "$REGION" \
  >/dev/null
echo "[safe-migrate] snapshot 시작됨 — 완료 대기..."

# 2. Snapshot 완료 대기 (최대 15분)
aws rds wait db-snapshot-completed \
  --db-snapshot-identifier "$SNAP_ID" \
  --region "$REGION"
echo "[safe-migrate] snapshot 완료: $SNAP_ID"

# 3. Prisma migrate deploy
if [ ! -f "${DST}/prisma/schema.prisma" ]; then
  echo "[safe-migrate] ERR: schema.prisma 없음 — $DST/prisma/"
  exit 2
fi

DB_URL=$(awk -F= '/^DATABASE_URL=/{sub(/^DATABASE_URL=/,""); print; exit}' /etc/iconia.server.env)
if [ -z "$DB_URL" ]; then
  echo "[safe-migrate] ERR: DATABASE_URL not in /etc/iconia.server.env"
  exit 3
fi

cd "$DST"
echo "[safe-migrate] running prisma migrate deploy ..."
DATABASE_URL="$DB_URL" sudo -u iconia npx --yes prisma migrate deploy

echo "[safe-migrate] $(date -u) — done"
echo "[safe-migrate] rollback 필요 시 snapshot: $SNAP_ID"
echo "[safe-migrate]   복구: aws rds restore-db-instance-from-db-snapshot --db-snapshot-identifier $SNAP_ID --db-instance-identifier iconia-prod-db-restored"
