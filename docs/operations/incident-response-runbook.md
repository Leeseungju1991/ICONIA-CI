# Incident Response Runbook

## 1. 정의

운영 서비스의 정상 동작이 방해받는 모든 사건.

| Severity | 정의 | 예시 | 대응팀 |
|---|---|---|---|
| SEV-1 | 전체 서비스 다운 또는 critical 보안 사고 | API 5xx 100%, DB 다운, 개인정보 침해 | SRE + secops + DPO + CEO |
| SEV-2 | 부분 기능 다운 또는 다수 사용자 영향 | AI provider 다운, ADMIN 접근 불가, 5% 이상 error rate | SRE + 담당 lead |
| SEV-3 | 소수 사용자 영향, 우회 가능 | 일부 기능 슬로우, 비핵심 페이지 오류 | 담당 개발자 |
| SEV-4 | 영향 미미 또는 모니터링 알람만 | 임계 근접, 단발성 에러 | 모니터링만 |

## 2. 인지 → 통지

- CloudWatch alarm → SNS → Slack `#alerts` 채널
- 사용자 신고 → CS → secops 전달
- 정기 dashboard review 에서 발견

## 3. 대응 흐름 (SEV-1/2)

### Phase A — 초기 대응 (0~15분)
1. 인지자 즉시 `#incident-{ID}` 채널 생성
2. Incident commander 지정 (대개 on-call SRE)
3. 영향 범위 파악 (사용자 수, 기능, 지역)
4. 상태 페이지 갱신 (있을 경우)

### Phase B — 안정화 (15~60분)
1. 우선 안전한 상태로 복귀 (배포 rollback / 기능 비활성)
2. 사용자 통지 (필요 시 — 영향 큰 경우)
3. 근본 원인 추정 → fix 계획

### Phase C — 해결 (1~4시간)
1. fix 적용 (긴급 hotfix or rollback)
2. health check + 사용자 영향 확인
3. 정상 동작 검증

### Phase D — 사후 분석 (24~72시간)
1. Postmortem 작성 (`docs/incidents/INC-YYYYMMDD-NN.md`)
2. 5 Whys / Timeline / Action items
3. 재발 방지 (코드/runbook/모니터링 보강)
4. 팀 디브리프

## 4. 알람 임계 (CloudWatch)

| Alarm | 임계 | 대응 |
|---|---|---|
| API 5xx rate | > 1% over 5min | SEV-2 |
| API p95 latency | > 3000ms over 10min | SEV-3 |
| DB connection | > 80% pool over 5min | SEV-2 |
| Gemini quota | 95%+ over 30min | SEV-3 (cool-down 자동) |
| EC2 CPU | > 90% over 15min | SEV-3 |
| RDS CPU | > 80% over 15min | SEV-2 |
| Audit log write fail | > 0 over 1min | SEV-1 (정합성 위협) |
| OTA failure rate | > 5% over 1h | SEV-2 |

## 5. Provider Incident

### 5.1 AWS region 장애 (ap-northeast-2)
- 1차: 운영 가능 여부 점검 (RDS, EC2, ALB)
- 2차: AWS Health Dashboard 모니터링
- 3차: multi-region failover 검토 (HD-06)

### 5.2 Google Gemini 장애
- AI service 의 fallback 응답 활성화 (in-character canned messages)
- 사용자에게 "일시적 응답 지연" 안내
- 운영자 dashboard 의 Gemini 키 풀 상태 점검

## 6. 통신 정책

- 외부 (사용자): 명확하고 간결하게, 기술 세부 제외
- 내부 (팀): timeline + technical detail
- 법무·DPO 통지: SEV-1 + 개인정보 영향 가능성 시 즉시

## 7. Post-Incident

- [ ] Postmortem 작성·공유
- [ ] 사용자 사후 안내 (해결 완료 통지)
- [ ] runbook 갱신
- [ ] 모니터링 / 알람 보강
- [ ] 테스트 케이스 추가 (Stage 6 wide stress 에 추가)
