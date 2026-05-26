# EventStore Cutover — `fs` → `prisma` (단일 EC2 → ASG 전환)

Server `src/services/eventStore.js` 는 두 백엔드를 지원한다.

| 백엔드 | 저장소 | 인스턴스 모델 | race 처리 |
|---|---|---|---|
| `fs` (기본) | EFS atomic 파일 | **단일 EC2** | 파일 락 — 같은 인스턴스 내 시리얼 |
| `prisma` | RDS PostgreSQL `event_store` 테이블 | **ASG N=2+** | `event_id` unique 제약 + `claim_pending_event` race-free |

ASG N=2 이상으로 스케일 아웃하기 전에 반드시 `prisma` 로 cutover 해야 한다.
`fs` 인 채로 다중 인스턴스가 같은 EFS 파일을 동시 쓰면 atomic 파일 rename 이
race 차단을 100% 보장하지 못한다 (NFS close-to-open consistency 한계).

본 문서는 단일 EC2 운영 → ASG cutover 절차를 단계별로 정리한다.

---

## 0. 사전 점검

```powershell
# (1) Server 가 최신 (PrismaEventStore claim/lease 도입 commit 6ce29eb 이후) 인지 확인
cd "C:\Users\user\Music\ICONIA\2. SERVER"
git log --oneline | Select-String "PrismaEventStore|claim/lease"

# (2) RDS 가 가용한지 확인 (5종 인프라 중 RDB)
cd "C:\Users\user\Music\ICONIA\6. CI\terraform"
terraform output -raw rds_endpoint
# (또는 RDS Proxy endpoint)
terraform output -raw rds_proxy_endpoint  # 출력 정의에 따라 다름

# (3) 현재 Server 의 EVENT_STORE_BACKEND 확인
aws ssm send-command `
  --document-name "AWS-RunShellScript" `
  --instance-ids $env:ICONIA_EC2_INSTANCE_ID `
  --parameters "commands=['grep EVENT_STORE_BACKEND /etc/iconia.env']" `
  --region $env:AWS_REGION
```

기대 출력: `EVENT_STORE_BACKEND=fs` (cutover 전).

---

## 1. Cutover 절차

### 1.1 Prisma migration 적용 (event_store 테이블 + claim/lease 컬럼)

`6ce29eb` 라운드에서 도입된 `event_store` 테이블 + `claimed_by` / `claimed_at`
/ `lease_until` 컬럼이 운영 RDS 에 반영되어야 한다.

`ec2-pull-and-restart.sh` 가 server svc deploy 시 자동으로 `prisma migrate deploy`
를 실행하므로, **신규 server 배포만 트리거하면 마이그레이션이 적용**된다.

```powershell
pwsh -File scripts\trigger-deploy.ps1 -Service server
```

SSM 콘솔에서 출력 확인:
```
server prisma migrate deploy
... Database schema is up to date.
```

### 1.2 검증 — Prisma 백엔드가 적재 가능한 상태인지

운영 RDS 에 직접 붙어 테이블 존재 확인 (운영자 임시 권한 + SSM port-forward 가정):

```sql
\d event_store
-- columns: id, event_id (unique), payload, status, claimed_by, claimed_at, lease_until, created_at, ...
```

### 1.3 `event_store_backend = prisma` 로 terraform apply

```powershell
cd "C:\Users\user\Music\ICONIA\6. CI\terraform"

# terraform.tfvars 또는 -var 로 주입
terraform apply -var="event_store_backend=prisma"
```

`launch_template.tf` 가 user-data 를 재렌더링 → ASG instance refresh 가 트리거된다
(launch template version 변경). 신규 인스턴스가 `/etc/iconia.env` 에
`EVENT_STORE_BACKEND=prisma` 를 가진 채로 부팅.

**기존 단일 EC2 인스턴스에는 즉시 반영되지 않음** — 다음 1.4 로 강제 반영.

### 1.4 기존 인스턴스 즉시 cutover (instance refresh 기다리지 않을 때)

```powershell
# SSM 으로 /etc/iconia.env 직접 갱신 + systemctl restart
aws ssm send-command `
  --document-name "AWS-RunShellScript" `
  --instance-ids $env:ICONIA_EC2_INSTANCE_ID `
  --parameters @"
commands=[
  'sed -i s/^EVENT_STORE_BACKEND=.*/EVENT_STORE_BACKEND=prisma/ /etc/iconia.env',
  'grep EVENT_STORE_BACKEND /etc/iconia.env',
  'systemctl restart iconia-server',
  'sleep 5',
  'curl -fsS http://127.0.0.1:8080/health'
]
"@ `
  --region $env:AWS_REGION
```

### 1.5 검증 — claim_pending_event 호출 로그

restart 직후 CloudWatch Logs:
```
{ "component": "eventStore", "backend": "prisma", "msg": "store_initialized" }
{ "component": "analysisQueue", "claim": { "event_id": "...", "claimed_by": "i-0abc..." }, ... }
```

`claimed_by` 가 EC2 instance-id (`i-xxx`) 로 보이면 INSTANCE_ID 주입 성공.
`<hostname>-<pid>` 형태로 보이면 IMDSv2 fetch 실패 — `INSTANCE_ID` 빈 값 점검.

```powershell
aws logs filter-log-events `
  --log-group-name "/iconia/$env:ICONIA_ENV/server" `
  --filter-pattern '{ $.component = "analysisQueue" && $.claim.claimed_by = "i-*" }' `
  --start-time ((Get-Date).AddMinutes(-5).ToUniversalTime() - (Get-Date "1970-01-01")).TotalMilliseconds `
  --region $env:AWS_REGION
