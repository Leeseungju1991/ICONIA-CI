# GCP Cloud Quotas Auto-Lift (Round 2026-05-26, Task #11)

ICONIA 의 Gemini API quota 증설 신청을 주간 cron 으로 자동화한다.

본 라운드는 **준비 단계**다. 운영자가 명시적으로 활성화 결정을 내릴 때까지
EventBridge schedule 은 `DISABLED` 로 시작한다 — Lambda 본체만 생성된다.

---

## 1. 배치 결정 — AWS Lambda vs GCP Cloud Function

| 항목 | AWS Lambda + EventBridge | GCP Cloud Function + Cloud Scheduler |
|---|---|---|
| 호출 대상 GCP API 와의 거리 | 외부 호출 (TLS handshake 1회) | 같은 GCP 프로젝트 내부 (latency 미세 우위) |
| 운영 단일성 (ICONIA 다른 자동화는 AWS) | **O** | X (GCP 콘솔 1개 더 관리) |
| Secret 보관 | AWS Secrets Manager (다른 회전 hook 과 동거) | GCP Secret Manager (별도 격리) |
| 모니터링 | CloudWatch Logs + 알람 (기존 운영) | Cloud Logging (별도 대시보드 필요) |
| IAM 분리 | GCP service account 키를 Secrets Manager 에 보관 (노출 면 +1) | GCP 자체 ADC — 키 파일 불필요 (보안 우위) |
| 결정 | **권장 (운영 단일성 우선)** | 보안/지연 극단 최적화가 필요할 때 |

**결정: AWS Lambda 채택.** ICONIA 의 모든 자동화(rds-password-rotator,
efs-userspace-provisioner)가 AWS Lambda 에 있으므로 운영 표면을 한 곳으로 유지.

> GCP Secret Manager + Cloud Function 전환은 운영 표면이 2개로 분기되는 단점이
> 보안 우위(SA 키 파일 비휴대)를 압도. 향후 GCP 자체 자원(BigQuery export 등)이
> 늘어나 GCP 자동화가 임계 도달 시 재평가.

---

## 2. 파일 구성

| 경로 | 역할 |
|---|---|
| `terraform/quotas-auto-lift.tf` | Lambda + EventBridge rule + IAM role + Outputs |
| `terraform/lambda/gcp_quotas_auto_lift.py` | Lambda 본체 (Python 3.12) |
| `terraform/QUOTAS_AUTO_LIFT_README.md` | 본 문서 (활성화 절차 / 한계 / 비용) |

---

## 3. 활성화 절차 (운영자)

### 3.1 GCP 측 — service account 발급

```bash
# 1) Cloud Quotas API 활성화
gcloud services enable cloudquotas.googleapis.com --project=<gcp-project>

# 2) service account 생성 + role 부여
gcloud iam service-accounts create iconia-quotas-lifter \
  --display-name="ICONIA Cloud Quotas auto-lift" \
  --project=<gcp-project>

gcloud projects add-iam-policy-binding <gcp-project> \
  --member="serviceAccount:iconia-quotas-lifter@<gcp-project>.iam.gserviceaccount.com" \
  --role="roles/cloudquotas.admin"

# 3) JSON 키 발급 (1회만 — 즉시 Secrets Manager 로 이동, 로컬 보관 금지)
gcloud iam service-accounts keys create gcp-sa-iconia.json \
  --iam-account=iconia-quotas-lifter@<gcp-project>.iam.gserviceaccount.com
```

### 3.2 AWS 측 — Secrets Manager 등록

```bash
aws secretsmanager create-secret \
  --name "iconia/${ENV}/gcp/service_account_json" \
  --description "GCP SA JSON for Cloud Quotas auto-lift (ICONIA Round 2026-05-26 Task #11)" \
  --secret-string file://gcp-sa-iconia.json

# 키 파일 즉시 폐기
shred -u gcp-sa-iconia.json
```

### 3.3 Lambda Python deps layer 빌드

Lambda 가 `google-auth`, `google-auth-httplib2`, `google-api-python-client` 를
필요로 한다. 본 라운드의 `archive_file` 은 단일 `.py` 만 묶으므로 첫 invoke 가
`ImportError` 로 명시 실패한다 (의도된 fail-fast).

레이어 1회 빌드:

```bash
mkdir -p layer/python
pip install --target layer/python google-auth google-auth-httplib2 requests
cd layer && zip -r ../gcp-deps-layer.zip python && cd ..

aws lambda publish-layer-version \
  --layer-name iconia-gcp-deps \
  --description "google-auth + requests for GCP Cloud Quotas API" \
  --zip-file fileb://gcp-deps-layer.zip \
  --compatible-runtimes python3.12

# 결과의 LayerVersionArn 을 quotas-auto-lift.tf 의 `layers = [...]` 주석을 풀어 주입.
```

또는 `pip install -t ./terraform/lambda/_deps ...` 후 archive_file 의
source_dir 를 deps 포함 폴더로 변경 (zip 동봉 옵션).

### 3.4 Terraform 활성화

`terraform/terraform.tfvars`:

```hcl
enable_quotas_auto_lift = true
gcp_project_id          = "iconia-prod-457912"
# gcp_quotas_sa_secret_name 은 default ("iconia/${env}/gcp/service_account_json") 사용
# quotas_multiplier       = 2     # baseline 의 200% (persona-ai 권장)
# quotas_hard_ceiling     = 10000 # 최종 안전 상한 (RPM)
# quotas_cron_expression  = "cron(0 0 ? * SUN *)"  # 매주 일요일 00:00 UTC
```

```bash
cd terraform
terraform plan -out=tfplan
terraform apply tfplan
```

### 3.5 첫 발사 검증

```bash
# 수동 invoke (cron 기다리지 말고 즉시 검증)
aws lambda invoke \
  --function-name iconia-${ENV}-gcp-quotas-auto-lift \
  --payload '{}' \
  /tmp/quotas-lift-result.json
cat /tmp/quotas-lift-result.json

# 로그 확인
aws logs tail /aws/lambda/iconia-${ENV}-gcp-quotas-auto-lift --follow

# 신청 결과는 GCP 콘솔에서:
# https://console.cloud.google.com/iam-admin/quotas?project=<gcp-project>
# → "Quota requests" 탭에서 status 확인 (PENDING_APPROVAL → APPROVED|DENIED).
```

---

## 4. 한계 — 자동 승인 불가

**Google 측 manual review (1~3 영업일).** 본 Lambda 는 "신청만 자동화".
일부 quota 는 즉시 자동 승인 (Cloud Quotas API 의 `cooldown` 정책 적용 대상)
이지만 `GenerateContentRequestsPerMinutePerProject` 는 manual.

운영 절차:

1. Lambda 가 매주 일요일 신청 → CloudWatch 알람 (`QuotasAutoLiftRequested`).
2. 운영자가 월요일 GCP 콘솔에서 status 확인.
3. APPROVED → effective 즉시. DENIED → Google support 케이스 (justification 보강).

**결과 polling 자동화는 본 라운드 범위 외.** 다음 라운드에서:
- Lambda 가 `quotaPreferences/list` 로 직전 신청 status 조회.
- DENIED 면 CloudWatch + Slack 알람 격상.

---

## 5. 비용

| 항목 | 추정 |
|---|---|
| Lambda invocation (주 1회) | 월 4회 × 60s × 256MB = 무료 free tier 안 |
| Secrets Manager API call | 월 4회 × $0.05/10000 = < $0.0001 |
| CloudWatch Logs | 로그 1회 ~수 KB × 4 = < $0.01 |
| CloudWatch PutMetricData | 3 metric × 월 4회 = < $0.001 |
| EventBridge rule | 월 4회 invocation = 무료 |
| GCP Cloud Quotas API | 무료 |
| **합계** | **월 $0.01 미만** |

---

## 6. 보안 영향

| 항목 | 내용 |
|---|---|
| 신규 공격 표면 | GCP SA JSON 키 1개가 AWS Secrets Manager 에 추가됨. |
| 키 회전 | service account 키는 90일 회전 권장 (수동). 자동화는 별도 라운드. |
| IAM 최소권한 | Lambda 는 `iconia/${env}/gcp/service_account_json` 1건만 `GetSecretValue` 가능. CloudWatch namespace 도 `ICONIA/Quotas` 한정. |
| GCP 측 권한 | `roles/cloudquotas.admin` — quota 변경만 가능. Gemini API 호출/billing/IAM 변경은 불가. |
| 키 노출 시 영향 | quota 조회/신청만 가능. 데이터 / billing 영향 X. 즉시 GCP 콘솔에서 키 폐기 → 신규 키 발급 → Secrets Manager 갱신. |

---

## 7. 장애 시나리오

| 시나리오 | 영향 | 복구 |
|---|---|---|
| Lambda invocation 실패 (ImportError) | quota 증설 신청 미발생 → 다음 주 cron 까지 누락 | 운영자 수동 invoke 또는 GCP 콘솔에서 직접 신청 |
| GCP API 응답 5xx | 동일 (1주 누락) | 다음 cron 자동 재시도 (멱등) |
| Secrets Manager 미존재 | Lambda 실패 + CloudWatch alarm | secret 등록 후 재invoke |
| baseline=0 응답 (limit 자체 미존재) | no-op + CloudWatch metric `QuotasAutoLiftError` | limit_name 변수 재검토 |
| Google 측 DENIED | quota 변경 0 | 다음 cron 까지 운영자가 Google support 케이스 |

---

## 8. 이후 라운드 권장 작업

- [ ] `quotaPreferences/list` 로 직전 신청 status polling → DENIED 알람.
- [ ] GCP SA 키 90일 자동 회전 (Lambda + Secrets Manager 회전 hook).
- [ ] limit_name 다중화: `generate_content_input_tokens_per_minute_per_project` 등.
- [ ] region/model 별 dimension 신청 분기 (현재는 글로벌만).
- [ ] `deploy/RUNBOOK.md` 의 "Quotas 운영" 섹션 추가.
