# ICONIA Chaos / Fault Injection Test Plan (V1.0)

| 항목 | 값 |
|---|---|
| 상태 | **Accepted (1차 정본)** |
| 날짜 | 2026-05-27 |
| 적용 범위 | 테스트 환경 한정 (`DEPLOY_TARGET=local` 또는 `staging`). 운영(`prod`) 금지. |
| 관련 문서 | `deploy/aws/multi-az-failover-runbook.md`, `deploy/RUNBOOK.md` |

본 문서는 ICONIA V1.0 출시 직전 운영팀이 수행해야 하는 **장애 주입(chaos) 시나리오**의 정본이다.
3종 시나리오 — circuit breaker / DB 슬로우 쿼리 / 외부 API 502 — 를 테스트 환경에서 강제
발동시켜 system 의 회복력을 측정한다. 시나리오 정의는 cross-repo 영역이므로 실 실행은
SERVER / AI / ADMIN 의 운영자 콘솔에서 환경변수로 트리거한다.

---

## 0. 전제

- chaos 트리거는 **테스트 환경에서만**: `process.env.ICONIA_CHAOS_ENABLED == '1'` 이 필요.
  prod 코드 경로는 이 환경변수가 정의돼 있어도 무시한다 (서버 부팅 시 `env=prod` 면 강제 false).
- 본 라운드(V1.0)는 **수동 트리거 + 수동 관찰** — 자동화된 chaos engineering 플랫폼
  (AWS FIS / Gremlin / Chaos Mesh) 도입은 V1.x 라운드.
- 모든 chaos 실행은 사전 슬랙 공유 + 종료 후 short post-mortem 필수.

---

## 1. 시나리오 — circuit breaker 강제 발동

**대상**: SERVER 의 `personaClient` (AI 호출), `geminiClient` (외부 LLM).

**가설**: 외부 의존성이 5xx 다발 시 circuit breaker 가 OPEN → 일정 시간 fail-fast → HALF_OPEN
시도 → 회복 시 CLOSED 로 자동 복귀.

**트리거**:

```bash
# SERVER 운영자 콘솔 (테스트 환경)
export ICONIA_CHAOS_ENABLED=1
export ICONIA_CHAOS_PERSONA_502_RATE=1.0    # 100% 502 응답.
# 또는 personaClient 가 mock 으로 동작 — fail rate 강제.
systemctl restart iconia-server
```

**관찰 지표**:

| 지표 | 기대값 |
|---|---|
| `aiHealthTracker.circuitState` | `CLOSED` → `OPEN` (~10초) → `HALF_OPEN` (~30s) |
| Server `/v1/persona/respond` p95 | OPEN 동안 fail-fast 50ms 이하 (외부 호출 안 함) |
| Sentry `circuit_open` 이벤트 | 1건 이상 |
| CloudWatch `ICONIA/Server.AiCircuitOpenCount` metric | > 0 |
| 사용자 응답 | in-character fallback ("내가 지금 좀 멍해") 반환 |

**복구 검증**:

```bash
unset ICONIA_CHAOS_PERSONA_502_RATE
systemctl restart iconia-server
# CB 가 자동으로 CLOSED 로 돌아가는지 30~60초 안에 확인.
```

---

## 2. 시나리오 — DB 슬로우 쿼리 주입

**대상**: RDS PostgreSQL — Server 의 read query 가 느려진 상태.

**가설**: 슬로우 쿼리가 connection pool 을 점유 → 대기 큐 누적 → 일정 임계 초과 시
load shed (503 응답) → 알람 발사.

**트리거**:

```sql
-- prisma 마이그레이션 X. 운영자 콘솔 (psql staging) 에서 명시 실행.
-- 슬로우 클론 함수 등록.
CREATE OR REPLACE FUNCTION chaos_slow_query() RETURNS void AS $$
BEGIN
  PERFORM pg_sleep(2);  -- 2초 sleep.
END;
$$ LANGUAGE plpgsql;

-- 테스트 트래픽 발생.
SELECT chaos_slow_query() FROM generate_series(1, 50);
```

또는 server 측에서:

```bash
export ICONIA_CHAOS_DB_SLOW_MS=2000  # 모든 prisma 호출에 2000ms 지연 (인터셉터).
systemctl restart iconia-server
```

