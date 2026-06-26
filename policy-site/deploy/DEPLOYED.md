# Policy site — DEPLOYED

> 본 사이트는 AWS S3 + CloudFront 로 배포되어 있습니다. 본 문서는 현재 deployed 상태의 리소스 식별자를 기록합니다.

## 배포 URL

- **현재 URL**: https://dzq72tlftowz4.cloudfront.net
- 활성화 일자: 2026-05-28

## 리소스 식별자

| 항목 | 값 |
|---|---|
| AWS Account | 169063643478 |
| Region | ap-northeast-2 (서울) |
| S3 Bucket | `iconia-prod-policy-169063643478` |
| Bucket 정책 | OAC 전용 (public 차단, CloudFront `EJTW5G0D050C6` 만 GetObject) |
| 암호화 | SSE-S3 (AES256) + Bucket Key |
| Versioning | Enabled |
| CloudFront Distribution ID | `EJTW5G0D050C6` |
| CloudFront Domain | `dzq72tlftowz4.cloudfront.net` |
| CloudFront OAC ID | `ER9JZC5ENMOQ9` |
| Price Class | PriceClass_200 (NA/EU/Asia) |
| TLS | TLS 1.2_2021 minimum |
| HTTP/2, IPv6 | Enabled |
| Response Headers Policy | SecurityHeadersPolicy (`67f7725c-6f97-4210-82d7-5512b31e9d03`) — HSTS / X-Content-Type-Options / X-Frame-Options DENY / Referrer-Policy |
| Cache Policy | CachingOptimized (`658327ea-f89d-4fab-a63d-7e88639e58f6`) |
| SPA Fallback | 403/404 → /index.html (200) |

## 정책 본문 갱신 → 재배포 (1 줄)

```bash
bash "6. CI/scripts/sync-policy-site.sh"
```

> S3 sync (`--delete`) + Content-Type 보정 + CloudFront invalidation `/*`. 1~3 분 내 반영.

## Custom Domain 추가 (향후, 사용자 결정 필요)

현재는 CloudFront default URL 사용 중. custom domain (예: `policy.dollsoom.com`) 으로 갈 때:

```bash
# 1) ACM 인증서 발급 (반드시 us-east-1)
aws acm request-certificate \
  --domain-name policy.dollsoom.com \
  --validation-method DNS \
  --region us-east-1

# 2) Route53 (또는 외부 DNS) 에 검증 CNAME 추가 → ACM 검증 완료까지 대기

# 3) CloudFront distribution 업데이트
#    - Aliases: ["policy.dollsoom.com"]
#    - ViewerCertificate: { AcmCertificateArn, SSLSupportMethod=sni-only, MinimumProtocolVersion=TLSv1.2_2021 }

# 4) Route53 에 ALIAS record (A or AAAA) → dzq72tlftowz4.cloudfront.net
```

## 비용

- S3 storage: < 1 MB → ~$0.00002/월
- CloudFront 전송: 무료 tier 월 1 TB + 10M 요청 → 정책 사이트 수준이면 $0
- 인증서: CloudFront default URL 사용 시 무료. ACM 발급도 무료
- **예상 월 비용: $0 (트래픽 무료 tier 내)**

## 보안 모델

- S3 bucket → public access 전체 차단 (PublicAccessBlock 모든 항목 true)
- CloudFront → OAC (Origin Access Control, sigv4 always) 로만 S3 접근
- Bucket policy → `aws:SourceArn` 조건으로 본 distribution 만 허용
- TLS 1.2_2021 minimum + HSTS (CloudFront 관리 SecurityHeadersPolicy)
- Versioning Enabled (rollback 대비)

## 리소스 삭제 (deprecation 시)

```bash
# 1) CloudFront distribution 비활성화 → 배포 완료 대기 → 삭제
aws cloudfront get-distribution-config --id EJTW5G0D050C6 > /tmp/dist.json
# 위 JSON 에서 Enabled: false 로 수정 후 update-distribution → 배포 완료 후 delete-distribution

# 2) S3 bucket 비우기 + 삭제
aws s3 rm s3://iconia-prod-policy-169063643478 --recursive
aws s3api delete-bucket --bucket iconia-prod-policy-169063643478

# 3) OAC 삭제
aws cloudfront delete-origin-access-control --id ER9JZC5ENMOQ9 --if-match <etag>
```
