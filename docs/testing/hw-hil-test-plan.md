# HW HIL (Hardware-in-the-Loop) Test Plan

> 실 ESP32 인형 + 실 BLE/Wi-Fi 환경에서 검증해야 하는 시나리오. **실 기기 투입 결정은 HD-12**.

## 1. 필요 장비

- ESP32-S3 양산 PCB × 5~10대 (다양한 LOT)
- Wi-Fi AP × 2종 (2.4GHz, dual-band)
- 다양한 모바일 디바이스 (iOS 14+ × 2, Android 10+ × 2)
- 전류 측정기 (DC, deep-sleep 측정용)
- 측정 환경: EMI shielding 가능한 공간 권장

## 2. 시나리오 (HW-09 ~ HW-14)

### HW-09: BLE disconnect 시나리오
- [ ] 페어링 성공 후 BLE 임의 단절 → 자동 reconnect 동작
- [ ] 단절 횟수 limit (예: 5회) 후 사용자에게 알림
- [ ] reconnect 동안 사용자 UX (loading indicator)

### HW-10: Wi-Fi timeout
- [ ] 잘못된 SSID/password 입력 → 적절한 timeout (15초) + 사용자 에러 메시지
- [ ] Wi-Fi 신호 약한 환경에서 connect 재시도 횟수
- [ ] 2.4GHz vs 5GHz 분기 (ESP32-S3 는 2.4GHz only — 5GHz 시도 시 에러 안내)

### HW-11: 이미 프로비저닝된 디바이스
- [ ] 페어링된 인형이 다른 사용자의 앱과 페어링 시도 → 거부
- [ ] AS 처리 시: factory reset 후 재페어링 가능

### HW-12: Factory reset
- [ ] 인형 측 long-press button or 앱 commands → factory reset
- [ ] reset 후 모든 사용자 데이터/페어링 제거 검증
- [ ] reset 후 재페어링 정상

### HW-13: OTA 성공
- [ ] 정상 버전 OTA 다운로드 → 검증 → flash → 재부팅 → health OK → commit
- [ ] 다양한 Wi-Fi 속도 (Wi-Fi N/AC) 에서 download 시간

### HW-14: OTA 실패 / retry
- [ ] 다운로드 중 network 끊김 → 재시도
- [ ] 서명 검증 실패 → 펌웨어 거부
- [ ] flash 실패 → 자동 이전 안정 버전으로 boot
- [ ] secure version 낮음 → 거부 (anti-rollback)

## 3. 추가 안전성 시나리오

| ID | 시나리오 | 측정 |
|---|---|---|
| HW-SAFE-01 | 배터리 완전 방전 → 충전 → 부팅 | 정상 동작 |
| HW-SAFE-02 | 충전 중 사용 | 발열 < 60℃ |
| HW-SAFE-03 | 과충전 보호 | BMS 동작 |
| HW-SAFE-04 | 단락 보호 | BMS 동작 |
| HW-SAFE-05 | 진동 (낙하 30cm) | 정상 동작 |
| HW-SAFE-06 | 정전기 (ESD ±8kV) | 정상 동작 (인증 표준) |
| HW-SAFE-07 | 고온 환경 (60℃) | 안전 셧다운 또는 정상 |
| HW-SAFE-08 | 저온 환경 (-10℃) | 정상 / 셧다운 |
| HW-SAFE-09 | 24시간 idle 후 deep-sleep 전류 | < 50µA |
| HW-SAFE-10 | watchdog 동작 검증 | 의도된 hang 시 자동 reset |

## 4. EMC / 인증 사전 시험 (HW-CERT)

| ID | 시험 | 표준 | 실시 시점 |
|---|---|---|---|
| HW-CERT-01 | 무선 출력 power (BLE) | KS X 3201 등 | 양산 PCB 확정 후 |
| HW-CERT-02 | 무선 출력 power (Wi-Fi) | KS X 3201 | 위와 동일 |
| HW-CERT-03 | 점유 주파수 대역 | 동상 | |
| HW-CERT-04 | 스퓨리어스 방사 | 동상 | |
| HW-CERT-05 | EMC 일반 | KC EMC | 외부 인증 기관 |

본 시험은 KC 적합성평가 (HD-03) 와 연계.

## 5. 실시 일정 (HD-12 결정 후)

- **베타 출시 전**: HW-09 ~ HW-14 (필수)
- **양산 출하 전**: HW-SAFE-01 ~ 10 + HW-CERT-01 ~ 05 (필수)
- **분기 1회**: DR drill 동시에 실시

## 6. 결과 보관

- `6. CI/docs/testing/hw-hil-test-results-<date>.md`
- 실패 항목은 BLOCKER_REGISTER 에 P0/P1 등록
- 인증 결과는 `docs/operations/device-certification-checklist.md` 에 반영
