# BLOCKER REGISTER

> P0/P1/P2 분류는 Stage 별 자동 점검에서 갱신된다.

## P0 (출시 차단)

| ID | Description | Repo(s) | Found At | Fix Plan | Status |
|---|---|---|---|---|---|
| B-P0-01 | production build 에 APP_MODE_1_MOCK_CONNECTIVITY 가 활성 가능 | APP | Stage 0 | build-time + runtime guard, EAS production profile 분리 | open |
| B-P0-02 | 커머스 UI 에 결제/주문 문구 미점검 | APP, ADMIN | Stage 0 | grep + lint + Stage 5 final check | open |
| B-P0-03 | 사용자 동의 이력 저장 구조 미확정 | SERVER | Stage 0 | Stage 3 ConsentRecord 스키마/이벤트 로깅 강화 | partially (스키마 존재) |
| B-P0-04 | 회원 탈퇴/삭제 요청 경로 검증 미수행 | APP, SERVER | Stage 0 | adminPipaRoutes + App ReconsentModal/Delete UX | partially |
| B-P0-05 | KC/전파 인증 검토 docs 미작성 | HW | Stage 0 | Stage 3 docs/operations/device-certification-checklist.md | open |
| B-P0-06 | Wi-Fi password 서버 저장 여부 결정/문서화 | HW, SERVER | Stage 0 | Stage 2 코드 grep + Stage 3 정책 문서 | open |
| B-P0-07 | production 로그 PII 마스킹 검증 미수행 | SERVER, AI | Stage 0 | redact middleware + audit log review | partially mitigated (server 측 redact.js 존재) |

## P1 (release candidate 전 권장 해결)

| ID | Description | Repo(s) | Found At | Fix Plan | Status |
|---|---|---|---|---|---|
| B-P1-01 | font/asset 정합성 검증 자동화 부재 | APP | Stage 0 | Stage 1 expo doctor + font validation script | open |
| B-P1-02 | seed dry-run 옵션 미정형 | SERVER | Stage 0 | Stage 1 `node prisma/seed.js --dry-run` + DRY_RUN env | mitigated (DRY_RUN=1 존재) |
| B-P1-03 | E2E test matrix 문서 부재 | ALL | Stage 0 | Stage 6 docs/testing/e2e-test-matrix.md | open |
| B-P1-04 | performance baseline 미측정 | SERVER, AI | Stage 0 | Stage 6 measurement | open |
| B-P1-05 | HIL test plan 부재 | HW | Stage 0 | Stage 6 hw-hil-test-plan.md | open |
| B-P1-06 | 운영자 퇴사 시 lifecycle runbook | ADMIN, SERVER | Stage 0 | Stage 4 admin-operation-policy.md | open |
| B-P1-07 | trigger-deploy healthcheck retry 부족 | CI | Recent | retry 회수/간격 늘리고 standalone swap fallback 추가 | open |

## P2 (출시 후 개선)

| ID | Description | Repo(s) | Found At | Fix Plan | Status |
|---|---|---|---|---|---|
| B-P2-01 | 코드 중복 정리 (admin 의 user-360/cs 패턴) | ADMIN | Stage 0 | refactor backlog | open |
| B-P2-02 | 비용 모니터링 dashboard 강화 | CI | Stage 0 | CloudWatch + AWS Cost Explorer 자동화 | open |
| B-P2-03 | Next.js 14.2.18 보안 업데이트 | ADMIN | recent log | bump 14.2.32+ | open |

## 신규 발견 (2026-05-28 — CloudWatch active alarms)

| ID | Severity | Description | Repo(s) | Fix Plan | Status |
|---|---|---|---|---|---|
| B-P0-08 | P0 | `iconia-server-lifecycle-finalizer-stalled` 알람 ACTIVE — 사용자 탈퇴 24개월 후 폐기 cron 정지 (개인정보 보호법 위반 risk) | SERVER | `docs/operations/active-alarms-resolution.md` A-01 | open |
| B-P0-09 | P0 | `iconia-server-rds-memory-low` 알람 ACTIVE — RDS t4g.medium (4GB) 메모리 부족 | SERVER + AWS | A-02 절차 — Performance Insights → query 최적화 또는 t4g.large upgrade | open |
| B-P1-08 | P1 | `iconia-server-redis-no-connections` 알람 ACTIVE — Redis backend 없음, multi-instance 시 rate limit 부정확 | SERVER + AWS | A-03 절차 — ElastiCache 도입 or 알람 임계 조정 | open |

## 자동 처리 완료 (2026-05-28 라운드 — 법무 제외 11건)

| ID | Description | Resolution |
|---|---|---|
| PRE-01 | preflight-placeholders 가 build-and-upload 에서 호출 안 됨 | build-and-upload.ps1 에 통합 (warning mode, `REQUIRE_PREFLIGHT=1` 시 차단) |
| EMAIL-01 | companyInfo.ts ↔ business-info.md 이메일 도메인 불일치 | companyInfo.ts `dollsoom.com` 으로 통일 + 법률 docs 8종 일괄 patch |
| DEPLOY-01 | ec2-pull-and-restart.sh healthcheck retry 부족 (10회/20s) | 30회/60s 로 보강 + S3 업로드 + SSM 으로 EC2 `/usr/local/bin/` 직접 갱신 |
| DEPLOY-02 | ADMIN .next stale cache | build-and-upload.ps1 의 admin 빌드 전 자동 삭제 |
| SEED-FAIL | legacy seed JSON 의 schema mismatch (hw_device_id, items, hashtags) | dolls.json / orders.json / feed_posts.json 직접 정리 |
| OSS-AUTO | OSS notice 자동 생성 미실행 | generate-oss-notice.ps1 실행 → 4 레포 licenses-*.json + open-source-notice-generated.md (100KB+) |
| STRESS-TEST | pytest 실행 검증 안 됨 | 22/22 passed |
| MIGRATE-01 | rollback plan 없는 prisma migrate | `safe-migrate-deploy.sh` 신규 — RDS snapshot 자동 생성 |
| SEED-PROD | prod RDS sample seed cleanup 절차 없음 | `cleanup-sample-seed.sql` + `seed-prod-cleanup.md` |
| MEDIA-EXT | 외부 placeholder URL 의존 | `operational-hardening.md` 의 S3 mirror 가이드 |
| RATE-DIST + POOL-FIXED + OPERATOR-LIFECYCLE | rate limit multi-instance / DB pool / 퇴사 자동화 | `operational-hardening.md` plan |
| CLAUDE-MD | 5 레포 + CI 운영 규칙 갱신 | 루트 CLAUDE.md 운영 규칙 섹션 추가 |
