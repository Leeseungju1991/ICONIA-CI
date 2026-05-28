"""Agent 공통 베이스 + registry."""
from __future__ import annotations

import abc
from dataclasses import dataclass, field
from typing import Any, Optional


@dataclass
class AgentTrigger:
    """조건부 agent 의 트리거 조건."""
    name: str
    metric: str
    threshold: float
    comparator: str = ">"   # > | < | ==
    sustained_s: int = 60   # 임계 지속 시간


@dataclass
class AgentResult:
    agent: str
    summary: str
    findings: list[str] = field(default_factory=list)
    recommended_actions: list[str] = field(default_factory=list)
    severity: str = "info"  # info | warn | critical


class BaseAgent(abc.ABC):
    name: str = "base"
    role: str = ""

    @abc.abstractmethod
    async def run(self, ctx: dict[str, Any]) -> AgentResult:
        ...


# Registry
_AGENTS: dict[str, type[BaseAgent]] = {}


def register(cls: type[BaseAgent]) -> type[BaseAgent]:
    _AGENTS[cls.name] = cls
    return cls


def get_agent(name: str) -> Optional[type[BaseAgent]]:
    return _AGENTS.get(name)


def list_agents() -> list[str]:
    return sorted(_AGENTS.keys())
