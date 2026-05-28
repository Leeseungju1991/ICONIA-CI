# Database Migration Runbook

## 1. Prisma 기반 운영

- Schema: `2. SERVER/prisma/schema.prisma`
- Migrations: `2. SERVER/prisma/migrations/<ts>_<name>/migration.sql`
- Apply: `npx prisma migrate deploy` (production), `migrate dev` (dev)

## 2. 신규 Migration 작성 절차

### 2.1 Dev (local)

```bash
cd "2. SERVER"
npx prisma migrate dev --name <descriptive>
# - schema 변경 → migration.sql 자동 생성
# - dev DB 적용
# - prisma generate 자동
```

### 2.2 Migration 검증

- [ ] `prisma migrate diff --from-empty --to-schema-datamodel schema.prisma` 결과 검토
- [ ] DATA LOSS 위험 (column drop, type 변경) 평가
- [ ] Forward compatibility (구 코드도 작동하는지)
- [ ] Backward compatibility (이전 데이터 형식 지원)
- [ ] Performance 영향 (large table 의 index 추가 등)

### 2.3 Staging 적용

```bash
# Staging EC2 에서
npx prisma migrate deploy
# health check + smoke test
```

### 2.4 Production 적용 (HD-07 승인)

- 운영팀 책임자 명시적 승인 필요
- 작업 시간 (저트래픽 시간대 권장)
- RDS snapshot 사전 생성
- ec2-pull-and-restart 가 자동 `prisma migrate deploy` 실행

## 3. Destructive Migration 가드

CI 의 `.github/workflows` 에 `db-migration-policy-check.js` 가 다음 체크:
- 의도하지 않은 `DROP TABLE`/`DROP COLUMN` 차단
- `ALTER TYPE` 의 type 변경 차단 (또는 명시적 승인)

운영자가 의도한 destructive change 는 별도 plan + RDS snapshot + rollback 절차 작성.

## 4. Migration 실패 대응

### 4.1 적용 중 실패

- Prisma 가 자동으로 transaction rollback (단일 migration 안 의 statements 가 transactional 인 경우)
- 멀티 statement 의 일부만 적용된 경우 → 수동 SQL 로 정리
- migrate state 가 `failed` 면 `prisma migrate resolve --rolled-back <migration-name>` 또는 `--applied`

### 4.2 적용 후 문제 발견

- 위 rollback-runbook.md 참조
- 새 migration 작성 (revert 형태) + 정식 적용

## 5. Seed 운영

- `2. SERVER/prisma/seed.js` — 환경 변수 기반
- `SEED_SKIP_NONESSENTIAL=1` → users/dolls/notices/product_categories 만 시드
- `DRY_RUN=1` → 변경 없이 카운트만
- `SEED_RESET=1` → 시드 전 truncate (위험, production 금지)
- production seed 는 운영자 confirm + 명시적 작업 시간

## 6. Backup 정책

- AWS RDS automated backup: 매일 + 7일 retention
- 매주 manual snapshot: 4주 retention
- Production destructive migration 전: 별도 snapshot
- Backup 복구 절차: `docs/operations/backup-restore-runbook.md`

## 7. LEGAL_REVIEW_REQUIRED

데이터 보관 기간 + 익명화 정책은 DPO 검토 필요.
