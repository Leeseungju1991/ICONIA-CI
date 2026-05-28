# ICONIA Human Decisions Required

이 문서는 ICONIA 7단계 엔터프라이즈 양산화 자동 작업 중, Claude Code 가 임의로 결정하면 안 되는 항목만 모은 문서다. (2026-05-28 final 갱신 — 자동 처리 가능 항목 모두 처리됨)

## Summary

- 총 결정 필요 항목: **23** (자동 처리 완료된 항목 제외)
- 핵심 출시 차단 P0: **6** (HD-01, HD-03, HD-06, HD-08, HD-09, HD-12)
- 출시 전 권장 P1: **10** (자동 처리 후 잔여 — 대부분 비용/정책 결정)
- 출시 후 가능 P2: **4**

## 핵심 6건 (P0 — 출시 직전 필수)

| ID | Priority | Decision | Owner | Status | Note |
|---|---|---|---|---|---|
| **HD-01** | P0 | 사내 법무 + DPO 가 8종 법률 docs 검토·승인 | 사내 법무 + DPO | open | 8종 모두 final review-ready 수준 — 검토만 하면 됨 |
| **HD-03** | P0 | KC 적합성평가 (BLE/Wi-Fi 기기) | 외부 인증 기관 | open | HW lead 외부 의뢰 |
| **HD-06** | P0 | production AWS 리소스 변경·배포 승인 | AWS 계정 admin | open | terraform/scripts 모두 준비됨 |
| **HD-08** | P0 | App Store / Play Store 실 제출 | 사업 책임자 | open | EAS production profile 준비됨 |
| **HD-09** | P0 | Secrets Manager 도입 + production secret 실 값 주입 | DevOps lead | open | 코드 + 설계 준비됨 |
| **HD-12** | P0 | HIL (HW-09~14, SAFE-01~10) 실 기기 테스트 | HW lead | open | test plan + 시나리오 준비됨 |

## 자동 처리 완료된 항목 (이전 P0/P1 에서 mitigated)

| 이전 ID | 항목 | 자동 처리 결과 |
|---|---|---|
| HD-14 | AI disclosure 본문 final | `docs/legal/ai-disclosure-policy.md` 본문 final 완성 |
| HD-16 | OSS license notice 자동 생성 | `scripts/generate-oss-notice.ps1` + CI workflow + 본문 reference |
| B-P0-06 | Wi-Fi password 정책 | 코드 검증 → "서버 비저장" 정책 확정 + 문서화 |
| B-P0-07 | PII 마스킹 | server + AI redact.js 검증 완료 |
| B-P1-01 | Font/asset validation | `scripts/font/validate-app-fonts.mjs` + CI |
| B-P1-07 | trigger-deploy healthcheck retry | ec2-pull-and-restart.sh retry 60s |

## 잔여 P1 (출시 전 권장 — 일부 외부 행위)

| ID | Priority | Decision | Owner | Status |
|---|---|---|---|---|
| HD-04 | P1 | 통신판매업 신고 필요 여부 (display-only 라도 확인) | 법무 | open |
| HD-05 | P1 | 위치정보사업 해당 여부 (GPS 미사용 — 잠정 비적용) | 법무 | open |
| HD-07 | P1 | production DB migration / seed 실행 승인 | 운영팀 책임자 | open |
| HD-10 | P1 | 결제 기능 향후 도입 여부 | CEO / PM | open (현재 display-only lock) |
| HD-11 | P1 | Gemini API 월 사용 한도 | CFO / CTO | open (Tier 1 결제 활성 권장) |
| HD-13 | P1 | 외부 모니터링 (Sentry/Datadog) 도입 결정 | DevOps lead | open |
| HD-15 | P1 | 미성년자 사용 정책 (본인 인증 절차 강화 여부) | 법무 + DPO | open (현재 자가 확인) |
| HD-17 | P1 | 데이터 보관 기간 정책 적정성 | DPO | docs 완성 — 검토만 |
| HD-18 | P1 | 데이터 국외이전 정책 (Gemini US) | 법무 + DPO | docs 완성 — 검토만 |
| HD-19 | P1 | 운영자 퇴사 시 lifecycle 정책 | 보안팀 + 인사 | runbook 완성 — 검토만 |

## P2 (출시 후 가능)

| ID | Decision | Owner |
|---|---|---|
| HD-20 | 분석/리서치 동의 항목 추가 여부 | PM + DPO |
| HD-21 | CloudWatch 알람/log retention 비용 한도 | DevOps + CFO |
| HD-22 | UGC 모더레이션 인력 배치 | 운영팀 lead |
| HD-23 | 향후 마케팅 캠페인 별 동의 재취득 정책 | DPO + 마케팅 |

## 본 문서 운영

- 본 문서는 자동 갱신
- 결정 완료 항목은 status `decided` + 결정 내용/일자 기록
- 출시 결재 시 본 문서의 P0 6건이 모두 `decided` 여야 함
