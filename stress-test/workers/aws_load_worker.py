"""AWS Load Worker — 가상 이벤트를 ALB/API endpoint 로 전송 + 메트릭 수집.

target endpoint:
  - SERVER  (Express :80 또는 :8080)
  - ADMIN   (Next.js :8082)
  - AI      (Gemini wrapper :8081)

CMD §5-1, §5-2 의 검증 항목 측정.
"""
from __future__ import annotations

import asyncio
import os
import time
from dataclasses import dataclass, field
from typing import Any, Optional

import aiohttp
from prometheus_client import Counter, Histogram, start_http_server

from simulator.event_types import EventPayload, EventType


# Prometheus 메트릭 (CMD §10-2)
REQ_TOTAL = Counter("stress_request_total", "Total requests", ["target", "event_type", "status"])
REQ_LATENCY = Histogram("stress_request_latency_seconds", "Request latency",
                        ["target", "event_type"], buckets=[0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 30])
TIMEOUT_COUNT = Counter("stress_timeout_total", "Timeouts", ["target"])
RETRY_COUNT = Counter("stress_retry_total", "Retries", ["target"])
THROTTLE_429 = Counter("stress_throttle_429_total", "429 throttling", ["target"])


@dataclass
class AWSLoadConfig:
    server_base: str
    admin_base: str
    ai_base: str
    jwt_token: Optional[str] = None
    request_timeout: float = 10.0
    max_retries: int = 3
    backoff_base: float = 0.5

    @classmethod
    def from_env(cls) -> "AWSLoadConfig":
        target = os.getenv("STRESS_TARGET", "staging").lower()
        if target == "local":
            return cls(
                server_base=os.getenv("LOCAL_SERVER_BASE", "http://localhost:8080"),
                admin_base=os.getenv("LOCAL_ADMIN_BASE", "http://localhost:3000"),
                ai_base=os.getenv("LOCAL_AI_BASE", "http://localhost:8081"),
                jwt_token=os.getenv("STRESS_JWT_TOKEN") or None,
            )
        return cls(
            server_base=os.getenv("STAGING_SERVER_BASE", ""),
            admin_base=os.getenv("STAGING_ADMIN_BASE", ""),
            ai_base=os.getenv("STAGING_AI_BASE", ""),
            jwt_token=os.getenv("STRESS_JWT_TOKEN") or None,
        )


class AWSLoadWorker:
    def __init__(self, cfg: AWSLoadConfig) -> None:
        self.cfg = cfg
        self._session: Optional[aiohttp.ClientSession] = None

    async def __aenter__(self) -> "AWSLoadWorker":
        headers = {"User-Agent": "ICONIA-Stress/1.0"}
        if self.cfg.jwt_token:
            headers["Authorization"] = f"Bearer {self.cfg.jwt_token}"
        self._session = aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=self.cfg.request_timeout),
            headers=headers,
        )
        return self

    async def __aexit__(self, *args) -> None:
        if self._session:
            await self._session.close()

    def _resolve_target(self, event: EventPayload) -> tuple[str, str, str, Optional[dict]]:
        """이벤트 타입 → (target_label, method, url, body)"""
        et = event.event_type
        c = self.cfg
        if et.startswith("admin."):
            base = c.admin_base
            target = "admin"
        elif et.startswith("ai."):
            base = c.ai_base
            target = "ai"
        else:
            base = c.server_base
            target = "server"

        method = "GET"
        path = "/health"
        body = None

        if et == EventType.FEED_LIST.value:
            method = "GET"; path = "/api/v1/admin/feed/posts"
        elif et == EventType.FEED_POST_CREATE.value:
            method = "POST"; path = "/api/v1/feed/posts"; body = event.payload
        elif et == EventType.COMMERCE_LIST.value:
            method = "GET"; path = "/api/v1/admin/commerce/products"
        elif et == EventType.USER_LOGIN.value:
            method = "POST"; path = "/auth/login"; body = event.payload
        elif et == EventType.AI_CHAT_REQUEST.value:
            method = "POST"; path = "/persona/chat"; body = event.payload
        elif et == EventType.DEVICE_HEARTBEAT.value:
            method = "POST"; path = "/api/v1/devices/heartbeat"; body = event.payload
        elif et == EventType.ADMIN_USERS_SEARCH.value:
            method = "GET"; path = "/api/v1/admin/users?email=&limit=50"
        return target, method, base + path, body

    async def send(self, event: EventPayload) -> dict[str, Any]:
        target, method, url, body = self._resolve_target(event)
        attempts = 0
        last_status = 0
        last_error: Optional[str] = None
        latency = 0.0
        assert self._session
        while attempts < self.cfg.max_retries:
            t0 = time.perf_counter()
            try:
                async with self._session.request(
                    method, url, json=body
                ) as resp:
                    last_status = resp.status
                    latency = time.perf_counter() - t0
                    REQ_LATENCY.labels(target=target, event_type=event.event_type).observe(latency)
                    REQ_TOTAL.labels(target=target, event_type=event.event_type, status=str(resp.status)).inc()
                    if resp.status == 429:
                        THROTTLE_429.labels(target=target).inc()
                    if resp.status < 500:
                        await resp.text()
                        return {"ok": resp.status < 400, "status": resp.status,
                                "latency_s": latency, "target": target, "attempts": attempts + 1}
            except asyncio.TimeoutError:
                TIMEOUT_COUNT.labels(target=target).inc()
                last_error = "timeout"
            except Exception as e:
                last_error = type(e).__name__
            attempts += 1
            if attempts < self.cfg.max_retries:
                RETRY_COUNT.labels(target=target).inc()
                await asyncio.sleep(self.cfg.backoff_base * (2 ** attempts))
        return {
            "ok": False, "status": last_status, "latency_s": latency,
            "target": target, "attempts": attempts, "error": last_error,
        }


def start_metrics_server(port: int = 9091) -> None:
    """Prometheus scrape endpoint."""
    start_http_server(port)
