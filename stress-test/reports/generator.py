"""Report Generator — JSON / CSV / HTML (CMD §11).

각 run 폴더 (`reports/output/<ts>/`) 에:
  - summary.json
  - requests.json
  - requests.csv
  - report.html  (Jinja2)
"""
from __future__ import annotations

import csv
import json
import os
import statistics
import sys
from pathlib import Path
from typing import Any

from jinja2 import Environment, FileSystemLoader


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    k = (len(s) - 1) * pct / 100
    f = int(k)
    c = min(f + 1, len(s) - 1)
    return s[f] + (s[c] - s[f]) * (k - f)


def compute_stats(results: list[dict]) -> dict:
    latencies = [r.get("latency_s", 0) for r in results if r.get("ok") and "latency_s" in r]
    by_target: dict[str, list[float]] = {}
    by_status: dict[str, int] = {}
    by_pattern: dict[str, int] = {}
    chaos_count: dict[str, int] = {}
    for r in results:
        tgt = r.get("target", "?")
        by_target.setdefault(tgt, []).append(r.get("latency_s", 0))
        st = str(r.get("status", "?"))
        by_status[st] = by_status.get(st, 0) + 1
        pat = r.get("pattern", "normal")
        by_pattern[pat] = by_pattern.get(pat, 0) + 1
        if "chaos" in r:
            chaos_count[r["chaos"]] = chaos_count.get(r["chaos"], 0) + 1
    return {
        "total": len(results),
        "ok": sum(1 for r in results if r.get("ok")),
        "failed": sum(1 for r in results if not r.get("ok")),
        "p50_s": round(percentile(latencies, 50), 4) if latencies else 0,
        "p95_s": round(percentile(latencies, 95), 4) if latencies else 0,
        "p99_s": round(percentile(latencies, 99), 4) if latencies else 0,
        "mean_s": round(statistics.mean(latencies), 4) if latencies else 0,
        "max_s": round(max(latencies), 4) if latencies else 0,
        "by_target_count": {k: len(v) for k, v in by_target.items()},
        "by_status": by_status,
        "by_pattern": by_pattern,
        "chaos_count": chaos_count,
    }


def write_csv(out_dir: Path, results: list[dict]) -> Path:
    csv_path = out_dir / "requests.csv"
    if not results:
        csv_path.write_text("")
        return csv_path
    cols = ["event_id", "event_type", "pattern", "target", "status",
            "ok", "latency_s", "attempts", "chaos", "error"]
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for r in results:
            w.writerow({k: r.get(k, "") for k in cols})
    return csv_path


HTML_TEMPLATE = """\
<!doctype html>
<html lang="ko">
<head><meta charset="utf-8"><title>ICONIA Stress Test Report — {{ summary.pattern }}</title>
<style>
body { font-family: -apple-system, sans-serif; margin: 24px; color: #222; }
h1 { font-size: 22px; }
h2 { font-size: 16px; margin-top: 24px; color: #555; }
.kpi { display: flex; gap: 12px; flex-wrap: wrap; }
.card { background: #f6f8fa; padding: 12px 16px; border-radius: 8px; min-width: 140px; }
.card .v { font-size: 24px; font-weight: bold; }
.card .l { font-size: 11px; color: #777; text-transform: uppercase; }
.ok { color: #2a7; }
.fail { color: #c33; }
.warn { color: #d70; }
table { border-collapse: collapse; width: 100%; margin: 8px 0; font-size: 13px; }
th, td { border-bottom: 1px solid #eee; padding: 6px 8px; text-align: left; }
th { background: #fafbfc; }
.bottleneck { background: #fff5e6; padding: 12px; border-left: 3px solid #e90; margin: 8px 0; }
</style>
</head><body>
<h1>ICONIA Stress Test Report</h1>
<p><b>Pattern</b>: {{ summary.pattern }} | <b>RPS target</b>: {{ summary.rps }} | <b>Duration</b>: {{ summary.duration_s }}s | <b>Started</b>: {{ summary.started_at }}</p>

<h2>KPI</h2>
<div class="kpi">
  <div class="card"><div class="l">Total</div><div class="v">{{ stats.total }}</div></div>
  <div class="card"><div class="l">OK</div><div class="v ok">{{ stats.ok }}</div></div>
  <div class="card"><div class="l">Failed</div><div class="v fail">{{ stats.failed }}</div></div>
  <div class="card"><div class="l">p50</div><div class="v">{{ stats.p50_s }}s</div></div>
  <div class="card"><div class="l">p95</div><div class="v">{{ stats.p95_s }}s</div></div>
  <div class="card"><div class="l">p99</div><div class="v">{{ stats.p99_s }}s</div></div>
  <div class="card"><div class="l">Max</div><div class="v warn">{{ stats.max_s }}s</div></div>
</div>

<h2>By Status</h2>
<table><tr><th>Status</th><th>Count</th></tr>
{% for k, v in stats.by_status.items() %}<tr><td>{{ k }}</td><td>{{ v }}</td></tr>{% endfor %}
</table>

<h2>By Target</h2>
<table><tr><th>Target</th><th>Count</th></tr>
{% for k, v in stats.by_target_count.items() %}<tr><td>{{ k }}</td><td>{{ v }}</td></tr>{% endfor %}
</table>

<h2>By Pattern (Virtual Event)</h2>
<table><tr><th>Pattern</th><th>Count</th></tr>
{% for k, v in stats.by_pattern.items() %}<tr><td>{{ k }}</td><td>{{ v }}</td></tr>{% endfor %}
</table>

{% if stats.chaos_count %}
<h2>Chaos Injection</h2>
<table><tr><th>Kind</th><th>Count</th></tr>
{% for k, v in stats.chaos_count.items() %}<tr><td>{{ k }}</td><td>{{ v }}</td></tr>{% endfor %}
</table>
{% endif %}

{% if bottlenecks %}
<h2>Bottlenecks (자동 탐지)</h2>
{% for b in bottlenecks %}<div class="bottleneck">{{ b }}</div>{% endfor %}
{% endif %}

<h2>Top 10 Slowest</h2>
<table><tr><th>Event ID</th><th>Type</th><th>Target</th><th>Latency (s)</th><th>Status</th></tr>
{% for r in slowest %}<tr><td>{{ r.event_id[:8] }}</td><td>{{ r.event_type }}</td><td>{{ r.target }}</td><td>{{ '%.3f'|format(r.latency_s) }}</td><td>{{ r.status }}</td></tr>{% endfor %}
</table>

<h2>Top 10 Errors</h2>
<table><tr><th>Event ID</th><th>Type</th><th>Target</th><th>Status</th><th>Error</th></tr>
{% for r in errors %}<tr><td>{{ r.event_id[:8] }}</td><td>{{ r.event_type }}</td><td>{{ r.target }}</td><td>{{ r.status }}</td><td>{{ r.error or '-' }}</td></tr>{% endfor %}
</table>
</body></html>
"""


