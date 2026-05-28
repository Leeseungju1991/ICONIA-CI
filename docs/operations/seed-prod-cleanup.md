# Production Seed Sample Data Cleanup 절차

> 출시 직전 prod RDS 의 sample seed 데이터 (batch2 의 24 users / 32 posts / 50 products 등) 를 cleanup 하기 위한 절차.

## 1. 배경

2026-05-28 라운드에서 ADMIN UI 검증 + 시연용으로 prod RDS 에 sample seed 데이터를 직접 시드함:
- users 24 (seed-1@iconia.dev ~ seed-20)
- dolls 26 (handle luna-01 ~ haessal-20)
- feedPost 32 + feedMedia 38 + feedComment 71
- product 50 (sku ICN-B2-001~020 등)

본 데이터는 **실 사용자 출시 전 반드시 cleanup** 필요 (실 사용자 혼란 + 시연 데이터 노출 차단).

## 2. Cleanup Script (안전)

```sql
-- Postgres — staging/prod RDS 에서 실행 시 반드시 사전 snapshot 후
BEGIN;

-- 1. Sample products (woo_id 20001~20020 + sku ICN-B2-*)
DELETE FROM products WHERE woo_id BETWEEN 20001 AND 20020;
DELETE FROM products WHERE sku LIKE 'ICN-B2-%';

-- 2. Sample feed (id prefix a0000004-, a0000005-, a0000006-)
DELETE FROM feed_reactions  WHERE post_id IN (SELECT id FROM feed_posts WHERE id::text LIKE 'a0000004-%');
DELETE FROM feed_comments   WHERE post_id IN (SELECT id FROM feed_posts WHERE id::text LIKE 'a0000004-%');
DELETE FROM feed_comments   WHERE id::text LIKE 'a0000006-%';
DELETE FROM feed_media      WHERE id::text LIKE 'a0000005-%';
DELETE FROM feed_posts      WHERE id::text LIKE 'a0000004-%';

-- 3. Sample dolls (id prefix a0000002-)
DELETE FROM dolls WHERE id::text LIKE 'a0000002-%';

-- 4. Sample users (id prefix a0000001-, email seed-N@iconia.dev)
DELETE FROM consent_records WHERE user_id::text LIKE 'a0000001-%';
DELETE FROM users           WHERE id::text LIKE 'a0000001-%';
DELETE FROM users           WHERE email LIKE 'seed-%@iconia.dev';

-- 검증
SELECT 'users'::text AS table, count(*) FROM users WHERE email LIKE 'seed-%@iconia.dev'
UNION ALL
SELECT 'products', count(*) FROM products WHERE sku LIKE 'ICN-B2-%'
UNION ALL
SELECT 'feed_posts', count(*) FROM feed_posts WHERE id::text LIKE 'a0000004-%';
-- 모두 0 이어야 함.

COMMIT;
```

## 3. 실행 절차 (Runbook)

### 3.1 사전 준비
1. RDS manual snapshot — `aws rds create-db-snapshot --db-instance-identifier iconia-prod-db --db-snapshot-identifier pre-sample-cleanup-$(date +%Y%m%d)`
2. snapshot 완료 확인 (5~10분)
3. 운영팀 책임자 명시적 승인 (HD-07)
4. 작업 시간 — 저트래픽 시간대 (KST 03:00~04:00)

### 3.2 실행 (SSM 또는 직접 psql)
```bash
# SSM 권장
aws ssm send-command \
  --instance-ids i-042de709f0f8f9020 \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["psql $DATABASE_URL -f /opt/iconia/server/scripts/cleanup-sample-seed.sql"]'
```

### 3.3 검증
- `prisma studio` 또는 ADMIN `dashboard/users` 페이지에서 seed user 0건 확인
- 정상 사용자 데이터 영향 없음 확인

### 3.4 사후
- audit_logs 에 cleanup 작업 기록
- snapshot 14일 보존 후 삭제

## 4. 실수 방지 가드

- 본 SQL 의 모든 DELETE 는 **명시적 ID prefix (`a0000001-` 등)** 또는 **명확한 email/sku 패턴**으로 제한
- 일반 사용자 데이터는 영향 받지 않음
- 트랜잭션 (BEGIN/COMMIT) 으로 단일 실패 시 전체 rollback

## 5. 자동화 script

`2. SERVER/scripts/cleanup-sample-seed.sql` 를 신규 작성 → SERVER 배포에 포함 → 운영자가 명시적 SSM 으로 실행.

## 6. LEGAL_REVIEW_REQUIRED (HD-07)

prod 데이터 변경 작업이므로 운영팀 책임자 사전 승인 + DPO 통지 필요.
