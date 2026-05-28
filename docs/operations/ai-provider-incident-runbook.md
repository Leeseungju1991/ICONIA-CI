# AI Provider Incident Runbook

## 1. 적용 범위

- Google Gemini API 장애
- Gemini API rate limit / quota exhaustion
- Gemini API 응답 품질 저하 (부적절한 응답)
- Gemini API 정책 위반 통보
- AI 측 SOUL 엔진 장애

## 2. Detection

| 신호 | 임계 | 알람 |
|---|---|---|
| Gemini API 응답 5xx | > 5% over 5min | SEV-2 |
| Gemini API timeout | > 10% over 10min | SEV-2 |
| AI fallback rate | > 10% over 30min | SEV-3 |
| 키 풀 active rate | < 1/N (= 1키만 살아있음) | SEV-2 |
| 키 풀 0/N (모두 cooldown) | 모든 키 다운 | SEV-1 |
| AI p95 latency | > 5000ms over 10min | SEV-3 |
| 부적절한 응답 신고 | > 5건/day | SEV-3 |

## 3. 즉각 대응 (Phase A)

### 3.1 모든 키 cooldown

- 즉시 in-character fallback 활성 (`3. AI` 의 canned messages)
- 사용자 통지: "AI 페르소나가 잠시 휴식 중입니다. 곧 돌아옵니다."
- 운영자 점검: ADMIN `dashboard/ai-usage` 에서 키별 상태 확인

### 3.2 신규 키 추가 (5~10분)

```bash
# 운영자가:
# 1. Google Cloud Console → AI Studio → Create API Key (새 프로젝트)
# 2. AWS Secrets Manager 또는 SSM Parameter Store 에 추가
# 3. AI 서비스 재시작 (systemd restart iconia-ai)
# 4. ADMIN dashboard/ai-usage 에서 풀 active 확인
```

### 3.3 Tier 승급 (장기 대책)

- 결제 활성 + Tier 1 자동 진입 → 100배 한도 증가
- 가이드: `5. ADMIN/app/dashboard/ai-usage` 의 GeminiManagementPanel

## 4. 응답 품질 저하

### 4.1 Prompt injection 의심
- regression test 실행 (`3. AI/src/rag/canaryToken.js`)
- canary token 출현 시 → 시스템 프롬프트 누출 가능성 → secops 통지

### 4.2 부적절한 응답 (Gemini safety filter 우회)
- 응답 차단 + 사용자 알림 (페르소나 일관성 유지하며 사과)
- AI lead 통지 + 페르소나 별 검증

### 4.3 페르소나 일관성 약화
- 영향받은 페르소나 별 trace 분석
- SOUL 파일 검증 (`3. AI` 측)
- 필요 시 페르소나 rollback (이전 SOUL version)

## 5. Gemini 정책 위반 통보 수신

- Google 의 통보 → secops + 법무
- 영향 받는 사용자 + 콘텐츠 식별
- 해당 콘텐츠 차단/삭제 + 사용자 안내

## 6. 사후 분석

- Postmortem (`docs/incidents/`)
- 5 Whys + Action items
- 키 풀 정책 점검 (몇 개가 적절한가)
- Tier 승급 필요성 재검토

## 7. 사용자 통신

- AI 페르소나 응답 지연 시: 화면에 "잠시 후 다시 시도" 표시
- 신고된 응답 처리 후: 신고자에게 결과 통지
- 정책 변경 시: 약관/AI disclosure 업데이트 + 재동의 (해당 시)

## 8. LEGAL_REVIEW_REQUIRED

- 부적절한 응답으로 인한 사용자 피해 시 책임 한도 — 법무 검토
- Gemini 정책 위반 시 처리 절차 — 법무 검토
