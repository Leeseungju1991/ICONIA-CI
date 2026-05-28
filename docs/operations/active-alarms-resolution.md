# Active Alarms Resolution Plan (2026-05-28 발견)

> CloudWatch 알람 점검에서 발견된 3건 active ALARM. 즉시 대응 필요.

## A-01: `iconia-server-lifecycle-finalizer-stalled` (ALARM)

**증상**: 사용자 탈퇴 후 24개월 경과 → scheduled_purge 처리하는 `lifecycle-finalizer` cron 이 멈춤.

**영향**:
- 탈퇴 사용자 데이터 보관 기간 초과 가능성 (개인정보 보호법 위반 risk)
- 신규 데이터 적체

**원인 후보**:
1. `2. SERVER/scripts/lifecycle-finalizer.js` 또는 `services/lifecycleFinalizer.js` 의 cron 미실행
2. systemd timer 누락
3. RDS 쿼리 timeout
4. 권한 부족 (S3 deletion certificate 발급 권한 등)

**즉시 조치**:
1. `journalctl -u iconia-lifecycle-finalizer.timer --no-pager | tail -30` 확인
2. 수동 실행: `cd /opt/iconia/server && sudo -u iconia node scripts/lifecycle-finalizer.js`
3. 실패 사유 분석 → fix
4. systemd timer 재기동

**Owner**: SRE + DPO (개인정보 영향)

## A-02: `iconia-server-rds-memory-low` (ALARM)

**증상**: RDS `db.t4g.medium` (4GB RAM) 의 FreeableMemory 가 임계 미만.

**영향**:
- query latency 증가
- swap 사용 → 추가 latency
- 최악의 경우 OOM 으로 RDS 재시작

**원인 후보**:
1. 시드 데이터 + index 적재 후 메모리 부족
2. 잘못된 query (full table scan) 가 buffer pool 차지
3. connection pool 의 idle connection 누적

**즉시 조치 (단기)**:
1. RDS Performance Insights 로 top SQL 확인
2. 비효율 query (full scan) index 추가
3. PostgreSQL `shared_buffers` 점검

**중기 조치**:
- `db.t4g.large` (8GB) upgrade — production 영향 + 비용 ($) 발생 → HD-06 / HD-21 결정 필요
- 또는 read replica 추가 (multi-region 스캐폴드에 이미 정의됨)

**Owner**: DevOps + DBA

## A-03: `iconia-server-redis-no-connections` (ALARM)

**증상**: Redis (ElastiCache or 별도 인스턴스) 가 연결 안 됨. server 의 `redis_connection_error` 또는 `no_connections` 메트릭 활성.

**영향**:
- rate limit 분산 backend (Redis) → 메모리 backend 로 fallback → multi-instance 시 부정확
- session 캐시 미사용 → DB 부하 증가
- pub/sub 기능 (websocket fanout 등) 비활성

**원인 후보**:
1. ElastiCache cluster 미생성 (현재 PoC 단계)
2. Security Group 규칙 부재
3. `REDIS_URL` env 미설정 → server 가 redis 비활성 모드 부팅

**즉시 조치**:
1. `/etc/iconia.server.env` 의 `REDIS_URL` 확인
2. 없으면 메모리 backend 사용 명시 — 알람 임계 조정 (warning level)
3. Multi-instance / production scale 시 ElastiCache 도입 — `terraform/` 에 스캐폴드 추가 필요

**Owner**: DevOps

## 알람 정책 점검

위 3건은 모두 `terraform/alarms.tf` 에 정의된 알람이 실 운영 데이터에 active 한 상태. 즉:
- **알람 자체는 정상 동작 중** ✓
- **알람 대응 절차 (runbook + on-call rotation) 가 부재** ✗

→ `docs/operations/incident-response-runbook.md` 의 §4 알람 임계 표 갱신 + on-call rotation 결정 (HD-19) 필요.

## 출시 차단성

| 알람 | 출시 전 필수 해결? |
|---|---|
| A-01 lifecycle-finalizer | **YES** — 개인정보 보관 위반 risk |
| A-02 rds-memory-low | **YES** — production 부하 시 OOM |
| A-03 redis-no-connections | NO — 메모리 fallback 동작 시 (단, multi-instance 전환 전 필수) |
