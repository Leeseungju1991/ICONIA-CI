"""Chaos Injection Worker — CMD §8-1, §9-1 (6) Chaos Injection Agent.

요청 전·후로 timeout/latency/throttling/network instability/partial failure 주입.
"""
from __future__ import annotations

import asyncio
import os
import random
from dataclasses import dataclass
from prometheus_client import Counter


CHAOS_INJECTED = Counter("stress_chaos_injected_total", "Chaos events injected", ["kind"])


@dataclass
class ChaosConfig:
    enabled: bool = False
    timeout_ratio: float = 0.02
    latency_ms: int = 500
    throttle_429_ratio: float = 0.05
    partial_failure_ratio: float = 0.01

    @classmethod
    def from_env(cls) -> "ChaosConfig":
        return cls(
            enabled=os.getenv("CHAOS_ENABLED", "false").lower() in ("1", "true", "yes"),
            timeout_ratio=float(os.getenv("CHAOS_TIMEOUT_RATIO", "0.02")),
            latency_ms=int(os.getenv("CHAOS_LATENCY_MS", "500")),
            throttle_429_ratio=float(os.getenv("CHAOS_THROTTLE_429_RATIO", "0.05")),
            partial_failure_ratio=float(os.getenv("CHAOS_PARTIAL_FAILURE_RATIO", "0.01")),
        )


class ChaosInjectionWorker:
    def __init__(self, cfg: ChaosConfig) -> None:
        self.cfg = cfg

    async def maybe_inject(self) -> str | None:
        """본 호출 전에 호출 — chaos 발생 여부 반환.

        Returns:
            "timeout" | "latency" | "throttle" | "partial_failure" | None
        """
        if not self.cfg.enabled:
            return None
        r = random.random()
        if r < self.cfg.timeout_ratio:
            CHAOS_INJECTED.labels(kind="timeout").inc()
            await asyncio.sleep(30)  # 강제 timeout
            return "timeout"
        if r < self.cfg.timeout_ratio + self.cfg.throttle_429_ratio:
            CHAOS_INJECTED.labels(kind="throttle").inc()
            return "throttle"
        if r < self.cfg.timeout_ratio + self.cfg.throttle_429_ratio + self.cfg.partial_failure_ratio:
            CHAOS_INJECTED.labels(kind="partial_failure").inc()
            return "partial_failure"
        # 일반 latency 주입 (확률 더 높음)
        if random.random() < 0.05:
            CHAOS_INJECTED.labels(kind="latency").inc()
            await asyncio.sleep(self.cfg.latency_ms / 1000.0)
            return "latency"
        return None