**관찰 지표**:

| 지표 | 기대값 |
|---|---|
| RDS `DatabaseConnections` | 평소 < 20 → 80 이상 (pool 점유) |
| ALB `TargetResponseTime` p95 | 평소 < 200ms → > 2000ms |
| CloudWatch alarm `iconia-server-slo-p95-latency-high` | trip (5분) |
| Server log `slow query` | 다수 발생 |
| Server 응답 | 일부 503 (load shed) — 모든 요청 200 이면 안전마진 부족 |

**복구**:

```bash
unset ICONIA_CHAOS_DB_SLOW_MS
DROP FUNCTION chaos_slow_query();
systemctl restart iconia-server
```

---

## 3. 시나리오 — 외부 API 502 주입

**대상**: Gemini (AI 호출), Apple/Google push provider, Sentry ingest.

**가설**: 외부 API 가 502/503 다발 → retry policy 가 backoff 적용 → 일정 횟수 초과 시
fail-fast → 본 application 은 자체 fallback 응답 + 알람.

**트리거** (toxiproxy / mitmproxy 활용):

```bash
# toxiproxy 로 generativelanguage.googleapis.com 의 5% 만 502 로 변환.
toxiproxy-cli create gemini -l 127.0.0.1:18080 -u generativelanguage.googleapis.com:443
toxiproxy-cli toxic add gemini -t latency -a latency=2000   # 2s 지연.
toxiproxy-cli toxic add gemini -t bandwidth -a rate=1       # 1 byte/s — 사실상 timeout.

# 또는 AI 서비스에 mock 5xx 주입.
export ICONIA_CHAOS_GEMINI_5XX_RATE=0.3  # 30% 5xx.
systemctl restart iconia-ai
```

**관찰 지표**:

| 지표 | 기대값 |
|---|---|
| `ICONIA/AI.GeminiUpstream5xxCount` | > 0 |
| AI `/v1/persona/respond` 응답 | 일부 fallback 응답 (script 캐시) |
| SERVER → AI 통신 의 `aiHealthTracker.errorRate` | > 30% 도달 시 CB OPEN |
| Sentry 이벤트 | `gemini_upstream_5xx` |
| 알람 | `iconia-ai-gemini-5xx-rate-high` (V1.x 추가 예정) |

**복구**:

```bash
unset ICONIA_CHAOS_GEMINI_5XX_RATE
toxiproxy-cli delete gemini
systemctl restart iconia-ai
```

---

## 4. 측정 / 보고 양식

각 시나리오 종료 후:

```markdown
# Chaos Test YYYY-MM-DD: <시나리오 이름>

## 실행 정보
- 실행자  : <이름>
- 환경    : staging / local
- 트리거  : <환경변수 / toxiproxy 명령>
- 지속    : <시작 ~ 종료>

## 관찰
- (지표별 실측값 + 스크린샷)

## 검증
- [ ] CB 자동 OPEN/CLOSED
- [ ] 알람 정상 trip
- [ ] 사용자 응답이 graceful (5xx 누수 없음)
- [ ] 복구 30분 이내

## 액션 아이템
- [ ] (있다면) 알람 임계 조정
- [ ] (있다면) fallback 메시지 보완
- [ ] (있다면) RUNBOOK §X 단계 추가
```

---

## 5. V1.x 로드맵

- **AWS FIS (Fault Injection Simulator)** 도입 — `aws fis create-experiment-template` 으로
  EC2 / RDS / Network 장애를 IaC 로 정의.
- **chaos schedule** — 분기 1회 자동 chaos 실행 (테스트 환경 + 운영 관찰자 present).
- **GameDay 매트릭스** — 시나리오 8종 (위 3종 + EFS / Redis / S3 / 인증서 만료 / DNS 회귀).
- **MTTR / MTBF 메트릭** — chaos 통해 측정한 RTO / RPO 를 정량화 → 분기 보고.

---

## 6. 변경 이력

| 날짜 | 변경 | 작성자 |
|---|---|---|
| 2026-05-27 | V1.0 초기 정본 — 3종 시나리오 + 보고 양식 | (주)숨코리아 운영팀 |
