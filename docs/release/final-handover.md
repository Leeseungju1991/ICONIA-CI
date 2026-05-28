# Final Handover Document

> ICONIA 7단계 엔터프라이즈 양산화 완료 시점에 운영팀·법무·인증 전문가에게 인계.

## 1. 인계 대상

| 인계 받는 분 | 영역 | 핵심 docs |
|---|---|---|
| 운영팀 lead | 배포·롤백·인시던트·OTA | `docs/operations/*` |
| DPO | 동의 이력·삭제 요청·데이터 보관 | `docs/compliance/*`, `docs/legal/privacy-policy-draft.md` |
| 사내 법무 | 약관·AI disclosure·국외이전 | `docs/legal/*` |
| HW lead + 인증 전문가 | KC 인증·HIL 테스트 | `docs/operations/device-certification-checklist.md`, `docs/testing/hw-hil-test-plan.md` |
| DevOps lead | AWS Secrets Manager·IAM·CloudWatch | `docs/operations/deployment-runbook.md`, terraform/ |
| 보안팀 | 침해사고·운영자 권한·secret 관리 | `docs/operations/personal-data-breach-runbook.md`, `docs/operations/admin-operation-policy.md` |
| CS lead | 고객 응대 · FAQ · 모더레이션 | `docs/operations/customer-support-runbook.md` |
| App store 담당 | 심사 자료 + EAS 빌드 | `docs/release/app-release-checklist.md` (아래 7번) |

## 2. 운영 시작 시 첫 100시간 체크리스트

### 0~24시간
- [ ] 운영팀 입사 / MFA 등록 / IP allowlist 등록
- [ ] CloudWatch dashboard 모니터링 시작
- [ ] Slack `#alerts` 채널 onboarding
- [ ] On-call rotation 시작

### 24~72시간
- [ ] 첫 사용자 가입 모니터링
- [ ] AI provider 응답 latency 실시간 추적
- [ ] 디바이스 페어링 성공률 추적

### 72~168시간 (1주)
- [ ] 첫 정기 backup 검증
- [ ] 첫 OTA 배포 시뮬레이션
- [ ] Customer support 첫 사례 처리

## 3. 핵심 정책 요지 (인계 시 반드시 안내)

1. **production 에 mock connectivity 불가** — 위반 시 P0
2. **결제·주문·배송 기능 활성화 금지** (display-only)
3. **법률 문구 임의 변경 금지** — 법무 검토 후만
4. **개인정보 접근 시 audit log 자동 기록** (5년 보관)
5. **운영자 퇴사 시 lifecycle runbook 준수**
6. **production AWS / DB 변경은 명시적 승인 필수** (HD-06/07)
7. **OTA 펌웨어는 anti-rollback** — secure version 강제
8. **AI 응답 부적절 신고 시 24시간 내 검토**
9. **개인정보 침해 사고 시 72시간 내 조치 + 사용자 통지**
10. **위탁/제3자 변경 시 사전 사용자 고지 + 재동의 (해당 시)**

## 4. 알려진 한계 (출시 전 사람 결정 대기 — HUMAN_DECISIONS_REQUIRED.md)

| ID | 내용 | 영향 |
|---|---|---|
| HD-01 | 법무 최종 검토 | privacy/terms 시행일 |
| HD-03 | KC 인증 | HW 출시 차단 |
| HD-09 | Secrets Manager | 운영 보안 강화 |
| HD-12 | HIL 테스트 | 양산 품질 |
| HD-14 | AI disclosure 본문 | 사용자 안내 |
| HD-16 | OSS notice 자동 생성 | 라이선스 의무 |

위 6개 결정 완료 시 production ready (score 90+).

## 5. 코드 / 인프라 자산

| 자산 | 위치 |
|---|---|
| 5개 product 레포 | https://github.com/Leeseungju1991/ICONIA-{APP,SERVER,ADMIN,AI,HW} |
| CI 레포 | https://github.com/Leeseungju1991/ICONIA-CI |
| AWS 계정 | 022671037305 (ap-northeast-2) |
| EC2 instance | i-042de709f0f8f9020 |
| RDS | iconia-prod-db.c3m6c8wi816o.ap-northeast-2.rds.amazonaws.com |
| ALB | iconia-prod-alb-1600486872.ap-northeast-2.elb.amazonaws.com |
| S3 buckets | iconia-prod-{artifacts,events,exports,firmware}-022671037305 |

## 6. 운영 인사이트

- **Gemini 키 풀**: 현재 free tier — 베타 5명 이상 동시 채팅 시 cooldown 시작. Tier 1 결제 활성 시 100배 한도 (HD-11)
- **EC2 단일 instance**: 현재 PoC 단계. 사용자 증가 시 ASG / multi-AZ / multi-region 검토 (terraform/multi-region/ 스캐폴드 존재)
- **ADMIN .next stale cache 주의**: 배포 시 반드시 `rm -rf .next` 후 빌드
- **trigger-deploy healthcheck false-negative**: 가끔 발생 — chunk 직접 검증 절차로 우회

## 7. 출시 전 마지막 체크 (App Store / Play Store)

별도 `docs/release/app-release-checklist.md` 작성 (Stage 7 의 향후 작업):

- iOS Privacy manifest (Apple ATT)
- Android Data Safety form (Google Play)
- 화면 캡처 + 마케팅 이미지
- 연령 등급 (성인 대상 — 17+/18+)
- IDFA 사용 여부 명시 (현재 비사용)
- 외부 결제 안내 (앱 외부 채널 — Apple/Google 의 in-app payment 정책 회피)

## 8. 연락처 (HD-01 확정 필요)

- DPO: [pending]
- 보안 lead: [pending]
- 운영팀 lead: [pending]
- 외부 자문 변호사: [pending]
- KC 인증 전문가: [pending]
- AWS 계정 admin: [pending]

## 9. 인계 완료 조건

- [ ] 운영팀이 본 handover + STAGE_*_REPORT 모두 읽음
- [ ] 운영팀이 admin console 에 MFA 로 첫 로그인
- [ ] 운영팀이 모의 인시던트 응대 1회 실시
- [ ] 인계자가 운영팀에게 30분 onboarding 진행

## 10. 본 문서 정본

본 문서는 출시 후에도 분기 1회 갱신 — 운영 정책 변경, 신규 결정, 새 docs 추가 시.
