#!/usr/bin/env bash
# (주)숨코리아 정책 사이트 — 정책 본문 변경 후 한 줄로 재배포.
#
# 사용:
#   bash 6. CI/scripts/sync-policy-site.sh
#
# 동작:
#   1) policy-site/ → S3 sync (deploy/, README.md, .git/ 제외) + --delete
#   2) 각 파일 별 Content-Type 보정 (text/html / text/css / application/javascript / text/markdown)
#   3) CloudFront invalidation /* — 캐시 무효화
#
# 정책 본문 정본 (`6. CI/docs/legal/*.md`) → `policy-site/content/*.md` 동기화는 본 스크립트 범위 밖.

set -euo pipefail

BUCKET="iconia-prod-policy-022671037305"
DIST_ID="E3UVE6Q83ZP9MM"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_DIR="$SCRIPT_DIR/../policy-site"

cd "$SITE_DIR"

echo "==> sync to s3://$BUCKET/"
aws s3 sync . "s3://$BUCKET/" \
  --exclude "deploy/*" \
  --exclude "README.md" \
  --exclude ".git/*" \
  --exclude ".gitignore" \
  --cache-control "public, max-age=300" \
  --delete

echo
echo "==> Content-Type 보정"
aws s3 cp "s3://$BUCKET/index.html" "s3://$BUCKET/index.html" \
  --metadata-directive REPLACE \
  --content-type "text/html; charset=utf-8" \
  --cache-control "public, max-age=60" >/dev/null
aws s3 cp "s3://$BUCKET/assets/style.css" "s3://$BUCKET/assets/style.css" \
  --metadata-directive REPLACE \
  --content-type "text/css; charset=utf-8" \
  --cache-control "public, max-age=86400" >/dev/null
aws s3 cp "s3://$BUCKET/assets/app.js" "s3://$BUCKET/assets/app.js" \
  --metadata-directive REPLACE \
  --content-type "application/javascript; charset=utf-8" \
  --cache-control "public, max-age=86400" >/dev/null
for f in content/*.md; do
  aws s3 cp "s3://$BUCKET/$f" "s3://$BUCKET/$f" \
    --metadata-directive REPLACE \
    --content-type "text/markdown; charset=utf-8" \
    --cache-control "public, max-age=300" >/dev/null
done

echo
echo "==> CloudFront invalidation"
INVAL=$(aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/*" --query 'Invalidation.Id' --output text)
echo "  invalidation id: $INVAL"

echo
echo "==> Done — https://d2txfcpfr4o2k.cloudfront.net"
echo "    (invalidation 완료까지 1-3 분)"
