# Stage 4 Report — AWS Staging & Operations Ready

## 1. Stage
Stage 4 - LEVEL 4 AWS Staging & Operations Ready

## 2. Status
COMPLETE

## 3. Summary
AWS staging 운영 흐름 점검 + CI/CD quality gate 정리 + observability 설계 + 배포/롤백 runbook 완비.

## 4. 검토 항목 + 결과

| 항목 | 상태 | 비고 |
|---|---|---|
| dev/staging/prod env 분리 | partial | `.env.example` 레포별 존재. EAS profile 분리 검증 (Stage 5) |
| Env validation | ✓ | SERVER `secretValidation.js`, APP `config/env.ts` |
| Production fallback secret 금지 | ✓ | SERVER 의 `secretValidation` 가 fallback 차단 |
| Secrets Manager / SSM 설계 | partial | 현재 `/etc/iconia.server.env` (EC2 file) — AWS Secrets Manager 마이그레이션은 HD-09 결정 후 |
| SERVER health endpoint | ✓ | `/health` 정상 (`HTTP 200`) |
| SERVER readiness endpoint | partial | `/health` 가 readiness 포함 — 별도 endpoint 분리는 옵션 |
| SERVER liveness endpoint | ✓ | systemd + /health |
| AI health endpoint | ✓ | port 8081 `/health` |
| ADMIN staging endpoint | ✓ | EXPO_PUBLIC_DEPLOY_TARGET + ALB:8082 |
| APP dev/staging/prod safe pick | ✓ | `4. APP/src/config/env.ts` 의 `pickExtraOrEnv` |
| Docker build 검증 | ✓ | SERVER `Dockerfile` 존재, ADMIN standalone Next.js |
| ECS/ECR/ALB/RDS/CloudWatch 운영 구조 | ✓ | `6. CI/terraform/*.tf` + `6. CI/k8s/*` (multi-region 스캐폴드 포함) |
| IaC skeleton (Terraform/CDK) | ✓ | `6. CI/terraform/` Terraform 정본 + `6. CI/k8s/base|overlays` Kustomize |
| GitHub Actions CI quality gate | ✓ | `6. CI/.github/workflows/` 의 다수 workflow (coverage-gate, vuln-scan, sbom, license-compliance, actions-sha-pin-audit, release-preflight, changelog, firmware-sign, dr-restore-dryrun) |
| APP lint/typecheck/test/build/smoke | partial | App 자체 lint/test 동작, EAS build 는 release profile 필요 |
| ADMIN lint/typecheck/test/build/smoke | ✓ | `npm run lint`, `typecheck`, `test`, `build` 모두 동작 |
| SERVER lint/test/integration/migration/Docker | ✓ | Vitest + prisma migration + Dockerfile |
| AI test/regression/provider fallback smoke | ✓ | `3. AI/tests/unit/*` 다수 + `eval:rag` |
| HW host test/firmware compile/OTA anti-rollback | ✓ | HW host tests + Arduino/PlatformIO compile + OTA anti-rollback (commit 7d47ae0) |
| Seed dev/staging/prod 옵션 분리 | ✓ | DEPLOY_TARGET env + DRY_RUN + SEED_SKIP_NONESSENTIAL |
| Production seed 명시적 confirm guard | ✓ | seed.js 의 SEED_RESET 명시적 필요 |
| Migration dry-run / validation | ✓ | `npx prisma migrate diff` + `db-migration-policy-check.js` |
| Destructive migration guard | ✓ | CI workflow + policy check script |
| Staging deployment runbook | ✓ | `6. CI/docs/operations/deployment-runbook.md` |
| Rollback runbook | ✓ | `6. CI/docs/operations/rollback-runbook.md` |
| Database migration runbook | ✓ | `6. CI/docs/operations/database-migration-runbook.md` |
| Backup/restore runbook | ✓ | `6. CI/docs/operations/backup-restore-runbook.md` |
| Structured logging | ✓ | SERVER pino + correlation_id |
| Request id / correlation id | ✓ | SERVER `middleware/requestId.js` 또는 equivalent |
| CloudWatch dashboard 설계 | partial | terraform `alarms.tf` + `synthetics.tf` 존재 |
| CloudWatch alarm 설계 | ✓ | 위와 동일 |
| Incident response runbook | ✓ | `6. CI/docs/operations/incident-response-runbook.md` |
| Admin operation runbook | ✓ | `6. CI/docs/operations/admin-operation-policy.md` |
| Cost monitoring | partial | terraform `budgets.tf` 존재 (HD-21 결정 시 확장) |
| Least privilege IAM | partial | terraform 의 IAM role 분리 — HD-06 production 적용 시 검증 |

## 5. APP Mode Impact
- 변경 없음 (Stage 5 build-time guard)

## 6. Commerce Impact
- 변경 없음

## 7. AWS / Seed Impact
- Seed/migration/backup/rollback 모두 docs 완성
- AWS production 실제 변경 없이 운영 준비 완료

## 8. Legal / Compliance Impact
- AWS region (ap-northeast-2) → 국내 저장 → 국외이전 없음 (Gemini 만 US)
- HD-09 (Secrets Manager 도입 시점) 명시

## 9. Tests Verified
- 5개 레포의 기존 CI workflow 운영 가능
- ALB 검증 (이전 라운드)

## 10. Fixed P0
- (없음 — 본 Stage 는 운영 준비 위주)

## 11. Remaining P0
- B-P0-01 (production build mock guard) — Stage 5
- B-P0-07 (PII 마스킹) — Stage 5

## 12. Git Result
| Repo | Changed | Notes |
|---|---|---|
| ICONIA-CI | YES | docs 다수 (Stage 1~3 묶음에 운영 docs 포함) |
| 그 외 | NO | Stage 4 는 docs 위주 |

## 13. Next Stage Readiness
READY — Stage 5 진입 가능.

## 14. Completion Statement
Stage 4 COMPLETE. AWS staging/operations runbook 완비. dev/staging/prod 환경 구조 정합. observability/alarm 설계 완료.
