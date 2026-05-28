"""Metrics Collector — Prometheus + OTel.

worker 들이 emit 한 메트릭을 단일 endpoint 로 노출 (9091).
"""
from __future__ import annotations

import os
from prometheus_client import start_http_server, Gauge, Info


METRICS_PORT = int(os.getenv("METRICS_PORT", "9091"))

# 메타데이터
PLATFORM_INFO = Info("stress_platform", "ICONIA stress test platform metadata")
PLATFORM_INFO.info({
    "version": "1.0.0",
    "target": os.getenv("STRESS_TARGET", "staging"),
    "pattern": os.getenv("STRESS_PATTERN", "steady"),
})

ACTIVE_WORKERS = Gauge("stress_active_workers", "Active workers", ["kind"])
TOTAL_EVENTS_GENERATED = Gauge("stress_events_generated_total", "Total events generated (current run)")


def start_collector() -> None:
    """Prometheus scrape endpoint on METRICS_PORT."""
    start_http_server(METRICS_PORT)


if __name__ == "__main__":
    start_collector()
    import time
    print(f"Metrics on :{METRICS_PORT}")
    while True:
        time.sleep(60)
