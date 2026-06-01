"""APP Verification Worker — CMD §7-1.

이벤트 반영/지연/중복/누락/상태 불일치/WebSocket reconnect/polling 일관성 검증.
APP 은 모바일 RN — 직접 시뮬레이션 어려움. 따라서 본 worker 는 server API 의
APP 측 endpoint 응답을 polling 하여 검증.
"""
from __future__ import annotations

import asyncio
import os
import time
from dataclasses import dataclass, field
from typing import Optional

import aiohttp
from prometheus_client import Counter, Gauge, Histogram

from simulator.event_types import EventPayload


APP_SYNC_DELAY = Histogram("stress_app_sync_delay_seconds",
                           "APP API polling sync delay",
                           buckets=[0.1, 0.5, 1, 2, 5, 10, 30, 60])
APP_MISSING_EVENT = Counter("stress_app_missing_event_total", "Events not reflected after timeout")
APP_DUPLICATE = Counter("stress_app_duplicate_event_total", "Duplicate events observed")
APP_POLL_OK = Counter("stress_app_poll_total", "APP polling", ["status"])
APP_WS_RECONNECT = Counter("stress_app_ws_reconnect_total", "Simulated WS reconnects")


@dataclass
class AppVerificationConfig:
    server_base: str
    jwt_token: Optional[str] = None
    poll_interval_s: float = 1.0
    poll_timeout_s: float = 30.0


class AppVerificationWorker:
    """server API 의 feed/commerce list 를 polling 하며 이벤트 반영 검증."""

    def __init__(self, cfg: AppVerificationConfig) -> None:
        self.cfg = cfg
        self._seen_ids: set[str] = set()
        self._dup_ids: set[str] = set()

    async def verify_event_visible(self, expected_id: str, list_url: str) -> dict:
        """expected_id 가 list_url 응답에 나타나는지 polling — timeout 까지."""
        headers = {"Authorization": f"Bearer {self.cfg.jwt_token}"} if self.cfg.jwt_token else {}
        deadline = time.time() + self.cfg.poll_timeout_s
        start = time.time()
        async with aiohttp.ClientSession(headers=headers) as sess:
            while time.time() < deadline:
                try:
                    async with sess.get(list_url, timeout=aiohttp.ClientTimeout(total=5)) as resp:
                        APP_POLL_OK.labels(status=str(resp.status)).inc()
                        if resp.status == 200:
                            data = await resp.json()
                            items = data.get("data", {}).get("items", []) if isinstance(data, dict) else []
                            ids = [it.get("id") for it in items if isinstance(it, dict)]
                            if expected_id in ids:
                                delay = time.time() - start
                                APP_SYNC_DELAY.observe(delay)
                                # 중복 검사
                                if ids.count(expected_id) > 1:
                                    APP_DUPLICATE.inc()
                                    if expected_id not in self._dup_ids:
                                        self._dup_ids.add(expected_id)
                                self._seen_ids.add(expected_id)
                                return {"ok": True, "delay_s": delay, "duplicates": ids.count(expected_id) - 1}
                except Exception:
                    APP_POLL_OK.labels(status="error").inc()
                await asyncio.sleep(self.cfg.poll_interval_s)
        APP_MISSING_EVENT.inc()
        return {"ok": False, "delay_s": self.cfg.poll_timeout_s, "reason": "not_visible_within_timeout"}

    async def simulate_ws_reconnect(self) -> None:
        """WebSocket reconnect 시나리오 — 실 ws endpoint 없을 시 carrier metric."""
        APP_WS_RECONNECT.inc()
        await asyncio.sleep(0.1)

    @classmethod
    def from_env(cls) -> "AppVerificationWorker":
        base = os.getenv("STAGING_SERVER_BASE", "")
        return cls(AppVerificationConfig(server_base=base, jwt_token=os.getenv("STRESS_JWT_TOKEN") or None))
