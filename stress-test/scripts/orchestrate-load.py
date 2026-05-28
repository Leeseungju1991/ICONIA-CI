#!/usr/bin/env python
"""Main orchestrator — 모든 worker 를 병렬 실행.

CMD §8-2 (병렬 작업) 충족. asyncio.gather 로 다음을 동시 실행:
  - Virtual Event Generator
  - AWS Load Worker
  - Gemini Validation Worker
  - APP Verification Worker
  - ADMIN Verification Worker
  - Chaos Injection Worker
  - Metrics Collector
  - Report Generator (run 종료 후)
"""
from __future__ import annotations

import asyncio
import os
import sys
import time
from pathlib import Path

# 상위 디렉토리 PYTHONPATH 추가
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dotenv import load_dotenv
load_dotenv()

from simulator.orchestrator import make_simulator
from workers.aws_load_worker import AWSLoadWorker, AWSLoadConfig, start_metrics_server
from workers.gemini_validation_worker import GeminiValidationWorker
from workers.app_verification_worker import AppVerificationWorker
from workers.admin_verification_worker import AdminVerificationWorker
from workers.chaos_injection_worker import ChaosInjectionWorker, ChaosConfig


async def run_event_loop(sim, aws_worker, chaos, app_verifier, results: list) -> None:
    async for event in sim.stream():
        chaos_kind = await chaos.maybe_inject()
        if chaos_kind == "throttle":
            # throttle 시뮬레이션 — request 건너뛰기
            results.append({"ok": False, "skipped": "throttle", "event_id": event.event_id})
            continue
        r = await aws_worker.send(event)
        r["event_id"] = event.event_id
        r["pattern"] = event.pattern
        r["event_type"] = event.event_type
        if chaos_kind:
            r["chaos"] = chaos_kind
        results.append(r)


async def run_admin_loop(admin_verifier, deadline: float) -> list[dict]:
    """ADMIN 동시 접속 시뮬레이션 — 4개 페이지 병렬 fetch 반복."""
    admin_results = []
    paths = ["/dashboard", "/dashboard/user-360", "/dashboard/feed", "/dashboard/content/commerce"]
    while time.time() < deadline:
        r = await admin_verifier.verify_admin_consistency(paths)
        admin_results.extend(r)
        await asyncio.sleep(5)
    return admin_results


async def run_gemini_loop(gemini, deadline: float) -> list[dict]:
    """Gemini 병렬 요청 + 응답 검증."""
    prompts = [
        "안녕! 오늘 기분 어때?",
        "짧은 시 한 편 써줘.",
        "x" * 5000,  # long prompt
        "INVALID_PROMPT_<>{}",  # malformed-like
    ]
    results = []
    while time.time() < deadline:
        batch = [gemini.call(p) for p in prompts]
        outs = await asyncio.gather(*batch, return_exceptions=True)
        for o in outs:
            if isinstance(o, Exception):
                results.append({"ok": False, "error": type(o).__name__})
            else:
                results.append({
                    "ok": o.ok, "latency_s": o.latency_s, "input_tokens": o.input_tokens,
                    "output_tokens": o.output_tokens, "invalid_json": o.invalid_json,
                    "empty": o.empty, "schema_mismatch": o.schema_mismatch, "error": o.error,
                })
        await asyncio.sleep(2)
    return results


async def main() -> None:
    pattern = os.getenv("STRESS_PATTERN", "steady")
    rps = int(os.getenv("STRESS_RPS_TARGET", "100"))
    duration_s = int(os.getenv("STRESS_DURATION_S", "300"))

    print(f"[ICONIA Stress] pattern={pattern} rps={rps} duration={duration_s}s")
    print(f"[ICONIA Stress] target={os.getenv('STRESS_TARGET', 'staging')}")

    # 안전 가드: production 금지
    server_base = os.getenv("STAGING_SERVER_BASE", "")
    if "prod" in server_base.lower() and "staging" not in server_base.lower():
        print("❌ STAGING_SERVER_BASE 가 production endpoint 처럼 보입니다. 중단.")
        sys.exit(2)

    # Prometheus metrics endpoint
    start_metrics_server(int(os.getenv("METRICS_PORT", "9091")))
    print(f"[ICONIA Stress] Metrics on :{os.getenv('METRICS_PORT', '9091')}/metrics")

    sim = make_simulator(pattern, rps, duration_s)
    aws_cfg = AWSLoadConfig.from_env()
    chaos = ChaosInjectionWorker(ChaosConfig.from_env())
    gemini = GeminiValidationWorker.from_env()
    app_verifier = AppVerificationWorker.from_env()
    admin_verifier = AdminVerificationWorker.from_env()

    aws_results: list = []
    deadline = time.time() + duration_s

    async with AWSLoadWorker(aws_cfg) as aws_worker:
        # 병렬 실행
        await asyncio.gather(
            run_event_loop(sim, aws_worker, chaos, app_verifier, aws_results),
            run_admin_loop(admin_verifier, deadline),
            run_gemini_loop(gemini, deadline),
        )

    # 리포트 생성
    out_dir = Path(os.getenv("REPORT_OUT_DIR", "./reports/output")) / time.strftime("%Y%m%d-%H%M%S")
    out_dir.mkdir(parents=True, exist_ok=True)

    import json
    summary = {
        "pattern": pattern,
        "rps": rps,
        "duration_s": duration_s,
        "total_requests": len(aws_results),
        "successful": sum(1 for r in aws_results if r.get("ok")),
        "failed": sum(1 for r in aws_results if not r.get("ok")),
        "throttled": sum(1 for r in aws_results if r.get("skipped") == "throttle"),
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(deadline - duration_s)),
        "ended_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time())),
    }
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    (out_dir / "requests.json").write_text(json.dumps(aws_results[:10000], indent=2, ensure_ascii=False))
    print(f"[ICONIA Stress] Done. Results: {out_dir}")
    print(json.dumps(summary, indent=2, ensure_ascii=False))

    # 리포트 generator 호출
    from reports.generator import generate_reports
    generate_reports(out_dir, summary, aws_results)


if __name__ == "__main__":
    asyncio.run(main())
