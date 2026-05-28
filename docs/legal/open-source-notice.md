# 오픈소스 라이선스 고지 (Open Source Notice)

> 본 문서는 ICONIA 가 사용하는 주요 오픈소스 의존성과 그 라이선스를 정리한다. 자동 생성 도구 (예: `npm-license-checker`, `pip-licenses`) 의 결과를 사용해 출시 직전 업데이트한다.

## 1. 생성 도구 (자동화)

```bash
# Node 기반 레포 (SERVER, ADMIN, AI, APP)
npx license-checker --production --json > docs/legal/licenses-<repo>.json

# pip 기반 (해당 시)
pip-licenses --format=json > docs/legal/licenses-<repo>.json
```

## 2. 주요 의존성 (high-level)

### SERVER (Node.js + Express + Prisma)
- Express — MIT
- Prisma — Apache-2.0
- pino — MIT
- zod — MIT
- @aws-sdk/* — Apache-2.0
- bcrypt — MIT
- jsonwebtoken — MIT
- helmet — MIT
- multer — MIT
- ioredis — MIT

### ADMIN (Next.js)
- Next.js — MIT
- React — MIT
- TailwindCSS — MIT
- @tanstack/react-query — MIT
- Playwright — Apache-2.0
- Vitest — MIT

### AI (Node + Gemini SDK)
- @google/generative-ai — Apache-2.0
- pino — MIT
- zod — MIT

### APP (React Native + Expo)
- react-native — MIT
- expo — MIT
- @react-native-async-storage/async-storage — MIT
- react-native-ble-plx — Apache-2.0
- @sentry/react-native — MIT (도입 시)
- react-navigation — MIT

### HW (Firmware, Arduino/PlatformIO)
- esp-idf — Apache-2.0
- Arduino core for ESP32 — LGPL-2.1
- ArduinoJson — MIT
- 기타 라이브러리 — 각 라이브러리별 라이선스 확인

## 3. 라이선스 의무 (요약)

| 라이선스 | 주요 의무 |
|---|---|
| MIT / BSD / Apache-2.0 | 라이선스 텍스트 동봉 (앱 내 표시) |
| LGPL | 동적 링크 시 라이브러리 교체 가능성 보장 + 라이선스 동봉 |
| GPL | (사용 안 함 권장) 전체 코드 공개 가능성 → 검토 필수 |
| CC-BY | 저작자 표시 |
| Commercial / Proprietary | 사용 계약서 확인 |

## 4. 앱 내 표시 (HD-16)

- 설정 > 오픈소스 라이선스 화면
- 패키지명·버전·라이선스·라이선스 텍스트 모두 표시
- 자동 생성 후 앱 빌드 시 포함

## 5. CI 라이선스 스캔

- `6. CI/.github/workflows/license-compliance.yml` 가 PR 마다 실행
- GPL/AGPL 같은 카피레프트 라이선스 도입 시 알람
- SBOM 생성 (`6. CI/.github/workflows/sbom.yml`) 와 함께

## 6. LEGAL_REVIEW_REQUIRED

- HD-16: 출시 전 사내 법무 + 개발팀 합동 검토
- 향후 신규 의존성 추가 시 라이선스 검토 의무화
