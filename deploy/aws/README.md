# AWS infra artifacts (정본)

이 폴더는 ICONIA-SERVER 가 의존하는 AWS 리소스의 **정본 정책 파일**과 **수동 적용 명령** 모음입니다. CDK/Terraform IaC 도입(M+1) 전까지는 본 정의를 source-of-truth 로 사용하고, AWS CLI 로 직접 적용합니다.

| 파일 | 용도 | 적용 대상 |
|---|---|---|
| `s3-lifecycle.json` | 이미지·음성·export 자동 만료 | S3 bucket `iconia-prod-events` |
| `s3-bucket-policy.json` | 버킷 정책 — TLS 강제, 퍼블릭 차단 | 동일 |
| `s3-encryption.json` | 버킷 기본 암호화 (SSE-KMS) | 동일 |
| `s3-public-access-block.json` | BlockPublicAccess 모든 옵션 | 동일 |
| `iam-ec2-instance-role.json` | EC2 instance profile 권한 | 운영 EC2 |
| `iam-ec2-trust-policy.json` | EC2 trust policy | 동일 |
| `cloudwatch-alarms.json` | 운영 알람 정의 | CloudWatch |
| `cloudwatch-log-metric-filters.json` | PII 누출 감시 metric filter | CloudWatch Logs |
| `kms-key-policy.json` | CMK key policy (회전 활성) | KMS |

## 적용 순서 (운영 신규 셋업)

```bash
# 변수
export REGION=ap-northeast-2
export BUCKET=iconia-prod-events
export ROLE_NAME=iconia-ec2-role
export INSTANCE_PROFILE=iconia-ec2-profile
export KEY_ALIAS=alias/iconia-prod-data

# 1) KMS CMK 생성 + 회전 활성 + 별칭 부여
aws kms create-key --region $REGION \
  --description "ICONIA prod data encryption (S3, EFS optional)" \
  --policy file://kms-key-policy.json \
  --tags TagKey=service,TagValue=iconia
# 출력 KeyId 를 KEY_ID 에 저장
aws kms enable-key-rotation --region $REGION --key-id $KEY_ID
aws kms create-alias --region $REGION --alias-name $KEY_ALIAS --target-key-id $KEY_ID

# 2) S3 bucket 보안 강화
aws s3api put-public-access-block --bucket $BUCKET \
  --public-access-block-configuration file://s3-public-access-block.json
aws s3api put-bucket-encryption --bucket $BUCKET \
  --server-side-encryption-configuration file://s3-encryption.json
aws s3api put-bucket-policy --bucket $BUCKET --policy file://s3-bucket-policy.json
aws s3api put-bucket-lifecycle-configuration --bucket $BUCKET \
  --lifecycle-configuration file://s3-lifecycle.json
aws s3api put-bucket-versioning --bucket $BUCKET \
  --versioning-configuration Status=Enabled

# 3) EC2 instance profile + role
aws iam create-role --role-name $ROLE_NAME \
  --assume-role-policy-document file://iam-ec2-trust-policy.json
aws iam put-role-policy --role-name $ROLE_NAME \
  --policy-name iconia-ec2-inline --policy-document file://iam-ec2-instance-role.json
aws iam create-instance-profile --instance-profile-name $INSTANCE_PROFILE
aws iam add-role-to-instance-profile \
  --instance-profile-name $INSTANCE_PROFILE --role-name $ROLE_NAME

# 4) CloudWatch 알람 / metric filter 적용
# (json 안의 actions/topic ARN 을 운영 SNS 토픽으로 미리 치환)
bash apply-cloudwatch.sh
```

## 검증

```bash
# IAM 정책 simulation — 사용자별 prefix 격리 확인
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::ACCOUNT:role/$ROLE_NAME \
  --action-names s3:GetObject \
  --resource-arns arn:aws:s3:::$BUCKET/iconia/events/*

# 퍼블릭 노출 확인 (모두 false 여야 함)
aws s3api get-public-access-block --bucket $BUCKET

# 암호화 확인
aws s3api get-bucket-encryption --bucket $BUCKET
```

## 비용 시나리오 (월간, ap-northeast-2 표준 기준)

- KMS CMK: $1/월 + 호출당 $0.03/10k → 일 1만 호출(1000 디바이스 × 10회) ≈ $0.09/일 ≈ $2.7/월
- CloudWatch alarms: $0.10/알람/월 × 8 = $0.80/월
- CloudWatch metric filter: 무료 (로그 자체 ingestion 비용은 별도)
- S3 versioning: 비활성 버전 30일 후 자동 삭제 정책으로 누적 차단 (lifecycle 룰에 포함됨)
- S3 lifecycle 적용 자체는 무료, 전환 시 $0.01/1000 객체

총 추가 비용: 월 $5 미만 (M0 트래픽 가정).
