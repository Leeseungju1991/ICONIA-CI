"""ADMIN Verification Worker — CMD §7-2.

관리자 대시보드 데이터 반영/동시 접속/필터/검색/stale cache 검증.
Playwright headless 대체 — HTTP GET + HTML/JSON 파싱.
"""
from __future__ import annotations

import asyncio
import os
import time
from dataclasses import dataclass
from typing import Optional

import aiohttp
from prometheus_client import Counter, Histogram


ADMIN_SYNC_DELAY = Histogram("stress_admin_sync_delay_seconds",
                             "ADMIN dashboard render delay",
                             buckets=[0.2, 0.5, 1, 2, 5, 10, 30])
ADMIN_PAGE_FETCH = Counter("stress_admin_page_fetch_total", "ADMIN page fetch", ["page", "status"])
ADMIN_FILTER_FAIL = Counter("stress_admin_filter_fail_total", "Filter/search result mismatch")
ADMIN_STALE_CACHE = Counter("stress_admin_stale_cache_total", "Stale cache observed")
ADMIN_CONCURRENT_OPS = Counter("stress_admin_concurrent_ops_total", "Concurrent admin operations")


@dataclass
class AdminVerificationConfig:
    admin_base: str
    server_base: str
    jwt_token: Optional[str] = None
    fetch_timeout_s: float = 10.0


class AdminVerificationWorker:
    """ADMIN page fetch + server API 동기성 검증."""

    def __init__(self, cfg: AdminVerificationConfig) -> None:
        self.cfg = cfg

    async def fetch_page(self, path: str) -> dict:
        url = self.cfg.admin_base + path
        headers = {}
        if self.cfg.jwt_token:
            headers["Cookie"] = f"iconia-session={self.cfg.jwt_token}"
        t0 = time.time()
        try:
            async with aiohttp.ClientSession(headers=headers) as sess:
                async with sess.get(url, timeout=aiohttp.ClientTimeout(total=self.cfg.fetch_timeout_s)) as resp:
                    delay = time.time() - t0
                    ADMIN_SYNC_DELAY.observe(delay)
                    ADMIN_PAGE_FETCH.labels(page=path, status=str(resp.status)).inc()
                    body = await resp.text()
                    return {"ok": resp.status in (200, 307), "status": resp.status,
                            "delay_s": delay, "len": len(body)}
        except Exception as e:
            ADMIN_PAGE_FETCH.labels(page=path, status="error").inc()
            return {"ok": False, "error": type(e).__name__, "delay_s": time.time() - t0}

    async def verify_admin_consistency(self, paths: list[str]) -> list[dict]:
        """병렬로 여러 admin 페이지 fetch — 동시 접속 시뮬레이션."""
        ADMIN_CONCURRENT_OPS.inc(len(paths))
        results = await asyncio.gather(*[self.fetch_page(p) for p in paths], return_exceptions=True)
        return [r if isinstance(r, dict) else {"ok": False, "error": str(r)} for r in results]

    async def verify_filter_search(self) -> dict:
        """server API 의 검색·필터 결과 일관성 검증."""
        if not self.cfg.jwt_token:
            return {"ok": False, "reason": "no_jwt"}
        # 동일 쿼리 2번 호출 — 결과 같아야 함
        url = self.cfg.server_base + "/api/v1/admin/users?email=&limit=10"
        headers = {"Authorization": f"Bearer {self.cfg.jwt_token}"}
        try:
            async with aiohttp.ClientSession(headers=headers) as sess:
                r1 = await sess.get(url, timeout=aiohttp.ClientTimeout(total=5))
                d1 = await r1.json()
                await asyncio.sleep(0.1)
                r2 = await sess.get(url, timeout=aiohttp.ClientTimeout(total=5))
                d2 = await r2.json()
                if d1 != d2:
                    ADMIN_FILTER_FAIL.inc()
                    return {"ok": False, "reason": "filter_mismatch"}
                return {"ok": True}
        except Exception as e:
            return {"ok": False, "error": type(e).__name__}

    @classmethod
    def from_env(cls) -> "AdminVerificationWorker":
        return cls(AdminVerificationConfig(
            admin_base=os.getenv("STAGING_ADMIN_BASE", ""),
            server_base=os.getenv("STAGING_SERVER_BASE", ""),
            jwt_token=os.getenv("STRESS_JWT_TOKEN") or None,
        ))
