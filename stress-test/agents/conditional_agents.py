"""CMD §9-2 의 5 조건부 즉시 생성 agent.

trigger 조건이 충족되면 ConditionalAgentSpawner 가 자동 호출.
"""
from __future__ import annotations

from typing import Any
from .base import BaseAgent, AgentResult, AgentTrigger, register


@register
class BottleneckInvestigationAgent(BaseAgent):
    name = "bottleneck_investigation"
    role = "p99 latency 증가 / queue backlog 증가 / WebSocket delay 증가 시 자동 발동"
    triggers = [
        AgentTrigger("p99_latency", "stats.p99_s", 5.0, ">", 60),
        AgentTrigger("queue_backlog", "queue.backlog", 1000, ">", 30),
        AgentTrigger("ws_delay", "ws.delay_s", 3.0, ">", 60),
    ]

    async def run(self, ctx: dict[str, Any]) -> AgentResult:
        stats = ctx.get("stats", {})
        findings = []
        actions = []
        # Top slow targets
        slow_by_target = []
        results = ctx.get("results", [])
        target_lat: dict[str, list[float]] = {}
        for r in results:
            if r.get("ok"):
                target_lat.setdefault(r.get("target", "?"), []).append(r.get("latency_s", 0))
        for tgt, lats in target_lat.items():
            if not lats:
                continue
            lats_sorted = sorted(lats)
            p99 = lats_sorted[int(len(lats_sorted) * 0.99)] if len(lats_sorted) > 1 else lats_sorted[0]
            slow_by_target.append((tgt, p99))
        slow_by_target.sort(key=lambda x: x[1], reverse=True)
        for tgt, p99 in slow_by_target[:3]:
            findings.append(f"{tgt} p99: {p99:.2f}s")
            if p99 > 5.0:
                actions.append(f"{tgt} 측 DB query / 외부 provider / connection pool 점검")
        return AgentResult(self.name, "병목 구간 자동 탐지", findings, actions, "warn")


@register
class APIFailureAnalysisAgent(BaseAgent):
    name = "api_failure_analysis"
    role = "API error rate 증가 / AWS 429 증가 / retry storm 발생 시 자동 발동"
    triggers = [
        AgentTrigger("error_rate", "stats.failure_rate", 0.05, ">", 60),
        AgentTrigger("aws_429", "stats.by_status.429", 100, ">", 60),
    ]

    async def run(self, ctx: dict[str, Any]) -> AgentResult:
        stats = ctx.get("stats", {})
        results = ctx.get("results", [])
        by_status = stats.get("by_status", {})
        retry_count = sum(r.get("attempts", 1) - 1 for r in results)
        findings = [
            f"5xx: 500={by_status.get('500',0)}, 502={by_status.get('502',0)}, 503={by_status.get('503',0)}",
            f"429 throttle: {by_status.get('429', 0)}",
            f"총 retry: {retry_count}",
        ]
        actions = []
        if by_status.get("429", 0) > 50:
            actions.append("rate limit policy 검토 + 외부 provider quota 확인")
        if (by_status.get("500", 0) + by_status.get("502", 0) + by_status.get("503", 0)) > 10:
            actions.append("server logs review + circuit breaker 동작 확인")
        return AgentResult(self.name, "API 실패 패턴 분석", findings, actions, "critical" if by_status.get("500", 0) > 5 else "warn")


