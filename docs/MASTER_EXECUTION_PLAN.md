# ICONIA 7단계 엔터프라이즈 양산화 — 마스터 실행 계획

> 본 문서는 5개 레포(ICONIA-APP / ICONIA-ADMIN / ICONIA-AI / ICONIA-HW / ICONIA-SERVER)를 AWS 실서버 기반 엔터프라이즈 양산화 수준으로 끌어올리는 7단계 자동 실행 계획의 마스터 문서다. CI 레포(ICONIA-CI)는 인프라/배포 컨트롤 플레인 역할을 한다.

## 0. 제품 전제

- **APP_MODE_1_MOCK_CONNECTIVITY** — BLE/Wi-Fi 만 mock. 로그인/피드/커머스/AI/관리자는 실제 AWS dev/staging API. 개발·QA·시연 전용. production release 금지.
- **APP_MODE_2_REAL_DEVICE** — 실 출시 모드. BLE/Wi-Fi 실 동작. production release 는 본 모드만 허용.
- **커머스 display-only** — 결제·주문·장바구니·배송·환불·청약철회 전부 비구현. UI 에 결제/주문 문구 금지. 데이터는 AWS DB seed → API.
- **법률/컴플라이언스** — 법무 검토 제출 수준의 초안 작성. Claude Code 는 법률 최종 승인 단정 금지. `LEGAL_REVIEW_REQUIRED` 마킹.

## 1. 5개 레포 책임

| 레포 | URL | 책임 |
|---|---|---|
| ICONIA-APP | github.com/Leeseungju1991/ICONIA-APP | RN/Expo 모바일. APP modes, BLE/Wi-Fi 어댑터, 법률 화면, 동의 흐름 |
| ICONIA-SERVER | github.com/Leeseungju1991/ICONIA-SERVER | Express API, Prisma, auth/RBAC, seed, audit, feed/commerce display API |
| ICONIA-ADMIN | github.com/Leeseungju1991/ICONIA-ADMIN | Next.js 관리자 콘솔, RBAC 게이팅, 운영 페이지 |
| ICONIA-AI | github.com/Leeseungju1991/ICONIA-AI | Gemini 통합, RAG, persona, prompt injection 가드, AI 안전 |
| ICONIA-HW | github.com/Leeseungju1991/ICONIA-HW | ESP32 펌웨어, BLE/Wi-Fi 프로비저닝, OTA, anti-rollback |
| ICONIA-CI | github.com/Leeseungju1991/ICONIA-CI | Terraform/k8s/deploy 스크립트 + master docs |

## 2. 7단계 등급

| Stage | 등급 | 목표 |
|---|---|---|
| 0 | Bootstrap | 5개 레포 사전 점검, master docs, CI README, agent setup |
| 1 | LEVEL 1 Demo & QA Ready | APP_MODE_1, 피드/커머스 seed, font/asset validation, smoke test |
| 2 | LEVEL 2 Real Device Core Ready | APP_MODE_2, APP-HW BLE contract, Wi-Fi provisioning |
| 3 | LEVEL 3 Legal/Compliance/User Disclosure | legal register, compliance matrix, 법률 화면, 동의 흐름 |
| 4 | LEVEL 4 AWS Staging & Operations Ready | dev/staging/prod 분리, CI/CD gate, 배포/롤백 runbook, observability |
| 5 | LEVEL 5 Release Candidate Security & Reliability | P0 제거, mock production 차단, security hardening, OTA anti-rollback |
| 6 | LEVEL 6 E2E Wide Stress & Resilience Verified | 멀티-에이전트 병렬 E2E, stress/chaos/security 검증, baseline 측정 |
| 7 | LEVEL 7 Enterprise Production Finalization & Go/No-Go | release candidate, final readiness score, handover |

## 3. 절대 금지 (모든 Stage)

- production AWS 리소스 생성/변경/삭제 실제 실행
- production DB migration / seed 실제 실행
- production traffic 전환
- app store / play store 실제 배포
- 결제/주문/배송/환불 기능 활성화
- 실제 secret 값 생성·커밋
- 법률 최종 승인 단정
- KC/전파 인증 완료 단정
- 통신판매업 신고 필요/불필요 단정
- 위치정보사업 해당/비해당 단정

## 4. Stage 종료 규칙

각 Stage 가 끝나면:
1. 변경 파일 `git status --porcelain` 확인 + secret/env 스캔
2. Stage 와 관련된 변경만 `git add`
3. 가능 검증 (`npm test` / `lint` / `typecheck` / `prisma validate`) 실행 → 실패는 `NOT_RUN_WITH_REASON` 또는 fix
4. Commit message 형식: `stageN: <목적>` (예: `stage1(app): add mock connectivity guard`)
5. `git push origin main` — 실패 시 `PUSH_BLOCKED` 로 기록 (CI README + Final Report)
6. Stage Report 파일로 작성 (사용자에게 중간 보고 X)

## 5. P0/P1/P2 기준 (요약)

- **P0** — 출시 차단. production mock 가능, 결제 UI 활성, secret 누출, 인증 우회, KC 미검토, OTA downgrade, 핵심 E2E 실패 등
- **P1** — release candidate 전 해결 권장. 로깅 부족, runbook 부족, HIL 미수행 등
- **P2** — 출시 후 개선 가능

## 6. 문서 위치

- 마스터/공통: `6. CI/docs/`
- 레포별: 각 레포 `docs/`
- 사용자 결정 필요 항목: `6. CI/docs/release/HUMAN_DECISIONS_REQUIRED.md` + `6. CI/README.md` 의 보강 섹션
- Stage commit/push 로그: `6. CI/docs/git/STAGE_COMMIT_PUSH_LOG.md`

## 7. Agent 매핑

| Agent | 1차 책임 영역 |
|---|---|
| principal-orchestrator (본 Claude) | 7단계 총괄, integration, final go/no-go |
| rn-mobile | ICONIA-APP |
| aws-infra | ICONIA-SERVER (Express/AWS), CI |
| persona-ai | ICONIA-AI (Genome, Gemini, RAG) |
| hw-fw | ICONIA-HW (ESP32 펌웨어) |
| integration-reviewer | 5-레포 contract/스키마 정합성 |
| product-experience | UX, in-character, 안전, 법률 표면 |
| Explore | 코드/패턴 위치 탐색 |
| general-purpose | 다단계 검색·작업 |

## 8. 자동 실행 흐름

```
사용자 "작업시작" 입력
  ↓
Stage 0 (이 문서 + 등록부 + CI README + Stage 0 report)
  ↓ commit/push
Stage 1 → 2 → 3 → 4 → 5 → 6 → 7
  ↓ 각 단계마다 commit/push + report
Final 1회 사용자 보고 (Stage 7 끝난 후)
```

중간 보고 금지. 단, production 실제 행위·secret·법률 최종 승인·KC 인증 등 외부 사람 결정 필요 시에만 멈춤.

## 9. 본 문서 운영

본 문서는 Stage 0 종료 시점 기준. 이후 Stage 별로 갱신되지 않는다 (Stage Report 가 누적). 변경 사항은 각 Stage Report 와 Final Report 에서 확인.
