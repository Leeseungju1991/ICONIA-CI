# 오픈소스 라이선스 고지

## 1. 자동 생성 도구

```powershell
# Node 기반 레포 (SERVER, ADMIN, AI, APP)
npx license-checker --production --json > docs/legal/licenses-<repo>.json

# pip 기반 (해당 시)
pip-licenses --format=json > docs/legal/licenses-<repo>.json

# 본 워크플로는 `6. CI/scripts/generate-oss-notice.ps1` 가 자동화
```

## 2. 주요 의존성 (high-level)

> 정본 자동 생성 시점에 본 §2 가 갱신됨. 아래는 현재 코드베이스 기준 요약.

### SERVER (Node.js + Express + Prisma)
| 라이브러리 | 라이선스 |
|---|---|
| Express | MIT |
| Prisma | Apache-2.0 |
| pino | MIT |
| zod | MIT |
| @aws-sdk/* | Apache-2.0 |
| bcrypt | MIT |
| jsonwebtoken | MIT |
| helmet | MIT |
| multer | MIT |
| ioredis | MIT |

### ADMIN (Next.js)
| 라이브러리 | 라이선스 |
|---|---|
| Next.js | MIT |
| React | MIT |
| TailwindCSS | MIT |
| @tanstack/react-query | MIT |
| Playwright | Apache-2.0 |
| Vitest | MIT |

### AI (Node + Gemini SDK)
| 라이브러리 | 라이선스 |
|---|---|
| @google/generative-ai | Apache-2.0 |
| pino | MIT |
| zod | MIT |

### APP (React Native + Expo)
| 라이브러리 | 라이선스 |
|---|---|
| react-native | MIT |
| expo | MIT |
| @react-native-async-storage/async-storage | MIT |
| react-native-ble-plx | Apache-2.0 |
| react-navigation | MIT |
| @sentry/react-native | MIT (도입 시) |

### HW (Firmware, ESP-IDF/Arduino)
| 라이브러리 | 라이선스 | 의무 |
|---|---|---|
| esp-idf | Apache-2.0 | 라이선스 동봉 |
| Arduino core for ESP32 | LGPL-2.1 | 동적 링크 가능성 보장 + 라이선스 동봉 |
| ArduinoJson | MIT | 라이선스 동봉 |

## 3. 라이선스 의무 (요약)

| 라이선스 | 주요 의무 | 적용 |
|---|---|---|
| MIT / BSD | 라이선스 텍스트 동봉 (앱 내 표시) | 대부분 |
| Apache-2.0 | 라이선스 텍스트 + NOTICE 파일 동봉 | aws-sdk, esp-idf, ble-plx 등 |
| LGPL-2.1 | 동적 링크 가능성 보장 + 라이선스 동봉 | Arduino core (HW) |
| GPL (사용 안 함) | 전체 코드 공개 가능성 | 도입 시 별도 review |
| CC-BY | 저작자 표시 | 해당 시 |

## 4. 앱 내 라이선스 표시

- 앱 설정 > 오픈소스 라이선스 화면
- 각 패키지 별 이름·버전·라이선스·전문 표시
- 출시 빌드 시 자동 생성 → 앱 내 정적 자원 포함

## 5. 회사 자체 코드

`iconia_*.h`, `iconia_*.cpp`, `5. ADMIN/`, `4. APP/src/`, `2. SERVER/src/`, `3. AI/src/`, `1. HW/ICONIA Firmware/` 의 회사 자체 작성 코드는 (주)숨코리아 / Soom Korea Inc. © 2026 All rights reserved.

본 회사 코드는 폐쇄 소스이며, 본 약관·라이선스 고지가 위 회사 자체 코드의 공개 의무를 발생시키지 않습니다.

## 6. LGPL 재링크 요청 절차 (HW 정본 §3)

LGPL-2.1 라이브러리 (Arduino core) 의 §6 (재링크 가능성 보장) 의무에 따라:

1. 사용자가 (주)숨코리아 AS 채널 (web@soomkorea.com) 로 LGPL 재링크 자료를 요청
2. 회사는 30일 이내 LGPL 부분의 object file + 빌드 instruction 을 제공
3. 사용자는 본인 빌드 환경에서 회사 펌웨어와 동일한 형태로 재빌드 가능
4. 회사 자체 코드는 binary 형태로 제공 (재빌드 가능 — LGPL 부분만 교체 가능)

## 7. CI 자동화

- `6. CI/.github/workflows/license-compliance.yml` — 매 PR 실행
- GPL/AGPL 등 카피레프트 라이선스 도입 시 알람
- SBOM 생성 (`6. CI/.github/workflows/sbom.yml`) 동시
- 라이선스 정합 위반 시 PR 자동 차단

## 8. 신규 의존성 도입 정책

신규 의존성 추가 시 다음 절차를 따릅니다.

1. PR 작성자가 신규 의존성 라이선스 명시
2. CI 가 자동 license check
3. GPL/AGPL/Commercial-only 라이선스 → 별도 검토 후 도입 결정
4. MIT/BSD/Apache-2.0/ISC 등 → 자동 승인

## 9. 시행

- 본 정책 시행일: 2026-05-28
- 최종 OSS notice list 는 출시 빌드 직전 자동 생성 → 앱 내 포함