@register
class AIResponseAuditAgent(BaseAgent):
    name = "ai_response_audit"
    role = "invalid JSON / hallucination-like / schema mismatch 증가 시 자동 발동"
    triggers = [
        AgentTrigger("invalid_json_rate", "gemini.invalid_json_rate", 0.05, ">", 60),
        AgentTrigger("schema_mismatch_rate", "gemini.schema_mismatch_rate", 0.05, ">", 60),
    ]

    async def run(self, ctx: dict[str, Any]) -> AgentResult:
        gemini = ctx.get("gemini_results", [])
        total = len(gemini)
        invalid = sum(1 for g in gemini if g.get("invalid_json"))
        empty = sum(1 for g in gemini if g.get("empty"))
        schema_mismatch = sum(1 for g in gemini if g.get("schema_mismatch"))
        findings = [
            f"전체 {total} / invalid {invalid} / empty {empty} / schema mismatch {schema_mismatch}",
        ]
        actions = []
        if invalid > total * 0.05:
            actions.append("Gemini 응답 sanitization 강화 — 응답 JSON 검증 + canary token")
        if empty > total * 0.05:
            actions.append("Gemini safety filter trigger 여부 점검")
        return AgentResult(self.name, "AI 응답 audit", findings, actions, "warn" if invalid + empty > total * 0.05 else "info")


@register
class MemoryLeakInvestigationAgent(BaseAgent):
    name = "memory_leak_investigation"
    role = "memory usage 지속 증가 / 장시간 테스트 성능 저하 / worker 재시작 빈도 증가 시 자동 발동"
    triggers = [
        AgentTrigger("memory_usage_mb", "process.memory_mb", 1024, ">", 300),
        AgentTrigger("worker_restart", "worker.restart_count", 3, ">", 60),
    ]

    async def run(self, ctx: dict[str, Any]) -> AgentResult:
        mem = ctx.get("memory_samples", [])
        restarts = ctx.get("worker_restart_count", 0)
        findings = [
            f"memory samples: min={min(mem) if mem else 0:.0f}MB, max={max(mem) if mem else 0:.0f}MB",
            f"worker 재시작: {restarts} 회",
        ]
        actions = []
        if mem and (max(mem) - min(mem)) > 500:
            actions.append("event_id seen_set 크기 / 캐시 정책 검토")
        return AgentResult(self.name, "메모리 누수 추적", findings, actions, "warn" if restarts > 0 else "info")


@register
class SyncMismatchAnalysisAgent(BaseAgent):
    name = "sync_mismatch_analysis"
    role = "APP/ADMIN 데이터 불일치 / 이벤트 누락 / 이벤트 순서 오류 시 자동 발동"
    triggers = [
        AgentTrigger("missing_count", "app.missing", 5, ">", 60),
        AgentTrigger("dup_count", "app.duplicate", 5, ">", 60),
    ]

    async def run(self, ctx: dict[str, Any]) -> AgentResult:
        missing = ctx.get("missing_count", 0)
        dup = ctx.get("duplicate_count", 0)
        out_of_order = ctx.get("out_of_order_count", 0)
        findings = [
            f"누락 {missing} / 중복 {dup} / 순서 오류 {out_of_order}",
        ]
        actions = []
        if missing > 0:
            actions.append("이벤트 dispatch retry/DLQ 정책 점검")
        if dup > 0:
            actions.append("idempotency key 검증 강화")
        if out_of_order > 0:
            actions.append("이벤트 순서 보장 (sequence id / FIFO queue) 점검")
        return AgentResult(self.name, "동기성 불일치 분석", findings, actions, "warn" if missing + dup > 0 else "info")


# Triggers spawner — orchestrator 가 stats 기반으로 호출
def evaluate_triggers(stats: dict, gemini_stats: dict, app_stats: dict) -> list[str]:
    """충족된 trigger agent 이름 list."""
    triggered: list[str] = []
    if stats.get("p99_s", 0) > 5.0:
        triggered.append("bottleneck_investigation")
    if stats.get("failed", 0) / max(stats.get("total", 1), 1) > 0.05:
        triggered.append("api_failure_analysis")
    if stats.get("by_status", {}).get("429", 0) > 100:
        triggered.append("api_failure_analysis")
    if gemini_stats.get("invalid_rate", 0) > 0.05:
        triggered.append("ai_response_audit")
    if app_stats.get("missing", 0) > 5 or app_stats.get("duplicate", 0) > 5:
        triggered.append("sync_mismatch_analysis")
    return list(set(triggered))
