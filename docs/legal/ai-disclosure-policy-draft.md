# AI 이용 안내 / 면책 정책 (Draft — Legal Review Required)

> **본 문서는 초안이며 출시 전 법무·개인정보보호책임자 검토 후 최종본으로 게시됩니다.**

## 1. AI 페르소나 사용 안내

ICONIA 서비스의 AI 페르소나는 다음 기술을 사용합니다.

- **Google Gemini API** — 응답 생성을 위한 대규모 언어 모델
- **자체 SOUL 엔진** — 페르소나 일관성, 5가지 욕구 → 8가지 신호 매핑, 4층 기억, 감정 온도 등 (회사 자체 IP)
- **RAG (Retrieval-Augmented Generation)** — 페르소나 별 기억·문서 기반 응답

## 2. 사용자에게 표시되는 안내 문구 (앱 내)

ICONIA 앱의 AI 화면 진입 시 사용자에게 다음 내용이 표시됩니다.

> AI 페르소나 응답은 인공지능이 생성한 것입니다.
>
> - 응답은 사실과 다르거나 부정확할 수 있습니다.
> - 의료·법률·금융 등 전문가 상담이 필요한 분야의 결정 근거로 사용하지 마세요.
> - 비밀번호, 카드번호, 주민등록번호 등 민감한 개인정보를 입력하지 마세요.
> - AI 응답은 페르소나 일관성을 위해 일부 캐릭터화되어 있으며, 실제 인물이나 의료적 진단을 대체하지 않습니다.

## 3. 데이터 처리

| 데이터 | 처리 위치 | 보관 기간 | 마스킹 |
|---|---|---|---|
| 사용자 입력 메시지 | Google Gemini (US) + 회사 RDS (KR) | RDS 90일, Gemini 정책에 따름 | PII redaction 후 저장 |
| AI 응답 | 회사 RDS | 90일 | 그대로 보관 |
| 페르소나 컨텍스트 (기억) | EFS / S3 (KR) | 사용자 탈퇴 시 폐기 | 사용자별 격리 |
| 운영 로그 | CloudWatch (KR) | 30일 | redact.js 마스킹 |

## 4. 사용자 동의 항목

회원 가입 시 다음 동의를 받습니다.

- **(필수) 제3자 제공 동의 (Google Gemini)** — AI 응답을 위해 사용자 메시지를 Google 에 전송
- **(필수) 국외이전 동의** — 미국 region 으로 데이터 전송
- **(선택) 분석·서비스 개선 동의** — 익명 통계로 활용

## 5. 학습 데이터 사용

현재 정책:
- 회사는 사용자 대화 내용을 AI 학습에 사용하지 **않습니다**.
- 사용자 대화는 Google 의 정책에 따라 Gemini API 호출 시 처리되며, Google 의 학습 데이터 사용 여부는 Google 의 정책을 따릅니다.
- 회사는 PII redaction 을 적용한 후에만 데이터를 저장·전송합니다.

향후 학습 데이터 활용 시:
- 별도 동의 항목 추가
- 사용자가 동의 거부 시에도 기본 AI 기능은 정상 이용 가능

## 6. AI 안전성 조치

| 항목 | 조치 |
|---|---|
| Prompt injection 방어 | 입력 sanitization + canary token (`3. AI/src/rag/canaryToken.js`) |
| 시스템 프롬프트 누출 방지 | 응답 검증 + canary detection |
| 부적절한 응답 차단 | Gemini safety filter + 자체 검증 |
| PII 마스킹 | 요청 전 마스킹 (`3. AI/src/utils/redact.js`) |
| 환각 (hallucination) 완화 | RAG 기반 사실 응답 우선, 모를 때 "확실하지 않다" 표시 |
| 페르소나 일관성 | SOUL 엔진 일관성 검증 |

## 7. AI 장애 시 대응

| 시나리오 | 대응 |
|---|---|
| Gemini API timeout | in-character fallback 응답 (canned message) |
| Gemini API rate limit | 키 풀 round-robin + cooldown |
| Gemini API outage | 그래도 페르소나 일관성 유지 + 사용자에게 일시적 응답 지연 안내 |
| 부적절한 응답 감지 | 응답 차단 + 페르소나 적합 사과 메시지 |

운영팀 runbook: `docs/operations/ai-provider-incident-runbook.md`

## 8. 책임 제한

- AI 응답은 사용자의 의사결정을 대체하지 않습니다.
- 회사는 AI 응답으로 인한 직접/간접 손해에 대해 고의 또는 중과실이 없는 한 책임을 지지 않습니다.
- 사용자는 AI 응답을 비판적으로 검토하고, 중요한 결정은 전문가 상담을 받으시기 바랍니다.

## 9. 변경 사항

- AI 모델·기능 변경 시 본 안내 갱신
- 학습 데이터 정책 변경 시 사전 동의 재취득

## 10. 본 문서 운영

- **상태**: DRAFT — LEGAL_REVIEW_REQUIRED (HD-14)
- **검토 담당**: 사내 법무 + PM + AI lead
- **공표 시점**: 출시 전 최종 검토 후 앱 내 표시
