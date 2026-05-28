# Operational Hardening — 잔여 P1/P2 처리 plan

> 본 docs 는 MEDIA-EXT / RATE-DIST / POOL-FIXED / OPERATOR-LIFECYCLE 의 처리 plan.

## MEDIA-EXT: 외부 placeholder 이미지/비디오 의존 → S3 mirror 가이드

### 현재 상태
- 피드 사진: `https://picsum.photos/id/{id}/1080/1080`
- 피드 비디오: `https://test-videos.co.uk/vids/...mp4`
- 커머스 사진: `https://picsum.photos/id/{id}/800/800`

외부 사이트 가용성 변동 시 사용자 앱에서 사진/비디오 깨짐.

### 처리 plan (출시 전 권장)
1. **placeholder asset 을 S3 로 mirror**:
   ```bash
   # 일회성 mirror
   for i in $(seq 100 1099); do
     curl -L -o "/tmp/picsum-$i.jpg" "https://picsum.photos/id/$i/1080/1080"
     aws s3 cp "/tmp/picsum-$i.jpg" "s3://iconia-prod-events-022671037305/placeholder/picsum/$i.jpg"
   done
   ```
2. seed JSON 의 URL 을 S3 CloudFront 도메인으로 갱신:
   ```
   https://picsum.photos/id/N/1080/1080
   → https://cdn.iconia.dollsoom.com/placeholder/picsum/N.jpg
   ```
3. `_generate-batch2.mjs` + `_generate-products-batch2.mjs` 수정 후 재시드

### 출시 후 실 콘텐츠 전환
사용자가 직접 업로드한 실 사진/비디오로 대체되면 본 placeholder 는 archived feed 만 사용. 점진적 제거.

## RATE-DIST: rate limit multi-instance 검증 plan

### 현재 상태
- `2. SERVER/src/middleware/rateLimit.js` 가 V1.0 다층화 강화됨
- 단일 EC2 instance — 메모리 backend
- multi-AZ / ASG 전환 시 Redis backend 필요

### 처리 plan
1. **현재**: `REDIS_URL` 환경변수 부재 시 메모리 backend (graceful) — `2. SERVER/src/middleware/rateLimit.js:initRedis()` 참조
2. **multi-instance 전환 시**:
   - ElastiCache (Redis) cluster 생성 — `6. CI/terraform/elasticache.tf` (신규)
   - Security Group 규칙 (EC2 → Redis :6379)
   - `/etc/iconia.server.env` 에 `REDIS_URL=rediss://...` 추가
   - server 재시작 → 자동 Redis backend 활성
3. **분산 환경 검증**:
   - Stage 6 wide stress (ST-08: rate limit) 에서 multi-instance 시뮬레이션
   - 각 instance 가 동일 사용자에 대해 일관된 카운트 유지 검증

### 알람 A-03 와 연계
현재 `iconia-server-redis-no-connections` ALARM 상태 — multi-instance 전환 전 필수 해결.

## POOL-FIXED: DB connection pool

### 현재 상태
- `2. SERVER` 의 Prisma client default pool — `DATABASE_URL?connection_limit=20` (env-driven)
- 트래픽 증가 시 부족 가능
- 알람 A-02 (`rds-memory-low`) 와 연계 — pool 크기 증가는 RDS 메모리 부담

### 처리 plan
1. **현재**: env `DATABASE_URL` 의 query string `?connection_limit=20` 명시 (없으면 default 10)
2. **모니터링**: CloudWatch metric `DatabaseConnections` watch + alarm 임계 ≥ 80%
3. **수평 확장**: ASG instance 추가 → 각 instance pool 분산
4. **수직 확장**: RDS instance class upgrade (`db.t4g.medium` → `db.t4g.large`) 시 pool size 도 비례 증가

### 권장 설정 (production)
```
DATABASE_URL=postgresql://...?connection_limit=20&pool_timeout=10&connect_timeout=5
```

## OPERATOR-LIFECYCLE: 운영자 퇴사 시 lifecycle 자동화

### 현재 상태
- `docs/operations/admin-operation-policy.md` §3 의 퇴사 절차 — runbook 만, 수동 절차

### 자동화 plan
1. **신규 admin endpoint**: `POST /api/v1/admin/operators/:id/offboard`
   - 운영자 비활성화 (`operators.status = 'inactive'`)
   - 모든 refresh token revoke
   - TOTP secret 폐기
   - audit_log 기록
2. **신규 ADMIN UI**: `dashboard/operators/:id` 에 [퇴사 처리] 버튼 (superadmin 만)
3. **자동 cron**: 매일 운영자 미접속 ≥ 90일 자동 알림 → secops 검토

### 구현 우선순위
P1 — Stage 5 docs 작성 + Stage 7 결재 항목. 실제 코드는 다음 SERVER round 에 구현.

## MIGRATE-01: rollback plan 보강

### 현재 상태
- `docs/operations/rollback-runbook.md` + `docs/operations/database-migration-runbook.md` 존재
- 신규 migration 시 RDS snapshot 의무는 docs 만

### 자동화 plan
1. **`prisma migrate deploy` wrapper** — `6. CI/scripts/safe-migrate-deploy.sh` 신규:
   ```bash
   set -euo pipefail
   SNAP_ID="pre-migrate-$(date +%Y%m%dT%H%M%SZ)"
   aws rds create-db-snapshot --db-instance-identifier iconia-prod-db --db-snapshot-identifier "$SNAP_ID"
   aws rds wait db-snapshot-completed --db-snapshot-identifier "$SNAP_ID"
   cd /opt/iconia/server
   sudo -u iconia npx prisma migrate deploy
   echo "Snapshot: $SNAP_ID — rollback 시 사용"
   ```
2. **ec2-pull-and-restart.sh 통합** — server 배포 중 자동 snapshot
3. **CI gate** — release tag 시 destructive migration 감지 → 수동 승인 필요
