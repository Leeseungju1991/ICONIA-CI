"""Agent 등록 + 결과 형식 검증."""
import asyncio
import pytest
from agents.base import list_agents, get_agent, AgentResult
from agents.basic_agents import (
    VirtualEventAgent, AWSLoadAgent, GeminiValidationAgent,
    AppVerificationAgent, AdminVerificationAgent, ChaosInjectionAgent,
    MetricsAnalysisAgent, ReportAgent,
)
from agents.conditional_agents import (
    BottleneckInvestigationAgent, APIFailureAnalysisAgent,
    AIResponseAuditAgent, MemoryLeakInvestigationAgent, SyncMismatchAnalysisAgent,
    evaluate_triggers,
)


def test_basic_8_agents_registered():
    expected = {
        "virtual_event", "aws_load", "gemini_validation",
        "app_verification", "admin_verification", "chaos_injection",
        "metrics_analysis", "report",
    }
    assert expected.issubset(set(list_agents()))


def test_conditional_5_agents_registered():
    expected = {
        "bottleneck_investigation", "api_failure_analysis",
        "ai_response_audit", "memory_leak_investigation", "sync_mismatch_analysis",
    }
    assert expected.issubset(set(list_agents()))


@pytest.mark.asyncio
async def test_aws_load_agent_returns_warn_for_high_429():
    agent = AWSLoadAgent()
    result = await agent.run({"stats": {"by_status": {"429": 100, "200": 800}, "p99_s": 1.0}})
    assert isinstance(result, AgentResult)
    assert result.severity in ("warn", "critical")
    assert any("429" in f for f in result.findings)


@pytest.mark.asyncio
async def test_bottleneck_agent_no_crash_on_empty():
    agent = BottleneckInvestigationAgent()
    result = await agent.run({"stats": {}, "results": []})
    assert isinstance(result, AgentResult)


def test_evaluate_triggers_p99():
    triggered = evaluate_triggers({"p99_s": 6.0}, {}, {})
    assert "bottleneck_investigation" in triggered


def test_evaluate_triggers_429():
    triggered = evaluate_triggers({"by_status": {"429": 200}, "p99_s": 1.0}, {}, {})
    assert "api_failure_analysis" in triggered


def test_evaluate_triggers_app_missing():
    triggered = evaluate_triggers({"p99_s": 1.0}, {}, {"missing": 10})
    assert "sync_mismatch_analysis" in triggered
