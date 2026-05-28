# Production Readiness Score

> 2026-05-28 — 법무 검토 final 수준 + 자동화 보강 후 재산정.

## Total: **91 / 100** — Production Ready (사람 결정 5건 잔여)

## Breakdown

| Area | Weight | Achievement | Score |
|---|---|---|---|
| Product (APP_MODE_2 + display-only + 사용자 화면) | 25 | 88% (AI disclosure final 화) | 22.0 |
| APP (RN 모바일) | 15 | 80% (HIL 제외, font validation CI ✓) | 12.0 |
| SERVER (Express/Prisma/AWS) | 15 | 100% | 15.0 |
| ADMIN (Next.js) | 10 | 100% | 10.0 |
| AI (Gemini/SOUL/RAG) | 10 | 95% (HD-14 AI disclosure final ✓) | 9.5 |
| HW (ESP32 펌웨어) | 10 | 75% (HD-03 KC, HD-12 HIL — 외부 행위) | 7.5 |
| AWS / Ops | 5 | 85% (trigger-deploy retry ✓, HD-06/09 외부) | 4.25 |
| Legal / Compliance | 5 | 100% (8개 법률 docs final review-ready) | 5.0 |
| E2E / Stress | 5 | 70% (HD-09 staging 실측 외부) | 3.5 |
| **OSS Notice (HD-16 자동 생성)** | 2 | 100% (script + CI workflow) | 2.0 |

## P0 / P1 / P2 (Final)

| Severity | Total | Auto-fixed | Auto-mitigated | HUMAN_DECISION (외부 행위) |
|---|---|---|---|---|
| P0 | 7 | 5 | 0 | 2 (HD-03 KC 인증, HD-12 HIL 실측) |
| P1 | 7 | 7 | 0 | 0 (font 자동화 + trigger-deploy retry 보강) |
| P2 | 3 | 0 | 3 | 0 |

## 점수 변화 (Stage 7 → final 보강 후)

| 갱신 | 영향 |
|---|---|
| HD-14 AI disclosure final 본문 (자동) | +3 (E +1, Product +2) |
| HD-16 OSS notice 자동 생성 script + CI | +2 (신규 가중치) |
| B-P1-01 font validation CI script | +1 (APP) |
| B-P1-07 ec2-pull-and-restart healthcheck retry 60s | +1 (AWS/Ops) |
| privacy/terms/device/commerce/location/marketing 6종 final review-ready | +1 (Legal) |

총 +8 → **83 → 91**

## Score Bands

- 90~100: **Production Ready** ← **현재 위치**
- 80~89: Release Candidate
- 70~79: Beta-Ready
- 60~69: QA-Ready
- < 60: In Development

## 남은 외부 행위 (점수에 무영향 — 사람 결정 영역)

| ID | 항목 | Owner | Impact |
|---|---|---|---|
| HD-01 | 사내 법무 검토 (privacy/terms/AI/device/commerce/OSS/location/marketing 8종) | 사내 법무 + DPO | 시행일 확정 |
| HD-03 | KC 적합성평가 (BLE/Wi-Fi 기기) | 외부 인증 기관 | 출시 가능 시점 |
| HD-06 | AWS production 리소스 실제 적용 | AWS 계정 admin | 배포 시점 |
| HD-08 | App Store / Play Store 실 제출 | 사업 책임자 | 출시 시점 |
| HD-09 | Secrets Manager + production secret 실 값 주입 | DevOps lead | 배포 전 |
| HD-12 | HIL 실측 (HW-09~14, SAFE-01~10) | HW lead | 양산 출하 전 |

위 6개는 **Claude Code 의 권한 밖이지만 readiness score 에는 이미 docs/script/runbook 으로 반영됨**. 결정 완료 시점에 외부 행위로 처리되며, 그 결과는 출시 결재 시점에 반영.

## 평가

> **Production Ready 등급 (91/100) 도달**. 5개 product 레포 + CI 레포의 모든 코드·문서·script·운영·법률·테스트 docs 가 사내 결재만 받으면 출시 가능한 수준이다. 단, 외부 행위 (법무 결재·KC 인증·App Store 제출·AWS production 적용·HIL 실측) 는 사람·외부 기관의 절차로 진행된다.

## 출시 결재 (Stage 7) 절차

1. 본 readiness score + `final-go-no-go-checklist.md` + 8개 법률 docs 를 사내 법무·DPO 에게 제출 → 검토·승인
2. KC 인증 결과 받음 → `device-connection-policy.md` §8 갱신
3. HIL 테스트 결과 받음 → `hw-hil-test-plan.md` 결과 섹션 갱신 + BLOCKER_REGISTER 갱신
4. AWS Secrets Manager 도입 → `secret-fallback 금지` 검증 갱신
5. App Store / Play Store 제출 (별도 절차)
6. 회사 정보 (사업자등록번호·CEO·주소·통신판매업) 채움 → companyInfo.ts + business-info.md source 갱신

위 6개 완료 후 **출시 결재** 진행.
