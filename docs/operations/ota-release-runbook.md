# OTA Release / Rollback Runbook

## 1. OTA 배포 정책

- 펌웨어 버전: SemVer (e.g., `1.2.3`)
- Secure version: monotonic increment (anti-rollback)
- 서명: 회사 비공개 키 (HW + 서버 측 검증)

## 2. 배포 단계

### 2.1 빌드 + 서명 (개발 → CI)

```yaml
# 6. CI/.github/workflows/firmware-sign.yml
- compile firmware (.bin)
- sign with private key
- compute SHA256
- upload to S3 (iconia-prod-firmware-<account>)
```

### 2.2 운영자 승인 (HD-06)

- ADMIN `dashboard/ota-deploy` 에서:
  - 펌웨어 버전 + sha256 + size 입력
  - 디바이스 그룹 선택 (beta / staff / canary 10% / all)
  - 운영자 사유 입력 (5자 이상)
- audit_log 자동 기록

### 2.3 디바이스 측 수신

- 부팅 시 또는 주기적으로 SERVER `/firmware/check` 호출
- 새 버전 발견 시 다운로드
- **서명 검증** (private key 의 public counterpart 로)
- **secure version 검증** (anti-rollback)
- 검증 통과 시 flash → 재부팅
- 부팅 후 health check → 통과 시 commit, 실패 시 자동 rollback

## 3. Canary 배포

- 1% → 10% → 50% → 100% 단계적 확대
- 각 단계 후 24시간 모니터링
- failure rate > 5% → 자동 일시 중지

## 4. Rollback

### 4.1 펌웨어 안에 anti-rollback enforce (HW)

- secure version 이 이전 버전보다 낮은 펌웨어 거부
- 정식 rollback 필요 시 → 신 펌웨어 + secure version 같이 (기능적 rollback)

### 4.2 OTA 서버 측

- ADMIN 에서 deployment 비활성화 → 신규 디바이스 다운로드 차단
- 이미 적용된 디바이스 → 다음 정식 fix 까지 대기

## 5. 알람

- OTA failure rate > 5% over 1h → SEV-2
- Signature 검증 실패 (디바이스 측) → 즉시 secops 통지

## 6. KC 인증 영향

- 펌웨어 변경 중 무선 통신 파라미터 (출력 파워, 주파수) 변경 시 → KC 재인증 검토 (HD-03)
- 기능적 변경 (BLE 프로비저닝 흐름 등) → 재인증 불필요 (대개)

## 7. Postmortem (OTA 실패 시)

- 영향받은 디바이스 수
- 부팅 실패 / health fail 원인
- 디바이스 측 rollback 동작 검증
- 재발 방지 (시뮬레이션 + HIL 강화)

## 8. LEGAL_REVIEW_REQUIRED

- OTA 자동 적용 정책의 사용자 동의 (device-connection-policy 의 §5)
- 펌웨어 변경 시 사용자 통지 의무 — 법무 검토
