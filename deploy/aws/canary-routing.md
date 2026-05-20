# Canary 트래픽 라우팅 운영 정본

## 1. 현 상태

현재 ICONIA 인프라는 **단일 EC2 + nginx host-header 라우팅** 모델. ALB / Target Group 이 없으므로 weighted routing 의 진입점이 Route53 한 곳뿐이다.

따라서 카나리 배포는 **두 가지 모드 중 하나**로 운영한다:

1. **Application-layer canary** (현 단계 기본). 단일 EC2 안에서 application 자체가 `X-Iconia-Canary: 1` 헤더나 `user_id` modulo 기반으로 신/구 코드 경로 분기. server 측 feature flag (Server `2. SERVER/src/services/featureFlags.js`) 가 책임.
2. **Route53 weighted record** (이중 EC2 가 살아 있을 때 한정). `api-canary.<root>` 를 신규 EIP 로 만들고 가중치를 5→25→50→100 으로 점진 증가. 실패 시 weighted 0 으로 즉시 회수.

## 2. Route53 weighted routing 활성 절차

ALB 도입 전까지는 weighted record 도 가능 — Route53 가 EIP 두 개로 라운드로빈 가중치 결정.

### 2.1 사전 준비

```bash
# stable EIP (현행).
STABLE_EIP=$(terraform -chdir="../../terraform" output -raw ec2_public_ip)

# canary EC2 를 별도 stack 으로 띄움 (terraform workspace canary).
cd ../../terraform
terraform workspace new canary
terraform apply -var "env=staging" -var "root_domain=YOUR_DOMAIN" -var "create_route53_records=false"
CANARY_EIP=$(terraform output -raw ec2_public_ip)
```

### 2.2 weighted A record 두 개 생성

```bash
HZID=$(terraform -chdir="../../terraform" output -raw route53_zone_id)

cat > /tmp/api-weighted.json <<JSON
{
  "Comment": "ICONIA api canary weighted - stable 95 / canary 5",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "api.YOUR_DOMAIN.",
        "Type": "A",
        "SetIdentifier": "stable",
        "Weight": 95,
        "TTL": 30,
        "ResourceRecords": [{"Value": "${STABLE_EIP}"}],
        "HealthCheckId": "STABLE_HEALTH_CHECK_ID"
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "api.YOUR_DOMAIN.",
        "Type": "A",
        "SetIdentifier": "canary",
        "Weight": 5,
        "TTL": 30,
        "ResourceRecords": [{"Value": "${CANARY_EIP}"}],
        "HealthCheckId": "CANARY_HEALTH_CHECK_ID"
      }
    }
  ]
}
JSON

aws route53 change-resource-record-sets --hosted-zone-id "$HZID" \
  --change-batch file:///tmp/api-weighted.json
```

### 2.3 단계적 가중치 상승

| 단계 | stable | canary | 관찰 시간 | 자동 회수 조건 |
|---|---|---|---|---|
| T+0  | 95 | 5   | 15분 | canary 5xx >= 1% **또는** p95 latency 2배 |
| T+15 | 75 | 25  | 30분 | 동일 |
| T+45 | 50 | 50  | 60분 | 동일 |
| T+105 | 0  | 100 | (canary → 새 stable) | post-deploy 30 분 모니터링 |

자동 회수 trigger: CloudWatch alarm `iconia-server-5xx-rate-high` (`SetIdentifier=canary` 의 ALB metric 또는 application metric) → SNS → Lambda 가 `Weight=0` 으로 즉시 UPSERT.

### 2.4 회수 (canary 실패 시)

```bash
# canary 의 Weight 만 0 으로 즉시 변경. stable 은 100 으로 자동 흡수.
aws route53 change-resource-record-sets --hosted-zone-id "$HZID" \
  --change-batch '{
    "Changes": [{"Action":"UPSERT","ResourceRecordSet":{
      "Name":"api.YOUR_DOMAIN.","Type":"A","SetIdentifier":"canary",
      "Weight":0,"TTL":30,"ResourceRecords":[{"Value":"CANARY_EIP"}]
    }}]
  }'
```

Route53 TTL 30 초 + DNS resolver client cache 까지 합쳐 약 1-3 분 안에 트래픽 회수.

## 3. Application-layer canary (현 라운드 기본)

ALB/이중 EC2 없이 단일 호스트에서 운영. `iconia-server` (Express) 가:

- 요청의 `user_id` 또는 `Authorization` JWT subject 의 modulo (`hash(user_id) % 100`) 와 `CANARY_PERCENT` env 비교.
- 또는 `X-Iconia-Canary: 1` 헤더 (운영자 / QA bot 만 발신) 강제 진입.

해당 분기를 받은 요청만 새 코드 경로 (e.g., 새 feature flag block) 실행. 본 흐름은 server 측 코드 책임이고, 본 인프라 폴더는 nginx 로 헤더 통과만 보장한다 (`include /etc/nginx/snippets/iconia-proxy.conf` 가 `proxy_set_header X-Iconia-Canary $http_x_iconia_canary;` 를 보존해야 함 — 운영자 점검 항목).

## 4. ALB 도입 후 (M+1 라운드)

ALB target group 두 개 (stable / canary) + listener rule 가중치로 진정한 L7 canary 도입. 이때는 본 문서의 Route53 weighted 모드를 deprecated 로 표기하고 ALB weighted target group 만 사용.

## 5. 점검 체크리스트

- [ ] canary 배포 직전: `terraform plan` 으로 변경 검토 + `trigger-deploy.ps1 -Service all` 의 dry-run 확인
- [ ] canary 활성 동안: CloudWatch dashboard 의 `iconia-server-5xx-rate-high` / `iconia-server-ai-p95-latency-high` 1분 주기 모니터링
- [ ] 회수 trigger 발사 후 3분 내 stable 100% 회복 확인
- [ ] post-mortem: canary 결과를 `2. SERVER/CHANGELOG.md` 의 해당 release 라인에 기록
