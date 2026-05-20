# Sentry DSN 매핑 정본

본 문서는 ICONIA 의 crash analytics (Sentry) 프로젝트 구성과 DSN 주입 경로를 정의한다.
실제 DSN 값은 **AWS Secrets Manager** 와 **Expo EAS Secrets** 에만 저장하며 본 폴더에 평문으로 커밋 금지.

## 1. 프로젝트 구성

Sentry organization `iconia` 아래 4 개 프로젝트 (단일 organization 권장 — quota 관리 통합).

| 프로젝트 슬러그 | 플랫폼 | 대상 코드 | environment 태그 |
|---|---|---|---|
| `iconia-server` | node-express | `2. SERVER` (Express, port 8080) | `prod` / `staging` / `dev` |
| `iconia-ai` | node | `3. AI` (Genome 엔진, port 8081) | 동일 |
| `iconia-admin` | nextjs | `5. ADMIN` (Next.js, port 3000) | 동일 |
| `iconia-app` | react-native | `4. APP` (Expo) | `prod` / `staging` / `dev` |

(HW 펌웨어 `1. HW` 는 Sentry 미사용 — 자체 OTA 로그가 device telemetry 로 Server 에 push.)

## 2. DSN 저장 위치 (정본)

| 대상 | 저장소 | secret_id / key |
|---|---|---|
| iconia-server | AWS Secrets Manager | `iconia/${env}/sentry/server_dsn` |
| iconia-ai | AWS Secrets Manager | `iconia/${env}/sentry/ai_dsn` |
| iconia-admin | AWS Secrets Manager | `iconia/${env}/sentry/admin_dsn` |
| iconia-app | Expo EAS Secret | `SENTRY_DSN_APP_${ENV}` (eas.json env 분기) |

서버 측은 `ec2-pull-and-restart.sh` 의 `inject_database_url` 함수와 같은 패턴으로 부팅 시 fetch 후 `/etc/iconia.${svc}.env` 에 주입한다 (별도 `inject_sentry_dsn` 함수 추가 — 본 라운드 스코프 외, 운영자 작업).

App 측은 EAS Build 시 `process.env.EXPO_PUBLIC_SENTRY_DSN` 으로 노출. **public 빌드 DSN 만 사용** — 서버 DSN 과 절대 공유 금지.

## 3. environment 태그 매핑

각 SDK 초기화 시 `Sentry.init({ environment: process.env.ICONIA_ENV })` 로 강제. CI 환경 시 `staging`, 운영 EC2 `prod`. App 은 release channel(`production`/`preview`) → `environment` 직접 mapping.

## 4. release 식별자

- Server/AI/Admin: `${service}@${SHA-short}` — `build-and-upload.ps1` 의 `$Version` (UTC timestamp) 을 release tag 로 같이 보냄.
- App: `iconia-app@${eas.buildVersion}+${EAS_BUILD_PROFILE}` — EAS Build env var.

source map / debug symbol 업로드는 각 빌드 단계에서 `sentry-cli releases files <release> upload-sourcemaps` 로. 본 라운드는 schema 만 정의 — 실제 업로드 자동화는 별도 라운드.

## 5. quota 알람

Sentry organization 의 monthly event quota 가 90% 초과 시 alarm. 운영자가 Sentry UI 의 Organization Settings → Subscription 에서 직접 임계 설정. 본 IaC 에는 외부 SaaS quota 알람 미정의.

## 6. PII 차단

server/ai/admin 의 SDK 초기화에 다음 옵션 강제:

```js
Sentry.init({
  dsn,
  environment: process.env.ICONIA_ENV,
  sendDefaultPii: false,
  beforeSend(event) {
    // request.headers.{authorization,cookie} 마스킹.
    if (event.request?.headers) {
      delete event.request.headers.authorization;
      delete event.request.headers.cookie;
      delete event.request.headers['x-api-key'];
    }
    return event;
  },
});
```

App 측은 RN 의 `breadcrumbs` 가 사용자 입력 텍스트를 잡지 않도록 `attachStacktrace=true` 만 활성.

## 7. 데이터 retention

Sentry SaaS 기본 90일. 우리 prod 는 90일 충분. PIPA 측면에서는 Sentry 가 EU/US 데이터센터이므로, 한국 PIPA 의 국외 이전 동의 흐름에 본 처리 명시 (PIPA 동의서 V2 §3) — 정책 정본은 `2. SERVER/docs/security-policy.md`.
