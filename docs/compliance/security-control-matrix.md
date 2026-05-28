# Security Control Matrix

> ICONIA 의 보안 통제 항목 ↔ 코드/문서/증적.

| Control ID | Control | Implementation | Evidence | Status |
|---|---|---|---|---|
| S-001 | TLS 1.2+ HTTPS 전송 | ALB + ACM (HD-06 확정 후) + Express helmet | ALB listener config | partially (현재 ALB:80/:8082 HTTP) |
| S-002 | 비밀번호 단방향 해시 | bcrypt (`2. SERVER/src/services/authService.js`) | password_hash column | implemented |
| S-003 | JWT 서명 (HS256) | `2. SERVER/src/utils/jwt.js` | JWT_SECRET env | implemented |
| S-004 | Refresh token rotation | `RefreshTokenFamily` 모델 + revoke | DB row | implemented |
| S-005 | 운영자 MFA (TOTP) | `2. SERVER/src/services/operatorMfaService.js` + backup codes | DB column + ADMIN UI | implemented |
| S-006 | IP allowlist (선택) | `2. SERVER/src/middleware/ipAllowlist.js` | env config | implemented |
| S-007 | Rate limit (다층화) | `2. SERVER/src/middleware/rateLimit.js` (메모리 + redis) | 응답 헤더 | implemented |
| S-008 | Input validation (zod) | 라우트별 schema 검증 | zod parse | implemented |
| S-009 | Audit log (hash chain) | `audit_logs` table + tamper-evident hash | DB row + chain verify | implemented |
| S-010 | PII redaction (log) | `2. SERVER/src/utils/redact.js`, `3. AI/src/utils/redact.js` | log review | implemented |
| S-011 | Secrets Manager 사용 | env loading + (HD-09 production 시) AWS Secrets Manager | `.env.example` placeholders | partially (현재 EC2 env file) |
| S-012 | IAM 최소권한 | (HD-06 확정 후) 운영 IAM role 분리 | IAM policy | draft |
| S-013 | OTA anti-rollback | HW `iconia_config.h` SECURE_VERSION + 서명 검증 | firmware deployment audit | implemented (commit 7d47ae0) |
| S-014 | OTA 펌웨어 서명 검증 | HW + SERVER firmware-sign.yml | signature audit | implemented |
| S-015 | 운영자 세션 timeout | `operator_sessions` + middleware | session config | implemented |
| S-016 | CSP / XSS 방어 | ADMIN next.config.mjs + helmet | response header | implemented |
| S-017 | CSRF 방어 | SameSite cookie + same-origin | cookie config | implemented |
| S-018 | SQL injection 방어 | Prisma ORM (parameterized) | code review | implemented |
| S-019 | Prompt injection 방어 | AI canary token + sanitization | regression test | implemented |
| S-020 | 디바이스 페어링 인증 | HMAC pairing token (`4. APP/src/ble/pairHmac.ts`) | code review | implemented |
| S-021 | Wi-Fi 비밀번호 서버 비저장 | 코드 검증 — HD-09 | grep + 코드 리뷰 | partially (확정 필요) |
| S-022 | 백업·복구 (RDS) | AWS RDS automated backup + manual snapshot | RDS console + runbook | partially (runbook draft) |
| S-023 | 침해사고 대응 절차 | `docs/operations/personal-data-breach-runbook.md` | runbook | draft |
| S-024 | Dependency vulnerability scan | CI `.github/workflows/vuln-scan.yml` | CI run log | implemented |
| S-025 | SBOM (Software Bill of Materials) | CI `.github/workflows/sbom.yml` | artifact | implemented |
| S-026 | License compliance scan | CI `.github/workflows/license-compliance.yml` | CI run log | implemented |
| S-027 | Secret scan (CI) | CI 추가 필요 — Stage 5 | — | open |
| S-028 | Production mock 차단 | APP runtime guard (Stage 5) | runtime check | open |
| S-029 | Production debug flag 차단 | APP + HW production macro | code review | open |
| S-030 | 운영자 lifecycle (퇴사 시 회수) | `docs/operations/admin-operation-policy.md` + adminUserRoutes | runbook | draft |

## Status Legend
- **implemented**: 코드/문서 완비
- **partially**: 일부 구현 — Stage 별 보강
- **draft**: 문서만 존재
- **open**: 미구현

## Stage 매핑
- Stage 4: S-001 TLS (ACM 결정 후), S-011 Secrets Manager, S-012 IAM
- Stage 5: S-021 Wi-Fi password 검증, S-027 secret scan CI, S-028 production mock 차단, S-029 debug flag 차단
- Stage 6: 전체 control 의 E2E 검증
- Stage 7: 모든 control implemented 확인
