"""CMD §9-1 의 8 기본 agent.

각 agent 는 ctx (worker 결과, metrics, etc.) 를 받아 분석 결과를 돌려준다.
"""
from __future__ import annotations

from typing import Any
from .base import BaseAgent, AgentResult, register


@register
class VirtualEventAgent(BaseAgent):
    name = "virtual_event"
    role = "HW 대체 이벤트 생성 + 부하량 조절 — simulator.virtual_events 직접 호출"

    async def run(self, ctx: dict[str, Any]) -> AgentResult:
        rps = ctx.get("rps", 0)
        pattern = ctx.get("pattern", "?")
        return AgentResult(
            agent=self.name,
            summary=f"Virtual event generation: pattern={pattern}, target_rps={rps}",
            findings=[f"events 생성 패턴 {ctx.get('patterns_used', [])}"],
            recommended_actions=[],
        )


@register
class AWSLoadAgent(BaseAgent):
    name = "aws_load"
    role = "AWS API 부하 + Lambda/SQS/DynamoDB 병목 분석 + retry/throttling 감지"

    async def run(self, ctx: dict[str, Any]) -> AgentResult:
        stats = ctx.get("stats", {})
        findings = []
        actions = []
        sev = "info"
        if stats.get("by_status", {}).get("429", 0) > 10:
            findings.append(f"429 throttling {stats['by_status']['429']} 건")
            actions.append("rate limit 조정 또는 외부 quota 확장")
            sev = "warn"
        if stats.get("by_status", {}).get("500", 0) > 5:
            findings.append("5xx 응답 다수 — server 안정성 점검")
            sev = "critical"
        if stats.get("p99_s", 0) > 5.0:
            findings.append(f"p99 latency {stats['p99_s']}s 임계 초과")
            actions.append("DB pool, 외부 provider 응답 확인")
            sev = "warn"
        return AgentResult(self.name, "AWS load 분석", findings, actions, sev)


@register
class GeminiValidationAgent(BaseAgent):
    name = "gemini_validation"
    role = "Gemini 응답 검증 + schema 검증 + token usage 분석 + invalid response 탐지"

    async def run(self, ctx: dict[str, Any]) -> AgentResult:
        gemini_results = ctx.get("gemini_results", [])
        invalid = sum(1 for g in gemini_results if g.get("invalid_json"))
        empty = sum(1 for g in gemini_results if g.get("empty"))
        schema_mismatch = sum(1 for g in gemini_results if g.get("schema_mismatch"))
        total_tokens = sum(g.get("input_tokens", 0) + g.get("output_tokens", 0) for g in gemini_results)
        findings = [
            f"Gemini 호출 {len(gemini_results)} / invalid JSON {invalid} / empty {empty} / schema mismatch {schema_mismatch}",
            f"Total tokens used: {total_tokens:,}",
        ]
        sev = "info"
        actions = []
        if invalid > len(gemini_results) * 0.05:
            sev = "warn"
            actions.append("Gemini 응답 형식 sanitization 강화 + canary token 검증")
        return AgentResult(self.name, "Gemini 응답 검증", findings, actions, sev)


@register
class AppVerificationAgent(BaseAgent):
    name = "app_verification"
    role = "APP 상태 반영 검증 + WebSocket/API polling + 데이터 누락 탐지"

    async def run(self, ctx: dict[str, Any]) -> AgentResult:
        missing = ctx.get("missing_count", 0)
        dup = ctx.get("duplicate_count", 0)
        avg_delay = ctx.get("avg_sync_delay_s", 0)
        findings = [
            f"누락 이벤트 {missing} 건",
            f"중복 이벤트 {dup} 건",
            f"평균 sync delay {avg_delay:.2f}s",
        ]
        sev = "warn" if (missing > 0 or avg_delay > 5) else "info"
        return AgentResult(self.name, "APP 동기성 검증", findings, [], sev)


@register
class AdminVerificationAgent(BaseAgent):
    name = "admin_verification"
    role = "관리자 화면 상태 + 동시 접속 + 권한/필터/검색 상태 검증"

    async def run(self, ctx: dict[str, Any]) -> AgentResult:
        results = ctx.get("admin_results", [])
        ok = sum(1 for r in results if r.get("ok"))
        fail = len(results) - ok
        findings = [f"ADMIN page fetch {len(results)} / ok {ok} / fail {fail}"]
        return AgentResult(self.name, "ADMIN 동시 접속 검증", findings, [], "warn" if fail else "info")


@register
class ChaosInjectionAgent(BaseAgent):
    name = "chaos_injection"
    role = "timeout / latency / throttling / network instability / partial failure 주입"

    async def run(self, ctx: dict[str, Any]) -> AgentResult:
        chaos = ctx.get("chaos_count", {})
        return AgentResult(self.name, "Chaos injection 결과",
                           [f"{k}: {v}" for k, v in chaos.items()], [], "info")


@register
class MetricsAnalysisAgent(BaseAgent):
    name = "metrics_analysis"
    role = "latency / error rate / p95/p99 / 병목 분석"

    async def run(self, ctx: dict[str, Any]) -> AgentResult:
        stats = ctx.get("stats", {})
        return AgentResult(
            self.name, "메트릭 분석",
            [f"p50={stats.get('p50_s',0)}s / p95={stats.get('p95_s',0)}s / p99={stats.get('p99_s',0)}s",
             f"성공률 {(stats.get('ok',0)/max(stats.get('total',1),1)*100):.1f}%"],
            [], "info"
        )


@register
class ReportAgent(BaseAgent):
    name = "report"
    role = "JSON / CSV / HTML 리포트 + 실패 요약 생성"

    async def run(self, ctx: dict[str, Any]) -> AgentResult:
        out_dir = ctx.get("out_dir", "?")
        return AgentResult(self.name, f"리포트 생성 완료: {out_dir}", [], [], "info")