```

### 1.6 ASG 스케일 아웃 (N=2)

`prisma` 백엔드가 안정 동작 확인 후 ASG desired 증가:

```powershell
cd "C:\Users\user\Music\ICONIA\6. CI\terraform"
terraform apply -var="asg_desired_capacity=2" -var="event_store_backend=prisma"
```

또는 일시 변경:
```powershell
aws autoscaling set-desired-capacity `
  --auto-scaling-group-name (terraform output -raw asg_name) `
  --desired-capacity 2 `
  --region $env:AWS_REGION
```

### 1.7 race 차단 검증

N=2 인스턴스가 같은 미처리 event 를 동시에 claim 시도 → 한 쪽만 성공해야 한다.

```sql
-- event_store 의 claim 분포 (instance-id 별)
SELECT claimed_by, COUNT(*) FROM event_store
 WHERE status = 'CLAIMED'
 GROUP BY claimed_by;
```

기대: 두 인스턴스가 비슷한 비율로 claim 분담. **같은 event_id 가 두 claimed_by
에 모두 기록되면 절대 안 됨** (unique 제약 + claim 로직이 작동하지 않은 것).

---

## 2. 롤백 절차 (prisma → fs)

장애 / 성능 이슈 발생 시. PostgreSQL `event_store` 의 데이터는 그대로 보존된다
(다음 cutover 때 재사용 가능).

### 2.1 ASG 를 단일 인스턴스로 축소

```powershell
terraform apply -var="asg_desired_capacity=1" -var="event_store_backend=fs"
```

### 2.2 기존 인스턴스 즉시 fs 복귀

```powershell
aws ssm send-command `
  --document-name "AWS-RunShellScript" `
  --instance-ids $env:ICONIA_EC2_INSTANCE_ID `
  --parameters @"
commands=[
  'sed -i s/^EVENT_STORE_BACKEND=.*/EVENT_STORE_BACKEND=fs/ /etc/iconia.env',
  'systemctl restart iconia-server',
  'sleep 5',
  'curl -fsS http://127.0.0.1:8080/health'
]
"@ `
  --region $env:AWS_REGION
```

### 2.3 미처리 event drain

`prisma` 모드에서 `CLAIMED` 상태로 남은 event 는 `lease_until` 만료 후 다음
스케줄러가 재처리한다. `fs` 모드는 이를 보지 못하므로 운영자가 수동 확인 필요:

```sql
SELECT event_id, claimed_by, lease_until FROM event_store
 WHERE status = 'CLAIMED' AND lease_until < NOW();
```

필요 시 수동으로 status='PENDING' 으로 갱신 후 fs 모드에서 재적재.

---

## 3. 주의사항

### 3.1 INSTANCE_ID fallback

user-data 가 IMDSv2 로 instance-id 를 fetch 하지 못하면 `INSTANCE_ID` 가 빈
값으로 `/etc/iconia.env` 에 기록된다. server.js 가 `${os.hostname()}-${process.pid}`
로 fallback — 단일 EC2 에선 무해하지만 **ASG N 인스턴스에서 hostname 중복 시
`claimed_by` 가 모호**해진다.

점검:
```powershell
aws ssm send-command `
  --document-name "AWS-RunShellScript" `
  --instance-ids $env:ICONIA_EC2_INSTANCE_ID `
  --parameters "commands=['grep ^INSTANCE_ID= /etc/iconia.env','hostname']" `
  --region $env:AWS_REGION
```

`INSTANCE_ID=i-...` 가 나와야 정상. 빈 값이면 IMDSv2 token 발급/네트워크 점검
(`launch_template.tf` 의 `metadata_options` 확인 — 이미 `http_tokens=required`,
`http_put_response_hop_limit=2` 설정됨).

### 3.2 ANALYSIS_CLAIM_LEASE_MS 튜닝

- 기본 300000 (5분). 인스턴스가 5분 이상 응답 없으면 다른 인스턴스가 재claim.
- AI 호출 평균 대비 충분히 길어야 함 (AI p95 latency × 안전계수).
- 너무 짧으면 정상 작업 중인데 다른 인스턴스가 가로채 중복 처리 발생.
- 너무 길면 인스턴스 죽었을 때 event 처리 지연.

운영 관찰 후 `var.analysis_claim_lease_ms` 로 조정 → terraform apply.

### 3.3 `EVENT_STORE_BACKEND=prisma` + `DATABASE_URL` 미설정

Server `src/config.js:232` 가 EVENT_STORE_BACKEND 를 로드하지만, DATABASE_URL 이
비어있으면 `eventStore.js` 의 createEventStore() 가 fs fallback 으로 빠진다
(README §11). cutover 검증 단계에서 반드시 server 로그의 `store_initialized` /
`backend` 값을 확인.

---

## 4. 참고

- `terraform/variables.tf` — `event_store_backend`, `analysis_claim_lease_ms`
- `ec2-bootstrap/user-data.sh.tftpl` — `/etc/iconia.env` 주입
- `docs/scale-up-runbook.md` — ASG/ALB 일반 운영
- 2.SERVER `src/server.js:849~850` — INSTANCE_ID / CLAIM_LEASE_MS 사용처
- 2.SERVER `src/services/eventStore.js` — createEventStore 팩토리 (fs/prisma 분기)
- 2.SERVER `prisma/schema.prisma:1301` — event_store 모델 정의
