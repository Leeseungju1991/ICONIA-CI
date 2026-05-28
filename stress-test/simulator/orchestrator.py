"""부하 패턴 orchestrator — CMD §8-1 의 15 가지 부하 방식.

각 패턴은 SimulatorConfig 를 조정해 stream() 으로 흘려보낸다.
"""
from __future__ import annotations

from dataclasses import replace
from .virtual_events import SimulatorConfig, VirtualEventSimulator


def cfg_for_pattern(pattern: str, base: SimulatorConfig) -> SimulatorConfig:
    p = pattern.lower()
    if p == "steady":
        return base
    if p == "spike":
        return replace(base, target_rps=base.target_rps * 10, duration_s=60)
    if p == "soak":
        return replace(base, target_rps=max(base.target_rps // 2, 10), duration_s=86400)
    if p == "stress":
        return replace(base, target_rps=base.target_rps * 5)
    if p == "chaos":
        return replace(base, malformed_ratio=0.15, timeout_ratio=0.15, abnormal_ratio=0.10, normal_ratio=0.40)
    if p == "burst":
        return replace(base, burst_ratio=0.30, normal_ratio=0.55)
    if p == "retry-storm":
        return replace(base, timeout_ratio=0.20, normal_ratio=0.60)
    if p == "queue-saturation":
        return replace(base, target_rps=base.target_rps * 20, duration_s=120)
    if p == "websocket-fanout":
        return replace(base, target_rps=base.target_rps, duration_s=180)
    if p == "ai-concurrency":
        return replace(base, target_rps=50, duration_s=180)
    if p == "admin-concurrent":
        return replace(base, target_rps=20, duration_s=300)
    if p == "data-consistency":
        return replace(base, duplicate_ratio=0.10, out_of_order_ratio=0.10, normal_ratio=0.70)
    if p == "failure-recovery":
        return replace(base, timeout_ratio=0.25, normal_ratio=0.55)
    if p == "memory-leak":
        return replace(base, target_rps=max(base.target_rps, 50), duration_s=3600)
    if p == "long-run":
        return replace(base, target_rps=base.target_rps, duration_s=3600 * 6)
    return base


def make_simulator(pattern: str, rps: int, duration_s: int) -> VirtualEventSimulator:
    base = SimulatorConfig(target_rps=rps, duration_s=duration_s)
    cfg = cfg_for_pattern(pattern, base)
    return VirtualEventSimulator(cfg)
