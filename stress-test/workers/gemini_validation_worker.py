"""Gemini Validation Worker — CMD §6.

병렬 호출 + schema/token/invalid JSON/hallucination-like 검증.
"""
from __future__ import annotations

import asyncio
import json
import os
import time
from dataclasses import dataclass, field
from typing import Any, Optional

from prometheus_client import Counter, Histogram


GEMINI_REQ = Counter("stress_gemini_request_total", "Gemini requests", ["status"])
GEMINI_LATENCY = Histogram("stress_gemini_latency_seconds", "Gemini latency",
                           buckets=[0.5, 1, 2, 3, 5, 10, 30, 60])
GEMINI_TOKENS = Counter("stress_gemini_tokens_total", "Gemini token usage", ["direction"])
GEMINI_INVALID_JSON = Counter("stress_gemini_invalid_json_total", "Invalid JSON responses")
GEMINI_EMPTY = Counter("stress_gemini_empty_response_total", "Empty responses")
GEMINI_SCHEMA_MISMATCH = Counter("stress_gemini_schema_mismatch_total", "Schema mismatch")


@dataclass
class GeminiConfig:
    api_key: str
    model: str = "gemini-1.5-flash"
    max_tokens_per_run: int = 500_000
    request_timeout: float = 30.0


@dataclass
class GeminiValidationResult:
    ok: bool
    latency_s: float
    prompt_len: int
    response_text: str = ""
    input_tokens: int = 0
    output_tokens: int = 0
    error: Optional[str] = None
    invalid_json: bool = False
    empty: bool = False
    schema_mismatch: bool = False


class GeminiValidationWorker:
    """Gemini API 직접 호출 + 응답 검증.

    실제 호출은 google-generativeai SDK 사용. SDK 미설치/key 미존재 시 mock 모드.
    """
    def __init__(self, cfg: GeminiConfig) -> None:
        self.cfg = cfg
        self._tokens_used = 0
        self._client = None
        try:
            import google.generativeai as genai
            genai.configure(api_key=cfg.api_key)
            self._client = genai.GenerativeModel(cfg.model)
        except Exception:
            self._client = None  # mock fallback

    def _validate_response(self, text: str, expect_json: bool = False) -> tuple[bool, bool, bool, bool]:
        """returns (ok, invalid_json, empty, schema_mismatch)"""
        empty = not text or not text.strip()
        invalid_json = False
        schema_mismatch = False
        if expect_json and not empty:
            try:
                parsed = json.loads(text)
                if not isinstance(parsed, dict):
                    schema_mismatch = True
            except Exception:
                invalid_json = True
        ok = not (empty or invalid_json or schema_mismatch)
        return ok, invalid_json, empty, schema_mismatch

    async def call(self, prompt: str, expect_json: bool = False) -> GeminiValidationResult:
        if self._tokens_used >= self.cfg.max_tokens_per_run:
            return GeminiValidationResult(ok=False, latency_s=0, prompt_len=len(prompt),
                                          error="token_budget_exceeded")
        if not self._client:
            # Mock 모드 — 실 API key 없을 때 deterministic mock
            await asyncio.sleep(0.1)
            ok, ij, em, sm = self._validate_response("mock response", expect_json)
            GEMINI_REQ.labels(status="mock").inc()
            return GeminiValidationResult(ok=ok, latency_s=0.1, prompt_len=len(prompt),
                                          response_text="mock response", input_tokens=10,
                                          output_tokens=5, invalid_json=ij, empty=em,
                                          schema_mismatch=sm)
        t0 = time.perf_counter()
        try:
            # SDK 가 동기 — executor 로 비동기 wrap
            loop = asyncio.get_event_loop()
            resp = await asyncio.wait_for(
                loop.run_in_executor(None, lambda: self._client.generate_content(prompt)),
                timeout=self.cfg.request_timeout,
            )
            latency = time.perf_counter() - t0
            text = resp.text if hasattr(resp, "text") else str(resp)
            input_tokens = getattr(getattr(resp, "usage_metadata", None), "prompt_token_count", 0)
            output_tokens = getattr(getattr(resp, "usage_metadata", None), "candidates_token_count", 0)
            self._tokens_used += input_tokens + output_tokens
            GEMINI_TOKENS.labels(direction="input").inc(input_tokens)
            GEMINI_TOKENS.labels(direction="output").inc(output_tokens)
            GEMINI_LATENCY.observe(latency)
            ok, ij, em, sm = self._validate_response(text, expect_json)
            if ij: GEMINI_INVALID_JSON.inc()
            if em: GEMINI_EMPTY.inc()
            if sm: GEMINI_SCHEMA_MISMATCH.inc()
            GEMINI_REQ.labels(status="ok" if ok else "validation_failed").inc()
            return GeminiValidationResult(
                ok=ok, latency_s=latency, prompt_len=len(prompt),
                response_text=text[:500], input_tokens=input_tokens, output_tokens=output_tokens,
                invalid_json=ij, empty=em, schema_mismatch=sm,
            )
        except asyncio.TimeoutError:
            GEMINI_REQ.labels(status="timeout").inc()
            return GeminiValidationResult(ok=False, latency_s=time.perf_counter() - t0,
                                          prompt_len=len(prompt), error="timeout")
        except Exception as e:
            GEMINI_REQ.labels(status="error").inc()
            return GeminiValidationResult(ok=False, latency_s=time.perf_counter() - t0,
                                          prompt_len=len(prompt), error=type(e).__name__)

    @classmethod
    def from_env(cls) -> "GeminiValidationWorker":
        return cls(GeminiConfig(
            api_key=os.getenv("GEMINI_API_KEY", ""),
            model=os.getenv("GEMINI_MODEL", "gemini-1.5-flash"),
            max_tokens_per_run=int(os.getenv("GEMINI_MAX_TOKENS_PER_RUN", "500000")),
        ))
