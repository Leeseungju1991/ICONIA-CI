# Release Decision Memo

> 작성: 2026-05-28 Stage 7 종료 시점.
> 결재 라인: CEO / CTO / CFO / 사내 법무 / DPO / HW lead / 인증 전문가

## 1. 권고

**Release Candidate 등급 (83/100)**. Production 출시는 다음 6개 결정·외부 행위 완료 후 가능.

| Item | Owner | ETA |
|---|---|---|
| HD-01 법무 검토 (privacy/terms/AI/device/commerce/OSS) | 사내 법무 + DPO | 2주 |
| HD-03 KC 적합성평가 (BLE/Wi-Fi 기기) | 외부 인증 기관 | 4~8주 |
| HD-09 Secrets Manager + production secret 주입 | DevOps lead | 1주 |
| HD-12 HIL 장비 확보 + HW-09~14 / SAFE-01~10 실시 | HW lead | 4주 |
| HD-14 AI disclosure 본문 최종 확정 | PM + 법무 | 1주 |
| HD-16 OSS license notice 자동 생성 + 앱 빌드 포함 | 개발팀 + 법무 | 1주 |

위 6개 완료 시 readiness score 90+ (Production Ready) 로 상승.

## 2. 현재까지 완성된 것

### Product 영역
- APP_MODE_1 (mock) / APP_MODE_2 (real) 정합 완료
- production build 의 mock guard 동작 검증
- 피드/커머스 AWS RDS seed → API → ADMIN/APP 표시 검증
- 결제·주문·배송·환불 0건 UI/API/문서
- 사용자 화면 (consent, account deletion, AI chat, BLE) 구현
- 인스타 톤 SNS 피드 32 posts, 미디어 38 (사진 + 비디오), 댓글 71
- 커머스 50 상품 (가격/사진/카테고리/재고/sale)
- 사용자 24명 (seed)

### Infrastructure 영역
- AWS prod RDS / EC2 / ALB / S3 / EFS / Route53 (단일 region)
- GitHub Actions CI (coverage / vuln / sbom / license / firmware-sign / dr-restore-dryrun / changelog 등 9개 workflow)
- Terraform (multi-region 스캐폴드 + alarms + budgets + canary + synthetics)
- K8s manifests (kustomize base + prod/stage overlay, 향후 ECS → EKS 전환 시)
- Docker build + standalone tar.gz + S3 + SSM Run Command 배포 흐름

### Security 영역
- JWT + Refresh token rotation
- 운영자 TOTP + backup codes + MFA enforce
- Audit logs (hash chain tamper-evident)
- PII redaction (server + AI)
- Rate limit (V1.0 다층화)
- OTA anti-rollback (commit 7d47ae0)
- Prompt injection canary token (commit 53dbf8a)
- SBOM + vuln scan + license compliance CI

### Legal / Compliance 영역
- Legal register (L-01~L-13, O-01~O-07)
- Compliance matrix (C-001~C-024)
- Data inventory (8 categories)
- Consent matrix (CN-01~CN-12)
- Security control matrix (S-001~S-030)
- Privacy policy / Terms / AI disclosure / Device connection / Commerce display 초안 (법무 검토 제출 수준)
- 데이터 보관/삭제/제3자 위탁/국외이전 정책
- Runbook: deployment, rollback, migration, backup/restore, incident response, personal data breach, data subject request, customer support, AI provider incident, OTA release, device certification, admin operation

### Testing 영역
- E2E test matrix (88 scenarios)
- Wide stress plan (20 scenarios)
- Performance baseline (목표값)
- HIL test plan (HD-12 대기)
- Stage 6 chaos / resilience scenario

## 3. 출시 후 즉시 모니터링 항목

- API error rate, p95 latency, AI fallback rate
- 운영자 audit logs 의 변조 detection
- Gemini quota 사용량
- Customer support 문의 카테고리별 통계
- 디바이스 OTA failure rate
- 개인정보 침해 사고 (R-PII alarm)

## 4. 출시 후 30일 review (필수)

- 사용자 24명 → 베타 200명 → 일반 출시 확장 전 단계별 점검
- 각 단계 후 stress 재측정 + readiness score 재산정
- 사용자 피드백 카테고리화 + P0/P1 우선순위
- Postmortem 작성 (사고 발생 시)

## 5. 결재

| Role | Approval | Date | Note |
|---|---|---|---|
| CEO | (pending) | — | 사업 risk + readiness 종합 |
| CTO | (pending) | — | 기술 readiness + HIL |
| 사내 법무 | (pending) | — | HD-01, HD-04, HD-06, HD-14, HD-18 검토 |
| DPO | (pending) | — | HD-01, HD-02, HD-17, HD-19 검토 |
| HW lead | (pending) | — | HD-03, HD-12 검토 |
| 인증 전문가 | (pending) | — | HD-03 KC 인증 |
| AWS 계정 admin | (pending) | — | HD-06, HD-09 |

각 결재자가 본 memo 와 `HUMAN_DECISIONS_REQUIRED.md` + 본 stage report 들을 검토 후 결재.
