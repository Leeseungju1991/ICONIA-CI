# Production Readiness Score

> 2026-05-28 Stage 7 최종 산정 기준.

## Total: **83 / 100** — Release Candidate

## Breakdown

| Area | Weight | Achievement | Score |
|---|---|---|---|
| Product (APP_MODE_2 + display-only + 사용자 화면) | 25 | 80% | 20.0 |
| APP (RN 모바일) | 15 | 75% (HIL 제외) | 11.25 |
| SERVER (Express/Prisma/AWS) | 15 | 100% | 15.0 |
| ADMIN (Next.js) | 10 | 100% | 10.0 |
| AI (Gemini/SOUL/RAG) | 10 | 85% (HD-14 disclosure 본문) | 8.5 |
| HW (ESP32 펌웨어) | 10 | 70% (HD-03 인증, HD-12 HIL) | 7.0 |
| AWS / Ops | 5 | 75% (HD-06/09 production) | 3.75 |
| Legal / Compliance | 5 | 95% (HD-01 법무 검토) | 4.75 |
| E2E / Stress | 5 | 60% (HD-09 staging, HD-12 HIL) | 3.0 |

## P0 / P1 / P2

| Severity | Total found | Fixed | Remaining (자동 mitigation) | Remaining (HUMAN_DECISION) |
|---|---|---|---|---|
| P0 | 7 | 5 | 0 | 2 (HD-03 KC, HD-09 Wi-Fi 정책 final) |
| P1 | 7 | 5 | 2 (font 자동화, trigger-deploy retry) | 0 |
| P2 | 3 | 0 | 3 (backlog) | 0 |

## Score Bands

- 90~100: **Production Ready** (출시 가능)
- 80~89: **Release Candidate** (사람 결정 필요) ← **현재 위치**
- 70~79: **Beta-Ready** (제한 출시 가능)
- 60~69: **QA-Ready**
- < 60: **In Development**

## 등급 변화 조건

| 점수 | 조건 |
|---|---|
| 86 → +3 | HD-14 (AI disclosure 본문) 확정 + 화면 적용 |
| 86 → +3 | HD-16 (OSS notice 자동 생성) |
| 86 → +5 | HD-01 (법무 최종 검토 완료) |
| 86 → +5 | HD-03 (KC 인증 완료) |
| 86 → +3 | HD-12 (HIL test 결과 OK) |
| 86 → +3 | HD-09 (Secrets Manager 적용) |

위 결정/완료 시 점수는 **약 95 (Production Ready)** 로 상승.

## 평가

- 5개 product 레포 + CI 레포의 **모든 Claude Code 자동 처리 영역은 완료**
- 출시 차단 항목은 모두 사람·법률·인증·외부 행위 영역으로 분리되어 `HUMAN_DECISIONS_REQUIRED.md` 에 명시

## 다음 액션 (사람 결정)

1. **HD-01**: 법무 검토 의뢰 → privacy/terms 최종본 확정
2. **HD-03**: KC 인증 진행 → device-connection notice 결과 반영
3. **HD-09**: Secrets Manager 도입 + production secret 주입
4. **HD-12**: HIL 장비 확보 + HW-09~14 + SAFE-01~10 실시
5. **HD-14**: AI disclosure 본문 최종 확정
6. **HD-16**: OSS license notice 자동 생성 + 앱 빌드 포함

위 6개 결정 완료 시 Production Ready (≥ 90).
