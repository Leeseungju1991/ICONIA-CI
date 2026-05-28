# Performance Baseline

> Stage 6 실측 시점에 갱신. 현재는 초기 목표값 + 알려진 측정 결과만 기록.

## 1. SERVER (Express :8080)

| Endpoint | p50 target | p95 target | p99 target | Measured (Stage 6) |
|---|---|---|---|---|
| GET /health | < 10ms | < 50ms | < 100ms | (pending) |
| POST /auth/login | < 100ms | < 300ms | < 800ms | (pending) |
| GET /api/v1/admin/feed/posts (paginated) | < 200ms | < 500ms | < 1500ms | (pending) |
| GET /api/v1/admin/commerce/products | < 200ms | < 500ms | < 1500ms | (pending) |
| POST /api/v1/admin/feed/posts/:id/takedown | < 300ms | < 800ms | < 2000ms | (pending) |
| GET /api/v1/admin/users?email= | < 200ms | < 500ms | < 1500ms | (pending) |

## 2. AI (Gemini wrapper :8081)

| Endpoint | p50 target | p95 target | p99 target | Measured |
|---|---|---|---|---|
| POST /persona/chat (default tier) | < 1500ms | < 3000ms | < 6000ms | (pending) |
| POST /persona/chat (with RAG) | < 2000ms | < 5000ms | < 10000ms | (pending) |
| GET /health | < 10ms | < 50ms | < 100ms | (pending) |

AI provider (Gemini) 외부 latency 가 dominant — 변동 큼.

## 3. ADMIN (Next.js :3000 / ALB :8082)

| Page | Cold load target | Subsequent target | Measured |
|---|---|---|---|
| /login | < 800ms | < 200ms | (pending) |
| /dashboard | < 1500ms | < 500ms | (pending) |
| /dashboard/user-360 | < 1500ms | < 500ms | (pending) |
| /dashboard/feed | < 1500ms | < 500ms | (pending) |
| /dashboard/content/commerce | < 1500ms | < 500ms | (pending) |

ADMIN 의 first chunk load 는 standalone tar.gz 크기 (~90MB) 영향.

## 4. APP (RN Expo)

| Metric | Target | Measured |
|---|---|---|
| Cold start (app launch → home) | < 3000ms | (pending HIL) |
| BLE scan duration | < 5000ms | (HIL_REQUIRED) |
| BLE connect duration | < 3000ms | (HIL_REQUIRED) |
| Wi-Fi provisioning duration | < 15000ms | (HIL_REQUIRED) |
| AI chat response (mock + AI) | < 3000ms | (pending) |
| Feed load (network) | < 1500ms | (pending) |

## 5. HW (Firmware)

| Metric | Target | Measured |
|---|---|---|
| Deep-sleep current | < 50µA | (commit 7d47ae0 V1.0 강화) |
| Active current (idle BLE) | < 30mA | (HIL) |
| BLE advertisement interval | 100~200ms | (configured) |
| Wi-Fi connect | < 10s | (HIL) |
| OTA download (1MB firmware) | < 30s | (HIL) |
| Boot time (cold) | < 3s | (HIL) |

## 6. DB (RDS PostgreSQL)

| Metric | Target | Measured |
|---|---|---|
| Query latency p95 (read) | < 50ms | (pending) |
| Query latency p95 (write) | < 100ms | (pending) |
| Connection pool size | 20 | (configured) |
| Connection saturation alarm | > 80% | (configured) |

## 7. Network / Infra

| Metric | Target |
|---|---|
| ALB → server health timeout | 5s |
| Server → AI health timeout | 5s |
| Server → DB timeout | 5s |
| External (Gemini) timeout | 30s |
| External (Gemini) total budget | 60s |

## 8. Resource Budget

- **EC2 instance**: t4g.medium (2 vCPU / 4GB) — Server + AI + Admin co-located in current PoC
- **RDS**: db.t4g.medium (2 vCPU / 4GB)
- **CloudWatch logs retention**: 30일 (general), 5년 (audit)

## 9. LEGAL_REVIEW_REQUIRED
- HD-11: AI provider 비용 한도 → 부하 테스트 시 한도 초과 방지 필요
