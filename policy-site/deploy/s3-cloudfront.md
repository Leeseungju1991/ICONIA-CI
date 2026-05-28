# 배포 — AWS S3 + CloudFront (권장)

> 정적 사이트 호스팅의 가장 안정적인 방식. 비용 거의 0 (S3 storage + CloudFront 무료 tier).

## 1. S3 버킷 생성

```bash
# 버킷 이름은 도메인과 같게 하면 편함 (예: policy.dollsoom.com)
BUCKET=iconia-policy-site
REGION=ap-northeast-2

aws s3 mb "s3://$BUCKET" --region "$REGION"
```

## 2. 정적 호스팅 활성화

```bash
aws s3 website "s3://$BUCKET" \
  --index-document index.html \
  --error-document index.html
```

> 본 사이트는 SPA — 모든 경로를 `index.html` 로 fallback (404 도 index.html).

## 3. 파일 업로드

```bash
cd "6. CI/policy-site"

# index.html / assets / content / 모두 업로드
aws s3 sync . "s3://$BUCKET" \
  --exclude "deploy/*" \
  --exclude "README.md" \
  --exclude ".git/*" \
  --cache-control "public, max-age=300"  # 5분 캐시
```

## 4. Bucket Policy — 공개 읽기

```bash
cat > /tmp/bucket-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PublicRead",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::$BUCKET/*"
  }]
}
EOF
aws s3api put-bucket-policy --bucket "$BUCKET" --policy file:///tmp/bucket-policy.json
```

## 5. CloudFront 분배

```bash
aws cloudfront create-distribution \
  --origin-domain-name "$BUCKET.s3.$REGION.amazonaws.com" \
  --default-root-object index.html
```

또는 콘솔에서 직접:
- Origin: S3 (위 버킷)
- Default behavior: Redirect HTTP to HTTPS
- Default root object: `index.html`
- Custom error response: 403, 404 → `/index.html`, 200

## 6. ACM 인증서 + Route53

```bash
# us-east-1 region 에서 ACM 발급 (CloudFront 는 us-east-1 만 지원)
aws acm request-certificate \
  --domain-name policy.dollsoom.com \
  --validation-method DNS \
  --region us-east-1

# Route53 에 검증 record 추가 후 CloudFront 에 도메인 + 인증서 연결
```

## 7. 배포 자동화 (CI)

`.github/workflows/policy-site-deploy.yml`:

```yaml
name: Deploy Policy Site

on:
  push:
    branches: [main]
    paths:
      - 'policy-site/**'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ap-northeast-2
      - name: Sync to S3
        working-directory: policy-site
        run: |
          aws s3 sync . s3://iconia-policy-site \
            --exclude "deploy/*" --exclude "README.md" --exclude ".git/*" \
            --cache-control "public, max-age=300"
      - name: Invalidate CloudFront
        run: |
          aws cloudfront create-invalidation \
            --distribution-id ${{ secrets.CLOUDFRONT_DIST_ID }} \
            --paths "/*"
```

## 8. 비용 (대략)

- S3 storage: 1MB 이하 → 거의 0
- CloudFront: 무료 tier 월 1TB 전송 + 1천만 요청 → 정책 사이트 정도면 0
- ACM 인증서: 무료
- Route53 hosted zone: $0.50/월
- **합계: 월 < $1**
