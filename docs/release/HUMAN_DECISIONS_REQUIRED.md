# ICONIA Human Decisions Required

이 문서는 ICONIA 7단계 엔터프라이즈 양산화 자동 작업 중, Claude Code 가 임의로 결정하면 안 되는 항목만 모은 문서다.

## Summary

- 총 결정 필요 항목: **23**
- P0 결정 항목: **9** (출시 차단)
- P1 결정 항목: **10** (출시 전 권장 해결)
- P2 결정 항목: **4** (출시 후 가능)
- 출시 전 반드시 결정해야 할 항목: **17**
- 출시 후 결정 가능 항목: **6**

## Decision Table

| ID | Priority | Category | Decision Needed | Why Human | Safe Default Applied | Impact If Not Decided | Owner | Due Before |
|---|---|---|---|---|---|---|---|---|
| HD-01 | P0 | LEGAL_APPROVAL | 이용약관·개인정보처리방침 최종 본 승인 | Claude Code 는 법률 최종 단정 금지 | 법무 검토 제출 가능한 초안 작성 (`6. CI/docs/legal/*-draft.md`) | 출시 차단 | 사내 법무, 개인정보보호책임자 | 출시 전 |
| HD-02 | P0 | PRIVACY_APPROVAL | 마케팅 동의/AI 학습 동의/위치정보 동의 항목 확정 | 개인정보보호법 + 사업 정책 결정 필요 | 동의 화면 구조 + ConsentRecord 스키마 준비 | 동의 흐름 출시 차단 | DPO | 출시 전 |
| HD-03 | P0 | CERTIFICATION_APPROVAL | KC/전파 인증 대상 여부 + 인증 진행 | 방송통신기자재 적합성평가, 전기용품 안전관리 — 전문가 판단 | 인증 체크리스트 문서화 (`docs/operations/device-certification-checklist.md`) | HW 출시 차단 | 외부 인증 전문가 | 양산 출고 전 |
| HD-04 | P0 | LEGAL_APPROVAL | 통신판매업 신고 필요 여부 (display-only 라도 향후 판매 시) | 전자상거래법 해석 | 현재 commerce=display-only 로 비신고 운영 + 향후 결제 도입 시 별도 review | 잘못 신고 시 행정 조치 | 사내 법무 | 결제 기능 추가 시 |
| HD-05 | P0 | LEGAL_APPROVAL | 위치정보사업/위치정보서비스 사업자 신고 여부 | 위치정보법 해석 — 현재 디바이스에서 GPS 사용 여부 확정 필요 | 코드 grep 결과 + 사용 시 동의 화면 초안 작성 | 출시 차단 가능 | 사내 법무 | 출시 전 |
| HD-06 | P0 | AWS_PRODUCTION_APPROVAL | production AWS 리소스 변경 (Route53/ALB/RDS/ECR) | production 영향 — Claude Code 비실행 | Terraform/k8s 스캐폴드 + dry-run 만 제공 | 배포 차단 | AWS 계정 admin | 배포 전 |
| HD-07 | P0 | DB_PRODUCTION_APPROVAL | production DB migration / seed 실행 승인 | 데이터 변조 위험 | `npx prisma migrate deploy` script + `SEED_RESET=0` 기본값 | migration 차단 | 운영팀 책임자 | 배포 전 |
| HD-08 | P0 | APP_STORE_RELEASE | App Store / Play Store 실제 제출·배포 승인 | 스토어 정책 위반 시 거절 — 사람 검토 필요 | EAS production profile + release checklist | 출시 차단 | 사업 책임자 | 출시 직전 |
| HD-09 | P0 | SECRET_REQUIRED | production 환경변수 (DB_URL, Gemini key, JWT secret, AWS access key) 실 값 | secret 은 Claude Code 가 생성·관리 불가 | `.env.example` placeholder + AWS Secrets Manager 설계 | 서버 부팅 불가 | DevOps lead | 배포 전 |
| HD-10 | P1 | BUSINESS_POLICY | 커머스 향후 실제 결제 도입 여부 (PG 연동 등) | 사업 전략 결정 | 현재는 display-only 로 lock-down | 미결정 시 backlog | CEO/PM | release 1.0 후 |
| HD-11 | P1 | COST_APPROVAL | Gemini API 월 사용 한도 (현재 free tier 만 검증됨) | 비용 사업 정책 | Tier 1 결제 활성 가이드 문서 + 알람 임계 | 베타 5명 이상 동시에 호출 시 cooldown | CFO/CTO | 베타 출시 전 |
| HD-12 | P1 | HARDWARE_HIL | HIL (Hardware-in-the-Loop) 테스트 장비 투입 여부 | 실 기기 테스트 — Claude Code 불가 | HIL test plan 작성 (`docs/testing/hw-hil-test-plan.md`) | 펌웨어 양산 품질 보장 약화 | HW lead | 양산 전 |
| HD-13 | P1 | PROVIDER_KEY_REQUIRED | 외부 모니터링 (Sentry/Datadog) 도입 결정 + key | 비용 + 개인정보 정책 | server 측 logger.js / structured logging 만 사용 | 운영 가시성 제한 | DevOps lead | 출시 전 |
| HD-14 | P1 | LEGAL_APPROVAL | AI 답변 면책/리스크 안내 문구 최종 본 | 법률 + 사용자 신뢰 | docs/legal/ai-disclosure-policy-draft.md 초안 | 사용자 오해 가능성 | 사내 법무 + PM | 출시 전 |
| HD-15 | P1 | LEGAL_APPROVAL | 미성년자 사용 정책 (성인 대상 제품임에도 본인 인증 절차 검토) | 법률 + 사업 정책 | 동의 화면에 성인 대상 명시 | 청소년보호법 리스크 | 사내 법무 + DPO | 출시 전 |
| HD-16 | P1 | LEGAL_APPROVAL | 오픈소스 라이선스 고지 화면 (전체 deps 자동 생성 + 검토) | 라이선스 정합성 | open-source-notice 생성 스크립트 | 라이선스 위반 위험 | 사내 법무 + 개발팀 | 출시 전 |
| HD-17 | P1 | PRIVACY_APPROVAL | 개인정보 보관 기간 / 자동 삭제 정책 확정 | 개인정보보호법 | data-retention-policy.md 초안 | 보관 기간 위반 | DPO | 출시 전 |
| HD-18 | P1 | LEGAL_APPROVAL | 데이터 국외이전 정책 (AWS ap-northeast-2 + Gemini 미국 region) | 개인정보보호법 + GDPR (해외 사용자 시) | cross-border-transfer-checklist.md 초안 | 국외이전 동의 누락 | 사내 법무 + DPO | 출시 전 |
| HD-19 | P1 | BUSINESS_POLICY | 운영자 퇴사 시 lifecycle (계정 회수, 토큰 revoke, 감사) | 사내 보안 정책 | docs/operations/admin-operation-policy.md 초안 | 퇴사자 권한 잔존 위험 | 보안팀 + 인사 | 출시 전 |
| HD-20 | P2 | BUSINESS_POLICY | 사용자 데이터 분석/리서치 동의 항목 추가 여부 | 사업 가치 vs 동의 부담 | 현재 미포함 — 동의 항목 추가는 ConsentScreen 확장으로 가능 | 분석 데이터 제약 | PM + DPO | release 후 |
| HD-21 | P2 | COST_APPROVAL | CloudWatch 알람/log retention 비용 한도 | AWS 비용 | 기본 7~14일 retention + 기본 알람 | 장기 로그 분석 제약 | DevOps + CFO | release 후 |
| HD-22 | P2 | BUSINESS_POLICY | 사용자 리뷰/UGC 모더레이션 인력 배치 | 운영 정책 | admin 의 reports/moderation 페이지 + auto rule | 운영 부담 증가 | 운영팀 lead | release 후 |
| HD-23 | P2 | LEGAL_APPROVAL | 향후 마케팅 메일/푸시 캠페인 별 동의 재취득 정책 | 마케팅법 | push 발송 시 audience='staff'/'beta' 기본 — 'all' 은 운영자 confirm 후 | 마케팅 확장 시 동의 갱신 부담 | DPO + 마케팅 | release 후 |

