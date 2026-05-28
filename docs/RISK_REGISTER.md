# RISK REGISTER

| ID | Risk | Probability | Impact | Mitigation | Owner | Status |
|---|---|---|---|---|---|---|
| R-01 | production build 에 mock BLE/Wi-Fi 가 포함될 가능성 | M | High | APP_MODE_1 build-time + runtime guard (P0 차단), EAS production profile 분리 | rn-mobile | open |
| R-02 | feed/commerce 가 앱 내부 mock array 의존 | L | High | 서버 seed → API, app 내부 mock 폐기 검증 | rn-mobile + backend | open |
| R-03 | commerce UI 에 결제/주문 버튼 잔존 | M | High | 코드 grep + UI lint + Stage 7 final check | product-experience | open |
| R-04 | 법무/개인정보보호책임자 미검토 출시 | H | Critical | LEGAL_REVIEW_REQUIRED 마킹 + Final Report 차단 | legal-compliance | open |
| R-05 | KC/전파 인증 누락 | H | Critical | docs/operations/device-certification-checklist.md + 출시 차단 | hw-fw | open |
| R-06 | 통신판매업 신고 필요 여부 단정 | M | Medium | display-only 명시, 향후 판매 기능 시 별도 review | legal | open |
| R-07 | secret 값이 git 에 커밋될 가능성 | L | High | `.env*` gitignore + secret scan CI + 커밋 전 staging review | aws-infra | open |
| R-08 | production DB migration 사고 | L | High | destructive migration guard + dry-run + rollback runbook | database | open |
| R-09 | Wi-Fi password 서버 저장 여부 미확정 → privacy 영향 | M | High | 코드 grep + 명시적 정책 문서화 | hw-fw + backend | open |
| R-10 | OTA downgrade 가능 (anti-rollback 미구현) | L | High | secure version + anti-rollback enforce + OTA test | hw-fw | mitigated (V1.0 commit 7d47ae0) |
| R-11 | prompt injection 으로 AI 가 시스템 프롬프트 누출 | M | High | regression 테스트 + 입력 sanitization + canary token | persona-ai | partially mitigated |
| R-12 | 사용자 PII 가 AI 로그/메트릭에 평문 기록 | M | High | redaction middleware + audit | persona-ai + backend | open |
| R-13 | EC2 헬스체크 timing 으로 trigger-deploy rollback false-negative | M | Medium | retry interval/count 증가 + chunk 직접 검증 절차 문서화 | aws-infra | open |
| R-14 | 운영자 RBAC 우회로 admin route 접근 | L | High | middleware.ts + adminGate enforce + audit | backend + admin | mitigated |
| R-15 | seed JSON 의 schema mismatch 로 누적 rollback | M | Medium | seed.js UNKNOWN_FIELDS auto-drop + idempotent upsert | database | mitigated (commit 94a70d0) |
| R-16 | 외부 placeholder 이미지/비디오 URL 의 가용성 변동 | L | Low | 다중 source pool + S3 미러 대안 문서화 | backend | open |
| R-17 | Next.js standalone 빌드의 stale .next/cache 로 옛 코드 풀림 | M | Medium | 모든 admin build 전 `.next` 삭제 → 클린 빌드 정책 | aws-infra | mitigated (운영 절차) |
| R-18 | App store / Play store 거절 (디바이스 BLE 권한 사유) | M | High | 명확한 권한 사용 사유 + 사용자 동의 화면 + privacy manifest | rn-mobile | open |
| R-19 | 마케팅 동의 없이 푸시 발송 | M | Medium | 동의 이력 기반 segment + audit log | backend + admin | mitigated |
| R-20 | 운영자 퇴사 시 계정/토큰 회수 누락 | M | High | operator lifecycle runbook + audit | aws-infra + admin | open |
