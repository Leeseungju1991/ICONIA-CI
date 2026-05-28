// k6 scenario — Locust 대안. 사용: k6 run load/k6/stress.js
//
// env: STAGING_SERVER_BASE, STRESS_JWT_TOKEN, STRESS_DURATION_S, STRESS_RPS_TARGET

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const BASE = __ENV.STAGING_SERVER_BASE || 'http://localhost:8080';
const TOKEN = __ENV.STRESS_JWT_TOKEN || '';
const DURATION = parseInt(__ENV.STRESS_DURATION_S || '300');
const RPS = parseInt(__ENV.STRESS_RPS_TARGET || '100');

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: RPS,
      timeUnit: '1s',
      duration: `${DURATION}s`,
      preAllocatedVUs: RPS * 2,
      maxVUs: RPS * 4,
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<2000', 'p(99)<5000'],
  },
};

const errors429 = new Counter('throttle_429');
const aiLatency = new Trend('ai_latency_ms');

const PROMPTS = [
  "안녕! 오늘 기분 어때?",
  "짧은 시 한 편 써줘.",
  "다음 주 일정 정리해줘.",
];

export default function () {
  const headers = TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {};
  const r = Math.random();

  if (r < 0.30) {
    const res = http.get(`${BASE}/api/v1/admin/feed/posts?page=1&page_size=25`, { headers, tags: { name: 'feed.list' } });
    check(res, { 'feed.list 2xx': (r) => r.status >= 200 && r.status < 300 });
    if (res.status === 429) errors429.add(1);
  } else if (r < 0.50) {
    const prompt = PROMPTS[Math.floor(Math.random() * PROMPTS.length)];
    const t0 = Date.now();
    const res = http.post(`${BASE}/persona/chat`, JSON.stringify({ prompt, persona_id: 'aria' }),
      { headers: { ...headers, 'Content-Type': 'application/json' }, tags: { name: 'ai.chat' } });
    aiLatency.add(Date.now() - t0);
    check(res, { 'ai.chat 2xx': (r) => r.status >= 200 && r.status < 300 });
  } else if (r < 0.70) {
    const res = http.get(`${BASE}/api/v1/admin/commerce/products?page=1&page_size=50`, { headers, tags: { name: 'commerce.list' } });
    check(res, { 'commerce 2xx': (r) => r.status >= 200 && r.status < 300 });
  } else if (r < 0.85) {
    const res = http.get(`${BASE}/api/v1/admin/users?email=&limit=10`, { headers, tags: { name: 'admin.users' } });
    check(res, { 'admin 2xx': (r) => r.status >= 200 && r.status < 300 });
  } else {
    const res = http.post(`${BASE}/api/v1/devices/heartbeat`,
      JSON.stringify({ battery: 80, firmware_version: '1.0.2' }),
      { headers: { ...headers, 'Content-Type': 'application/json' }, tags: { name: 'device.heartbeat' } });
    check(res, { 'device 2xx': (r) => r.status >= 200 && r.status < 300 });
  }
}
