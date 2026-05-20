# Push delivery 운영 정본 (Expo / FCM / APNs)

## 1. 전체 흐름

```
[ Server ]              [ Expo Push Service ]      [ FCM (Android) / APNs (iOS) ]      [ App ]
sendProactivePush() ─▶  https://exp.host/--/api/ ─▶  Google / Apple                  ─▶ Expo SDK push handler
        │                       │
        │                       └─ receipts (id) 응답 후 비동기 처리.
        └─ expo_push_token (DB: User.expoPushToken) 만 보유.
           실제 device token (FCM regId / APNs token) 은 Expo 측에서만 보유.
```

ICONIA APP 은 Expo SDK 의 `expo-notifications` 사용. **Expo Push Service 가 FCM/APNs 사이를 추상화** — 운영자가 FCM/APNs key 자체를 직접 다루는 경우는 EAS credentials 단계뿐.

## 2. 토큰 라이프사이클

| 단계 | 책임 |
|---|---|
| 발급 | App: `Notifications.getExpoPushTokenAsync({ projectId })` 호출 → 서버 `/api/v1/users/me/push-token` 으로 PUT |
| 저장 | Server: `User.expoPushToken` (Postgres). 변경 시 timestamped revision 보존 (deactivated_at). |
| 갱신 | App 부팅마다 token compare → 다르면 PUT. (Expo token 은 expire 안 하지만 reinstall 시 회전됨.) |
| 폐기 | Sentry/디바이스 unregister 시 또는 push DeviceNotRegistered receipt 수신 시 즉시 `expoPushToken=NULL` |

서버는 receipts (`expo-server-sdk` 의 `getPushNotificationReceiptsAsync`) 를 **15분 간격 cron** 으로 fetch — `DeviceNotRegistered` / `MessageRateExceeded` / `InvalidCredentials` 등을 메트릭으로 송출.

## 3. CloudWatch 메트릭 (정본)

namespace: `ICONIA/Push`

| MetricName | dimensions | 의미 | 알람 임계 |
|---|---|---|---|
| `PushSent` | Service=server | sendPush() 호출 수 | (정상치 트래킹, 알람 없음) |
| `PushDelivered` | Service=server | receipt status=ok | delivery rate < 90% 알람 |
| `PushFailed` | Service=server, ErrorCode={DeviceNotRegistered\|MessageRateExceeded\|InvalidCredentials\|MessageTooBig\|MismatchSenderId} | 실패 receipt | 5분 sum >= 50 알람 |
| `PushTokenInvalidated` | Service=server | DeviceNotRegistered 로 NULL 처리 | 5분 sum >= 100 알람 (대규모 토큰 회전 의심) |
| `PushLatencyMs` | Service=server | sendPush p95 | p95 >= 3000ms 알람 |

(상세 alarm 정의는 `cloudwatch-alarms.json` 의 후속 라운드 추가 항목 — 본 문서가 schema 정본.)

## 4. FCM/APNs key 회전 정책

Expo Managed credentials 모드 사용 시:

| key | 회전 주기 | 절차 |
|---|---|---|
| FCM Server Key (legacy) | **회전 불필요 — 사용 중단** | FCM HTTP v1 (`firebase-admin` JSON 서비스 계정) 으로 마이그레이션 (Google 2026 deprecation). |
| FCM service account JSON | 6 개월 | `eas credentials -p android` → `Set up Push Notifications: FCM V1` 로 신규 JSON 업로드. Expo 가 자동 회전. |
| APNs .p8 key | 12 개월 (Apple 자체 무기한이나 운영 정책상) | `eas credentials -p ios` → `Set up Push Notifications: Add a new Push Notifications Key`. AuthKey ID + Team ID 동시 갱신. |
| APNs distribution cert (legacy .p12) | **사용 중단** — .p8 key 로 통합 | 신규 추가 시에만 .p8 사용. |

회전 시 **새 key 등록 → 다음 EAS Build 트리거 → App store 제출 후 7 일 grace** 흐름. 본 폴더는 EAS 명령만 정의 — 실제 key 파일은 EAS Secrets 외부에 절대 저장 금지.

## 5. 환경 분기

| env | Expo `projectId` | EAS profile |
|---|---|---|
| prod | (EAS 콘솔의 prod project) | `production` |
| staging | 동일 project, channel=staging | `preview` |
| dev | local Expo Go (push 미동작 — fallback 로그) | `development` |

App 측 `app.config.ts` 에서 `extra.iconia.env` 분기. 서버 측 `User.environment` (또는 token 자체의 expo project ID prefix) 로 routing.

## 6. 운영자 daily/weekly 점검 항목

- [ ] CloudWatch `ICONIA/Push/PushDelivered / PushSent` 비율 (delivery rate) ≥ 95%
- [ ] `PushTokenInvalidated` 30일 합계 < 전체 active user 의 10%
- [ ] Expo Receipts queue lag — receipts cron 의 last_run timestamp 가 30분 이내
- [ ] EAS credentials 페이지의 FCM/APNs key 만료일 D-30 알림 등록 (Slack 수동)

## 7. 미해결 / 후속 라운드

- [ ] FCM HTTP v1 마이그레이션 (legacy server key 폐기). 2026-06 deadline.
- [ ] APNs .p8 → Sign In with Apple key 통합 검토 (token-based auth).
- [ ] Apple Live Activities / Android Foreground Service 도입 시 push payload schema 정본 추가.
- [ ] Push payload encryption (sensitive PII 가 in-transit 노출 차단 — 현재는 server-side message body 만 보내고 client 가 in-character 본문은 fetch 로 가져옴).
