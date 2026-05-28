# ICONIA E2E Wide Stress Test Platform

> HW(BLE/Wi-Fi/터치/이미지) 미준비 상태에서 **Virtual Event Simulator → AWS → Gemini AI → APP/ADMIN** 전체 흐름의 wide stress test 플랫폼.

## 1. 사용

```bash
# 가장 간단 (Docker)
docker compose up

# Makefile 진입점
make stress-test                # 전체 시나리오
make stress-test-spike          # spike 만
make stress-test-soak           # soak (장시간)
make report                     # 리포트 (JSON/CSV/HTML) 생성
make monitoring                 # Prometheus + Grafana + Loki only
```

## 2. 아키텍처

```
[Virtual Event Simulator] ──┐
                            ├──> AWS API/Lambda/SQS/DynamoDB ──> APP/ADMIN
[AWS Load Worker (locust)] ─┤                                    ▲
[Gemini Validation Worker] ──> Google Gemini API                 │
[Chaos Injection Worker] ────> latency/timeout/throttling 주입   │
                                                                  │
[APP Verification Worker]  ──────────────────────────────────────┘
[ADMIN Verification Worker] ─────────────────────────────────────┘

[Metrics Collector] ──> Prometheus ──> Grafana
                       ─> Loki     ──> Grafana
                       ─> OpenTelemetry Collector
[Report Agent] ──> reports/{json,csv,html}
```

## 3. 폴더 구조

| Path | 역할 |
|---|---|
| `simulator/` | Virtual Event 생성 (12 패턴, HW 제외) |
| `workers/` | AWS / Gemini / APP / ADMIN / Chaos / Metrics worker |
| `agents/` | 8 기본 + 5 조건부 즉시 생성 agent |
| `load/` | Locust + k6 시나리오 |
| `reports/` | JSON/CSV/HTML generator + Jinja2 template |
| `monitoring/` | Prometheus / Loki / OpenTelemetry / Grafana 설정·대시보드 |
| `tests/` | pytest 검증 |
| `scripts/` | shell 진입점 |
| `.github/workflows/` | GHA 자동 실행 |

## 4. 환경

- `.env.example` 복사 → `.env` + 실 값 채움
- Python 3.11+ (asyncio)
- Docker Compose v2
- (선택) k6 / Locust 로컬 설치

## 5. 안전 정책

- **production traffic 부하 금지** — staging endpoint 만 (`STRESS_TARGET=staging`)
- Gemini API 비용 한도 (`GEMINI_MAX_TOKENS_PER_RUN`) 강제
- 실 사용자 데이터 사용 금지 — Virtual Event Simulator 만

## 6. CI 통합

- GitHub Actions: 주간 자동 실행 + manual dispatch
- Jenkins: 별도 staging 파이프라인

## 7. 결과 리포트

`reports/output/<timestamp>/` 에 JSON + CSV + HTML 자동 생성. CI 가 artifact 업로드.

## 8. 본 플랫폼의 한계 (HW 미준비)

다음은 본 플랫폼이 다루지 않는다:
- BLE 실제 연동
- Wi-Fi provisioning 실제 동작
- 터치 센서 입력
- 카메라 이미지 캡처/업로드
- ESP32 펌웨어 실 동작

위는 HIL (Hardware-in-the-Loop, `6. CI/docs/testing/hw-hil-test-plan.md`) 로 별도 검증.