def detect_bottlenecks(stats: dict, results: list[dict]) -> list[str]:
    """간단 휴리스틱 기반 병목 탐지 (CMD §3 #8)."""
    out: list[str] = []
    if stats["p99_s"] > 5.0:
        out.append(f"⚠ p99 latency {stats['p99_s']}s 가 5초를 초과 — 병목 가능성 (DB pool / 외부 provider).")
    if stats["failed"] > stats["total"] * 0.05:
        out.append(f"⚠ 실패율 {stats['failed']/max(stats['total'],1)*100:.1f}% — error rate 임계 초과.")
    if stats["by_status"].get("429", 0) > 10:
        out.append(f"⚠ 429 throttling {stats['by_status']['429']} 건 — rate limit 또는 외부 provider quota.")
    if stats["by_status"].get("500", 0) > 5 or stats["by_status"].get("502", 0) > 0 or stats["by_status"].get("503", 0) > 0:
        out.append("⚠ 5xx 응답 다수 — server 측 안정성 점검 필요.")
    if "ai" in stats["by_target_count"] and stats["by_target_count"]["ai"] > 0:
        ai_lat = [r["latency_s"] for r in results if r.get("target") == "ai" and r.get("ok")]
        if ai_lat:
            ai_p95 = percentile(ai_lat, 95)
            if ai_p95 > 5.0:
                out.append(f"⚠ AI p95 latency {ai_p95:.2f}s — Gemini provider 응답 지연 의심.")
    return out


def generate_reports(out_dir: Path, summary: dict, results: list[dict]) -> None:
    """JSON + CSV + HTML 생성."""
    stats = compute_stats(results)

    # JSON (이미 summary.json 작성됨)
    (out_dir / "stats.json").write_text(json.dumps(stats, indent=2, ensure_ascii=False))

    # CSV
    write_csv(out_dir, results)

    # HTML
    bottlenecks = detect_bottlenecks(stats, results)
    slowest = sorted([r for r in results if r.get("ok")],
                     key=lambda r: r.get("latency_s", 0), reverse=True)[:10]
    errors = [r for r in results if not r.get("ok")][:10]

    env = Environment(autoescape=True)
    tmpl = env.from_string(HTML_TEMPLATE)
    html = tmpl.render(summary=summary, stats=stats, bottlenecks=bottlenecks,
                       slowest=slowest, errors=errors)
    (out_dir / "report.html").write_text(html, encoding="utf-8")

    print(f"[Report] generated: {out_dir}/report.html, stats.json, requests.csv")


if __name__ == "__main__":
    # Standalone: 가장 최근 output 디렉토리 대상으로 리포트 재생성
    base = Path(os.getenv("REPORT_OUT_DIR", "./reports/output"))
    if not base.exists():
        print("No reports/output dir.")
        sys.exit(0)
    runs = sorted([p for p in base.iterdir() if p.is_dir()])
    if not runs:
        print("No runs found.")
        sys.exit(0)
    latest = runs[-1]
    summary = json.loads((latest / "summary.json").read_text(encoding="utf-8"))
    requests_p = latest / "requests.json"
    results = json.loads(requests_p.read_text(encoding="utf-8")) if requests_p.exists() else []
    generate_reports(latest, summary, results)