## Detail (P0)

### HD-01 — 이용약관·개인정보처리방침 최종본 승인

- **무엇**: docs/legal/terms-of-service-draft.md, docs/legal/privacy-policy-draft.md 의 본문 + 회원가입/설정 화면 노출 본문 최종 확정
- **왜 사람**: Claude Code 는 변호사가 아니며 법률 최종 효력 단정 금지
- **안전한 기본값**: 법무 검토 제출 가능한 초안 작성 + "본 문서는 초안이며 출시 전 검토·승인 필요" 명시
- **결정 안 하면**: 정보통신망법·개인정보보호법 위반으로 출시 차단
- **출시 전 필수**: ✅
- **관련 레포**: ICONIA-APP (legal screens), ICONIA-SERVER (policy version), ICONIA-ADMIN (legal page)
- **관련 파일**: `6. CI/docs/legal/`, `4. APP/src/screens/Settings/*Policy*`, `5. ADMIN/app/dashboard/legal/`
- **관련 Stage**: 3
- **권장 선택지**: 사내 법무 의뢰 → 1~2주 검토 → 최종 본 확정 → SERVER `terms` 테이블에 신규 version 발행
- **Claude Code 추천**: 사내 법무 검토 우선, 외부 위탁이 필요한 경우 한국법령정보센터 표준약관 참고
- **최종 승인 담당자**: 사내 법무 lead, 개인정보보호책임자

### HD-02 ~ HD-09 (P0)

각 항목은 Decision Table 의 7개 컬럼으로 정의되어 있으며, 상세는 관련 Stage Report 및 해당 문서 (`6. CI/docs/legal/*`, `docs/operations/device-certification-checklist.md`) 참고.

## 본 문서 운영

- 본 문서는 자동 갱신 — Stage 별로 새로운 결정 항목이 발견되면 `git-release-agent` 가 추가
- 결정 완료 항목은 `status: decided` 로 마킹 (이 문서는 row 단위로 갱신)
- Final Report (Stage 7) 에서 남은 P0/P1 결정 항목이 release readiness score 에 반영
